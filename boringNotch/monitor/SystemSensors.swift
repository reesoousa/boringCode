//
//  SystemSensors.swift
//  boringCode
//
//  Sensores do Mac lidos sem permissão nenhuma (o app não tem sandbox):
//  - temperatura do chip pelos sensores HID (Apple Silicon: "PMU tdie*") ou pelo
//    SMC (Intel: TC0P/TC0D…);
//  - ventoinhas e consumo do Mac inteiro (watts) pelo SMC;
//  - uso da GPU pelas estatísticas do driver (IOAccelerator).
//  Tudo dentro do `SystemSampler` (actor), só enquanto o monitor está aberto.
//

import Foundation
import IOKit

// MARK: - HID (temperatura no Apple Silicon)

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: CFTypeRef, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: CFTypeRef) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: CFTypeRef, _ key: CFString) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: CFTypeRef, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: CFTypeRef, _ field: Int32) -> Double

/// Sensores de temperatura do chip. No M1…M4 os de dentro do die se chamam "PMU tdie1…14";
/// os "tdev" dão lixo (−9200) e os de bateria/SSD não interessam aqui.
final class ChipTemperatureSensors {
    private static let temperatureEvent: Int64 = 15
    private static let temperatureField: Int32 = 15 << 16

    /// Os serviços só respondem enquanto o cliente existe: fica guardado mesmo sem uso direto.
    private let client: CFTypeRef?
    private let services: [CFTypeRef]

    init() {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue() else {
            self.client = nil
            services = []
            return
        }
        // Página de uso da Apple (0xff00), uso 5 = sensor de temperatura.
        _ = IOHIDEventSystemClientSetMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let all = (IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [CFTypeRef]) ?? []
        let named = all.map { service in
            (service, (IOHIDServiceClientCopyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String) ?? "")
        }
        // M1/M2 também têm "pACC/eACC MTR Temp Sensor" (núcleos); se não houver tdie, usa esses.
        // Cada nome aparece até 3 vezes com o mesmo valor: um de cada basta (leitura 3× mais rápida).
        var seen = Set<String>()
        let unique = named.filter { seen.insert($0.1).inserted }
        let die = unique.filter { $0.1.contains("tdie") }
        let cores = unique.filter { $0.1.contains("ACC MTR") }
        self.client = client
        services = (die.isEmpty ? cores : die).map(\.0)
    }

    var isAvailable: Bool { !services.isEmpty }

    /// Média dos sensores do die em °C (descarta leituras fora do plausível).
    func read() -> Double? {
        let values = services.compactMap { service -> Double? in
            guard let event = IOHIDServiceClientCopyEvent(service, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { return nil }
            let value = IOHIDEventGetFloatValue(event, Self.temperatureField)
            return (5...130).contains(value) ? value : nil
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

// MARK: - SMC (ventoinhas, watts, temperatura no Intel)

/// Leitor mínimo do SMC (AppleSMC). Ler não pede permissão; escrever pediria root.
final class SMCReader {
    // Mesmo layout do `SMCKeyData_t` do kernel (80 bytes). Os campos de preenchimento
    // importam: o Swift não alinha structs aninhadas como o C.
    private struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
    private struct PLimit { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, memory: UInt32 = 0 }
    private struct KeyInfo { var size: UInt32 = 0, type: UInt32 = 0, attributes: UInt8 = 0, pad0: UInt8 = 0, pad1: UInt8 = 0, pad2: UInt8 = 0 }
    private struct Param {
        var key: UInt32 = 0
        var version = Version()
        var limit = PLimit()
        var info = KeyInfo()
        var result: UInt8 = 0, status: UInt8 = 0, command: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }

    private static let readBytes: UInt8 = 5
    private static let readKeyInfo: UInt8 = 9

    private var connection: io_connect_t = 0
    private var infoCache: [UInt32: KeyInfo] = [:]

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit {
        IOServiceClose(connection)
    }

    /// Valor numérico da chave (tipos flt, sp78, fpe2, ui8/16/32), ou nil se não existir.
    func value(_ key: String) -> Double? {
        let code = key.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard let info = keyInfo(code), info.size > 0, info.size <= 32 else { return nil }

        var input = Param()
        input.key = code
        input.info.size = info.size
        input.command = Self.readBytes
        guard let output = call(&input) else { return nil }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(info.size))) }

        switch Self.fourCC(info.type) {
        case "flt " where bytes.count == 4:
            return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        case "sp78" where bytes.count == 2:
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "fpe2" where bytes.count == 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "ui8 " where bytes.count == 1:
            return Double(bytes[0])
        case "ui16" where bytes.count == 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32" where bytes.count == 4:
            return Double(bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        default:
            return nil
        }
    }

    /// Temperatura do processador no Intel (no Apple Silicon ela vem dos sensores HID).
    func intelChipTemperature() -> Double? {
        ["TC0P", "TC0D", "TC0E", "TC0F", "TCXC"].lazy.compactMap { self.value($0) }.first { (5...130).contains($0) }
    }

    private func keyInfo(_ code: UInt32) -> KeyInfo? {
        if let cached = infoCache[code] { return cached }
        var input = Param()
        input.key = code
        input.command = Self.readKeyInfo
        let info = call(&input)?.info ?? KeyInfo()  // chave inexistente fica em cache como tamanho 0
        infoCache[code] = info
        return info
    }

    private func call(_ input: inout Param) -> Param? {
        var output = Param()
        var size = MemoryLayout<Param>.stride
        let status = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<Param>.stride, &output, &size)
        return status == kIOReturnSuccess && output.result == 0 ? output : nil
    }

    private static func fourCC(_ value: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8(value >> $0 & 0xff) }, encoding: .ascii) ?? ""
    }
}

// MARK: - GPU

enum GPUStatistics {
    /// Uso da GPU (0…1) pelo "Device Utilization %" do driver; nil sem GPU que informe.
    static func utilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        var best: Double?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
                  let percent = (stats["Device Utilization %"] ?? stats["GPU Activity(%)"]) as? NSNumber
            else { continue }
            // Mac com duas GPUs (Intel + AMD): vale a mais ocupada.
            best = max(best ?? 0, percent.doubleValue / 100)
        }
        return best.map { min(1, max(0, $0)) }
    }

    /// Núcleos da GPU (Apple Silicon), lido uma vez.
    static let coreCount: Int? = {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            if let cores = IORegistryEntryCreateCFProperty(entry, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber {
                return cores.intValue
            }
        }
        return nil
    }()
}

// MARK: - O que este Mac tem

/// Detectado uma vez (~10 ms) para os Ajustes e a aba saberem que cartões oferecer.
enum SystemSensorSupport {
    static let temperature: Bool = ChipTemperatureSensors().isAvailable || SMCReader()?.intelChipTemperature() != nil
    static let power: Bool = (SMCReader()?.value("PSTR") ?? 0) > 0
    static let gpu: Bool = GPUStatistics.utilization() != nil
}
