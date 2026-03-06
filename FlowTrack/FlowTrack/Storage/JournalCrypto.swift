import Foundation
import CryptoKit
import CommonCrypto

// MARK: - JournalCrypto
/// All cryptographic operations for the Journal feature.
/// - Key derivation: PBKDF2-SHA256, 200 000 iterations → 32-byte AES key
/// - Encryption/Decryption: AES-GCM (authenticated)
enum JournalCrypto {

    // MARK: - Constants

    static let saltLength      = 32   // bytes
    static let pbkdf2Rounds    = 200_000
    static let keyLength       = 32   // AES-256

    // MARK: - Key Derivation

    /// Derive a 256-bit symmetric key from a password + random salt using PBKDF2-SHA256.
    static func deriveKey(password: String, salt: Data) -> SymmetricKey {
        var derivedKeyData = Data(repeating: 0, count: keyLength)
        let passwordData   = Data(password.utf8)
        let result: Int32  = derivedKeyData.withUnsafeMutableBytes { derivedPtr in
            passwordData.withUnsafeBytes { passPtr in
                salt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passPtr.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(pbkdf2Rounds),
                        derivedPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }
        precondition(result == kCCSuccess, "PBKDF2 failed: \(result)")
        return SymmetricKey(data: derivedKeyData)
    }

    /// Generate a cryptographically random salt.
    static func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: saltLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, saltLength, &bytes)
        precondition(status == errSecSuccess)
        return Data(bytes)
    }

    // MARK: - HMAC Verifier

    /// Produce a stable verifier from a key. Used to confirm a password re-derives the same key.
    static func verifier(for key: SymmetricKey) -> Data {
        let tag = "FlowTrackJournalV1"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(tag.utf8), using: key)
        return Data(mac)
    }

    /// Check whether a derived key matches the stored verifier.
    static func isKeyValid(_ key: SymmetricKey, verifier storedVerifier: Data) -> Bool {
        let computed = verifier(for: key)
        return computed == storedVerifier
    }

    // MARK: - Encryption

    /// Encrypt plaintext with AES-GCM.
    /// Returns `(ciphertext || 16-byte GCM tag, nonce)` as separate `Data` values.
    static func encrypt(text: String, using key: SymmetricKey) throws -> (ciphertext: Data, nonce: Data) {
        let plaintext  = Data(text.utf8)
        let nonce      = AES.GCM.Nonce()
        let sealed     = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        let blob       = sealed.ciphertext + sealed.tag  // 16-byte auth tag appended
        return (blob, Data(nonce))
    }

    // MARK: - Decryption

    /// Decrypt a blob produced by `encrypt(text:using:)`.
    static func decrypt(ciphertext: Data, nonce nonceData: Data, using key: SymmetricKey) throws -> String {
        guard ciphertext.count >= 16 else {
            throw JournalCryptoError.invalidCiphertext
        }
        let tag        = ciphertext.suffix(16)
        let cipher     = ciphertext.dropLast(16)
        let nonce      = try AES.GCM.Nonce(data: nonceData)
        let sealed     = try AES.GCM.SealedBox(nonce: nonce, ciphertext: cipher, tag: tag)
        let plainData  = try AES.GCM.open(sealed, using: key)
        guard let text = String(data: plainData, encoding: .utf8) else {
            throw JournalCryptoError.invalidUTF8
        }
        return text
    }
}

// MARK: - Errors
enum JournalCryptoError: LocalizedError {
    case invalidCiphertext
    case invalidUTF8
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .invalidCiphertext: return "Journal entry data is corrupted."
        case .invalidUTF8:       return "Journal entry contains invalid text encoding."
        case .decryptionFailed:  return "Failed to decrypt journal entry. Wrong password?"
        }
    }
}
