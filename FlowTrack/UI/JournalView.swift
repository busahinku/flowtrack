import SwiftUI
import AppKit
import CryptoKit

// MARK: - JournalView (router)
struct JournalView: View {
    @Bindable private var store = JournalStore.shared
    @Environment(Theme.self) private var theme

    var body: some View {
        Group {
            if !store.isPasswordSetUp {
                JournalSetupView()
            } else if !store.isUnlocked {
                JournalUnlockView()
            } else {
                JournalEditorView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.timelineBackgroundColor)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Setup View
// ─────────────────────────────────────────────────────────────────────────────
private struct JournalSetupView: View {
    @State private var password     = ""
    @State private var confirm      = ""
    @State private var errorMessage = ""
    @State private var isWorking    = false
    @Environment(Theme.self) private var theme

    private var strength: Int {
        var s = 0
        if password.count >= 8  { s += 1 }
        if password.count >= 12 { s += 1 }
        if password.contains(where: \.isNumber)    { s += 1 }
        if password.contains(where: \.isUppercase) { s += 1 }
        if password.contains(where: "!@#$%^&*()-_+=[]{}|;:,./<>?".contains) { s += 1 }
        return s
    }

    private var strengthInfo: (label: String, color: Color) {
        switch strength {
        case 0, 1: return ("Weak",   theme.errorColor)
        case 2:    return ("Fair",   theme.warningColor)
        case 3:    return ("Good",   theme.infoColor)
        default:   return ("Strong", theme.successColor)
        }
    }

    private var canCreate: Bool { password.count >= 6 && !isWorking }

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                Spacer(minLength: 20)

                // Icon + heading
                VStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(theme.accentColor.opacity(0.12))
                            .frame(width: 72, height: 72)
                        Image(systemName: "book.closed.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(theme.accentColor)
                    }
                    Text("Create Your Journal")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(theme.primaryTextColor)
                    Text("Your entries are encrypted with AES-256.\nOnly you can read them — even if the database is opened directly.")
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryTextColor)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }

                // Form card
                VStack(spacing: 0) {
                    fieldRow(label: "Password", icon: "lock.fill") {
                        SecureField("At least 6 characters", text: $password)
                            .textFieldStyle(.plain)
                            .onSubmit { if canCreate { createPassword() } }
                    }

                    if !password.isEmpty {
                        Divider().padding(.leading, 42)
                        strengthRow
                    }

                    Divider().padding(.leading, 42)

                    fieldRow(label: "Confirm", icon: "lock.rotation") {
                        SecureField("Repeat password", text: $confirm)
                            .textFieldStyle(.plain)
                            .onSubmit { if canCreate { createPassword() } }
                    }
                }
                .background(theme.cardBackgroundColor, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.dividerColor.opacity(0.08), lineWidth: 1)
                )
                .frame(maxWidth: 380)

