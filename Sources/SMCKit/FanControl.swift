import Foundation

/// The only SMC fields this project may ever write.
///
/// The write entry point takes one of these plus a fan index and builds the key
/// itself, so there is no code path that can name an arbitrary SMC key. This is
/// the structural half of SPEC.md safety rule 1; the clamping in `FanController`
/// is the other half.
public enum FanWritableField {
    case mode    // F{i}Md
    case target  // F{i}Tg
    /// `Ftst` — a single global key, not per-fan; the index is ignored.
    ///
    /// From the M3 generation onward, `thermalmonitord` holds the fans in mode 3
    /// and the firmware refuses writes to `F{i}Md` with error 0x82 (130). Setting
    /// `Ftst` to 1 makes the firmware yield manual control; it must be returned
    /// to 0 afterwards or thermal management stays handed over.
    case testUnlock

    func key(index: Int) -> String {
        switch self {
        case .mode:       return "F\(index)Md"
        case .target:     return "F\(index)Tg"
        case .testUnlock: return "Ftst"
        }
    }

    /// Alternate spelling to try when `key(index:)` is not present.
    ///
    /// The mode key is reported as lowercase `F%dmd` on some newer silicon.
    /// That is a single unconfirmed report, so it is treated as a fallback
    /// rather than a branch: the documented name is tried first and this is
    /// used only if the SMC says it does not exist.
    func alternateKey(index: Int) -> String? {
        switch self {
        case .mode:       return "F\(index)md"
        case .target:     return nil
        case .testUnlock: return nil
        }
    }
}

public enum FanControlError: Error, CustomStringConvertible {
    case notRoot
    case invalidFanIndex(Int)
    case unwritableType(String, String)
    case writeRejected(String, UInt8)
    case noBaselineRecorded(Int)
    case implausibleRange(Int, Double, Double)

    public var description: String {
        switch self {
        case .notRoot:
            return "Writing fan settings requires root. Re-run with sudo."
        case .invalidFanIndex(let i):
            return "Fan index \(i) does not exist on this Mac."
        case .unwritableType(let key, let type):
            return "SMC key '\(key)' has type '\(type)', which this tool will not write."
        case .writeRejected(let key, let code):
            return "The SMC rejected a write to '\(key)' (error \(code))."
        case .noBaselineRecorded(let i):
            return "No automatic-mode baseline recorded for fan \(i); refusing to guess a value."
        case .implausibleRange(let i, let low, let high):
            return "Fan \(i) reports an implausible range (\(Int(low))–\(Int(high)) rpm); "
                 + "refusing to drive it."
        }
    }
}

/// Manual fan control.
///
/// Restoring automatic control writes back the mode value each fan reported
/// *before* anything was written to it, rather than a hardcoded constant. The
/// documented 0 = auto / 1 = forced convention does not hold on Apple Silicon —
/// an untouched M4 Pro reports 3 — so the only trustworthy "automatic" value is
/// the one the machine itself was using. See SPEC.md "Fan mode semantics".
public final class FanController: @unchecked Sendable {

    /// Value written to `F{i}Md` to take manual control.
    ///
    /// This is the documented convention and matches the MIT-licensed reference
    /// implementations. It has *not* been confirmed on hardware whose resting
    /// value is 3; `fanctl probe-mode` exists to establish that empirically, and
    /// every write is verified afterwards rather than assumed to have worked.
    public static let forcedModeValue: Double = 1

    /// How long to keep retrying the mode write after setting `Ftst`.
    ///
    /// The firmware does not yield at a fixed moment — `thermalmonitord` releases
    /// somewhere in a window of roughly 3–6 seconds, and a single attempt after a
    /// fixed sleep can miss it entirely. Retrying until it lands is what makes
    /// the unlock work.
    public static let unlockRetryWindow: TimeInterval = 12
    public static let unlockRetryInterval: TimeInterval = 0.25

    /// Restore runs when the firmware is already unlocked, so the write should
    /// land immediately. A shorter window keeps total recovery well inside the
    /// time a crashed app must be caught in, even with several fans.
    public static let restoreRetryWindow: TimeInterval = 4

    /// How long to wait for a written target to be reflected back.
    public static let targetVerifyWindow: TimeInterval = 2

    /// How long to wait for the firmware to take the fans back after `Ftst` is
    /// cleared. Observed to take longer than a couple of seconds.
    public static let reclaimWaitSeconds: TimeInterval = 10

    private let smc: SMCConnection
    private let fanReader: FanReader
    private let lock = NSLock()

