import Foundation

/// What part of the machine a temperature sensor is measuring.
///
/// This is for **display only**. It is deliberately separate from `SensorTier`,
/// which decides what counts as the CPU reading the failsafe acts on: grouping
/// a sensor into the wrong heading is cosmetic, while misclassifying one as CPU
/// is a safety matter. Keeping them apart means adding a nicer label here can
/// never change what the failsafe watches.
///
/// Unrecognised sensors land in `.other` and are still shown. On hardware nobody
/// has catalogued, an honest "Other" heading beats hiding readings or inventing
/// a category for them.
public enum SensorCategory: Int, CaseIterable, Sendable, Equatable {
    case processor
    case graphics
    case neuralEngine
    case imageProcessor
    case memory
    case storage
    case battery
    case power
    case display
    case wireless
    case other

    public var title: String {
        switch self {
        case .processor:      return "Processor"
        case .graphics:       return "Graphics"
        case .neuralEngine:   return "Neural Engine"
        case .imageProcessor: return "Image Processor"
        case .memory:         return "Memory"
        case .storage:        return "Storage"
        case .battery:        return "Battery"
        case .power:          return "Power"
        case .display:        return "Display"
        case .wireless:       return "Wireless"
        case .other:          return "Other"
        }
    }

    /// SF Symbol for the group heading.
    public var symbol: String {
        switch self {
        case .processor:      return "cpu"
        case .graphics:       return "display.trianglebadge.exclamationmark"
        case .neuralEngine:   return "brain"
        case .imageProcessor: return "camera.aperture"
        case .memory:         return "memorychip"
        case .storage:        return "internaldrive"
        case .battery:        return "battery.100"
        case .power:          return "bolt"
        case .display:        return "display"
        case .wireless:       return "wifi"
        case .other:          return "thermometer.medium"
        }
    }

    /// Name fragments per category, checked in the order listed here.
    ///
    /// Order matters: "GPU MTR Temp Sensor0" would also match the processor
    /// family's "mtr", so the more specific groups come first.
    private static let patterns: [(category: SensorCategory, fragments: [String])] = [
        (.graphics, ["gpu"]),
        (.neuralEngine, ["ane mtr", "ane temp", "neural"]),
        (.imageProcessor, ["isp mtr", "isp temp", "camera"]),
        (.storage, ["nand", "ssd", "nvme"]),
        (.battery, ["gas gauge", "batt"]),
        (.power, ["charger", "tcal", "pmic", "vrm", "pwr", "power"]),
        (.display, ["display", "lcd", "backlight"]),
        (.wireless, ["airport", "wifi", "wlan", "bluetooth", "btrs"]),
        (.memory, ["dram", "lpddr", "dimm"]),
        // Last of the specific groups: several processor sensors are named only
        // "PMU tdieN", which carries no clue beyond being a die sensor.
        (.processor, [
            "acc mtr", "soc mtr", "pmgr soc die", "cpu", "tdie", "tdev", "soc",
            // M1 Pro through M2 Ultra also expose "PMU TP0s", "PMU TP1g" and
            // similar, whose meaning is not published. They belong with the
            // processor rather than in "Other", even though they cannot be
            // given a meaningful name.
            "pmu ", "pmu2 ",
        ]),
    ]

    public static func classify(_ name: String) -> SensorCategory {
        let lower = name.lowercased()
        for entry in patterns where entry.fragments.contains(where: lower.contains) {
            return entry.category
        }
        return .other
    }
}

extension TemperatureSensor {
    public var category: SensorCategory { SensorCategory.classify(name) }
}

/// One row in the sensor list: several services can report the same sensor name,
/// so readings are collapsed per name.
public struct SensorReading: Identifiable, Sendable {
    /// Name the hardware reported, e.g. `PMU tdie1`.
    public let name: String
    /// Readable form, e.g. "Processor die 1".
    public let displayName: String
    /// SMC key behind it, e.g. `TP1b`, when known.
    public let smcKey: String?
    /// True when nothing was recognised and `displayName` is the raw name.
    public let isVerbatim: Bool
    public let category: SensorCategory
    /// Hottest reading among services reporting this name.
    public let celsius: Double
    /// How many services reported it, so a machine exposing each sensor three
    /// times does not look like it has three times as many sensors.
    public let sourceCount: Int

    public var id: String { smcKey ?? name }

    /// Collapse raw sensors into one row per physical sensor, hottest reading
    /// winning.
    ///
    /// Grouped by **SMC key**, not by display name. Several services report the
    /// same sensor — `PMU tdie1` appears three times, all keyed `TP1b`, and
    /// those are genuine duplicates. But a Mac also reports four *different*
    /// battery sensors all named "gas gauge battery", keyed `TG0B`, `TG1B`,
    /// `TG2B` and `TG0H`. Grouping by name merged those four into one and hid
    /// three real readings.
    public static func group(_ sensors: [TemperatureSensor]) -> [SensorReading] {
        var hottest: [String: (sensor: TemperatureSensor, celsius: Double, count: Int)] = [:]

        for sensor in sensors {
            let identity = sensor.smcKey ?? sensor.name
            if let existing = hottest[identity] {
                hottest[identity] = (
                    existing.sensor,
                    max(existing.celsius, sensor.celsius),
                    existing.count + 1
                )
            } else {
                hottest[identity] = (sensor, sensor.celsius, 1)
            }
        }

        return hottest
            .map { entry -> SensorReading in
                let named = SensorNaming.name(for: entry.value.sensor)
                return SensorReading(
                    name: entry.value.sensor.name,
                    displayName: named.display,
                    smcKey: named.smcKey,
                    isVerbatim: named.isVerbatim,
                    category: entry.value.sensor.category,
                    celsius: entry.value.celsius,
                    sourceCount: entry.value.count
                )
            }
            // Category first, then readable name using a natural ordering so
            // "Processor die 2" precedes "Processor die 10" rather than sorting
            // as text and putting 10 before 2.
            .sorted { first, second in
                if first.category != second.category {
                    return first.category.rawValue < second.category.rawValue
                }
                let byName = first.displayName.localizedStandardCompare(second.displayName)
                if byName != .orderedSame { return byName == .orderedAscending }
                // Same readable name, different sensors: order by key so the
                // rows do not reshuffle as temperatures change.
                return (first.smcKey ?? "") < (second.smcKey ?? "")
            }
    }

    /// Grouped by category, in category order, skipping empty groups.
    public static func byCategory(
        _ sensors: [TemperatureSensor]
    ) -> [(category: SensorCategory, readings: [SensorReading])] {
        let all = group(sensors)
        return SensorCategory.allCases.compactMap { category in
            let matching = all.filter { $0.category == category }
            return matching.isEmpty ? nil : (category, matching)
        }
    }
}
