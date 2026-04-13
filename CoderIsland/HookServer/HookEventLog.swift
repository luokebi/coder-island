import Foundation

/// A single recorded hook event for the debug viewer.
struct HookEventEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let action: String        // "permission", "ask", "event"
    let eventName: String     // "PreToolUse", "PermissionRequest", "AskUserQuestion", etc.
    let sessionId: String
    let agentId: String?
    let toolName: String?
    let toolInput: [String: Any]?
    let errorMessage: String?

    /// Short session ID for display.
    var shortSessionId: String { String(sessionId.prefix(8)) }

    /// Human-readable one-line summary.
    var summary: String {
        var parts = [eventName]
        if let tool = toolName { parts.append(tool) }
        return parts.joined(separator: " ")
    }
}

/// In-memory ring buffer of recent hook events, observable by the debug UI.
class HookEventLog: ObservableObject {
    static let shared = HookEventLog()

    @Published private(set) var entries: [HookEventEntry] = []

    private let maxEntries = 500

    private init() {}

    func append(
        action: String,
        eventName: String,
        sessionId: String,
        agentId: String? = nil,
        toolName: String? = nil,
        toolInput: [String: Any]? = nil,
        errorMessage: String? = nil
    ) {
        let entry = HookEventEntry(
            timestamp: Date(),
            action: action,
            eventName: eventName,
            sessionId: sessionId,
            agentId: agentId,
            toolName: toolName,
            toolInput: toolInput,
            errorMessage: errorMessage
        )
        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
    }

    func clear() {
        DispatchQueue.main.async {
            self.entries.removeAll()
        }
    }
}
