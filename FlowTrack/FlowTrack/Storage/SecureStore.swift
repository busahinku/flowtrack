import Foundation

// MARK: - SecureStore (file-based API key storage)
final class SecureStore: @unchecked Sendable {
    static let shared = SecureStore()

    private var cache: [String: String] = [:]
    private let lock = NSLock()
    private let fileURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("FlowTrack")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.fileURL = folder.appendingPathComponent(".apikeys")
        loadFromDisk()
    }

    func save(key: String, for provider: String) {
        lock.lock()
        defer { lock.unlock() }
        cache[provider] = key
        saveToDisk()
        print("[SecureStore] Saved API key for \(provider)")
    }

    func loadKey(for provider: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cache[provider]
    }

    func hasKey(for provider: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cache[provider] != nil && !cache[provider]!.isEmpty
    }

    func deleteKey(for provider: String) {
        lock.lock()
        defer { lock.unlock() }
        cache.removeValue(forKey: provider)
        saveToDisk()
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        cache = dict
    }

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: fileURL, options: .atomic)
        // Set file permissions to owner-only
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
