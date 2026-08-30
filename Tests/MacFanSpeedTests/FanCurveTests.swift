import XCTest
@testable import MacFanSpeed

/// A curve decides how hard the fans work on a machine that may be getting hot,
/// so every way of producing a malformed one has to end somewhere evaluable.
final class FanCurveTests: XCTestCase {

    private func curve(_ pairs: [(Double, Double)]) -> FanCurve {
        FanCurve(points: pairs.map { CurvePoint(celsius: $0.0, percent: $0.1) })
    }

    // MARK: Interpolation

    func testInterpolatesLinearlyBetweenPoints() {
        let c = curve([(30, 0.15), (50, 0.50)])
        XCTAssertEqual(c.percent(atCelsius: 30), 0.15, accuracy: 0.0001)
        XCTAssertEqual(c.percent(atCelsius: 50), 0.50, accuracy: 0.0001)
        XCTAssertEqual(c.percent(atCelsius: 40), 0.325, accuracy: 0.0001)
    }

    /// The user's own example, verbatim: 15% at 30 °C, 50% at 50 °C.
    func testTheStatedExample() {
        let c = curve([(30, 0.15), (50, 0.50)])
        XCTAssertEqual(c.percent(atCelsius: 30), 0.15, accuracy: 0.0001)
        XCTAssertEqual(c.percent(atCelsius: 50), 0.50, accuracy: 0.0001)
    }

    func testFlatOutsideTheEnds() {
        let c = curve([(40, 0.2), (80, 0.9)])
        XCTAssertEqual(c.percent(atCelsius: 20), 0.2, accuracy: 0.0001)
        XCTAssertEqual(c.percent(atCelsius: 95), 0.9, accuracy: 0.0001)
    }

    /// Steps would make a fraction of a degree at a boundary produce a full jump
    /// in speed, which is what makes other tools audibly hunt.
    func testSmallTemperatureChangesProduceSmallSpeedChanges() {
        let c = curve([(40, 0), (90, 1)])
        let a = c.percent(atCelsius: 64.9)
        let b = c.percent(atCelsius: 65.1)
        XCTAssertLessThan(abs(a - b), 0.01)
    }

    // MARK: Normalisation

    func testPointsAreSorted() {
        let c = curve([(80, 0.9), (30, 0.1), (55, 0.4)])
        XCTAssertEqual(c.points.map(\.celsius), [30, 55, 80])
    }

    func testSpeedIsForcedNonDecreasing() {
        // A curve that slows down as the machine heats has no defensible meaning
        // against a safety floor applied with max().
        let c = curve([(40, 0.8), (60, 0.2), (80, 0.5)])
        let percents = c.points.map(\.percent)
        XCTAssertEqual(percents, percents.sorted())
        XCTAssertEqual(percents.first, 0.8)
    }

    func testCoordinatesAreClamped() {
        let c = curve([(-40, -3), (500, 9)])
        XCTAssertEqual(c.points.first?.celsius, FanCurve.minimumCelsius)
        XCTAssertEqual(c.points.last?.celsius, FanCurve.maximumCelsius)
        XCTAssertEqual(c.points.first?.percent, 0)
        XCTAssertEqual(c.points.last?.percent, 1)
    }

    func testDuplicateTemperaturesCollapseToTheFasterPoint() {
        let c = curve([(60, 0.3), (60, 0.7), (80, 0.9)])
        XCTAssertEqual(c.points.filter { $0.celsius == 60 }.count, 1)
        XCTAssertEqual(c.points.first { $0.celsius == 60 }?.percent, 0.7)
    }

    func testNonFiniteCoordinatesAreDiscarded() {
        let c = curve([(.nan, 0.5), (40, 0.2), (70, .infinity), (85, 0.9)])
        XCTAssertTrue(c.points.allSatisfy { $0.celsius.isFinite && $0.percent.isFinite })
        XCTAssertGreaterThanOrEqual(c.points.count, FanCurve.minimumPoints)
    }

