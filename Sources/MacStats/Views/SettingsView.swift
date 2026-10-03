import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var stats: StatsEngine
    @ObservedObject private var settings = AppSettings.shared

    /// Closes the hosting `NSWindow`; `@Environment(\.dismiss)` does nothing here.
    var onDone: () -> Void = {}

    /// `menuBarItems` is a plain array, so each toggle drives it through the setter.
    private func menuBarBinding(_ metric: MenuBarMetric) -> Binding<Bool> {
        Binding(get: { settings.menuBarItems.contains(metric.rawValue) },
                set: { settings.setMenuBarMetric(metric, enabled: $0) })
    }

    private var menuBarNote: String {
        settings.showsMetricsInMenuBar
            ? "Selected metrics replace the menu bar icon. Each one adds width, so two or three is usually the limit before the bar gets crowded."
            : "With nothing selected the menu bar shows the MacStats icon."
    }

    private var samplingNote: String {
        settings.showsMetricsInMenuBar
            ? "Sampling runs continuously to keep the menu bar live, which costs a little CPU and battery. Turn off every menu bar metric to have it pause while the popover is closed."
            : "Sampling only runs while the popover is open."
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Display Options") {
                    Toggle("Show CPU Usage", isOn: $settings.showCPU)
                    Toggle("Show GPU", isOn: $settings.showGPU)
                    Toggle("Show Memory", isOn: $settings.showMemory)
                    Toggle("Show Battery", isOn: $settings.showBattery)
                    Toggle("Show Disk Usage", isOn: $settings.showDisk)
                    Toggle("Show Network", isOn: $settings.showNetwork)
                    Toggle("Show Fan Speed", isOn: $settings.showFan)
                    Toggle("Show Temperature", isOn: $settings.showTemperature)
                }

                Section("Menu Bar") {
                    ForEach(MenuBarMetric.allCases) { metric in
                        Toggle(metric.settingsTitle, isOn: menuBarBinding(metric))
                    }
                    Text(menuBarNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Update Interval") {
                    Picker("Refresh Rate", selection: $settings.updateInterval) {
                        Text("1s").tag(1.0)
                        Text("2s").tag(2.0)
                        Text("5s").tag(5.0)
                        Text("30s").tag(30.0)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Refresh rate")
                    Text(samplingNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Startup") {
                    Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                        .disabled(!settings.isLaunchAtLoginSupported)
                    Text(settings.launchAtLoginStatusDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let error = settings.launchAtLoginError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section("About") {
                    LabeledContent("MacStats", value: "Version \(Self.versionString)")
                    Text("Menu bar system monitor.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 380, minHeight: 480)
        .onAppear {
            settings.refreshLaunchAtLoginState()
        }
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?) where short != build: return "\(short) (\(build))"
        case let (short?, _): return short
        case let (_, build?): return build
        default: return "unknown"
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(StatsEngine.shared)
}
