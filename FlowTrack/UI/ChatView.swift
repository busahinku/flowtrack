import SwiftUI
import Combine

// MARK: - ChatView

struct ChatView: View {
    @State private var engine = ChatEngine.shared
    @State private var inputText = ""
    @State private var showDatePicker = false
    @FocusState private var inputFocused: Bool

    // Streaming state
    @State private var streamingText: String = ""
    @State private var isStreaming = false

    private var theme: AppTheme { AppSettings.shared.appTheme }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if engine.messages.isEmpty && !isStreaming {
                    emptyState
                } else {
                    messageList
                }
            }
            Divider()
            inputBar
        }
        .background(theme.timelineBg)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .principal) {
                dateNavToolbar
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if !engine.messages.isEmpty || isStreaming {
                    Button {
                        engine.clearMessages()
                        streamingText = ""
                        isStreaming = false
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.secondary)
                    }
                    .help("Clear conversation")
                }
            }
        }
    }

    // MARK: - Toolbar date nav

    private var dateNavToolbar: some View {
        HStack(spacing: 2) {
            Button {
                engine.contextDate = Calendar.current.date(byAdding: .day, value: -1, to: engine.contextDate) ?? engine.contextDate
                engine.clearMessages()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button { showDatePicker.toggle() } label: {
                Text(dateLabel)
                    .font(.headline)
                    .frame(minWidth: 90)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDatePicker) {
                DatePicker("", selection: Binding(
                    get: { engine.contextDate },
                    set: { newDate in
                        engine.contextDate = newDate
                        engine.clearMessages()
                        streamingText = ""
                    }
                ), displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.graphical)
                    .padding(8)
                    .frame(width: 300, height: 320)
            }

            Button {
                engine.contextDate = Calendar.current.date(byAdding: .day, value: 1, to: engine.contextDate) ?? engine.contextDate
                engine.clearMessages()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 24)
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(theme.accentColor.opacity(0.12))
                            .frame(width: 60, height: 60)
                        Image(systemName: "sparkles")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(theme.accentColor)
                    }
                    Text("FlowTrack AI")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Ask me anything about \(dateLabelFull)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(ChatEngine.suggestions, id: \.label) { s in
                        SuggestionChip(label: s.label, icon: s.icon) {
                            send(s.prompt)
                        }
                    }
                }
                .padding(.horizontal, 16)

                Spacer(minLength: 16)
            }
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(engine.messages) { msg in
                        MessageBubble(message: msg)
                            .id(msg.id)
                    }
                    // Streaming / thinking row
                    if isStreaming || engine.isThinking {
                        if isStreaming && !streamingText.isEmpty {
                            StreamingBubble(text: streamingText)
                                .id("streaming")
                        } else {
                            ThinkingIndicator()
                                .id("thinking")
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
            }
            .onChange(of: engine.messages.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: streamingText) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("streaming", anchor: .bottom)
                }
            }
            .onChange(of: engine.isThinking) { _, thinking in
                if thinking {
                    withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
                }
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if let last = engine.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            if !engine.messages.isEmpty && !engine.isThinking && !isStreaming {
                quickChips
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask about your day…", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .onSubmit { sendIfValid() }
                    .padding(.vertical, 9)
                    .padding(.horizontal, 13)
                    .background(theme.dividerColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))

                Button {
                    sendIfValid()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(canSend ? theme.accentColor : Color.secondary.opacity(0.35))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var quickChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(ChatEngine.suggestions.prefix(5), id: \.label) { s in
                    Button { send(s.prompt) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: s.icon).font(.system(size: 10))
                            Text(s.label).font(.system(size: 11))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.quaternary, in: Capsule())                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Send

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !engine.isThinking && !isStreaming
    }

    private func sendIfValid() {
        guard canSend else { return }
        send(inputText)
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        inputText = ""
        Task { await sendAndStream(trimmed) }
    }

    private func sendAndStream(_ text: String) async {
        // Append user message immediately
        let userMsg = ChatMessage(role: .user, content: text)
        engine.messages.append(userMsg)
        engine.isThinking = true
        streamingText = ""
        isStreaming = false

        do {
            let reply = try await engine.fetchReply(for: text)
            engine.isThinking = false
            // Animate the reply streaming in
            await streamIn(reply)
        } catch {
            engine.isThinking = false
            isStreaming = false
            streamingText = ""
            engine.messages.append(ChatMessage(role: .error, content: error.localizedDescription))
        }
    }

    /// Animates text appearing character-by-character, then commits to messages.
    private func streamIn(_ fullText: String) async {
        guard !fullText.isEmpty else { return }
        isStreaming = true
        streamingText = ""

        let chars = Array(fullText)
        let total = chars.count
        // Aim for ~1.5s total, but floor at 2 chars/tick and cap tick delay at 16ms
        let tickChars = max(2, total / 90)   // 90 ticks × tickChars ≈ total
        let tickMs: UInt64 = 16_000_000      // 16ms ≈ 60fps

        var idx = 0
        while idx < total {
            let end = min(idx + tickChars, total)
            streamingText = String(chars[0..<end])
            idx = end
            try? await Task.sleep(nanoseconds: tickMs)
        }

        // Commit final message and clear streaming state
        engine.messages.append(ChatMessage(role: .assistant, content: fullText))
        streamingText = ""
        isStreaming = false
    }

    // MARK: - Date Helpers

    private var dateLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(engine.contextDate) { return "Today" }
        if cal.isDateInYesterday(engine.contextDate) { return "Yesterday" }
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return f.string(from: engine.contextDate)
    }

    private var dateLabelFull: String {
        let cal = Calendar.current
        if cal.isDateInToday(engine.contextDate) { return "today" }
        if cal.isDateInYesterday(engine.contextDate) { return "yesterday" }
        let f = DateFormatter(); f.dateStyle = .long
        return f.string(from: engine.contextDate)
    }
}