    func testTooFewPointsBecomeAnEvaluableFlatCurve() {
        let c = curve([(50, 0.4)])
        XCTAssertEqual(c.points.count, FanCurve.minimumPoints)
        XCTAssertEqual(c.percent(atCelsius: 30), 0.4, accuracy: 0.0001)
        XCTAssertEqual(c.percent(atCelsius: 90), 0.4, accuracy: 0.0001)
    }

    func testEmptyInputStillEvaluates() {
        let c = FanCurve(points: [])
        XCTAssertGreaterThanOrEqual(c.points.count, FanCurve.minimumPoints)
        XCTAssertEqual(c.percent(atCelsius: 70), 0, accuracy: 0.0001)
    }

    /// `max(.nan, x)` is nan in Swift, so an unguarded clamp passes it straight
    /// through into a fan target.
    func testNonFiniteTemperatureResolvesToMaximumNotNaN() {
        let c = curve([(40, 0.2), (80, 0.9)])
        XCTAssertEqual(c.percent(atCelsius: .nan), 0.9, accuracy: 0.0001)
        XCTAssertFalse(c.percent(atCelsius: .nan).isNaN)
    }

    func testCurvesCannotExceedTheMaximumPointCount() {
        let many = (0..<40).map { (Double(20 + $0), Double($0) / 40) }
        XCTAssertLessThanOrEqual(curve(many).points.count, FanCurve.maximumPoints)
    }

    /// A curve may not describe speeds above the cutoff, because past it the
    /// fans belong to macOS.
    func testCurveCannotExtendAboveTheFailsafeCeiling() {
        XCTAssertEqual(FanCurve.maximumCelsius, Failsafe.maximumTripCelsius)
        let c = curve([(40, 0.2), (200, 1)])
        XCTAssertLessThanOrEqual(c.points.last!.celsius, Failsafe.maximumTripCelsius)
    }

    // MARK: Editing

    func testAddingAPointSplitsTheWidestGap() {
        var c = curve([(30, 0.1), (90, 1.0)])
        XCTAssertNotNil(c.addPoint())
        XCTAssertEqual(c.points.count, 3)
        XCTAssertEqual(c.points[1].celsius, 60, accuracy: 1)
    }

    func testRemovingNeverGoesBelowTwoPoints() {
        var c = curve([(30, 0.1), (90, 1.0)])
        c.remove(id: c.points[0].id)
        XCTAssertEqual(c.points.count, 2, "the last two points must survive")
    }

    func testUpdatingRenormalises() {
        var c = curve([(30, 0.1), (60, 0.5), (90, 1.0)])
        // Drag the middle point below its predecessor.
        c.update(id: c.points[1].id, celsius: 60, percent: 0.0)
        XCTAssertGreaterThanOrEqual(c.points[1].percent, c.points[0].percent)
    }

    // MARK: Codable

    func testRoundTripsThroughJSON() throws {
        let original = curve([(35, 0.2), (65, 0.6), (88, 1.0)])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FanCurve.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    /// Point ids are not encoded — they exist only for SwiftUI row identity, and
    /// leaving them out keeps a curve small enough to paste into a bug report.
    func testEncodedFormCarriesNoIdentifiers() throws {
        let data = try JSONEncoder().encode(curve([(40, 0.3), (80, 0.8)]))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.lowercased().contains("id"))
    }

    /// Hand-edited or corrupted JSON must not produce a curve that cannot be
    /// evaluated.
    func testDecodingRepairsMalformedData() throws {
        let json = #"[{"celsius":900,"percent":5},{"celsius":10,"percent":-1}]"#
        let decoded = try JSONDecoder().decode(FanCurve.self, from: Data(json.utf8))
        XCTAssertGreaterThanOrEqual(decoded.points.count, FanCurve.minimumPoints)
        XCTAssertTrue(decoded.points.allSatisfy { (0...1).contains($0.percent) })
        XCTAssertTrue(decoded.points.allSatisfy {
            (FanCurve.minimumCelsius...FanCurve.maximumCelsius).contains($0.celsius)
        })
    }
}
