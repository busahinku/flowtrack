import Foundation
import KeychainSwift
import OSLog

private let secureStoreLogger = Logger(subsystem: "com.flowtrack", category: "SecureStore")

// MARK: - SecureStore (Keychain-backed API key storage)
final class SecureStore: @unchecked Sendable {
    static let shared = SecureStore()

    private let keychain: KeychainSwift
    private let lock = NSLock()

    private init() {
        keychain = KeychainSwift(keyPrefix: "FlowTrack_")
        keychain.synchronizable = false
        migrateFromFileIfNeeded()
    }

    func save(key: String, for provider: String) {
        lock.lock()
        defer { lock.unlock() }
        keychain.set(key, forKey: provider)
        secureStoreLogger.debug("Saved API key for \(provider, privacy: .private)")
    }

    func loadKey(for provider: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return keychain.get(provider)
    }

    func hasKey(for provider: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let key = keychain.get(provider) else { return false }
        return !key.isEmpty
    }

    func deleteKey(for provider: String) {
        lock.lock()
        defer { lock.unlock() }
        keychain.delete(provider)
    }

    /// One-time migration: reads the old plaintext .apikeys file, moves keys to Keychain, then deletes the file.
    private func migrateFromFileIfNeeded() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let fileURL = appSupport.appendingPathComponent("FlowTrack/.apikeys")
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        for (provider, key) in dict where !key.isEmpty {
            keychain.set(key, forKey: provider)
        }
        try? FileManager.default.removeItem(at: fileURL)
        secureStoreLogger.info("Migrated API keys from plaintext file to Keychain")
    }
}
