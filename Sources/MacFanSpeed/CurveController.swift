import Foundation

/// Tuning for the anti-oscillation machinery.
///
/// Deliberately not exposed in the UI. Every fan-control tool that offers these
/// as settings has open threads from users who cannot tell whether hysteresis is
/// working — a correctly functioning deadband is indistinguishable from a broken
/// controller. On hardware the developer cannot test, fewer knobs is the safer
/// position.
struct CurveTuning: Equatable, Sendable {
    /// Samples in the median prefilter. Rejects a single-sample sensor spike at
    /// the cost of one poll of lag on a genuine ramp.
    var medianWindow: Int = 3
    /// EMA weight applied only while cooling. Rising temperatures are taken
    /// immediately.
    var coolingAlpha: Double = 0.25
    /// How far the temperature must move past the last committed change before
    /// the speed is allowed to follow it.
    var deadbandUpCelsius: Double = 1.5
    var deadbandDownCelsius: Double = 3.0
    /// Limits on how fast the commanded speed may change, as fraction of range
    /// per second.
    var slewUpPerSecond: Double = 0.25
    var slewDownPerSecond: Double = 0.03

    static let shipped = CurveTuning()
}

/// Median-of-N followed by an asymmetric exponential average.
///
/// The failsafe never sees this. Every stage here adds phase lag, and at a two
/// second poll an EMA at α = 0.25 has a time constant near seven seconds —
/// enough to delay a trip by several polls. Smoothing exists to keep the fans
/// quiet, never to decide whether the machine is safe.
///
/// The asymmetry is the safety property: a rising reading is adopted at once, a
/// falling one decays. The app therefore never underestimates how hot the
/// machine is, only how cool.
struct TemperatureFilter {
    private var window: [Double] = []
    private var smoothed: Double?

    mutating func step(_ raw: Double, tuning: CurveTuning = .shipped) -> Double {
        guard raw.isFinite else { return smoothed ?? raw }

        window.append(raw)
        if window.count > max(1, tuning.medianWindow) { window.removeFirst() }

        // Until the window is full there is nothing to take a median of, so the
        // raw value passes through rather than being averaged with itself.
        let candidate: Double
        if window.count >= tuning.medianWindow {
            candidate = window.sorted()[window.count / 2]
        } else {
            candidate = raw
        }

        guard let previous = smoothed else {
            smoothed = candidate
            return candidate
        }
        // Heating: adopt immediately. Cooling: decay.
        let next = candidate >= previous
            ? candidate
            : previous + (candidate - previous) * tuning.coolingAlpha
        smoothed = next
        return next
    }

    mutating func reset() {
        window.removeAll()
        smoothed = nil
    }

    var current: Double? { smoothed }
}

/// Holds a speed steady until the temperature has moved far enough from where
/// the speed last changed to justify moving it again.
///
/// The reference is the temperature at the last **committed output change**, not
/// a curve point. Attaching hysteresis to curve points is the naive approach and
/// it silently does nothing between points — which is where the fan spends
/// essentially all of its time. Tracking the operating point instead makes the
/// band behave identically at 45 °C and at 88 °C, with nothing to configure per
/// point.
///
/// The bands are asymmetric on purpose: a machine hovering at its thermal
/// equilibrium settles on the higher of the two speeds, never the lower.
struct HysteresisTrack {
    private var referenceCelsius: Double?
    private(set) var output: Double = 0

    /// - Parameter immediate: a direct user action — moving the slider, picking
    ///   a profile. Those bypass the band entirely, because a slider that
    ///   appears not to respond reads as a bug.
    mutating func step(
        curveValue: Double,
        atCelsius celsius: Double,
        tuning: CurveTuning = .shipped,
        immediate: Bool = false
    ) -> Double {
        guard curveValue.isFinite, celsius.isFinite else { return output }

        guard let reference = referenceCelsius, !immediate else {
            referenceCelsius = celsius
            output = curveValue
            return output
        }

        let movement = celsius - reference
        let band = movement >= 0 ? tuning.deadbandUpCelsius : tuning.deadbandDownCelsius
        guard abs(movement) >= band else { return output }

        referenceCelsius = celsius
        output = curveValue
        return output
    }

    mutating func reset(to percent: Double = 0) {
        referenceCelsius = nil
        output = percent
    }
}

/// Rate-limits the commanded speed so a change in the curve becomes a ramp
/// rather than a step.
///
/// Applied to the composed value, after the guard floor has been taken into
/// account, so one limiter governs everything that reaches the SMC.
///
/// Up and down differ by an order of magnitude. Escalation needs to be prompt
/// because it is safety-adjacent; de-escalation is purely acoustic, and a slow
/// spin-down is what stops a machine near its equilibrium from audibly hunting.
struct SlewLimiter {
    private(set) var value: Double
    private var lastStep: Date?

