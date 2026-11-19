import SwiftUI
import AppKit
import AdmiralCore

/// Semantic color tokens that resolve per system appearance (auto light/dark).
/// Centralizing them keeps the Warp look in one place.
enum Theme {
    static let accent = adaptive(light: 0x6C5CE7, dark: 0x8B7CF6)

    // ONE surface color for every main area — header, sidebar, content, and the claude
    // terminal — so the blacks all match. Dark = #121212 (Warp-style); light = #FFFFFF;
    // Stealth flag = the top of Stealth Browser's dark top-bar gradient.
    private static let darkSurface: UInt = 0x121212
    private static let stealthSurface: UInt = 0x0D1420
    static let surfaceNS = adaptiveNS(light: 0xFFFFFF, dark: darkSurface, stealth: stealthSurface)
    static let surface = Color(nsColor: surfaceNS)
    static let windowBackground = surface
    static let sidebarBackground = surface
    static let contentBackground = surface

    static let primaryText = Color(nsColor: .labelColor)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)

    // Elevated surfaces sit slightly above the flat surface so they stay legible.
    static let bubbleBackground = lifted(light: 0xFFFFFF, dark: 0x1F1F1F)
    static let bubbleBorder = lifted(light: 0xE6E6EC, dark: 0x2C2C2C)

    /// A faint accent-tinted card for the human's prompt (Warp-style), no fake avatar.
    static let userPromptBackground = lifted(light: 0xF4F2FD, dark: 0x232331)

    /// Selected sidebar row: a neutral fill we draw ourselves (same in every focus state).
    static let rowSelection = lifted(light: 0xE7E7EE, dark: 0x2A2A2A)
    static let rowHover = lifted(light: 0xF0F0F4, dark: 0x222222)

    static let codeChipBackground = adaptive(light: 0xEDEBFB, dark: 0x2C2942)
    static let codeChipText = adaptive(light: 0x4B3FB0, dark: 0xB7ADF5)

    static let planCardBackground = lifted(light: 0xF5F5F7, dark: 0x1E1E1E)
    static let planCardHeader = lifted(light: 0xEDEDF0, dark: 0x262626)

    static let chipBackground = lifted(light: 0xF0F0F3, dark: 0x222222)

    static let checkGreen = adaptive(light: 0x2BA84A, dark: 0x46D16B)
    static let inProgressBlue = adaptive(light: 0x2F6BFF, dark: 0x5B8CFF)
    static let pendingGray = adaptive(light: 0xBFBFC7, dark: 0x5A5A62)

    /// A tool card's diff rows: faint fills behind added / removed lines, quiet enough that
    /// the text on them keeps its normal color.
    static let diffAdded = adaptive(light: 0xE6F6EA, dark: 0x16301E)
    static let diffRemoved = adaptive(light: 0xFCE9E9, dark: 0x3A1D1F)
    /// A failed tool call's mark.
    static let failureRed = adaptive(light: 0xD93B3B, dark: 0xF26B6B)

    static let userAvatar = adaptive(light: 0x2F6BFF, dark: 0x5B8CFF)
    static let busyAmber = adaptive(light: 0xE8912D, dark: 0xF2A93B)
    /// "Unseen completed work" dot — the unread-blue convention, distinct from the amber
    /// busy comet and the gray idle status.
    static let attention = adaptive(light: 0x2F6BFF, dark: 0x5B8CFF)

    /// Status dot color by activity (busy is distinct from the completed-check green).
    static func statusColor(_ status: SessionStatus) -> Color {
        switch status {
        case .busy: return busyAmber
        case .idle: return Color(nsColor: .systemGray)
        case .shell, .unknown: return pendingGray
        }
    }

    /// Whether dark surfaces draw the Stealth palette. `AppModel.applyTheme` is the only writer;
    /// the dynamic colors below read it whenever they resolve.
    nonisolated(unsafe) static var usesStealthPalette = false

    static func adaptive(light: UInt, dark: UInt) -> Color {
        Color(nsColor: adaptiveNS(light: light, dark: dark))
    }

    /// Stealth Browser's hover fill: the blue that the Dark chip gray (0x222222) maps to.
    private static let stealthStep: UInt = 0x172131

    /// A neutral raised above the surface. Under the Stealth flag its lift runs along Stealth
    /// Browser's blue ramp instead of toward gray. Computed to an opaque color rather than drawn
    /// translucent: cards nest, and text scrolls beneath some of them.
    static func lifted(light: UInt, dark: UInt) -> Color {
        let lift = CGFloat(Int((dark >> 16) & 0xFF) - Int(darkSurface & 0xFF)) / CGFloat(0x22 - 0x12)
        let channel = { (shift: UInt) -> UInt in
            let base = CGFloat((stealthSurface >> shift) & 0xFF)
            let step = CGFloat((stealthStep >> shift) & 0xFF)
            return UInt((base + (step - base) * lift).rounded()) << shift
        }
        return Color(nsColor: adaptiveNS(light: light, dark: dark,
                                         stealth: channel(16) | channel(8) | channel(0)))
    }

    /// The appearance Admiral actually draws in — which is **not** the system's when the
    /// theme is pinned. SwiftUI gets this via `.preferredColorScheme`, but AppKit views we
    /// hand colors to (the terminal) have to be told explicitly.
    @MainActor
    static func appearance(for mode: ThemeMode) -> NSAppearance {
        switch mode {
        case .auto: NSApp.effectiveAppearance
        case .light: NSAppearance(named: .aqua) ?? NSApp.effectiveAppearance
        case .dark: NSAppearance(named: .darkAqua) ?? NSApp.effectiveAppearance
        }
    }

    /// Flatten a dynamic color to a static one for `appearance`.
    ///
    /// Load-bearing for the terminal: SwiftTerm snapshots whatever color it is handed into a
    /// `CGColor` on the view's layer, and since upstream `e4f31b0` that layer *is* the default
    /// background (runs carrying it are no longer filled). A dynamic `NSColor` therefore freezes
    /// at whatever `NSAppearance.current` was at assignment — the *system* appearance, because
    /// the view isn't in the window yet — so a light-mode Mac in dark mode got white terminals.
    static func resolved(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
        var out = color
        appearance.performAsCurrentDrawingAppearance { out = color.usingColorSpace(.sRGB) ?? color }
        return out
    }

    /// Dynamic NSColor that resolves per appearance — used directly for the window/title
    /// bar background so the header matches the chrome in both light and dark. `stealth`
    /// replaces `dark` while the Stealth flag is on.
    static func adaptiveNS(light: UInt, dark: UInt, stealth: UInt? = nil) -> NSColor {
        NSColor(name: nil) { appearance in
            guard appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua else {
                return NSColor(hex: light)
            }
            return NSColor(hex: usesStealthPalette ? stealth ?? dark : dark)
        }
    }
}

extension Color {
    /// `#RRGGBB` (or `RRGGBB`) → Color. Nil for malformed strings.
    init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self = Color(.sRGB,
                     red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }

    /// `#RRGGBB` for this color (sRGB).
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X",
                      Int(round(ns.redComponent * 255)),
                      Int(round(ns.greenComponent * 255)),
                      Int(round(ns.blueComponent * 255)))
    }
}

extension NSColor {
    convenience init(hex: UInt) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
