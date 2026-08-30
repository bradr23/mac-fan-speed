import Charts
import SwiftUI
import SMCKit

/// Editor for one profile's temperature-to-speed curve.
///
/// A points table with a live read-only chart above it, rather than a draggable
/// graph. The Settings window is a fixed 460 points wide, which leaves a plot
/// area where control points a few degrees apart would be a few points apart on
/// screen — the size at which dragging works worst and there is no way for the
/// user to make the window bigger. Editing in a `Stepper` and a `Slider` also
/// keeps keyboard access and VoiceOver working for free, which a `Chart` (one
/// opaque accessibility element) does not.
///
/// The chart does the one thing a chart is uniquely good at — showing shape —
/// without becoming somewhere input can go wrong.
struct CurveEditorView: View {
    @Binding var curve: FanCurve
    let fans: [Fan]
    let currentCelsius: Double?
    let cutoffCelsius: Double

    @State private var selection: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            preview

            // Explicit rows rather than a `Table`: a Table has no intrinsic
            // height, so nested in the scrolling detail pane it collapses to
            // nothing and the points simply do not appear.
            VStack(spacing: 4) {
                ForEach(curve.points) { point in
                    row(for: point)
                }
            }

            HStack {
                Button { addPoint() } label: { Image(systemName: "plus") }
                    .disabled(!curve.canAddPoint)
                    .help("Add a control point")
                Button { removeSelected() } label: { Image(systemName: "minus") }
                    // Gated on the point still existing, not just on an id being
                    // held: normalising can collapse the selected point away, and
                    // the stale id left the button enabled but inert.
                    .disabled(selectedPoint == nil || !curve.canRemovePoint)
                    .help("Remove the selected point")
                Spacer()
                Text("Speeds are a percentage of each fan's own range.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// One control point: temperature, speed, and what that resolves to on this
    /// machine.
    private func row(for point: CurvePoint) -> some View {
        HStack(spacing: 8) {
            Stepper(
                value: temperatureBinding(point),
                in: FanCurve.minimumCelsius...FanCurve.maximumCelsius,
                step: 1
            ) {
                Text("\(Int(point.celsius)) °C")
                    .monospacedDigit()
                    .frame(width: 46, alignment: .leading)
            }

            Slider(value: percentBinding(point), in: 0...1)

            Text("\(Int(point.percent * 100))%")
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)

            Text(resolvedRPM(point))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 66, alignment: .trailing)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(selection == point.id ? Color.accentColor.opacity(0.12) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { selection = point.id }
    }

    // MARK: Chart

    private var preview: some View {
        Chart {
            ForEach(curve.points) { point in
                LineMark(
                    x: .value("Temperature", point.celsius),
                    y: .value("Speed", point.percent * 100)
                )
                .interpolationMethod(.linear)
                .foregroundStyle(Color.accentColor)

                PointMark(
                    x: .value("Temperature", point.celsius),
                    y: .value("Speed", point.percent * 100)
                )
                .symbolSize(selection == point.id ? 120 : 55)
                .foregroundStyle(Color.accentColor)
            }

            // Where the machine is right now, so the curve is edited against
            // something real rather than in the abstract.
            if let currentCelsius, currentCelsius.isFinite {
                RuleMark(x: .value("Now", currentCelsius))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("now").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
            }

            // The point past which none of this applies, because the fans go
            // back to macOS. Better shown than discovered.
            RuleMark(x: .value("Cutoff", cutoffCelsius))
                .foregroundStyle(.red.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .top, alignment: .trailing) {
                    Text("\(Int(cutoffCelsius))°")
                        .font(.system(size: 9))
                        .foregroundStyle(.red.opacity(0.8))
                }
        }
        // Pinned rather than auto-fitted: an axis that resizes to the data makes
        // every curve look identical.
        .chartXScale(domain: FanCurve.minimumCelsius...FanCurve.maximumCelsius)
        .chartYScale(domain: 0...100)
        .chartXAxis {
            AxisMarks(values: .stride(by: 20)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let celsius = value.as(Double.self) {
                        Text("\(Int(celsius))°").font(.system(size: 9))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let percent = value.as(Double.self) {
                        Text("\(Int(percent))%").font(.system(size: 9))
                    }
                }
            }
        }
        .frame(height: 104)
        // The table below is the accessible representation of the same data.
        .accessibilityHidden(true)
    }

    // MARK: Editing

    private func temperatureBinding(_ point: CurvePoint) -> Binding<Double> {
        Binding(
            get: { point.celsius },
            set: {
                // The edited point can be collapsed into a neighbour; drop the
                // selection rather than leaving it pointing at nothing.
                if !curve.update(id: point.id, celsius: $0, percent: point.percent),
                   selection == point.id { selection = nil }
            }
        )
    }

    private func percentBinding(_ point: CurvePoint) -> Binding<Double> {
        Binding(
            get: { point.percent },
            set: { curve.update(id: point.id, celsius: point.celsius, percent: $0) }
        )
    }

    private func addPoint() {
        if let id = curve.addPoint() { selection = id }
    }

    /// The selected point, if it still exists.
    private var selectedPoint: CurvePoint? {
        guard let selection else { return nil }
        return curve.points.first { $0.id == selection }
    }

    private func removeSelected() {
        guard let selection else { return }
        curve.remove(id: selection)
        self.selection = nil
    }

    /// What a percentage actually means on this machine. The whole reason
    /// speeds are stored as percentages is that the number differs per Mac, so
    /// showing only the percentage hides the thing the user cares about.
    private func resolvedRPM(_ point: CurvePoint) -> String {
        let values = fans.map { $0.rpm(forPercent: point.percent) }
        // A fan whose limits the SMC does not report resolves everything to
        // zero; saying "0 rpm" would be a fabrication.
        guard let low = values.min(), let high = values.max(),
              fans.contains(where: { $0.maxRPM > $0.minRPM })
        else { return "—" }
        return low == high ? "\(Int(low)) rpm" : "\(Int(low))–\(Int(high))"
    }
}
