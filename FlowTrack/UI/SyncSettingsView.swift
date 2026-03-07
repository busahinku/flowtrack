import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - SyncSettingsView

struct SyncSettingsView: View {
    @Bindable private var settings = AppSettings.shared

    @State private var detectedLocations: [CloudFolderDetector.CloudLocation] = []
    @State private var isBackingUp  = false
    @State private var isRestoring  = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    private var theme: AppTheme { AppSettings.shared.appTheme }

    var body: some View {
        Form {
            cloudPickerSection
            if settings.syncProvider != .none, let location = activeLocation {
                backupSection(location: location)
                autoSyncSection
            }
            if let msg = statusMessage {
                Section {
                    Label(msg, systemImage: statusIsError ? "exclamationmark.triangle" : "checkmark.circle.fill")
                        .foregroundStyle(statusIsError ? theme.errorColor : theme.successColor)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { detectedLocations = CloudFolderDetector.detect() }
    }

    // MARK: Cloud Picker

    private var cloudPickerSection: some View {
        Section {
            Text("FlowTrack saves your entire database to a folder in your cloud storage. Install the app on another Mac, connect the same cloud account, and your data syncs automatically.")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)

            if detectedLocations.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.warningColor)
                    Text("No cloud storage detected. Install Google Drive, Dropbox, OneDrive, or use iCloud Drive on this Mac.")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
            } else {
                // Always show "Off" option
                providerRow(provider: .none, location: nil)
                // Show detected providers only
                ForEach(detectedLocations, id: \.rootURL) { loc in
                    providerRow(provider: loc.provider, location: loc)
                }
            }
        } header: {
            Text("Backup Destination")
        }
    }

    private func providerRow(provider: SyncProvider, location: CloudFolderDetector.CloudLocation?) -> some View {
        let isSelected = settings.syncProvider == provider
        return Button {
            settings.syncProvider = provider
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isSelected ? theme.accentColor : Color.secondary.opacity(0.12))
                        .frame(width: 34, height: 34)
                    Image(systemName: provider.icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isSelected ? .white : Color.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(theme.primaryText)
                    if let account = location?.accountName {
                        Text(account)
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                    } else if provider == .none {
                        Text("Backups disabled")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                    } else if let loc = location {
                        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
                        Text(loc.rootURL.path.replacingOccurrences(of: homePath, with: "~"))
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(theme.accentColor)
                        .fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Backup / Restore

    private func backupSection(location: CloudFolderDetector.CloudLocation) -> some View {
        let folder = CloudFolderDetector.backupFolder(for: location)
        let backups = folder.map { CloudFolderDetector.listBackups(in: $0) } ?? []

        return Section("Backup & Restore") {
            if let last = settings.lastSyncDate {
                Label(
                    "Last backup: \(last.formatted(date: .abbreviated, time: .shortened))",
                    systemImage: "clock"
                )
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
            }

            HStack {
                Button {
                    Task { await performBackup(to: location) }
                } label: {
                    if isBackingUp {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Backing up…") }
                    } else {
                        Label("Backup Now", systemImage: "arrow.up.circle")
                    }
                }
                .disabled(isBackingUp || isRestoring)

                Spacer()

                Button(role: .destructive) {
                    Task { await pickAndRestore(from: location) }
                } label: {
                    if isRestoring {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Restoring…") }
                    } else {
                        Label("Restore…", systemImage: "arrow.down.circle")
                    }
                }
                .disabled(isBackingUp || isRestoring)
            }

            if !backups.isEmpty {
                Divider()
                Text("Found in \(location.provider.displayName)")
                    .font(.caption.bold())
                    .foregroundStyle(theme.secondaryText)
                ForEach(backups.prefix(5), id: \.path) { fileURL in
                    HStack {
                        Image(systemName: "archivebox")
                            .font(.caption)
                            .foregroundStyle(theme.accentColor)
                        Text(fileURL.lastPathComponent)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        if let mod = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                            Text(mod.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(theme.secondaryText)
                        }
                        Button("Restore") {
                            Task { await doRestore(from: fileURL) }
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(isBackingUp || isRestoring)
                    }
                }
            }
        }
    }

    // MARK: Auto-sync

    private var autoSyncSection: some View {
        Section("Automatic Backup") {
            Toggle("Back up automatically", isOn: $settings.autoSyncEnabled)
            if settings.autoSyncEnabled {
                Picker("Frequency", selection: $settings.autoSyncIntervalDays) {
                    Text("Daily").tag(1)
                    Text("Every 3 days").tag(3)
                    Text("Weekly").tag(7)
                }
            }
        }
    }

    // MARK: - Helpers

    private var activeLocation: CloudFolderDetector.CloudLocation? {
        detectedLocations.first { $0.provider == settings.syncProvider }
    }

    private func performBackup(to location: CloudFolderDetector.CloudLocation) async {
        isBackingUp = true
        defer { isBackingUp = false }
        do {
            let backupURL = try await BackupManager.shared.createBackup()
            guard let folder = CloudFolderDetector.backupFolder(for: location) else {
                throw BackupError.restoreFailed("Could not access \(location.provider.displayName) folder")
            }
            let dest = folder.appendingPathComponent(backupURL.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: backupURL, to: dest)
            try? FileManager.default.removeItem(at: backupURL)
            settings.lastSyncDate = Date()
            showStatus("Backup saved to \(location.provider.displayName) ✓", isError: false)
        } catch {
            showStatus(error.localizedDescription, isError: true)
        }
    }

    private func pickAndRestore(from location: CloudFolderDetector.CloudLocation) async {
        let panel = NSOpenPanel()
        panel.title = "Select a FlowTrack Backup"
        panel.directoryURL = CloudFolderDetector.backupFolder(for: location)
        panel.allowedContentTypes = [UTType(filenameExtension: "flowtrackbak") ?? .data]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await doRestore(from: url)
    }

    @MainActor
    private func doRestore(from url: URL) async {
        let alert = NSAlert()
        alert.messageText = "Restore this backup?"
        alert.informativeText = "All current FlowTrack data will be replaced with the backup contents. The app will restart automatically.\n\nYour current data is saved as flowtrack.sqlite.prev just in case."
        alert.addButton(withTitle: "Restore & Restart")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isRestoring = true
        do {
            try await BackupManager.shared.restoreBackup(from: url)
            showStatus("Restore complete. Restarting…", isError: false)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            relaunchApp()
        } catch {
            isRestoring = false
            showStatus(error.localizedDescription, isError: true)
        }
    }

    private func showStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if statusMessage == message { statusMessage = nil }
        }
    }

    private func relaunchApp() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [Bundle.main.bundleURL.path]
        try? task.run()
        NSApp?.terminate(nil)
    }
}
