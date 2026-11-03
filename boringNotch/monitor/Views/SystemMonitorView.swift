//
//  SystemMonitorView.swift
//  boringCode
//
//  Aba do monitor: CPU, GPU, memória, temperatura, armazenamento, bateria,
//  energia, download e upload em cartões no visual do app — cinza/branco,
//  cantos 12, barra do player. Até 6 em 3×2; 7–8 em 4×2, num cartão mais
//  estreito (nome em cima, número embaixo).
//  Ao abrir, os cartões chegam em cascata (desfoque → nítido, com mola) e as
//  barras crescem enquanto os números contam do zero até o valor atual.
//

import Defaults
import SwiftUI

struct SystemMonitorView: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var battery = BatteryStatusViewModel.shared
    @Default(.monitorShowCPU) private var showCPU
    @Default(.monitorShowGPU) private var showGPU
    @Default(.monitorShowMemory) private var showMemory
    @Default(.monitorShowTemperature) private var showTemperature
    @Default(.monitorShowStorage) private var showStorage
    @Default(.monitorShowBattery) private var showBattery
    @Default(.monitorShowPower) private var showPower
    @Default(.monitorShowDownload) private var showDownload
    @Default(.monitorShowUpload) private var showUpload
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var appeared = false

    private var metrics: [SystemMetric] {
        SystemMetric.shown { metric in
            switch metric {
            case .cpu: showCPU
            case .gpu: showGPU
            case .memory: showMemory
            case .temperature: showTemperature
            case .storage: showStorage
            case .battery: showBattery
            case .power: showPower
            case .download: showDownload
            case .upload: showUpload
            }
        }
    }

    /// 1–3 lado a lado; 4 em 2×2; 5–6 em linhas de três; 7–8 em linhas de quatro.
    private var perRow: Int {
        switch metrics.count {
        case 4: 2
        case 7...: 4
        default: 3
        }
    }

    private var rows: [[SystemMetric]] {
        let perRow = perRow
        return stride(from: 0, to: metrics.count, by: perRow).map {
            Array(metrics[$0..<min($0 + perRow, metrics.count)])
        }
    }

    var body: some View {
        Group {
            if metrics.isEmpty {
                emptyState
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                        HStack(spacing: 8) {
                            ForEach(Array(row.enumerated()), id: \.element) { columnIndex, metric in
                                SystemMonitorTile(
                                    metric: metric,
                                    reading: reading(for: metric),
                                    compact: perRow == 4,
                                    appeared: appeared,
                                    // Cascata na diagonal: a onda desce e anda para a direita.
                                    order: rowIndex + columnIndex
                                )
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                            }
                        }
                    }
                }
                .animation(.smooth(duration: 0.35), value: metrics)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            monitor.begin()
            if reduceMotion {
                appeared = true
            } else {
                // Um quadro depois, para tudo sair do zero.
                DispatchQueue.main.async { appeared = true }
            }
        }
        .onDisappear {
            monitor.end()
            appeared = false
        }
    }

    // MARK: - Leituras

    private func reading(for metric: SystemMetric) -> SystemMonitorTile.Reading {
        let sample = monitor.sample
        switch metric {
        case .cpu:
            return .init(
                number: (sample.cpu ?? 0) * 100,
                format: .percent,
                detail: String(localized: "\(ProcessInfo.processInfo.activeProcessorCount) cores"),
                fraction: sample.cpu ?? 0,
                ready: sample.cpu != nil
            )
        case .gpu:
            return .init(
                number: (sample.gpu ?? 0) * 100,
                format: .percent,
                detail: GPUStatistics.coreCount.map { String(localized: "\($0) cores") } ?? "",
                fraction: sample.gpu ?? 0,
                ready: sample.gpu != nil
            )
        case .temperature:
            let celsius = sample.temperature ?? 0
            return .init(
                number: celsius,
                format: .temperature,
                detail: temperatureDetail(sample),
                // 30 °C (frio) → 0; 100 °C (o chip começa a segurar) → cheia.
                fraction: min(1, max(0, (celsius - 30) / 70)),
                ready: sample.temperature != nil,
                shortDetail: sample.fanSpeed.flatMap { $0 < 100 ? nil : "\(SystemMonitor.rpm($0)) rpm" }
            )
        case .power:
            return .init(
                number: sample.power ?? 0,
                format: .watts,
                detail: String(localized: "Peak \(SystemMonitor.watts(monitor.powerScale))"),
                fraction: min(1, (sample.power ?? 0) / monitor.powerScale),
                ready: sample.power != nil
            )
        case .memory:
            let used = SystemMonitor.memory(sample.memoryUsed)
            let total = SystemMonitor.memory(sample.memoryTotal)
            return .init(
                number: (sample.memoryFraction ?? 0) * 100,
                format: .percent,
                detail: String(localized: "\(used) of \(total)"),
                fraction: sample.memoryFraction ?? 0,
                ready: sample.memoryFraction != nil,
                shortDetail: used
            )
        case .storage:
            return .init(
                number: (sample.storageUsedFraction ?? 0) * 100,
                format: .percent,
                detail: sample.storageAvailable.map { String(localized: "\(SystemMonitor.bytes($0)) free") } ?? "",
                fraction: sample.storageUsedFraction ?? 0,
                ready: sample.storageUsedFraction != nil
            )
        case .battery:
            return .init(
                number: Double(battery.levelBattery),
                format: .percent,
                detail: batteryDetail,
                fraction: Double(battery.levelBattery) / 100,
                ready: true,
                symbol: batterySymbol,
                shortDetail: batteryShortDetail
            )
        case .download:
            return .init(
                number: sample.download ?? 0,
                format: .rate,
                detail: String(localized: "Peak \(SystemMonitor.rate(monitor.downloadScale))"),
                fraction: min(1, (sample.download ?? 0) / monitor.downloadScale),
                ready: sample.download != nil
            )
        case .upload:
            return .init(
                number: sample.upload ?? 0,
                format: .rate,
                detail: String(localized: "Peak \(SystemMonitor.rate(monitor.uploadScale))"),
                fraction: min(1, (sample.upload ?? 0) / monitor.uploadScale),
                ready: sample.upload != nil
            )
        }
    }

    /// Ventoinhas quando o Mac tem (paradas no MacBook Pro frio); senão, como o sistema está lidando com o calor.
    private func temperatureDetail(_ sample: SystemSample) -> String {
        if let speed = sample.fanSpeed {
            return speed < 100 ? String(localized: "Fans off") : String(localized: "Fans \(SystemMonitor.rpm(speed)) rpm")
        }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return String(localized: "Normal")
        case .fair: return String(localized: "Warm")
        case .serious: return String(localized: "Hot · slowing down")
        case .critical: return String(localized: "Very hot")
        @unknown default: return ""
        }
    }

    private var batterySymbol: String {
        if battery.isCharging { return "battery.100percent.bolt" }
        switch battery.levelBattery {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    /// Só o tempo ("2h 10min"), sem "restantes"/"para carregar".
    private var batteryShortDetail: String? {
        let minutes = battery.isCharging ? battery.timeToFullCharge : battery.isPluggedIn ? 0 : battery.timeToDischarge
        return minutes > 0 ? SystemMonitor.duration(minutes: minutes) : nil
    }

    private var batteryDetail: String {
        if battery.isCharging {
            if battery.timeToFullCharge > 0 {
                return String(localized: "Full in \(SystemMonitor.duration(minutes: battery.timeToFullCharge))")
            }
            return String(localized: "Charging")
        }
        if battery.isPluggedIn { return String(localized: "Plugged in") }
        if battery.timeToDischarge > 0 {
            return String(localized: "\(SystemMonitor.duration(minutes: battery.timeToDischarge)) left")
        }
        return String(localized: "On battery")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.gray)
            Text("Choose what to monitor in Settings")
                .font(.system(.title3, design: .rounded))
                .fontWeight(.medium)
                .foregroundStyle(.gray)
        }
    }
}

