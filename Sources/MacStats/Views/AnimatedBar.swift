import AppKit
import QuartzCore
import SwiftUI

/// A bar filled by stacked segments that eases to each new reading, drawn with Core
/// Animation layers.
///
/// The CPU core bars and the fan gauges used to animate with SwiftUI's `.animation`.
/// The popover is one hosting view, so every frame of those 0.2 s animations laid out
/// and re-rendered the whole page, about 20 % of a core while the page was open
/// (#35). Here the render server runs the animation and the app does no work per frame.
///
/// Draws only the fills; put the track behind it in SwiftUI. Hidden from VoiceOver:
/// the surrounding view carries the value.
struct AnimatedBar: NSViewRepresentable {
    enum Direction {
        /// Bottom-up, segments stacked in order.
        case up
        /// From the leading edge, segments side by side in order.
        case forward
    }

    struct Segment: Equatable {
        /// Share of the bar's length, 0...1.
        let fraction: Double
        let color: NSColor
    }

    let direction: Direction
    let segments: [Segment]
    /// Rounds the corners of the whole bar, clipping the fills.
    var cornerRadius: CGFloat = 0
    /// Rounds each fill's ends, like a capsule.
    var roundsFills = false

    static let duration = 0.2

    func makeNSView(context: Context) -> AnimatedBarView {
        let view = AnimatedBarView()
        view.configure(self, animated: false)
        return view
    }

    func updateNSView(_ view: AnimatedBarView, context: Context) {
        view.configure(self, animated: !context.transaction.disablesAnimations)
    }
}

final class AnimatedBarView: NSView {
    private var bar: AnimatedBar?
    private var fills: [CALayer] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ bar: AnimatedBar, animated: Bool) {
        let changed = bar.segments != self.bar?.segments || bar.direction != self.bar?.direction
        // A first reading appears in place, as SwiftUI's value-driven animation did.
        let animates = animated && self.bar != nil && changed
        self.bar = bar
        layer?.cornerRadius = bar.cornerRadius
        while fills.count < bar.segments.count {
            let fill = CALayer()
            layer?.addSublayer(fill)
            fills.append(fill)
        }
        apply(animated: animates)
    }

    override func layout() {
        super.layout()
        apply(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply(animated: false)
    }

    /// Lays the fills out end to end from the bar's start.
    private func apply(animated: Bool) {
        guard let bar else { return }
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(AnimatedBar.duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        let size = bounds.size
        let length = bar.direction == .up ? size.height : size.width
        let mirrored = bar.direction == .forward && userInterfaceLayoutDirection == .rightToLeft
        var offset: CGFloat = 0
        for (index, fill) in fills.enumerated() {
            let fraction = index < bar.segments.count ? min(max(bar.segments[index].fraction, 0), 1) : 0
            let extent = length * CGFloat(fraction)
            switch bar.direction {
            case .up:
                fill.frame = CGRect(x: 0, y: offset, width: size.width, height: extent)
            case .forward:
                fill.frame = CGRect(x: mirrored ? size.width - offset - extent : offset, y: 0,
                                    width: extent, height: size.height)
            }
            offset += extent
            fill.cornerRadius = bar.roundsFills ? min(fill.frame.width, fill.frame.height) / 2 : 0
            if index < bar.segments.count {
                var color: CGColor?
                effectiveAppearance.performAsCurrentDrawingAppearance {
                    color = bar.segments[index].color.cgColor
                }
                fill.backgroundColor = color
            }
        }
        CATransaction.commit()
    }
}
