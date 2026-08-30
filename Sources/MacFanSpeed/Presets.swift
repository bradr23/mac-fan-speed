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
    ///
    /// For a curve profile this mirrors the curve rather than driving it — see
    /// `FanCurve.mirroredPercent`. It is still written so that a build predating
    /// curves reads a sensible fixed speed instead of whatever happened to be in
    /// the struct.
    var percent: Double
    /// Built-ins can be edited but not deleted, so the list can never be emptied
    /// into a state with nothing to select.
    var isBuiltIn: Bool
    /// nil means a fixed-speed profile, which is every profile that existed
    /// before curves.
    ///
    /// An optional field rather than an enum, deliberately. `PresetStore.load`
    /// treats any decode failure as "nothing saved" and falls back to the
    /// built-ins, so a schema change that old data cannot satisfy would silently
    /// delete every preset a user had. Swift synthesises `decodeIfPresent` for
    /// optionals, so legacy JSON decodes cleanly and `percent` stays readable by
    /// older builds in both directions.
    var curve: FanCurve?

    enum Kind { case fixed, curve }
    var kind: Kind { curve == nil ? .fixed : .curve }

    init(
        id: UUID = UUID(),
        name: String,
        percent: Double,
        isBuiltIn: Bool = false,
        curve: FanCurve? = nil
    ) {
        self.id = id
        self.name = name
        self.percent = min(max(percent, 0), 1)
        self.isBuiltIn = isBuiltIn
        self.curve = curve
    }

    private enum CodingKeys: String, CodingKey { case id, name, percent, isBuiltIn, curve }

    /// Decoded defensively, for two reasons the synthesized version gets wrong.
    ///
    /// A malformed curve must not take the whole preset list with it.
    /// `PresetStore.load` treats any decode failure as "nothing saved" and falls
    /// back to the built-ins, so one bad control point in one profile would
    /// silently delete every preset the user had ever made. A curve that cannot
    /// be read is dropped to nil — the profile survives as a fixed speed.
    ///
    /// And `percent` is clamped here as well as in the memberwise init, which
    /// decoding otherwise bypasses entirely. `CurvePoint` and `FanCurve` both
    /// re-normalise on decode for the same reason; this type was the one in the
    /// file skipping it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        let storedPercent = try container.decode(Double.self, forKey: .percent)
        percent = storedPercent.isFinite ? min(max(storedPercent, 0), 1) : 0
        isBuiltIn = try container.decode(Bool.self, forKey: .isBuiltIn)
        curve = try? container.decodeIfPresent(FanCurve.self, forKey: .curve)
    }

    /// Turn a fixed profile into a curve, or the reverse.
    ///
    /// Switching to a curve starts from a flat one at the profile's current
    /// speed, so the machine does not change behaviour the instant the toggle is
    /// flipped — the user then edits from a known state.
    mutating func setUsesCurve(_ usesCurve: Bool) {
        guard usesCurve != (curve != nil) else { return }
        if usesCurve {
            curve = FanCurve(points: [
                CurvePoint(celsius: 40, percent: percent),
                CurvePoint(celsius: 85, percent: max(percent, 0.9)),
            ])
            percent = curve?.mirroredPercent ?? percent
        } else {
            percent = curve?.mirroredPercent ?? percent
            curve = nil
        }
    }

    /// Keep `percent` consistent with the curve after an edit.
    mutating func syncMirroredPercent() {
        if let curve { percent = curve.mirroredPercent }
    }

    /// What this preset means for one specific fan.
    func resolvedRPM(for fan: Fan) -> Double { fan.rpm(forPercent: percent) }

    /// Range this preset spans across all fans, for display.
    func resolvedDescription(for fans: [Fan]) -> String {
        if let curve {
            let low = Int(curve.minimumPercent * 100)
            let high = Int(curve.maximumPercent * 100)
            return low == high ? "\(low)% curve" : "\(low)–\(high)% curve"
        }
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
    static let smartID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

    static var builtIns: [FanPreset] {
        [
            FanPreset(id: quietID, name: "Quiet", percent: 0, isBuiltIn: true),
            FanPreset(id: coolID, name: "Cool", percent: 0.35, isBuiltIn: true),
            // The shipped curve profile. Added as a fourth built-in rather than
            // by converting an existing one, so upgrading changes nothing about
            // what Quiet, Cool and Max already do.
            FanPreset(
                id: smartID, name: "Smart",
                percent: FanCurve.defaultCurve.mirroredPercent,
                isBuiltIn: true, curve: .defaultCurve
            ),
            FanPreset(id: maxID, name: "Max", percent: 1, isBuiltIn: true),
        ]
    }
}

/// Stores presets in `UserDefaults` as JSON.
@MainActor
final class PresetStore: ObservableObject {
    @Published private(set) var presets: [FanPreset] = []

    private let defaultsKey = "fanPresets"
    private let defaults: UserDefaults

    /// Injectable so tests can exercise migration against a scratch domain
    /// rather than the developer's live settings.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

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
        var updated = preset
        // Keep the fixed speed in step with the curve, so a build that predates
        // curves still reads something sensible from the same record.
        updated.syncMirroredPercent()
        presets[index] = updated
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
        guard let data = defaults.data(forKey: defaultsKey),
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
        defaults.set(data, forKey: defaultsKey)
    }
}
