import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt
import Security
import SMCKit

// Privileged helper daemon. Runs as root under launchd and performs the only
// SMC writes in the project.
//
// Every path that could leave fans forced ends in a restore:
//   - watchdog, if the app stops heartbeating (crash, kill -9)
//   - XPC connection invalidation, when the app exits
//   - SIGTERM/SIGINT, when launchd or an admin stops the daemon
//   - system sleep
//
// See SPEC.md "FanHelper daemon".

let helperVersion = SMCKit.version

func log(_ message: String) {
    FileHandle.standardError.write(Data("MacFanSpeedHelper: \(message)\n".utf8))
}

// MARK: - Fan service

/// Owns the SMC connection and the watchdog. All access is serialized onto one
/// queue so the SMC is never touched concurrently.
final class FanService {
    static let shared = FanService()

    private let queue = DispatchQueue(label: "io.github.bradr23.MacFanSpeed.helper.fans")
    private var controller: FanController?
    private var watchdog: DispatchSourceTimer?
    private var hasForcedFans = false

    /// Set once the process is on its way out, after which no request may force
    /// a fan again. See `shutdownAndRestore`.
    private var isShuttingDown = false

    /// Set across a sleep restore, so a request that was already in flight cannot
    /// re-take the fans between the restore and the machine actually going down.
    ///
    /// The app re-sends its target every two seconds and does not know sleep is
    /// happening, so without this the daemon reliably handed the fans back and
    /// then had them taken straight off it again — while sleeping.
    private var isSuspending = false

    /// Live XPC connections, and which one currently owns the forced fans.
    ///
    /// Ownership matters: releasing on the *last* disconnect (0.2.0) stopped a
    /// short-lived `fanctl` from stealing control, but it also meant any client
    /// staying connected could keep another's fans forced, and any client's
    /// heartbeat could feed another's watchdog. Fans are now released when the
    /// client that forced them goes, whoever else is still attached.
    private var activeClients = 0
    private var owner: ObjectIdentifier?

    /// The daemon's own temperature sensing, independent of any client.
    private var temperatures: TemperatureReader?
    private var thermalTimer: DispatchSourceTimer?
    private var recoveryTimer: DispatchSourceTimer?
    private var suspendTimer: DispatchSourceTimer?
    /// All thermal decision-making, in a value type that lives in SMCKit so it
    /// can actually be tested — this executable target is in no test bundle.
    private var thermal = ThermalWatchState()

    private init() {}

