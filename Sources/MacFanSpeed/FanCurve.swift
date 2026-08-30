import Foundation

/// One control point on a fan curve: at `celsius`, run the fans at `percent`.
///
/// `id` is deliberately not encoded. It exists only so SwiftUI keeps row
/// identity while a temperature is being typed, and leaving it out of the JSON
/// keeps a curve small enough to paste into a bug report — which is how support
/// for hardware the developer cannot test actually gets added.
struct CurvePoint: Codable, Identifiable, Sendable {
    let id: UUID
    var celsius: Double
    var percent: Double

    init(celsius: Double, percent: Double, id: UUID = UUID()) {
        self.id = id
        self.celsius = celsius
        self.percent = percent
    }

    private enum CodingKeys: String, CodingKey { case celsius, percent }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        celsius = try container.decode(Double.self, forKey: .celsius)
        percent = try container.decode(Double.self, forKey: .percent)
    }
}

extension CurvePoint: Equatable {
    /// Identity is not part of the value: two points in the same place are the
    /// same point, whatever row they came from.
    static func == (a: CurvePoint, b: CurvePoint) -> Bool {
        a.celsius == b.celsius && a.percent == b.percent
    }
}

/// A temperature-to-fan-speed curve, held as percentages of each fan's own
/// range so it means the same thing on hardware it was not created on — the
/// same portability rule as `FanPreset`.
///
/// Values between points are interpolated **linearly** rather than stepped.
/// That is the single most important decision here, and it is made in the data
/// model before any hysteresis exists: a step table's output is discontinuous,
/// so a 0.1 °C wobble at a boundary produces a full step change in speed. That
/// is what makes other fan-control tools audibly hunt. Interpolated, the same
/// wobble moves the fans a fraction of a percent.
struct FanCurve: Codable, Equatable, Sendable {

    /// Curves are not editable above the failsafe ceiling: past it the fans are
    /// macOS's, so a control point there would describe something that cannot
    /// happen.
    static let minimumCelsius: Double = 20
    static var maximumCelsius: Double { Failsafe.maximumTripCelsius }
    static let minimumPoints = 2
    static let maximumPoints = 10

    private(set) var points: [CurvePoint]