/// Os cartões, na ordem da grade.
enum SystemMetric: Hashable, CaseIterable {
    case cpu, gpu, memory, temperature, storage, battery, power, download, upload

    /// Cabem 8 (4×2) no notch aberto.
    static let maximumShown = 8

    /// Os ligados que este Mac tem (bateria, sensores), no máximo `maximumShown`.
    static func shown(_ isOn: (SystemMetric) -> Bool) -> [SystemMetric] {
        Array(allCases.filter { $0.isSupported && isOn($0) }.prefix(maximumShown))
    }

    /// Este Mac tem como medir? (Mac de mesa não tem bateria; alguns Intel não dão watts.)
    var isSupported: Bool {
        switch self {
        case .battery: SystemPower.hasInternalBattery
        case .gpu: SystemSensorSupport.gpu
        case .temperature: SystemSensorSupport.temperature
        case .power: SystemSensorSupport.power
        case .cpu, .memory, .storage, .download, .upload: true
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .temperature: "Temperature"
        case .storage: "Storage"
        case .battery: "Battery"
        case .power: "Power"
        case .download: "Download"
        case .upload: "Upload"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "square.stack.3d.up"
        case .memory: "memorychip"
        case .temperature: "thermometer.medium"
        case .storage: "internaldrive"
        case .battery: "battery.100percent"
        case .power: "bolt"
        case .download: "arrow.down"
        case .upload: "arrow.up"
        }
    }
}

