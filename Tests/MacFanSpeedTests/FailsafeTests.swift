import XCTest
@testable import MacFanSpeed

/// The failsafe is the thing standing between a low manual fan setting and an
/// overheating machine, and it cannot be tested by actually overheating the
/// developer's Mac. These cover its logic exhaustively instead.
final class FailsafeTests: XCTestCase {

    /// Only the field under test needs naming at each call site.
    private func input(
        cpu: Double? = 40,
        battery: Double? = nil,
        storage: Double? = nil,
        thermalState: ProcessInfo.ThermalState = .nominal,
        age: TimeInterval = 0,
        now: Date = Date(timeIntervalSince1970: 1_000_000),
        manual: Bool = true
    ) -> FailsafeInput {
        FailsafeInput(
            cpuCelsius: cpu,
            hottestBatteryCelsius: battery,
            hottestStorageCelsius: storage,
            thermalState: thermalState,
            readingAge: age,
            now: now,
            manualControlActive: manual
        )
    }

    // MARK: Tripping on CPU temperature

    func testTripsAtThreshold() {
        var failsafe = Failsafe()
        XCTAssertEqual(failsafe.evaluate(input(cpu: 95)), .trip(.tooHot(95)))
        XCTAssertTrue(failsafe.isTripped)
    }

    func testDoesNotTripJustBelowThreshold() {
        var failsafe = Failsafe()
        XCTAssertEqual(failsafe.evaluate(input(cpu: 94.9)), .noChange)
        XCTAssertFalse(failsafe.isTripped)
    }

    func testTripsAtTheUsersLowerThreshold() {
        var failsafe = Failsafe(tripCelsius: 80)
        XCTAssertEqual(failsafe.evaluate(input(cpu: 80)), .trip(.tooHot(80)))
    }

    func testLostSensorsTripTheFailsafe() {
        // Holding a manual fan speed with no idea how hot the machine is would be
        // worse than handing control back.
        var failsafe = Failsafe()
        XCTAssertEqual(failsafe.evaluate(input(cpu: nil)), .trip(.temperatureUnavailable))
    }

    func testNonFiniteReadingCountsAsLost() {
        var failsafe = Failsafe()
        XCTAssertEqual(failsafe.evaluate(input(cpu: .nan)), .trip(.temperatureUnavailable))
    }

    func testDoesNotTripWhenFansAreAlreadyAutomatic() {
        // macOS is in charge at that point; there is nothing to take back.
        var failsafe = Failsafe()
        XCTAssertEqual(failsafe.evaluate(input(cpu: 99, manual: false)), .noChange)
        XCTAssertFalse(failsafe.isTripped)
    }

    // MARK: Supplementary trips

    /// A control loop that stops while the UI keeps showing its last comfortable
    /// reading is a documented failure mode in this class of app: the machine
    /// throttles behind a stale number.
    func testStaleReadingsTrip() {
        var failsafe = Failsafe()
        let outcome = failsafe.evaluate(input(cpu: 50, age: Failsafe.staleReadingSeconds + 1))
        guard case .trip(.readingsStale) = outcome else {
            return XCTFail("expected a stale-readings trip, got \(outcome)")
        }
    }

    func testFreshReadingsDoNotTrip() {
        var failsafe = Failsafe()
        XCTAssertEqual(failsafe.evaluate(input(cpu: 50, age: 2)), .noChange)
    }

    /// Nothing watched the battery before: it is excluded from the CPU figure,
    /// correctly, but that meant a pinned-fan laptop could cook the cell while
    /// the die sat comfortably below the cutoff.
    func testHotBatteryTrips() {
        var failsafe = Failsafe()
        let outcome = failsafe.evaluate(input(cpu: 60, battery: Failsafe.batteryTripCelsius))
        XCTAssertEqual(outcome, .trip(.batteryTooHot(Failsafe.batteryTripCelsius)))
    }

    func testNormalBatteryTemperatureDoesNotTrip() {
        var failsafe = Failsafe()
        XCTAssertEqual(failsafe.evaluate(input(cpu: 60, battery: 42)), .noChange)
    }

    func testHotStorageTrips() {
        var failsafe = Failsafe()
        let outcome = failsafe.evaluate(input(cpu: 60, storage: Failsafe.storageTripCelsius))
        XCTAssertEqual(outcome, .trip(.storageTooHot(Failsafe.storageTripCelsius)))
    }

    func testSystemThermalPressureTrips() {
        var failsafe = Failsafe()
        XCTAssertEqual(
            failsafe.evaluate(input(cpu: 60, thermalState: .serious)),
            .trip(.systemThermalPressure)
        )
    }

    /// `.nominal` is what macOS reports when it does not know, so it can never
    /// be read as evidence that anything is fine.
    func testNominalThermalStateIsNotTreatedAsSafety() {
        XCTAssertFalse(Failsafe.isPressured(.nominal))
        XCTAssertFalse(Failsafe.isPressured(.fair))
        XCTAssertTrue(Failsafe.isPressured(.serious))
        XCTAssertTrue(Failsafe.isPressured(.critical))

        // Nominal alongside a genuinely hot CPU must still trip on temperature.
        var failsafe = Failsafe()
        XCTAssertEqual(
            failsafe.evaluate(input(cpu: 96, thermalState: .nominal)), .trip(.tooHot(96))
        )
    }

    /// A machine parked just under the cutoff forever never crosses it, but
    /// thermal damage is cumulative.
    func testSustainedHeatTripsEvenBelowTheCutoff() {
        var failsafe = Failsafe()
        let start = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertEqual(failsafe.evaluate(input(cpu: 88, now: start)), .noChange)
        XCTAssertEqual(
            failsafe.evaluate(input(cpu: 88, now: start.addingTimeInterval(60))), .noChange
        )

        let later = start.addingTimeInterval(Failsafe.sustainedDuration + 1)
        let outcome = failsafe.evaluate(input(cpu: 88, now: later))
        guard case .trip(.sustainedHeat) = outcome else {
            return XCTFail("expected a sustained-heat trip, got \(outcome)")
        }
    }