    func start() {
        queue.sync {
            do {
                let smc = try SMCConnection()
                let controller = FanController(smc: smc)

                // The baseline is what every restore writes back, so capturing a
                // wrong one is worse than capturing none. If `Ftst` is set, some
                // earlier process left the firmware yielded and the modes on
                // screen are mid-manipulation — a previous run of this daemon
                // recorded a baseline of 0 that way. Hand control back first and
                // let the firmware settle, so the values read are genuinely its own.
                if let unlock = controller.unlockKeyValue(), unlock != 0 {
                    log("Ftst was \(unlock) at startup — clearing it before reading the baseline")

                    // `relock` documents its return as "nil once Ftst is
                    // confirmed clear, or a description of why it could not be.
                    // Never silently swallows the failure" — and this, its most
                    // important caller, silently swallowed it. A failed clear
                    // leaves the firmware yielded, which makes every later
                    // capture refuse and every setTarget throw
                    // noBaselineRecorded, with nothing in the log to say why.
                    if let error = controller.relock(force: true) {
                        log("WARNING: could not clear Ftst at startup: \(error). "
                            + "Thermal management may still be handed to a process "
                            + "that is gone, and no trustworthy baseline can be "
                            + "read while it is. Please report this.")
                    }

                    // Wait for the firmware to actually take the fans back rather
                    // than sleeping a guessed interval. Three seconds was shorter
                    // than the reclaim this hardware measurably takes — restores
                    // on the developer's Mac log 2.4-3.5 s, and
                    // `reclaimWaitSeconds` documents ten — so the capture could
                    // land mid-handshake, where SPEC records the mode reading 0,
                    // and write that down as the automatic baseline. Hard rule 1a
                    // is explicit that retrying beats guessing an interval, and
                    // hard rule 3 forbids restoring a mode of 0.
                    if !controller.waitForFirmwareToReclaim() {
                        log("WARNING: the firmware had not taken the fans back "
                            + "\(Int(FanController.reclaimWaitSeconds))s after Ftst was "
                            + "cleared; the baseline below may be a transitional value")
                    }
                }

                let baseline = controller.captureBaseline()
                self.controller = controller
                log("started, version \(helperVersion), fan mode baseline: \(baseline)")

                // The daemon reads its own temperatures rather than trusting a
                // client to tell it when to stop. Whether this works in the
                // system domain is stated in the log rather than assumed — the
                // sleep observer in 0.1.0 registered without error and was then
                // never called, and that failure was invisible for weeks.
                let reader = TemperatureReader()
                self.temperatures = reader
                let firstReading = reader.hottestCPU()
                self.thermal.observeStartup(celsius: firstReading?.celsius)
                if let hottest = firstReading {
                    log(String(
                        format: "independent failsafe ACTIVE — %@ reads %.1f °C, "
                              + "ceiling %.0f °C",
                        hottest.name, hottest.celsius, ThermalLimits.daemonTripCelsius
                    ))
                } else {
                    log("WARNING: the daemon cannot read temperatures, so its own "
                        + "failsafe is unavailable and only the app's applies. "
                        + "Fan control still works. Please report this.")
                }
            } catch {
                log("FATAL: could not open the SMC: \(error)")
            }
        }
    }

    func setFan(index: Int, targetRPM: Double, client: ObjectIdentifier?) -> String? {
        queue.sync {
            guard !isShuttingDown else { return "helper is shutting down" }
            guard !isSuspending else { return "the machine is going to sleep" }
            guard let controller else { return "helper has no SMC connection" }

            // Validated here as well as in FanController: this is the boundary
            // where a number from an untrusted client first enters the daemon,
            // and a non-finite one used to survive every clamp downstream.
            guard targetRPM.isFinite else { return "target must be a finite number" }
            guard index >= 0, index < FanReader.maximumFanIndex else {
                return "fan index out of range"
            }

            // The daemon's own failsafe outranks any client. While it holds, no
            // request may force a fan, however well-formed or well-signed.
            if let blocked = thermal.refusalReason(celsius: currentCelsius()) {
                return blocked
            }

            do {
                let result = try controller.setTarget(fanIndex: index, rpm: targetRPM)
                hasForcedFans = true
                // First writer owns the fans. Last-writer-wins let a second
                // client take responsibility for fans it did not force, so its
                // exit dropped someone else's.
                if owner == nil { owner = client }
                restartWatchdog()
                startThermalWatch()

                // Re-checked here because the firmware unlock holds this serial
                // queue for up to twelve seconds, and the thermal timer runs on
                // the same queue — so it cannot fire during exactly the window
                // where the fans are being taken over. A machine that crossed
                // the ceiling while we were unlocking would otherwise not be
                // noticed until the next tick.
                //
                // `observeHeat`, not `step`: this is a client request, not a tick
                // of the watch, and it must not advance the missed-reading
                // counter. It used to, and on a Mac whose daemon cannot read
                // temperatures — where the watch never runs, so this was the only
                // caller — three requests were enough to make every later one
                // force the fans and instantly release them, forever.
                if case .release(let reason) = thermal.observeHeat(celsius: currentCelsius()) {
                    performRestore(reason: "\(reason.logDescription) on completing the fan write")
                    return thermal.refusalReason(celsius: currentCelsius())
                        ?? "too hot on completing the fan write"
                }
                if !result.targetAccepted {
                    return String(
                        format: "the SMC did not accept the target "
                              + "(asked %.0f, reads back %@)",
                        result.clampedRPM,
                        result.readBackTarget.map { String(format: "%.0f", $0) } ?? "nothing"
                    )
                }
                return nil
            } catch {
                // A throw does NOT mean nothing happened. setTarget writes the
                // firmware unlock first, then the mode, then the target, and the
                // two later writes can each throw. Returning the error and
                // nothing else left the machine with thermal management yielded
                // — and possibly a fan pinned — while the daemon still believed
                // it owned nothing. Every restore path is gated on
                // `hasForcedFans`, so that one omission switched off the
                // watchdog, the disconnect restore, sleep, SIGTERM and the
                // daemon's own failsafe simultaneously.
                //
                // Ownership therefore begins at the first hardware write, not
                // at success. `firmwareUnlocked` used to be the test, and it is
                // fail-open exactly where it matters: it reads `Ftst`, and
                // answers false both on hardware that has no such key — where
                // `setTarget` still writes the forced mode — and when the
                // confirming read merely failed. `mayHoldFans` is set by the
                // writer itself, before the first write, so it cannot be wrong
                // in that direction.
                if controller.mayHoldFans {
                    if !hasForcedFans {
                        log("setFan failed with the firmware still yielded — "
                            + "arming supervision so the restore paths can recover")
                    }
                    hasForcedFans = true
                    if owner == nil { owner = client }
                    restartWatchdog()
                    startThermalWatch()
                }
                return "\(error)"
            }
        }
    }