// MARK: - Cartão

struct SystemMonitorTile: View {
    struct Reading: Equatable {
        enum Format: Equatable { case percent, rate, temperature, watts }

        /// Valor que os números "contam" (0–100 em %, bytes/s na rede).
        var number: Double
        var format: Format
        var detail: String
        var fraction: Double
        /// Já tem leitura? Antes disso o número mostra "—".
        var ready: Bool
        /// Ícone próprio (bateria muda com o nível).
        var symbol: String?
        /// Versão menor do detalhe para o cartão compacto ("2.320 rpm" em vez de "Ventoinhas 2.320 rpm").
        var shortDetail: String?
    }

    let metric: SystemMetric
    let reading: Reading
    /// Grade de 4 colunas: o nome sobe para uma linha só dele e o detalhe divide a linha
    /// com o número (some se não couber).
    var compact = false
    let appeared: Bool
    /// Posição na cascata de entrada.
    let order: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Cartão chega: desfoque → nítido, sobe um pouco, com mola suave.
    private var entrance: Animation {
        reduceMotion ? .smooth(duration: 0.2)
            : .spring(response: 0.6, dampingFraction: 0.82).delay(Double(order) * 0.06)
    }

    /// Barra e número juntos, logo depois do cartão.
    private var fill: Animation {
        reduceMotion ? .smooth(duration: 0.2)
            : .spring(response: 1.0, dampingFraction: 0.86).delay(0.1 + Double(order) * 0.07)
    }

