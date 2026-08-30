import AppKit
import Charts
import SwiftUI
import SMCKit

struct DropdownView: View {
    @ObservedObject var monitor: FanMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let error = monitor.startupError {
                errorBanner(error)
            } else {
                temperatureSection
                if monitor.hasFans {
                    Divider()
                    fanSection
                }
                Divider()
                chartSection
                Divider()
                controlSection
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 300)
    }

    // MARK: Header and readouts

    private var header: some View {
        HStack {
            Image(systemName: "fan")
            Text("Mac Fan Speed").font(.headline)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Sensors unavailable", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var temperatureSection: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CPU").font(.subheadline.weight(.medium))
                Text(monitor.cpuSensorLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(monitor.temperatureString(monitor.cpu?.celsius, includeSymbol: true))
                .font(.title3.weight(.medium))
                .monospacedDigit()
        }
    }

    private var fanSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(monitor.fans) { fan in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fan \(fan.index + 1)").font(.subheadline.weight(.medium))
                        Text("\(Int(fan.minRPM))–\(Int(fan.maxRPM)) rpm")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(Int(fan.actualRPM)) rpm")
                        .monospacedDigit()
                }
            }
        }
    }

    private var chartSection: some View {
        let windowed = monitor.visibleSamples
        let window = monitor.historyWindowStart...Date()

        return VStack(alignment: .leading, spacing: 10) {
            HistoryChart(
                title: "Temperature",
                caption: monitor.historyRange.caption,
                samples: windowed,
                window: window,
                value: { $0.celsius.map(monitor.unit.convert) },
                unitLabel: monitor.unit.symbol,
                tint: .orange,
                minimumSpan: 4
            )

            if monitor.hasFans {
                HistoryChart(
                    title: "Fan speed",
                    caption: nil,
                    samples: windowed,
                    window: window,
                    value: { $0.averageRPM },
                    unitLabel: "rpm",
                    tint: .blue,
                    // Fans cannot run backwards, and a stopped fan should read
                    // against a plausible scale rather than a ±1 rpm axis.
                    minimumSpan: 1000,
                    lowerLimit: 0
                )
            }

            rangeButtons
        }
    }

    private var rangeButtons: some View {
        HStack(spacing: 4) {
            ForEach(HistoryRange.allCases) { range in
                let isSelected = monitor.historyRange == range
                Button { monitor.historyRange = range } label: {
                    Text(range.label)
                        .font(.caption2)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? Color.accentColor.opacity(0.85)
                                         : Color.secondary.opacity(0.12))
                )
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
            }
        }
    }

    // MARK: Control

    @ViewBuilder
    private var controlSection: some View {
        if monitor.hasFans {
            VStack(alignment: .leading, spacing: 8) {
                helperBanner

                if monitor.helper.status.isReady {
                    presetButtons
                    speedSlider
                }

                if let message = monitor.failsafeMessage {
                    Label(message, systemImage: "thermometer.high")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = monitor.lastControlError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Auto plus one button per preset. Presets are percentages of each fan's own
    /// range, so the same button means the right thing on any Mac.
    private var presetButtons: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Mode").font(.subheadline.weight(.medium))
            HStack(spacing: 4) {
                modeButton(title: "Auto", isSelected: monitor.mode == .auto) {
                    monitor.setMode(.auto)
                }
                ForEach(monitor.presets.presets) { preset in
                    modeButton(title: preset.name, isSelected: isSelected(preset)) {
                        monitor.apply(preset: preset)
                    }
                }
            }
        }
    }

    private func isSelected(_ preset: FanPreset) -> Bool {
        monitor.mode == .manual && monitor.activePresetID == preset.id
    }

    private func modeButton(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let background: Color = isSelected ? .accentColor : Color.secondary.opacity(0.15)
        let foreground: Color = isSelected ? .white : .primary

        return Button(action: action) {
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 5).fill(background))
        .foregroundStyle(foreground)
    }

    @ViewBuilder
    private var speedSlider: some View {
        if monitor.linkFans || monitor.fans.count < 2 {
            singleSlider
        } else {
            // Unlinked: one row per fan, each with its own speed. Without this
            // the "use one slider for all fans" setting had nothing to switch
            // between and appeared to do nothing.
            VStack(alignment: .leading, spacing: 6) {
                ForEach(monitor.fans) { fan in
                    fanSlider(for: fan, label: "Fan \(fan.index + 1)")
                }
            }
        }
    }

    private var singleSlider: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Speed").font(.caption)
                Spacer()
                Text(resolvedTargetLabel)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            // The slider is a percentage of each fan's range; the label shows
            // what that resolves to in rpm on this hardware.
            Slider(
                value: Binding(
                    get: { monitor.currentPercent },
                    set: { monitor.setPercent($0) }
                ),
                in: 0...1
            )
            .disabled(monitor.mode != .manual)
        }
    }

    private func fanSlider(for fan: Fan, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text("\(Int(monitor.percent(for: fan) * 100))%  ·  "
                     + "\(Int(monitor.target(for: fan))) rpm")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { monitor.percent(for: fan) },
                    set: { monitor.setPercent($0, fanIndex: fan.index) }
                ),
                in: 0...1
            )
            .disabled(monitor.mode != .manual)
        }
    }

    private var resolvedTargetLabel: String {
        let percent = Int(monitor.currentPercent * 100)
        guard let fan = monitor.fans.first else { return "\(percent)%" }
        return "\(percent)%  ·  \(Int(monitor.target(for: fan))) rpm"
    }

    /// Shown only when the daemon is missing or not answering. Installing it
    /// needs an administrator, so the button opens Settings rather than trying.
    @ViewBuilder
    private var helperBanner: some View {
        switch monitor.helper.status {
        case .ready:
            EmptyView()

        case .checking:
            Text("Checking for the fan control helper…")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .notInstalled:
            VStack(alignment: .leading, spacing: 4) {
                Label("Fan control not enabled", systemImage: "lock")
                    .font(.caption.weight(.medium))
                Text("Monitoring works without it. Enabling fan control installs a "
                     + "small background service and asks for your password once.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Enable Fan Control…") {
                    SettingsWindowController.shared.show(tab: .helper)
                }
                .controlSize(.small)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .unreachable(let reason):
            VStack(alignment: .leading, spacing: 3) {
                Label("Helper not responding", systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Sensors…") { SensorsWindowController.shared.show() }
            Button("Settings…") { SettingsWindowController.shared.show() }
                .keyboardShortcut(",")
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

/// A compact sparkline over the rolling sample history.
struct HistoryChart: View {
    let title: String
    let caption: String?
    let samples: [FanMonitor.Sample]
    /// The span the x-axis covers, which is the selected range rather than the
    /// extent of the data.
    let window: ClosedRange<Date>
    let value: (FanMonitor.Sample) -> Double?
    let unitLabel: String
    let tint: Color
    /// Smallest y-range to display, so a flat line doesn't get magnified into
    /// meaningless noise.
    var minimumSpan: Double = 1
    /// Lower bound the axis may never go below, for quantities that cannot be
    /// negative.
    var lowerLimit: Double? = nil

    /// Most points a 300 pt wide sparkline can usefully show.
    private static let renderLimit = 240

    private var points: [(time: Date, value: Double)] {
        let raw = samples.compactMap { sample in
            value(sample).map { (time: sample.time, value: $0) }
        }
        guard raw.count > Self.renderLimit else { return raw }

        // Six hours is 10,800 samples, far more than a sparkline this size can
        // draw distinctly, and enough to make the whole dropdown stutter.
        // Average into buckets rather than sampling every Nth point, so a brief
        // spike still shows up instead of falling between the chosen points.
        let bucketSize = Double(raw.count) / Double(Self.renderLimit)
        var reduced: [(time: Date, value: Double)] = []
        reduced.reserveCapacity(Self.renderLimit)

        for bucket in 0..<Self.renderLimit {
            let start = Int(Double(bucket) * bucketSize)
            let end = min(Int(Double(bucket + 1) * bucketSize), raw.count)
            guard start < end else { continue }
            let slice = raw[start..<end]
            let mean = slice.reduce(0) { $0 + $1.value } / Double(slice.count)
            reduced.append((time: slice[slice.startIndex].time, value: mean))
        }
        return reduced
    }

    var body: some View {
        // Computed once per render and passed down. As a computed property this
        // ran five times per render — header, chart, coverage note and twice for
        // the y-axis — each downsampling up to 10,800 samples on the six-hour
        // view.
        let series = points

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.caption.weight(.medium))
                if let caption {
                    Text(caption).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                if let last = series.last {
                    Text("\(Int(last.value.rounded())) \(unitLabel)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if series.count < 2 {
                // One sample cannot draw a line; say so rather than showing a
                // misleading flat chart.
                Text("collecting…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(height: 44, alignment: .leading)
            } else {
                chart(series)
                if let note = coverage(series) {
                    Text(note)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func chart(_ series: [(time: Date, value: Double)]) -> some View {
        Chart {
            ForEach(series, id: \.time) { point in
                LineMark(
                    x: .value("Time", point.time),
                    y: .value(title, point.value)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(tint)
            }
        }
        // Pin the axis to the selected window. Left to itself Swift Charts fits
        // the axis to the data, so every range drew an identical line until
        // there was more history than the shortest window — which made the range
        // buttons look like they did nothing at all.
        .chartXScale(domain: window)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
                AxisGridLine()
                AxisValueLabel().font(.caption2)
            }
        }
        .chartYScale(domain: yDomain(series))
        .frame(height: 44)
    }

    /// Note when the history so far covers only part of the chosen window, so a
    /// line filling a fraction of the width reads as "not enough history yet"
    /// rather than as a bug.
    private func coverage(_ series: [(time: Date, value: Double)]) -> String? {
        guard let earliest = series.first?.time else { return nil }
        let windowSeconds = window.upperBound.timeIntervalSince(window.lowerBound)
        let haveSeconds = window.upperBound.timeIntervalSince(earliest)
        guard haveSeconds < windowSeconds * 0.95 else { return nil }

        let minutes = Int(haveSeconds / 60)
        let span = minutes < 1 ? "under a minute" : (minutes < 60
            ? "\(minutes) min"
            : String(format: "%.1f hours", haveSeconds / 3600))
        return "\(span) of history so far"
    }

    /// Pad the range so a nearly flat line doesn't fill the whole chart height,
    /// while keeping the axis physically sensible.
    private func yDomain(_ series: [(time: Date, value: Double)]) -> ClosedRange<Double> {
        let base = lowerLimit ?? 0
        let values = series.map(\.value)
        guard let low = values.min(), let high = values.max() else {
            return base...(base + minimumSpan)
        }

        let padding = max((high - low) * 0.15, minimumSpan * 0.1)
        var lower = low - padding
        var upper = high + padding

        if let lowerLimit { lower = max(lower, lowerLimit) }
        if upper - lower < minimumSpan { upper = lower + minimumSpan }

        return lower...upper
    }
}
