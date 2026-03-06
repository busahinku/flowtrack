import Foundation
import AppKit
import CryptoKit
import GRDB
import OSLog

private let journalLog = Logger(subsystem: "com.flowtrack", category: "JournalStore")

private let _dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

// MARK: - JournalStore
@MainActor @Observable
final class JournalStore {
    static let shared = JournalStore()

    // MARK: - Observable State

    /// Whether a journal password has been set up. Observed by JournalView for routing.
    private(set) var isPasswordSetUp: Bool = false
    /// Whether the journal is currently unlocked (session key is in memory).
    private(set) var isUnlocked: Bool = false
    /// Dates that have journal entries (sorted descending, "YYYY-MM-DD").
    private(set) var entryDates: [String] = []

    /// In-memory session key only. Never written to disk or Keychain.
    private var sessionKey: SymmetricKey?

    // MARK: - Init

    private init() {
        isPasswordSetUp = JournalPasswordManager.shared.isSetUp
        // Auto-lock when app resigns active
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.lock() }
        }
        loadEntryDates()
    }

    // MARK: - Unlock (called from background task after PBKDF2)

    /// Accept a pre-derived session key (PBKDF2 must have run on a background thread).
    func unlockWithKey(_ key: SymmetricKey) {
        sessionKey = key
        isUnlocked = true
        isPasswordSetUp = true
        loadEntryDates()
    }

    func lock() {
        // Wipe key from memory
        sessionKey = nil
        isUnlocked = false
    }

    // MARK: - CRUD

    func save(text: String, for dateKey: String) {
        guard let key = sessionKey else { return }
        do {
            let (ciphertext, nonce) = try JournalCrypto.encrypt(text: text, using: key)
            let now = Date()
            try Database.shared.dbQueue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO journal_entries (date, ciphertext, nonce, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(date) DO UPDATE SET
                        ciphertext = excluded.ciphertext,
                        nonce      = excluded.nonce,
                        updatedAt  = excluded.updatedAt
                    """,
                    arguments: [dateKey, ciphertext, nonce, now, now]
                )
            }
            if !entryDates.contains(dateKey) {
                entryDates.append(dateKey)
                entryDates.sort(by: >)
            }
        } catch {
            journalLog.error("Save failed for \(dateKey): \(error.localizedDescription)")
        }
    }

    func load(date dateKey: String) -> String? {
        guard let key = sessionKey else { return nil }
        do {
            return try Database.shared.dbQueue.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT ciphertext, nonce FROM journal_entries WHERE date = ?",
                    arguments: [dateKey]
                ) else { return nil }
                let ciphertext: Data = row["ciphertext"]
                let nonce: Data      = row["nonce"]
                return try JournalCrypto.decrypt(ciphertext: ciphertext, nonce: nonce, using: key)
            }
        } catch {
            journalLog.error("Load failed for \(dateKey): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Reset (Forgot Password)

    func resetAll() {
        do {
            try Database.shared.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM journal_entries")
            }
        } catch {
            journalLog.error("Wipe failed: \(error.localizedDescription)")
        }
        JournalPasswordManager.shared.reset()
        lock()
        entryDates = []
        isPasswordSetUp = false
        journalLog.info("Journal reset — all entries deleted, password cleared")
    }

    // MARK: - Helpers

    private func loadEntryDates() {
        do {
            entryDates = try Database.shared.dbQueue.read { db in
                try String.fetchAll(db, sql: "SELECT date FROM journal_entries ORDER BY date DESC")
            }
        } catch {
            journalLog.error("Failed to load dates: \(error.localizedDescription)")
        }
    }

    static func dateKey(for date: Date = Date()) -> String {
        _dateFormatter.string(from: date)
    }

    static func date(from key: String) -> Date? {
        _dateFormatter.date(from: key)
    }
}
