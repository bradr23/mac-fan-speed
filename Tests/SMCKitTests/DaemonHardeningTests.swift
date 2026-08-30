import XCTest
@testable import SMCKit

/// Covers the fixes from the v0.3.0 security audit that live in the shared
/// layer. The daemon-side pieces are exercised on hardware by
/// scripts/verify-safety.sh; these pin the logic that can be tested off-device.
final class DaemonHardeningTests: XCTestCase {

    private func fan(min: Double, max: Double, limitsReported: Bool = true) -> Fan {
        Fan(
            index: 0, actualRPM: min, minRPM: min, maxRPM: max,
            targetRPM: min, modeRaw: 3, limitsReported: limitsReported
        )
    }

    // MARK: Unknown limits

    /// A missing `F{i}Mn` used to read as 0, which is indistinguishable from a
    /// fan that genuinely reports a floor of zero — and a zero floor is a clamp
    /// that permits stopping the fan outright, on hardware nobody has tested.
    func testAFanWithUnreportedLimitsIsNotDrivable() {
        XCTAssertFalse(fan(min: 0, max: 7826, limitsReported: false).limitsReported)
    }

    func testNormallyReadFansStillReportTheirLimits() {
        XCTAssertTrue(fan(min: 2317, max: 7826).limitsReported)
    }

    /// The flag defaults to true so existing call sites keep their meaning; the
    /// reader is the only thing that should ever set it false.
    func testLimitsAreAssumedReportedWhenConstructedDirectly() {
        let f = Fan(index: 0, actualRPM: 100, minRPM: 1, maxRPM: 2, targetRPM: 1, modeRaw: 3)
        XCTAssertTrue(f.limitsReported)
    }

    // MARK: Shared thermal limits

    /// The daemon must not take a threshold from a client, so it compiles in its
    /// own — and it has to be the ceiling, not the user's setting.
    func testDaemonCeilingIsTheAbsoluteMaximum() {
        XCTAssertEqual(ThermalLimits.daemonTripCelsius, ThermalLimits.maximumTripCelsius)
        XCTAssertEqual(ThermalLimits.maximumTripCelsius,
                       ThermalLimits.assumedCriticalCelsius - 5)
    }

    /// The app's cutoff can only ever be lower, so in normal use the app trips
    /// first and the daemon's limit is never reached.
    func testEverySettableCutoffIsAtOrBelowTheDaemonCeiling() {
        for value in stride(from: ThermalLimits.minimumTripCelsius,
                            through: ThermalLimits.maximumTripCelsius, by: 1) {
            XCTAssertLessThanOrEqual(
                ThermalLimits.clampTrip(value), ThermalLimits.daemonTripCelsius
            )
        }
    }

    func testCutoffCannotBeRaisedPastTheCeiling() {
        for attempt in [96.0, 100, 150, 10_000] {
            XCTAssertEqual(ThermalLimits.clampTrip(attempt), ThermalLimits.maximumTripCelsius)
        }
    }

    /// `min(max(.nan, lo), hi)` is nan in Swift, so a naive clamp would pass a
    /// non-finite threshold straight through into the comparison that decides
    /// whether to hand the fans back — where it would never compare true.
    func testNonFiniteCutoffFallsBackToTheCeiling() {
        XCTAssertEqual(ThermalLimits.clampTrip(.nan), ThermalLimits.maximumTripCelsius)
        XCTAssertEqual(ThermalLimits.clampTrip(.infinity), ThermalLimits.maximumTripCelsius)
        XCTAssertFalse(ThermalLimits.clampTrip(.nan).isNaN)
    }

    func testDaemonResetIsBelowItsTrip() {
        XCTAssertLessThan(ThermalLimits.daemonResetCelsius, ThermalLimits.daemonTripCelsius)
    }

    // MARK: Error formatting