    /// Hand the fans back at a client's request.
    ///
    /// Delegates to `performRestore` rather than open-coding a second restore.
    /// It used to be its own implementation, and when the fix for "a failed
    /// restore must not disarm supervision" landed it was applied to only one of
    /// the two — leaving the path that every app-initiated release actually uses
    /// (clicking Auto, a failsafe trip, quitting) clearing `hasForcedFans` before
    /// it had looked at whether the restore worked. Every other restore path is
    /// gated on that flag, so failing here switched all of them off at once.
    ///
    /// `force` is what makes this correct after a daemon restart. `hasForcedFans`
    /// is per-process state, so a daemon that was replaced (`install-helper.sh`),
    /// kickstarted, or that crashed while the app held the fans starts life
    /// believing it owns nothing — while the hardware is still forced. Delegating
    /// without it meant every client-facing way of handing the fans back returned
    /// success for doing nothing, in exactly the crash-recovery case the
    /// persisted baseline was added to survive.
    func setAllAuto() -> String? {
        queue.sync {
            guard controller != nil else { return "helper has no SMC connection" }
            let failures = performRestore(
                reason: "client asked for automatic control", force: true
            )
            guard failures.isEmpty else {
                return failures.map { "fan \($0.key): \($0.value)" }.joined(separator: "; ")
            }
            return nil
        }
    }

    /// Only the client that forced the fans may feed the watchdog.
    ///
    /// It used to check the daemon-global `hasForcedFans`, so any accepted
    /// connection could keep another client's fans alive indefinitely — the
    /// watchdog was being fed by something that had never asked for anything.
    func heartbeat(client: ObjectIdentifier?) -> String? {
        queue.sync {
            guard hasForcedFans, let owner, owner == client else { return nil }
            restartWatchdog()
            return nil
        }
    }

    /// Restore automatic control. Used by the disconnect, signal and sleep paths.
    ///
    /// Serialized onto the fan queue like everything else. Previously this ran on
    /// whatever thread invoked it while the watchdog ran the same work on the
    /// queue, so a disconnect and a watchdog firing could interleave — one
    /// clearing `Ftst` while the other was still writing modes, which makes those
    /// writes fail for their entire retry window and leaves the fans forced.
    func emergencyRestore(reason: String) {
        queue.sync { _ = performRestore(reason: reason) }
    }