// MARK: - MessageBubble

private struct MessageBubble: View {
    let message: ChatMessage
    @State private var isHovered = false
    private var theme: AppTheme { AppSettings.shared.appTheme }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 52) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 3) {
                bubbleContent
                    .textSelection(.enabled)
                Text(timeString)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
            if message.role != .user { Spacer(minLength: 52) }
        }
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        switch message.role {
        case .user:
            Text(message.content)
                .font(.system(size: 13))
                .foregroundStyle(theme.selectedForeground)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(theme.accentColor, in: RoundedRectangle(cornerRadius: 16))

        case .assistant:
            ZStack(alignment: .topTrailing) {
                MarkdownBubble(text: message.content)
                if isHovered {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.content, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .padding(5)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .offset(x: -6, y: 6)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .contextMenu {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.content, forType: .string)
                }
            }

        case .error:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.warningColor)
                Text(message.content)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(theme.warningColor.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.warningColor.opacity(0.2)))
            )
        }
    }

    private var timeString: String {
        let f = DateFormatter(); f.timeStyle = .short
        return f.string(from: message.timestamp)
    }
}

// MARK: - StreamingBubble (same look as assistant, shown during animation)

private struct StreamingBubble: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            MarkdownBubble(text: text, showCursor: true)
            Spacer(minLength: 52)
        }
    }
}

// MARK: - MarkdownBubble

private struct MarkdownBubble: View {
    let text: String
    var showCursor: Bool = false
    private var theme: AppTheme { AppSettings.shared.appTheme }

    var body: some View {
        MarkdownRenderer(text: text, showCursor: showCursor)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(theme.dividerColor.opacity(0.07), lineWidth: 1)
                    )
            )
    }
}

// MARK: - MarkdownRenderer

