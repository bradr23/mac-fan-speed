import Foundation

/// The temperature failsafe.
///
/// Mandatory and not user-configurable (SPEC.md safety rule 3). Manual control
/// can hold fans *slower* than macOS would choose, so something has to notice
/// when that stops being safe. Two conditions trip it:
///
///  - the CPU reaches `tripCelsius`
///  - temperature becomes unreadable while fans are forced, because holding a
///    manual speed with no idea how hot the machine is would be worse than
///    giving control back
///
/// Recovery is hysteretic: it releases only below `resetCelsius`, so a machine
/// hovering at the threshold does not oscillate between modes.
struct Failsafe {
    static let tripCelsius: Double = 95
    static let resetCelsius: Double = 85

    enum Reason: Equatable {
        case tooHot(Double)
        case temperatureUnavailable

        var message: String {
            switch self {
            case .tooHot(let celsius):
                return String(
                    format: "CPU reached %.0f °C — fans returned to macOS control.", celsius
                )
            case .temperatureUnavailable:
                return "Lost temperature readings — fans returned to macOS control."
            }
        }
    }

    private(set) var trippedReason: Reason?

    var isTripped: Bool { trippedReason != nil }

    /// Evaluate one reading. Returns a reason when the failsafe should trip now,
    /// and clears itself once the machine has cooled below the reset threshold.
    ///
    /// - Parameters:
    ///   - celsius: hottest CPU reading, or nil if unavailable.
    ///   - manualControlActive: whether fans are currently forced.
    /// - Returns: `.trip(reason)` on a new trip, `.release` when recovered,
    ///   `.noChange` otherwise.
    mutating func evaluate(celsius: Double?, manualControlActive: Bool) -> Outcome {
        if isTripped {
            // Only release once genuinely cool, and only with a real reading.
            if let celsius, celsius < Self.resetCelsius {
                trippedReason = nil
                return .release
            }
            return .noChange
        }

        guard manualControlActive else { return .noChange }

        guard let celsius else {
            trippedReason = .temperatureUnavailable
            return .trip(.temperatureUnavailable)
        }
        if celsius >= Self.tripCelsius {
            trippedReason = .tooHot(celsius)
            return .trip(.tooHot(celsius))
        }
        return .noChange
    }

    enum Outcome: Equatable {
        case noChange
        case trip(Reason)
        case release
    }
}
