import XCTest
@testable import MacFanSpeed

/// The failsafe is the thing standing between a low manual fan setting and an
/// overheating machine, and it cannot be tested by actually overheating the
/// developer's Mac. These cover its logic exhaustively instead.
final class FailsafeTests: XCTestCase {

    // MARK: Tripping

    func testTripsAtThreshold() {
        var failsafe = Failsafe()
        let outcome = failsafe.evaluate(celsius: 95, manualControlActive: true)
        XCTAssertEqual(outcome, .trip(.tooHot(95)))
        XCTAssertTrue(failsafe.isTripped)
    }

    func testDoesNotTripJustBelowThreshold() {
        var failsafe = Failsafe()
        XCTAssertEqual(failsafe.evaluate(celsius: 94.9, manualControlActive: true), .noChange)
        XCTAssertFalse(failsafe.isTripped)
    }

    func testLostSensorsTripTheFailsafe() {
        // Holding a manual fan speed with no idea how hot the machine is would be
        // worse than handing control back.
        var failsafe = Failsafe()
        let outcome = failsafe.evaluate(celsius: nil, manualControlActive: true)
        XCTAssertEqual(outcome, .trip(.temperatureUnavailable))
    }

    func testDoesNotTripWhenFansAreAlreadyAutomatic() {
        // macOS is in charge at that point; there is nothing to take back.
        var failsafe = Failsafe()
        XCTAssertEqual(failsafe.evaluate(celsius: 99, manualControlActive: false), .noChange)
        XCTAssertFalse(failsafe.isTripped)
    }

    // MARK: Recovery

    func testStaysTrippedBetweenResetAndTripThresholds() {
        // The hysteresis band exists so a machine sitting at ~90 °C does not
        // flap between manual and automatic every poll.
        var failsafe = Failsafe()
        _ = failsafe.evaluate(celsius: 96, manualControlActive: true)

        for temperature in [94.0, 90.0, 86.0, 85.0] {
            XCTAssertEqual(
                failsafe.evaluate(celsius: temperature, manualControlActive: false),
                .noChange,
                "should still be tripped at \(temperature) °C"
            )
            XCTAssertTrue(failsafe.isTripped)
        }
    }

    func testReleasesBelowResetThreshold() {
        var failsafe = Failsafe()
        _ = failsafe.evaluate(celsius: 96, manualControlActive: true)
        XCTAssertEqual(failsafe.evaluate(celsius: 84.9, manualControlActive: false), .release)
        XCTAssertFalse(failsafe.isTripped)
    }

    func testDoesNotReleaseWhileTemperatureIsUnknown() {
        // Recovering blind would re-enable manual control with no way to notice
        // the machine heating up again.
        var failsafe = Failsafe()
        _ = failsafe.evaluate(celsius: 96, manualControlActive: true)
        XCTAssertEqual(failsafe.evaluate(celsius: nil, manualControlActive: false), .noChange)
        XCTAssertTrue(failsafe.isTripped)
    }

    func testTripsAgainAfterRecoveringAndReheating() {
        var failsafe = Failsafe()
        _ = failsafe.evaluate(celsius: 96, manualControlActive: true)
        XCTAssertEqual(failsafe.evaluate(celsius: 80, manualControlActive: false), .release)
        XCTAssertEqual(
            failsafe.evaluate(celsius: 97, manualControlActive: true),
            .trip(.tooHot(97))
        )
    }

    // MARK: Thresholds

    func testThresholdsMatchTheSpecification() {
        // SPEC.md safety rule 3: mandatory and not user-configurable.
        XCTAssertEqual(Failsafe.tripCelsius, 95)
        XCTAssertEqual(Failsafe.resetCelsius, 85)
        XCTAssertLessThan(Failsafe.resetCelsius, Failsafe.tripCelsius)
    }
}

/// Regression: the failsafe must outrank every route into manual control.
///
/// A deferred startup restore once re-enabled manual while the failsafe was
/// still tripped, and the fans climbed back to full speed on a machine the
/// failsafe had just protected.
@MainActor
final class FailsafeAuthorityTests: XCTestCase {

    func testTrippedFailsafeBlocksManualMode() {
        var failsafe = Failsafe()
        _ = failsafe.evaluate(celsius: 99, manualControlActive: true)
        XCTAssertTrue(failsafe.isTripped)

        // While tripped, any request to hold a manual speed must be refused —
        // including one arriving from the startup restore rather than the user.
        XCTAssertEqual(failsafe.evaluate(celsius: 99, manualControlActive: false), .noChange)
        XCTAssertTrue(failsafe.isTripped, "must stay tripped until genuinely cool")
    }

    func testOnlyCoolingReleasesIt() {
        var failsafe = Failsafe()
        _ = failsafe.evaluate(celsius: 99, manualControlActive: true)
        for temperature in [98.0, 90.0, 86.0] {
            XCTAssertNotEqual(
                failsafe.evaluate(celsius: temperature, manualControlActive: false), .release
            )
        }
        XCTAssertEqual(failsafe.evaluate(celsius: 84, manualControlActive: false), .release)
    }
}
