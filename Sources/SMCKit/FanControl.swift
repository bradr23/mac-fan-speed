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
    case limitsUnknown(Int)
    case invalidTarget(Int, Double)

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
            // Formatted without Int(): these values reached here precisely
            // because they are untrustworthy, and Int(Double.nan) traps.
            return String(
                format: "Fan %d reports an implausible range (%.0f–%.0f rpm); "
                      + "refusing to drive it.", i, low, high
            )
        case .limitsUnknown(let i):
            return "Fan \(i) does not report its speed limits, so it cannot be "
                 + "driven safely."
        case .invalidTarget(let i, let rpm):
            return String(format: "Fan %d was given an invalid target (%f).", i, rpm)
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

    /// The value `F{i}Md` passes through while the firmware is taking the fans
    /// back. SPEC records the mode dropping 3 -> 0 -> 3 during that handshake, so
    /// a 0 read at the wrong moment is a transition, not a resting state — and
    /// hard rule 3 forbids writing 0 back as a "restore".
    ///
    /// Named rather than written as a literal because two separate places have to
    /// agree on it: the reclaim wait, which must not mistake it for a completed
    /// handover, and the baseline store, which must never record it.
    public static let midHandshakeModeValue: Double = 0

    /// How long to keep retrying the mode write after setting `Ftst`.
    ///
    /// The firmware does not yield at a fixed moment — `thermalmonitord` releases
    /// somewhere in a window of roughly 3–6 seconds, and a single attempt after a
    /// fixed sleep can miss it entirely. Retrying until it lands is what makes
    /// the unlock work.
    public static let unlockRetryWindow: TimeInterval = 12
    public static let unlockRetryInterval: TimeInterval = 0.25

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

    /// Whether this instance has written anything that could leave the fans out
    /// of the firmware's hands. Set before the first write, not after the last
    /// one succeeds, so a throw partway through still reports the truth.
    private var hasWrittenControl = false

    /// Where the baseline is remembered across processes. All of its rules —
    /// what may be stored, when a stored file is still evidence, when to rewrite
    /// it — live in `BaselineStore`, where they can be tested without hardware.
    private var store: BaselineStore

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

    /// Where the automatic baseline is remembered across processes.
    public static let defaultBaselineStore = BaselineStore.defaultURL

    public init(smc: SMCConnection, baselineStore: URL? = FanController.defaultBaselineStore) {
        self.smc = smc
        self.fanReader = FanReader(smc: smc)
        self.store = BaselineStore(url: baselineStore)
    }

    public static var isRoot: Bool { geteuid() == 0 }

    /// Whether this instance may have left the fans forced or the firmware
    /// yielded — true from the first hardware write until a restore is confirmed
    /// clean.
    ///
    /// The daemon arms its supervision on this rather than on reading `Ftst`
    /// back: that read answers false both on hardware with no such key, where
    /// the mode write happens anyway, and when the read itself merely fails.
    /// This flag is set by the writer, so it cannot be wrong in that direction.
    public var mayHoldFans: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasWrittenControl
    }

    /// Positive evidence that the fans are out of the firmware's hands *right
    /// now*, from any process.
    ///
    /// Deliberately not "a fan reads the forced mode": that value is 1, and a Mac
    /// that legitimately rests there is indistinguishable from one being held.
    /// Treating the mode as proof would make every restore on such a machine
    /// report failure and latch supervision that never lets go.
    public var fansAppearHeld: Bool {
        if let unlock = unlockKeyValue(), unlock != 0 { return true }
        lock.lock()
        defer { lock.unlock() }
        return hasWrittenControl || store.recoveredAnything
    }

    /// Record each fan's resting mode so automatic control can be restored
    /// exactly. Must be called before any write; safe to call repeatedly, as it
    /// never overwrites a baseline already captured.
    @discardableResult
    public func captureBaseline() -> [Int: Double] {
        // A remembered baseline outranks anything observable now for the fans it
        // covers, because it was recorded before this project touched them. It
        // used to short-circuit the whole capture, which made the file
        // all-or-nothing: one fan whose mode read missed at capture time was
        // written down as absent, and every process from then on trusted that
        // partial file and never observed the second fan again — leaving it
        // permanently uncontrollable, since `setTarget` refuses without a
        // baseline. So it seeds, and observation fills the gaps.
        let recovered = loadPersistedBaseline()

        // Otherwise the readings have to be *shown* to be trustworthy, not
        // assumed to be.
        //
        // This used to ask only whether `Ftst` was non-zero. On the Macs that
        // need no firmware unlock — SPEC records M1, and M5 reportedly — that key
        // is absent or zero *even while the fans are forced*, so the guard always
        // passed and a fresh process meeting already-forced fans recorded
        // "forced" as the automatic baseline. Every later restore then wrote that
        // back and did nothing. It worked on the developer's Mac purely because
        // that machine has `Ftst`, which is exactly the shape hard rule 6 exists
        // to catch.
        guard !fansAreDemonstrablyForced() else { return automaticBaselineSnapshot() }

        lock.lock()
        // Only a mode the SMC actually reported. A fabricated 0 would be cached
        // permanently and written back on every restore, setting a mode the
        // machine never had.
        for fan in fanReader.readAll()
        where automaticBaseline[fan.index] == nil && fan.modeReported {
            // Recovering a baseline at all means this process is the successor of
            // one that held the fans, so a fan still sitting on the forced value
            // is forced — not resting there. Recording it would make every later
            // restore write "forced" back over "forced" and report success.
            if recovered, abs(fan.modeRaw - Self.forcedModeValue) < 0.001 { continue }
            automaticBaseline[fan.index] = fan.modeRaw
        }
        let captured = automaticBaseline
        lock.unlock()
        return captured
    }

    /// Whether there is **positive evidence** that the fans are mid-manipulation,
    /// and their modes therefore are not an automatic baseline.
    ///
    /// Only `Ftst` counts as that evidence. The mode alone deliberately does not:
    /// `forcedModeValue` is 1, and a Mac that legitimately *rests* at mode 1 is
    /// indistinguishable from one that is forced to it. Treating "mode == 1" as
    /// proof of manipulation would mean such a machine never captured a baseline
    /// at all — and since `setTarget` refuses without one, fan control would be
    /// dead on exactly the untested hardware this rule exists to protect. That is
    /// the same shape as the bug being fixed, pointed the other way.
    ///
    /// What actually solves the restart-while-forced case is the persisted
    /// baseline: if this project forced the fans, it wrote down what came before.
    /// If something else did, no reading available now can recover it, and
    /// guessing is worse than recording the best value we have.
    private func fansAreDemonstrablyForced() -> Bool {
        guard let unlock = unlockKeyValue() else { return false }
        return unlock != 0
    }

    /// Merge any remembered baseline into this instance's.
    ///
    /// - Returns: true when the file supplied at least one usable value.
    @discardableResult
    private func loadPersistedBaseline() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let recovered = store.load()
        guard !recovered.isEmpty else { return false }
        for (index, value) in recovered where automaticBaseline[index] == nil {
            automaticBaseline[index] = value
        }
        return true
    }

    /// Remember the baseline before the first write, so a process that restarts
    /// while fans are forced still knows what "automatic" was.
    private func persistBaseline() {
        lock.lock()
        defer { lock.unlock() }
        store.save(automaticBaseline)
    }

    /// Forget the remembered baseline once the fans are genuinely back under
    /// macOS control.
    private func clearPersistedBaseline() {
        lock.lock()
        defer { lock.unlock() }
        store.clear()
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

        // Rejected before the clamp, not after: `min(max(rpm, lo), hi)` is
        // NaN-transparent, because every comparison against nan is false. A
        // non-finite target therefore survives clamping, reaches the SMC, and
        // then traps the first `Int(...)` that formats it — killing a root
        // process. This is the boundary where untrusted numbers stop.
        guard rpm.isFinite else {
            throw FanControlError.invalidTarget(fanIndex, rpm)
        }

        guard let fan = fanReader.read(index: fanIndex) else {
            throw FanControlError.invalidFanIndex(fanIndex)
        }

        // A fan whose limits the SMC never published has no trustworthy floor,
        // and the clamp is the only thing standing between a request and a
        // stopped fan.
        guard fan.limitsReported else {
            throw FanControlError.limitsUnknown(fanIndex)
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

        // No trustworthy baseline means no way to hand the fans back afterwards,
        // and forcing a fan you cannot release is the one thing this project must
        // never do. Refusing is the safe direction.
        guard baseline(forFan: fanIndex) != nil else {
            throw FanControlError.noBaselineRecorded(fanIndex)
        }
        // Written down before the first hardware write, so a crash or restart
        // mid-session still leaves the next process able to restore.
        persistBaseline()

        // Everything below writes to the hardware, and each write can throw. The
        // daemon reads this to decide whether a failed request still needs
        // supervising, so it is set here rather than on the way out.
        lock.lock()
        hasWrittenControl = true
        lock.unlock()

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
        // Only once the fans are genuinely back: a remembered baseline is how the
        // next process recovers from a failed restore, so it must outlive one.
        if failures.isEmpty {
            clearPersistedBaseline()
            lock.lock()
            hasWrittenControl = false
            lock.unlock()
        }
        return failures
    }

    /// Poll until every fan is genuinely back under the firmware's control.
    /// - Returns: true once the firmware has taken the fans back.
    @discardableResult
    public func waitForFirmwareToReclaim() -> Bool {
        let deadline = Date().addingTimeInterval(Self.reclaimWaitSeconds)
        while Date() < deadline {
            if fanReader.readAll().allSatisfy(hasReclaimed) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return fanReader.readAll().allSatisfy(hasReclaimed)
    }

    /// Whether one fan is back where it started.
    ///
    /// This used to be "the mode is not `forcedModeValue`", which is wrong in
    /// both directions. It accepts `midHandshakeModeValue` — the value the mode
    /// passes *through* on its way back — so a poll landing mid-handshake was
    /// reported as a completed reclaim, and the restore went on to delete the
    /// crash-recovery file and disarm ownership on the strength of a transient
    /// reading. And on a Mac whose resting mode is itself the forced value it can
    /// never be satisfied, so every restore burned the full ten seconds and
    /// reported failure.
    ///
    /// The captured baseline is the only exact answer, so it is used wherever one
    /// exists.
    private func hasReclaimed(_ fan: Fan) -> Bool {
        guard fan.modeReported else { return false }

        if let base = automaticBaselineValue(fan.index) {
            // A machine that rests on the forced value is indistinguishable from
            // one being held, and spinning for ten seconds to say so helps
            // nobody. Clearing `Ftst` is what actually returns control there.
            guard abs(base - Self.forcedModeValue) >= 0.001 else { return true }
            return abs(fan.modeRaw - base) < 0.001
        }

        // No baseline yet — this is the daemon's startup path, before anything is
        // recorded. The best available test is "neither forced nor mid-handshake".
        return abs(fan.modeRaw - Self.forcedModeValue) >= 0.001
            && abs(fan.modeRaw - Self.midHandshakeModeValue) >= 0.001
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
            let present = probeUnlockKey()
            // Only a definite answer is cached; "could not tell" leaves it nil so
            // the next attempt probes again rather than inheriting one bad read.
            if let present {
                lock.lock()
                hasUnlockKey = present
                lock.unlock()
                if !present { return }
            }
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

        // Nothing to clear on hardware that has no unlock key — but "we could
        // not find out" is not the same answer, and must not be reported as
        // success. Returning nil here means "Ftst is confirmed clear"; saying
        // that without having checked is how a yielded firmware got recorded as
        // a completed restore.
        lock.lock()
        let cached = hasUnlockKey
        lock.unlock()
        let availability = cached ?? probeUnlockKey()
        if let availability {
            lock.lock()
            hasUnlockKey = availability
            lock.unlock()
            if !availability { return nil }
        } else {
            return "could not determine whether this Mac has the Ftst unlock key"
        }

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

    /// Whether this Mac has the unlock key: true, false, or nil for "could not
    /// tell".
    ///
    /// `(try? read) != nil` conflates a key that does not exist with a read that
    /// failed, and the answer used to be cached permanently either way. A single
    /// transient failure therefore latched the process into "no unlock key",
    /// after which `relock` returned nil — which its own documentation defines as
    /// "Ftst confirmed clear" — without ever writing it. Only `keyNotFound` is
    /// evidence of absence.
    private func probeUnlockKey() -> Bool? {
        do {
            _ = try smc.read("Ftst")
            return true
        } catch SMCError.keyNotFound {
            return false
        } catch {
            return nil
        }
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
