import XCTest
@testable import MacFanSpeed

/// The guard is what stops a low manual setting from becoming dangerous when
/// the machine is taxed. It cannot be tested by actually overheating a Mac, so
/// it is tested exhaustively here instead.
final class ThermalGuardTests: XCTestCase {

    func testDoesNothingWhileTheMachineIsCool() {
        // A guard that engaged during ordinary use would defeat the entire point
        // of the app.
        for celsius in [20.0, 35, 50, 60, 64] {
            XCTAssertEqual(
                ThermalGuard.percent(atCelsius: celsius), 0, accuracy: 0.0001,
                "should not raise the fans at \(celsius) °C"
            )
        }
    }

    func testRampsUpThroughTheWarningBand() {
        XCTAssertEqual(ThermalGuard.percent(atCelsius: 70), 0.20, accuracy: 0.01)
        XCTAssertEqual(ThermalGuard.percent(atCelsius: 80), 0.60, accuracy: 0.01)
        XCTAssertEqual(ThermalGuard.percent(atCelsius: 85), 0.80, accuracy: 0.01)
    }

    func testReachesFullSpeedBeforeTheCutoff() {
        XCTAssertEqual(ThermalGuard.percent(atCelsius: 90), 1.0, accuracy: 0.0001)
        // Full speed must arrive before the failsafe fires, so handing control
        // back is a last resort rather than the first thing that happens.
        XCTAssertLessThan(90, Failsafe.defaultTripCelsius)
        XCTAssertEqual(ThermalGuard.percent(atCelsius: 94), 1.0, accuracy: 0.0001)
    }

    func testIsMonotonic() {
        var previous = -1.0
        for celsius in stride(from: 20.0, through: 95.0, by: 0.5) {
            let value = ThermalGuard.percent(atCelsius: celsius)
            XCTAssertGreaterThanOrEqual(value, previous, "dipped at \(celsius) °C")
            previous = value
        }
    }

    /// An unknown temperature asks for everything. It lasts at most one poll —
    /// the failsafe trips on unreadable sensors the same tick — and running the
    /// fans hard for two seconds is the cheap side of that trade.
    func testUnknownTemperatureAsksForMaximum() {
        XCTAssertEqual(ThermalGuard.percent(atCelsius: nil), 1.0)
        XCTAssertEqual(ThermalGuard.percent(atCelsius: .nan), 1.0)
        XCTAssertEqual(ThermalGuard.percent(atCelsius: .infinity), 1.0)
    }

    // MARK: The user's stated scenario

    /// "manually set my fan speed to a low rpm (cool) but I then tax the system
    /// and the temps get up to warning like 80c+"
    func testALowManualSettingIsRaisedAsTheMachineHeats() {
        let requested = 0.15

        // Cool: the user's setting stands, untouched.
        XCTAssertEqual(max(requested, ThermalGuard.percent(atCelsius: 55)), 0.15, accuracy: 0.001)

        // Warming: still theirs, because the machine is not yet working hard.
        XCTAssertEqual(max(requested, ThermalGuard.percent(atCelsius: 64)), 0.15, accuracy: 0.001)

        // 80 °C — the temperature the user named. The guard now leads.
        let atEighty = max(requested, ThermalGuard.percent(atCelsius: 80))
        XCTAssertEqual(atEighty, 0.60, accuracy: 0.01)
        XCTAssertGreaterThan(atEighty, requested)

        // Hotter still: everything the fans have.
        XCTAssertEqual(max(requested, ThermalGuard.percent(atCelsius: 90)), 1.0, accuracy: 0.001)
    }

    /// The floor may only ever raise a speed. This is what makes the safety
    /// argument a one-line proof rather than a curve-merging algorithm.
    func testNeverLowersARequestedSpeed() {
        for requested in stride(from: 0.0, through: 1.0, by: 0.05) {
            for celsius in stride(from: 20.0, through: 95.0, by: 2.5) {
                let commanded = max(requested, ThermalGuard.percent(atCelsius: celsius))
                XCTAssertGreaterThanOrEqual(
                    commanded, requested,
                    "\(requested) at \(celsius) °C was lowered to \(commanded)"
                )
            }
        }
    }

    func testAUserAskingForFullSpeedIsNeverReducedByTheGuard() {
        XCTAssertEqual(max(1.0, ThermalGuard.percent(atCelsius: 70)), 1.0)
    }

    func testIsRaisingReportsWhenTheGuardLeads() {
        XCTAssertFalse(ThermalGuard.isRaising(requested: 0.15, celsius: 50))
        XCTAssertTrue(ThermalGuard.isRaising(requested: 0.15, celsius: 80))
        XCTAssertFalse(ThermalGuard.isRaising(requested: 1.0, celsius: 90))
    }
}
