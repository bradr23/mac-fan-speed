import XCTest
@testable import MacFanSpeed

/// Covers the menu bar display paths, including the ones that cannot be produced
/// on the developer's Mac: a fanless machine, and sensors that stop responding.
final class MenuBarFormatterTests: XCTestCase {

    // MARK: Fan speed

    func testCompactRPMFormatting() {
        XCTAssertEqual(MenuBarFormatter.rpm(2400), "2.4k")
        XCTAssertEqual(MenuBarFormatter.rpm(7826), "7.8k")
        XCTAssertEqual(MenuBarFormatter.rpm(1000), "1.0k")
    }

    func testSubThousandRPMShownExactly() {
        XCTAssertEqual(MenuBarFormatter.rpm(0), "0")
        XCTAssertEqual(MenuBarFormatter.rpm(850), "850")
    }

    func testUnreadableRPMUsesPlaceholder() {
        XCTAssertEqual(MenuBarFormatter.rpm(nil), "----")
    }

    // MARK: Temperature

    func testTemperatureRoundsToWholeDegrees() {
        XCTAssertEqual(MenuBarFormatter.temperature(38.8, unit: .celsius), "39°")
        XCTAssertEqual(MenuBarFormatter.temperature(38.2, unit: .celsius), "38°")
    }

    func testFahrenheitConversion() {
        XCTAssertEqual(MenuBarFormatter.temperature(100, unit: .fahrenheit), "212°")
        XCTAssertEqual(MenuBarFormatter.temperature(0, unit: .fahrenheit), "32°")
    }

    func testUnreadableTemperatureUsesPlaceholder() {
        XCTAssertEqual(MenuBarFormatter.temperature(nil, unit: .celsius), "--°")
        XCTAssertEqual(MenuBarFormatter.detailedTemperature(nil, unit: .celsius), "-- °C")
    }

    // MARK: Whole label

    func testNormalLabelShowsBothValues() {
        let label = MenuBarFormatter.label(
            celsius: 52, averageRPM: 2400, hasFans: true, unit: .celsius
        )
        XCTAssertEqual(label, "52° 2.4k")
    }

    func testFanlessMacShowsTemperatureOnly() {
        // A Mac with no fans must not display a fabricated "0" fan speed.
        let label = MenuBarFormatter.label(
            celsius: 45, averageRPM: nil, hasFans: false, unit: .celsius
        )
        XCTAssertEqual(label, "45°")
    }

    func testAllSensorsUnreadable() {
        let label = MenuBarFormatter.label(
            celsius: nil, averageRPM: nil, hasFans: true, unit: .celsius
        )
        XCTAssertEqual(label, "--° ----")
    }

    func testTemperatureLostButFansStillReadable() {
        let label = MenuBarFormatter.label(
            celsius: nil, averageRPM: 3000, hasFans: true, unit: .celsius
        )
        XCTAssertEqual(label, "--° 3.0k")
    }

    func testStoppedFansReportZeroNotUnavailable() {
        // Fans genuinely at rest is different from fans being unreadable, and the
        // label must distinguish them.
        let label = MenuBarFormatter.label(
            celsius: 39, averageRPM: 0, hasFans: true, unit: .celsius
        )
        XCTAssertEqual(label, "39° 0")
    }
}
