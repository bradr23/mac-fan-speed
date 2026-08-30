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

    /// Live XPC connections. The fans are released when this reaches zero, not on
    /// every disconnect — see `clientDisconnected`.
    private var activeClients = 0

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
                    controller.relock(force: true)
                    Thread.sleep(forTimeInterval: 3)
                }

                let baseline = controller.captureBaseline()
                self.controller = controller
                log("started, version \(helperVersion), fan mode baseline: \(baseline)")
            } catch {
                log("FATAL: could not open the SMC: \(error)")
            }
        }
    }

    func setFan(index: Int, targetRPM: Double) -> String? {
        queue.sync {
            guard !isShuttingDown else { return "helper is shutting down" }
            guard let controller else { return "helper has no SMC connection" }
            do {
                let result = try controller.setTarget(fanIndex: index, rpm: targetRPM)
                hasForcedFans = true
                restartWatchdog()
                if !result.targetAccepted {
                    return "the SMC did not accept the target "
                         + "(asked \(Int(result.clampedRPM)), reads back "
                         + "\(result.readBackTarget.map { String(Int($0)) } ?? "nothing"))"
                }
                return nil
            } catch {
                return "\(error)"
            }
        }
    }

    func setAllAuto() -> String? {
        queue.sync {
            guard let controller else { return "helper has no SMC connection" }
            cancelWatchdog()
            let failures = controller.restoreAllAutomatic()
            hasForcedFans = false
            guard failures.isEmpty else {
                return failures.map { "fan \($0.key): \($0.value)" }.joined(separator: "; ")
            }
            log("all fans returned to automatic control")
            return nil
        }
    }

    func heartbeat() -> String? {
        queue.sync {
            guard hasForcedFans else { return nil }
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
        queue.sync { performRestore(reason: reason) }
    }

    // MARK: Client tracking

    /// Register an accepted client. Must be paired with `clientDisconnected`.
    func clientConnected() {
        queue.sync { activeClients += 1 }
    }

    /// Release the fans, but only once *every* client has gone.
    ///
    /// Restoring on any disconnect is wrong whenever more than one client exists,
    /// and more than one is routine: every `fanctl` invocation opens its own
    /// connection, and the diagnostics this project asks people to run in bug
    /// reports are `fanctl` commands. Running `fanctl helper-status` while a
    /// preset was active used to knock the fans straight back to automatic — the
    /// app was still connected and still sending its target, but a short-lived
    /// second client had just exited.
    ///
    /// The watchdog is unaffected and remains the backstop for a client that dies
    /// without its connection being torn down.
    func clientDisconnected() {
        queue.sync {
            activeClients = max(0, activeClients - 1)
            guard activeClients == 0 else {
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
    private func performRestore(reason: String) {
        guard hasForcedFans else { return }
        log("restoring automatic control (\(reason))")

        // Stop the other path from starting a competing restore.
        cancelWatchdog()

        let started = Date()
        let failures = controller?.restoreAllAutomatic() ?? [:]
        hasForcedFans = false

        let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
        if failures.isEmpty {
            log("fans returned to automatic control in \(elapsed)s")
        } else {
            log("restore finished in \(elapsed)s with problems: \(failures)")
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

final class HelperService: NSObject, FanHelperProtocol {
    func setFan(index: Int, targetRPM: Double, reply: @escaping (String?) -> Void) {
        reply(FanService.shared.setFan(index: index, targetRPM: targetRPM))
    }

    func setAllAuto(reply: @escaping (String?) -> Void) {
        reply(FanService.shared.setAllAuto())
    }

    func heartbeat(reply: @escaping (String?) -> Void) {
        reply(FanService.shared.heartbeat())
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

        connection.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        connection.exportedObject = HelperService()

        // The app going away is one of the paths that must end in automatic fans.
        // The watchdog would catch it too; this just makes it immediate.
        //
        // Counted rather than acted on directly: a `fanctl` command run alongside
        // the app is a second client, and its exit must not release fans the app
        // is still holding.
        FanService.shared.clientConnected()
        connection.invalidationHandler = {
            FanService.shared.clientDisconnected()
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

        case PowerMessage.systemWillSleep:
            // Sleep waits for the acknowledgement, so the fans are handed back
            // before the machine goes down rather than racing it.
            FanService.shared.emergencyRestore(reason: "system going to sleep")
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
installSignalHandlers()
observeSleep()

let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
let delegate = ListenerDelegate()
listener.delegate = delegate
listener.resume()

log("listening on \(HelperConstants.machServiceName)")
RunLoop.main.run()
