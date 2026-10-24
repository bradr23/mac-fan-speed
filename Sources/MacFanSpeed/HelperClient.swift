import Foundation
import SMCKit

/// Talks to the privileged daemon.
///
/// The app itself never writes to the SMC; every change goes through here, and
/// the daemon re-validates it.
@MainActor
final class HelperClient: ObservableObject {

    enum Status: Equatable {
        case checking
        case notInstalled
        case unreachable(String)
        case ready(version: String)

        var isReady: Bool { if case .ready = self { return true }; return false }

        var version: String? {
            if case .ready(let version) = self { return version }
            return nil
        }
    }

    @Published private(set) var status: Status = .checking

    /// The daemon is running a different build from this app.
    ///
    /// Updating the app means replacing `MacFanSpeed.app`. The daemon lives in
    /// `/usr/local/libexec` and is untouched by that, so it keeps running the
    /// version it was installed from — indefinitely, and silently, since it
    /// answers every request exactly as before. Anyone who updates the app and
    /// wonders why a fixed bug is still there would have no way to tell.
    ///
    /// Compared against `SMCKit.version` because that constant is compiled into
    /// both the app and the helper it ships with, and `scripts/release.sh`
    /// checks it against the bundle version.
    var isOutdated: Bool {
        Self.isOutdated(installed: status.version, bundled: SMCKit.version)
    }

    /// Split out so the comparison is testable without a running daemon.
    ///
    /// A nil installed version means the daemon is missing or not answering,
    /// which is a different problem with its own message — reporting it as
    /// "out of date" as well would send the user to the wrong button.
    static func isOutdated(installed: String?, bundled: String) -> Bool {
        guard let installed else { return false }
        return installed != bundled
    }

    /// Version this app would install, for the "installed X, bundled Y" message.
    var bundledVersion: String { SMCKit.version }

    /// The daemon is refusing this process because the app was replaced under it.
    ///
    /// Checked only when the connection is already failing: the underlying test
    /// is a code-signature validation, and there is no reason to pay for it while
    /// everything works.
    var needsRelaunch: Bool {
        guard case .unreachable = status else { return false }
        return AppCodeIdentity.wasReplacedWhileRunning
    }

    private var connection: NSXPCConnection?

    /// When the status was last re-checked after the daemon stopped answering.
    /// A transient failure otherwise left the app stuck: `sendTargets` refuses to
    /// run unless the helper is ready, and nothing re-tested it, so fan control
    /// stayed dead until the user found "Re-check" in Settings.
    private var lastUnreachableRetry: Date?
    private static let unreachableRetryInterval: TimeInterval = 10

    // MARK: Connection

    private func proxy() -> FanHelperProtocol? {
        if connection == nil {
            let new = NSXPCConnection(
                machServiceName: HelperConstants.machServiceName,
                options: .privileged
            )
            new.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
            new.invalidationHandler = { [weak self] in
                Task { @MainActor in self?.connection = nil }
            }
            new.interruptionHandler = { [weak self] in
                Task { @MainActor in self?.connection = nil }
            }
            new.resume()
            connection = new
        }
        return connection?.remoteObjectProxyWithErrorHandler { [weak self] error in
            Task { @MainActor in
                self?.status = .unreachable(error.localizedDescription)
                self?.connection = nil
            }
        } as? FanHelperProtocol
    }

    /// Ask the daemon for its version. Distinguishes "not installed" from
    /// "installed but not responding", because the fix differs.
    func refreshStatus() {
        guard FileManager.default.fileExists(atPath: HelperConstants.installedBinaryPath) else {
            status = .notInstalled
            return
        }
        guard let proxy = proxy() else {
            status = .unreachable("could not create a connection")
            return
        }
        proxy.version { version in
            Task { @MainActor in self.status = .ready(version: version) }
        }
    }

    /// Re-test a daemon that stopped answering, at most every few seconds.
    ///
    /// Called from the poll loop so the app recovers on its own from a daemon
    /// that was restarted, reinstalled, or briefly unreachable, instead of
    /// waiting for someone to open Settings and press "Re-check".
    func retryIfUnreachable() {
        guard case .unreachable = status else {
            lastUnreachableRetry = nil
            return
        }
        let now = Date()
        if let last = lastUnreachableRetry,
           now.timeIntervalSince(last) < Self.unreachableRetryInterval {
            return
        }
        lastUnreachableRetry = now
        refreshStatus()
    }

    // MARK: Commands

    func setFan(index: Int, rpm: Double, completion: @escaping (String?) -> Void = { _ in }) {
        guard let proxy = proxy() else {
            completion("helper unavailable")
            return
        }
        proxy.setFan(index: index, targetRPM: rpm) { error in
            Task { @MainActor in completion(error) }
        }
    }

    func setAllAuto(completion: @escaping (String?) -> Void = { _ in }) {
        guard let proxy = proxy() else {
            completion("helper unavailable")
            return
        }
        proxy.setAllAuto { error in
            Task { @MainActor in completion(error) }
        }
    }

    /// Blocking restore for the quit path, with a deadline.
    ///
    /// Termination will not wait for an async reply, and quitting with fans still
    /// forced is exactly what SPEC.md safety rule 2 forbids. The watchdog would
    /// catch it within 15 s, but leaving cleanly is better than relying on that.
    ///
    /// The deadline is the whole point. This used to call
    /// `synchronousRemoteObjectProxyWithErrorHandler`, which takes no timeout and
    /// whose error handler fires only for connection-level failures — not for a
    /// daemon that simply never replies. A user found the app wedged with its
    /// fans held: 2480 of 2480 samples of the main thread were inside that one
    /// call, `__NSXPCCONNECTION_IS_WAITING_FOR_A_SYNCHRONOUS_REPLY__`, reached
    /// from the Quit button through `applicationWillTerminate`. The UI was frozen
    /// and the app could not be quit at all. Whatever makes the daemon slow or
    /// silent, an app must not become unquittable because of it.
    ///
    /// So: the asynchronous proxy, whose reply arrives on an XPC-owned queue and
    /// therefore still lands while this thread is blocked, plus a semaphore with
    /// a deadline. The error handler here deliberately does not touch
    /// `@MainActor` state — this runs *on* the main thread with it blocked, so a
    /// `Task { @MainActor in … }` could never be scheduled, and the shared
    /// `proxy()` handler does exactly that.
    ///
    /// - Returns: true if the daemon confirmed before the deadline. On false the
    ///   caller should say so and let termination proceed: the daemon releases
    ///   the fans when the connection drops, which is measured at 2-4 s on the
    ///   developer's hardware and is what actually recovered the wedged app.
    ///
    /// Five seconds is chosen from both ends. Restores on the developer's
    /// hardware log 2.4-3.5 s, so it has to clear that or the clean path would
    /// usually lose a race it was winning. It must not be much more: this blocks
    /// the main thread, and at logout or restart macOS judges an app that stops
    /// answering as one holding up the shutdown — which this app has been
    /// accused of before.
    @discardableResult
    func setAllAutoSynchronously(timeout: TimeInterval = 5) -> Bool {
        guard FileManager.default.fileExists(atPath: HelperConstants.installedBinaryPath),
              let connection
        else { return false }

        let finished = DispatchSemaphore(value: 0)
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in finished.signal() }
        guard let helper = proxy as? FanHelperProtocol else { return false }
        helper.setAllAuto { _ in finished.signal() }

        return finished.wait(timeout: .now() + timeout) == .success
    }
}
