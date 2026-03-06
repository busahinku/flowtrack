import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - AppTheme
enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    case pastel = "Pastel"
    case midnight = "Midnight"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light, .pastel: return .light
        case .dark, .midnight: return .dark
        }
    }

    // System uses the Light or Dark values depending on macOS appearance
    var cardBg: Color {
        switch self {
        case .system: return Color(nsColor: .textBackgroundColor)
        case .light: return .white
        case .dark: return Color(red: 0.15, green: 0.15, blue: 0.17)
        case .pastel: return Color(red: 0.96, green: 0.95, blue: 0.98)
        case .midnight: return Color(red: 0.10, green: 0.10, blue: 0.18)
        }
    }

    var timelineBg: Color {
        switch self {
        case .system: return Color(nsColor: .textBackgroundColor).opacity(0.95)
        case .light: return Color(red: 0.97, green: 0.97, blue: 0.98)
        case .dark: return Color(red: 0.10, green: 0.10, blue: 0.12)
        case .pastel: return Color(red: 0.98, green: 0.97, blue: 1.0)
        case .midnight: return Color(red: 0.06, green: 0.06, blue: 0.12)
        }
    }

    var sidebarBg: Color {
        switch self {
        case .system: return Color(nsColor: .windowBackgroundColor)
        case .light: return Color(red: 0.95, green: 0.95, blue: 0.97)
        case .dark: return Color(red: 0.12, green: 0.12, blue: 0.14)
        case .pastel: return Color(red: 0.94, green: 0.93, blue: 0.97)
        case .midnight: return Color(red: 0.07, green: 0.07, blue: 0.14)
        }
    }

    var gridLineColor: Color {
        switch self {
        case .system: return Color(nsColor: .separatorColor)
        case .light: return Color.gray.opacity(0.2)
        case .dark: return Color.gray.opacity(0.15)
        case .pastel: return Color.purple.opacity(0.1)
        case .midnight: return Color.blue.opacity(0.15)
        }
    }

    var hourLabelColor: Color {
        switch self {
        case .system: return .secondary
        case .light: return .secondary
        case .dark: return Color.gray
        case .pastel: return Color(red: 0.5, green: 0.4, blue: 0.6)
        case .midnight: return Color(red: 0.4, green: 0.4, blue: 0.7)
        }
    }

    var accentColor: Color {
        switch self {
        case .system, .light, .dark: return .blue
        case .pastel: return Color(red: 0.6, green: 0.4, blue: 0.8)
        case .midnight: return Color(red: 0.3, green: 0.4, blue: 0.9)
        }
    }

    var primaryText: Color {
        switch self {
        case .system: return Color(nsColor: .labelColor)
        case .light: return Color(white: 0.10)
        case .dark: return Color(white: 0.92)
        case .pastel: return Color(red: 0.22, green: 0.18, blue: 0.32)
        case .midnight: return Color(red: 0.82, green: 0.86, blue: 1.0)
        }
    }

    var secondaryText: Color {
        switch self {
        case .system: return Color(nsColor: .secondaryLabelColor)
        case .light: return Color(white: 0.45)
        case .dark: return Color(white: 0.50)
        case .pastel: return Color(red: 0.50, green: 0.42, blue: 0.62)
        case .midnight: return Color(red: 0.45, green: 0.50, blue: 0.72)
        }
    }

    /// Positive / success state (green family)
    var successColor: Color {
        switch self {
        case .system: return .green
        case .light: return Color(red: 0.18, green: 0.65, blue: 0.32)
        case .dark: return Color(red: 0.25, green: 0.82, blue: 0.45)
        case .pastel: return Color(red: 0.28, green: 0.68, blue: 0.52)
        case .midnight: return Color(red: 0.18, green: 0.88, blue: 0.62)
        }
    }

    /// Negative / error / stop state (red family)
    var errorColor: Color {
        switch self {
        case .system: return .red
        case .light: return Color(red: 0.85, green: 0.20, blue: 0.20)
        case .dark: return Color(red: 1.0, green: 0.40, blue: 0.40)
        case .pastel: return Color(red: 0.88, green: 0.40, blue: 0.55)
        case .midnight: return Color(red: 1.0, green: 0.32, blue: 0.48)
        }
    }

    /// Warning / caution state (orange/amber family)
    var warningColor: Color {
        switch self {
        case .system: return .orange
        case .light: return Color(red: 0.92, green: 0.55, blue: 0.10)
        case .dark: return Color(red: 1.0, green: 0.72, blue: 0.28)
        case .pastel: return Color(red: 0.93, green: 0.62, blue: 0.38)
        case .midnight: return Color(red: 1.0, green: 0.76, blue: 0.28)
        }
    }

    /// Informational / decorative highlight (blue/violet family)
    var infoColor: Color {
        switch self {
        case .system: return .blue
        case .light: return Color(red: 0.20, green: 0.45, blue: 0.95)
        case .dark: return Color(red: 0.40, green: 0.67, blue: 1.0)
        case .pastel: return Color(red: 0.55, green: 0.40, blue: 0.88)
        case .midnight: return Color(red: 0.38, green: 0.58, blue: 1.0)
        }
    }

    /// Current-time indicator line in the timeline
    var nowLineColor: Color { errorColor }

    /// Foreground text/icon colour used on top of accent-filled or selected backgrounds
    var selectedForeground: Color {
        switch self {
        case .system, .light, .dark, .pastel: return .white
        case .midnight: return Color(red: 0.88, green: 0.92, blue: 1.0)
        }
    }

    /// Base colour for drop-shadows — apply `.opacity()` at the call-site
    var shadowColor: Color {
        switch self {
        case .system, .light, .dark, .midnight: return .black
        case .pastel: return Color(red: 0.40, green: 0.20, blue: 0.60)
        }
    }

    /// Subtle separator / divider colour — apply `.opacity()` at the call-site
    var dividerColor: Color {
        switch self {
        case .system: return Color(nsColor: .separatorColor)
        case .light: return Color(white: 0.70)
        case .dark: return Color(white: 0.40)
        case .pastel: return Color(red: 0.60, green: 0.40, blue: 0.80)
        case .midnight: return Color(red: 0.25, green: 0.30, blue: 0.65)
        }
    }

    /// Asset name for menu bar / in-app logo by theme. For .system, pass current colorScheme.
    func menuBarIconName(under colorScheme: ColorScheme?) -> String {
        switch self {
        case .system:
            return (colorScheme == .dark) ? "WhiteLogo" : "DarkLogo"
        case .light:
            return "DarkLogo"
        case .dark, .midnight:
            return "WhiteLogo"
        case .pastel:
            return "PastelLogo"
        }
    }
}

