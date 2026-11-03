//
//  SystemMonitorSettingsView.swift
//  boringCode
//
//  Ajustes do monitor do sistema: que cartões mostrar (até 8) e de quanto em quanto tempo medir.
//

import Defaults
import SwiftUI

struct SystemMonitorSettingsView: View {
    @Default(.monitorEnabled) private var monitorEnabled
    @Default(.monitorInterval) private var monitorInterval
    @Default(.monitorShowCPU) private var showCPU
    @Default(.monitorShowGPU) private var showGPU
    @Default(.monitorShowMemory) private var showMemory
    @Default(.monitorShowTemperature) private var showTemperature
    @Default(.monitorShowStorage) private var showStorage
    @Default(.monitorShowBattery) private var showBattery
    @Default(.monitorShowPower) private var showPower
    @Default(.monitorShowDownload) private var showDownload
    @Default(.monitorShowUpload) private var showUpload

    /// Ligados e que este Mac tem (sem o limite de 8).
    private var chosenCount: Int {
        let on: [SystemMetric: Bool] = [
            .cpu: showCPU, .gpu: showGPU, .memory: showMemory, .temperature: showTemperature, .storage: showStorage,
            .battery: showBattery, .power: showPower, .download: showDownload, .upload: showUpload,
        ]
        return SystemMetric.allCases.filter { $0.isSupported && on[$0] == true }.count
    }

    private var isFull: Bool { chosenCount >= SystemMetric.maximumShown }

    /// Com 8 ligados, os desligados ficam esperando: no notch só cabem 8.
    @ViewBuilder
    private func metricToggle(_ key: Defaults.Key<Bool>, isOn: Bool, _ title: LocalizedStringKey) -> some View {
        Defaults.Toggle(key: key) { Text(title) }
            .disabled(isFull && !isOn)
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .monitorEnabled) {
                    Text("Show the system monitor in the notch")
                }
            } footer: {
                Text("Adds a button next to the mirror in the open notch.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Section {
                metricToggle(.monitorShowCPU, isOn: showCPU, "CPU")
                if SystemMetric.gpu.isSupported {
                    metricToggle(.monitorShowGPU, isOn: showGPU, "GPU")
                }
                metricToggle(.monitorShowMemory, isOn: showMemory, "Memory")
                if SystemMetric.temperature.isSupported {
                    metricToggle(.monitorShowTemperature, isOn: showTemperature, "Temperature")
                }
                metricToggle(.monitorShowStorage, isOn: showStorage, "Storage")
                if SystemMetric.battery.isSupported {
                    metricToggle(.monitorShowBattery, isOn: showBattery, "Battery")
                }
                if SystemMetric.power.isSupported {
                    metricToggle(.monitorShowPower, isOn: showPower, "Power")
                }
                metricToggle(.monitorShowDownload, isOn: showDownload, "Download")
                metricToggle(.monitorShowUpload, isOn: showUpload, "Upload")
            } header: {
                Text("Metrics")
            } footer: {
                Text("Up to 8 at a time. Temperature shows the chip and, on Macs with fans, how fast they spin. Power is what the whole Mac is drawing right now.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .disabled(!monitorEnabled)

            Section {
                Picker("Update every", selection: $monitorInterval) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Updates")
            } footer: {
                Text("Readings only happen while the monitor is open, so it costs nothing in the background.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .disabled(!monitorEnabled)
        }
        .formStyle(.grouped)
        .navigationTitle("System Monitor")
    }
}
