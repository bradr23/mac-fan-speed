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
    public static func label(
        celsius: Double?,
        averageRPM: Double?,
        hasFans: Bool,
        unit: TemperatureUnit
    ) -> String {
        let temp = temperature(celsius, unit: unit)
        guard hasFans else { return temp }
        return "\(temp) \(rpm(averageRPM))"
    }
}
