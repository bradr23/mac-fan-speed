import Foundation

/// Names shared by the app and the daemon.
public enum HelperConstants {
    public static let machServiceName = "io.github.bradr23.MacFanSpeed.helper"
    public static let appBundleIdentifier = "io.github.bradr23.MacFanSpeed"
    public static let installedBinaryPath = "/usr/local/libexec/MacFanSpeedHelper"
    public static let launchDaemonPlistPath =
        "/Library/LaunchDaemons/io.github.bradr23.MacFanSpeed.helper.plist"

    /// If no command arrives within this window, the helper hands the fans back
    /// to macOS. The app heartbeats every 2 s, so a crashed or killed app is
    /// caught quickly.
    public static let watchdogTimeout: TimeInterval = 15
}

/// The complete set of privileged operations.
///
/// There is deliberately no generic "write SMC key" call: the daemon exposes
/// only fan targets and a release-to-automatic, and re-validates both against
/// limits it reads itself.
@objc public protocol FanHelperProtocol {
    /// Set one fan's target. `reply` carries nil on success or a message on
    /// failure. The daemon clamps independently of whatever the client sent.
    func setFan(index: Int, targetRPM: Double, reply: @escaping (String?) -> Void)

    /// Hand every fan back to macOS.
    func setAllAuto(reply: @escaping (String?) -> Void)

    /// Keeps the watchdog from firing while the app is alive and in manual mode.
    func heartbeat(reply: @escaping (String?) -> Void)

    /// Helper version, used by the app to detect a stale installed daemon.
    func version(reply: @escaping (String) -> Void)
}