private struct MarkdownRenderer: View {
    let text: String
    var showCursor: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func renderBlock(_ block: MDBlock) -> some View {
        switch block {
        case .heading(let text, let level):
            inlineText(text, bold: true)
                .font(level == 1 ? .system(size: 16, weight: .bold) :
                      level == 2 ? .system(size: 14, weight: .semibold) :
                                   .system(size: 13, weight: .medium))
                .padding(.top, level == 1 ? 6 : 3)

        case .bullet(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .top, spacing: 7) {
                        Text("•")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 10)
                            .padding(.top, 1)
                        inlineText(item)
                            .font(.system(size: 13))
                    }
                }
            }

        case .paragraph(let text):
            let displayText = showCursor && block == blocks.last ? text + "▌" : text
            inlineText(displayText)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)

        case .numbered(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .top, spacing: 7) {
                        Text("\(i + 1).")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 18, alignment: .trailing)
                        inlineText(item)
                            .font(.system(size: 13))
                    }
                }
            }

        case .divider:
            Divider().opacity(0.5)

        case .codeBlock(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    // Inline markdown rendering via Apple's AttributedString parser (handles bold/italic/code/links correctly)
    private func inlineText(_ raw: String, bold: Bool = false) -> Text {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attr = try? AttributedString(markdown: raw, options: opts) {
            return bold ? Text(attr).bold() : Text(attr)
        }
        return bold ? Text(raw).bold() : Text(raw)
    }

    // MARK: Parse into blocks
    private var blocks: [MDBlock] {
        let lines = text.components(separatedBy: "\n")
        var result: [MDBlock] = []
        var bulletBuffer: [String] = []
        var numberedBuffer: [String] = []
        var paragraphBuffer: [String] = []
        var inCodeBlock = false
        var codeBuffer: [String] = []

        func flushBullets() {
            if !bulletBuffer.isEmpty { result.append(.bullet(bulletBuffer)); bulletBuffer = [] }
        }
        func flushNumbered() {
            if !numberedBuffer.isEmpty { result.append(.numbered(numberedBuffer)); numberedBuffer = [] }
        }
        func flushParagraph() {
            let joined = paragraphBuffer.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { result.append(.paragraph(joined)) }
            paragraphBuffer = []
        }
        func flushCode() {
            if !codeBuffer.isEmpty { result.append(.codeBlock(codeBuffer.joined(separator: "\n"))); codeBuffer = [] }
        }

        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)

            // Code fence toggle
            if t.hasPrefix("```") {
                if inCodeBlock {
                    flushCode()
                    inCodeBlock = false
                } else {
                    flushBullets(); flushNumbered(); flushParagraph()
                    inCodeBlock = true
                }
                continue
            }
            if inCodeBlock { codeBuffer.append(line); continue }

            // Headings: support both "# Text" and "#Text" (no space)
            if t.range(of: "^#{1,3}\\s*\\S", options: .regularExpression) != nil {
                flushBullets(); flushNumbered(); flushParagraph()
                let hashCount = t.prefix(while: { $0 == "#" }).count
                let level = min(hashCount, 3)
                let heading = t.replacingOccurrences(of: "^#{1,6}\\s*", with: "", options: .regularExpression)
                result.append(.heading(heading, level))
            } else if t.hasPrefix("- ") || t.hasPrefix("• ") || t.hasPrefix("* ") {
                flushNumbered(); flushParagraph()
                bulletBuffer.append(String(t.dropFirst(2)))
            } else if let match = t.range(of: "^\\d+\\.\\s+", options: .regularExpression) {
                flushBullets(); flushParagraph()
                numberedBuffer.append(String(t[match.upperBound...]))
            } else if t == "---" || t == "***" || t == "___" {
                flushBullets(); flushNumbered(); flushParagraph()
                result.append(.divider)
            } else if t.isEmpty {
                flushBullets(); flushNumbered(); flushParagraph()
            } else {
                flushBullets(); flushNumbered()
                paragraphBuffer.append(t)
            }
        }
        flushBullets(); flushNumbered(); flushParagraph(); flushCode()
        return result
    }
}

private enum MDBlock: Equatable {
    case heading(String, Int)
    case bullet([String])
    case numbered([String])
    case paragraph(String)
    case divider
    case codeBlock(String)
}

// MARK: - ThinkingIndicator

private struct ThinkingIndicator: View {
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()
    private var theme: AppTheme { AppSettings.shared.appTheme }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(theme.secondaryText.opacity(phase == i ? 0.85 : 0.25))
                        .frame(width: 6, height: 6)
                        .scaleEffect(phase == i ? 1.25 : 1.0)
                        .animation(.easeInOut(duration: 0.35), value: phase)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.dividerColor.opacity(0.07)))
            )
            Spacer()
        }
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
    }
}

// MARK: - SuggestionChip

private struct SuggestionChip: View {
    let label: String
    let icon: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(AppSettings.shared.appTheme.accentColor)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovered ? AppSettings.shared.appTheme.dividerColor.opacity(0.06) : AppSettings.shared.appTheme.dividerColor.opacity(0.03))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppSettings.shared.appTheme.dividerColor.opacity(0.08)))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
