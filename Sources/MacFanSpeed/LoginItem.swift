import Foundation
import ServiceManagement

/// Starting the app at login.
///
/// `SMAppService.mainApp` is the modern API and needs no files on disk, but it
/// reports `.notFound` for this app however it is launched and wherever it lives
/// — verified from `~/Applications` and via LaunchServices, not just from a build
/// directory. The cause is the same one that rules out `SMAppService.daemon`:
/// registration requires a real code-signing identity, and this project ships
/// ad-hoc signed.
///
/// So the login item is a user LaunchAgent written directly. That needs no
/// privileges at all — `~/Library/LaunchAgents` belongs to the user — and works
/// regardless of signing. If a Developer ID is obtained later, `SMAppService` can
/// replace this; `isUsingModernAPI` already reports when that becomes possible.
enum LoginItemManager {

    static let label = "io.github.bradr23.MacFanSpeed"

    static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// True when `SMAppService` would work, in which case it should be preferred.
    static var isUsingModernAPI: Bool {
        SMAppService.mainApp.status != .notFound
    }

    static var isEnabled: Bool {
        if isUsingModernAPI { return SMAppService.mainApp.status == .enabled }
        guard let contents = try? String(contentsOf: plistURL, encoding: .utf8) else {
            return false
        }
        // A plist pointing at an app that has since moved is not a working login
        // item, so treat a stale path as disabled rather than reporting success.
        return contents.contains(executablePath)
    }

    private static var executablePath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/MacFanSpeed")
            .path
    }

    /// - Returns: an error message, or nil on success.
    static func setEnabled(_ enabled: Bool) -> String? {
        if isUsingModernAPI {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        return enabled ? writeAgent() : removeAgent()
    }

    private static func writeAgent() -> String? {
        let directory = plistURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        } catch {
            return "Could not create \(directory.path): \(error.localizedDescription)"
        }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            // Not KeepAlive: quitting the app should keep it quit until the next
            // login, not have launchd restart it immediately.
            "ProcessType": "Interactive",
        ]

        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            )
            try data.write(to: plistURL, options: .atomic)
            return nil
        } catch {
            return "Could not write the login item: \(error.localizedDescription)"
        }
    }

    private static func removeAgent() -> String? {
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return nil }
        do {
            try FileManager.default.removeItem(at: plistURL)
            return nil
        } catch {
            return "Could not remove the login item: \(error.localizedDescription)"
        }
    }
}