    /// Mode value per fan before this process wrote anything.
    private var automaticBaseline: [Int: Double] = [:]

    /// Whether `Ftst` is currently set. Tracked so the unlock delay is paid once
    /// on entering manual control rather than on every target change.
    private var isUnlocked = false

    /// Whether this Mac has the firmware unlock key at all.
    ///
    /// `Ftst` appeared with the generation where `thermalmonitord` began holding
    /// the fans. Hardware without it accepts mode writes directly, and treating
    /// a missing key as a failure would break fan control entirely on those
    /// machines. nil means not yet determined.
    private var hasUnlockKey: Bool?

    public init(smc: SMCConnection) {
        self.smc = smc
        self.fanReader = FanReader(smc: smc)
    }

    public static var isRoot: Bool { geteuid() == 0 }

    /// Record each fan's resting mode so automatic control can be restored
    /// exactly. Must be called before any write; safe to call repeatedly, as it
    /// never overwrites a baseline already captured.
    @discardableResult
    public func captureBaseline() -> [Int: Double] {
        // A mode read while the firmware is yielded is not an automatic value.
        // `fanctl auto` runs as a fresh process that may start with the fans
        // already forced; recording mode 1 as "automatic" there made restore a
        // no-op and left the fans forced. Only values seen while the firmware
        // holds the fans are trustworthy.
        guard (unlockKeyValue() ?? 0) == 0 else { return automaticBaselineSnapshot() }

        lock.lock()
        defer { lock.unlock() }

        for fan in fanReader.readAll() where automaticBaseline[fan.index] == nil {
            automaticBaseline[fan.index] = fan.modeRaw
        }
        return automaticBaseline
    }

    private func automaticBaselineSnapshot() -> [Int: Double] {
        lock.lock()
        defer { lock.unlock() }
        return automaticBaseline
    }

