import Foundation

/// A single fan as reported by the SMC.
///
/// Every field comes from the hardware. Nothing here is assumed from the
/// developer's machine — see SPEC.md "Portability rule".
public struct Fan: Identifiable, Equatable, Sendable {
    public let index: Int
    /// Current speed in RPM.
    public let actualRPM: Double
    /// Lowest speed this fan will accept. Not necessarily zero.
    public let minRPM: Double
    /// Highest speed this fan will accept.
    public let maxRPM: Double
    /// Speed the SMC is currently aiming for.
    public let targetRPM: Double
    /// Whether the SMC actually reported this fan's minimum and maximum.
    ///
    /// A missing limit key used to read as 0, which is indistinguishable from a
    /// fan that genuinely reports a floor of zero — and a floor of zero means a
    /// clamp that permits stopping the fan outright. The limits are advisory
    /// anyway (the SMC has been observed accepting targets outside them), so the
    /// clamp is the real protection and it cannot be built on a guess. A fan
    /// whose limits are unknown is reported, but never driven.
    public let limitsReported: Bool

    /// Whether the SMC actually reported this fan's mode.
    ///
    /// `?? 0` made an unreadable mode indistinguishable from a genuine 0, and
    /// that value was then cached as the automatic baseline and written back on
    /// every restore — restoring a mode the machine never had. Same reasoning as
    /// `limitsReported`.
    public let modeReported: Bool

    /// Raw value of `F{i}Md`.
    ///
    /// Mode semantics are not the documented 0 = auto / 1 = forced on Apple
    /// Silicon: an idle Mac16,8 (M4 Pro) reports 3 for both fans with nothing
    /// having written to the SMC. Because the value meaning "forced" cannot be
    /// known without performing a write, this is reported verbatim and no
    /// automatic/forced judgement is made until Phase 3 establishes it
    /// empirically. Do not compare it against 0.
    public let modeRaw: Double

    public var id: Int { index }

    public init(
        index: Int,
        actualRPM: Double,
        minRPM: Double,
        maxRPM: Double,
        targetRPM: Double,
        modeRaw: Double,
        limitsReported: Bool = true,
        modeReported: Bool = true
    ) {
        self.index = index
        self.actualRPM = actualRPM
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.targetRPM = targetRPM
        self.modeRaw = modeRaw
        self.limitsReported = limitsReported
        self.modeReported = modeReported
    }

    /// Where `rpm` sits in this fan's range, 0...1. Presets are stored as
    /// percentages so they mean the same thing on hardware with different ranges.
    public func percent(forRPM rpm: Double) -> Double {
        guard maxRPM > minRPM else { return 0 }
        return ((rpm - minRPM) / (maxRPM - minRPM)).clamped(to: 0...1)
    }

    /// Resolve a 0...1 preset percentage to an RPM for this specific fan.
    public func rpm(forPercent percent: Double) -> Double {
        let p = percent.clamped(to: 0...1)
        return (minRPM + (maxRPM - minRPM) * p).rounded()
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

public struct FanReader: Sendable {
    private let smc: SMCConnection

    public init(smc: SMCConnection) {
        self.smc = smc
    }

    /// Number of fans this Mac reports. Zero is a valid, supported answer —
    /// fanless Macs run the app in monitoring-only mode.
    public func fanCount() -> Int {
        guard let count = smc.readNumber("FNum") else { return 0 }
        return Int(count.clamped(to: 0...16))
    }

    /// Upper bound on fan indices to probe. No Mac comes close to this; it exists
    /// so a machine reporting a nonsense `FNum` cannot spin here indefinitely.
    public static let maximumFanIndex = 16

    /// Read every fan. Returns an empty array on fanless hardware.
    ///
    /// `FNum` is a count, not the highest index in use. Scanning only
    /// `0..<FNum` would miss a fan on hardware that numbers them with a gap, so
    /// this keeps looking until it has found that many or run out of plausible
    /// indices. In the common case — contiguous from zero — it stops as soon as
    /// it has them all.
    public func readAll() -> [Fan] {
        let expected = fanCount()
        guard expected > 0 else { return [] }

        var found: [Fan] = []
        var index = 0
        while found.count < expected && index < Self.maximumFanIndex {
            if let fan = read(index: index) { found.append(fan) }
            index += 1
        }
        return found
    }

    /// Read one fan, or nil if its keys are missing.
    public func read(index: Int) -> Fan? {
        // A fan without a readable current speed is not usable.
        guard let actual = smc.readNumber("F\(index)Ac") else { return nil }

        // Tracked rather than defaulted: `?? 0` turned an unreadable limit into a
        // legitimate-looking floor of zero, which would let a fan be commanded to
        // a full stop on hardware that simply does not publish the key.
        let reportedMin = smc.readNumber("F\(index)Mn")
        let reportedMax = smc.readNumber("F\(index)Mx")
        let minRPM = reportedMin ?? 0
        let maxRPM = reportedMax ?? 0
        let target = smc.readNumber("F\(index)Tg") ?? actual
        // Mode is spelled lowercase on some hardware; try both before giving up.
        let reportedMode = smc.readNumber("F\(index)Md") ?? smc.readNumber("F\(index)md")
        let mode = reportedMode ?? 0

        return Fan(
            index: index,
            actualRPM: actual,
            minRPM: minRPM,
            maxRPM: maxRPM,
            targetRPM: target,
            modeRaw: mode,
            limitsReported: reportedMin != nil && reportedMax != nil,
            modeReported: reportedMode != nil
        )
    }

    /// Average speed across all fans, for the menu bar. Nil when there are no fans.
    public func averageRPM(_ fans: [Fan]) -> Double? {
        guard !fans.isEmpty else { return nil }
        return fans.reduce(0) { $0 + $1.actualRPM } / Double(fans.count)
    }
}
