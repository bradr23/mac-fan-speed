import XCTest
@testable import SMCKit

/// Sensor names taken from real dumps of machines the developer does not own.
///
/// Every string here was observed on actual hardware and posted publicly, not
/// inferred from a pattern. They exist so that a change to the naming rules
/// cannot quietly break a Mac nobody here can test.
final class RealHardwareNamesTests: XCTestCase {

    // MARK: M1 and M2 — the named families

    func testM1NamedFamilies() {
        // M1 and M1 Pro expose descriptive names the app can genuinely translate.
        let expected: [String: String] = [
            "pACC MTR Temp Sensor2": "Performance cores 2",
            "eACC MTR Temp Sensor0": "Efficiency cores 0",
            "GPU MTR Temp Sensor1": "Graphics 1",
            "SOC MTR Temp Sensor0": "System-on-chip 0",
            "ANE MTR Temp Sensor1": "Neural Engine 1",
            "ISP MTR Temp Sensor5": "Image processor 5",
            "PMGR SOC Die Temp Sensor0": "System-on-chip die 0",
        ]
        for (raw, friendly) in expected {
            XCTAssertEqual(SensorNaming.friendlyName(for: raw), friendly, raw)
        }
    }

    func testDieIndexZeroExists() {
        // M1 Pro and M2 number from zero; an implementation assuming 1-based
        // would mislabel or drop it.
        XCTAssertEqual(SensorNaming.friendlyName(for: "PMU tdie0"), "Processor die 0")
    }

    // MARK: PMU2 is a second controller, not a second die

    func testPMU2IsNotDescribedAsASecondDie() {
        // Dumps from M2 Ultra and M3 Ultra contain no PMU2 sensors at all, while
        // base M1, base M4 and A18 do. PMU2 is a second power controller on
        // single-die machines, so calling it a second package was backwards.
        let name = SensorNaming.friendlyName(for: "PMU2 tdie5")
        XCTAssertEqual(name, "Die sensor 5 (second controller)")
        XCTAssertFalse(name?.lowercased().contains("package") ?? true)

        XCTAssertEqual(SensorNaming.friendlyName(for: "PMU2 tcal"),
                       "Calibration reference (second controller)")
    }

    // MARK: Names with no published meaning

    func testOpaquePMUSensorsKeepTheirNameButAreStillGrouped() {
        // "PMU TP1g" and "PMU2 TR1d" appear on M1 Pro through M2 Ultra and on
        // older macOS. What they measure is not published, so inventing a label
        // would be a guess — but they are clearly processor-side and should not
        // be dumped into "Other".
        XCTAssertNil(SensorNaming.friendlyName(for: "PMU TP1g"))
        XCTAssertNil(SensorNaming.friendlyName(for: "PMU2 TR1d"))
        XCTAssertEqual(SensorCategory.classify("PMU TP1g"), .processor)
        XCTAssertEqual(SensorCategory.classify("PMU2 TR1d"), .processor)
    }

    // MARK: Peripherals

    func testChargerAndStorageAndBattery() {
        // Charger sensors were observed on an A18 Pro Mac17,5.
        XCTAssertEqual(SensorNaming.friendlyName(for: "Charger TQ0d"), "Charger")
        XCTAssertEqual(SensorCategory.classify("Charger TQ0d"), .power)

        XCTAssertEqual(SensorNaming.friendlyName(for: "NAND CH0 temp"),
                       "Storage — NAND channel 0")
        XCTAssertEqual(SensorNaming.friendlyName(for: "gas gauge battery"), "Battery")
    }

    func testDesktopsWithoutABatteryAreNormal() {
        // Every Mac mini and Mac Studio dump lacks "gas gauge battery" entirely,
        // with nothing replacing it. Its absence must not look like a fault.
        let desktop = [
            TemperatureSensor(name: "PMU tdie1", celsius: 40, tier: .socDie, smcKey: "TP1b"),
            TemperatureSensor(name: "NAND CH0 temp", celsius: 33, tier: .excluded, smcKey: "TN0n"),
        ]
        let sections = SensorReading.byCategory(desktop)
        XCTAssertEqual(sections.map(\.category), [.processor, .storage])
        XCTAssertFalse(sections.contains { $0.category == .battery })
    }

