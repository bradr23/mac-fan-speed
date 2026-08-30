import Foundation

/// Turns hardware sensor names into something a person can read.
///
/// The rule throughout is **rename, never invent**. `pACC MTR Temp Sensor0`
/// genuinely identifies a performance core cluster, so calling it that is a
/// translation. `PMU tdie1` says only that it is a die sensor — this Mac has 14
/// of them and 12 CPU cores, so labelling them "CPU core 1…12" would be a guess
/// dressed as a fact. Those become "Processor die 1", which is exactly what is
/// known and no more.
///
/// Anything unrecognised keeps the name the hardware gave it. A wrong friendly
/// name is worse than an ugly true one, especially on hardware nobody has
/// catalogued.
public enum SensorNaming {

    /// A readable name, plus the raw detail needed to verify or report it.
    public struct Named {
        /// What to show, e.g. "Performance cores 0" or "Processor die 1".
        public let display: String
        /// The name the hardware reported, e.g. `pACC MTR Temp Sensor0`.
        public let raw: String
        /// SMC key behind it, e.g. `TP1b`, when known.
        public let smcKey: String?
        /// True when `display` is just `raw` — nothing was recognised.
        public let isVerbatim: Bool
    }

    /// Recognised families. Checked in order, so specific patterns come first.
    ///
    /// `%` marks where a trailing index is substituted.
    private static let rules: [(fragment: String, template: String)] = [
        // Named families, present on M1 and M2 and genuinely descriptive.
        ("pacc mtr", "Performance cores %"),
        ("eacc mtr", "Efficiency cores %"),
        ("gpu mtr", "Graphics %"),
        ("ane mtr", "Neural Engine %"),
        ("isp mtr", "Image processor %"),
        ("pmgr soc die", "System-on-chip die %"),
        ("soc mtr", "System-on-chip %"),

        // Calibration references, which read well above the real die sensors.
        // Checked before the die families so "PMU2 tcal" is not caught by a
        // broader PMU2 rule.
        ("pmu2 tcal", "Calibration reference (second controller)"),
        ("pmu tcal", "Calibration reference"),
        ("tcal", "Calibration reference"),

        // `PMU2` is a **second power controller on base-tier single-die Macs**
        // (M1, base M4, A18) — it is not a second die. Dumps from M2 Ultra and
        // M3 Ultra contain no PMU2 sensors at all, while base M4 and M1 do.
        // Naming these "second package" was simply wrong.
        ("pmu2 tdie", "Die sensor % (second controller)"),
        ("pmu2 tdev", "Sensor % (second controller)"),

        // Generic die sensors. "die" and "dev" are the two families the hardware
        // distinguishes; which physical block each covers is not published, so
        // the name says no more than that.
        ("pmu tdie", "Processor die %"),
        ("pmu tdev", "Processor sensor %"),

        ("nand ch", "Storage — NAND channel %"),
        ("nand", "Storage"),
        ("gas gauge battery", "Battery"),
        ("batt", "Battery %"),
        ("charger", "Charger"),
        ("airport", "Wi-Fi"),
        ("wifi", "Wi-Fi"),
        ("display", "Display %"),
        ("ambient", "Ambient %"),
    ]

    public static func name(for sensor: TemperatureSensor) -> Named {
        let display = friendlyName(for: sensor.name)
        return Named(
            display: display ?? sensor.name,
            raw: sensor.name,
            smcKey: sensor.smcKey,
            isVerbatim: display == nil
        )
    }

    /// - Returns: a readable name, or nil when nothing is recognised and the raw
    ///   name should stand as-is.
    public static func friendlyName(for rawName: String) -> String? {
        let lower = rawName.lowercased()
        guard let rule = rules.first(where: { lower.contains($0.fragment) }) else {
            return nil
        }

        guard rule.template.contains("%") else { return rule.template }
        let index = trailingIndex(of: rawName)
        return rule.template.replacingOccurrences(
            of: "%", with: index.map(String.init) ?? ""
        )
        .replacingOccurrences(of: "  ", with: " ")
        .trimmingCharacters(in: .whitespaces)
    }

    /// The index a sensor name carries.
    ///
    /// Usually trailing — `PMU tdie12` → 12, `pACC MTR Temp Sensor3` → 3 — but
    /// not always: `NAND CH0 temp` puts it in the middle, which a trailing-only
    /// search misses, producing "Storage — NAND channel" with no number. So this
    /// takes the last run of digits anywhere in the name.
    private static func trailingIndex(of name: String) -> Int? {
        var digits = ""
        var current = ""
        for character in name {
            if character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                digits = current
                current = ""
            }
        }
        if !current.isEmpty { digits = current }
        return digits.isEmpty ? nil : Int(digits)
    }
}
