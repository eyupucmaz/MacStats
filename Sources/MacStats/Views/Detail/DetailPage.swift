import SwiftUI

/// The frame every metric page is built in: a header with the live card value,
/// an optional range picker, then the page's sections stacked top to bottom.
///
///     @State private var range = HistoryRange.default
///
///     DetailPage(metric: .cpu, range: $range) {
///         DetailSection(usageTitle) { … }
///     }
///
/// `StatsView` puts the page in a scroll view and caps the popover's height,
/// so a page only lays out its content.
struct DetailPage<Content: View>: View {
    let metric: MenuBarMetric
    let range: Binding<HistoryRange>?
    let content: Content

    @EnvironmentObject private var stats: StatsEngine
    @EnvironmentObject private var navigation: DetailNavigation

    init(metric: MenuBarMetric, range: Binding<HistoryRange>? = nil, @ViewBuilder content: () -> Content) {
        self.metric = metric
        self.range = range
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailHeader(metric: metric, card: metric.card(stats.snapshot)) {
                withAnimation(DetailNavigation.animation) { navigation.back() }
            }
            if let range {
                DetailRangePicker(selection: range)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Back chevron, metric icon and title, and the same value the card shows.
struct DetailHeader: View {
    let metric: MenuBarMetric
    let card: StatCardModel
    let onBack: () -> Void

    @FocusState private var isBackFocused: Bool
    @AccessibilityFocusState private var isTitleFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut(.cancelAction)
            .focused($isBackFocused)
            .help(L10n.string("Back"))
            .accessibilityLabel(L10n.string("Back to all stats"))

            Image(systemName: card.icon)
                .foregroundStyle(card.color)
                .accessibilityHidden(true)
            Text(metric.detailTitle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($isTitleFocused)
            Spacer(minLength: 8)
            Text(card.value)
                .font(.subheadline)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .accessibilityLabel(card.accessibility)
        }
        // A button takes one shortcut, so ⌘[ gets an invisible twin of the chevron.
        .background {
            Button("", action: onBack)
                .keyboardShortcut("[", modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
        }
        // Land keyboard users on the way back and VoiceOver on the page title.
        .onAppear {
            isBackFocused = true
            isTitleFocused = true
        }
    }
}

/// The 1 m / 5 m / 15 m / 1 h selector shared by every page with charts.
struct DetailRangePicker: View {
    @Binding var selection: HistoryRange

    var body: some View {
        Picker(L10n.string("Time range"), selection: $selection) {
            ForEach(HistoryRange.allCases) { range in
                Text(range.pickerLabel)
                    .accessibilityLabel(range.spokenLabel)
                    .tag(range)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

extension HistoryRange {
    var pickerLabel: String {
        switch self {
        case .oneMinute: return L10n.string("1m")
        case .fiveMinutes: return L10n.string("5m")
        case .fifteenMinutes: return L10n.string("15m")
        case .oneHour: return L10n.string("1h")
        }
    }

    var spokenLabel: String {
        switch self {
        case .oneMinute: return L10n.string("1 minute")
        case .fiveMinutes: return L10n.string("5 minutes")
        case .fifteenMinutes: return L10n.string("15 minutes")
        case .oneHour: return L10n.string("1 hour")
        }
    }
}

/// A titled block of a detail page.
struct DetailSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }
}

/// Shown instead of a value or section the hardware or macOS does not expose,
/// so nothing is ever drawn as a made-up zero.
struct DetailUnavailableView: View {
    var title = Self.notAvailableTitle
    let reason: String
    var icon = "exclamationmark.circle"

    static var notAvailableTitle: String { L10n.string("Not available on this Mac") }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .accessibilityElement(children: .combine)
    }
}
