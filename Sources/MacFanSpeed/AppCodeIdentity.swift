import Foundation
import Security

/// Whether this process still matches the app bundle it was launched from.
enum AppCodeIdentity {

    /// True when the bundle on disk has been replaced since this process started.
    ///
    /// This is the ordinary way people update a Mac app: drag the new version
    /// into Applications, choose Replace, and carry on. The old process keeps
    /// running against a bundle that is no longer its own.
    ///
    /// It matters here because the privileged daemon validates its client's code
    /// signature, and it can only do so against the binary on disk — inspecting a
    /// user-session process from the system domain is not permitted, so the
    /// direct check is unavailable. A swapped bundle therefore fails with
    /// `errSecCSStaticCodeChanged`, the daemon refuses the connection, and all
    /// the app can report is "Couldn't communicate with a helper application" —
    /// which says nothing about the fix, and looks exactly like a broken install.
    ///
    /// Quitting and reopening resolves it completely.
    ///
    /// Cached once true, since it cannot become false again for this process.
    static var wasReplacedWhileRunning: Bool {
        if cachedResult { return true }

        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else {
            return false
        }
        // No requirement: this asks only whether the running code still matches
        // its own on-disk representation, not whether it satisfies some identity.
        if SecCodeCheckValidity(selfCode, [], nil) == errSecCSStaticCodeChanged {
            cachedResult = true
        }
        return cachedResult
    }

    private static var cachedResult = false
}
