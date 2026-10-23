import AppKit
import SwiftUI

/// PDF Page View Theme (`RDPDFViewTheme` / `_RDPDFDEDrawingModeForPDFViewTheme`)
/// Reverse-engineered from `RDPDFKit.framework` (`-[RDPDFDocumentView documentBackgroundColorForViewTheme:]`)
/// and `RDPDFShaders.metallib`.
public enum PDFViewTheme: Int, CaseIterable, Identifiable, Codable {
    case day = 0
    case sepia = 2
    case night = 1

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .day:   return "日间"
        case .sepia: return "纸质"
        case .night: return "夜间"
        }
    }

    public var englishTitle: String {
        switch self {
        case .day:   return "Day"
        case .sepia: return "Sepia"
        case .night: return "Night"
        }
    }

    public var iconName: String {
        switch self {
        case .day:   return "sun.max.fill"
        case .sepia: return "book.pages.fill"
        case .night: return "moon.stars.fill"
        }
    }

    /// Outline glyph used by the reader toolbar's theme switcher and the theme cards
    public var toolbarIconName: String {
        switch self {
        case .day:   return "sun.max"
        case .sepia: return "scroll"
        case .night: return "moon"
        }
    }

    /// Document canvas background color (`-[RDPDFDocumentView documentBackgroundColorForViewTheme:]` at `0xab1b4`):
    /// - Day: `ColorPalette.systemBackgroundColor` (`#DCDCDE` Light / `#131314` Dark)
    /// - Sepia: `RGB(0.90, 0.87, 0.81)` = `#E5DECF` (`0x2d2bc8..0x2d2bd8`)
    /// - Night: `RGB(0.125490, 0.133333, 0.137255)` = `#202223` (`0x2d2be0, 0x2d29c8, 0x2d2be8`)
    public func documentBackgroundNSColor(isDarkUI: Bool) -> NSColor {
        switch self {
        case .day:
            return isDarkUI
                ? NSColor(srgbRed: 0x13 / 255.0, green: 0x13 / 255.0, blue: 0x14 / 255.0, alpha: 1.0)
                : NSColor(srgbRed: 0xDC / 255.0, green: 0xDC / 255.0, blue: 0xDE / 255.0, alpha: 1.0)
        case .sepia:
            return NSColor(srgbRed: 0.90, green: 0.87, blue: 0.81, alpha: 1.0) // #E5DECF
        case .night:
            return NSColor(srgbRed: 32.0 / 255.0, green: 34.0 / 255.0, blue: 35.0 / 255.0, alpha: 1.0) // #202223
        }
    }

    public func documentBackgroundColor(isDarkUI: Bool) -> Color {
        Color(nsColor: documentBackgroundNSColor(isDarkUI: isDarkUI))
    }

    /// Page paper color (`White (1,1,1)` output of `RDPDFShaders.metallib`):
    /// - Day: `#FFFFFF` `(1.0, 1.0, 1.0)`
    /// - Sepia: `#F5EFDC` `(0.961, 0.938, 0.863)`
    /// - Night: `#000000` `(0.0, 0.0, 0.0)`
    public var pagePaperNSColor: NSColor {
        switch self {
        case .day:
            return NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        case .sepia:
            return NSColor(srgbRed: 0.961, green: 0.938, blue: 0.863, alpha: 1.0) // #F5EFDC
        case .night:
            return NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 1.0) // #000000
        }
    }

    public var pagePaperColor: Color {
        Color(nsColor: pagePaperNSColor)
    }

    /// Page primary ink color (`Black (0,0,0)` output of `RDPDFShaders.metallib`):
    /// - Day: `#000000` `(0.0, 0.0, 0.0)`
    /// - Sepia: `#3F2A18` `(0.247, 0.165, 0.094)`
    /// - Night: `#BFBFBF` `(0.75, 0.75, 0.75)`
    public var pageInkNSColor: NSColor {
        switch self {
        case .day:
            return NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        case .sepia:
            return NSColor(srgbRed: 0.247, green: 0.165, blue: 0.094, alpha: 1.0) // #3F2A18
        case .night:
            return NSColor(srgbRed: 0.750, green: 0.750, blue: 0.750, alpha: 1.0) // #BFBFBF
        }
    }

    public var pageInkColor: Color {
        Color(nsColor: pageInkNSColor)
    }
}

/// App UI Appearance Mode (System / Light / Dark)
public enum AppAppearanceMode: String, CaseIterable, Identifiable, Codable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "浅色外观"
        case .dark:   return "深色外观"
        }
    }

    public var shortTitle: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "浅色"
        case .dark:   return "深色"
        }
    }

    public var iconName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

