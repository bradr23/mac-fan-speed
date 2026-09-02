import Foundation

/// The remembered automatic-mode baseline: what "macOS was in charge" looked
/// like before this project wrote anything.
///
/// It exists because the release path needs a value the *live* fan modes can no
/// longer supply. Once the fans are forced, every mode read says "forced", so a
/// daemon that restarts mid-session — replaced by `install-helper.sh`,
/// kickstarted, or crashed — has nothing to restore from unless its predecessor
/// wrote it down.
///
/// Extracted from `FanController` for the same reason `ThermalWatchState` was
/// extracted from the daemon: the file's rules decide whether fans can ever be
/// handed back, and none of them need an SMC handle to be wrong. Every defect
/// review found here was a decision at this layer.
public struct BaselineStore {

    /// Root-owned, because only root can force a fan in the first place. A
    /// non-root process (`fanctl` reading) simply finds it unreadable and falls
    /// back to observation, which is all it could do anyway.
    public static let defaultURL =
        URL(fileURLWithPath: "/var/db/io.github.bradr23.MacFanSpeed.baseline.json")

    /// On-disk shape. The boot stamp is what makes a stale file safe.
    struct Payload: Codable {
        var bootTime: Double?
        var fans: [String: Double]
    }

    private let url: URL?
    private let bootTime: () -> Double?

    /// Read once per process; later calls report the same answer.
    private var loaded = false
    private var recovered: [Int: Double] = [:]

    /// What was last written, so the file is only rewritten when it changed.
    private var lastWritten: [Int: Double]?

    public init(
        url: URL?,
        bootTime: @escaping () -> Double? = BaselineStore.currentBootTime
    ) {
        self.url = url
        self.bootTime = bootTime
    }

    /// Seconds since the epoch at which this boot began, or nil if it cannot be
    /// read.
    public static func currentBootTime() -> Double? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return nil }
        return Double(tv.tv_sec)
    }

    /// Entries worth remembering.
    ///
    /// Two values are dropped rather than stored, both because they can only come
    /// from a capture that read a fan mid-transition, and because keeping one
    /// turns a transient mis-read into a permanent one: the file outranks live
    /// observation, and a restore that writes the wrong mode never succeeds, so
    /// nothing ever deletes the file that caused it.
    ///
    /// - `forcedModeValue` — a fan being held, not resting.
    /// - `midHandshakeModeValue` — the value the mode passes through while the
    ///   firmware takes the fans back. The daemon's own comment records a
    ///   previous run writing exactly this down as "automatic", and hard rule 3
    ///   forbids writing 0 back as a restore.
    ///
    /// This is deliberately narrower than it looks. It filters what is *written
    /// down for the next process*, never what this one captured: a machine that
    /// genuinely rests at either value still restores correctly from its
    /// in-memory baseline. All it gives up is crash recovery on such hardware,
    /// where clearing `Ftst` is the release mechanism anyway.
    static func usableEntries(_ fans: [Int: Double]) -> [Int: Double] {
        fans.filter { entry in
            entry.value.isFinite
                && abs(entry.value - FanController.forcedModeValue) >= 0.001
                && abs(entry.value - FanController.midHandshakeModeValue) >= 0.001
        }
    }

    /// Whether the file supplied anything usable this run.
    ///
    /// Only meaningful after `load()`. A daemon that recovers a baseline is by
    /// definition the successor of one that took the fans over, which is the
    /// closest thing to positive evidence available on hardware with no `Ftst`.
    public var recoveredAnything: Bool { !recovered.isEmpty }

    /// Whatever the file has to offer, or empty.
    public mutating func load() -> [Int: Double] {
        if loaded { return recovered }
        loaded = true

        guard let url, let data = try? Data(contentsOf: url) else { return [:] }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            clear()
            return [:]
        }

        // A file left by an earlier boot is not evidence about this one. The
        // firmware owns the fans across a restart, so the live modes are the
        // ground truth then and the file can only mislead. Only a definite
        // mismatch discards it — a machine where `kern.boottime` cannot be read
        // keeps whatever it recorded.
        if let written = payload.bootTime, let now = bootTime(), abs(written - now) > 1 {
            clear()
            return [:]
        }

        var parsed: [Int: Double] = [:]
        for (key, value) in payload.fans {
            guard let index = Int(key) else { continue }
            parsed[index] = value
        }
        recovered = Self.usableEntries(parsed)
        if recovered.isEmpty { clear() }
        return recovered
    }

    /// Remember the baseline before the first write.
    ///
    /// Best effort: a machine that cannot write the file is no worse off than it
    /// was before this existed. Skipped entirely when nothing changed — the app
    /// re-sends every fan's target every two seconds as a watchdog heartbeat, and
    /// the baseline cannot change while control is held, so writing on each one
    /// was tens of thousands of atomic rewrites a day on the same serial queue
    /// the daemon's thermal watch runs on.
    public mutating func save(_ baseline: [Int: Double]) {
        guard let url, lastWritten != baseline else { return }

        let usable = Self.usableEntries(baseline)
        guard !usable.isEmpty else { return }

        let payload = Payload(
            bootTime: bootTime(),
            fans: Dictionary(uniqueKeysWithValues: usable.map { (String($0.key), $0.value) })
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        lastWritten = baseline
    }

    /// Forget the remembered baseline, so the next run observes fresh rather
    /// than trusting a value that may since have changed.
    public mutating func clear() {
        lastWritten = nil
        recovered = [:]
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