// MARK: - Menu bar icon: template image so macOS auto-colors it like all other menu bar icons
struct MenuBarIconView: View {
    var size: CGFloat = 18

    var body: some View {
        Image(nsImage: templateIcon(size: size))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }

    /// Loads DarkLogo and marks it as a template image.
    /// macOS then renders it in the correct menu bar foreground color automatically.
    private func templateIcon(size: CGFloat) -> NSImage {
        guard let source = NSImage(named: "DarkLogo") else {
            let fallback = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil) ?? NSImage()
            fallback.isTemplate = true
            return fallback
        }
        let targetSize = NSSize(width: size, height: size)
        let scaled = NSImage(size: targetSize)
        scaled.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(origin: .zero, size: targetSize),
                    from: NSRect(origin: .zero, size: source.size),
                    operation: .copy, fraction: 1)
        scaled.unlockFocus()
        scaled.isTemplate = true   // ← macOS handles dark/light automatically
        return scaled
    }
}

// MARK: - Theme-aware icon for in-app only (headers, onboarding) — uses app theme
struct ThemeAwareMenuIcon: View {
    @Bindable private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme

    var size: CGFloat = 18

    var body: some View {
        Group {
            if let nsImage = loadIcon(name: settings.appTheme.menuBarIconName(under: colorScheme), side: size) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "bolt.fill")
                    .font(.system(size: size))
            }
        }
        .frame(width: size, height: size)
    }

    private func loadIcon(name: String, side: CGFloat) -> NSImage? {
        guard let img = NSImage(named: name) else { return nil }
        let targetSize = NSSize(width: side, height: side)
        let newImage = NSImage(size: targetSize)
        newImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        img.draw(in: NSRect(origin: .zero, size: targetSize),
                 from: NSRect(origin: .zero, size: img.size),
                 operation: .copy,
                 fraction: 1)
        newImage.unlockFocus()
        return newImage
    }
}

// MARK: - Theme Helpers
enum Theme {
    static var current: AppTheme {
        AppSettings.shared.appTheme
    }

    private static let formatterAMPM: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()
    private static let formatter24h: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    static func color(for category: Category) -> Color {
        CategoryManager.shared.color(for: category)
    }

    static func formatDuration(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "<1m"
    }

    static func formatTime(_ date: Date) -> String {
        let f = AppSettings.shared.use24HourClock ? formatter24h : formatterAMPM
        return f.string(from: date)
    }

    static func formatTimeRange(_ start: Date, _ end: Date) -> String {
        "\(formatTime(start)) – \(formatTime(end))"
    }
}