    func testDroppingOutOfTheHeatBandClearsTheDwellTimer() {
        var failsafe = Failsafe()
        let start = Date(timeIntervalSince1970: 1_000_000)
        _ = failsafe.evaluate(input(cpu: 88, now: start))
        // Cooled off; the clock restarts.
        _ = failsafe.evaluate(input(cpu: 70, now: start.addingTimeInterval(60)))
        let later = start.addingTimeInterval(Failsafe.sustainedDuration + 1)
        XCTAssertEqual(failsafe.evaluate(input(cpu: 88, now: later)), .noChange)
    }

    // MARK: Recovery

    func testStaysTrippedBetweenResetAndTripThresholds() {
        // The hysteresis band exists so a machine sitting at ~90 °C does not
        // flap between manual and automatic every poll.
        var failsafe = Failsafe()
        _ = failsafe.evaluate(input(cpu: 96))

        for temperature in [94.0, 90.0, 86.0, 85.0] {
            XCTAssertEqual(
                failsafe.evaluate(input(cpu: temperature, manual: false)), .noChange,
                "should still be tripped at \(temperature) °C"
            )
            XCTAssertTrue(failsafe.isTripped)
        }
    }

    func testReleasesBelowResetThreshold() {
        var failsafe = Failsafe()
        _ = failsafe.evaluate(input(cpu: 96))
        XCTAssertEqual(failsafe.evaluate(input(cpu: 84.9, manual: false)), .release)
        XCTAssertFalse(failsafe.isTripped)
    }

    func testDoesNotReleaseWhileTemperatureIsUnknown() {
        // Recovering blind would re-enable manual control with no way to notice
        // the machine heating up again.
        var failsafe = Failsafe()
        _ = failsafe.evaluate(input(cpu: 96))
        XCTAssertEqual(failsafe.evaluate(input(cpu: nil, manual: false)), .noChange)
        XCTAssertTrue(failsafe.isTripped)
    }

    func testDoesNotReleaseWhileReadingsAreStale() {
        var failsafe = Failsafe()
        _ = failsafe.evaluate(input(cpu: 96))
        XCTAssertEqual(
            failsafe.evaluate(input(cpu: 50, age: 30, manual: false)), .noChange
        )
    }

    func testDoesNotReleaseWhileTheBatteryIsStillHot() {
        var failsafe = Failsafe()
        _ = failsafe.evaluate(input(cpu: 60, battery: 60))
        XCTAssertEqual(
            failsafe.evaluate(input(cpu: 50, battery: 52, manual: false)), .noChange
        )
        XCTAssertEqual(
            failsafe.evaluate(input(cpu: 50, battery: 40, manual: false)), .release
        )
    }

    func testDoesNotReleaseWhileMacOSStillReportsPressure() {
        var failsafe = Failsafe()
        _ = failsafe.evaluate(input(cpu: 60, thermalState: .serious))
        XCTAssertEqual(
            failsafe.evaluate(input(cpu: 50, thermalState: .serious, manual: false)),
            .noChange
        )
        XCTAssertEqual(
            failsafe.evaluate(input(cpu: 50, thermalState: .nominal, manual: false)),
            .release
        )
    }

    func testTripsAgainAfterRecoveringAndReheating() {
        var failsafe = Failsafe()
        _ = failsafe.evaluate(input(cpu: 96))
        XCTAssertEqual(failsafe.evaluate(input(cpu: 80, manual: false)), .release)
        XCTAssertEqual(failsafe.evaluate(input(cpu: 97)), .trip(.tooHot(97)))
    }

    // MARK: Thresholds

    func testDefaultThresholdsMatchTheSpecification() {
        let failsafe = Failsafe()
        XCTAssertEqual(failsafe.tripCelsius, 95)
        XCTAssertEqual(failsafe.resetCelsius, 85)
        XCTAssertLessThan(failsafe.resetCelsius, failsafe.tripCelsius)
    }
}

/// Regression: the failsafe must outrank every route into manual control.
///
/// A deferred startup restore once re-enabled manual while the failsafe was
/// still tripped, and the fans climbed back to full speed on a machine the
/// failsafe had just protected.
@MainActor
final class FailsafeAuthorityTests: XCTestCase {

    private func input(cpu: Double?, manual: Bool) -> FailsafeInput {
        FailsafeInput(cpuCelsius: cpu, manualControlActive: manual)
    }

    func testTrippedFailsafeBlocksManualMode() {
        var failsafe = Failsafe()
        _ = failsafe.evaluate(input(cpu: 99, manual: true))
        XCTAssertTrue(failsafe.isTripped)

        // While tripped, any request to hold a manual speed must be refused —
        // including one arriving from the startup restore rather than the user.
        XCTAssertEqual(failsafe.evaluate(input(cpu: 99, manual: false)), .noChange)
        XCTAssertTrue(failsafe.isTripped, "must stay tripped until genuinely cool")
    }

    func testOnlyCoolingReleasesIt() {
        var failsafe = Failsafe()
        _ = failsafe.evaluate(input(cpu: 99, manual: true))
        for temperature in [98.0, 90.0, 86.0] {
            XCTAssertNotEqual(failsafe.evaluate(input(cpu: temperature, manual: false)), .release)
        }
        XCTAssertEqual(failsafe.evaluate(input(cpu: 84, manual: false)), .release)
    }
}