                // Error
                if !errorMessage.isEmpty {
                    Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(theme.errorColor)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(theme.errorColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                // Create button
                Button { createPassword() } label: {
                    Group {
                        if isWorking {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.8)
                                Text("Securing…")
                            }
                        } else {
                            Label("Create Journal", systemImage: "checkmark.shield.fill")
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.selectedForegroundColor)
                    .frame(maxWidth: 320)
                    .padding(.vertical, 12)
                    .background(
                        canCreate ? theme.accentColor : theme.dividerColor.opacity(0.3),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canCreate)

                // Security note
                HStack(spacing: 5) {
                    Image(systemName: "lock.shield.fill").font(.caption).foregroundStyle(theme.successColor)
                    Text("AES-256-GCM · PBKDF2-SHA256 · Stored locally · Never transmitted")
                        .font(.caption2).foregroundStyle(theme.secondaryTextColor)
                }

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 40)
        }
    }

    @ViewBuilder
    private func fieldRow<Content: View>(label: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(theme.accentColor)
                .frame(width: 22)
                .padding(.leading, 14)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(theme.secondaryTextColor)
                .frame(width: 68, alignment: .leading)
            content()
                .frame(maxWidth: .infinity)
                .padding(.trailing, 14)
        }
        .frame(height: 44)
    }

    private var strengthRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryTextColor)
                .frame(width: 22)
                .padding(.leading, 14)
            Text("Strength")
                .font(.caption)
                .foregroundStyle(theme.secondaryTextColor)
                .frame(width: 68, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(0..<5) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(i < strength ? strengthInfo.color : theme.dividerColor.opacity(0.25))
                        .frame(height: 5)
                        .animation(.easeInOut(duration: 0.2), value: strength)
                }
            }
            Text(strengthInfo.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(strengthInfo.color)
                .frame(width: 46, alignment: .trailing)
                .padding(.trailing, 14)
        }
        .frame(height: 36)
    }

    private func createPassword() {
        guard !password.isEmpty else { errorMessage = "Please enter a password."; return }
        guard password.count >= 6 else { errorMessage = "Password must be at least 6 characters."; return }
        guard password == confirm else { errorMessage = "Passwords do not match."; return }
        isWorking = true; errorMessage = ""
        let pwd = password
        let mgr = JournalPasswordManager.shared
        Task.detached(priority: .userInitiated) {
            do {
                // PBKDF2 runs off main thread here
                let key = try mgr.setupAndDeriveKey(password: pwd)
                await MainActor.run {
                    JournalStore.shared.unlockWithKey(key)
                    isWorking = false
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Unlock View
// ─────────────────────────────────────────────────────────────────────────────
private struct JournalUnlockView: View {
    @State private var password     = ""
    @State private var errorMessage = ""
    @State private var isWorking    = false
    @State private var showReset    = false
    @FocusState private var focused: Bool
    @Environment(Theme.self) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 28) {
                // Icon
                ZStack {
                    Circle().fill(theme.accentColor.opacity(0.10)).frame(width: 64, height: 64)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(theme.accentColor)
                }

                VStack(spacing: 6) {
                    Text("Journal Locked")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(theme.primaryTextColor)
                    Text("Enter your password to continue")
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryTextColor)
                }

                // Password field
                VStack(spacing: 12) {
                    HStack {
                        SecureField("Password", text: $password)
                            .textFieldStyle(.roundedBorder)
                            .focused($focused)
                            .onSubmit { unlock() }
                        Button { unlock() } label: {
                            Image(systemName: isWorking ? "arrow.2.circlepath" : "arrow.right.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(password.isEmpty ? theme.dividerColor : theme.accentColor)
                                .rotationEffect(.degrees(isWorking ? 360 : 0))
                                .animation(isWorking ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: isWorking)
                        }
                        .buttonStyle(.plain)
                        .disabled(password.isEmpty || isWorking)
                    }
                    .frame(width: 300)

                    if !errorMessage.isEmpty {
                        Label(errorMessage, systemImage: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(theme.errorColor)
                    }
                }

                Button("Forgot password?") { showReset = true }
                    .font(.caption)
                    .foregroundStyle(theme.secondaryTextColor.opacity(0.7))
                    .buttonStyle(.plain)
            }
            Spacer()
        }
        .onAppear { focused = true }
        .sheet(isPresented: $showReset) {
            JournalResetSheet(isPresented: $showReset)
                .withEnvironment()
        }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        isWorking = true; errorMessage = ""
        let pwd = password
        let mgr = JournalPasswordManager.shared
        Task.detached(priority: .userInitiated) {
            do {
                let key = try mgr.verifyAndDeriveKey(password: pwd)
                await MainActor.run {
                    JournalStore.shared.unlockWithKey(key)
                    isWorking = false
                }
            } catch JournalPasswordError.wrongPassword {
                await MainActor.run { isWorking = false; errorMessage = "Incorrect password." }
            } catch {
                await MainActor.run { isWorking = false; errorMessage = error.localizedDescription }
            }
        }
        password = ""
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Password Reset Sheet
// ─────────────────────────────────────────────────────────────────────────────
struct JournalResetSheet: View {
    @Binding var isPresented: Bool
    @State private var step = 1
    @State private var confirmText = ""
    @Environment(Theme.self) private var theme

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(theme.errorColor)

            if step == 1 {
                VStack(spacing: 10) {
                    Text("Reset Journal Password")
                        .font(.title3.weight(.bold)).foregroundStyle(theme.primaryTextColor)
                    Text("This will **permanently delete all journal entries**.\nThis cannot be undone.")
                        .font(.subheadline).foregroundStyle(theme.secondaryTextColor)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 12) {
                    Button("Cancel") { isPresented = false }
                        .keyboardShortcut(.escape)
                    Button("I Understand") { step = 2 }
                        .foregroundStyle(theme.errorColor)
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 10) {
                    Text("Final Confirmation")
                        .font(.title3.weight(.bold)).foregroundStyle(theme.primaryTextColor)
                    Text("Type **DELETE** to permanently erase all journal entries and the password.")
                        .font(.subheadline).foregroundStyle(theme.secondaryTextColor)
                        .multilineTextAlignment(.center)
                }
                TextField("Type DELETE", text: $confirmText)
                    .textFieldStyle(.roundedBorder).frame(width: 200)
                HStack(spacing: 12) {
                    Button("Cancel") { isPresented = false }
                    Button("Delete Everything") {
                        JournalStore.shared.resetAll()
                        isPresented = false
                    }
                    .foregroundStyle(confirmText == "DELETE" ? theme.errorColor : theme.secondaryTextColor)
                    .disabled(confirmText != "DELETE")
                    .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(32)
        .frame(width: 400)
        .background(theme.cardBackgroundColor)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Editor View
// ─────────────────────────────────────────────────────────────────────────────
private struct JournalEditorView: View {
    @Bindable private var store = JournalStore.shared
    @Environment(Theme.self) private var theme

    @State private var currentDate: Date = .init()
    @State private var text: String = ""
    @State private var isPreview: Bool = false
    @State private var isSaving: Bool = false
    @State private var saveTask: Task<Void, Never>? = nil
    @State private var textViewRef: NSTextView? = nil

    private var dateKey: String { JournalStore.dateKey(for: currentDate) }
    private var isToday: Bool { Calendar.current.isDateInToday(currentDate) }
    private var canGoForward: Bool { !isToday }

    private var headerDateString: String {
        if isToday { return "Today" }
        if Calendar.current.isDateInYesterday(currentDate) { return "Yesterday" }
        let f = DateFormatter(); f.dateFormat = "MMMM d, yyyy"; return f.string(from: currentDate)
    }
    private var dayOfWeek: String {
        let f = DateFormatter(); f.dateFormat = "EEEE"; return f.string(from: currentDate)
    }
    private var wordCount: Int { text.split { $0.isWhitespace || $0.isNewline }.count }

    var body: some View {
        VStack(spacing: 0) {
            editorToolbar
            Divider()
            if isPreview {
                MarkdownPreviewView(text: text, theme: theme)
            } else {
                MarkdownEditorNSView(text: $text, theme: theme) { tv in
                    textViewRef = tv
                }
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Write something…")
                            .font(.system(size: 15, design: .serif))
                            .foregroundStyle(theme.secondaryTextColor.opacity(0.4))
                            .padding(.horizontal, 28)
                            .padding(.top, 20)
                            .allowsHitTesting(false)
                    }
                }
            }
            Divider()
            statusBar
        }
        .onAppear { loadEntry() }
        .onChange(of: currentDate) { _, _ in loadEntry() }
        .onChange(of: text) { _, _ in scheduleAutoSave() }
    }

    // MARK: - Toolbar

    private var editorToolbar: some View {
        VStack(spacing: 0) {
            // Top bar: navigation + mode toggle + lock
            HStack(spacing: 10) {
                navButton(icon: "chevron.left") { navigateDay(-1) }

                VStack(spacing: 1) {
                    Text(headerDateString)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(theme.primaryTextColor)
                    Text(dayOfWeek)
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryTextColor)
                }
                .frame(minWidth: 140)

                navButton(icon: "chevron.right") { navigateDay(1) }
                    .opacity(canGoForward ? 1 : 0.25)
                    .disabled(!canGoForward)

                Spacer()

                // Saving indicator
                if isSaving {
                    HStack(spacing: 4) {
                        ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                        Text("Saving…").font(.caption2).foregroundStyle(theme.secondaryTextColor)
                    }
                }

                // Past entries
                if !store.entryDates.isEmpty {
                    Menu {
                        ForEach(store.entryDates.prefix(30), id: \.self) { key in
                            Button(entryMenuLabel(key)) {
                                if let d = JournalStore.date(from: key) { currentDate = d }
                            }
                        }
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 13)).foregroundStyle(theme.secondaryTextColor)
                    }
                    .menuStyle(.borderlessButton).frame(width: 28)
                }

                // Preview toggle
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isPreview.toggle() }
                } label: {
                    Label(isPreview ? "Edit" : "Preview",
                          systemImage: isPreview ? "pencil" : "eye")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(isPreview ? theme.selectedForegroundColor : theme.secondaryTextColor)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(
                            isPreview ? theme.accentColor : theme.dividerColor.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                }
                .buttonStyle(.plain)

                // Lock
                Button { store.lock() } label: {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 13)).foregroundStyle(theme.secondaryTextColor)
                }
                .buttonStyle(.plain).help("Lock journal")
            }
            .padding(.horizontal, 16).padding(.vertical, 8)

            if !isPreview {
                Divider().opacity(0.4)
                // Markdown toolbar
                MarkdownToolbarView { action in
                    applyMarkdown(action)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
        .background(theme.cardBackgroundColor)
    }

    private func navButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.secondaryTextColor)
                .frame(width: 26, height: 26)
                .background(theme.dividerColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text("\(wordCount) words")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(theme.secondaryTextColor)
            Text("·")
                .foregroundStyle(theme.secondaryTextColor.opacity(0.4))
            Text("\(text.count) characters")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(theme.secondaryTextColor)
            Spacer()
            if store.entryDates.contains(dateKey) {
                Label("Encrypted", systemImage: "lock.shield.fill")
                    .font(.caption2)
                    .foregroundStyle(theme.successColor.opacity(0.8))
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 6)
        .background(theme.cardBackgroundColor)
    }

    // MARK: - Logic

    private func loadEntry() {
        saveTask?.cancel()
        text = store.load(date: dateKey) ?? ""
        isSaving = false
    }

    private func scheduleAutoSave() {
        isSaving = true
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            store.save(text: text, for: dateKey)
            await MainActor.run { isSaving = false }
        }
    }

    private func navigateDay(_ delta: Int) {
        if let d = Calendar.current.date(byAdding: .day, value: delta, to: currentDate) {
            currentDate = d
        }
    }

    private func entryMenuLabel(_ key: String) -> String {
        guard let d = JournalStore.date(from: key) else { return key }
        if Calendar.current.isDateInToday(d)     { return "Today · \(key)" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday · \(key)" }
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; return f.string(from: d)
    }

    // MARK: - Markdown formatting

    private func applyMarkdown(_ action: MarkdownAction) {
        guard let tv = textViewRef else { return }
        MarkdownFormatter.apply(action, to: tv)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Markdown Toolbar
// ─────────────────────────────────────────────────────────────────────────────
enum MarkdownAction: CaseIterable {
    case h1, h2, h3
    case bold, italic, strikethrough
    case inlineCode, codeBlock
    case quote, bulletList, numberedList
    case link, rule

    var icon: String {
        switch self {
        case .h1:          return "textformat.size.larger"
        case .h2:          return "textformat.size"
        case .h3:          return "textformat.size.smaller"
        case .bold:        return "bold"
        case .italic:      return "italic"
        case .strikethrough: return "strikethrough"
        case .inlineCode:  return "chevron.left.forwardslash.chevron.right"
        case .codeBlock:   return "doc.plaintext"
        case .quote:       return "quote.bubble"
        case .bulletList:  return "list.bullet"
        case .numberedList: return "list.number"
        case .link:        return "link"
        case .rule:        return "minus"
        }
    }

    var tooltip: String {
        switch self {
        case .h1:          return "Heading 1"
        case .h2:          return "Heading 2"
        case .h3:          return "Heading 3"
        case .bold:        return "Bold"
        case .italic:      return "Italic"
        case .strikethrough: return "Strikethrough"
        case .inlineCode:  return "Inline Code"
        case .codeBlock:   return "Code Block"
        case .quote:       return "Block Quote"
        case .bulletList:  return "Bullet List"
        case .numberedList: return "Numbered List"
        case .link:        return "Insert Link"
        case .rule:        return "Horizontal Rule"
        }
    }

    var label: String {
        switch self {
        case .h1: return "H1"; case .h2: return "H2"; case .h3: return "H3"
        default:  return tooltip
        }
    }

    var separator: Bool { self == .h1 || self == .bold || self == .inlineCode || self == .quote || self == .bulletList || self == .link }
}

private struct MarkdownToolbarView: View {
    @Environment(Theme.self) private var theme
    let onAction: (MarkdownAction) -> Void

    // Groups with dividers between them
    private let groups: [[MarkdownAction]] = [
        [.h1, .h2, .h3],
        [.bold, .italic, .strikethrough],
        [.inlineCode, .codeBlock],
        [.quote, .bulletList, .numberedList],
        [.link, .rule]
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(groups.indices, id: \.self) { gi in
                if gi > 0 {
                    Divider().frame(height: 18).padding(.horizontal, 5)
                }
                ForEach(groups[gi], id: \.self) { action in
                    toolbarButton(action)
                }
            }
            Spacer()
        }
    }

    private func toolbarButton(_ action: MarkdownAction) -> some View {
        Button { onAction(action) } label: {
            Group {
                if action == .h1 || action == .h2 || action == .h3 {
                    Text(action.label)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: action.icon)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 22, height: 22)
                }
            }
            .foregroundStyle(theme.secondaryTextColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(action.tooltip)
        .padding(.horizontal, 2)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Markdown Formatter
// ─────────────────────────────────────────────────────────────────────────────
enum MarkdownFormatter {
    static func apply(_ action: MarkdownAction, to tv: NSTextView) {
        let str = tv.string as NSString
        let sel = tv.selectedRange()
        let selected = str.substring(with: sel)
        let hasSelection = !selected.isEmpty

        switch action {
        // ── Inline wrappers ──
        case .bold:
            wrap(tv, sel: sel, selected: selected, open: "**", close: "**", placeholder: "bold text")
        case .italic:
            wrap(tv, sel: sel, selected: selected, open: "*", close: "*", placeholder: "italic text")
        case .strikethrough:
            wrap(tv, sel: sel, selected: selected, open: "~~", close: "~~", placeholder: "strikethrough")
        case .inlineCode:
            wrap(tv, sel: sel, selected: selected, open: "`", close: "`", placeholder: "code")
        case .link:
            if hasSelection {
                let replacement = "[\(selected)](url)"
                tv.insertText(replacement, replacementRange: sel)
                // Place cursor on "url"
                let urlRange = NSRange(location: sel.location + selected.count + 3, length: 3)
                tv.setSelectedRange(urlRange)
            } else {
                let replacement = "[link text](url)"
                tv.insertText(replacement, replacementRange: sel)
                tv.setSelectedRange(NSRange(location: sel.location + 1, length: 9))
            }

        // ── Block / Line-level ──
        case .h1:         applyLinePrefix("# ",  tv: tv)
        case .h2:         applyLinePrefix("## ", tv: tv)
        case .h3:         applyLinePrefix("### ", tv: tv)
        case .quote:      applyLinePrefix("> ",  tv: tv)
        case .bulletList: applyLinePrefix("- ",  tv: tv)
        case .numberedList: applyLinePrefix("1. ", tv: tv)

        case .codeBlock:
            let inner = hasSelection ? selected : "code here"
            let replacement = "```\n\(inner)\n```"
            tv.insertText(replacement, replacementRange: sel)
            if !hasSelection {
                tv.setSelectedRange(NSRange(location: sel.location + 4, length: 9))
            }

        case .rule:
            // Insert on its own line
            let lineRange = str.lineRange(for: NSRange(location: sel.location, length: 0))
            let lineText = str.substring(with: lineRange)
            let prefix = lineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n"
            let replacement = "\(prefix)\n---\n\n"
            tv.insertText(replacement, replacementRange: sel)
        }
    }

    private static func wrap(_ tv: NSTextView, sel: NSRange, selected: String, open: String, close: String, placeholder: String) {
        if !selected.isEmpty {
            // Toggle: if already wrapped, unwrap
            if selected.hasPrefix(open) && selected.hasSuffix(close) && selected.count > open.count + close.count {
                let inner = String(selected.dropFirst(open.count).dropLast(close.count))
                tv.insertText(inner, replacementRange: sel)
                tv.setSelectedRange(NSRange(location: sel.location, length: inner.count))
            } else {
                let replacement = "\(open)\(selected)\(close)"
                tv.insertText(replacement, replacementRange: sel)
                tv.setSelectedRange(NSRange(location: sel.location, length: replacement.count))
            }
        } else {
            let replacement = "\(open)\(placeholder)\(close)"
            tv.insertText(replacement, replacementRange: sel)
            // Select placeholder so user can type over it
            tv.setSelectedRange(NSRange(location: sel.location + open.count, length: placeholder.count))
        }
    }

    private static func applyLinePrefix(_ prefix: String, tv: NSTextView) {
        let str = tv.string as NSString
        let sel = tv.selectedRange()

        // Handle multi-line selection
        var lineStart = sel.location
        var lineEnd   = sel.location + sel.length
        // Expand to full lines
        str.getLineStart(&lineStart, end: &lineEnd, contentsEnd: nil, for: NSRange(location: sel.location, length: 0))
        var allLineEnd = lineEnd
        if sel.length > 0 {
            str.getLineStart(nil, end: &allLineEnd, contentsEnd: nil, for: NSRange(location: sel.location + sel.length - 1, length: 0))
        }
        let fullRange = NSRange(location: lineStart, length: allLineEnd - lineStart)
        let block = str.substring(with: fullRange)

        // Toggle prefix on each line
        let lines = block.components(separatedBy: "\n")
        let allHavePrefix = lines.filter { !$0.isEmpty }.allSatisfy { $0.hasPrefix(prefix) }
        let newLines = lines.map { line -> String in
            if line.isEmpty { return line }
            if allHavePrefix { return String(line.dropFirst(prefix.count)) }
            else { return prefix + line }
        }
        let replacement = newLines.joined(separator: "\n")
        tv.insertText(replacement, replacementRange: fullRange)
        tv.setSelectedRange(NSRange(location: fullRange.location, length: replacement.count))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - NSTextView Wrapper (Edit mode)
// ─────────────────────────────────────────────────────────────────────────────
private struct MarkdownEditorNSView: NSViewRepresentable {
    @Binding var text: String
    let theme: Theme
    let onReady: (NSTextView) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSTextView.scrollableTextView()
        guard let tv = sv.documentView as? NSTextView else { return sv }
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isEditable = true
        tv.isSelectable = true
        tv.isAutomaticQuoteSubstitutionEnabled  = false
        tv.isAutomaticDashSubstitutionEnabled   = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextCompletionEnabled     = false
        tv.isGrammarCheckingEnabled             = false
        tv.isContinuousSpellCheckingEnabled     = true
        tv.textContainerInset = NSSize(width: 8, height: 16)
        tv.font        = .systemFont(ofSize: 15)
        tv.textColor   = .labelColor
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        // Ensure vertical growth works inside scroll view
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        tv.string = text
        context.coordinator.lastText = text
        // Pass reference to parent for toolbar actions
        DispatchQueue.main.async { onReady(tv) }
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? NSTextView else { return }
        // Only update content if text changed from outside (not from user typing)
        if text != context.coordinator.lastText {
            let sel = tv.selectedRange()
            tv.string = text
            let safeLoc = min(sel.location, tv.string.count)
            tv.setSelectedRange(NSRange(location: safeLoc, length: 0))
            context.coordinator.lastText = text
        }
        // Keep text color in sync with theme (light/dark switch)
        tv.textColor = .labelColor
    }

    func makeCoordinator() -> Coordinator { Coordinator($text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var binding: Binding<String>
        var lastText = ""
        init(_ b: Binding<String>) { binding = b }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            lastText = tv.string
            binding.wrappedValue = tv.string
        }
        // Explicitly handle Return so SwiftUI focus system doesn't swallow it
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return true
            }
            return false
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - NSTextView Wrapper (Preview mode)
// ─────────────────────────────────────────────────────────────────────────────
private struct MarkdownPreviewView: NSViewRepresentable {
    let text: String
    let theme: Theme

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSTextView.scrollableTextView()
        guard let tv = sv.documentView as? NSTextView else { return sv }
        tv.isEditable = false
        tv.isSelectable = true
        tv.textContainerInset = NSSize(width: 8, height: 16)
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        updateContent(tv)
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? NSTextView else { return }
        updateContent(tv)
    }

    private func updateContent(_ tv: NSTextView) {
        let mutable = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        var inCodeBlock = false
        var codeBuffer: [String] = []

        func flushCode() {
            guard !codeBuffer.isEmpty else { return }
            let code = codeBuffer.joined(separator: "\n")
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor,
                .backgroundColor: NSColor.tertiarySystemFill
            ]
            let block = NSMutableAttributedString(string: "\n" + code + "\n", attributes: attrs)
            mutable.append(block)
            codeBuffer = []
        }

        for (i, line) in lines.enumerated() {
            let suffix = i < lines.count - 1 ? "\n" : ""
            let t = line.trimmingCharacters(in: .whitespaces)

            // Code fence toggle
            if t.hasPrefix("```") {
                if inCodeBlock { flushCode(); inCodeBlock = false }
                else { inCodeBlock = true }
                continue
            }
            if inCodeBlock { codeBuffer.append(line); continue }

            // Headings — match "# Text", "## Text", "### Text", and "#Text" (no space)
            if t.range(of: "^#{1,3}\\s*\\S", options: .regularExpression) != nil {
                let hashCount = min(t.prefix(while: { $0 == "#" }).count, 3)
                let headingText = t.replacingOccurrences(of: "^#{1,6}\\s*", with: "", options: .regularExpression)
                let size: CGFloat = hashCount == 1 ? 22 : hashCount == 2 ? 18 : 15
                mutable.append(headingAttr(headingText + suffix, size: size))
            } else if t == "---" || t == "***" || t == "___" {
                mutable.append(NSAttributedString(string: "────────────────────────\n",
                    attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.separatorColor]))
            } else {
                // Use AttributedString(markdown:) for inline bold/italic/code on regular lines
                let inline = line + suffix
                if let attr = try? AttributedString(markdown: inline,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)),
                   let ns = try? NSAttributedString(attr, including: \.appKit) {
                    let ms = NSMutableAttributedString(attributedString: ns)
                    let r = NSRange(location: 0, length: ms.length)
                    ms.addAttribute(.foregroundColor, value: NSColor.labelColor, range: r)
                    ms.enumerateAttribute(.font, in: r) { v, rr, _ in
                        if v == nil { ms.addAttribute(.font, value: NSFont.systemFont(ofSize: 14), range: rr) }
                    }
                    mutable.append(ms)
                } else {
                    mutable.append(NSAttributedString(string: inline,
                        attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor]))
                }
            }
        }
        if inCodeBlock { flushCode() }
        tv.textStorage?.setAttributedString(mutable)
    }

    private func headingAttr(_ s: String, size: CGFloat) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: NSColor.labelColor
        ])
    }
}
