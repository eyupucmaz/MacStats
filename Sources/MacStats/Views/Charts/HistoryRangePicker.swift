import SwiftUI

/// The 1 m / 5 m / 15 m / 1 h switch a detail page puts in its header; the
/// page owns the selection and feeds the matching slice to its charts.
struct HistoryRangePicker: View {
    @Binding var selection: HistoryRange

    var body: some View {
        Picker(L10n.string("History range"), selection: $selection) {
            ForEach(HistoryRange.allCases) { range in
                Text(range.chartShortLabel)
                    .accessibilityLabel(range.chartSpokenLabel)
                    .tag(range)
            }
        }
        .pickerStyle(.segmented)
        // The title is for VoiceOver only; shown, it crowds the header.
        .labelsHidden()
        .fixedSize()
    }
}

// Named `chart…` so they never clash with the detail page's own range labels
// (#21); the string keys differ too, so both string blocks can coexist.
extension HistoryRange {
    /// Segment label, e.g. "5 m" / "5 dk".
    var chartShortLabel: String {
        switch self {
        case .oneMinute: return Self.minutes(1)
        case .fiveMinutes: return Self.minutes(5)
        case .fifteenMinutes: return Self.minutes(15)
        case .oneHour: return L10n.string("\(String(1)) h")
        }
    }

    /// Spelled-out form for VoiceOver, e.g. "5 minutes".
    var chartSpokenLabel: String {
        switch self {
        case .oneMinute: return L10n.string("\(String(1)) minute")
        case .fiveMinutes: return L10n.string("\(String(5)) minutes")
        case .fifteenMinutes: return L10n.string("\(String(15)) minutes")
        case .oneHour: return L10n.string("\(String(1)) hour")
        }
    }

    private static func minutes(_ count: Int) -> String {
        L10n.string("\(String(count)) m")
    }
}

#Preview {
    struct Host: View {
        @State var range = HistoryRange.default
        var body: some View {
            HistoryRangePicker(selection: $range).padding()
        }
    }
    return Host()
}
