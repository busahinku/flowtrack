import Foundation

struct BrowserDescriptor: Sendable {
    let bundleIDs: Set<String>
    let bundleIDPrefixes: [String]
    let nameMarkers: [String]
    let usesSafariScript: Bool
    let usesChromiumScript: Bool
    let usesFirefoxAX: Bool
    let appleScriptAppName: String?
}

enum BrowserCatalog {
    nonisolated private static let descriptors: [BrowserDescriptor] = [
        BrowserDescriptor(
            bundleIDs: ["com.apple.safari"],
            bundleIDPrefixes: [],
            nameMarkers: ["safari"],
            usesSafariScript: true,
            usesChromiumScript: false,
            usesFirefoxAX: false,
            appleScriptAppName: "Safari"
        ),
        BrowserDescriptor(
            bundleIDs: ["com.apple.safaritechnologypreview"],
            bundleIDPrefixes: [],
            nameMarkers: ["safari technology preview"],
            usesSafariScript: true,
            usesChromiumScript: false,
            usesFirefoxAX: false,
            appleScriptAppName: "Safari Technology Preview"
        ),
        BrowserDescriptor(
            bundleIDs: ["com.google.chrome", "com.google.chrome.canary"],
            bundleIDPrefixes: ["com.google.chrome."],
            nameMarkers: ["google chrome", "chrome canary", "chrome beta", "chrome dev"],
            usesSafariScript: false,
            usesChromiumScript: true,
            usesFirefoxAX: false,
            appleScriptAppName: "Google Chrome"
        ),
        BrowserDescriptor(
            bundleIDs: ["com.brave.browser"],
            bundleIDPrefixes: ["com.brave.browser."],
            nameMarkers: ["brave browser", "brave"],
            usesSafariScript: false,
            usesChromiumScript: true,
            usesFirefoxAX: false,
            appleScriptAppName: "Brave Browser"
        ),
        BrowserDescriptor(
            bundleIDs: ["com.microsoft.edgemac"],
            bundleIDPrefixes: ["com.microsoft.edgemac."],
            nameMarkers: ["microsoft edge", "edge"],
            usesSafariScript: false,
            usesChromiumScript: true,
            usesFirefoxAX: false,
            appleScriptAppName: "Microsoft Edge"
        ),
        BrowserDescriptor(
            bundleIDs: ["com.opera.opera", "com.operasoftware.opera", "com.operasoftware.operagx"],
            bundleIDPrefixes: ["com.operasoftware.opera"],
            nameMarkers: ["opera gx", "opera"],
            usesSafariScript: false,
            usesChromiumScript: true,
            usesFirefoxAX: false,
            appleScriptAppName: "Opera"
        ),
        BrowserDescriptor(
            bundleIDs: ["com.vivaldi.vivaldi"],
            bundleIDPrefixes: ["com.vivaldi.vivaldi."],
            nameMarkers: ["vivaldi"],
            usesSafariScript: false,
            usesChromiumScript: true,
            usesFirefoxAX: false,
            appleScriptAppName: "Vivaldi"
        ),
        BrowserDescriptor(
            bundleIDs: ["company.thebrowser.browser"],
            bundleIDPrefixes: ["company.thebrowser.browser."],
            nameMarkers: ["arc"],
            usesSafariScript: false,
            usesChromiumScript: true,
            usesFirefoxAX: false,
            appleScriptAppName: "Arc"
        ),
        BrowserDescriptor(
            bundleIDs: ["com.chromium.chromium"],
            bundleIDPrefixes: ["org.chromium.chromium."],
            nameMarkers: ["chromium"],
            usesSafariScript: false,
            usesChromiumScript: true,
            usesFirefoxAX: false,
            appleScriptAppName: "Chromium"
        ),
        BrowserDescriptor(
            bundleIDs: [
                "org.mozilla.firefox",
                "org.mozilla.firefoxdeveloperedition",
                "org.mozilla.nightly",
                "io.gitlab.librewolf-community",
                "net.waterfox.waterfox",
                "org.torproject.torbrowser",
                "one.ablaze.floorp",
                "app.zen-browser.zen"
            ],
            bundleIDPrefixes: [],
            nameMarkers: ["firefox", "firefox developer", "nightly", "librewolf", "waterfox", "tor browser", "floorp", "zen browser"],
            usesSafariScript: false,
            usesChromiumScript: false,
            usesFirefoxAX: true,
            appleScriptAppName: nil
        ),
        BrowserDescriptor(
            bundleIDs: ["com.kagi.orion"],
            bundleIDPrefixes: ["com.kagi.orion."],
            nameMarkers: ["orion"],
            usesSafariScript: false,
            usesChromiumScript: false,
            usesFirefoxAX: false,
            appleScriptAppName: nil
        ),
        BrowserDescriptor(
            bundleIDs: ["com.duckduckgo.macos.browser"],
            bundleIDPrefixes: [],
            nameMarkers: ["duckduckgo"],
            usesSafariScript: false,
            usesChromiumScript: false,
            usesFirefoxAX: false,
            appleScriptAppName: nil
        ),
        BrowserDescriptor(
            bundleIDs: [
                "ru.yandex.desktop.yandex-browser",
                "com.pushplaylabs.sidekick",
                "com.wavebox.wavebox",
                "com.sigmaos.sigmaos"
            ],
            bundleIDPrefixes: [],
            nameMarkers: ["yandex", "sidekick", "wavebox", "sigmaos"],
            usesSafariScript: false,
            usesChromiumScript: true,
            usesFirefoxAX: false,
            appleScriptAppName: nil
        )
    ]

    nonisolated static var knownBrowserBundleIDs: Set<String> {
        Set(descriptors.flatMap(\.bundleIDs))
    }

    nonisolated static var knownBrowserBundleIDPrefixes: [String] {
        Array(Set(descriptors.flatMap(\.bundleIDPrefixes))).sorted()
    }

    nonisolated static func descriptor(appName: String, bundleID: String) -> BrowserDescriptor? {
        let normalizedBundleID = bundleID.lowercased()
        let normalizedName = appName.lowercased()

        if let exactBundleMatch = descriptors.first(where: { $0.bundleIDs.contains(normalizedBundleID) }) {
            return exactBundleMatch
        }
        if let prefixBundleMatch = descriptors.first(where: { descriptor in
            descriptor.bundleIDPrefixes.contains { normalizedBundleID.hasPrefix($0) }
        }) {
            return prefixBundleMatch
        }
        return descriptors.first {
            $0.nameMarkers.contains(where: { normalizedName.contains($0) })
        }
    }

    nonisolated static func isBrowser(appName: String = "", bundleID: String) -> Bool {
        descriptor(appName: appName, bundleID: bundleID) != nil
    }
}
