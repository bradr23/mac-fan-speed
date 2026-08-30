import XCTest
@testable import MacFanSpeed

/// The cutoff is settable downward and must never be raisable. These cover the
/// clamp that the safety argument rests on — the UI's slider bounds and the
/// settings clamps are conveniences layered on top of it.
final class SafetyCutoffTests: XCTestCase {

    func testCeilingIsFiveDegreesBelowTheAssumedCriticalPoint() {
        XCTAssertEqual(
            Failsafe.maximumTripCelsius,
            Failsafe.assumedCriticalCelsius - 5
        )
    }

    /// The ceiling equals the threshold the app has always shipped, so adding
    /// the setting cannot make any machine hotter than the previous release did.
    func testCeilingMatchesThePreviouslyHardcodedThreshold() {
        XCTAssertEqual(Failsafe.maximumTripCelsius, 95)
        XCTAssertEqual(Failsafe.defaultTripCelsius, 95)
    }

    func testCannotBeSetAboveTheCeiling() {
        for attempt in [96.0, 100, 105, 150, 10_000] {
            XCTAssertEqual(
                Failsafe(tripCelsius: attempt).tripCelsius,
                Failsafe.maximumTripCelsius,
                "\(attempt) °C must be refused"
            )
        }
    }

    func testCanBeSetLower() {
        XCTAssertEqual(Failsafe(tripCelsius: 80).tripCelsius, 80)
        XCTAssertEqual(Failsafe(tripCelsius: 70).tripCelsius, 70)
    }

    func testCannotBeSetBelowTheFloor() {
        XCTAssertEqual(Failsafe(tripCelsius: 10).tripCelsius, Failsafe.minimumTripCelsius)
        XCTAssertEqual(Failsafe(tripCelsius: -100).tripCelsius, Failsafe.minimumTripCelsius)
    }

    /// `min(max(.nan, lo), hi)` is nan in Swift, because every comparison
    /// against nan is false. A naive clamp would pass it straight through into
    /// the trip threshold, where it would never compare true and so never trip.
    func testNonFiniteValuesFallBackToTheDefaultNotABound() {
        XCTAssertEqual(Failsafe.clampTrip(.nan), Failsafe.defaultTripCelsius)
        XCTAssertEqual(Failsafe.clampTrip(.infinity), Failsafe.defaultTripCelsius)
        XCTAssertEqual(Failsafe.clampTrip(-.infinity), Failsafe.defaultTripCelsius)
        XCTAssertFalse(Failsafe(tripCelsius: .nan).tripCelsius.isNaN)
    }

    func testSetTripIsAlsoClamped() {
        var failsafe = Failsafe(tripCelsius: 80)
        failsafe.setTrip(99)
        XCTAssertEqual(failsafe.tripCelsius, Failsafe.maximumTripCelsius)
        failsafe.setTrip(.nan)
        XCTAssertEqual(failsafe.tripCelsius, Failsafe.defaultTripCelsius)
    }

    func testResetIsAlwaysBelowTrip() {
        // Derived rather than settable, so the ordering holds by construction.
        for trip in stride(from: Failsafe.minimumTripCelsius,
                           through: Failsafe.maximumTripCelsius, by: 1) {
            let failsafe = Failsafe(tripCelsius: trip)
            XCTAssertLessThan(failsafe.resetCelsius, failsafe.tripCelsius)
        }
    }

    func testSettableRangeNeverReachesTheAssumedCriticalPoint() {
        XCTAssertLessThan(
            Failsafe.settableRange.upperBound, Failsafe.assumedCriticalCelsius
        )
    }

    // MARK: Persisted settings

    @MainActor
    func testStoredValueAboveTheCeilingIsClampedOnRead() {
        // Simulates a hand-edited preferences file or `defaults write`.
        let suite = "io.github.bradr23.MacFanSpeed.tests.cutoff-read"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(130.0, forKey: "safetyCutoffCelsius")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.safetyCutoffCelsius, Failsafe.maximumTripCelsius)
    }

    @MainActor
    func testAssigningAnUnsafeValueIsClampedOnWrite() {
        let suite = "io.github.bradr23.MacFanSpeed.tests.cutoff-write"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.safetyCutoffCelsius = 120
        XCTAssertEqual(settings.safetyCutoffCelsius, Failsafe.maximumTripCelsius)
        XCTAssertEqual(
            defaults.double(forKey: "safetyCutoffCelsius"), Failsafe.maximumTripCelsius
        )
    }

    @MainActor
    func testLoweringPersists() {
        let suite = "io.github.bradr23.MacFanSpeed.tests.cutoff-lower"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.safetyCutoffCelsius = 85
        XCTAssertEqual(AppSettings(defaults: defaults).safetyCutoffCelsius, 85)
    }
}
