import XCTest
@testable import MacFanSpeed

/// The controller is what stops the fans hunting audibly. A correctly working
/// deadband looks identical to a broken one from the outside, so it is pinned
/// down here rather than judged by ear.
///
/// Time is injected throughout; nothing here sleeps.
final class CurveControllerTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000_000)
    private func tick(_ n: Int) -> Date { start.addingTimeInterval(Double(n) * 2) }

    private func curve(_ pairs: [(Double, Double)]) -> FanCurve {
        FanCurve(points: pairs.map { CurvePoint(celsius: $0.0, percent: $0.1) })
    }

    // MARK: Filter

    /// A sustained rise is taken at full value as soon as the median confirms
    /// it — one extra sample, no exponential lag on top. That one sample is the
    /// price of rejecting spikes, and the failsafe never pays it: it reads the
    /// raw maximum.
    func testASustainedRiseIsAdoptedInFullOnceConfirmed() {
        var filter = TemperatureFilter()
        _ = filter.step(50)
        _ = filter.step(50)
        _ = filter.step(50)

        let firstHot = filter.step(90)
        XCTAssertEqual(firstHot, 50, accuracy: 0.001, "one sample is held back")

        let confirmed = filter.step(90)
        XCTAssertEqual(confirmed, 90, accuracy: 0.001, "then adopted in full, not averaged")
    }

    func testFilterDecaysSlowlyWhenCooling() {
        var filter = TemperatureFilter()
        for _ in 0..<4 { _ = filter.step(90) }
        _ = filter.step(50)
        let cooled = filter.step(50)
        // Somewhere between the two, not straight down to the new value.
        XCTAssertLessThan(cooled, 90)
        XCTAssertGreaterThan(cooled, 50)
    }

    /// The asymmetry is the safety property: the filter can under-report how
    /// cool the machine is, never how hot.
    func testCoolingIsSlowerThanHeating() {
        var heating = TemperatureFilter()
        for _ in 0..<3 { _ = heating.step(50) }
        _ = heating.step(90)
        let afterRise = heating.step(90)

        var cooling = TemperatureFilter()
        for _ in 0..<3 { _ = cooling.step(90) }
        _ = cooling.step(50)
        let afterFall = cooling.step(50)

        XCTAssertEqual(afterRise, 90, accuracy: 0.001)
        XCTAssertGreaterThan(afterFall, 55, "cooling should still be decaying")
    }

    func testMedianRejectsASingleSampleSpike() {
        // The failsafe reads the raw max; this filter exists so one core's
        // transient does not slam the fans.
        var filter = TemperatureFilter()
        _ = filter.step(50)
        _ = filter.step(50)
        let spiked = filter.step(95)
        XCTAssertLessThan(spiked, 95, "a lone spike should not reach the output")
    }

    func testFilterPassesThroughBeforeTheWindowFills() {
        var filter = TemperatureFilter()
        XCTAssertEqual(filter.step(62), 62, accuracy: 0.001)
    }

    // MARK: Deadband

    func testSmallTemperatureWobblesDoNotMoveTheFans() {
        var track = HysteresisTrack()
        let c = curve([(40, 0), (90, 1)])

        let first = track.step(curveValue: c.percent(atCelsius: 70), atCelsius: 70)
        let wobble = track.step(curveValue: c.percent(atCelsius: 70.8), atCelsius: 70.8)
        XCTAssertEqual(first, wobble, "0.8 °C is inside the deadband")
    }

    func testALargeRiseCommitsImmediately() {
        var track = HysteresisTrack()
        let c = curve([(40, 0), (90, 1)])
        _ = track.step(curveValue: c.percent(atCelsius: 70), atCelsius: 70)
        let hotter = track.step(curveValue: c.percent(atCelsius: 76), atCelsius: 76)
        XCTAssertGreaterThan(hotter, c.percent(atCelsius: 70) - 0.001)
        XCTAssertEqual(hotter, c.percent(atCelsius: 76), accuracy: 0.001)
    }

    /// Asymmetric on purpose: a machine hovering at its equilibrium settles on
    /// the higher of the two speeds, never the lower.
    func testTheDownBandIsWiderThanTheUpBand() {
        XCTAssertGreaterThan(
            CurveTuning.shipped.deadbandDownCelsius,
            CurveTuning.shipped.deadbandUpCelsius
        )

        var track = HysteresisTrack()
        let c = curve([(40, 0), (90, 1)])
        _ = track.step(curveValue: c.percent(atCelsius: 70), atCelsius: 70)

        // 2 °C down is inside the wider band and must not commit...
        let slightlyCooler = track.step(curveValue: c.percent(atCelsius: 68), atCelsius: 68)
        XCTAssertEqual(slightlyCooler, c.percent(atCelsius: 70), accuracy: 0.001)

        // ...while 2 °C up would have.
        var upTrack = HysteresisTrack()
        _ = upTrack.step(curveValue: c.percent(atCelsius: 70), atCelsius: 70)
        let warmer = upTrack.step(curveValue: c.percent(atCelsius: 72), atCelsius: 72)
        XCTAssertEqual(warmer, c.percent(atCelsius: 72), accuracy: 0.001)
    }

    /// The band is drawn around the last committed change, not around a curve
    /// point — otherwise it does nothing between points, which is where the fan
    /// spends essentially all its time.
    func testTheBandTracksTheOperatingPointNotCurvePoints() {
        var track = HysteresisTrack()
        let c = curve([(40, 0), (90, 1)])
        // 63 °C is nowhere near a control point.
        _ = track.step(curveValue: c.percent(atCelsius: 63), atCelsius: 63)
        let wobble = track.step(curveValue: c.percent(atCelsius: 63.9), atCelsius: 63.9)
        XCTAssertEqual(wobble, c.percent(atCelsius: 63), accuracy: 0.001)
    }

    func testUserActionsBypassTheDeadband() {
        var track = HysteresisTrack()
        _ = track.step(curveValue: 0.5, atCelsius: 70)
        let moved = track.step(curveValue: 0.9, atCelsius: 70.1, immediate: true)
        XCTAssertEqual(moved, 0.9, accuracy: 0.001)
    }

    // MARK: Slew

    func testSpeedRampsRatherThanStepping() {
        var slew = SlewLimiter(startingAt: 0.2)
        _ = slew.step(towards: 0.2, now: start)
        let after2s = slew.step(towards: 1.0, now: tick(1))
        XCTAssertGreaterThan(after2s, 0.2)
        XCTAssertLessThan(after2s, 1.0, "should not jump the whole way in one poll")
    }

    func testEscalationIsFasterThanDeEscalation() {
        XCTAssertGreaterThan(
            CurveTuning.shipped.slewUpPerSecond,
            CurveTuning.shipped.slewDownPerSecond
        )
    }

    func testFullEscalationCompletesWithinAFewSeconds() {
        var slew = SlewLimiter(startingAt: 0)
        _ = slew.step(towards: 0, now: start)
        let value = slew.step(towards: 1.0, now: start.addingTimeInterval(5))
        XCTAssertEqual(value, 1.0, accuracy: 0.001, "escalation must not be sluggish")
    }

    func testUserActionsBypassTheRateLimit() {
        var slew = SlewLimiter(startingAt: 1.0)
        _ = slew.step(towards: 1.0, now: start)
        let dropped = slew.step(towards: 0.2, now: tick(1), immediate: true)
        XCTAssertEqual(dropped, 0.2, accuracy: 0.001)
    }

    /// A wake from sleep leaves a large gap; trusting it would let the limiter
    /// jump the whole range in one step for the wrong reason.
    func testAnImplausibleTimeGapSnapsRatherThanExtrapolating() {
        var slew = SlewLimiter(startingAt: 0.1)
        _ = slew.step(towards: 0.1, now: start)
        let value = slew.step(towards: 0.8, now: start.addingTimeInterval(3600))
        XCTAssertEqual(value, 0.8, accuracy: 0.001)
    }

    func testOutputStaysInRange() {
        var slew = SlewLimiter(startingAt: 0.5)
        _ = slew.step(towards: 0.5, now: start)
        XCTAssertLessThanOrEqual(slew.step(towards: 5, now: tick(1)), 1.0)
        XCTAssertGreaterThanOrEqual(slew.step(towards: -5, now: tick(2)), 0.0)
    }

    // MARK: Composition — the user's stated case

    /// A flat 15% setting, machine heating under load. The guard has to take
    /// over without the user's setting ever being rewritten.
    func testFlatSettingIsRaisedByTheGuardAsTheMachineHeats() {
        var controller = CurveController()
        controller.reset(to: 0.15)

        // Cool: the user's setting stands.
        var value = controller.step(
            requested: 0.15, curve: nil, rawCelsius: 50, now: start, immediate: true
        )
        XCTAssertEqual(value, 0.15, accuracy: 0.01)
        XCTAssertEqual(controller.driver, .user)

        // Hot: hold it there long enough for the filter and limiter to settle.
        for index in 1...40 {
            value = controller.step(
                requested: 0.15, curve: nil, rawCelsius: 85, now: tick(index)
            )
        }
        XCTAssertGreaterThan(value, 0.6, "the guard should be leading by 85 °C")
        guard case .thermalGuard = controller.driver else {
            return XCTFail("expected the guard to be driving, got \(controller.driver)")
        }
    }

    func testCurveDrivesWhenTheProfileHasOne() {
        var controller = CurveController()
        controller.reset(to: 0)
        let c = curve([(30, 0.15), (50, 0.50)])

        let value = controller.step(
            requested: 0, curve: c, rawCelsius: 50, now: start, immediate: true
        )
        XCTAssertEqual(value, 0.50, accuracy: 0.01)
        XCTAssertEqual(controller.driver, .profileCurve)
    }

    func testGuardOverridesACurveThatIsTooLowForTheTemperature() {
        var controller = CurveController()
        controller.reset(to: 0)
        // A curve that asks for very little even when hot.
        let lazy = curve([(30, 0.05), (95, 0.10)])

        var value = 0.0
        for index in 0...40 {
            value = controller.step(
                requested: 0, curve: lazy, rawCelsius: 88, now: tick(index)
            )
        }
        XCTAssertGreaterThan(value, 0.8, "the floor applies to curves as well")
    }

    func testUnknownTemperatureCommandsMaximum() {
        var controller = CurveController()
        controller.reset(to: 0.15)
        let value = controller.step(
            requested: 0.15, curve: nil, rawCelsius: nil, now: start, immediate: true
        )
        XCTAssertEqual(value, 1.0, accuracy: 0.001)
    }

    func testResetClearsStateSoAGapCannotGovernTheNextCommit() {
        var controller = CurveController()
        controller.reset(to: 0)
        _ = controller.step(requested: 0, curve: nil, rawCelsius: 88, now: start)
        controller.reset(to: 0.2)
        XCTAssertNil(controller.filteredCelsius)
        XCTAssertEqual(controller.commanded, 0.2, accuracy: 0.001)
        XCTAssertEqual(controller.driver, .user)
    }

    /// Whatever the temperature, whatever the curve, the commanded value can
    /// never fall below the floor for that temperature once settled.
    func testCommandedSpeedNeverFallsBelowTheGuard() {
        for temperature in stride(from: 30.0, through: 94.0, by: 4) {
            var controller = CurveController()
            controller.reset(to: 0)
            var value = 0.0
            for index in 0...60 {
                value = controller.step(
                    requested: 0, curve: nil, rawCelsius: temperature, now: tick(index)
                )
            }
            let floor = ThermalGuard.percent(atCelsius: temperature)
            XCTAssertGreaterThanOrEqual(
                value, floor - 0.02,
                "at \(temperature) °C commanded \(value) is below the floor \(floor)"
            )
        }
    }
}
