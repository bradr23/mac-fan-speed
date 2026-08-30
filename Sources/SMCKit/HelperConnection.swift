import Foundation

/// Minimal XPC client for the privileged daemon.
///
/// Used by `fanctl` so the daemon — including its watchdog — can be exercised
/// without the GUI. The app has its own observable wrapper around the same
/// protocol.
public final class HelperConnection {
    private var connection: NSXPCConnection?

    public init() {}

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: HelperConstants.installedBinaryPath)
    }

    private func proxy(
        onError: @escaping (String) -> Void
    ) -> FanHelperProtocol? {
        if connection == nil {
            let new = NSXPCConnection(
                machServiceName: HelperConstants.machServiceName,
                options: .privileged
            )
            new.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
            new.resume()
            connection = new
        }
        return connection?.remoteObjectProxyWithErrorHandler { error in
            onError(error.localizedDescription)
        } as? FanHelperProtocol
    }

    /// Synchronous wrappers, since `fanctl` is a straight-line command.
    private func waitFor(
        _ body: (FanHelperProtocol, @escaping (String?) -> Void) -> Void
    ) -> String? {
        var result: String? = "no response from the helper"
        let semaphore = DispatchSemaphore(value: 0)

        guard let proxy = proxy(onError: { message in
            result = message
            semaphore.signal()
        }) else {
            return "could not connect to the helper"
        }

        body(proxy) { error in
            result = error
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + 5) == .timedOut {
            return "timed out waiting for the helper"
        }
        return result
    }

    public func version() -> String? {
        var version: String?
        let semaphore = DispatchSemaphore(value: 0)
        guard let proxy = proxy(onError: { _ in semaphore.signal() }) else { return nil }
        proxy.version { value in
            version = value
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        return version
    }

    public func setFan(index: Int, rpm: Double) -> String? {
        waitFor { proxy, done in proxy.setFan(index: index, targetRPM: rpm, reply: done) }
    }

    public func setAllAuto() -> String? {
        waitFor { proxy, done in proxy.setAllAuto(reply: done) }
    }

    public func heartbeat() -> String? {
        waitFor { proxy, done in proxy.heartbeat(reply: done) }
    }
}
