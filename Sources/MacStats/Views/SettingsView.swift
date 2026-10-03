import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    /// Closes the hosting `NSWindow`; `@Environment(\.dismiss)` does nothing here.
    var onDone: () -> Void = {}

    /// Routes each checkbox through `AppSettings` so the card flags and the
    /// ordered `menuBarItems` array keep their existing persisted shape.
    private func binding(_ metric: MenuBarMetric, _ placement: MetricPlacement) -> Binding<Bool> {
        Binding(get: { settings.isShown(metric, in: placement) },
                set: { settings.setShown(metric, in: placement, $0) })
    }

    private var menuBarNote: String {
        settings.showsMetricsInMenuBar
            ? "Metrics ticked under Menu bar replace the MacStats icon. Each one adds width, so two or three is usually the limit before the bar gets crowded."
            : "With nothing ticked under Menu bar, the menu bar shows the MacStats icon."
    }

    private var samplingNote: String {
        settings.showsMetricsInMenuBar
            ? "Sampling runs continuously to keep the menu bar live, which costs a little CPU and battery. Turn off every menu bar metric to have it pause while the popover is closed."
            : "Sampling only runs while the popover is open."
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Metrics") {
                    metricsTable
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

    /// One row per metric with a checkbox for each place it can appear;
    /// replaces two separate eight-toggle lists.
    private var metricsTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("Metric")
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(MetricPlacement.allCases, id: \.self) { placement in
                    Text(placement.columnTitle)
                        .frame(minWidth: Self.checkboxColumnWidth)
                        .gridColumnAlignment(.center)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)

            ForEach(MenuBarMetric.allCases) { metric in
                GridRow {
                    Text(metric.settingsTitle)
                        .accessibilityHidden(true) // each checkbox already names its metric
                    ForEach(MetricPlacement.allCases, id: \.self) { placement in
                        Toggle(placement.accessibilityLabel(for: metric),
                               isOn: binding(metric, placement))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .accessibilityHint(placement.accessibilityHint)
                    }
                }
            }
        }
    }

    private static let checkboxColumnWidth: CGFloat = 64

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

extension MetricPlacement {
    /// Column header in the Settings metrics table.
    var columnTitle: String {
        switch self {
        case .card: return "Card"
        case .menuBar: return "Menu bar"
        }
    }

    /// The checkboxes have no visible label, so VoiceOver needs metric and column.
    func accessibilityLabel(for metric: MenuBarMetric) -> String {
        "\(metric.settingsTitle), \(columnTitle)"
    }

    var accessibilityHint: String {
        switch self {
        case .card: return "Shows this metric as a card when you open MacStats from the menu bar."
        case .menuBar: return "Shows this metric in the menu bar."
        }
    }
}

#Preview {
    SettingsView()
}
