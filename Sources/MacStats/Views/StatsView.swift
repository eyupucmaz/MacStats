import AppKit
import SwiftUI

/// Does not observe `StatsEngine` itself: only the card grid and the detail pages do,
/// so a tick re-renders the numbers, not the header, tab picker and frame around
/// them (#35).
struct StatsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var onboarding = Onboarding.shared
    @ObservedObject var navigation: DetailNavigation
    /// The card with keyboard focus; Return opens it.
    @FocusState private var focusedCard: MenuBarMetric?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One width for both tabs so switching does not resize the popover sideways;
    /// wide enough for the Audio tab's device pickers and per-app rows.
    static let popoverWidth: CGFloat = 340
    /// Detail pages grow the popover up to this height, then scroll.
    static let maxPopoverHeight: CGFloat = 560

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

            Picker(L10n.string("MacStats section"), selection: $navigation.tab) {
                Text(L10n.string("System")).tag(PopoverTab.system)
                Text(L10n.string("Audio")).tag(PopoverTab.audio)
            }
            .pickerStyle(.segmented)
            // The title is for VoiceOver only; shown, it crowds the segments.
            .labelsHidden()

            Divider()

            if navigation.tab == .system {
                systemContent
            } else {
                AudioTab()
            }
        }
        .padding(12)
        .frame(width: Self.popoverWidth)
        // Past the cap the popover stops growing and the page's scroll view
        // takes the squeeze. The Audio tab keeps sizing itself.
        .frame(maxHeight: navigation.tab == .system ? Self.maxPopoverHeight : nil)
        .environmentObject(navigation)
        .onChange(of: navigation.tab) { onSelectTab($0) }
    }

    /// The grid and the detail pages slide like a navigation stack: a page
    /// comes in from the trailing edge and leaves the same way.
    private var systemContent: some View {
        ZStack(alignment: .top) {
            switch navigation.route {
            case .grid:
                grid
                    .transition(pageTransition(from: .leading))
            case .detail(let metric):
                ScrollView {
                    MetricDetailView(metric: metric)
                        .padding(.bottom, 8)
                }
                .transition(pageTransition(from: .trailing))
            }
        }
        .clipped()
    }

    private func pageTransition(from edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    private func open(_ metric: MenuBarMetric) {
        withAnimation(DetailNavigation.animation) { navigation.open(metric) }
    }

    @ViewBuilder
    private var grid: some View {
        if settings.hasVisibleCards {
            StatCardGrid(settings: settings, focusedCard: $focusedCard, open: open)
                .padding(.bottom, 8)
                // Space presses a focused button; this lets Return open it too.
                .background {
                    Button("") { focusedCard.map(open) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(focusedCard == nil)
                        .hidden()
                        .accessibilityHidden(true)
                }
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
}

/// The cards, the one part of the grid view that changes on every tick.
private struct StatCardGrid: View {
    @EnvironmentObject private var stats: StatsEngine
    @ObservedObject var settings: AppSettings
    var focusedCard: FocusState<MenuBarMetric?>.Binding
    let open: (MenuBarMetric) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(StatCardFactory.cards(stats.snapshot, settings: settings)) { card in
                if let metric = card.metric {
                    Button { open(metric) } label: {
                        StatCard(card: card, isFocused: focusedCard.wrappedValue == metric)
                    }
                    .buttonStyle(StatCardButtonStyle())
                    .focused(focusedCard, equals: metric)
                    .accessibilityLabel(card.accessibility)
                    .accessibilityHint(L10n.string("Opens details"))
                }
            }
        }
    }
}

enum PopoverTab: Hashable {
    case system
    case audio
}

struct StatCard: View {
    let card: StatCardModel
    var isFocused = false

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
            // Hints that the card opens a page.
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(6)
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.accessibility)
    }
}

/// The card's background, stronger on hover and while pressed, plus the
/// pointing-hand cursor that says it is clickable.
private struct StatCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StatCardButton(configuration: configuration)
    }

    private struct StatCardButton: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(background, in: .rect(cornerRadius: 6))
                .contentShape(.rect(cornerRadius: 6))
                .onHover { hovering in
                    guard hovering != isHovered else { return }
                    isHovered = hovering
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                // Opening a page removes the card from under the pointer, which
                // may never report the exit and would leave the hand pushed.
                .onDisappear {
                    if isHovered { NSCursor.pop() }
                    isHovered = false
                }
                .modifier(NoSystemFocusRing())
        }

        private var background: AnyShapeStyle {
            if configuration.isPressed { return AnyShapeStyle(.tertiary) }
            return isHovered ? AnyShapeStyle(.tertiary.opacity(0.6)) : AnyShapeStyle(.quaternary)
        }
    }
}

/// `StatCard` draws its own rounded focus ring; the system's would double it.
private struct NoSystemFocusRing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
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
    StatsView(navigation: DetailNavigation())
        .environmentObject(StatsEngine.shared)
}