    public func baseline(forFan index: Int) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return automaticBaseline[index]
    }

    /// Result of applying a target, so callers can report what actually happened
    /// instead of assuming the write took effect.
    public struct ApplyResult {
        public let requestedRPM: Double
        public let clampedRPM: Double
        public let readBackTarget: Double?
        public let readBackMode: Double?
        /// True when the SMC reports the target we asked for.
        public var targetAccepted: Bool {
            guard let readBackTarget else { return false }
            return abs(readBackTarget - clampedRPM) < 50
        }
        public var wasClamped: Bool { abs(requestedRPM - clampedRPM) >= 1 }
    }

    /// Force a fan to a target RPM, clamped to the range that fan reports.
    ///
    /// Always captures a baseline first, so automatic control can be restored
    /// even if the caller forgot to.
    @discardableResult
    public func setTarget(fanIndex: Int, rpm: Double) throws -> ApplyResult {
        guard Self.isRoot else { throw FanControlError.notRoot }

        captureBaseline()

        guard let fan = fanReader.read(index: fanIndex) else {
            throw FanControlError.invalidFanIndex(fanIndex)
        }

        // Clamp to this fan's own limits. Never trust a caller's range.
        //
        // These limits are advisory: the SMC has been observed accepting targets
        // outside them, driving fans to a complete stop below the reported
        // minimum. The clamp here is therefore the real protection, not a
        // formality — which also means implausible reported limits have to be
        // rejected rather than clamped to.
        guard fan.maxRPM > fan.minRPM, fan.maxRPM > 100, fan.maxRPM < 30000 else {
            throw FanControlError.implausibleRange(fanIndex, fan.minRPM, fan.maxRPM)
        }
        let clamped = min(max(rpm, fan.minRPM), fan.maxRPM)

        try unlockIfNeeded()

        // Only take control if this fan is not already under it. The app
        // re-sends targets every two seconds as a heartbeat, and re-writing a
        // mode the fan already holds is refused with error 130 — which surfaced
        // as a permanent red error in the UI while control was working fine.
        if abs(fan.modeRaw - Self.forcedModeValue) >= 0.001 {
            try forceModeWithRetry(fanIndex: fanIndex)
        }
        try write(fanIndex: fanIndex, field: .target, value: clamped)

        // The firmware does not reflect the target instantly. Reading straight
        // back reports "not accepted" for a write that is about to take effect,
        // which is how a working 4520 rpm write got flagged as a failure.
        var after = fanReader.read(index: fanIndex)
        let deadline = Date().addingTimeInterval(Self.targetVerifyWindow)
        while Date() < deadline {
            if let after, abs(after.targetRPM - clamped) < 50 { break }
            Thread.sleep(forTimeInterval: 0.2)
            after = fanReader.read(index: fanIndex)
        }

        return ApplyResult(
            requestedRPM: rpm,
            clampedRPM: clamped,
            readBackTarget: after?.targetRPM,
            readBackMode: after?.modeRaw
        )
    }

    /// Hand a fan back to macOS by restoring the mode it had before we wrote.
    public func restoreAutomatic(fanIndex: Int) throws {
        guard Self.isRoot else { throw FanControlError.notRoot }

        guard let baseline = baseline(forFan: fanIndex) else {
            throw FanControlError.noBaselineRecorded(fanIndex)
        }
        try unlockIfNeeded()
        try writeModeWithRetry(fanIndex: fanIndex, value: baseline)
    }

    /// Restore every fan. Errors are collected rather than thrown, so one failing
    /// fan cannot prevent the others from being released — this runs on exit
    /// paths where giving up partway would leave fans forced.
    @discardableResult
    public func restoreAllAutomatic() -> [Int: String] {
        var failures: [Int: String] = [:]
        captureBaseline()

        // Only fans actually sitting on a non-baseline mode need restoring.
        // Writing the mode requires the firmware to be unlocked, so attempting it
        // unconditionally fails noisily on a machine that was never forced.
        let needingRestore = fanReader.readAll().filter { fan in
            guard let base = automaticBaselineValue(fan.index) else { return false }
            return abs(fan.modeRaw - base) > 0.001
        }

        if !needingRestore.isEmpty {
            // Best effort, and expected to fail on this firmware.
            //
            // Control is asymmetric: you take it by writing mode 1, but you
            // cannot give it back by writing the old mode — that write is
            // refused with error 130 even while unlocked. Clearing Ftst is the
            // only thing that actually hands the fans back. Retrying this was
            // costing four seconds per fan and reporting failures for a write
            // that was never going to land, so it gets one attempt and its
            // result is ignored.
            try? unlockIfNeeded()
            for fan in needingRestore {
                guard let base = automaticBaselineValue(fan.index) else { continue }
                _ = try? smc.writeFan(index: fan.index, field: .mode, value: base)
            }
        }

        // Always clear the unlock, even if a mode restore failed. Leaving `Ftst`
        // set would keep thermal management handed over to us — the worst state
        // this code could leave the machine in.
        if let error = relock(force: true) {
            failures[-1] = "could not clear Ftst: \(error)"
        }

        // Clearing Ftst is what actually returns control: the firmware reclaims
        // the fans and sets the mode itself. That is the mechanism relied on when
        // no trustworthy baseline exists, so wait for it rather than reporting
        // success the instant the write returns.
        if !waitForFirmwareToReclaim() {
            failures[-2] = "firmware had not reclaimed the fans after "
                + "\(Int(Self.reclaimWaitSeconds))s"
        }
        return failures
    }

    /// Poll until no fan is still sitting on the forced mode value.
    /// - Returns: true once the firmware has taken the fans back.
    @discardableResult
    public func waitForFirmwareToReclaim() -> Bool {
        let deadline = Date().addingTimeInterval(Self.reclaimWaitSeconds)
        while Date() < deadline {
            let stillForced = fanReader.readAll().contains {
                abs($0.modeRaw - Self.forcedModeValue) < 0.001
            }
            if !stillForced { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return !fanReader.readAll().contains {
            abs($0.modeRaw - Self.forcedModeValue) < 0.001
        }
    }

    private func automaticBaselineValue(_ index: Int) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return automaticBaseline[index]
    }

    // MARK: Firmware unlock

    /// Ask the firmware to yield fan control.
    ///
    /// `Ftst` must stay set for as long as manual control is held; clearing it
    /// hands the fans straight back.
    private func unlockIfNeeded() throws {
        lock.lock()
        let alreadyUnlocked = isUnlocked
        lock.unlock()

        // Trusting the cached flag is not enough: the firmware clears `Ftst`
        // across sleep, so after a wake the app believes it still holds the
        // unlock while every mode write is being refused. Confirm against the
        // hardware instead.
        if alreadyUnlocked {
            if let value = unlockKeyValue(), value != 0 { return }
            lock.lock()
            isUnlocked = false
            lock.unlock()
        }

        // Determine once whether this hardware has the key, and treat its
        // absence as "no unlock needed" rather than as a failure.
        lock.lock()
        let known = hasUnlockKey
        lock.unlock()
        if known == false { return }
        if known == nil {
            let present = (try? smc.read("Ftst")) != nil
            lock.lock()
            hasUnlockKey = present
            lock.unlock()
            if !present { return }
        }

        do {
            try smc.writeFan(index: 0, field: .testUnlock, value: 1)
        } catch SMCError.keyNotFound {
            lock.lock()
            hasUnlockKey = false
            lock.unlock()
            return
        }

        lock.lock()
        isUnlocked = true
        lock.unlock()
    }

    /// Write the forced mode, retrying until the firmware accepts it.
    ///
    /// `thermalmonitord` releases the fans somewhere in a window rather than at a
    /// fixed moment after the unlock, so this keeps trying instead of sleeping a
    /// guessed interval and attempting once.
    ///
    /// - Returns: how long it took to land, for diagnostics.
    @discardableResult
    public func forceModeWithRetry(fanIndex: Int) throws -> TimeInterval {
        try writeModeWithRetry(fanIndex: fanIndex, value: Self.forcedModeValue)
    }

    /// Write any mode value, retrying through the firmware's yield window.
    /// Restoring the baseline needs the same patience as forcing does.
    @discardableResult
    func writeModeWithRetry(
        fanIndex: Int,
        value: Double,
        window: TimeInterval = FanController.unlockRetryWindow
    ) throws -> TimeInterval {
        let started = Date()
        var lastError: Error?

        while Date().timeIntervalSince(started) < window {
            do {
                try smc.writeFan(index: fanIndex, field: .mode, value: value)
                return Date().timeIntervalSince(started)
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: Self.unlockRetryInterval)
            }
        }
        throw lastError ?? FanControlError.writeRejected("F\(fanIndex)Md", 130)
    }

    /// Return thermal control to the firmware.
    ///
    /// - Parameter force: write `Ftst = 0` even if this instance does not believe
    ///   it set it. Used on restore paths, where a previous process may have left
    ///   it set and the safe action is to clear it regardless.
    /// - Returns: nil once `Ftst` is confirmed clear, or a description of why it
    ///   could not be. Never silently swallows the failure: leaving `Ftst` set
    ///   means thermal management stays handed to a process that may be gone.
    @discardableResult
    public func relock(force: Bool = false) -> String? {
        lock.lock()
        let shouldWrite = isUnlocked || force
        isUnlocked = false
        lock.unlock()

        guard shouldWrite else { return nil }
        guard Self.isRoot else { return FanControlError.notRoot.description }

        // Nothing to clear on hardware that has no unlock key.
        lock.lock()
        let keyAvailable = hasUnlockKey ?? ((try? smc.read("Ftst")) != nil)
        hasUnlockKey = keyAvailable
        lock.unlock()
        guard keyAvailable else { return nil }

        // The firmware does not always reflect the write immediately, so confirm
        // rather than assume, and retry before giving up.
        var lastError: String?
        for attempt in 0..<5 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.5) }
            do {
                try smc.writeFan(index: 0, field: .testUnlock, value: 0)
            } catch {
                lastError = "\(error)"
            }
            if let value = (try? smc.read("Ftst"))?.number, value == 0 { return nil }
        }
        return lastError ?? "Ftst still reads non-zero after 5 attempts"
    }

    /// Current value of the firmware unlock key.
    public func unlockKeyValue() -> Double? { (try? smc.read("Ftst"))?.number }

    /// Whether the firmware is currently handed over to us.
    public var firmwareUnlocked: Bool {
        (try? smc.read("Ftst"))?.number.map { $0 != 0 } ?? false
    }

    /// Diagnostic write reporting the SMC's answer instead of throwing.
    ///
    /// Skips the clamping that `setTarget` applies, so a probe can find out what
    /// the SMC will and will not accept. Still confined to the two fan fields —
    /// the guardrail is structural and applies here too.
    ///
    /// - Returns: nil on success, or a description of the refusal.
    public func rawWrite(fanIndex: Int, field: FanWritableField, value: Double) -> String? {
        guard Self.isRoot else { return FanControlError.notRoot.description }
        do {
            try smc.writeFan(index: fanIndex, field: field, value: value)
            return nil
        } catch {
            return "\(error)"
        }
    }

    // MARK: Private

    private func write(fanIndex: Int, field: FanWritableField, value: Double) throws {
        guard fanIndex >= 0, fanIndex < 16 else {
            throw FanControlError.invalidFanIndex(fanIndex)
        }
        try smc.writeFan(index: fanIndex, field: field, value: value)
    }
}

extension FanReader {
    /// Indices of every fan actually present, for iteration on restore paths.
    /// Derived from what responded, not from assuming 0..<FNum.
    public func fanIndices() -> [Int] { readAll().map(\.index) }
}
