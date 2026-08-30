import Foundation
import SMCKit

/// A named fan speed, stored as a fraction of each fan's own range.
///
/// Percentages rather than RPM because a preset has to mean the same thing on
/// hardware it was not created on: "35%" is sensible whether a fan tops out at
/// 3000 or 7826 rpm, while "2500 rpm" is meaningless on the first and timid on
/// the second. This is also what makes settings portable between Macs.
struct FanPreset: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// 0 = the fan's minimum, 1 = its maximum.
    var percent: Double
    /// Built-ins can be edited but not deleted, so the list can never be emptied
    /// into a state with nothing to select.
    var isBuiltIn: Bool

    init(id: UUID = UUID(), name: String, percent: Double, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.percent = min(max(percent, 0), 1)
        self.isBuiltIn = isBuiltIn
    }

    /// What this preset means for one specific fan.
    func resolvedRPM(for fan: Fan) -> Double { fan.rpm(forPercent: percent) }

    /// Range this preset spans across all fans, for display.
    func resolvedDescription(for fans: [Fan]) -> String {
        let values = fans.map { Int(resolvedRPM(for: $0)) }
        guard let low = values.min(), let high = values.max() else {
            return "\(Int(percent * 100))%"
        }
        return low == high ? "\(low) rpm" : "\(low)–\(high) rpm"
    }

    /// The name this preset shipped with before it was shortened to "Cool".
    /// Kept only so saved copies can be migrated; see `PresetStore.load`.
    static let previousCoolName = "Cool Lap"

    // Stable ids so a preset selected before an update stays selected after one.
    static let quietID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let coolID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let maxID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    static var builtIns: [FanPreset] {
        [
            FanPreset(id: quietID, name: "Quiet", percent: 0, isBuiltIn: true),
            FanPreset(id: coolID, name: "Cool", percent: 0.35, isBuiltIn: true),
            FanPreset(id: maxID, name: "Max", percent: 1, isBuiltIn: true),
        ]
    }
}

/// Stores presets in `UserDefaults` as JSON.
@MainActor
final class PresetStore: ObservableObject {
    @Published private(set) var presets: [FanPreset] = []

    private let defaultsKey = "fanPresets"

    init() { load() }

    func preset(id: UUID?) -> FanPreset? {
        guard let id else { return nil }
        return presets.first { $0.id == id }
    }

    func add(name: String = "New preset", percent: Double = 0.5) -> FanPreset {
        let preset = FanPreset(name: name, percent: percent)
        presets.append(preset)
        save()
        return preset
    }

    func update(_ preset: FanPreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = preset
        save()
    }

    /// Built-ins are never removed, so there is always something selectable.
    func delete(_ preset: FanPreset) {
        guard !preset.isBuiltIn else { return }
        presets.removeAll { $0.id == preset.id }
        save()
    }

    func resetToDefaults() {
        presets = FanPreset.builtIns
        save()
    }

    // MARK: Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode([FanPreset].self, from: data),
              !stored.isEmpty
        else {
            presets = FanPreset.builtIns
            return
        }

        // A built-in missing from stored data means this version added one; merge
        // it in rather than losing it, and keep the user's edits to the others.
        var merged = stored
        for builtIn in FanPreset.builtIns where !merged.contains(where: { $0.id == builtIn.id }) {
            merged.append(builtIn)
        }

        // "Cool Lap" was renamed to "Cool". Anyone who saved presets under the
        // old build still has the old label, so update it — but only if it is
        // still the shipped name. A preset the user renamed themselves is theirs.
        var didMigrate = false
        for index in merged.indices
        where merged[index].id == FanPreset.coolID
            && merged[index].name == FanPreset.previousCoolName {
            merged[index].name = "Cool"
            didMigrate = true
        }

        presets = merged
        if didMigrate { save() }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
