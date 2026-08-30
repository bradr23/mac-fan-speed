import Foundation
import SMCKit

/// Everything the failsafe judges a tick on.
///
/// A struct rather than a growing parameter list, so adding a rule cannot
/// silently skip a call site.
struct FailsafeInput {
    /// Hottest CPU reading, **raw and instantaneous**. Never the filtered value
    /// the fan curve uses: every stage of that filter adds lag, and a failsafe
    /// that lags is not a failsafe.
    var cpuCelsius: Double?
    var hottestBatteryCelsius: Double?
    var hottestStorageCelsius: Double?
    var thermalState: ProcessInfo.ThermalState = .nominal
    /// How long since a successful sensor read. Catches a control loop that has
    /// stopped while the UI keeps showing its last comfortable value.
    var readingAge: TimeInterval = 0
    var now: Date = Date()
    var manualControlActive: Bool
}

/// The temperature failsafe.
///
/// Manual control can hold fans *slower* than macOS would, so something has to
/// notice when that stops being safe. This is the mechanism that leaves manual
/// control entirely and gives the fans back — distinct from `ThermalGuard`,
/// which raises the speed while staying in manual. Keeping them separate means
/// a bug in one cannot disable the other.
///
/// The CPU threshold is user-configurable **downward only**; see
/// `maximumTripCelsius`. Every other rule here is fixed.
///
/// Recovery is hysteretic throughout: each rule releases at a lower temperature
/// than it trips at, so a machine sitting near a threshold does not flap.
struct Failsafe {

    // MARK: Thresholds

    /// The assumed critical point and the ceiling derived from it now live in
    /// `SMCKit.ThermalLimits`, because the **daemon** needs them too and must not
    /// take a threshold from a client. See that type for why the number is an
    /// assumption rather than a reading.
    static var assumedCriticalCelsius: Double { ThermalLimits.assumedCriticalCelsius }

    /// The highest cutoff a user can choose. There is no code path producing a
    /// higher trip, and the daemon enforces the same ceiling independently.
    static var maximumTripCelsius: Double { ThermalLimits.maximumTripCelsius }
    static var minimumTripCelsius: Double { ThermalLimits.minimumTripCelsius }
    static var defaultTripCelsius: Double { ThermalLimits.maximumTripCelsius }
    static var hysteresisCelsius: Double { ThermalLimits.hysteresisCelsius }

    static var settableRange: ClosedRange<Double> {
        minimumTripCelsius...maximumTripCelsius
    }

    /// Fixed rules the user cannot configure.
    static let batteryTripCelsius: Double = 55
    static let batteryResetCelsius: Double = 48
    static let storageTripCelsius: Double = 80
    static let storageResetCelsius: Double = 70
    /// Sitting just below the cutoff indefinitely never trips a threshold, but
    /// thermal damage is cumulative, so dwell is capped too.
    static let sustainedCelsius: Double = 85
    static let sustainedReleaseCelsius: Double = 80
    static let sustainedDuration: TimeInterval = 5 * 60
    /// Three polls. Longer than any legitimate gap, short enough to catch a
    /// wedged loop before the machine cooks behind a stale reading.
    static let staleReadingSeconds: TimeInterval = 6

    private(set) var tripCelsius: Double
    var resetCelsius: Double { max(tripCelsius - Self.hysteresisCelsius, 40) }

    init(tripCelsius: Double = Failsafe.defaultTripCelsius) {
        self.tripCelsius = Self.clampTrip(tripCelsius)
    }

    /// The authoritative clamp, and the layer the safety argument actually rests
    /// on — the UI bound and the settings clamps above it are conveniences.
    ///
    /// Non-finite input yields the default rather than a bound, because
    /// `min(max(.nan, lo), hi)` is `nan` in Swift: every comparison against nan
    /// is false, so a naive clamp passes it straight through.
    static func clampTrip(_ value: Double) -> Double {
        ThermalLimits.clampTrip(value)
    }

    /// Adopt a changed user setting without losing an in-flight trip.
    mutating func setTrip(_ celsius: Double) {
        tripCelsius = Self.clampTrip(celsius)
    }

    // MARK: State

    enum Reason: Equatable {
        case tooHot(Double)
        case temperatureUnavailable
        case readingsStale(TimeInterval)
        case sustainedHeat(Double, TimeInterval)
        case batteryTooHot(Double)
        case storageTooHot(Double)
        case systemThermalPressure

