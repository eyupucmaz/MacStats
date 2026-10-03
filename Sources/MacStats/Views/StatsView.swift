import AppKit
import SwiftUI

struct StatsView: View {
    @EnvironmentObject var stats: StatsEngine
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var onboarding = Onboarding.shared
    @State private var selectedTab: PopoverTab = .system

    /// One width for both tabs so switching does not resize the popover sideways;
    /// wide enough for the Audio tab's device pickers and per-app rows.
    static let popoverWidth: CGFloat = 340

    /// Injected by `AppDelegate` so the popover can drive real AppKit windows/menus.
    var onOpenSettings: () -> Void = {}
    var onShowMenu: (NSView) -> Void = { _ in }
    /// Lets `AppDelegate` pause stats sampling while the Audio tab is shown.
    var onSelectTab: (PopoverTab) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if onboarding.isHintVisible {
                OnboardingHint(onDismiss: { onboarding.dismissHint() })
            }

            Picker(L10n.string("MacStats section"), selection: $selectedTab) {
                Text(L10n.string("System")).tag(PopoverTab.system)
                Text(L10n.string("Audio")).tag(PopoverTab.audio)
            }
            .pickerStyle(.segmented)
            // The title is for VoiceOver only; shown, it crowds the segments.
            .labelsHidden()

            Divider()

            if selectedTab == .system {
                systemContent
            } else {
                AudioTab()
            }
        }
        .padding(12)
        .frame(width: Self.popoverWidth)
        .onChange(of: selectedTab) { onSelectTab($0) }
    }

    @ViewBuilder
    private var systemContent: some View {
        if settings.hasVisibleCards {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(cards) { card in
                    StatCard(card: card)
                }
            }
            .padding(.bottom, 8)
        } else {
            Text(L10n.string("All stats are hidden. Enable some in Settings."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
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
            .help(L10n.string("Settings"))
            .accessibilityLabel(L10n.string("Open Settings"))

            MenuAnchorButton(action: onShowMenu)
                .frame(width: 16, height: 16)
                .help(L10n.string("More"))
                .accessibilityLabel(L10n.string("More actions"))
        }
    }

    // MARK: - Cards

    private var cards: [StatCardModel] {
        StatCardFactory.cards(stats.snapshot, settings: settings)
    }
}

enum PopoverTab: Hashable {
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
        button.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: L10n.string("More actions"))
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
