import AppKit
import SwiftUI
import SMCKit

struct SettingsView: View {
    @ObservedObject var monitor: FanMonitor
    @ObservedObject var settings: AppSettings
    @ObservedObject var presets: PresetStore
    @ObservedObject var installer: HelperInstaller

    @State private var selectedTab: Tab

    init(
        monitor: FanMonitor,
        settings: AppSettings,
        presets: PresetStore,
        installer: HelperInstaller,
        initialTab: Tab = .general
    ) {
        self.monitor = monitor
        self.settings = settings
        self.presets = presets
        self.installer = installer
        _selectedTab = State(initialValue: initialTab)
    }

    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case presets = "Presets"
        case helper = "Fan Control"
        case about = "About"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .presets: return "slider.horizontal.3"
            case .helper: return "lock.shield"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettings(settings: settings, monitor: monitor)
                .tabItem { Label(Tab.general.rawValue, systemImage: Tab.general.icon) }
                .tag(Tab.general)

            PresetSettings(presets: presets, monitor: monitor)
                .tabItem { Label(Tab.presets.rawValue, systemImage: Tab.presets.icon) }
                .tag(Tab.presets)

            HelperSettings(monitor: monitor, installer: installer)
                .tabItem { Label(Tab.helper.rawValue, systemImage: Tab.helper.icon) }
                .tag(Tab.helper)