    /// Restore for sleep, refusing new requests until the machine wakes.
    ///
    /// Unlike `shutdownAndRestore` this is reversible: `resumeAfterWake` lifts it.
    func suspendAndRestore(reason: String) {
        queue.sync {
            isSuspending = true
            performRestore(reason: reason)

            // A gate that only a wake message can lift is a gate that refuses
            // everything forever if that message never arrives — and "a
            // notification that silently never fires" is this project's most
            // repeated bug. The wake path clears it promptly; this only bounds
            // the damage if it does not.
            //
            // The previous timer is cancelled rather than dropped. Replacing a
            // live one left it running, so a gate opened by sleep N+1 could be
            // lifted early by sleep N's timer.
            suspendTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.suspendGateTimeout)
            timer.setEventHandler { [weak self] in
                guard let self, self.isSuspending else { return }
                log("no wake notification after \(Int(Self.suspendGateTimeout))s — "
                    + "lifting the sleep gate anyway (expected if the machine "
                    + "slept for longer than that)")
                self.isSuspending = false
            }
            timer.resume()
            suspendTimer = timer
        }
    }

    /// How long the sleep gate may hold without a wake message.
    ///
    /// The gate exists to stop a request that was already in flight from
    /// re-taking the fans between the restore and the machine actually going
    /// down. That window is seconds — `IOAllowPowerChange` is called the moment
    /// the restore returns — so the timeout only has to outlast it.
    ///
    /// It was 120 s, which turned out to be far too long to be harmless. The
    /// developer's log shows 70 sleeps against 34 wake notifications and 72
    /// expiries of this timer: the wake message usually does not arrive before
    /// the gate times out, and every one of those cost up to two minutes in
    /// which the daemon answered every fan request with "the machine is going to
    /// sleep". Fifteen seconds covers the real window and bounds the damage from
    /// a missed wake to something a user would not notice.
    static let suspendGateTimeout: TimeInterval = 15

    /// Accept requests again after a wake.
    func resumeAfterWake() {
        queue.sync {
            suspendTimer?.cancel()
            suspendTimer = nil
            guard isSuspending else { return }
            isSuspending = false
            log("awake — accepting fan requests again")
        }
    }

    // MARK: Client tracking

    /// Register an accepted client. Must be paired with `clientDisconnected`.
    func clientConnected() {
        queue.sync { activeClients += 1 }
    }


    /// Release the fans when the client that **forced** them disconnects.
    ///
    /// Not when the last of any clients does — that was 0.2.0's rule, and this
    /// comment described it for a release after the code had stopped doing it.
    ///
    /// The history is worth keeping because both wrong answers were tried.
    /// Releasing on *any* disconnect broke the common case: every `fanctl`
    /// invocation opens its own connection, and the diagnostics this project asks
    /// people to paste into bug reports are `fanctl` commands, so running
    /// `fanctl helper-status` while a preset was active knocked the fans straight
    /// back to automatic. Releasing only when *all* clients had gone then let an
    /// unrelated connection hold someone else's fans for as long as it stayed
    /// attached. Ownership is the answer to both.
    ///
    /// The watchdog is unaffected and remains the backstop for a client that dies
    /// without its connection being torn down.
    func clientDisconnected(_ client: ObjectIdentifier?) {
        queue.sync {
            activeClients = max(0, activeClients - 1)

            // Release when the client that forced the fans goes, not when the
            // last of any clients does. Waiting for the count to reach zero let
            // an unrelated connection hold another client's fans forced for as
            // long as it stayed attached.
            if hasForcedFans, let owner, owner == client {
                performRestore(reason: "the client holding the fans disconnected")
                return
            }
            if activeClients > 0 {
                log("a client disconnected; \(activeClients) still connected, "
                    + "keeping fan control")
                return
            }
            performRestore(reason: "last client disconnected")
        }
    }

    /// Restore, then refuse to force anything again. For paths that end in
    /// `exit()`.
    ///
    /// Restoring takes a few seconds, and the app keeps sending its target every
    /// two seconds throughout — including while the daemon is being replaced,
    /// which is when a stop is most likely. Those requests queue behind the
    /// restore and would otherwise be honoured *after* it, re-forcing the fans
    /// and setting `Ftst` again moments before the process exits. Nothing would
    /// then be left to hand them back.
    ///
    /// Both the flag and the restore run in one block on the serial queue, so a
    /// request already executing finishes first and every later one is refused.
    func shutdownAndRestore(reason: String) {
        queue.sync {
            isShuttingDown = true
            performRestore(reason: reason)
        }
    }

    /// Must be called on `queue`.
    /// - Returns: the failures the restore reported; empty means the fans are
    ///   genuinely back under macOS control.
    @discardableResult
    private func performRestore(reason: String, force: Bool = false) -> [Int: String] {
        guard hasForcedFans || force else { return [:] }
        log("restoring automatic control (\(reason))")

        // Stop the other path from starting a competing restore.
        cancelWatchdog()

        let started = Date()
        let failures = controller?.restoreAllAutomatic() ?? [:]
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))

        if failures.isEmpty {
            hasForcedFans = false
            owner = nil
            stopThermalWatch()
            log("fans returned to automatic control in \(elapsed)s")
            return failures
        }

        // The restore FAILED, which means the fans may still be forced. Clearing
        // the state anyway — as this used to — told every other safety mechanism
        // there was nothing left to protect: the watchdog stayed cancelled, the
        // thermal watch was stopped, and the one situation where supervision
        // matters most was the one where it was switched off.
        //
        // So the state stands and the watchdog is re-armed to try again. The
        // exception is shutdown, where nothing will be left running to retry.
        log("restore finished in \(elapsed)s WITH PROBLEMS: \(failures)")
        // A forced restore that failed on a machine that shows evidence of being
        // held means a restarted daemon has met the hardware its predecessor
        // left. Taking responsibility is what arms the retry. Without the
        // evidence check this would also latch on a Mac that merely *rests* at
        // the forced mode value, where the reclaim wait can never be satisfied.
        if force, !hasForcedFans, controller?.fansAppearHeld == true {
            log("the fans still appear to be held — taking ownership so the "
                + "watchdog can retry the restore")
            hasForcedFans = true
        }
        if isShuttingDown {
            hasForcedFans = false
            owner = nil
            stopThermalWatch()
            log("WARNING: exiting with a failed restore; the fans may still be forced")
        } else {
            log("keeping the watchdog and thermal watch armed to retry")
            restartWatchdog()
            startThermalWatch()
        }
        return failures
    }

    // MARK: The daemon's own failsafe

    /// How often the daemon checks the temperature while it is holding fans.
    static let thermalInterval: TimeInterval = 2

    /// The daemon's own current reading, or nil if it has none.
    ///
    /// Must be called on `queue`.
    private func currentCelsius() -> Double? {
        guard let temperatures else { return nil }
        guard let hottest = temperatures.hottestCPU(), hottest.celsius.isFinite else { return nil }
        return hottest.celsius
    }

    /// Watch the temperature for as long as fans are forced.
    ///
    /// This is the daemon's answer to the fact that every other thermal
    /// protection in this project lives in the app — which the daemon does not
    /// trust and cannot verify. A client that lies, crashes, or was never the app
    /// at all cannot disable this, because nothing about it depends on the
    /// client: its own reader, its own timer, its own compiled-in ceiling.
    ///
    /// Must be called on `queue`.
    private func startThermalWatch() {
        // Gated on sensing having been PROVEN, not on a client object existing.
        // Starting a watch that can never read anything is how the daemon used to
        // trip a lockout it could never lift.
        guard thermalTimer == nil, thermal.shouldWatch, temperatures != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.thermalInterval, repeating: Self.thermalInterval)
        timer.setEventHandler { [weak self] in self?.checkTemperature() }
        timer.resume()
        thermalTimer = timer
    }

    /// Must be called on `queue`.
    private func stopThermalWatch() {
        thermalTimer?.cancel()
        thermalTimer = nil
    }

    /// Must be called on `queue`.
    private func checkTemperature() {
        guard hasForcedFans else { return }
        switch thermal.step(celsius: currentCelsius()) {
        case .none:
            return
        case .release(.readingsLost):
            log("lost temperature readings while holding fans — returning them to "
                + "macOS; the daemon's own failsafe is inactive until readings return")
            performRestore(reason: "temperature readings lost")
        case .release(.tooHot(let celsius)):
            log(String(
                format: "FAILSAFE: %.1f °C reached the %.0f °C ceiling — returning fans to macOS",
                celsius, ThermalLimits.daemonTripCelsius
            ))
            performRestore(reason: "daemon failsafe")
        }
    }

    /// Clear the lockout once the machine is genuinely cool again, and re-arm the
    /// watch if sensing has come back.
    ///
    /// Must be called on `queue`.
    private func releaseThermalLockoutIfCool() {
        let wasLockedOut = thermal.lockedOut
        let regained = thermal.recoveryTick(celsius: currentCelsius())

        if regained {
            log("temperature readings returned — the daemon's own failsafe is active again")
            // Re-arm immediately rather than waiting for the next setFan. Fans
            // already held were otherwise left unsupervised until a client
            // happened to send another request, which it may never do.
            if hasForcedFans { startThermalWatch() }
        }
        if wasLockedOut, !thermal.lockedOut {
            log("cooled below the reset point — fan control available again")
        }
    }

    /// Slow tick that runs for the life of the daemon, so a lockout can lift even
    /// with nothing connected.
    func startRecoveryWatch() {
        queue.sync {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler { [weak self] in self?.releaseThermalLockoutIfCool() }
            timer.resume()
            recoveryTimer = timer
        }
    }

    // MARK: Watchdog

    private func restartWatchdog() {
        cancelWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + HelperConstants.watchdogTimeout)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            log("watchdog fired — no heartbeat for \(Int(HelperConstants.watchdogTimeout))s")
            // Already on `queue`; calling emergencyRestore would deadlock on its
            // queue.sync, so go straight to the serialized body.
            self.performRestore(reason: "watchdog")
        }
        timer.resume()
        watchdog = timer
    }

    private func cancelWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }
}

