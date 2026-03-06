import Foundation
import KeychainSwift
import OSLog

private let secureStoreLogger = Logger(subsystem: "com.flowtrack", category: "SecureStore")

// MARK: - SecureStore (Keychain-backed API key storage)
//
// All API keys are stored as a SINGLE Keychain item (JSON dict) so macOS only
// shows one "Allow access" prompt instead of one per provider.
final class SecureStore: @unchecked Sendable {
    static let shared = SecureStore()

    private let keychain: KeychainSwift
    private let lock = NSLock()
    /// Single Keychain item key that holds all provider keys as JSON.
    private let bundleKey = "AllAPIKeys_v1"
    /// In-memory cache — loaded once from Keychain, kept in sync on every write/delete.
    private var cache: [String: String] = [:]

    private init() {
        keychain = KeychainSwift(keyPrefix: "FlowTrack_")
        keychain.synchronizable = false
        loadCache()
        migrateFromFileIfNeeded()
    }

    // MARK: - Public API

    func save(key: String, for provider: String) {
        lock.lock(); defer { lock.unlock() }
        cache[provider] = key
        persistCache()
        secureStoreLogger.debug("Saved API key for \(provider, privacy: .private)")
    }

    func loadKey(for provider: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return cache[provider]
    }

    func hasKey(for provider: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !(cache[provider] ?? "").isEmpty
    }

    func deleteKey(for provider: String) {
        lock.lock(); defer { lock.unlock() }
        cache.removeValue(forKey: provider)
        persistCache()
    }

    // MARK: - Private helpers

    /// Load the single JSON bundle from Keychain into the in-memory cache.
    private func loadCache() {
        guard let raw = keychain.get(bundleKey),
              let data = raw.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        cache = dict
    }

    /// Write the current cache back to Keychain as a single JSON item.
    private func persistCache() {
        guard let data = try? JSONEncoder().encode(cache),
              let raw = String(data: data, encoding: .utf8) else { return }
        keychain.set(raw, forKey: bundleKey, withAccess: .accessibleWhenUnlockedThisDeviceOnly)
    }

    /// One-time migration: consolidate any pre-existing per-provider Keychain items
    /// and the legacy plaintext .apikeys file into the new single bundle item.
    private func migrateFromFileIfNeeded() {
        // 1. Migrate legacy per-provider Keychain items (old format used provider name as key)
        let legacyProviders = ["claude", "openai", "gemini", "ollama", "lmstudio", "claudecli", "chatgptcli"]
        var migrated = false
        for p in legacyProviders {
            if let v = keychain.get(p), !v.isEmpty {
                cache[p] = v
                keychain.delete(p)
                migrated = true
            }
        }

        // 2. Migrate legacy plaintext .apikeys file
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let fileURL = appSupport.appendingPathComponent("FlowTrack/.apikeys")
        if FileManager.default.fileExists(atPath: fileURL.path),
           let data = try? Data(contentsOf: fileURL),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            for (provider, key) in dict where !key.isEmpty {
                cache[provider] = key
            }
            try? FileManager.default.removeItem(at: fileURL)
            migrated = true
            secureStoreLogger.info("Migrated API keys from plaintext file to Keychain")
        }

        if migrated { persistCache() }
    }
}
