import Foundation
import CIOHIDShim

/// How confident we are that a sensor reflects CPU die temperature.
///
/// Sensor names differ across chip generations and variants, and no single list
/// can be complete for hardware that does not exist yet. Rather than guessing,
/// sensors are sorted into tiers and the best available tier wins.
public enum SensorTier: Int, Comparable, CustomStringConvertible, Sendable {
    /// Per-core cluster sensors (`pACC`/`eACC`). Documented for M-series, but
    /// absent entirely on some hardware — an M4 Pro (Mac16,8) exposes none.
    case coreCluster = 1
    /// Whole-SoC or PMU die sensors. This is what an M4 Pro actually provides
    /// (`PMU tdie1`–`tdie14`), so tier 2 is a normal outcome, not a degraded one.
    case socDie = 2
    /// Not identifiable as CPU, but not a known non-CPU sensor either.
    case unclassified = 3
    /// Known not to be a CPU sensor (battery, storage, ambient...).
    case excluded = 4

    public static func < (a: SensorTier, b: SensorTier) -> Bool { a.rawValue < b.rawValue }

    public var description: String {
        switch self {
        case .coreCluster:  return "core-cluster"
        case .socDie:       return "soc-die"
        case .unclassified: return "unclassified"
        case .excluded:     return "excluded"
        }
    }
}

public struct TemperatureSensor: Sendable {
    /// The name the hardware reports, e.g. `PMU tdie1`.
    public let name: String
    public let celsius: Double
    public let tier: SensorTier
    /// SMC key backing this sensor, e.g. `TP1b`. Nil when unavailable.
    public let smcKey: String?

    public init(name: String, celsius: Double, tier: SensorTier, smcKey: String? = nil) {
        self.name = name
        self.celsius = celsius
        self.tier = tier
        self.smcKey = smcKey
    }
}

/// Reads Apple Silicon temperature sensors through IOKit's HID event system.
///
/// All failures are reported as "no readings" rather than thrown: losing sensors
/// is an expected state that the failsafe reacts to, not an error to crash on.
public final class TemperatureReader: @unchecked Sendable {

    /// Name fragments that identify CPU sensors, most specific tier first.
    /// Adding support for new hardware should mean adding a string here.
    ///
    /// Two naming schemes exist and both must be covered. M1 and M2 expose a
    /// named family (`pACC MTR Temp Sensor0`, `eACC…`, `SOC MTR…`,
    /// `PMGR SOC Die Temp Sensor…`). M4 and later expose only generic die
    /// sensors (`PMU tdie1`, and on multi-die parts `PMU2 tdie1`). Where exactly
    /// the change happened is not publicly documented, so neither scheme is
    /// assumed — whichever is present wins.
    private static let tierPatterns: [(tier: SensorTier, fragments: [String])] = [
        (.coreCluster, ["acc mtr temp"]),
        (.socDie, [
            "soc mtr temp", "soc mtr",
            "pmgr soc die",          // M1-era whole-SoC die sensor
            "tdie",                  // matches PMU tdie1 and PMU2 tdie1 alike
        ]),
    ]

    /// Sensors that must never feed the failsafe. Checked before the tiers
    /// above, so a fallback reading never silently reports something else as CPU.
    ///
    /// Two of these matter more than the obvious ones:
    ///
    /// - `tcal` is a static calibration constant, not a measurement. It reads
    ///   51.85 on every Apple Silicon machine regardless of load — about 15 °C
    ///   above the real die sensors on an idle M4 Pro. Treating it as a CPU
    ///   reading would inflate every value and could trip the failsafe early.
    /// - `tdev` reads garbage: about −21.7 on M1 and around −9201 on M4 Pro.
    ///   The plausible-range check below happens to drop both, but −21.7 sits
    ///   barely outside it, so hardware reporting a merely *odd* value rather
    ///   than an absurd one would slip through and corrupt the failsafe's input.
    ///   Excluding the family by name does not rely on the range check.
    ///
    /// Exclusion here only affects what the failsafe watches. These sensors are
    /// still listed in the Sensors view — see `SensorCategory`.
    private static let excludedFragments = [
        "batt", "nand", "charger", "ambient", "gas gauge",
        "tcal", "tdev", "display", "airport", "wifi", "camera", "speaker",
    ]

    /// Sensor names that are not real readings.
    private static let ignoredNames: Set<String> = ["noname", ""]

    private var client: CIOHIDEventSystemClientRef?

    /// Everything about the sensors on this machine that cannot change between
    /// readings, discovered once and reused.
    ///
    /// This is for robustness, not speed, and the measurement is worth recording
    /// so nobody re-litigates it: a full `readAll()` is 85 ms on a Mac16,8 with
    /// 52 sensors, and caching the enumeration changed that by nothing
    /// measurable. The cost is ~1.6 ms per `IOHIDServiceClientCopyEvent`, 52
    /// times — reading the sensors, not finding them. It cannot be cut by
    /// collapsing the list either: sensors sharing a name are *not* duplicates.
    /// On this machine `PMU tdie1` appears three times with values that differ
    /// by up to 0.2 °C, and `gas gauge battery` appears six times under six
    /// distinct SMC keys, all six of which feed the failsafe's battery rule.
    ///
    /// What this does buy: a sensor's name, SMC key and tier are properties of
    /// the hardware, so re-deriving them every two seconds was pointless work;
    /// and a transient `IOHIDEventSystemClientCopyServices` failure — long
    /// documented here as something that happens on any Mac — no longer empties
    /// the reading. The temperatures themselves are always read fresh.
    ///
    /// The `services` array is held deliberately. `IOHIDEventSystemClientCopyServices`
    /// is a `Copy` function and the array owns the service references, so
    /// keeping the references means keeping the array that owns them.
    private struct Catalogue {
        let services: CFArray
        let entries: [Entry]
        let discoveredAt: Date

