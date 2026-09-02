import Foundation

/// Decides whether sensor readings have genuinely stopped, or whether the app
/// merely was not running for a while.
///
/// Extracted from `FanMonitor` because both stale-readings field bugs lived in
/// this decision and neither could be tested where it was: a private method on a
/// `@MainActor` singleton with a private initialiser. In 0.3.0 the age was
/// computed at a call site where it was always zero, so the check could not fire
/// at all; in 0.4.1 a suspended process resumed holding an old timestamp and was
/// read as a wedged loop, which knocked the app out of manual control with no
/// path back. Clock in, verdict out — no timers, no singleton, no hardware.
struct StalenessJudge: Equatable {

    /// What the caller should do.
    enum Verdict: Equatable {
        /// Nothing to report.
        case fine
        /// The process itself was away — a sleep, or App Nap freezing the timer.
        /// Not a stalled loop, and not this check's business.
        case wasSuspended(TimeInterval)
        /// Readings genuinely stopped while the app kept running. The associated
        /// value is the age to report.
        case stalled(TimeInterval)
    }

    /// A gap in `poll()` itself larger than this many poll intervals means the
    /// process was not running, so an equally old snapshot is innocent.
    ///
    /// A wedged queue leaves the poll timer running, so its own clock stays
    /// current and the snapshot age crosses the threshold within a couple of
    /// ticks. That difference is the entire discrimination.
    static let suspensionPollMultiple: Double = 3

    let pollInterval: TimeInterval
    let staleAfter: TimeInterval

    init(pollInterval: TimeInterval, staleAfter: TimeInterval) {
        self.pollInterval = pollInterval
        self.staleAfter = staleAfter
    }

    /// - Parameters:
    ///   - lastSnapshot: when a sensor snapshot last arrived, or nil if none has.
    ///   - lastPoll: when the poll timer last ran, or nil on the first tick.
    func judge(now: Date, lastSnapshot: Date?, lastPoll: Date?) -> Verdict {
        // Nothing has arrived yet, so there is no age to be stale.
        guard let lastSnapshot else { return .fine }

        if let lastPoll {
            let pollGap = now.timeIntervalSince(lastPoll)
            if pollGap > pollInterval * Self.suspensionPollMultiple {
                return .wasSuspended(pollGap)
            }
        }

        let age = now.timeIntervalSince(lastSnapshot)
        // A clock that moved backwards is not evidence of anything.
        guard age > staleAfter else { return .fine }
        return .stalled(age)
    }
}