// MARK: - XPC

/// One instance per connection, so every request carries the identity of the
/// client that made it. Fan ownership and the heartbeat both depend on knowing
/// *which* client is asking, not merely that someone is.
final class HelperService: NSObject, FanHelperProtocol {
    /// Identity of the connection this instance serves.
    private let client: ObjectIdentifier

    init(client: ObjectIdentifier) {
        self.client = client
    }

    func setFan(index: Int, targetRPM: Double, reply: @escaping (String?) -> Void) {
        reply(FanService.shared.setFan(index: index, targetRPM: targetRPM, client: client))
    }

    func setAllAuto(reply: @escaping (String?) -> Void) {
        reply(FanService.shared.setAllAuto())
    }

    func heartbeat(reply: @escaping (String?) -> Void) {
        reply(FanService.shared.heartbeat(client: client))
    }

    func version(reply: @escaping (String) -> Void) {
        reply(helperVersion)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard Self.isAcceptableClient(connection) else {
            log("rejected a connection that failed code-signature validation")
            return false
        }

        let client = ObjectIdentifier(connection)
        connection.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        connection.exportedObject = HelperService(client: client)

        // The app going away is one of the paths that must end in automatic fans.
        // The watchdog would catch it too; this just makes it immediate.
        //
        // Counted rather than acted on directly: a `fanctl` command run alongside
        // the app is a second client, and its exit must not release fans the app
        // is still holding.
        FanService.shared.clientConnected()
        connection.invalidationHandler = {
            FanService.shared.clientDisconnected(client)
        }
        connection.resume()
        return true
    }

