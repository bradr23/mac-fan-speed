import Foundation

/// Temperature limits shared by the app and the privileged daemon.
///
/// These live in SMCKit rather than in the app because the **daemon** needs them
/// too, and the daemon must not take a threshold from a client. Its own limit is
/// compiled in.
public enum ThermalLimits {

    /// **Not a measurement.** Apple has never published a junction temperature
    /// for any M-series chip, and nothing on the machine exposes one: all 3222
    /// SMC keys on a Mac16,8 were enumerated and none is a limit. The most
    /// convincing candidate — `mlTJ`/`mlTj`, reading 100.00, with `Tj` the
    /// industry notation for junction temperature — is element ten of a
    /// twelve-entry percentage table.
    ///
    /// So this is an assumption, and it is named like one. Do not raise it.
    public static let assumedCriticalCelsius: Double = 100

    /// The highest cutoff anything in this project may use, five degrees below
    /// the assumed critical point. Also the shipped default.
    public static let maximumTripCelsius: Double = assumedCriticalCelsius - 5
    public static let minimumTripCelsius: Double = 60
    public static let hysteresisCelsius: Double = 10

    /// The daemon's own ceiling.
    ///
    /// Deliberately the maximum rather than the user's setting. The app's cutoff
    /// can only ever be lower, so in normal use the app trips first and this is
    /// never reached; it exists for the case where the client is not the app, or
    /// is not doing its job. A client cannot change it.
    public static var daemonTripCelsius: Double { maximumTripCelsius }
    public static var daemonResetCelsius: Double { maximumTripCelsius - hysteresisCelsius }

    public static var settableRange: ClosedRange<Double> {
        minimumTripCelsius...maximumTripCelsius
    }

    /// Clamp a user-supplied cutoff. Non-finite input yields the default rather
    /// than a bound, because `min(max(.nan, lo), hi)` is `nan` in Swift — every
    /// comparison against nan is false, so a naive clamp passes it straight
    /// through.
    public static func clampTrip(_ value: Double) -> Double {
        guard value.isFinite else { return maximumTripCelsius }
        return Swift.min(Swift.max(value, minimumTripCelsius), maximumTripCelsius)
    }
}