    // MARK: Renaming across macOS versions

    func testSameHardwareRenamedAcrossOSVersionsStillWorks() {
        // The same M1 reports "PMU2 TR1d" on macOS 11–13 and "PMU2 tdie1" on
        // macOS 15+. Both must classify as processor, so an OS upgrade does not
        // move sensors into "Other".
        XCTAssertEqual(SensorCategory.classify("PMU2 TR1d"), .processor)
        XCTAssertEqual(SensorCategory.classify("PMU2 tdie1"), .processor)
    }

    // MARK: Duplication

    func testNamesRepeatBetweenTwoAndEightTimes() {
        // Observed repetition ranges from 2× to 8× across services; on M2 Ultra
        // tdie1 and tdie2 repeat 8× while the rest repeat 4×. The SMC key is
        // what identifies a sensor, not the name or the count.
        let raw = (0..<8).map { _ in
            TemperatureSensor(name: "PMU tdie1", celsius: 45, tier: .socDie, smcKey: "TP1b")
        }
        let grouped = SensorReading.group(raw)
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].sourceCount, 8)
    }
}

/// Sensors that must never reach the failsafe, whatever they report.
final class FailsafeInputExclusionTests: XCTestCase {

    func testCalibrationConstantIsNeverTreatedAsCPU() {
        // tcal is a fixed constant, not a measurement: 51.85 on every Apple
        // Silicon machine regardless of load. Feeding it in would inflate every
        // reading and could trip the 95 °C cutoff early.
        XCTAssertEqual(TemperatureReader.classify("PMU tcal"), .excluded)
        XCTAssertEqual(TemperatureReader.classify("PMU2 tcal"), .excluded)

        let reader = TemperatureReader()
        let onlyCalibration = [
            TemperatureSensor(name: "PMU tcal", celsius: 51.85, tier: .excluded)
        ]
        XCTAssertNil(reader.hottestCPU(from: onlyCalibration))
    }

    func testDeviceSensorsAreNeverTreatedAsCPU() {
        // tdev reads garbage — roughly −21.7 on M1 and −9201 on M4 Pro. The
        // plausible-range filter drops both, but −21.7 is barely outside it, so
        // the exclusion must not depend on the range check.
        XCTAssertEqual(TemperatureReader.classify("PMU tdev3"), .excluded)
        XCTAssertEqual(TemperatureReader.classify("PMU2 tdev1"), .excluded)

        let reader = TemperatureReader()
        // A tdev value that looks perfectly plausible must still be ignored.
        let plausibleGarbage = [
            TemperatureSensor(name: "PMU tdev3", celsius: 42, tier: .excluded)
        ]
        XCTAssertNil(reader.hottestCPU(from: plausibleGarbage))
    }

    func testExcludedSensorsAreStillListedForTheUser() {
        // Excluding them from the failsafe must not hide them from the Sensors
        // view; they are real hardware readings, just not CPU temperature.
        XCTAssertEqual(SensorCategory.classify("PMU tdev3"), .processor)
        XCTAssertEqual(SensorCategory.classify("PMU tcal"), .power)
    }

    func testDieSensorsStillDriveTheFailsafe() {
        // The exclusions must not take the real sensors with them.
        XCTAssertEqual(TemperatureReader.classify("PMU tdie6"), .socDie)
        let reader = TemperatureReader()
        let mixed = [
            TemperatureSensor(name: "PMU tcal", celsius: 51.85, tier: .excluded),
            TemperatureSensor(name: "PMU tdie6", celsius: 44, tier: .socDie),
        ]
        XCTAssertEqual(reader.hottestCPU(from: mixed)?.name, "PMU tdie6")
    }
}