    /// Verify the connecting process.
    ///
    /// Two known limitations, both consequences of shipping without a Developer
    /// ID, and both documented rather than quietly skipped:
    ///
    /// 1. The usual team-identifier check is impossible — there is no team ID.
    ///    The requirement checks the signing identifier instead, which stops a
    ///    different or tampered binary but not a re-signed impostor.
    /// 2. The client is identified by PID. `NSXPCConnection.auditToken` would be
    ///    race-free but is private API; a PID can in principle be recycled
    ///    between the call and this check.
    ///
    /// The daemon's real safety property does not rest on this check: it exposes
    /// only fan targets, re-clamps them against limits it reads itself, and
    /// reverts to automatic on any silence.
    private static func isAcceptableClient(_ connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier

        let requirementText = """
            identifier "\(HelperConstants.appBundleIdentifier)" or identifier "fanctl"
            """
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
                  requirementText as CFString, [], &requirement
              ) == errSecSuccess
        else {
            log("could not build the client signing requirement")
            return false
        }

        // Preferred: ask the system to identify the running process directly.
        var code: SecCode?
        let guestStatus = SecCodeCopyGuestWithAttributes(
            nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code
        )
        if guestStatus == errSecSuccess, let code {
            let valid = SecCodeCheckValidity(code, [], requirement)
            if valid == errSecSuccess { return true }
            log("client pid \(pid) failed the signing requirement (OSStatus \(valid))")
            return false
        }
        // 100001 is kPOSIXErrorBase + EPERM: the lookup was not permitted rather
        // than the client being wrong. A system-domain daemon inspecting a
        // user-session process hits this routinely.

