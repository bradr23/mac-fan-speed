import XCTest
@testable import SMCKit

/// Full sensor inventories from real dumps, one per model.
///
/// Each case asserts the whole set behaves: every sensor gets a category, the
/// failsafe picks a genuine die sensor, and neither the calibration constant nor
/// the garbage-reading device sensors can win. Testing complete inventories
/// rather than individual strings is what catches a rule that works in isolation
/// and breaks in company.
final class KnownModelCoverageTests: XCTestCase {

    /// Build a plausible inventory: die sensors warm, tcal at its constant 51.85,
    /// tdev at the garbage values these machines actually report.
    private func inventory(_ names: [String]) -> [TemperatureSensor] {
        names.map { name in
            let lower = name.lowercased()
            let celsius: Double
            if lower.contains("tcal") {
                celsius = 51.85                     // constant on every machine
            } else if lower.contains("tdev") {
                celsius = -21.7                     // garbage, as seen on M1
            } else if lower.contains("battery") {
                celsius = 30
            } else if lower.contains("nand") {
                celsius = 33
            } else {
                celsius = 45
            }
            return TemperatureSensor(
                name: name,
                celsius: celsius,
                tier: TemperatureReader.classify(name),
                smcKey: nil
            )
        }
    }

    private func assertHealthy(
        _ names: [String],
        expectedTier: SensorTier,
        model: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let sensors = inventory(names)
        let reader = TemperatureReader()

        guard let hottest = reader.hottestCPU(from: sensors) else {
            return XCTFail("\(model): no CPU sensor identified", file: file, line: line)
        }
        // Assert the tier rather than a specific sensor: within a tier the
        // hottest wins, and which sensor that is depends on the moment.
        XCTAssertEqual(hottest.tier, expectedTier, model, file: file, line: line)

        // Neither non-measurement family may ever be chosen.
        XCTAssertFalse(hottest.name.lowercased().contains("tcal"),
                       "\(model): calibration constant used as CPU", file: file, line: line)
        XCTAssertFalse(hottest.name.lowercased().contains("tdev"),
                       "\(model): garbage sensor used as CPU", file: file, line: line)

        // Everything is listed somewhere, and nothing lands in Other.
        let sections = SensorReading.byCategory(sensors)
        XCTAssertEqual(sections.flatMap(\.readings).count, Set(names).count,
                       "\(model): sensors lost while grouping", file: file, line: line)
        XCTAssertFalse(sections.contains { $0.category == .other },
                       "\(model): sensor fell into Other", file: file, line: line)
    }

    // MARK: Inventories

    func testM1() {
        // M1 exposes the named MTR families alongside PMU sensors. Indices are
        // neither contiguous nor zero-based: pACC runs 2,3,4,5,7,8,9.
        assertHealthy(
            ["ANE MTR Temp Sensor1", "GPU MTR Temp Sensor1", "GPU MTR Temp Sensor4",
             "ISP MTR Temp Sensor5", "NAND CH0 temp",
             "PMGR SOC Die Temp Sensor0", "PMGR SOC Die Temp Sensor1",
             "PMU TP3w", "PMU tcal", "PMU tdev1", "PMU tdev8",
             "PMU tdie1", "PMU tdie8", "SOC MTR Temp Sensor0",
             "eACC MTR Temp Sensor0", "pACC MTR Temp Sensor2",
             "pACC MTR Temp Sensor9", "gas gauge battery"],
            // A named core-cluster sensor outranks everything else present,
            // including the Neural Engine and the generic die sensors.
            expectedTier: .coreCluster,
            model: "M1"
        )
    }

    func testM1ProAndM1Max() {
        // Identical sets. The MTR families are gone; tdie starts at 0.
        assertHealthy(
            ["gas gauge battery", "NAND CH0 temp", "PMU tcal",
             "PMU tdev1", "PMU tdev8", "PMU tdie0", "PMU tdie10",
             "PMU TP0s", "PMU TP1g", "PMU TP1s", "PMU TP2g", "PMU TP2s", "PMU TP3g"],
            expectedTier: .socDie,
            model: "M1 Pro / M1 Max"
        )
    }

    func testM2ProHasNoBattery() {
        // Desktop and some laptop configurations omit the battery sensor
        // entirely, with nothing replacing it.
        assertHealthy(
            ["NAND CH0 temp", "PMU TP0s", "PMU TP1g", "PMU tcal",
             "PMU tdev1", "PMU tdie0", "PMU tdie10"],
            expectedTier: .socDie,
            model: "M2 Pro"
        )
    }

    func testM3MaxAndM4Max() {
        // No PMU TP*, no tdie0, no PMU2 — the leanest inventory of the lot.
        assertHealthy(
            ["NAND CH0 temp", "PMU tcal", "PMU tdev1", "PMU tdev8",
             "PMU tdie1", "PMU tdie10", "gas gauge battery"],
            expectedTier: .socDie,
            model: "M3 Max / M4 Max"
        )
    }

    func testBaseM4WithSecondPowerController() {
        // PMU2 is a second controller on single-die machines. Both its naming
        // eras must classify the same, since the same silicon is renamed across
        // macOS versions rather than across chips.
        assertHealthy(
            ["NAND CH0 temp", "PMU tcal", "PMU tdev1", "PMU tdie1", "PMU tdie14",
             "PMU2 tcal", "PMU2 tdev1", "PMU2 tdie1", "PMU2 tdie10"],
            expectedTier: .socDie,
            model: "base M4"
        )

        assertHealthy(
            ["NAND CH0 temp", "PMU tcal", "PMU tdie1",
             "PMU2 TR0Z", "PMU2 TR1d", "PMU2 TR8b"],
            expectedTier: .socDie,
            model: "M1 on macOS 12 (PMU2 TR* era)"
        )
    }

    func testUltraChipsHaveNoSecondController() {
        assertHealthy(
            ["NAND CH0 temp", "PMU TP0s", "PMU TP1g", "PMU tcal",
             "PMU tdev1", "PMU tdie0", "PMU tdie10"],
            expectedTier: .socDie,
            model: "M2 Ultra / M3 Ultra"
        )
    }

    func testThisDevelopmentMachine() {
        assertHealthy(
            ["NAND CH0 temp", "PMU tcal", "PMU tdie1", "PMU tdie14",
             "gas gauge battery"],
            expectedTier: .socDie,
            model: "M4 Pro (Mac16,8)"
        )
    }
}
