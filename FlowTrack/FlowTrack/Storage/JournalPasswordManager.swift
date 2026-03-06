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

    private let keychain: KeychainSwift
    private let lock = NSLock()
    private let saltKey     = "journal_salt_v2"
    private let verifierKey = "journal_verifier_v2"

    private init() {
        keychain = KeychainSwift(keyPrefix: "FlowTrackJournal_")
        keychain.synchronizable = false
    }

    // MARK: - State

    var isSetUp: Bool {
        lock.lock(); defer { lock.unlock() }
        return keychain.getData(saltKey) != nil && keychain.getData(verifierKey) != nil
    }

    // MARK: - Setup

    /// First-time password setup.
    /// Runs PBKDF2 synchronously — MUST be called from a background thread (Task.detached).
    /// Returns the derived `SymmetricKey` so the caller can immediately unlock without a second PBKDF2 round.
    func setupAndDeriveKey(password: String) throws -> SymmetricKey {
        lock.lock(); defer { lock.unlock() }
        // Allow re-setup after reset (isSetUp already cleared). Protect against concurrent calls.
        let salt     = JournalCrypto.randomSalt()
        let key      = JournalCrypto.deriveKey(password: password, salt: salt)
        let verifier = JournalCrypto.verifier(for: key)

        let saltOk = keychain.set(salt,     forKey: saltKey,     withAccess: .accessibleWhenUnlockedThisDeviceOnly)
        let verOk  = keychain.set(verifier, forKey: verifierKey, withAccess: .accessibleWhenUnlockedThisDeviceOnly)
        guard saltOk && verOk else {
            // Clean up on failure
            keychain.delete(saltKey)
            keychain.delete(verifierKey)
            pmLog.error("Keychain write failed (salt=\(saltOk) ver=\(verOk))")
            throw JournalPasswordError.keychainFailed
        }
        pmLog.info("Journal password set up successfully")
        return key
    }

    // MARK: - Verification

    /// Verify a password and return the derived key.
    /// Runs PBKDF2 synchronously — MUST be called from a background thread (Task.detached).
    func verifyAndDeriveKey(password: String) throws -> SymmetricKey {
        lock.lock()
        guard let salt     = keychain.getData(saltKey),
              let stored   = keychain.getData(verifierKey) else {
            lock.unlock()
            throw JournalPasswordError.notSetUp
        }
        lock.unlock()

        let key = JournalCrypto.deriveKey(password: password, salt: salt)
        guard JournalCrypto.isKeyValid(key, verifier: stored) else {
            throw JournalPasswordError.wrongPassword
        }
        return key
    }

    // MARK: - Reset

    func reset() {
        lock.lock(); defer { lock.unlock() }
        keychain.delete(saltKey)
        keychain.delete(verifierKey)
        pmLog.info("Journal password reset — Keychain cleared")
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
