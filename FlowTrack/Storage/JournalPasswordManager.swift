import Foundation
import KeychainSwift
import CryptoKit
import OSLog

private let pmLog = Logger(subsystem: "com.flowtrack", category: "JournalPasswordManager")

// MARK: - JournalPasswordManager
/// Manages Journal password lifecycle: setup, verification, and reset.
///
/// Security properties:
///   - Raw password and derived key are NEVER persisted to disk or Keychain.
///   - Keychain stores only: random 32-byte salt + HMAC-SHA256 verifier.
///   - All Keychain items are `.thisDeviceOnly` — no iCloud sync, no device transfer.
///   - Thread-safe via NSLock.
final class JournalPasswordManager {
    static let shared = JournalPasswordManager()

    nonisolated(unsafe) private let keychain: KeychainSwift
    private let lock = NSLock()
    /// Single Keychain item holding both salt + verifier as a 64-byte blob (32+32).
    private let credsKey = "journal_creds_v3"

    private init() {
        keychain = KeychainSwift(keyPrefix: "FlowTrackJournal_")
        keychain.synchronizable = false
        migrateV2IfNeeded()
    }

    // MARK: - State

    nonisolated var isSetUp: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let blob = keychain.getData(credsKey) else { return false }
        return blob.count == 64
    }

    // MARK: - Setup

    /// First-time password setup.
    /// Runs PBKDF2 synchronously — MUST be called from a background thread (Task.detached).
    /// Returns the derived `SymmetricKey` so the caller can immediately unlock without a second PBKDF2 round.
    nonisolated func setupAndDeriveKey(password: String) throws -> SymmetricKey {
        lock.lock(); defer { lock.unlock() }
        let salt     = try JournalCrypto.randomSalt()
        let key      = try JournalCrypto.deriveKey(password: password, salt: salt)
        let verifier = JournalCrypto.verifier(for: key)
        // Store salt(32) + verifier(32) as a single 64-byte Keychain item → one prompt instead of two
        var blob = Data()
        blob.append(salt)
        blob.append(verifier)
        guard keychain.set(blob, forKey: credsKey, withAccess: .accessibleWhenUnlockedThisDeviceOnly) else {
            Logger(subsystem: "com.flowtrack", category: "JournalPasswordManager").error("Keychain write failed for journal credentials")
            throw JournalPasswordError.keychainFailed
        }
        Logger(subsystem: "com.flowtrack", category: "JournalPasswordManager").info("Journal password set up successfully")
        return key
    }

    // MARK: - Verification

    /// Verify a password and return the derived key.
    /// Runs PBKDF2 synchronously — MUST be called from a background thread (Task.detached).
    nonisolated func verifyAndDeriveKey(password: String) throws -> SymmetricKey {
        lock.lock()
        guard let blob = keychain.getData(credsKey), blob.count == 64 else {
            lock.unlock()
            throw JournalPasswordError.notSetUp
        }
        let salt   = Data(blob.prefix(32))
        let stored = Data(blob.suffix(32))
        lock.unlock()

        let key = try JournalCrypto.deriveKey(password: password, salt: salt)
        guard JournalCrypto.isKeyValid(key, verifier: stored) else {
            throw JournalPasswordError.wrongPassword
        }
        return key
    }

    // MARK: - Reset

    func reset() {
        lock.lock(); defer { lock.unlock() }
        keychain.delete(credsKey)
        pmLog.info("Journal password reset — Keychain cleared")
    }

    // MARK: - Migration from v2 (two separate items → one blob)

    private func migrateV2IfNeeded() {
        let oldSaltKey = "journal_salt_v2"
        let oldVerKey  = "journal_verifier_v2"
        guard keychain.getData(credsKey) == nil,
              let salt = keychain.getData(oldSaltKey),
              let ver  = keychain.getData(oldVerKey),
              salt.count == 32, ver.count == 32 else { return }
        var blob = Data(); blob.append(salt); blob.append(ver)
        if keychain.set(blob, forKey: credsKey, withAccess: .accessibleWhenUnlockedThisDeviceOnly) {
            keychain.delete(oldSaltKey)
            keychain.delete(oldVerKey)
            pmLog.info("Migrated journal credentials from v2 (2 items) to v3 (1 item)")
        }
    }
}

// MARK: - Errors
enum JournalPasswordError: LocalizedError {
    case alreadySetUp
    case notSetUp
    case wrongPassword
    case keychainFailed

    var errorDescription: String? {
        switch self {
        case .alreadySetUp:   return "A journal password is already configured."
        case .notSetUp:       return "No journal password has been set up."
        case .wrongPassword:  return "Incorrect password. Please try again."
        case .keychainFailed: return "Failed to save password securely. Check Keychain permissions."
        }
    }
}
