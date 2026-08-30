import Foundation
import SMCKit

/// Installs and removes the privileged daemon from inside the app bundle.
///
/// Everything the installer needs — the helper binary, its launchd plist and the
/// scripts — ships inside `MacFanSpeed.app`, so a machine that has only the
/// downloaded app can still enable fan control. Nothing here depends on the
/// source tree.
///
/// `SMAppService.daemon` would be the modern route and would need no password,
/// but it requires a real code-signing identity that this project does not have.
/// The fallback is the standard authorization prompt, which is why enabling fan
/// control asks for an administrator password once.
@MainActor
final class HelperInstaller: ObservableObject {

    enum Result: Equatable {
        case installed
        case removed
        case cancelled
        case failed(String)
    }

    @Published private(set) var lastResult: Result?
    @Published private(set) var isWorking = false

    /// Paths inside the running bundle.
    private var resourceURL: URL? { Bundle.main.resourceURL }

    var isBundleComplete: Bool {
        guard let resourceURL else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: resourceURL.appendingPathComponent("MacFanSpeedHelper").path)
            && fm.fileExists(atPath: resourceURL.appendingPathComponent("install-helper.sh").path)
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: HelperConstants.installedBinaryPath)
    }

    func install(completion: @escaping (Result) -> Void) {
        run(script: "install-helper.sh", success: .installed, completion: completion)
    }

    func uninstall(completion: @escaping (Result) -> Void) {
        run(script: "uninstall-helper.sh", success: .removed, completion: completion)
    }

    private func run(
        script: String,
        success: Result,
        completion: @escaping (Result) -> Void
    ) {
        guard let scriptURL = resourceURL?.appendingPathComponent(script),
              FileManager.default.fileExists(atPath: scriptURL.path)
        else {
            let result = Result.failed(
                "This build is missing \(script). Rebuild with scripts/build.sh."
            )
            lastResult = result
            completion(result)
            return
        }

        isWorking = true
        let path = scriptURL.path

        // AppleScript's authorization prompt blocks, so keep it off the main
        // thread and let the UI keep updating behind the dialog.
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Self.runPrivileged(scriptPath: path, success: success)
            DispatchQueue.main.async {
                self.isWorking = false
                self.lastResult = outcome
                completion(outcome)
            }
        }
    }

    private nonisolated static func runPrivileged(
        scriptPath: String,
        success: Result
    ) -> Result {
        // Quote the path so spaces in the bundle location — /Applications is
        // fine, but a user folder may well contain them — do not split the command.
        let quoted = scriptPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"/bin/bash \\\"\(quoted)\\\"\" with administrator privileges"

        guard let script = NSAppleScript(source: source) else {
            return .failed("Could not build the installation command.")
        }

        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)

        guard let errorInfo else { return success }

        // -128 is the user dismissing the password prompt, which is a choice
        // rather than a fault and should not be reported as an error.
        if let code = errorInfo[NSAppleScript.errorNumber] as? Int, code == -128 {
            return .cancelled
        }
        let message = errorInfo[NSAppleScript.errorMessage] as? String
            ?? "The installation command failed."
        return .failed(message)
    }
}