    /// These messages describe values that reached the error path *because* they
    /// were untrustworthy, so formatting them with `Int(...)` — which traps on a
    /// non-finite Double — would crash the root daemon while reporting a fault.
    func testErrorDescriptionsSurviveNonFiniteValues() {
        let messages = [
            FanControlError.implausibleRange(0, .nan, .nan).description,
            FanControlError.implausibleRange(0, -.infinity, .infinity).description,
            FanControlError.invalidTarget(0, .nan).description,
            FanControlError.limitsUnknown(0).description,
        ]
        for message in messages {
            XCTAssertFalse(message.isEmpty)
        }
    }
}

/// Regressions for defects introduced by the security fixes themselves and
/// caught in review. The daemon's state machine is transcribed here because the
/// real one only runs as root; these pin the logic, and
/// scripts/verify-safety.sh exercises the real thing on hardware.
final class DaemonLockoutTests: XCTestCase {

    /// Mirrors FanService's thermal state machine.
    private struct Machine {
        var sensingProven = false
        var thermalLockout = false
        var missed = 0
        let missesBeforeLost = 3

        mutating func startupRead(_ celsius: Double?) {
            if celsius != nil { sensingProven = true }
        }
        /// Returns whether the watch actually started.
        func watchWouldStart() -> Bool { sensingProven }

        mutating func tick(_ celsius: Double?) {
            guard let celsius else {
                missed += 1
                guard missed >= missesBeforeLost else { return }
                sensingProven = false          // degrade, do NOT latch
                return
            }
            missed = 0
            sensingProven = true
            if celsius >= ThermalLimits.daemonTripCelsius { thermalLockout = true }
        }

        mutating func recoveryTick(_ celsius: Double?) {
            guard let celsius else { return }
            if !sensingProven { sensingProven = true; missed = 0 }
            if thermalLockout, celsius < ThermalLimits.daemonResetCelsius {
                thermalLockout = false
            }
        }
        var refusesControl: Bool { thermalLockout }
    }

    /// The bug: the watch was gated on "a HID client exists" but tripped on "a
    /// reading arrived". On a Mac where the first is true and the second never
    /// is, the daemon latched a lockout it could never lift — killing fan
    /// control for the life of the daemon, and blaming heat for it.
    func testAMachineThatNeverReadsTemperaturesDoesNotStartTheWatch() {
        var m = Machine()
        m.startupRead(nil)
        XCTAssertFalse(m.watchWouldStart(), "a watch that can never read must not run")
        XCTAssertFalse(m.refusesControl)
    }

    /// A single failed read must not be treated as a lost sensor: the reader
    /// returns empty if the service copy fails once, on any Mac.
    func testOneMissedReadingIsTolerated() {
        var m = Machine()
        m.startupRead(50)
        m.tick(nil)
        XCTAssertTrue(m.sensingProven)
        XCTAssertFalse(m.refusesControl)
    }

    /// Losing readings degrades the daemon's failsafe; it must never latch,
    /// because the only thing that could lift the latch is the reading that is
    /// missing.
    func testLosingReadingsDegradesButNeverLatches() {
        var m = Machine()
        m.startupRead(50)
        for _ in 0..<10 { m.tick(nil) }
        XCTAssertFalse(m.sensingProven)
        XCTAssertFalse(m.refusesControl, "a lost sensor must not brick fan control")
    }

    func testSensorsComingBackReArmTheFailsafe() {
        var m = Machine()
        m.startupRead(50)
        for _ in 0..<5 { m.tick(nil) }
        XCTAssertFalse(m.sensingProven)
        m.recoveryTick(45)
        XCTAssertTrue(m.sensingProven, "readings returning must restore protection")
    }

    /// Heat is the one thing that does latch, and only cooling lifts it.
    func testHeatLatchesAndOnlyCoolingLiftsIt() {
        var m = Machine()
        m.startupRead(50)
        m.tick(ThermalLimits.daemonTripCelsius + 1)
        XCTAssertTrue(m.refusesControl)

        m.recoveryTick(ThermalLimits.daemonTripCelsius - 1)
        XCTAssertTrue(m.refusesControl, "still above the reset point")

        m.recoveryTick(ThermalLimits.daemonResetCelsius - 1)
        XCTAssertFalse(m.refusesControl, "cooled — control must return")
    }
}
