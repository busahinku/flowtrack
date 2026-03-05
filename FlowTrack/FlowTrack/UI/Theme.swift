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
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    static func formatTimeRange(_ start: Date, _ end: Date) -> String {
        "\(formatTime(start)) – \(formatTime(end))"
    }
}