        var message: String {
            switch self {
            case .tooHot(let celsius):
                return String(
                    format: "CPU reached %.0f °C — fans returned to macOS control.", celsius
                )
            case .temperatureUnavailable:
                return "Lost temperature readings — fans returned to macOS control."
            case .readingsStale(let age):
                return String(
                    format: "Temperature readings stopped updating %.0f s ago — "
                          + "fans returned to macOS control.", age
                )
            case .sustainedHeat(let celsius, let duration):
                return String(
                    format: "CPU held above %.0f °C for %.0f minutes — "
                          + "fans returned to macOS control.",
                    celsius, duration / 60
                )
            case .batteryTooHot(let celsius):
                return String(
                    format: "Battery reached %.0f °C — fans returned to macOS control.", celsius
                )
            case .storageTooHot(let celsius):
                return String(
                    format: "Storage reached %.0f °C — fans returned to macOS control.", celsius
                )
            case .systemThermalPressure:
                return "macOS reported thermal pressure — fans returned to macOS control."
            }
        }
    }

    private(set) var trippedReason: Reason?
    private var heatBandEntered: Date?

    var isTripped: Bool { trippedReason != nil }

    enum Outcome: Equatable {
        case noChange
        case trip(Reason)
        case release
    }

    /// Evaluate one tick.
    ///
    /// Order matters only in that the first matching rule wins the message; any
    /// of them tripping has the same effect.
    mutating func evaluate(_ input: FailsafeInput) -> Outcome {
        trackSustainedHeat(input)

        if isTripped {
            // Release needs a real, current reading below the reset point and
            // every other rule quiet. Recovering blind would re-enable manual
            // control with no way to notice the machine heating again.
            // The dwell timer is deliberately not consulted here. It is a *trip*
            // condition — it exists to catch a machine parked just under the
            // cutoff — and requiring it to be clear before releasing would have
            // meant nothing could ever recover between the dwell band (85 °C)
            // and the CPU reset point, which is most of the recovery range.
            // Clearing it below is what stops it firing again the instant
            // manual control resumes.
            guard let celsius = input.cpuCelsius, celsius.isFinite,
                  celsius < resetCelsius,
                  input.readingAge <= Self.staleReadingSeconds,
                  (input.hottestBatteryCelsius ?? 0) < Self.batteryResetCelsius,
                  (input.hottestStorageCelsius ?? 0) < Self.storageResetCelsius,
                  !Self.isPressured(input.thermalState)
            else { return .noChange }

            trippedReason = nil
            heatBandEntered = nil
            return .release
        }

        // Nothing to take back if macOS already has the fans.
        guard input.manualControlActive else { return .noChange }

        if input.readingAge > Self.staleReadingSeconds {
            return trip(.readingsStale(input.readingAge))
        }
        guard let celsius = input.cpuCelsius, celsius.isFinite else {
            return trip(.temperatureUnavailable)
        }
        if celsius >= tripCelsius { return trip(.tooHot(celsius)) }
        if let battery = input.hottestBatteryCelsius, battery >= Self.batteryTripCelsius {
            return trip(.batteryTooHot(battery))
        }
        if let storage = input.hottestStorageCelsius, storage >= Self.storageTripCelsius {
            return trip(.storageTooHot(storage))
        }
        if Self.isPressured(input.thermalState) {
            return trip(.systemThermalPressure)
        }
        if let entered = heatBandEntered {
            let held = input.now.timeIntervalSince(entered)
            if held >= Self.sustainedDuration {
                return trip(.sustainedHeat(Self.sustainedCelsius, held))
            }
        }
        return .noChange
    }

    private mutating func trip(_ reason: Reason) -> Outcome {
        trippedReason = reason
        return .trip(reason)
    }

    /// A machine can sit just below the cutoff indefinitely without ever
    /// crossing it. Time spent in the band above `sustainedCelsius` is therefore
    /// tracked, and cleared the moment it drops back out.
    private mutating func trackSustainedHeat(_ input: FailsafeInput) {
        guard let celsius = input.cpuCelsius, celsius.isFinite else { return }
        if celsius >= Self.sustainedCelsius {
            if heatBandEntered == nil { heatBandEntered = input.now }
        } else if celsius < Self.sustainedReleaseCelsius {
            heatBandEntered = nil
        }
    }

    /// `.serious` and `.critical` mean macOS is already mitigating.
    ///
    /// Supplementary only, never a substitute for a temperature. `NSProcessInfo`
    /// documents that where thermal state is unknown or unsupported the value is
    /// always `.nominal` — a signal whose failure mode is the reassuring answer.
    /// It also defines `.serious` partly as "fans are running at maximum speed",
    /// a premise this app invalidates by design. So the bad values are acted on
    /// and `.nominal` is never taken as evidence of anything.
    static func isPressured(_ state: ProcessInfo.ThermalState) -> Bool {
        state == .serious || state == .critical
    }
}
