import SwiftUI
import Combine

// MARK: - ChatView

struct ChatView: View {
    @State private var engine = ChatEngine.shared
    @State private var inputText = ""
    @State private var showDatePicker = false
    @FocusState private var inputFocused: Bool
    @State private var scrollProxy: ScrollViewProxy?

    private var theme: AppTheme { AppSettings.shared.appTheme }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            ZStack {
                if engine.messages.isEmpty {
                    emptyState
                } else {
                    messageList
                }
            }
            Divider()
            inputBar
        }
        .background(Color(NSColor.windowBackgroundColor))
        .sheet(isPresented: $showDatePicker) { datePicker }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.accentColor)

            Text("FlowTrack AI")
                .font(.system(size: 14, weight: .semibold))

            Spacer()

            // Date selector button
            Button {
                showDatePicker = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .font(.system(size: 11))
                    Text(dateLabel)
                        .font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.quaternary, in: Capsule())
            }
            .buttonStyle(.plain)

            if !engine.messages.isEmpty {
                Button {
                    engine.clearMessages()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear conversation")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Empty State (suggestions)

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 20)
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(theme.accentColor.opacity(0.12))
                            .frame(width: 56, height: 56)
                        Image(systemName: "sparkles")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(theme.accentColor)
                    }
                    Text("Ask me anything about your day")
                        .font(.system(size: 14, weight: .semibold))
                    Text(dateLabelFull)
                        .font(.caption)
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

                Spacer(minLength: 20)
            }
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(engine.messages) { msg in
                        MessageBubble(message: msg)
                            .id(msg.id)
                    }
                    if engine.isThinking {
                        ThinkingIndicator()
                            .id("thinking")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onAppear { scrollProxy = proxy }
            .onChange(of: engine.messages.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: engine.isThinking) { _, thinking in
                if thinking { scrollToBottom(proxy: proxy, anchor: "thinking") }
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, anchor: String? = nil) {
        withAnimation(.easeOut(duration: 0.25)) {
            if let a = anchor {
                proxy.scrollTo(a, anchor: .bottom)
            } else if let last = engine.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            // Suggestion chips when messages exist
            if !engine.messages.isEmpty && !engine.isThinking {
                quickChips
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask about your day…", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .onSubmit { sendIfValid() }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.quaternary)
                    )

                Button {
                    sendIfValid()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(canSend ? theme.accentColor : Color.secondary.opacity(0.4))
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
            HStack(spacing: 8) {
                ForEach(ChatEngine.suggestions.prefix(5), id: \.label) { s in
                    Button {
                        send(s.prompt)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: s.icon)
                                .font(.system(size: 10))
                            Text(s.label)
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Date Picker Sheet

    private var datePicker: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Select Date")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Done") { showDatePicker = false }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.accentColor)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            DatePicker("", selection: $engine.contextDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding(.horizontal, 12)
                .onChange(of: engine.contextDate) { _, _ in
                    engine.clearMessages()
                }
            Spacer()
        }
        .frame(width: 320, height: 380)
    }

    // MARK: - Helpers

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !engine.isThinking
    }

    private func sendIfValid() {
        guard canSend else { return }
        send(inputText)
    }

    private func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        inputText = ""
        Task { await engine.send(t) }
    }

    private var dateLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(engine.contextDate) { return "Today" }
        if cal.isDateInYesterday(engine.contextDate) { return "Yesterday" }
        if engine.contextDate > Date().addingTimeInterval(86400 * 6) { return "Future" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: engine.contextDate)
    }

    private var dateLabelFull: String {
        let cal = Calendar.current
        if cal.isDateInToday(engine.contextDate) { return "Today" }
        let f = DateFormatter()
        f.dateStyle = .long
        return f.string(from: engine.contextDate)
    }
}

// MARK: - MessageBubble

private struct MessageBubble: View {
    let message: ChatMessage
    @State private var isExpanded = false

    private var theme: AppTheme { AppSettings.shared.appTheme }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 48) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 3) {
                bubbleContent
                    .textSelection(.enabled)
                Text(timeString)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }

            if message.role != .user { Spacer(minLength: 48) }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        switch message.role {
        case .user:
            Text(message.content)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(theme.accentColor, in: BubbleShape(isUser: true))

        case .assistant:
            MarkdownText(message.content)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    BubbleShape(isUser: false)
                        .fill(Color(NSColor.controlBackgroundColor))
                        .overlay(
                            BubbleShape(isUser: false)
                                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                        )
                )

        case .error:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text(message.content)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.orange.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                    )
            )
        }
    }

    private var timeString: String {
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: message.timestamp)
    }
}

// MARK: - MarkdownText (simple subset)

/// Renders **bold**, bullet lists, and ## headings from AI responses.
private struct MarkdownText: View {
    let raw: String

    init(_ raw: String) { self.raw = raw }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, para in
                para
            }
        }
    }

    private var paragraphs: [AnyView] {
        let lines = raw.components(separatedBy: "\n")
        var views: [AnyView] = []
        var buffer: [String] = []

        func flush() {
            if !buffer.isEmpty {
                let joined = buffer.joined(separator: "\n")
                if !joined.trimmingCharacters(in: .whitespaces).isEmpty {
                    views.append(AnyView(styledText(joined).font(.system(size: 13))))
                }
                buffer = []
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") || trimmed.hasPrefix("# ") {
                flush()
                let heading = trimmed.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
                views.append(AnyView(
                    Text(heading)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                ))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("• ") || trimmed.hasPrefix("* ") {
                flush()
                let bullet = trimmed.dropFirst(2)
                views.append(AnyView(
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.top, 1)
                        styledText(String(bullet))
                            .font(.system(size: 13))
                    }
                ))
            } else if trimmed.isEmpty {
                flush()
            } else {
                buffer.append(line)
            }
        }
        flush()
        return views
    }

    private func styledText(_ raw: String) -> Text {
        // Parse **bold** segments
        var result = Text("")
        var remaining = raw
        while let boldStart = remaining.range(of: "**") {
            let before = String(remaining[remaining.startIndex..<boldStart.lowerBound])
            if !before.isEmpty { result = result + Text(before) }
            remaining = String(remaining[boldStart.upperBound...])
            if let boldEnd = remaining.range(of: "**") {
                let bold = String(remaining[remaining.startIndex..<boldEnd.lowerBound])
                result = result + Text(bold).bold()
                remaining = String(remaining[boldEnd.upperBound...])
            }
        }
        if !remaining.isEmpty { result = result + Text(remaining) }
        return result
    }
}

// MARK: - ThinkingIndicator

private struct ThinkingIndicator: View {
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.45, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.secondary.opacity(phase == i ? 0.9 : 0.3))
                        .frame(width: 6, height: 6)
                        .scaleEffect(phase == i ? 1.2 : 0.9)
                        .animation(.easeInOut(duration: 0.4), value: phase)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(
                BubbleShape(isUser: false)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .overlay(
                        BubbleShape(isUser: false)
                            .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                    )
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
                    .fill(isHovered ? Color.primary.opacity(0.06) : Color.primary.opacity(0.03))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - BubbleShape

private struct BubbleShape: Shape {
    let isUser: Bool

    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 14
        let tailR: CGFloat = 4
        var path = Path()
        if isUser {
            // Rounded rect with slight point at bottom-right
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: r, height: r))
        } else {
            path.addRoundedRect(in: rect, cornerSize: CGSize(width: r, height: r))
        }
        return path
    }
}
