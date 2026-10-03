import SwiftUI

/// The dismissible first-run hint shown above the popover's tabs; see `Onboarding`.
struct OnboardingHint: View {
    var onDismiss: () -> Void = {}

    struct Tip: Identifiable, Equatable {
        let icon: String
        let text: String
        var id: String { icon }
    }

    static var title: String { L10n.string("Welcome to MacStats") }
    static var dismissTitle: String { L10n.string("Got It") }

    /// One line per way into the app, in the order the user meets them.
    static var tips: [Tip] {
        [
            Tip(icon: "cursorarrow.click",
                text: L10n.string("Click the MacStats item in the menu bar to open or close this panel.")),
            Tip(icon: "rectangle.split.2x1",
                text: L10n.string("Use the tabs below to switch between System stats and Audio controls.")),
            Tip(icon: "gearshape",
                text: L10n.string("Click the gear to choose which cards and menu bar metrics to show.")),
            Tip(icon: "ellipsis.circle",
                text: L10n.string("Right-click the menu bar item, or click ⋯, for Settings, About and Quit.")),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.title)
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            ForEach(Self.tips) { tip in
                Label {
                    Text(tip.text)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: tip.icon)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                }
                .font(.caption)
            }
            HStack {
                Spacer()
                Button(Self.dismissTitle, action: onDismiss)
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(.quaternary, in: .rect(cornerRadius: 6))
        .accessibilityElement(children: .contain)
    }
}

#Preview {
    OnboardingHint()
        .frame(width: StatsView.popoverWidth)
        .padding()
}
