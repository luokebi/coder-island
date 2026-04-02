import Foundation
import AppKit

enum AgentType: String, CaseIterable, Identifiable {
    case claudeCode = "claude"
    case codex = "codex"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude"
        case .codex: return "Codex"
        }
    }
}

enum AgentStatus: String {
    case idle
    case running
    case waiting
    case done
    case error
}

class AgentSession: ObservableObject, Identifiable {
    let id: String
    let agentType: AgentType
    let pid: Int32
    let startTime: Date

    @Published var taskName: String
    @Published var subtitle: String?
    @Published var status: AgentStatus
    @Published var terminalApp: String
    @Published var askQuestion: String?
    @Published var askOptions: [(label: String, description: String)]?
    @Published var lastUserMessage: String?
    @Published var lastAssistantMessage: String?

    init(
        id: String = UUID().uuidString,
        agentType: AgentType,
        pid: Int32,
        taskName: String = "Working...",
        subtitle: String? = nil,
        status: AgentStatus = .running,
        terminalApp: String = "Terminal",
        startDate: Date? = nil,
        askQuestion: String? = nil,
        askOptions: [(label: String, description: String)]? = nil,
        lastUserMessage: String? = nil,
        lastAssistantMessage: String? = nil
    ) {
        self.id = id
        self.agentType = agentType
        self.pid = pid
        self.startTime = startDate ?? Date()
        self.taskName = taskName
        self.subtitle = subtitle
        self.status = status
        self.terminalApp = terminalApp
        self.askQuestion = askQuestion
        self.askOptions = askOptions
        self.lastUserMessage = lastUserMessage
        self.lastAssistantMessage = lastAssistantMessage
    }

    var elapsedTimeString: String {
        let elapsed = Date().timeIntervalSince(startTime)
        if elapsed < 60 {
            return "\(Int(elapsed))s"
        } else if elapsed < 3600 {
            return "\(Int(elapsed / 60))m"
        } else {
            return "\(Int(elapsed / 3600))h"
        }
    }

    func jumpToTerminal() {
        let workspace = NSWorkspace.shared
        if let app = workspace.runningApplications.first(where: {
            $0.localizedName?.lowercased().contains(terminalApp.lowercased()) == true
        }) {
            app.activate()
        }
    }
}
