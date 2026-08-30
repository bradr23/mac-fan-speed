import XCTest
@testable import SMCKit

/// These tests cover the logic that has to be right on hardware the developer
/// cannot test. They use synthetic sensor data deliberately — nothing here
/// touches the SMC, so they pass on any machine including CI.
final class SensorClassificationTests: XCTestCase {

    // MARK: Classification

    func testCoreClusterSensorsAreTierOne() {
        // Documented M1–M3 layout.
        XCTAssertEqual(TemperatureReader.classify("pACC MTR Temp Sensor0"), .coreCluster)
        XCTAssertEqual(TemperatureReader.classify("eACC MTR Temp Sensor3"), .coreCluster)
    }

    func testDieSensorsAreTierTwo() {
        // Real names observed on Mac16,8 (M4 Pro), which exposes no ACC sensors.
        XCTAssertEqual(TemperatureReader.classify("PMU tdie8"), .socDie)
        XCTAssertEqual(TemperatureReader.classify("PMU tdie14"), .socDie)
        XCTAssertEqual(TemperatureReader.classify("SOC MTR Temp Sensor0"), .socDie)
    }

    func testCalibrationSensorIsExcluded() {
        // PMU tcal reads roughly 15 °C above the die sensors on an idle M4 Pro.
        // Treating it as a CPU sensor would inflate every reading and could trip
        // the 95 °C failsafe early.
        XCTAssertEqual(TemperatureReader.classify("PMU tcal"), .excluded)
    }

    func testNonCPUSensorsAreExcluded() {
        XCTAssertEqual(TemperatureReader.classify("gas gauge battery"), .excluded)
        XCTAssertEqual(TemperatureReader.classify("NAND CH0 temp"), .excluded)
        XCTAssertEqual(TemperatureReader.classify("ambient light"), .excluded)
    }

    func testUnknownSensorsAreUnclassifiedNotExcluded() {
        // Unfamiliar hardware should still produce a reading rather than nothing.
        XCTAssertEqual(TemperatureReader.classify("XYZ Future Sensor"), .unclassified)
    }

    func testClassificationIsCaseInsensitive() {
        XCTAssertEqual(TemperatureReader.classify("pmu TDIE3"), .socDie)
        XCTAssertEqual(TemperatureReader.classify("GAS GAUGE BATTERY"), .excluded)
    }

    // MARK: Tier preference

    func testMoreSpecificTierWinsEvenWhenCooler() {
        // A core-cluster sensor must be preferred over a hotter die sensor:
        // tier order encodes confidence, not temperature.
        let reader = TemperatureReader()
        let sensors = [
            TemperatureSensor(name: "pACC MTR Temp Sensor0", celsius: 50, tier: .coreCluster),
            TemperatureSensor(name: "PMU tdie8", celsius: 80, tier: .socDie),
        ]
        XCTAssertEqual(reader.hottestCPU(from: sensors)?.name, "pACC MTR Temp Sensor0")
    }

    func testFallsBackThroughTiers() {
        let reader = TemperatureReader()
        let dieOnly = [
            TemperatureSensor(name: "PMU tdie1", celsius: 40, tier: .socDie),
            TemperatureSensor(name: "PMU tdie2", celsius: 45, tier: .socDie),
        ]
        XCTAssertEqual(reader.hottestCPU(from: dieOnly)?.celsius, 45)
    }

    func testExcludedSensorsNeverBecomeTheCPUReading() {
        // Even with nothing else available, a battery sensor must not be
        // reported as CPU temperature — the app reports "unknown" instead.
        let reader = TemperatureReader()
        let batteryOnly = [
            TemperatureSensor(name: "gas gauge battery", celsius: 30, tier: .excluded)
        ]
        XCTAssertNil(reader.hottestCPU(from: batteryOnly))
    }

    func testNoSensorsYieldsNil() {
        XCTAssertNil(TemperatureReader().hottestCPU(from: []))
    }
}

/// Sensor naming differs sharply between chip generations, and the developer has
/// hardware from exactly one of them. These pin down names reported for the
/// others so a change cannot silently break them.
final class SensorNamingAcrossChipsTests: XCTestCase {

    func testM1AndM2NamedSensors() {
        XCTAssertEqual(TemperatureReader.classify("pACC MTR Temp Sensor0"), .coreCluster)
        XCTAssertEqual(TemperatureReader.classify("eACC MTR Temp Sensor3"), .coreCluster)
        XCTAssertEqual(TemperatureReader.classify("SOC MTR Temp Sensor0"), .socDie)
        // M1 exposes a whole-SoC die sensor under a different name again.
        XCTAssertEqual(TemperatureReader.classify("PMGR SOC Die Temp Sensor1"), .socDie)
    }

