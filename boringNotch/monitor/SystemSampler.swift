//
//  SystemSampler.swift
//  boringCode
//
//  Leituras baratas direto do kernel, sem processos externos: CPU pelos ticks
//  do host (mach), disco pelo volume de inicialização e rede pelos contadores
//  de 64 bits das interfaces (sysctl NET_RT_IFLIST2); temperatura, ventoinhas,
//  watts e GPU em `SystemSensors.swift`. Cada leitura custa microssegundos (a
//  temperatura, ~10 ms esperando o chip); o monitor só chama com a aba aberta.
//

import Darwin
import Foundation
import IOKit.ps

struct SystemSample: Equatable, Sendable {
    /// 0…1. nil na primeira leitura (CPU precisa de duas para ter o intervalo).
    var cpu: Double?
    var storageTotal: Int64?
    var storageAvailable: Int64?
    /// Bytes por segundo. nil na primeira leitura.
    var download: Double?
    var upload: Double?
    /// Bytes em uso (como o "Memória usada" do Monitor de Atividade) e total físico.
    var memoryUsed: Int64?
    var memoryTotal: Int64 = Int64(ProcessInfo.processInfo.physicalMemory)
    /// 0…1.
    var gpu: Double?
    /// °C do chip.
    var temperature: Double?
    /// Rotação média das ventoinhas (rpm) e a máxima delas; nil em Mac sem ventoinha.
    var fanSpeed: Double?
    var fanMaxSpeed: Double?
    /// Consumo do Mac inteiro, em watts.
    var power: Double?

    var memoryFraction: Double? {
        guard let used = memoryUsed, memoryTotal > 0 else { return nil }
        return min(1, max(0, Double(used) / Double(memoryTotal)))
    }

    var storageUsedFraction: Double? {
        guard let total = storageTotal, let available = storageAvailable, total > 0 else { return nil }
        return min(1, max(0, Double(total - available) / Double(total)))
    }
}

actor SystemSampler {
    private var previousTicks: (busy: UInt64, total: UInt64)?
    private var previousBytes: (received: UInt64, sent: UInt64, time: TimeInterval)?
    private var cachedStorage: (total: Int64, available: Int64, time: TimeInterval)?
    // Abertos na primeira leitura e soltos quando a aba fecha (`stop`).
    private var chipSensors: ChipTemperatureSensors?
    private var smc: SMCReader?
    private var smcOpened = false

    /// O disco muda devagar: relê no máximo a cada 10 s.
    private static let storageInterval: TimeInterval = 10

    func sample() -> SystemSample {
        var result = SystemSample()
        result.cpu = cpuUsage()
        result.memoryUsed = memoryUsed()
        (result.download, result.upload) = networkRates()
        if let storage = storage() {
            result.storageTotal = storage.total
            result.storageAvailable = storage.available
        }
        result.gpu = GPUStatistics.utilization()
        readSensors(into: &result)
        return result
    }

    /// Fecha o SMC e os sensores (a aba fechou).
    func stop() {
        chipSensors = nil
        smc = nil
        smcOpened = false
    }

    /// Zera o histórico (ao reabrir a aba, o primeiro intervalo não conta o tempo fechado).
    func reset() {
        previousTicks = nil
        previousBytes = nil
    }

    // MARK: - CPU

    private func cpuUsage() -> Double? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }

        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle
        defer { previousTicks = (busy, total) }

        guard let previous = previousTicks, total > previous.total else { return nil }
        return min(1, max(0, Double(busy &- previous.busy) / Double(total - previous.total)))
    }

    // MARK: - Memória

    /// Memória de apps + fixa (wired) + comprimida — a mesma conta do Monitor de Atividade.
    private func memoryUsed() -> Int64? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let pageSize = Int64(vm_kernel_page_size)
        let appPages = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
        let pages = max(0, appPages) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
        return pages * pageSize
    }

    // MARK: - Rede

    private func networkRates() -> (Double?, Double?) {
        guard let (received, sent) = Self.interfaceBytes() else { return (nil, nil) }
        let now = ProcessInfo.processInfo.systemUptime
        defer { previousBytes = (received, sent, now) }

        guard let previous = previousBytes, now > previous.time else { return (nil, nil) }
        let elapsed = now - previous.time
        // Contador zerado (interface caiu e voltou): conta como zero, não como negativo.
        let down = received >= previous.received ? Double(received - previous.received) / elapsed : 0
        let up = sent >= previous.sent ? Double(sent - previous.sent) / elapsed : 0
        return (down, up)
    }

    /// Soma dos bytes das interfaces físicas (Wi-Fi/Ethernet `en*`, celular `pdp_ip*`).
    /// VPN (`utun`) fica de fora: o tráfego dela já passa pela interface física.
    private static func interfaceBytes() -> (UInt64, UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

        var received: UInt64 = 0, sent: UInt64 = 0
        var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if if_indextoname(UInt32(message.ifm_index), &nameBuffer) != nil {
                        let name = String(cString: nameBuffer)
                        if name.hasPrefix("en") || name.hasPrefix("pdp_ip") {
                            received += message.ifm_data.ifi_ibytes
                            sent += message.ifm_data.ifi_obytes
                        }
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (received, sent)
    }

    // MARK: - Sensores

    private func readSensors(into result: inout SystemSample) {
        if chipSensors == nil { chipSensors = ChipTemperatureSensors() }
        if !smcOpened {
            smc = SMCReader()
            smcOpened = true
        }

        result.temperature = chipSensors?.read()
            ?? smc?.intelChipTemperature()

        if let smc {
            let fans = Int(smc.value("FNum") ?? 0)
            if fans > 0 {
                let speeds = (0..<fans).compactMap { smc.value("F\($0)Ac") }
                if !speeds.isEmpty { result.fanSpeed = speeds.reduce(0, +) / Double(speeds.count) }
                result.fanMaxSpeed = (0..<fans).compactMap { smc.value("F\($0)Mx") }.max()
            }
            if let watts = smc.value("PSTR"), watts > 0 { result.power = watts }
        }
    }

    // MARK: - Disco

    private func storage() -> (total: Int64, available: Int64)? {
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = cachedStorage, now - cached.time < Self.storageInterval {
            return (cached.total, cached.available)
        }
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return cachedStorage.map { ($0.total, $0.available) } }
        cachedStorage = (Int64(total), available, now)
        return (Int64(total), available)
    }
}

enum SystemPower {
    /// Mac com bateria interna (MacBook)? Em Mac de mesa o cartão de bateria some.
    static let hasInternalBattery: Bool = {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        return list.contains { source in
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { return false }
            return description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }()
}

