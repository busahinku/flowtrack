import Foundation
import GRDB
import os.log

private nonisolated let backupLog = Logger(subsystem: "com.flowtrack.app", category: "BackupManager")

// MARK: - BackupInfo

struct BackupInfo: Codable {
    let appVersion: String
    let schemaVersion: Int
    let deviceName: String
    let createdAt: Date
    let fileCount: Int

    static var current: BackupInfo {
        BackupInfo(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            schemaVersion: 8,
            deviceName: Host.current().localizedName ?? "Mac",
            createdAt: Date(),
            fileCount: 2  // sqlite + categories.json
        )
    }
}

// MARK: - BackupError

enum BackupError: LocalizedError {
    case databaseNotFound
    case invalidBackupFile
    case missingRequiredFile(String)
    case zipFailed(Int32)
    case unzipFailed(Int32)
    case restoreFailed(String)

    var errorDescription: String? {
        switch self {
        case .databaseNotFound:            return "FlowTrack database file not found."
        case .invalidBackupFile:           return "The selected file is not a valid FlowTrack backup."
        case .missingRequiredFile(let f):  return "Backup is missing required file: \(f)"
        case .zipFailed(let c):            return "Failed to create backup archive (exit code \(c))."
        case .unzipFailed(let c):          return "Failed to extract backup archive (exit code \(c))."
        case .restoreFailed(let msg):      return "Restore failed: \(msg)"
        }
    }
}

// MARK: - BackupManager

@MainActor
final class BackupManager {
    static let shared = BackupManager()
    private init() {}

    private var appSupportFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("FlowTrack")
    }
    private var dbURL: URL { appSupportFolder.appendingPathComponent("flowtrack.sqlite") }
    private var categoriesURL: URL { appSupportFolder.appendingPathComponent("categories.json") }

    // MARK: - Create Backup

    /// Creates a .flowtrackbak ZIP archive in a temp directory and returns its URL.
    func createBackup() async throws -> URL {
        backupLog.info("Creating backup...")

        // 1. Checkpoint WAL to consolidate all data into the main SQLite file
        try await checkpointWAL()

        // 2. Stage files into a temp directory
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowTrackBackup_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw BackupError.databaseNotFound
        }
        try FileManager.default.copyItem(at: dbURL, to: tempDir.appendingPathComponent("flowtrack.sqlite"))

        if FileManager.default.fileExists(atPath: categoriesURL.path) {
            try FileManager.default.copyItem(at: categoriesURL, to: tempDir.appendingPathComponent("categories.json"))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        let metaData = try encoder.encode(BackupInfo.current)
        try metaData.write(to: tempDir.appendingPathComponent("backup_info.json"))

        // 3. Zip the temp directory
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        let fileName = "FlowTrack_backup_\(dateFmt.string(from: Date())).flowtrackbak"
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: outputURL)

        let exitCode = await zip(sourceDir: tempDir, outputFile: outputURL)
        guard exitCode == 0 else { throw BackupError.zipFailed(exitCode) }

        backupLog.info("Backup created at \(outputURL.path, privacy: .public)")
        return outputURL
    }

    // MARK: - Restore Backup

    /// Restores a .flowtrackbak backup, replacing the current database and categories.
    /// The caller is responsible for restarting Database / CategoryManager after this returns.
    func restoreBackup(from url: URL) async throws {
        backupLog.info("Restoring backup from \(url.lastPathComponent, privacy: .public)")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlowTrackRestore_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Unzip
        let exitCode = await unzip(zipFile: url, toDir: tempDir)
        guard exitCode == 0 else { throw BackupError.unzipFailed(exitCode) }

        // Validate
        let restoredDB = tempDir.appendingPathComponent("flowtrack.sqlite")
        guard FileManager.default.fileExists(atPath: restoredDB.path) else {
            throw BackupError.missingRequiredFile("flowtrack.sqlite")
        }
        guard isValidSQLite(at: restoredDB) else {
            throw BackupError.invalidBackupFile
        }

        // Replace DB
        let fm = FileManager.default
        if fm.fileExists(atPath: dbURL.path) {
            // Keep a rolling backup of current DB just in case
            let prevBackup = appSupportFolder.appendingPathComponent("flowtrack.sqlite.prev")
            try? fm.removeItem(at: prevBackup)
            try? fm.copyItem(at: dbURL, to: prevBackup)
            try fm.removeItem(at: dbURL)
        }
        try fm.copyItem(at: restoredDB, to: dbURL)

        // Replace categories if present
        let restoredCats = tempDir.appendingPathComponent("categories.json")
        if fm.fileExists(atPath: restoredCats.path) {
            try? fm.removeItem(at: categoriesURL)
            try fm.copyItem(at: restoredCats, to: categoriesURL)
        }

        backupLog.info("Restore complete. App restart required.")
    }

    // MARK: - Helpers

    private func checkpointWAL() async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try Database.shared.dbQueue.inDatabase { db in
                        try db.execute(sql: "PRAGMA wal_checkpoint(FULL)")
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func zip(sourceDir: URL, outputFile: URL) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                process.arguments = ["-r", "-j", outputFile.path, sourceDir.path]
                process.launch()
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus)
            }
        }
    }

    private func unzip(zipFile: URL, toDir: URL) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                process.arguments = ["-o", zipFile.path, "-d", toDir.path]
                process.launch()
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus)
            }
        }
    }

    /// Quick SQLite validity check: verify the 16-byte magic header.
    private func isValidSQLite(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        let header = handle.readData(ofLength: 16)
        try? handle.close()
        let magic = "SQLite format 3\0".data(using: .utf8)!
        return header.prefix(magic.count) == magic
    }
}
