import Foundation

/// Detects locally-installed cloud storage services and returns their sync folder URLs.
/// No OAuth, no API keys — just reads the paths that cloud desktop apps create on disk.
struct CloudFolderDetector {

    struct CloudLocation {
        let provider: SyncProvider
        let rootURL: URL
        /// Account identifier extracted from folder name (e.g. email for Google Drive)
        let accountName: String?
    }

    static func detect() -> [CloudLocation] {
        var locations: [CloudLocation] = []
        let home = FileManager.default.homeDirectoryForCurrentUser

        // iCloud Drive — always check first
        let iCloudDocs = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: iCloudDocs.path) {
            locations.append(CloudLocation(provider: .iCloud, rootURL: iCloudDocs, accountName: nil))
        }

        // Google Drive desktop — macOS 12+ puts it in ~/Library/CloudStorage/
        let cloudStorage = home.appendingPathComponent("Library/CloudStorage")
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: cloudStorage.path) {
            for entry in entries where entry.hasPrefix("GoogleDrive-") {
                // entry is like "GoogleDrive-user@gmail.com"
                let email = String(entry.dropFirst("GoogleDrive-".count))
                let myDrive = cloudStorage.appendingPathComponent(entry).appendingPathComponent("My Drive")
                let root = FileManager.default.fileExists(atPath: myDrive.path)
                    ? myDrive
                    : cloudStorage.appendingPathComponent(entry)
                locations.append(CloudLocation(provider: .googleDrive, rootURL: root, accountName: email))
            }
        }

        // Dropbox — classic location
        let dropboxPaths = [
            home.appendingPathComponent("Dropbox"),
            home.appendingPathComponent("Dropbox (Personal)"),
            home.appendingPathComponent("Dropbox (Business)"),
        ]
        for path in dropboxPaths where FileManager.default.fileExists(atPath: path.path) {
            locations.append(CloudLocation(provider: .dropbox, rootURL: path, accountName: nil))
        }

        // OneDrive — various naming patterns
        let oneDrivePaths = try? FileManager.default.contentsOfDirectory(atPath: home.path)
        for name in oneDrivePaths ?? [] where name.hasPrefix("OneDrive") {
            let url = home.appendingPathComponent(name)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                let account = name == "OneDrive" ? nil : String(name.dropFirst("OneDrive - ".count))
                locations.append(CloudLocation(provider: .oneDrive, rootURL: url, accountName: account))
            }
        }

        return locations
    }

    /// Returns the FlowTrack backup subfolder for a given cloud location, creating it if needed.
    static func backupFolder(for location: CloudLocation) -> URL? {
        let folder = location.rootURL.appendingPathComponent("FlowTrack")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        } catch {
            return nil
        }
    }

    /// Lists .flowtrackbak files in the given folder, sorted newest first.
    static func listBackups(in folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: []
        )) ?? []
        return files
            .filter { $0.pathExtension == "flowtrackbak" }
            .sorted {
                let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return d1 > d2
            }
    }
}
