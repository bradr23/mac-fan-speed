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
        // Non-emptiness asserted first: a stride whose upper bound is below its
        // lower bound walks nothing, and a loop that never runs asserts nothing.
        XCTAssertGreaterThan(
            ThermalLimits.maximumTripCelsius, ThermalLimits.minimumTripCelsius
        )

        var checked = 0
        for value in stride(from: ThermalLimits.minimumTripCelsius,
                            through: ThermalLimits.maximumTripCelsius, by: 1) {
            XCTAssertLessThanOrEqual(
                ThermalLimits.clampTrip(value), ThermalLimits.daemonTripCelsius
            )
            checked += 1
        }
        XCTAssertGreaterThan(checked, 1, "the settable range walked no values")
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

/// Fixes from the v0.4.1 full audit that live in the shared layer.
final class AuditFixTests: XCTestCase {

    /// `?? 0` made an unreadable mode indistinguishable from a genuine 0, and
    /// that value was cached as the automatic baseline and written back on every
    /// restore — setting a mode the machine never had.
    func testAnUnreportedModeIsFlagged() {
        let reported = Fan(index: 0, actualRPM: 100, minRPM: 1, maxRPM: 2,
                           targetRPM: 1, modeRaw: 3)
        XCTAssertTrue(reported.modeReported, "the default must stay true for existing callers")

        let unreported = Fan(index: 0, actualRPM: 100, minRPM: 1, maxRPM: 2,
                             targetRPM: 1, modeRaw: 0, limitsReported: true,
                             modeReported: false)
        XCTAssertFalse(unreported.modeReported)
    }

    /// Errors that describe an unreadable fan must survive being formatted, since
    /// the values reaching them are the untrustworthy ones. `Int(Double.nan)`
    /// traps, which would crash the root daemon while reporting a fault.
    func testEveryFanControlErrorFormatsNonFiniteValues() {
        let messages = [
            FanControlError.implausibleRange(0, .nan, .infinity).description,
            FanControlError.invalidTarget(0, .nan).description,
            FanControlError.limitsUnknown(0).description,
            FanControlError.noBaselineRecorded(0).description,
            FanControlError.writeRejected("F0Md", 130).description,
            FanControlError.unwritableType("F0Md", "ui8 ").description,
            FanControlError.invalidFanIndex(99).description,
            FanControlError.notRoot.description,
        ]
        for message in messages { XCTAssertFalse(message.isEmpty) }
    }

    /// The daemon compiles in its own ceiling and must never take one from a
    /// client, so the app's settable range has to sit at or below it.
    func testNoSettableCutoffExceedsTheDaemonCeiling() {
        XCTAssertEqual(ThermalLimits.settableRange.upperBound,
                       ThermalLimits.daemonTripCelsius)
        XCTAssertLessThan(ThermalLimits.settableRange.upperBound,
                          ThermalLimits.assumedCriticalCelsius)
    }
}

/// Deciding when the firmware has taken the fans back.
///
/// Two shipped versions of this were wrong in opposite directions: "anything but
/// the forced value" accepted the value the handshake passes *through* as a
/// completed handover, and "exactly the captured baseline" ran the full ten
/// second wait and reported failure on restores that had in fact worked — six
/// times in the field, all after a wake.
final class ReclaimDetectionTests: XCTestCase {

    private let forced = FanController.forcedModeValue      // 1
    private let handshake = FanController.midHandshakeModeValue  // 0
    private let resting: Double = 3

    private func reclaimed(
        mode: Double, baseline: Double? = 3, previous: Double? = nil, reported: Bool = true
    ) -> Bool {
        FanController.modeLooksReclaimed(
            mode: mode, reported: reported, baseline: baseline, previousMode: previous
        )
    }

    func testTheBaselineIsConclusiveImmediately() {
        XCTAssertTrue(reclaimed(mode: resting))
    }

    func testAFanStillOnTheForcedValueHasNotReclaimed() {
        XCTAssertFalse(reclaimed(mode: forced))
        XCTAssertFalse(reclaimed(mode: forced, previous: forced))
    }

    /// The defect in "anything but forced": one poll landing mid-handshake was
    /// read as a completed reclaim, which then deleted the crash-recovery file.
    func testASingleMidHandshakeReadingIsNotEnough() {
        XCTAssertFalse(reclaimed(mode: handshake))
    }

    /// The defect in "exactly the baseline": a mode that has stopped moving is
    /// evidence even when it is not the value we hoped for. A transient cannot
    /// be stable across two consecutive polls.
    func testAModeThatHasStoppedMovingCounts() {
        XCTAssertTrue(reclaimed(mode: handshake, previous: handshake))
        XCTAssertTrue(reclaimed(mode: 2, previous: 2))
    }

    func testAMovingModeDoesNotCount() {
        XCTAssertFalse(reclaimed(mode: handshake, previous: resting))
        XCTAssertFalse(reclaimed(mode: 2, previous: handshake))
    }

    /// A Mac resting on the forced value can never satisfy a "not forced" test,
    /// so the wait must not spin for ten seconds to say so.
    func testAMacRestingOnTheForcedValueShortCircuits() {
        XCTAssertTrue(reclaimed(mode: forced, baseline: forced))
    }

    /// The daemon's startup path has no baseline yet.
    func testWithNoBaselineAStableNonForcedModeStillCounts() {
        XCTAssertFalse(reclaimed(mode: resting, baseline: nil))
        XCTAssertTrue(reclaimed(mode: resting, baseline: nil, previous: resting))
    }

    func testAnUnreportedModeIsNeverEvidence() {
        XCTAssertFalse(reclaimed(mode: resting, previous: resting, reported: false))
    }
}
