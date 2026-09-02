import XCTest
@testable import MacFanSpeed

/// The sleep-versus-wedge discrimination, tested against the real type.
///
/// Both stale-readings field bugs lived in this decision, and neither could have
/// been caught before: it was a private method on a `@MainActor` singleton with a
/// private initialiser, so deleting the 0.4.1 fix left the suite green.
final class StalenessJudgeTests: XCTestCase {

    private let poll: TimeInterval = 2
    private let stale: TimeInterval = 6
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private var judge: StalenessJudge {
        StalenessJudge(pollInterval: poll, staleAfter: stale)
    }

    // MARK: The 0.4.1 bug — sleep read as a wedged loop

    /// A suspended process resumes holding an arbitrarily old snapshot for an
    /// innocent reason. Reading that as a stalled loop is what dropped the app to
    /// Auto after every sleep, with no path back.
    func testALongGapInPollingIsASuspensionNotAStall() {
        // 944 s was the real number from the field report.
        let verdict = judge.judge(
            now: t0.addingTimeInterval(944),
            lastSnapshot: t0,
            lastPoll: t0
        )
        XCTAssertEqual(verdict, .wasSuspended(944))
    }

    /// The signature of a genuine wedge: the poll timer keeps running — so its
    /// own clock stays current — while snapshots stop arriving.
    func testSnapshotsStoppingWhilePollingContinuesIsAStall() {
        let now = t0.addingTimeInterval(10)
        let verdict = judge.judge(
            now: now,
            lastSnapshot: t0,                          // 10 s old
            lastPoll: now.addingTimeInterval(-poll)    // polled 2 s ago: still alive
        )
        XCTAssertEqual(verdict, .stalled(10))
    }

    /// And it is caught quickly, not after a long delay.
    func testAWedgeIsCaughtWithinACoupleOfPolls() {
        let now = t0.addingTimeInterval(stale + 1)
        let verdict = judge.judge(
            now: now, lastSnapshot: t0, lastPoll: now.addingTimeInterval(-poll)
        )
        guard case .stalled = verdict else {
            return XCTFail("a live poll loop with stale snapshots must stall, got \(verdict)")
        }
    }

    // MARK: The 0.3.0 bug — a check that could never fire

    /// The age was computed where it was always zero, so the rule never fired.
    /// A fresh snapshot must read as fine, but only because it is fresh.
    func testFreshSnapshotsAreFine() {
        let now = t0.addingTimeInterval(2)
        XCTAssertEqual(
            judge.judge(now: now, lastSnapshot: now.addingTimeInterval(-1),
                        lastPoll: now.addingTimeInterval(-poll)),
            .fine
        )
    }

    func testExactlyAtTheThresholdIsStillFine() {
        let now = t0.addingTimeInterval(stale)
        XCTAssertEqual(
            judge.judge(now: now, lastSnapshot: t0, lastPoll: now.addingTimeInterval(-poll)),
            .fine
        )
    }

    // MARK: Edges

    /// First tick after launch: no snapshot yet, so there is no age to be stale.
    func testNoSnapshotYetIsFine() {
        XCTAssertEqual(judge.judge(now: t0, lastSnapshot: nil, lastPoll: nil), .fine)
        XCTAssertEqual(judge.judge(now: t0, lastSnapshot: nil, lastPoll: t0), .fine)
    }

    /// First poll after launch has no previous poll to compare against, so the
    /// suspension test cannot run — it must not therefore assume a stall.
    func testFirstPollWithAnOldSnapshotDoesNotFalselySuspend() {
        let verdict = judge.judge(
            now: t0.addingTimeInterval(100), lastSnapshot: t0, lastPoll: nil
        )
        XCTAssertEqual(verdict, .stalled(100), "no poll history means judge on the snapshot")
    }

    /// A gap just over the poll interval is ordinary timer jitter, not a sleep.
    func testOrdinaryTimerJitterIsNotASuspension() {
        let now = t0.addingTimeInterval(20)
        let verdict = judge.judge(
            now: now,
            lastSnapshot: t0,
            lastPoll: now.addingTimeInterval(-(poll * 1.5))
        )
        guard case .stalled = verdict else {
            return XCTFail("a 3 s poll gap is jitter, not a suspension: got \(verdict)")
        }
    }

    /// A clock that moved backwards is not evidence of anything.
    func testABackwardsClockDoesNotTrip() {
        let now = t0
        XCTAssertEqual(
            judge.judge(now: now, lastSnapshot: now.addingTimeInterval(60),
                        lastPoll: now.addingTimeInterval(-poll)),
            .fine
        )
    }

    /// The threshold that separates the two verdicts is the poll multiple, and it
    /// has to sit above jitter and below any real sleep.
    func testTheSuspensionThresholdIsWhereItClaims() {
        XCTAssertEqual(StalenessJudge.suspensionPollMultiple, 3)
        let boundary = poll * StalenessJudge.suspensionPollMultiple
        let now = t0.addingTimeInterval(100)

        guard case .stalled = judge.judge(
            now: now, lastSnapshot: t0, lastPoll: now.addingTimeInterval(-(boundary - 0.1))
        ) else { return XCTFail("just inside the band must be a stall") }

        guard case .wasSuspended = judge.judge(
            now: now, lastSnapshot: t0, lastPoll: now.addingTimeInterval(-(boundary + 0.1))
        ) else { return XCTFail("just outside the band must be a suspension") }
    }
}