    init(points: [CurvePoint]) {
        self.points = Self.normalised(points)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        points = Self.normalised(try container.decode([CurvePoint].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(points)
    }

    /// The one function that restores every invariant. Everything that can
    /// produce a curve — init, decode, the editor, migration — goes through it,
    /// so there is no way to hold a curve that interpolation cannot evaluate.
    static func normalised(_ raw: [CurvePoint]) -> [CurvePoint] {
        // Non-finite coordinates would poison every comparison downstream:
        // in Swift `max(.nan, 60)` is nan, because `60 >= nan` is false.
        var cleaned = raw.filter { $0.celsius.isFinite && $0.percent.isFinite }

        for index in cleaned.indices {
            cleaned[index].celsius = Swift.min(
                Swift.max(cleaned[index].celsius, minimumCelsius), maximumCelsius
            )
            cleaned[index].percent = Swift.min(Swift.max(cleaned[index].percent, 0), 1)
        }

        cleaned.sort { $0.celsius < $1.celsius }

        // Two points at the same temperature make the interpolation ambiguous.
        // Keep the faster one: erring upward is the safe direction.
        var collapsed: [CurvePoint] = []
        for point in cleaned {
            if let last = collapsed.last, last.celsius == point.celsius {
                if point.percent > last.percent { collapsed[collapsed.count - 1] = point }
            } else {
                collapsed.append(point)
            }
        }

        // Force non-decreasing speed. No surveyed tool enforces this, but this
        // app composes the curve with `max()` against a safety floor and with a
        // deadband around the operating point, and a curve that slows down as
        // the machine heats up has no defensible meaning against either.
        for index in collapsed.indices.dropFirst() {
            collapsed[index].percent = Swift.max(
                collapsed[index].percent, collapsed[index - 1].percent
            )
        }

        // Keep the hottest point when trimming. A plain `prefix` drops the top
        // of the curve, which lowers its maximum — the unsafe direction — so the
        // surplus is taken from the middle instead.
        if collapsed.count > maximumPoints {
            let last = collapsed[collapsed.count - 1]
            collapsed = Array(collapsed.prefix(maximumPoints - 1)) + [last]
        }

        // A curve with fewer than two points cannot describe a ramp. Rather than
        // failing, flatten to something evaluable at the speed that survived.
        if collapsed.count < minimumPoints {
            let percent = collapsed.first?.percent ?? 0
            collapsed = [
                CurvePoint(celsius: minimumCelsius, percent: percent),
                CurvePoint(celsius: maximumCelsius, percent: percent),
            ]
        }
        return collapsed
    }

    /// Speed for a temperature: linear between neighbouring points, flat beyond
    /// the ends.
    ///
    /// A non-finite temperature resolves to the curve's **maximum**, never its
    /// first point. That can only be reached on the tick before the failsafe
    /// trips on unreadable sensors, and resolving high is the safe direction.
    func percent(atCelsius celsius: Double) -> Double {
        guard celsius.isFinite else { return maximumPercent }
        guard let first = points.first, let last = points.last else { return 0 }

        if celsius <= first.celsius { return first.percent }
        if celsius >= last.celsius { return last.percent }

        for index in points.indices.dropLast() {
            let low = points[index]
            let high = points[index + 1]
            guard celsius >= low.celsius, celsius <= high.celsius else { continue }

            let span = high.celsius - low.celsius
            guard span > 0 else { return Swift.max(low.percent, high.percent) }

            let position = (celsius - low.celsius) / span
            return low.percent + (high.percent - low.percent) * position
        }
        return last.percent
    }

    var minimumPercent: Double { points.first?.percent ?? 0 }
    var maximumPercent: Double { points.last?.percent ?? 0 }

    /// Written into `FanPreset.percent` whenever a curve is saved, so a build
    /// that predates curves reads a sensible fixed speed rather than whatever
    /// happened to be in the struct. 60 °C stands in for sustained load.
    var mirroredPercent: Double { percent(atCelsius: 60) }

    /// Used when a curve cannot be recovered at all.
    static var fallback: FanCurve {
        FanCurve(points: [
            CurvePoint(celsius: 40, percent: 0),
            CurvePoint(celsius: 90, percent: 1),
        ])
    }

    /// What the shipped curve profile starts as: quiet until the machine is
    /// working, then climbing steadily.
    static var defaultCurve: FanCurve {
        FanCurve(points: [
            CurvePoint(celsius: 40, percent: 0.15),
            CurvePoint(celsius: 55, percent: 0.30),
            CurvePoint(celsius: 70, percent: 0.55),
            CurvePoint(celsius: 85, percent: 0.90),
        ])
    }

    // MARK: Editing

    /// Replace one point, keeping the edit local to that point.
    ///
    /// The edited point is clamped between its neighbours rather than being
    /// allowed to drag them. `normalised` enforces monotonicity by ratcheting
    /// every later point up to match, which is right for repairing decoded data
    /// and badly wrong for editing: dragging the first row's slider to 90%
    /// pushed every other point to 90% too, and dragging it back down left them
    /// there. One gesture silently flattened the whole curve.
    ///
    /// - Returns: whether the point still exists afterwards. It may not: moving
    ///   it onto a neighbour's temperature collapses the two.
    @discardableResult
    mutating func update(id: UUID, celsius: Double, percent: Double) -> Bool {
        guard let index = points.firstIndex(where: { $0.id == id }) else { return false }

        var working = points
        working[index].celsius = celsius.isFinite
            ? min(max(celsius, Self.minimumCelsius), Self.maximumCelsius)
            : working[index].celsius
        working[index].percent = percent.isFinite ? min(max(percent, 0), 1) : working[index].percent
        working.sort { $0.celsius < $1.celsius }

        // Constrain only the point being edited, so monotonicity is preserved
        // without touching anything else.
        if let moved = working.firstIndex(where: { $0.id == id }) {
            let lower = moved > 0 ? working[moved - 1].percent : 0
            let upper = moved < working.count - 1 ? working[moved + 1].percent : 1
            working[moved].percent = min(max(working[moved].percent, lower), max(lower, upper))
        }

        points = Self.normalised(working)
        return points.contains { $0.id == id }
    }

    /// Add a point midway through the widest gap, which is where a user editing
    /// a curve almost always wants one.
    @discardableResult
    mutating func addPoint() -> UUID? {
        guard points.count < Self.maximumPoints else { return nil }

        var gapIndex = 0
        var widest = -Double.infinity
        for index in points.indices.dropLast() {
            let gap = points[index + 1].celsius - points[index].celsius
            if gap > widest { widest = gap; gapIndex = index }
        }
        guard widest > 1 else { return nil }

        let low = points[gapIndex]
        let high = points[gapIndex + 1]
        let point = CurvePoint(
            celsius: ((low.celsius + high.celsius) / 2).rounded(),
            percent: (low.percent + high.percent) / 2
        )
        points = Self.normalised(points + [point])
        return point.id
    }

    /// Curves below two points cannot be evaluated, so the last two are kept.
    mutating func remove(id: UUID) {
        guard points.count > Self.minimumPoints else { return }
        points = Self.normalised(points.filter { $0.id != id })
    }

    var canAddPoint: Bool { points.count < Self.maximumPoints }
    var canRemovePoint: Bool { points.count > Self.minimumPoints }
}
