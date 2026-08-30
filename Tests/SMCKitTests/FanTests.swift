import XCTest
@testable import SMCKit

/// Fan range maths and the fanless-Mac path. Presets are stored as percentages
/// precisely so they behave sensibly on hardware with different RPM ranges, so
/// the conversion is worth pinning down.
final class FanTests: XCTestCase {

    private func fan(min: Double, max: Double) -> Fan {
        Fan(index: 0, actualRPM: min, minRPM: min, maxRPM: max, targetRPM: min, modeRaw: 3)
    }

    func testPercentResolvesAcrossTheFansOwnRange() {
        let f = fan(min: 2000, max: 6000)
        XCTAssertEqual(f.rpm(forPercent: 0), 2000)
        XCTAssertEqual(f.rpm(forPercent: 1), 6000)
        XCTAssertEqual(f.rpm(forPercent: 0.5), 4000)
    }

    func testSamePercentGivesDifferentRPMOnDifferentHardware() {
        // The whole point of percentage presets: "35 %" means something sane on
        // both a narrow-range and a wide-range fan.
        XCTAssertEqual(fan(min: 2317, max: 7826).rpm(forPercent: 0.35), 4245)
        XCTAssertEqual(fan(min: 1200, max: 3000).rpm(forPercent: 0.35), 1830)
    }

    func testPercentIsClampedToTheValidRange() {
        let f = fan(min: 2000, max: 6000)
        XCTAssertEqual(f.rpm(forPercent: 5.0), 6000)
        XCTAssertEqual(f.rpm(forPercent: -3.0), 2000)
    }

    func testPercentForRPMIsTheInverse() {
        let f = fan(min: 2000, max: 6000)
        XCTAssertEqual(f.percent(forRPM: 4000), 0.5, accuracy: 0.0001)
        XCTAssertEqual(f.percent(forRPM: 2000), 0.0, accuracy: 0.0001)
        XCTAssertEqual(f.percent(forRPM: 6000), 1.0, accuracy: 0.0001)
    }

    func testDegenerateRangeDoesNotDivideByZero() {
        // A fan reporting min == max would otherwise produce NaN and poison the UI.
        let f = fan(min: 3000, max: 3000)
        XCTAssertEqual(f.percent(forRPM: 3000), 0)
        XCTAssertFalse(f.rpm(forPercent: 0.5).isNaN)
    }

    func testRPMOutsideRangeStillClampsToZeroOne() {
        let f = fan(min: 2000, max: 6000)
        XCTAssertEqual(f.percent(forRPM: 9000), 1.0, accuracy: 0.0001)
        XCTAssertEqual(f.percent(forRPM: 0), 0.0, accuracy: 0.0001)
    }

    // MARK: Fanless Macs

    func testFanlessMacIsASupportedState() {
        // MacBook Airs report FNum == 0. Monitoring must still work.
        let snapshot = SystemSnapshot(
            fans: [],
            cpuTemperature: TemperatureSensor(name: "PMU tdie1", celsius: 45, tier: .socDie),
            sensors: []
        )
        XCTAssertFalse(snapshot.hasFans)
        XCTAssertNil(snapshot.averageRPM)
        XCTAssertEqual(snapshot.cpuTemperature?.celsius, 45)
    }

    func testAverageRPMAcrossMultipleFans() {
        let snapshot = SystemSnapshot(
            fans: [
                Fan(index: 0, actualRPM: 2000, minRPM: 1000, maxRPM: 5000, targetRPM: 2000, modeRaw: 3),
                Fan(index: 1, actualRPM: 3000, minRPM: 1000, maxRPM: 5000, targetRPM: 3000, modeRaw: 3),
            ],
            cpuTemperature: nil,
            sensors: []
        )
        XCTAssertEqual(snapshot.averageRPM, 2500)
        XCTAssertTrue(snapshot.hasFans)
    }
}
