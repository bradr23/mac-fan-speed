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
    }

    @Published private(set) var status: Status = .checking

    private var connection: NSXPCConnection?

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

    func heartbeat() {
        proxy()?.heartbeat { _ in }
    }

    /// Blocking restore for the quit path.
    ///
    /// Termination will not wait for an async reply, and quitting with fans still
    /// forced is exactly what SPEC.md safety rule 2 forbids. The watchdog would
    /// catch it within 15 s, but leaving cleanly is better than relying on that.
    func setAllAutoSynchronously() {
        guard FileManager.default.fileExists(atPath: HelperConstants.installedBinaryPath),
              let connection
        else { return }

        let proxy = connection.synchronousRemoteObjectProxyWithErrorHandler { _ in }
        (proxy as? FanHelperProtocol)?.setAllAuto { _ in }
    }
}