        // Fallback: resolve the client's binary and validate it on disk.
        //
        // The guest lookup above fails when the daemon (system domain) inspects a
        // process in a user session, which is the normal case here. Validating the
        // executable is session-independent. It is weaker — the file could in
        // principle be swapped between this check and a later call — but the
        // daemon's safety does not rest on client identity: it exposes only fan
        // targets, re-clamps them, and reverts to automatic on silence.
        log("guest lookup for pid \(pid) failed (OSStatus \(guestStatus)); "
            + "falling back to on-disk validation")

        var pathBuffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 else {
            log("could not resolve the executable for pid \(pid)")
            return false
        }
        let path = String(cString: pathBuffer)

        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            URL(fileURLWithPath: path) as CFURL, [], &staticCode
        )
        if createStatus == errSecSuccess, let staticCode {
            let status = SecStaticCodeCheckValidity(staticCode, [], requirement)
            if status == errSecSuccess { return true }
            log("client \(path) failed the signing requirement (OSStatus \(status))")
            return false
        }

        // Neither check could be *performed* — as opposed to being performed and
        // failing. A daemon cannot read a client living under ~/Documents, which
        // TCC protects, so refusing here would make the app unusable for anyone
        // running a build from their home directory.
        //
        // Accepting is defensible only because identity is not what protects this
        // daemon: it exposes nothing but fan targets, re-clamps them against
        // limits it reads itself, and reverts to automatic the moment a client
        // stops talking. A caller that lies about who it is still cannot ask for
        // anything the hardware would not accept from the real app.
        log("WARNING: cannot verify client pid \(pid) at \(path) "
            + "(OSStatus \(createStatus)); accepting on the daemon's narrow API")
        return true
    }
}

// MARK: - Signals and sleep

/// Signal handlers must be async-signal-safe, so they only flip a flag that a
/// dispatch source acts on.
func installSignalHandlers() {
    for signalNumber in [SIGTERM, SIGINT] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler {
            // Shutdown variant: the process is about to exit, so nothing may be
            // allowed to re-force the fans after this restore.
            FanService.shared.shutdownAndRestore(reason: "received signal \(signalNumber)")
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }
}

