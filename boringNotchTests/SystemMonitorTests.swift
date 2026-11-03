//
//  SystemMonitorTests.swift
//  boringCode
//
//  Grade do monitor (ordem e limite de 8 cartões) e formatação dos novos números.
//

import XCTest
@testable import boringNotch

@MainActor
final class SystemMonitorTests: XCTestCase {
    func testShownKeepsGridOrderAndCapsAtEight() {
        let all = SystemMetric.shown { _ in true }
        XCTAssertLessThanOrEqual(all.count, SystemMetric.maximumShown)
        // Mesma ordem de `allCases`, só sem os que este Mac não tem.
        XCTAssertEqual(all, Array(SystemMetric.allCases.filter(\.isSupported).prefix(SystemMetric.maximumShown)))
    }

    func testShownSkipsDisabled() {
        XCTAssertEqual(SystemMetric.shown { $0 == .cpu || $0 == .upload }, [.cpu, .upload])
        XCTAssertTrue(SystemMetric.shown { _ in false }.isEmpty)
    }

    func testTemperatureAndWattsParts() {
        let temperature = SystemMonitor.temperatureParts(52.4)
        if SystemMonitor.usesFahrenheit {
            XCTAssertEqual(temperature.number, "126")
            XCTAssertEqual(temperature.unit, "°F")
        } else {
            XCTAssertEqual(temperature.number, "52")
            XCTAssertEqual(temperature.unit, "°C")
        }
        XCTAssertEqual(SystemMonitor.wattsParts(11.84).unit, "W")
        XCTAssertTrue(SystemMonitor.wattsParts(11.84).number.hasPrefix("11"))
    }
}