    private var shownNumber: Double { appeared && reading.ready ? reading.number : 0 }
    private var shownFraction: Double { appeared ? reading.fraction : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            if compact {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    icon
                    title
                    Spacer(minLength: 0)
                }
                // Sem o ícone na frente: o número começa na borda do cartão, como o nome do detalhe.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        number
                        Spacer(minLength: 0)
                        detail(reading.detail)
                    }
                    if let short = reading.shortDetail {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            number
                            Spacer(minLength: 0)
                            detail(short)
                        }
                    }
                    HStack(alignment: .firstTextBaseline) {
                        number
                        Spacer(minLength: 0)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    icon
                    title
                    Spacer(minLength: 4)
                    number
                }

                // Alinhado ao nome (ícone de 18 + espaço de 6).
                detail(reading.detail)
                    .padding(.leading, 24)
            }

            Spacer(minLength: 0)

            SystemMonitorBar(fraction: shownFraction)
                .animation(.smooth(duration: 0.6), value: reading.fraction)
                .animation(fill, value: appeared)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // minWidth 0: textos de tamanho fixo não alargam um cartão mais que os vizinhos.
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.94)
        .blur(radius: appeared || reduceMotion ? 0 : 6)
        .offset(y: appeared || reduceMotion ? 0 : 8)
        .animation(entrance, value: appeared)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(metric.title))
        .accessibilityValue(Text(verbatim: "\(CountingText.string(reading.number, reading.format)), \(reading.detail)"))
    }

    private var icon: some View {
        Image(systemName: reading.symbol ?? metric.symbol)
            // Bateria é um símbolo largo: um ponto menor para caber na mesma coluna.
            .font(.system(size: metric == .battery ? 10.5 : 12, weight: .medium))
            .foregroundStyle(.gray)
            .frame(width: 18)
            .contentTransition(.symbolEffect(.replace))
    }

    private var title: some View {
        Text(metric.title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.gray)
            .lineLimit(1)
            .fixedSize()  // nomes curtos: sempre inteiros
    }

    private var number: some View {
        Group {
            if reading.ready || !appeared {
                CountingText(value: shownNumber, format: reading.format)
            } else {
                Text(verbatim: "—")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .animation(.smooth(duration: 0.6), value: reading.number)
        .animation(fill, value: appeared)
    }

    private func detail(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.gray.opacity(0.8))
            .lineLimit(1)
            // No compacto, sem caber ele some inteiro (ViewThatFits) em vez de virar "Ventoi…".
            .fixedSize(horizontal: compact, vertical: false)
            .contentTransition(.numericText())
            .animation(.smooth(duration: 0.4), value: text)
    }
}

/// Número que conta até o valor (interpolado a cada quadro pela animação), com a
/// unidade menor e em cinza ao lado — "36 %", "23,9 MB/s" — como nos apps da Apple.
struct CountingText: View, Animatable {
    var value: Double
    let format: SystemMonitorTile.Reading.Format

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        let parts = Self.parts(value, format)
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(verbatim: parts.number)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(verbatim: parts.unit)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.gray)
        }
    }

    static func string(_ value: Double, _ format: SystemMonitorTile.Reading.Format) -> String {
        let parts = parts(value, format)
        return format == .percent || format == .temperature ? "\(parts.number)\(parts.unit)" : "\(parts.number) \(parts.unit)"
    }

    static func parts(_ value: Double, _ format: SystemMonitorTile.Reading.Format) -> (number: String, unit: String) {
        switch format {
        case .percent: ("\(Int(value.rounded()))", "%")
        case .rate: SystemMonitor.rateParts(value)
        case .temperature: SystemMonitor.temperatureParts(value)
        case .watts: SystemMonitor.wattsParts(value)
        }
    }
}

/// A barra do player de música: trilho cinza, 4 pt, cantos redondos, preenchimento branco.
struct SystemMonitorBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.gray.opacity(0.3))
                Capsule()
                    .fill(Color.white)
                    .frame(width: geometry.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 4)
    }
}

/// Botão do cabeçalho, no mesmo formato dos vizinhos (cápsula preta de 30 pt).
/// Aberto, ganha o fundo da aba selecionada.
struct SystemMonitorHeaderButton: View {
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Capsule()
                .fill(isActive ? Color(nsColor: .secondarySystemFill) : Color.black)
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .foregroundColor(.white)
                        .padding()
                        .imageScale(.medium)
                }
                .animation(.smooth(duration: 0.3), value: isActive)
        }
        .buttonStyle(PlainButtonStyle())
        .help(Text("System monitor"))
        .accessibilityLabel(Text("System monitor"))
    }
}