    func testM4AndLaterGenericDieSensors() {
        XCTAssertEqual(TemperatureReader.classify("PMU tdie8"), .socDie)
        // Machines with a second power controller expose PMU2 sensors; matching
        // on "PMU tdie" alone would miss every one of these.
        XCTAssertEqual(TemperatureReader.classify("PMU2 tdie5"), .socDie)

        // tdev is deliberately NOT a CPU sensor: it reads garbage on every
        // machine observed. These assertions previously required the opposite.
        XCTAssertEqual(TemperatureReader.classify("PMU tdev3"), .excluded)
        XCTAssertEqual(TemperatureReader.classify("PMU2 tdev2"), .excluded)
    }

    func testCalibrationSensorsExcludedOnBothDies() {
        // Reads roughly 15 °C above the real die sensors; including it would
        // inflate every reading and could trip the failsafe early.
        XCTAssertEqual(TemperatureReader.classify("PMU tcal"), .excluded)
        XCTAssertEqual(TemperatureReader.classify("PMU2 tcal"), .excluded)
    }

    func testNamedSensorsWinOverGenericOnesWhenBothExist() {
        // M2 reports both families at once. The named per-core sensors are the
        // more specific signal and must be preferred even if cooler.
        let reader = TemperatureReader()
        let mixed = [
            TemperatureSensor(name: "pACC MTR Temp Sensor8", celsius: 51, tier: .coreCluster),
            TemperatureSensor(name: "PMU tdie5", celsius: 74, tier: .socDie),
        ]
        XCTAssertEqual(reader.hottestCPU(from: mixed)?.name, "pACC MTR Temp Sensor8")
    }
}

/// Grouping for the Sensors view. Names here come from other Apple Silicon
/// models, since the development machine exposes only die, storage and battery
/// sensors — the categories most likely to be wrong are the ones that cannot be
/// seen locally.
final class SensorCategoryTests: XCTestCase {

    func testProcessorSensorsAcrossNamingSchemes() {
        XCTAssertEqual(SensorCategory.classify("pACC MTR Temp Sensor0"), .processor)
        XCTAssertEqual(SensorCategory.classify("eACC MTR Temp Sensor2"), .processor)
        XCTAssertEqual(SensorCategory.classify("SOC MTR Temp Sensor0"), .processor)
        XCTAssertEqual(SensorCategory.classify("PMGR SOC Die Temp Sensor1"), .processor)
        XCTAssertEqual(SensorCategory.classify("PMU tdie8"), .processor)
        XCTAssertEqual(SensorCategory.classify("PMU2 tdev3"), .processor)
    }

    func testGraphicsWinsOverTheProcessorFamily() {
        // "GPU MTR Temp Sensor0" also contains the processor family's "mtr", so
        // the specific groups have to be checked first.
        XCTAssertEqual(SensorCategory.classify("GPU MTR Temp Sensor0"), .graphics)
    }

    func testAcceleratorsAndPeripherals() {
        XCTAssertEqual(SensorCategory.classify("ANE MTR Temp Sensor1"), .neuralEngine)
        XCTAssertEqual(SensorCategory.classify("ISP MTR Temp Sensor0"), .imageProcessor)
        XCTAssertEqual(SensorCategory.classify("NAND CH0 temp"), .storage)
        XCTAssertEqual(SensorCategory.classify("gas gauge battery"), .battery)
        XCTAssertEqual(SensorCategory.classify("PMU tcal"), .power)
    }

    func testUnknownSensorsAreShownRatherThanHidden() {
        // Hardware nobody has catalogued should still list its readings.
        XCTAssertEqual(SensorCategory.classify("XYZ Future Sensor"), .other)
    }

    // MARK: Grouping

    func testRepeatedNamesCollapseToTheHottestReading() {
        // Macs report the same sensor from several services; the list should show
        // one row, not three, and the hottest value of the set.
        let raw = [
            TemperatureSensor(name: "PMU tdie1", celsius: 37.0, tier: .socDie),
            TemperatureSensor(name: "PMU tdie1", celsius: 38.5, tier: .socDie),
            TemperatureSensor(name: "PMU tdie1", celsius: 37.4, tier: .socDie),
        ]
        let grouped = SensorReading.group(raw)
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].celsius, 38.5)
        XCTAssertEqual(grouped[0].sourceCount, 3)
    }

    func testEmptyCategoriesAreOmitted() {
        let raw = [TemperatureSensor(name: "NAND CH0 temp", celsius: 34, tier: .excluded)]
        let sections = SensorReading.byCategory(raw)
        XCTAssertEqual(sections.map(\.category), [.storage])
    }

    func testCategoriesComeBackInAStableOrder() {
        // Processor first, other last, so the list does not reshuffle as
        // temperatures change.
        let raw = [
            TemperatureSensor(name: "gas gauge battery", celsius: 30, tier: .excluded),
            TemperatureSensor(name: "PMU tdie1", celsius: 40, tier: .socDie),
            TemperatureSensor(name: "Mystery Sensor", celsius: 20, tier: .unclassified),
        ]
        XCTAssertEqual(SensorReading.byCategory(raw).map(\.category),
                       [.processor, .battery, .other])
    }
}
