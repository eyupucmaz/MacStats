import AppKit
import SwiftUI

/// Series colors and dash patterns for `MetricChart`. Each color has a light
/// and a dark variant chosen to reach at least 3:1 contrast (WCAG 1.4.11, non-
/// text graphics) against the popover background in that appearance, and each
/// series also has its own dash pattern so it can be told apart without color.
enum ChartPalette {
    /// sRGB components, 0–255.
    struct RGB: Equatable {
        let red: Int
        let green: Int
        let blue: Int

        /// WCAG relative luminance.
        var luminance: Double {
            func channel(_ value: Int) -> Double {
                let c = Double(value) / 255
                return c <= 0.039_28 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
        }

        func contrast(with other: RGB) -> Double {
            let (a, b) = (luminance, other.luminance)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }

        var nsColor: NSColor {
            NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        }
    }

    /// Blue, orange, green, purple — in that order, so two-series charts get
    /// the most distinct pair.
    static let light: [RGB] = [
        RGB(red: 0x1F, green: 0x6F, blue: 0xEB),
        RGB(red: 0xC2, green: 0x41, blue: 0x0C),
        RGB(red: 0x0F, green: 0x7B, blue: 0x6C),
        RGB(red: 0x8B, green: 0x3F, blue: 0xD9),
    ]

    static let dark: [RGB] = [
        RGB(red: 0x58, green: 0xA6, blue: 0xFF),
        RGB(red: 0xFB, green: 0x92, blue: 0x3C),
        RGB(red: 0x34, green: 0xD3, blue: 0x99),
        RGB(red: 0xC4, green: 0xA5, blue: 0xFF),
    ]

    /// The darkest light-mode and the lightest dark-mode popover backgrounds
    /// the colors were checked against (the popover's material varies with
    /// the desktop behind it).
    static let lightBackgrounds = [RGB(red: 0xFF, green: 0xFF, blue: 0xFF), RGB(red: 0xD8, green: 0xD8, blue: 0xD8)]
    static let darkBackgrounds = [RGB(red: 0x1E, green: 0x1E, blue: 0x1E), RGB(red: 0x3C, green: 0x3C, blue: 0x3C)]

    /// Solid, dashed, dotted, dash-dot.
    static let dashes: [[CGFloat]] = [[], [6, 3], [1.5, 2.5], [7, 2.5, 1.5, 2.5]]

    static let lineWidth: CGFloat = 1.6

    static func color(_ index: Int) -> Color {
        let index = index % light.count
        let light = light[index].nsColor
        let dark = dark[index].nsColor
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    static func dash(_ index: Int) -> [CGFloat] {
        dashes[index % dashes.count]
    }

    static func stroke(_ index: Int, width: CGFloat = lineWidth) -> StrokeStyle {
        // Round caps would grow every dash by the line width and close the gaps.
        let dash = dash(index)
        return StrokeStyle(lineWidth: width, lineCap: dash.isEmpty ? .round : .butt, lineJoin: .round, dash: dash)
    }
}