    init(startingAt value: Double = 0) {
        self.value = value
    }

    mutating func step(
        towards target: Double,
        now: Date,
        tuning: CurveTuning = .shipped,
        immediate: Bool = false
    ) -> Double {
        guard target.isFinite else { return value }

        defer { lastStep = now }
        guard let last = lastStep, !immediate else {
            value = target
            return value
        }

        let elapsed = now.timeIntervalSince(last)
        // A clock that jumped backwards, or a wake from sleep: treat the gap as
        // one poll rather than trusting it.
        guard elapsed > 0, elapsed < 60 else {
            value = target
            return value
        }

        let limit = (target > value ? tuning.slewUpPerSecond : tuning.slewDownPerSecond) * elapsed
        let delta = target - value
        value += abs(delta) <= limit ? delta : (delta > 0 ? limit : -limit)
        value = min(max(value, 0), 1)
        return value
    }

    mutating func reset(to percent: Double) {
        value = min(max(percent, 0), 1)
        lastStep = nil
    }
}

/// What is actually deciding the fan speed right now.
///
/// Surfaced in the dropdown so a user who set 15% and hears 6000 rpm can see
/// why. Without it that is a support report.
enum SpeedDriver: Equatable {
    /// The user's own setting is in force.
    case user
    /// A profile's curve is choosing the speed for the current temperature.
    case profileCurve
    /// The safety floor is overriding a setting that is too low to be safe.
    case thermalGuard(requested: Double, celsius: Double)
}

/// Ties the pieces together: filter the temperature, evaluate whatever the
/// profile asks for, take the higher of that and the safety floor, then ramp
/// towards it.
struct CurveController {
    private var filter = TemperatureFilter()
    private var profileTrack = HysteresisTrack()
    private var slew = SlewLimiter()

    private(set) var driver: SpeedDriver = .user
    private(set) var filteredCelsius: Double?

    /// - Parameters:
    ///   - requested: what the user asked for — a flat percentage, or nil when a
    ///     curve is driving.
    ///   - curve: the active profile's curve, if it has one.
    ///   - rawCelsius: the hottest CPU reading, unfiltered.
    ///   - immediate: bypass smoothing and rate limits for a direct user action.
    /// - Returns: the fraction of each fan's range to command.
    mutating func step(
        requested: Double,
        curve: FanCurve?,
        rawCelsius: Double?,
        now: Date,
        tuning: CurveTuning = .shipped,
        immediate: Bool = false
    ) -> Double {
        let filtered: Double?
        if let rawCelsius, rawCelsius.isFinite {
            filtered = filter.step(rawCelsius, tuning: tuning)
        } else {
            filtered = nil
        }
        filteredCelsius = filtered

        // Without a temperature there is no curve to evaluate and no floor to
        // interpolate; ask for everything until the failsafe takes over.
        guard let filtered else {
            driver = .thermalGuard(requested: requested, celsius: .nan)
            return slew.step(towards: 1, now: now, tuning: tuning, immediate: immediate)
        }

        // A non-finite request must not reach the comparison below. Swift's
        // `max(.nan, x)` returns nan, because `x >= nan` is false — so a NaN
        // stored speed would win against the safety floor and silently defeat
        // it at every temperature. Everything else feeding this path already
        // guards finiteness; this is the one value that arrives straight from
        // preferences.
        var profileValue = requested.isFinite ? min(max(requested, 0), 1) : 0
        if let curve {
            profileValue = profileTrack.step(
                curveValue: curve.percent(atCelsius: filtered),
                atCelsius: filtered,
                tuning: tuning,
                immediate: immediate
            )
        }

        // The floor is NOT passed through the deadband. That damping exists to
        // keep the fans quiet, and applying it here let the effective floor sit
        // several points below what ThermalGuard actually demands for as long as
        // the temperature stayed inside the band. Acoustics do not get a say in
        // the safety floor; the slew limiter below still smooths the result.
        let floorValue = ThermalGuard.percent(atCelsius: filtered)

        let composed = max(profileValue, floorValue)

        if floorValue > profileValue + 0.001 {
            driver = .thermalGuard(requested: profileValue, celsius: filtered)
        } else if curve != nil {
            driver = .profileCurve
        } else {
            driver = .user
        }

        return slew.step(towards: composed, now: now, tuning: tuning, immediate: immediate)
    }

    /// Clear all state. Needed whenever continuity is broken — entering manual
    /// control, switching profile, waking from sleep, or the failsafe releasing
    /// — so a stale reference temperature from before the gap cannot govern the
    /// first commit after it.
    mutating func reset(to percent: Double = 0) {
        let safe = percent.isFinite ? min(max(percent, 0), 1) : 0
        filter.reset()
        profileTrack.reset(to: safe)
        slew.reset(to: safe)
        driver = .user
        filteredCelsius = nil
    }

    var commanded: Double { slew.value }
}
