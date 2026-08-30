import Foundation

/// Pure formatting for the menu bar label.
///
/// Kept free of any state so the display paths that cannot be reproduced on the
/// developer's hardware — a fanless Mac, or sensors that stop responding — are
/// still covered by tests.
public enum MenuBarFormatter {

    /// Compact fan speed: 2400 becomes "2.4k". `nil` means unreadable.
    public static func rpm(_ value: Double?) -> String {
        guard let value else { return "----" }
        if value >= 1000 { return String(format: "%.1fk", value / 1000) }
        return String(format: "%.0f", value)
    }

    /// Whole-degree temperature for the menu bar. `nil` means unreadable.
    public static func temperature(_ celsius: Double?, unit: TemperatureUnit) -> String {
        guard let celsius else { return "--°" }
        return String(format: "%.0f°", unit.convert(celsius))
    }

    /// Temperature with its unit, for the dropdown.
    public static func detailedTemperature(_ celsius: Double?, unit: TemperatureUnit) -> String {
        guard let celsius else { return "-- \(unit.symbol)" }
        return String(format: "%.1f %@", unit.convert(celsius), unit.symbol)
    }

    /// The complete menu bar label.
    ///
    /// A Mac with no fans shows temperature alone rather than a fabricated zero.
    ///
    /// Fans that are stopped read "off" rather than "0". This is the state an
    /// idle Mac sits in most of the time — macOS holds the fans off until the
    /// machine is already warm, which is the whole reason this app exists — so it
    /// is the label most users see most often, and a bare "0" beside a
    /// temperature reads like a truncated number rather than a fan state. It
    /// stays distinct from `----`, which means the speed could not be read at all.
    public static func label(
        celsius: Double?,
        averageRPM: Double?,
        hasFans: Bool,
        unit: TemperatureUnit
    ) -> String {
        let temp = temperature(celsius, unit: unit)
        guard hasFans else { return temp }
        guard let averageRPM, averageRPM < 1 else { return "\(temp) \(rpm(averageRPM))" }
        return "\(temp) off"
    }
}