            AboutSettings(settings: settings)
                .tabItem { Label(Tab.about.rawValue, systemImage: Tab.about.icon) }
                .tag(Tab.about)
        }
        .frame(width: 460, height: 400)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var monitor: FanMonitor
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Start Mac Fan Speed at login", isOn: Binding(
                    get: { settings.loginItemState.isEnabled },
                    set: { loginError = settings.setLaunchAtLogin($0) }
                ))
                .disabled(isLoginToggleDisabled)

                switch settings.loginItemState {
                case .requiresApproval:
                    InlineNote(
                        icon: "exclamationmark.triangle",
                        tint: .orange,
                        text: "macOS needs you to approve this in System Settings › "
                            + "General › Login Items.",
                        action: ("Open Login Items", openLoginItemsSettings)
                    )
                case .unavailable(let reason):
                    InlineNote(icon: "xmark.octagon", tint: .red, text: reason)
                case .enabled where !settings.usesModernLoginAPI:
                    InlineNote(
                        icon: "checkmark.circle", tint: .secondary,
                        text: "Mac Fan Speed will start the next time you log in."
                    )
                default:
                    if !settings.isInApplicationsFolder {
                        // The login item records wherever the app is now, so a
                        // build run from a temporary folder registers a path that
                        // will not survive being moved.
                        InlineNote(
                            icon: "info.circle",
                            tint: .secondary,
                            text: "Move the app to your Applications folder first — "
                                + "a login item points at the app's current location.\n"
                                + settings.bundlePath
                        )
                    }
                }

                if let loginError {
                    InlineNote(icon: "xmark.octagon", tint: .red, text: loginError)
                }
            } header: {
                Text("Startup").font(.headline)
            }

            Section {
                Picker("Temperature unit", selection: $settings.unit) {
                    Text("Celsius (°C)").tag(TemperatureUnit.celsius)
                    Text("Fahrenheit (°F)").tag(TemperatureUnit.fahrenheit)
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Display").font(.headline)
            }

            Section {
                Toggle("Use one slider for all fans", isOn: $settings.linkFans)
                    .disabled(monitor.fans.count < 2)
                if monitor.fans.count < 2 {
                    Text("This Mac has \(monitor.fans.isEmpty ? "no fans" : "a single fan"), "
                         + "so there is nothing to link.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(settings.linkFans
                         ? "One speed slider controls all \(monitor.fans.count) fans."
                         : "Each fan gets its own slider in the menu bar dropdown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Fans").font(.headline)
            }
        }
        .formStyle(.grouped)
        .onAppear { settings.refreshLoginItemState() }
    }

    private var isLoginToggleDisabled: Bool {
        if case .unavailable = settings.loginItemState { return true }
        return false
    }

    private func openLoginItemsSettings() {
        // Opening a settings pane is a convenience; failing to build the URL
        // should never take the app down with it.
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Presets

private struct PresetSettings: View {
    @ObservedObject var presets: PresetStore
    @ObservedObject var monitor: FanMonitor
    @State private var selection: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Presets are a percentage of each fan's own range, so they mean "
                 + "the same thing on any Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)

            List(selection: $selection) {
                ForEach(presets.presets) { preset in
                    PresetRow(preset: preset, presets: presets, fans: monitor.fans)
                        .tag(preset.id)
                }
            }

            Divider()
            HStack {
                Button {
                    selection = presets.add().id
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a preset")

                Button {
                    if let preset = presets.preset(id: selection) { presets.delete(preset) }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(presets.preset(id: selection)?.isBuiltIn ?? true)
                .help("Delete the selected preset")

                Spacer()

                Button("Restore Defaults") { presets.resetToDefaults() }
            }
            .padding(10)
        }
    }
}

private struct PresetRow: View {
    let preset: FanPreset
    @ObservedObject var presets: PresetStore
    let fans: [Fan]

    var body: some View {
        HStack(spacing: 10) {
            TextField("Name", text: Binding(
                get: { preset.name },
                set: { var copy = preset; copy.name = $0; presets.update(copy) }
            ))
            .textFieldStyle(.plain)
            .frame(width: 110, alignment: .leading)

            Slider(
                value: Binding(
                    get: { preset.percent },
                    set: { var copy = preset; copy.percent = $0; presets.update(copy) }
                ),
                in: 0...1
            )

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(Int(preset.percent * 100))%")
                    .monospacedDigit()
                // The resolved speed is what the percentage actually means on
                // this machine, which is otherwise invisible.
                Text(preset.resolvedDescription(for: fans))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(width: 96, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Fan control helper

private struct HelperSettings: View {
    @ObservedObject var monitor: FanMonitor
    @ObservedObject var installer: HelperInstaller

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    switch monitor.helper.status {
                    case .ready(let version):
                        Label("Installed and running (\(version))", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    case .notInstalled:
                        Label("Not installed", systemImage: "lock")
                            .foregroundStyle(.secondary)
                    case .unreachable(let reason):
                        Label("Not responding — \(reason)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    case .checking:
                        Label("Checking…", systemImage: "ellipsis.circle")
                    }
                }

                HStack {
                    if monitor.helper.status.isReady || installer.isInstalled {
                        Button("Remove Helper…") {
                            installer.uninstall { _ in monitor.helper.refreshStatus() }
                        }
                    } else {
                        Button("Install Helper…") {
                            installer.install { _ in monitor.helper.refreshStatus() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!installer.isBundleComplete)
                    }

                    Button("Re-check") { monitor.helper.refreshStatus() }

                    if installer.isWorking { ProgressView().controlSize(.small) }
                }

                switch installer.lastResult {
                case .failed(let message):
                    InlineNote(icon: "xmark.octagon", tint: .red, text: message)
                case .cancelled:
                    InlineNote(icon: "info.circle", tint: .secondary,
                               text: "Installation cancelled.")
                case .installed:
                    InlineNote(icon: "checkmark.circle", tint: .green,
                               text: "Helper installed. Fan control is available.")
                case .removed:
                    InlineNote(icon: "checkmark.circle", tint: .green,
                               text: "Helper removed. Monitoring still works.")
                case nil:
                    EmptyView()
                }

                if !installer.isBundleComplete {
                    InlineNote(
                        icon: "exclamationmark.triangle", tint: .orange,
                        text: "This build does not contain the helper. "
                            + "Rebuild with scripts/build.sh."
                    )
                }
            } header: {
                Text("Privileged helper").font(.headline)
            } footer: {
                Text("Reading temperatures and fan speeds needs no privileges. "
                     + "Changing fan speed does, so a small background service runs "
                     + "as an administrator and does nothing else. Installing it asks "
                     + "for your password once.\n\n"
                     + "If the app stops responding, the service returns your fans to "
                     + "macOS control automatically within a few seconds.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { monitor.helper.refreshStatus() }
    }
}

// MARK: - About

private struct AboutSettings: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "fan")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Mac Fan Speed").font(.title2.weight(.semibold))
            Text("Version \(Self.version)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Temperature and fan monitoring with manual control, "
                 + "for Apple Silicon Macs.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 30)

            Divider().padding(.horizontal, 60)

            VStack(spacing: 3) {
                Text("Fans return to macOS control automatically if the CPU reaches "
                     + "95 °C, if temperature readings are lost, or if this app quits "
                     + "or crashes.")
                Text("MIT licensed. No warranty.")
            }
            .font(.caption)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24)

            Text(settings.bundlePath)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return short ?? SMCKit.version
    }
}

// MARK: - Shared

private struct InlineNote: View {
    let icon: String
    let tint: Color
    let text: String
    var action: (String, () -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(text).fixedSize(horizontal: false, vertical: true)
                if let action {
                    Button(action.0, action: action.1)
                        .buttonStyle(.link)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(tint == .secondary ? .secondary : .primary)
    }
}
