import XCTest
@testable import MacFanSpeed

/// One test per defect found reviewing the fan-curve feature before release.
/// Each was confirmed by execution, not by reading, so each gets a test.
@MainActor
final class CurveRegressionTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    /// A NaN stored speed used to win against the safety floor.
    ///
    /// `max(.nan, x)` returns nan in Swift, so a corrupted preference silently
    /// disabled the escalation floor at every temperature, and the dropdown
    /// still reported the user's own setting as the driver.
    func testNonFiniteRequestCannotDefeatTheSafetyFloor() {
        var controller = CurveController()
        controller.reset(to: .nan)

        var commanded = 0.0
        var clock = start
        for _ in 0..<40 {
            clock = clock.addingTimeInterval(2)
            commanded = controller.step(
                requested: .nan, curve: nil, rawCelsius: 90, now: clock
            )
        }

        XCTAssertFalse(commanded.isNaN, "NaN must never reach the fan target")
        XCTAssertEqual(commanded, 1.0, accuracy: 0.01, "the floor must still apply at 90 °C")
        guard case .thermalGuard = controller.driver else {
            return XCTFail("the guard must report that it is driving, got \(controller.driver)")
        }
    }

    func testResetWithNonFiniteValueIsSanitised() {
        var controller = CurveController()
        controller.reset(to: .nan)
        XCTAssertFalse(controller.commanded.isNaN)
        XCTAssertEqual(controller.commanded, 0, accuracy: 0.001)
    }

    /// The floor was routed through the acoustic deadband, so the speed actually
    /// applied could sit several points below what the guard demanded for as
    /// long as the temperature stayed inside the band. Damping is for comfort;
    /// it does not get a say in the safety floor.
    func testTheFloorIsNotDampedByTheDeadband() {
        var controller = CurveController()
        controller.reset(to: 0)
        var clock = start

        // Settle at a temperature, then creep up by less than the deadband.
        for _ in 0..<30 {
            clock = clock.addingTimeInterval(2)
            _ = controller.step(requested: 0, curve: nil, rawCelsius: 78, now: clock)
        }
        for _ in 0..<40 {
            clock = clock.addingTimeInterval(2)
            _ = controller.step(requested: 0, curve: nil, rawCelsius: 79, now: clock)
        }

        let expected = ThermalGuard.percent(atCelsius: 79)
        XCTAssertEqual(
            controller.commanded, expected, accuracy: 0.02,
            "the applied floor must track ThermalGuard, not lag inside a deadband"
        )
    }

    // MARK: Curve editing

    /// Dragging one slider used to drag the whole curve with it, permanently.
    ///
    /// `normalised` enforces monotonicity by ratcheting later points upward,
    /// which is right for repairing decoded data and destructive for an edit:
    /// raising the first point flattened every other point to match, and
    /// lowering it again left them raised.
    func testEditingOnePointDoesNotFlattenTheRest() {
        var curve = FanCurve.defaultCurve
        let original = curve.points.map(\.percent)
        let firstID = curve.points[0].id

        // Drag the first row up, then back down, as a slider gesture does.
        for value in stride(from: 0.15, through: 0.90, by: 0.05) {
            curve.update(id: firstID, celsius: 40, percent: value)
        }
        for value in stride(from: 0.90, through: 0.20, by: -0.05) {
            curve.update(id: firstID, celsius: 40, percent: value)
        }
        // Explicit rather than relying on the stride landing exactly on 0.15,
        // which floating point does not guarantee.
        curve.update(id: firstID, celsius: 40, percent: 0.15)

        XCTAssertEqual(
            curve.points.map(\.percent), original,
            "the other control points must be exactly where they started"
        )
    }

    func testAnEditIsClampedByItsNeighboursRatherThanMovingThem() {
        var curve = FanCurve(points: [
            CurvePoint(celsius: 40, percent: 0.2),
            CurvePoint(celsius: 60, percent: 0.5),
            CurvePoint(celsius: 80, percent: 0.8),
        ])
        let middle = curve.points[1].id

        // Ask for more than the point above it allows.
        curve.update(id: middle, celsius: 60, percent: 0.95)
        XCTAssertEqual(curve.points[1].percent, 0.8, accuracy: 0.001, "clamped to its neighbour")
        XCTAssertEqual(curve.points[2].percent, 0.8, accuracy: 0.001, "the neighbour did not move")
        XCTAssertEqual(curve.points[0].percent, 0.2, accuracy: 0.001)
    }

    func testUpdateReportsWhenThePointWasCollapsedAway() {
        var curve = FanCurve(points: [
            CurvePoint(celsius: 40, percent: 0.2),
            CurvePoint(celsius: 55, percent: 0.5),
            CurvePoint(celsius: 80, percent: 0.8),
        ])
        let first = curve.points[0].id
        // Move it onto its neighbour; the two collapse.
        let survived = curve.update(id: first, celsius: 55, percent: 0.2)
        XCTAssertFalse(survived, "the editor needs to know its selection is gone")
        XCTAssertFalse(curve.points.contains { $0.id == first })
    }

    /// Truncation used to drop the hottest points, lowering the curve's maximum
    /// — the unsafe direction.
    func testTrimmingKeepsTheHottestPoint() {
        let many = (0..<20).map {
            CurvePoint(celsius: Double(20 + $0 * 4), percent: Double($0) / 19)
        }
        let curve = FanCurve(points: many)
        XCTAssertEqual(curve.points.count, FanCurve.maximumPoints)
        XCTAssertEqual(curve.maximumPercent, 1.0, accuracy: 0.001, "the top of the curve survives")
        XCTAssertEqual(
            curve.points.last?.celsius ?? 0, min(20.0 + 19 * 4, FanCurve.maximumCelsius),
            accuracy: 0.001
        )
    }

    // MARK: Persistence

    /// One bad control point used to wipe every preset: `PresetStore.load`
    /// treats any decode failure as "nothing saved" and falls back to built-ins.
    func testAMalformedCurveDoesNotDestroyTheUsersPresets() {
        let suite = "io.github.bradr23.MacFanSpeed.tests.badcurve"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        // The third preset's curve has a point missing "percent".
        let json = """
        [{"id":"11111111-1111-1111-1111-111111111111","name":"Mine A","percent":0.4,"isBuiltIn":false},
         {"id":"22222222-2222-2222-2222-222222222222","name":"Mine B","percent":0.6,"isBuiltIn":false},
         {"id":"33333333-3333-3333-3333-333333333333","name":"Broken","percent":0.5,"isBuiltIn":false,
          "curve":[{"celsius":40,"percent":0.2},{"celsius":80}]}]
        """
        defaults.set(Data(json.utf8), forKey: "fanPresets")

        let store = PresetStore(defaults: defaults)
        XCTAssertNotNil(store.presets.first { $0.name == "Mine A" }, "unrelated presets must survive")
        XCTAssertNotNil(store.presets.first { $0.name == "Mine B" })

        let broken = store.presets.first { $0.name == "Broken" }
        XCTAssertNotNil(broken, "the profile itself survives")
        XCTAssertNil(broken?.curve, "only the unreadable curve is dropped")
    }

    /// Decoding bypasses the memberwise init, so the clamp there did not apply.
    func testDecodedPercentIsClamped() throws {
        let json = #"{"id":"11111111-1111-1111-1111-111111111111","name":"X","percent":9.0,"isBuiltIn":false}"#
        let preset = try JSONDecoder().decode(FanPreset.self, from: Data(json.utf8))
        XCTAssertEqual(preset.percent, 1.0, "an out-of-range stored speed must be clamped on read")
    }

    func testNonFinitePreferencesAreSanitisedOnRead() {
        let suite = "io.github.bradr23.MacFanSpeed.tests.nanprefs"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(Double.nan, forKey: "manualPercent")
        defaults.set(["0": Double.nan, "1": 0.4], forKey: "perFanPercent")

        let settings = AppSettings(defaults: defaults)
        XCTAssertFalse(settings.manualPercent.isNaN)
        XCTAssertFalse(settings.perFanPercent.values.contains { $0.isNaN })
        XCTAssertEqual(settings.perFanPercent["1"], 0.4, "valid entries are kept")
    }
}
