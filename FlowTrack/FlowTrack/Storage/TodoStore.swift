import Foundation
import OSLog

private let todoLog = Logger(subsystem: "com.flowtrack", category: "TodoStore")

// MARK: - TodoStore
@MainActor @Observable
final class TodoStore {
    static let shared = TodoStore()

    var todos: [TodoItem] = []
    var timerSessions: [TimerSession] = []
    var isBreakingDown = false
    var breakdownError: String?

    private let todosURL: URL
    private let sessionsURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlowTrack", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        todosURL = support.appendingPathComponent("todos.json")
        sessionsURL = support.appendingPathComponent("timer_sessions.json")
        load()
    }

    // MARK: - Persistence

    func load() {
        if let data = try? Data(contentsOf: todosURL),
           let decoded = try? JSONDecoder().decode([TodoItem].self, from: data) {
            todos = decoded
        }
        if let data = try? Data(contentsOf: sessionsURL),
           let decoded = try? JSONDecoder().decode([TimerSession].self, from: data) {
            timerSessions = decoded
        }
    }

    private func saveTodos() {
        if let data = try? JSONEncoder().encode(todos) {
            try? data.write(to: todosURL, options: .atomic)
        }
    }

    private func saveSessions() {
        if let data = try? JSONEncoder().encode(timerSessions) {
            try? data.write(to: sessionsURL, options: .atomic)
        }
    }

    // MARK: - Todo CRUD

    func add(_ todo: TodoItem) {
        todos.insert(todo, at: 0)
        saveTodos()
    }

    func update(_ todo: TodoItem) {
        guard let idx = todos.firstIndex(where: { $0.id == todo.id }) else { return }
        var updated = todo
        updated.updatedAt = Date()
        todos[idx] = updated
        saveTodos()
    }

    func delete(_ todo: TodoItem) {
        todos.removeAll { $0.id == todo.id }
        saveTodos()
    }

    func toggle(_ todo: TodoItem) {
        guard let idx = todos.firstIndex(where: { $0.id == todo.id }) else { return }
        var t = todos[idx]
        t.status = t.status == .done ? .pending : .done
        t.updatedAt = Date()
        todos[idx] = t
        saveTodos()
    }

    func setStatus(_ status: TodoStatus, for todoId: String) {
        guard let idx = todos.firstIndex(where: { $0.id == todoId }) else { return }
        guard todos[idx].status != status else { return }
        var t = todos[idx]
        t.status = status
        t.updatedAt = Date()
        todos[idx] = t
        saveTodos()
    }

    // MARK: - Timer Sessions

    func saveTimerSession(_ session: TimerSession) {
        timerSessions.append(session)
        saveSessions()
    }

    func trackedTime(for todoId: String) -> TimeInterval {
        timerSessions.filter { $0.todoId == todoId }.reduce(0) { $0 + $1.duration }
    }

    // MARK: - Data Management

    func clearTimerSessions() {
        timerSessions.removeAll()
        saveSessions()
    }

    func clearCompletedTodos() {
        todos.removeAll { $0.status == .done }
        saveTodos()
    }

    func clearAllTodos() {
        todos.removeAll()
        saveTodos()
    }

    func clearAll() {
        todos.removeAll()
        timerSessions.removeAll()
        saveTodos()
        saveSessions()
    }

    // MARK: - AI Task Breakdown

    func breakdown(todo: TodoItem) async {
        isBreakingDown = true
        breakdownError = nil
        defer { isBreakingDown = false }

        let prompt = """
        Break down this task into 3-7 specific, actionable subtasks.
        Task: \(todo.title)
        \(todo.notes.isEmpty ? "" : "Details: \(todo.notes)")

        Return ONLY a JSON array of short task title strings, nothing else. Example:
        ["Research options","Draft outline","Review and revise"]
        """

        do {
            let response = try await AppState.shared.withFallback { provider in
                try await provider.chat(
                    messages: [ChatTurn(role: "user", content: prompt)],
                    systemPrompt: "You are a productivity assistant. Return only valid JSON arrays, no markdown, no explanation."
                )
            }
            // Strip markdown code fences if present
            let cleaned = response
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let data = cleaned.data(using: .utf8),
                  let titles = try? JSONDecoder().decode([String].self, from: data) else {
                breakdownError = "Could not parse AI response"
                return
            }

            for title in titles {
                let sub = TodoItem(title: title, priority: todo.priority)
                todos.insert(sub, at: (todos.firstIndex(where: { $0.id == todo.id }) ?? 0) + 1)
            }
            saveTodos()
        } catch {
            breakdownError = error.localizedDescription
            todoLog.error("Breakdown failed: \(error.localizedDescription)")
        }
    }
}
