import SwiftUI
import SMCKit

/// Every temperature sensor the machine exposes, grouped by what it measures.
///
/// The app only acts on the hottest processor reading, but Macs expose dozens of
/// sensors and there is no reason to hide them. This is also the view that makes
/// a bug report useful: it shows exactly what the app can see on hardware the
/// developer does not have.
struct SensorsView: View {
    @ObservedObject var monitor: FanMonitor

    private var groups: [(category: SensorCategory, readings: [SensorReading])] {
        SensorReading.byCategory(monitor.allSensors)
    }

    var body: some View {
        // Grouped once per render rather than separately for the list and the
        // count in the header, which had it collapsing 52 readings twice every
        // two seconds.
        let grouped = groups
        let total = grouped.reduce(0) { $0 + $1.readings.count }

        return VStack(alignment: .leading, spacing: 0) {
            header(sensorCount: total)

            if monitor.allSensors.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(grouped, id: \.category) { group in
                            categorySection(group.category, group.readings)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
            }
        }
    }

    private func header(sensorCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("\(sensorCount) sensors")
                    .font(.caption.weight(.medium))
                Spacer()
                Text("updates every \(Int(FanMonitor.pollInterval)) seconds")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text("Readings come straight from the hardware. Only the hottest "
                 + "processor sensor drives fan control.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "thermometer.medium.slash")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text("No sensors readable")
                .font(.callout.weight(.medium))
            Text("The app could not open the system's sensor interface.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func categorySection(
        _ category: SensorCategory,
        _ readings: [SensorReading]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(category.title, systemImage: category.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(readings) { reading in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(reading.displayName)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        // The hardware's own name and SMC key, so a reading can
                        // always be traced back to what produced it — and quoted
                        // in a bug report from hardware nobody has catalogued.
                        if !reading.isVerbatim {
                            Text(detail(for: reading))
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(monitor.temperatureString(reading.celsius, includeSymbol: true))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(colour(for: reading.celsius))
                }
            }
        }
    }

    private func detail(for reading: SensorReading) -> String {
        var parts = [reading.name]
        if let key = reading.smcKey { parts.append(key) }
        if reading.sourceCount > 1 { parts.append("×\(reading.sourceCount)") }
        return parts.joined(separator: "  ·  ")
    }

    /// Warm colours above the point where a machine is working hard. Deliberately
    /// well below the 95 °C failsafe — this is a readability cue, not a warning.
    private func colour(for celsius: Double) -> Color {
        switch celsius {
        case ..<60: return .secondary
        case ..<80: return .orange
        default:    return .red
        }
    }
}
