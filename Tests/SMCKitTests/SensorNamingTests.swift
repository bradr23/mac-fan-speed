import XCTest
@testable import SMCKit

/// Readable sensor names.
///
/// The governing rule is rename, never invent. A name is only translated when
/// the hardware's own name says what the sensor measures; anything else keeps
/// the name it came with. These tests exist mainly to stop a future "nicer"
/// label from asserting something the hardware never said.
final class SensorNamingTests: XCTestCase {

    func testNamedFamiliesAreTranslated() {
        XCTAssertEqual(SensorNaming.friendlyName(for: "pACC MTR Temp Sensor0"),
                       "Performance cores 0")
        XCTAssertEqual(SensorNaming.friendlyName(for: "eACC MTR Temp Sensor2"),
                       "Efficiency cores 2")
        XCTAssertEqual(SensorNaming.friendlyName(for: "GPU MTR Temp Sensor1"), "Graphics 1")
        XCTAssertEqual(SensorNaming.friendlyName(for: "ANE MTR Temp Sensor0"),
                       "Neural Engine 0")
        XCTAssertEqual(SensorNaming.friendlyName(for: "ISP MTR Temp Sensor0"),
                       "Image processor 0")
    }

    func testGenericDieSensorsClaimOnlyWhatIsKnown() {
        // This Mac reports 14 die sensors and has 12 CPU cores, so there is no
        // per-core mapping to be had. "Processor die 1" is the whole of what the
        // hardware tells us; "CPU core 1" would be a guess presented as fact.
        XCTAssertEqual(SensorNaming.friendlyName(for: "PMU tdie1"), "Processor die 1")
        XCTAssertEqual(SensorNaming.friendlyName(for: "PMU tdev3"), "Processor sensor 3")
        // PMU2 is a second power controller on single-die machines, not a
        // second package — this assertion previously encoded that mistake.
        XCTAssertEqual(SensorNaming.friendlyName(for: "PMU2 tdie5"),
                       "Die sensor 5 (second controller)")
    }

    func testPeripheralsAndPower() {
        XCTAssertEqual(SensorNaming.friendlyName(for: "gas gauge battery"), "Battery")
        XCTAssertEqual(SensorNaming.friendlyName(for: "PMU tcal"), "Calibration reference")
    }

    func testIndexIsFoundEvenWhenItIsNotAtTheEnd() {
        // "NAND CH0 temp" carries its index in the middle. Searching only the end
        // produced "Storage — NAND channel" with the number missing entirely.
        XCTAssertEqual(SensorNaming.friendlyName(for: "NAND CH0 temp"),
                       "Storage — NAND channel 0")
        XCTAssertEqual(SensorNaming.friendlyName(for: "NAND CH1 temp"),
                       "Storage — NAND channel 1")
    }

    func testUnrecognisedNamesAreLeftAlone() {
        // On hardware nobody has catalogued, an ugly true name beats a pretty
        // wrong one.
        XCTAssertNil(SensorNaming.friendlyName(for: "XYZ Future Sensor"))

        let sensor = TemperatureSensor(
            name: "XYZ Future Sensor", celsius: 40, tier: .unclassified
        )
        let named = SensorNaming.name(for: sensor)
        XCTAssertTrue(named.isVerbatim)
        XCTAssertEqual(named.display, "XYZ Future Sensor")
    }

    func testRawNameAndKeyAreKeptForTraceability() {
        let sensor = TemperatureSensor(
            name: "PMU tdie6", celsius: 39, tier: .socDie, smcKey: "TP6b"
        )
        let named = SensorNaming.name(for: sensor)
        XCTAssertEqual(named.display, "Processor die 6")
        XCTAssertEqual(named.raw, "PMU tdie6")
        XCTAssertEqual(named.smcKey, "TP6b")
        XCTAssertFalse(named.isVerbatim)
    }
}

/// Grouping identity. Display names are not unique — a Mac reports four
/// different battery sensors all called "gas gauge battery" — so the SMC key is
/// what identifies a physical sensor.
final class SensorGroupingIdentityTests: XCTestCase {

    func testSameKeyReportedTwiceIsOneSensor() {
        // PMU tdie1 arrives from three services, all keyed TP1b. That is one
        // sensor seen three times.
        let raw = (0..<3).map { i in
            TemperatureSensor(
                name: "PMU tdie1", celsius: 37 + Double(i), tier: .socDie, smcKey: "TP1b"
            )
        }
        let grouped = SensorReading.group(raw)
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].sourceCount, 3)
        XCTAssertEqual(grouped[0].celsius, 39)
    }

    func testSameNameDifferentKeysAreDifferentSensors() {
        // Four distinct battery sensors share one display name. Grouping by name
        // merged them and silently hid three readings.
        let raw = ["TG0B", "TG1B", "TG2B", "TG0H"].map { key in
            TemperatureSensor(
                name: "gas gauge battery", celsius: 30, tier: .excluded, smcKey: key
            )
        }
        let grouped = SensorReading.group(raw)
        XCTAssertEqual(grouped.count, 4, "four keys means four sensors")
        XCTAssertEqual(Set(grouped.compactMap(\.smcKey)).count, 4)
    }

    func testSensorsWithoutKeysStillGroupByName() {
        // If the key is unavailable the name is the only identity available.
        let raw = [
            TemperatureSensor(name: "Mystery", celsius: 30, tier: .unclassified),
            TemperatureSensor(name: "Mystery", celsius: 34, tier: .unclassified),
        ]
        let grouped = SensorReading.group(raw)
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].celsius, 34)
    }
}
