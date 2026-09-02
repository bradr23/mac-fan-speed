import XCTest
@testable import SMCKit

/// The daemon's thermal state machine, tested against the real type.
///
/// These replace a suite that asserted against a `private struct Machine`
/// transcribed into the test file — a copy of the logic, not the logic. It
/// passed, and would have kept passing through any regression in the daemon,
/// which is worse than no test because it reads as coverage.
final class ThermalWatchStateTests: XCTestCase {

    private let hot = ThermalLimits.daemonTripCelsius + 1
    private let cool = ThermalLimits.daemonResetCelsius - 1

    // MARK: The 0.4.0 lockout bug

    /// The watch was gated on "a HID client exists" but tripped on "a reading
    /// arrived". On a Mac where the first held and the second never did, the
    /// daemon latched a lockout nothing could lift and fan control died for the
    /// life of the daemon — while the log blamed heat.
    func testAMachineThatNeverReadsDoesNotArmTheWatch() {
        var state = ThermalWatchState()
        state.observeStartup(celsius: nil)
        XCTAssertFalse(state.shouldWatch, "a watch that can never read must not run")
        XCTAssertFalse(state.lockedOut)
        XCTAssertNil(state.refusalReason(celsius: nil), "and must not refuse control")
    }

    func testAMachineThatReadsArmsTheWatch() {
        var state = ThermalWatchState()
        state.observeStartup(celsius: 40)
        XCTAssertTrue(state.shouldWatch)
    }

    /// One failed read is not a lost sensor: the reader returns empty if the
    /// service copy fails once, on any Mac.
    func testASingleMissedReadingIsTolerated() {
        var state = ThermalWatchState()
        state.observeStartup(celsius: 40)
        XCTAssertEqual(state.step(celsius: nil), .none)
        XCTAssertTrue(state.shouldWatch)
    }

    func testMissesShortOfTheThresholdDoNotRelease() {
        var state = ThermalWatchState()
        state.observeStartup(celsius: 40)
        for _ in 0..<(ThermalWatchState.missesBeforeLost - 1) {
            XCTAssertEqual(state.step(celsius: nil), .none)
        }
    }

    /// Losing readings hands the fans back, but must never latch: the only thing
    /// that could lift such a latch is the reading that is missing.
    func testLosingReadingsReleasesWithoutLatching() {
        var state = ThermalWatchState()
        state.observeStartup(celsius: 40)
        var outcome: ThermalWatchState.Decision = .none
        for _ in 0..<ThermalWatchState.missesBeforeLost {
            outcome = state.step(celsius: nil)
        }
        XCTAssertEqual(outcome, .release(.readingsLost))
        XCTAssertFalse(state.lockedOut, "a lost sensor must not brick fan control")
        XCTAssertNil(state.refusalReason(celsius: nil))
        XCTAssertFalse(state.shouldWatch)
    }

    func testSensorsReturningReArmTheFailsafe() {
        var state = ThermalWatchState()
        state.observeStartup(celsius: 40)
        for _ in 0..<ThermalWatchState.missesBeforeLost { _ = state.step(celsius: nil) }
        XCTAssertFalse(state.shouldWatch)

        XCTAssertTrue(state.recoveryTick(celsius: 40), "should report that sensing returned")
        XCTAssertTrue(state.shouldWatch)
        XCTAssertFalse(state.recoveryTick(celsius: 40), "and only report it once")
    }

    // MARK: Heat

    func testHeatReleasesAndLatches() {
        var state = ThermalWatchState()
        state.observeStartup(celsius: 40)
        XCTAssertEqual(state.step(celsius: hot), .release(.tooHot(hot)))
        XCTAssertTrue(state.lockedOut)
        XCTAssertNotNil(state.refusalReason(celsius: 30), "must refuse even when cool now")
    }

    func testOnlyCoolingLiftsTheLatch() {
        var state = ThermalWatchState()
        state.observeStartup(celsius: 40)
        _ = state.step(celsius: hot)

        state.recoveryTick(celsius: ThermalLimits.daemonTripCelsius - 1)
        XCTAssertTrue(state.lockedOut, "still above the reset point")

        state.recoveryTick(celsius: cool)
        XCTAssertFalse(state.lockedOut)
        XCTAssertNil(state.refusalReason(celsius: cool))
    }

    func testJustBelowTheCeilingDoesNotRelease() {
        var state = ThermalWatchState()
        state.observeStartup(celsius: 40)
        XCTAssertEqual(state.step(celsius: ThermalLimits.daemonTripCelsius - 0.1), .none)
        XCTAssertFalse(state.lockedOut)
    }

    /// A non-finite reading is not a reading.
    func testNonFiniteReadingsCountAsMisses() {
        var state = ThermalWatchState()
        state.observeStartup(celsius: .nan)
        XCTAssertFalse(state.shouldWatch)
        XCTAssertNil(state.refusalReason(celsius: .nan))
    }

    /// With no reading at all, the daemon must not refuse control on a
    /// temperature it does not have.
    func testMissingTemperatureDoesNotRefuseControl() {
        let state = ThermalWatchState()
        XCTAssertNil(state.refusalReason(celsius: nil))
        XCTAssertNil(state.refusalReason(celsius: .nan))
    }

    /// But a reading above the ceiling refuses regardless of whether sensing has
    /// been "proven" yet. Requiring proof first opened a window at startup, and
    /// another after a lost-readings release, in which a genuinely hot machine
    /// had its fans taken over for the whole twelve-second unlock retry.
    func testHotReadingRefusesEvenBeforeSensingIsProven() {
        let state = ThermalWatchState()
        XCTAssertFalse(state.sensingProven)
        XCTAssertNotNil(state.refusalReason(celsius: ThermalLimits.daemonTripCelsius))
        XCTAssertNotNil(state.refusalReason(celsius: 200))
    }

    /// Client requests must never advance the miss counter. On a Mac where the
    /// daemon cannot read temperatures the periodic watch never runs, so
    /// `setFan`'s post-write check was the only caller — and once it had counted
    /// three, every later request forced the fans and released them again.
    func testClientChecksDoNotAccumulateMisses() {
        var state = ThermalWatchState()
        for _ in 0..<50 {
            XCTAssertEqual(state.observeHeat(celsius: nil), .none)
        }
        XCTAssertFalse(state.lockedOut)
        XCTAssertNil(state.refusalReason(celsius: nil))

        // The watch itself still counts, and still releases.
        XCTAssertEqual(state.step(celsius: nil), .none)
        XCTAssertEqual(state.step(celsius: nil), .none)
        XCTAssertEqual(state.step(celsius: nil), .release(.readingsLost))
    }

    /// Heat latches from a client-side check too: the ceiling must not depend on
    /// which timer happened to notice.
    func testClientChecksStillLatchOnHeat() {
        var state = ThermalWatchState()
        XCTAssertEqual(
            state.observeHeat(celsius: 120),
            .release(.tooHot(120))
        )
        XCTAssertTrue(state.lockedOut)
        XCTAssertNotNil(state.refusalReason(celsius: nil))
    }

    /// Release reasons are logged, so they must not read like enum cases.
    func testReasonsDescribeThemselvesForTheLog() {
        XCTAssertEqual(
            ThermalWatchState.Decision.Reason.readingsLost.logDescription,
            "temperature readings lost"
        )
        let hot = ThermalWatchState.Decision.Reason.tooHot(97).logDescription
        XCTAssertTrue(hot.contains("97.0"), hot)
        XCTAssertFalse(hot.contains("tooHot"), hot)
    }
}
