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
            ? L10n.string("Metrics ticked under Menu bar replace the MacStats icon. Each one adds width, so two or three is usually the limit before the bar gets crowded.")
            : L10n.string("With nothing ticked under Menu bar, the menu bar shows the MacStats icon.")
    }

    private var samplingNote: String {
        settings.showsMetricsInMenuBar
            ? L10n.string("Sampling runs continuously to keep the menu bar live, which costs a little CPU and battery. Turn off every menu bar metric to have it pause while the popover is closed.")
            : L10n.string("Sampling only runs while the popover is open.")
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(L10n.string("Metrics")) {
                    metricsTable
                    Text(menuBarNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section(L10n.string("Update Interval")) {
                    Picker(L10n.string("Refresh Rate"), selection: $settings.updateInterval) {
                        ForEach(AppSettings.intervalChoices, id: \.self) { seconds in
                            Text(Self.intervalLabel(seconds)).tag(seconds)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel(L10n.string("Refresh rate"))
                    Text(samplingNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section(L10n.string("Startup")) {
                    Toggle(L10n.string("Launch at Login"), isOn: $settings.launchAtLogin)
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

                Section(L10n.string("About")) {
                    LabeledContent("MacStats", value: L10n.string("Version \(Self.versionString)"))
                    Text(L10n.string("Menu bar system monitor."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button(L10n.string("Done"), action: onDone)
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
                Text(L10n.string("Metric"))
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

    /// Segment title for an update interval, e.g. "5s".
    static func intervalLabel(_ seconds: Double) -> String {
        L10n.string("\(String(Int(seconds)))s")
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?) where short != build: return "\(short) (\(build))"
        case let (short?, _): return short
        case let (_, build?): return build
        default: return L10n.string("unknown")
        }
    }
}

extension MetricPlacement {
    /// Column header in the Settings metrics table.
    var columnTitle: String {
        switch self {
        case .card: return L10n.string("Card")
        case .menuBar: return L10n.string("Menu bar")
        }
    }

    /// The checkboxes have no visible label, so VoiceOver needs metric and column.
    func accessibilityLabel(for metric: MenuBarMetric) -> String {
        L10n.string("\(metric.settingsTitle), \(columnTitle)")
    }

    var accessibilityHint: String {
        switch self {
        case .card: return L10n.string("Shows this metric as a card when you open MacStats from the menu bar.")
        case .menuBar: return L10n.string("Shows this metric in the menu bar.")
        }
    }
}

#Preview {
    SettingsView()
}
