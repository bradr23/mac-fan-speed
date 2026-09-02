import Foundation

/// The escalation floor: the minimum fan speed the app will command at a given
/// temperature, whatever the user asked for.
///
/// This exists because the app's whole purpose — holding fans *slower* than
/// macOS would — is safe while the machine is cool and stops being safe when it
/// is not. Left alone, a laptop pinned at 15% can be taxed until it is at 90 °C
/// with the fans still barely turning, which is precisely what macOS would never
/// do.
///
/// It is applied as `max(requested, floor)`, so it can only ever raise a speed.
/// That matters more than it looks: `max` is monotone, so no user curve, no
/// slider position, no per-fan value and no corrupted preference file can
/// produce a commanded speed below this floor. There is no merging algorithm to
/// get wrong.
///
/// It is deliberately **not** the failsafe. This is a *speed* mechanism that
/// works inside manual control; the failsafe is a *mode* mechanism that leaves
/// manual control entirely. Keeping them as separate code with separate state
/// means a bug in one cannot disable the other.
///
/// Hardcoded and not user-editable, by design — see SPEC.md "Safety rules".
enum ThermalGuard {

    /// Below the first point the user's setting stands untouched: a guard that
    /// engaged during ordinary browsing would defeat the point of the app.
    /// 65 °C is moderate sustained load — well above idle (33–38 °C measured)
    /// and below where the firmware is already ramping hard.
    ///
    /// It reaches full speed at 90 °C, five degrees below the default cutoff, so
    /// by the time the failsafe hands control back the app has already been
    /// asking for everything the fans have. The failsafe is then a genuine last
    /// resort rather than the first thing that happens.
    static let floor = FanCurve(points: [
        CurvePoint(celsius: 65, percent: 0.00),
        CurvePoint(celsius: 70, percent: 0.20),
        CurvePoint(celsius: 75, percent: 0.40),
        CurvePoint(celsius: 80, percent: 0.60),
        CurvePoint(celsius: 85, percent: 0.80),
        CurvePoint(celsius: 90, percent: 1.00),
    ])

    /// Minimum speed this temperature demands, as a fraction of each fan's range.
    ///
    /// An unknown temperature asks for everything: with nothing to judge by, the
    /// only safe direction is more cooling.
    ///
    /// The window is bounded by `Failsafe.missesBeforeSensorsLost`, not by a
    /// single poll. The failsafe tolerates two misses before handing the fans
    /// back, because `TemperatureReader` returns empty whenever the HID service
    /// copy fails once and tripping on that hiccup was worse. So this can hold
    /// for up to three polls — six seconds — and at `slewUpPerSecond` the command
    /// does reach full range inside it. Audible, and deliberately preferred to
    /// guessing a temperature.
    static func percent(atCelsius celsius: Double?) -> Double {
        guard let celsius, celsius.isFinite else { return 1 }
        return floor.percent(atCelsius: celsius)
    }

    /// Whether the guard is currently asking for more than the user did.
    static func isRaising(requested: Double, celsius: Double?) -> Bool {
        percent(atCelsius: celsius) > requested + 0.001
    }

    /// Lowest temperature at which the guard does anything at all, for the UI.
    static var engagesAtCelsius: Double { floor.points.first?.celsius ?? 65 }
}