        struct Entry {
            let service: CIOHIDServiceClientRef
            let name: String
            let tier: SensorTier
            let smcKey: String?
        }
    }

    private var catalogue: Catalogue?

    /// How often the sensor list is rebuilt from scratch.
    ///
    /// Not never. Hard rule 6 says hardware is read at runtime rather than
    /// assumed, and that applies to a list cached for the life of the process
    /// just as much as to a constant in the source: a sensor whose name failed
    /// to copy on the first pass would otherwise be missing forever. A minute
    /// is 1/30th of the old cost and still re-reads everything regularly.
    private static let rediscoverInterval: TimeInterval = 60

    /// The HID client is not safe to drive from two threads at once.
    private let lock = NSLock()

    public init() {
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)

        guard let client else { return }
        let matching: [String: Any] = [
            "PrimaryUsagePage": kCIOHIDPageAppleVendor,
            "PrimaryUsage": kCIOHIDUsageAppleVendorTemperatureSensor,
        ]
        IOHIDEventSystemClientSetMatching(client, matching as CFDictionary)
    }

    deinit {
        CIOHIDReleaseClient(client)
    }

    /// True when the sensor interface is usable at all.
    public var isAvailable: Bool { client != nil }

    private static func fourCharCode(_ value: UInt32) -> String? {
        let bytes = [
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff),
        ]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func classify(_ name: String) -> SensorTier {
        let lower = name.lowercased()
        if excludedFragments.contains(where: lower.contains) { return .excluded }
        for entry in tierPatterns where entry.fragments.contains(where: lower.contains) {
            return entry.tier
        }
        return .unclassified
    }

    /// Every temperature sensor currently readable, with its classification.
    public func readAll() -> [TemperatureSensor] {
        lock.lock()
        defer { lock.unlock() }

        guard let entries = currentCatalogue()?.entries else { return [] }

        var sensors: [TemperatureSensor] = []
        sensors.reserveCapacity(entries.count)

        for entry in entries {
            var celsius: Double = 0
            guard CIOHIDReadTemperature(entry.service, &celsius) == 1 else { continue }

            // Readings outside this range mean the sensor is not reporting a real
            // die temperature; including them would corrupt the hottest-CPU value.
            guard celsius > -20, celsius < 150 else { continue }

            sensors.append(
                TemperatureSensor(
                    name: entry.name,
                    celsius: celsius,
                    tier: entry.tier,
                    smcKey: entry.smcKey
                )
            )
        }
        // The catalogue is built sorted, so the output already is.
        return sensors
    }

    /// The sensor catalogue, rebuilt if it is missing or stale.
    ///
    /// Must be called with `lock` held. A rebuild that finds nothing leaves the
    /// previous catalogue in place rather than replacing it with an empty one:
    /// `IOHIDEventSystemClientCopyServices` returning nothing is a transient
    /// failure this project has documented for years, and discarding a working
    /// list because of one is how a reader that was fine becomes a reader that
    /// reports no sensors.
    private func currentCatalogue() -> Catalogue? {
        if let catalogue,
           Date().timeIntervalSince(catalogue.discoveredAt) < Self.rediscoverInterval {
            return catalogue
        }
        if let rebuilt = buildCatalogue() {
            catalogue = rebuilt
        }
        return catalogue
    }

    /// Must be called with `lock` held.
    private func buildCatalogue() -> Catalogue? {
        guard let client,
              let services = IOHIDEventSystemClientCopyServices(client)
        else { return nil }

        var entries: [Catalogue.Entry] = []
        let count = CFArrayGetCount(services)
        entries.reserveCapacity(count)

        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(services, i) else { continue }
            let service = CIOHIDServiceClientRef(raw)

            var nameBuffer = [CChar](repeating: 0, count: 256)
            guard CIOHIDCopySensorName(service, &nameBuffer, 256) == 1 else { continue }
            let name = String(cString: nameBuffer)

            // Services with no usable name are skipped above; this catches the
            // placeholder text some dumping tools substitute for a NULL product
            // name, in case it ever arrives as a real string.
            guard !Self.ignoredNames.contains(name.lowercased()) else { continue }

            // Catalogued on the strength of its name alone. Requiring a
            // successful first temperature read here would drop a sensor that
            // happened to be unreadable at that moment for the whole rediscover
            // interval, where the old per-poll code retried it two seconds
            // later. Read failures and out-of-range values are handled in
            // `readAll`, every poll, as before.
            let keyCode = CIOHIDCopySensorKey(service)
            entries.append(
                Catalogue.Entry(
                    service: service,
                    name: name,
                    tier: Self.classify(name),
                    smcKey: keyCode == 0 ? nil : Self.fourCharCode(keyCode)
                )
            )
        }

        guard !entries.isEmpty else { return nil }
        return Catalogue(
            services: services,
            entries: entries.sorted { $0.name < $1.name },
            discoveredAt: Date()
        )
    }

    /// Hottest CPU temperature, using the most specific tier that matched.
    ///
    /// Returns nil when nothing usable was found. Callers must treat nil as
    /// "temperature unknown" — the failsafe forces fans back to automatic in
    /// that case rather than holding a manual speed blind.
    public func hottestCPU(from sensors: [TemperatureSensor]? = nil) -> TemperatureSensor? {
        let all = sensors ?? readAll()
        for tier in [SensorTier.coreCluster, .socDie, .unclassified] {
            let matches = all.filter { $0.tier == tier }
            if let hottest = matches.max(by: { $0.celsius < $1.celsius }) {
                return hottest
            }
        }
        return nil
    }
}
