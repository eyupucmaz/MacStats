import AppKit
import SwiftUI

struct StatsView: View {
    @EnvironmentObject var stats: StatsEngine
    @ObservedObject private var settings = AppSettings.shared
    @State private var selectedTab: PopoverTab = .system

    /// Injected by `AppDelegate` so the popover can drive real AppKit windows/menus.
    var onOpenSettings: () -> Void = {}
    var onShowMenu: (NSView) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("MacStats section", selection: $selectedTab) {
                Text("System").tag(PopoverTab.system)
                Text("Audio").tag(PopoverTab.audio)
            }
            .pickerStyle(.segmented)

            if selectedTab == .system {
                systemContent
            } else {
                AudioTab()
            }
        }
        .padding(12)
        .frame(width: selectedTab == .system ? 320 : 360)
    }

    private var systemContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            if settings.hasVisibleCards {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(cards) { card in
                        StatCard(card: card)
                    }
                }
                .padding(.bottom, 8)
            } else {
                Text("All stats are hidden. Enable some in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("MacStats")
                .font(.headline)
            Spacer()
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Open Settings")

            MenuAnchorButton(action: onShowMenu)
                .frame(width: 16, height: 16)
                .help("More")
                .accessibilityLabel("More actions")
        }
        .padding(.bottom, 4)
    }

    // MARK: - Cards

    private var cards: [StatCardModel] {
        StatCardFactory.cards(stats.snapshot, settings: settings)
    }
}

private enum PopoverTab: Hashable {
    case system
    case audio
}

struct StatCard: View {
    let card: StatCardModel

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: card.icon)
                .foregroundStyle(card.color)
                .font(.caption)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(card.value)
                    .font(.caption)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(.quaternary, in: .rect(cornerRadius: 6))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.accessibility)
    }
}

/// A borderless SwiftUI button that hands its backing `NSView` to the action so
/// AppKit can anchor an `NSMenu` to it.
private struct MenuAnchorButton: NSViewRepresentable {
    let action: (NSView) -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More actions")
        button.contentTintColor = .secondaryLabelColor
        button.target = context.coordinator
        button.action = #selector(Coordinator.fire(_:))
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: (NSView) -> Void
        init(action: @escaping (NSView) -> Void) { self.action = action }
        @objc func fire(_ sender: NSButton) { action(sender) }
    }
}

#Preview {
    StatsView()
        .environmentObject(StatsEngine.shared)
}
