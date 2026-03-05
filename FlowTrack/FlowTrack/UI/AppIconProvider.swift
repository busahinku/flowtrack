import SwiftUI
import AppKit

// MARK: - AppIconProvider
enum AppIconProvider {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}

// MARK: - AppIconImage (SwiftUI)
struct AppIconImage: View {
    let bundleID: String
    var size: CGFloat = 20

    var body: some View {
        if let nsImage = AppIconProvider.icon(for: bundleID) {
            Image(nsImage: nsImage)
                .resizable()
                .frame(width: size, height: size)
                .cornerRadius(4)
        } else {
            Image(systemName: "app.fill")
                .resizable()
                .frame(width: size, height: size)
                .foregroundStyle(.secondary)
        }
    }
}
