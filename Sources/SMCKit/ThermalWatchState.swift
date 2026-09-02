import Foundation

/// The privileged daemon's thermal decision-making, as a plain value type.
///
/// This lives outside `FanService` for one reason: the daemon is an executable
/// target that no test bundle can import, so logic left inside it cannot be
/// tested. The regression tests written for the 0.4.0 lockout bug asserted
/// against a *transcription* of this state machine into the test file, which
/// would have stayed green through any regression in the real thing — coverage
/// in appearance only. Everything here is temperature in, decision out: no SMC
/// handle, no timers, no clock.
public struct ThermalWatchState: Equatable, Sendable {

    /// What the daemon should do about the reading it just took.
    public enum Decision: Equatable, Sendable {
        /// Carry on.
        case none
        /// Hand the fans back, and why.
        case release(Reason)

        public enum Reason: Equatable, Sendable {
            case tooHot(Double)
            case readingsLost

            /// Written out rather than interpolated. `"\(reason)"` on an enum
            /// yields `tooHot(97.0)`, and these strings go straight into the log
            /// this project asks people to paste into bug reports.
            public var logDescription: String {
                switch self {
                case .tooHot(let celsius):
                    return String(
                        format: "%.1f °C reached the %.0f °C ceiling",
                        celsius, ThermalLimits.daemonTripCelsius
                    )
                case .readingsLost:
                    return "temperature readings lost"
                }
            }
        }
    }

    /// Consecutive failed reads tolerated before sensing is declared lost.
    /// `TemperatureReader.readAll()` returns empty if the service copy fails
    /// once, so a single miss must not be decisive.
    public static let missesBeforeLost = 3

    /// Whether a temperature has ever actually been read.
    ///
    /// Distinct from `TemperatureReader.isAvailable`, which only reports that a
    /// HID client object exists — nearly always true, and silent about whether
    /// any sensor enumerates. Gating the watch on availability while tripping it
    /// on a reading meant the two tested different things.
    public private(set) var sensingProven = false

    /// Set only by heat. Losing readings deliberately does not latch: the only
    /// thing that could lift such a latch is the reading that is missing, so
    /// latching there produced a daemon that refused fan control forever while
    /// blaming temperature.
    public private(set) var lockedOut = false

    private var misses = 0

    public init() {}

    /// Record the daemon's first read at startup.
    public mutating func observeStartup(celsius: Double?) {
        if let celsius, celsius.isFinite {
            sensingProven = true
            misses = 0
        }
    }

    /// Whether the periodic watch is worth running at all.
    public var shouldWatch: Bool { sensingProven }

    /// Why a fan request must be refused right now, or nil to allow it.
    ///
    /// Deliberately does **not** require `sensingProven`. A reading is evidence
    /// of itself: gating the ceiling on a flag that is false at startup until the
    /// first read lands, and false again after a lost-readings release, opened
    /// windows where a genuine 100 °C machine had its fans taken over — for the
    /// whole twelve-second unlock retry, before anything re-checked. Hard rule 4
    /// makes that ceiling unconditional.
    public func refusalReason(celsius: Double?) -> String? {
        if lockedOut {
            return "too hot — the helper has returned the fans to macOS"
        }
        guard let celsius, celsius.isFinite,
              celsius >= ThermalLimits.daemonTripCelsius
        else { return nil }
        return String(
            format: "too hot (%.0f °C, ceiling %.0f °C)",
            celsius, ThermalLimits.daemonTripCelsius
        )
    }

    /// One tick of the periodic watch while fans are held.
    ///
    /// Only the watch may call this: the miss counter measures consecutive
    /// *ticks*, so anything else advancing it changes what the tolerance means.
    public mutating func step(celsius: Double?) -> Decision {
        guard let celsius, celsius.isFinite else {
            misses += 1
            guard misses >= Self.missesBeforeLost else { return .none }
            sensingProven = false
            misses = 0
            return .release(.readingsLost)
        }
        return observeHeat(celsius: celsius)
    }

    /// Judge a reading taken outside the periodic watch.
    ///
    /// Heat still latches — the ceiling must not depend on which timer noticed —
    /// but a *missing* reading is not counted, and that difference matters.
    /// Letting client requests advance the miss counter meant that on a Mac where
    /// the daemon cannot read temperatures at all (a configuration it logs as
    /// supported, and hard rule 6 requires) the counter only ever went up: the
    /// periodic watch never starts there, so `setFan` was its sole caller. Three
    /// requests in, every later one forced the fans and immediately released
    /// them, handing the client a heat error from a machine that had reported no
    /// temperature at all.
    public mutating func observeHeat(celsius: Double?) -> Decision {
        guard let celsius, celsius.isFinite else { return .none }

        misses = 0
        sensingProven = true

        guard celsius >= ThermalLimits.daemonTripCelsius else { return .none }
        lockedOut = true
        return .release(.tooHot(celsius))
    }

    /// The slow tick that runs for the daemon's whole life, so recovery does not
    /// depend on a client asking for anything.
    ///
    /// - Returns: true when sensing has just come back, so the caller can re-arm
    ///   a watch it had stopped. Without this the watch stayed off until the next
    ///   `setFan`, leaving already-forced fans unsupervised indefinitely.
    @discardableResult
    public mutating func recoveryTick(celsius: Double?) -> Bool {
        guard let celsius, celsius.isFinite else { return false }

        let regained = !sensingProven
        if regained {
            sensingProven = true
            misses = 0
        }
        if lockedOut, celsius < ThermalLimits.daemonResetCelsius {
            lockedOut = false
        }
        return regained
    }
}