var signalSources: [DispatchSourceSignal] = []

/// Root port for the system power notifications, needed to acknowledge them.
private var powerRootPort: io_connect_t = 0

/// Power-management message codes.
///
/// `IOMessage.h` builds these with the `iokit_common_msg` macro, which Swift
/// cannot import ("structure not supported"), so they are reconstructed here.
/// The macro is `sys_iokit | sub_iokit_common | code`, where `sys_iokit` is
/// `err_system(0x38)` — `0x38 << 26` — and `sub_iokit_common` is 0, giving the
/// `0xE0000000` prefix.
///
/// Confirmed against the SDK rather than assumed, by compiling the real macros:
///
///     printf("0x%08X 0x%08X", kIOMessageCanSystemSleep, kIOMessageSystemWillSleep)
///     // 0xE0000270 0xE0000280
private enum PowerMessage {
    private static let iokitCommon: UInt32 = 0xE000_0000
    /// Idle sleep asking whether it may proceed. `0xE0000270`.
    static let canSystemSleep = iokitCommon | 0x270
    /// Sleep is happening; the system waits for an acknowledgement. `0xE0000280`.
    static let systemWillSleep = iokitCommon | 0x280
    /// The machine is awake again. `0xE0000300`.
    static let systemHasPoweredOn = iokitCommon | 0x300
}

/// Restore automatic control before the machine sleeps.
///
/// This must use IOKit rather than `NSWorkspace.willSleepNotification`.
/// `NSWorkspace` notifications are delivered per *user session*, and a
/// LaunchDaemon runs in the system domain with no session attached — the
/// observer registers without error and is then never called. That is not a
/// theory: the daemon logged a restore for every other exit path across weeks of
/// use and not one for sleep, through many real sleep cycles.
/// `IORegisterForSystemPower` is the session-independent equivalent and is what
/// daemons are expected to use.
///
/// Answering `kIOMessageSystemWillSleep` also holds sleep off until the fans are
/// actually released, which the notification-based version could never do even
/// if it had fired.
func observeSleep() {
    var notifyPort: IONotificationPortRef?
    var notifier: io_object_t = 0

    let callback: IOServiceInterestCallback = { _, _, messageType, messageArgument in
        switch messageType {
        case PowerMessage.canSystemSleep:
            // Idle sleep asks permission first. Failing to answer stalls it for
            // 30 s, so allow it — the real work happens on WillSleep below.
            IOAllowPowerChange(powerRootPort, Int(bitPattern: messageArgument))

        case PowerMessage.systemHasPoweredOn:
            FanService.shared.resumeAfterWake()

        case PowerMessage.systemWillSleep:
            // Sleep waits for the acknowledgement, so the fans are handed back
            // before the machine goes down rather than racing it.
            FanService.shared.suspendAndRestore(reason: "system going to sleep")
            IOAllowPowerChange(powerRootPort, Int(bitPattern: messageArgument))

        default:
            break
        }
    }

    powerRootPort = IORegisterForSystemPower(nil, &notifyPort, callback, &notifier)
    guard powerRootPort != 0, let notifyPort else {
        log("WARNING: could not register for sleep notifications; the watchdog "
            + "remains the backstop")
        return
    }

    CFRunLoopAddSource(
        CFRunLoopGetMain(),
        IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(),
        .defaultMode
    )
    log("registered for system sleep notifications")
}

// MARK: - Entry point

if CommandLine.arguments.contains("--version") {
    print("MacFanSpeedHelper \(helperVersion) (SMCKit \(SMCKit.version))")
    exit(0)
}

guard FanController.isRoot else {
    log("must run as root")
    exit(1)
}

FanService.shared.start()
FanService.shared.startRecoveryWatch()
installSignalHandlers()
observeSleep()

let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
let delegate = ListenerDelegate()
listener.delegate = delegate
listener.resume()

log("listening on \(HelperConstants.machServiceName)")
RunLoop.main.run()
