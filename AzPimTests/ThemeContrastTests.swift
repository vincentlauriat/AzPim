import AppKit
@testable import AzPim
import SwiftUI
import Testing

/// Increase Contrast: every coloured token keeps 4.5:1 (WCAG text) on a panel card and on its own 14 % tinted capsule
/// (Active tag, countdowns), in light and dark mode. Card: the snapshot background with the 6 % `cardFill`.
@MainActor
struct ThemeContrastTests {
    private struct RGB {
        let red: Double, green: Double, blue: Double

        init(_ red: Double, _ green: Double, _ blue: Double) {
            (self.red, self.green, self.blue) = (red, green, blue)
        }
    }

    private static let lightCard = mix(RGB(0, 0, 0), over: RGB(0.96, 0.96, 0.96), alpha: 0.06)
    private static let darkCard = mix(RGB(1, 1, 1), over: RGB(0.12, 0.12, 0.12), alpha: 0.06)

    @Test(arguments: Theme.Tone.all.map(\.name))
    func increasedContrastTokensReachTextContrast(_ name: String) throws {
        let tone = try #require(Theme.Tone.all.first { $0.name == name }?.tone)
        for (dark, card) in [(false, Self.lightCard), (true, Self.darkCard)] {
            let color = Self.rgb(tone.hex(dark: dark, increasedContrast: true))
            let tinted = Self.mix(color, over: card, alpha: 0.14)
            #expect(Self.ratio(color, card) >= 4.5, "\(name) on a \(dark ? "dark" : "light") card")
            #expect(Self.ratio(color, tinted) >= 4.5, "\(name) on its \(dark ? "dark" : "light") capsule")
        }
    }

    /// The tokens follow the setting when drawn (the snapshot override stands in for System Settings).
    @Test func tokensResolveToTheirContrastVersion() throws {
        defer { Theme.contrastOverride = nil }
        Theme.contrastOverride = true
        #expect(try resolvedHex(Theme.active, appearance: .aqua) == Theme.Tone.active.lightContrast)
        #expect(try resolvedHex(Theme.active, appearance: .darkAqua) == Theme.Tone.active.darkContrast)
        Theme.contrastOverride = false
        #expect(try resolvedHex(Theme.active, appearance: .aqua) == Theme.Tone.active.light)
    }

    private func resolvedHex(_ color: Color, appearance name: NSAppearance.Name) throws -> UInt32 {
        let appearance = try #require(NSAppearance(named: name))
        var hex: UInt32 = 0
        appearance.performAsCurrentDrawingAppearance {
            guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            let channel = { (value: CGFloat) in UInt32((value * 255).rounded()) }
            hex = channel(srgb.redComponent) << 16 | channel(srgb.greenComponent) << 8 | channel(srgb.blueComponent)
        }
        return hex
    }

    private static func rgb(_ hex: UInt32) -> RGB {
        RGB(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    private static func mix(_ top: RGB, over bottom: RGB, alpha: Double) -> RGB {
        RGB(top.red * alpha + bottom.red * (1 - alpha), top.green * alpha + bottom.green * (1 - alpha),
            top.blue * alpha + bottom.blue * (1 - alpha))
    }

    /// WCAG 2 relative luminance contrast.
    private static func ratio(_ first: RGB, _ second: RGB) -> Double {
        func luminance(_ color: RGB) -> Double {
            func linear(_ value: Double) -> Double {
                value <= 0.039_28 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
        }
        let (high, low) = (max(luminance(first), luminance(second)), min(luminance(first), luminance(second)))
        return (high + 0.05) / (low + 0.05)
    }
}