/// Exact replica of `RDDesignLibrary.ColorPalette` & `Assets.car` extracted from `PDF Expert.app`
public enum RDColorPalette {
    // Primary Brand & Tint Colors
    public static let primaryTint = Color(hex: 0x2FA5FF)
    public static let brightPrimaryTint = Color(hex: 0x7BC6FF)
    public static let systemDarkBlue = Color(hex: 0x0D72FF)

    // Semantic Backgrounds (Light / Dark pairs extracted from RDDesignLibrary disassembly)
    public static func systemBackground(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0x131314 : 0xDCDCDE)
    }

    public static func secondarySystemBackground(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0x2A2A2E : 0xEEEEF0)
    }

    public static func tertiarySystemBackground(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0x343438 : 0xF4F4F7)
    }

    public static func quaternarySystemBackground(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0x3D3D42 : 0xFCFCFF)
    }

    public static func elevatedBackground(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0x2A2A2E : 0xDCDCDE)
    }

    public static func secondaryElevatedBackground(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0x131314 : 0xEEEEF0)
    }

    // Semantic Labels (extracted from PE/Label/* in RDDesignLibrary Assets.car)
    public static func labelPrimary(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0xE3E3E5 : 0x17171A)
    }

    public static func labelSecondary(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0xB1B1B2 : 0x46464D)
    }

    public static func labelTertiary(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0x87878C : 0x7A7A80)
    }

    public static func labelQuaternary(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0x757580 : 0x969699)
    }

    public static func separator(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0x3B3B40 : 0xCACACC)
    }

    public static func cardBackground(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0x232326 : 0xF8F8FB)
    }

    // Primary action blue (prominent buttons, links, selection rings) as rendered by PDF Expert 3.13
    public static let accentBlue = Color(hex: 0x3A82F7)

    // Window Chrome (tab strip + toolbar). PDF Expert always paints this chrome graphite; here every
    // token is a light/dark pair so the title bar follows the appearance while keeping PDF Expert's
    // elevation order: tab strip < toolbar < selected tab.
    public static func tabStripBackground(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0x131314 : 0xE3E3E6)
    }

    public static func tabSelectedBackground(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0x48484D : 0xFFFFFF)
    }

    public static func tabHoverBackground(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0x232326 : 0xD8D8DC)
    }

    public static func tabSeparator(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0x2E2E32 : 0xCBCBD0)
    }

    public static func toolbarBackground(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0x343438 : 0xF6F6F8)
    }

    public static func toolbarControlFill(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0x45454A : 0xE8E8EB)
    }

    public static func toolbarHover(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0x45454A : 0xE6E6EA)
    }

    public static func toolbarActive(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0x56565C : 0xDCDCE1)
    }

    public static func toolbarIcon(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0xD8D8DC : 0x3C3C42)
    }

    public static func chromeHairline(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0x0E0E10 : 0xD6D6DB)
    }

    // Reader Panels (left Document Summary / View Settings dock, right Search dock)
    public static func panelBackground(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0x262629 : 0xF1F1F3)
    }

    public static func panelListBackground(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0x2C2C30 : 0xFFFFFF)
    }

    public static func panelSeparator(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0x3A3A3F : 0xE6E6EA)
    }

    public static func panelHairline(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0x121214 : 0xDADADF)
    }

    public static func segmentedTrack(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0x1C1C1F : 0xE4E4E8)
    }

    public static func segmentedThumb(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0x4A4A50 : 0xFFFFFF)
    }

    public static func rowHover(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0x36363B : 0xF3F3F6)
    }

    // Home Tab (opaque sidebar + white page, as in PDF Expert 3.13)
    public static func homeSidebarBackground(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0x1F1F22 : 0xF1F3F5)
    }

    public static func homeSidebarSelection(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0x313136 : 0xE3E6EA)
    }

    public static func homeContentBackground(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0x161618 : 0xFFFFFF)
    }

    public static func homeCardBackground(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0x242427 : 0xF5F5F7)
    }

    public static func homeCardHover(_ isDark: Bool) -> Color {
        Color(hex: isDark ? 0x2C2C30 : 0xEEEEF1)
    }

    // Accent Colors
    public static let systemGreen = Color(hex: 0x3CC83C)
    public static let systemYellow = Color(hex: 0xFFB72B)
    public static let systemOrange = Color(hex: 0xFF9128)
    public static let systemRed = Color(hex: 0xFA4655)
    public static let systemPurple = Color(hex: 0x5B6AE5)
}

extension Color {
    public init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
