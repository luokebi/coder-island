import Foundation
import Combine
import AppKit
import os

private let log = Logger(subsystem: "com.coderisland.app", category: "AgentManager")

func debugLog(_ msg: String) {
    log.debug("\(msg)")
}

class AgentManager: ObservableObject {
    @Published var sessions: [AgentSession] = []
    var onAskAppeared: (() -> Void)?
    private var scanTimer: Timer?
    private var knownSessionIds: Set<String> = []
    private let claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")

    func startMonitoring() {
        scanForSessions()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.scanForSessions()
        }
    }

    func stopMonitoring() {
        scanTimer?.invalidate()
        scanTimer = nil
    }

    private func scanForSessions() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }

            var activeSessions: [AgentSession] = []
            var activeIds: Set<String> = []

            let claudeSessions = self.scanClaudeCodeSessions()
            activeSessions.append(contentsOf: claudeSessions)
            activeIds.formUnion(claudeSessions.map { $0.id })

            let codexSessions = self.scanCodexSessions()
            activeSessions.append(contentsOf: codexSessions)
            activeIds.formUnion(codexSessions.map { $0.id })

            DispatchQueue.main.async {
                for session in activeSessions {
                    if !self.knownSessionIds.contains(session.id) {
                        self.sessions.append(session)
                        self.knownSessionIds.insert(session.id)
                    } else if let idx = self.sessions.firstIndex(where: { $0.id == session.id }) {
                        let hadAsk = self.sessions[idx].askQuestion != nil
                        self.sessions[idx].status = session.status
                        self.sessions[idx].taskName = session.taskName
                        self.sessions[idx].subtitle = session.subtitle
                        self.sessions[idx].askQuestion = session.askQuestion
                        self.sessions[idx].askOptions = session.askOptions
                        self.sessions[idx].lastUserMessage = session.lastUserMessage
                        self.sessions[idx].lastAssistantMessage = session.lastAssistantMessage

                        // Auto-expand when a new ask appears
                        if session.askQuestion != nil && !hadAsk {
                            self.onAskAppeared?()
                        }
                    }
                }

                self.sessions.removeAll { session in
                    if !activeIds.contains(session.id) {
                        self.knownSessionIds.remove(session.id)
                        return true
                    }
                    return false
                }

                // Sort: running first, then done, then idle — within same status, newest first
                self.sessions.sort { a, b in
                    let order: [AgentStatus: Int] = [.running: 0, .waiting: 0, .done: 1, .idle: 2, .error: 1]
                    let oa = order[a.status] ?? 2
                    let ob = order[b.status] ?? 2
                    if oa != ob { return oa < ob }
                    return a.startTime > b.startTime
                }
            }
        }
    }

    // MARK: - Claude Code

    private func scanClaudeCodeSessions() -> [AgentSession] {
        let sessionsDir = claudeDir.appendingPathComponent("sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil
        ) else { return [] }

        var sessions: [AgentSession] = []

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pid = (json["pid"] as? NSNumber)?.intValue,
                  let sessionId = json["sessionId"] as? String else {
                continue
            }

            guard isProcessRunning(pid: Int32(pid)) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }

            let cwd = json["cwd"] as? String ?? ""
            let startedAt = (json["startedAt"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
            let sessionName = json["name"] as? String
            let taskName = sessionName ?? cwd.components(separatedBy: "/").last ?? "Claude session"

            let state = readSessionState(sessionId: sessionId)
            let terminal = detectTerminalForProcess(pid: Int32(pid))

            let session = AgentSession(
                id: sessionId,
                agentType: .claudeCode,
                pid: Int32(pid),
                taskName: taskName,
                subtitle: state.subtitle,
                status: state.status,
                terminalApp: terminal,
                startDate: Date(timeIntervalSince1970: startedAt / 1000),
                askQuestion: state.askQuestion,
                askOptions: state.askOptions,
                lastUserMessage: state.lastUserMessage,
                lastAssistantMessage: state.lastAssistantMessage
            )
            sessions.append(session)
        }

        return sessions
    }

    struct SessionState {
        var status: AgentStatus
        var subtitle: String?
        var askQuestion: String?
        var askOptions: [(label: String, description: String)]?
        var lastUserMessage: String?
        var lastAssistantMessage: String?
    }

    private func readSessionState(sessionId: String) -> SessionState {
        let projectsDir = claudeDir.appendingPathComponent("projects")
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil
        ) else { return SessionState(status: .idle) }

        for projectDir in projectDirs {
            let jsonlFile = projectDir.appendingPathComponent("\(sessionId).jsonl")
            if FileManager.default.fileExists(atPath: jsonlFile.path) {
                return parseLastMessage(from: jsonlFile)
            }
        }

        return SessionState(status: .idle)
    }

    private func parseLastMessage(from file: URL) -> SessionState {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return SessionState(status: .running)
        }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        let readSize: UInt64 = min(fileSize, 16384)
        handle.seek(toFileOffset: fileSize - readSize)
        let tailData = handle.readDataToEndOfFile()

        guard let tail = String(data: tailData, encoding: .utf8) else {
            return SessionState(status: .running)
        }

        let lines = tail.components(separatedBy: "\n").filter { !$0.isEmpty }

        // Collect recent user/assistant messages (skip metadata)
        var recent: [(type: String, json: [String: Any])] = []
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String,
                  type == "user" || type == "assistant" else {
                continue
            }
            recent.append((type, json))
            if recent.count >= 4 { break }
        }

        guard let last = recent.first else { return SessionState(status: .running) }

        // Find user's latest text message (not tool_result)
        let lastUserMsg: String? = {
            for entry in recent where entry.type == "user" {
                if let msg = entry.json["message"] as? [String: Any],
                   let content = msg["content"] as? String {
                    return "You: \(String(content.prefix(50)))"
                }
            }
            return nil
        }()

        // Find assistant's latest text response
        let lastAssistantMsg: String? = {
            for entry in recent where entry.type == "assistant" {
                if let msg = entry.json["message"] as? [String: Any],
                   let contentArray = msg["content"] as? [[String: Any]] {
                    if let textContent = contentArray.last(where: { $0["type"] as? String == "text" }),
                       let text = textContent["text"] as? String {
                        return String(text.prefix(80))
                    }
                }
            }
            return nil
        }()

        if last.type == "user" {
            let content = last.json["message"] as? [String: Any]
            let contentValue = content?["content"]
            let isToolResult: Bool
            if let arr = contentValue as? [[String: Any]] {
                isToolResult = arr.contains { $0["type"] as? String == "tool_result" }
            } else {
                isToolResult = false
            }

            if isToolResult {
                if recent.count >= 2 && recent[1].type == "user" {
                    return SessionState(status: .idle)
                }
                if let prev = recent.dropFirst().first(where: { $0.type == "assistant" }),
                   let msg = prev.json["message"] as? [String: Any],
                   let contentArray = msg["content"] as? [[String: Any]],
                   let toolUse = contentArray.last(where: { $0["type"] as? String == "tool_use" }),
                   let toolName = toolUse["name"] as? String {
                    let input = toolUse["input"] as? [String: Any]
                    return SessionState(status: .running, subtitle: describeToolUsage(tool: toolName, input: input))
                }
                return SessionState(status: .running, subtitle: "Working...")
            }

            if recent.count >= 2 && recent[1].type == "user" {
                return SessionState(status: .idle)
            }

            return SessionState(status: .running, subtitle: "Thinking...")
        }

        if last.type == "assistant",
           let message = last.json["message"] as? [String: Any] {
            let stopReason = message["stop_reason"] as? String

            if stopReason == "end_turn" || stopReason == nil {
                // end_turn or no stop_reason (stream ended/interrupted) = done
                return SessionState(status: .done, lastUserMessage: lastUserMsg, lastAssistantMessage: lastAssistantMsg)
            } else if stopReason == "tool_use" {
                if let contentArray = message["content"] as? [[String: Any]],
                   let toolUse = contentArray.last(where: { $0["type"] as? String == "tool_use" }),
                   let toolName = toolUse["name"] as? String {
                    let input = toolUse["input"] as? [String: Any]

                    if toolName == "AskUserQuestion" {
                        let hooksEnabled = UserDefaults.standard.bool(forKey: "askHooksEnabled")
                        if hooksEnabled {
                            return SessionState(status: .waiting, subtitle: "Waiting for answer...", lastUserMessage: lastUserMsg)
                        }
                        let question = extractQuestion(from: input)
                        let options = extractOptions(from: input)
                        return SessionState(
                            status: .waiting, subtitle: question,
                            askQuestion: question, askOptions: options,
                            lastUserMessage: lastUserMsg
                        )
                    }
                    return SessionState(status: .running, subtitle: describeToolUsage(tool: toolName, input: input))
                }
                return SessionState(status: .running, subtitle: "Working...")
            }
            return SessionState(status: .running, subtitle: "Thinking...")
        }

        return SessionState(status: .running)
    }

    private func describeToolUsage(tool: String, input: [String: Any]?) -> String {
        guard let input = input else { return tool }
        switch tool {
        case "Bash":
            if let cmd = input["command"] as? String {
                return "$ \(String(cmd.prefix(40)))"
            }
        case "Read":
            if let path = input["file_path"] as? String {
                return "Read \(URL(fileURLWithPath: path).lastPathComponent)"
            }
        case "Write":
            if let path = input["file_path"] as? String {
                return "Write \(URL(fileURLWithPath: path).lastPathComponent)"
            }
        case "Edit":
            if let path = input["file_path"] as? String {
                return "Edit \(URL(fileURLWithPath: path).lastPathComponent)"
            }
        case "Grep":
            if let pattern = input["pattern"] as? String {
                return "Grep \"\(String(pattern.prefix(30)))\""
            }
        case "Glob":
            if let pattern = input["pattern"] as? String {
                return "Glob \(pattern)"
            }
        case "Agent":
            if let desc = input["description"] as? String {
                return "Agent: \(String(desc.prefix(30)))"
            }
        case "AskUserQuestion":
            return extractQuestion(from: input) ?? "Asking..."
        case "WebSearch":
            if let query = input["query"] as? String {
                return "Search: \(String(query.prefix(30)))"
            }
        case "WebFetch":
            if let url = input["url"] as? String {
                return "Fetch: \(String(url.prefix(30)))"
            }
        default:
            break
        }
        return tool
    }

    private func extractQuestion(from input: [String: Any]?) -> String? {
        guard let input = input,
              let questions = input["questions"] as? [[String: Any]],
              let first = questions.first,
              let question = first["question"] as? String else {
            return nil
        }
        return question
    }

    private func extractOptions(from input: [String: Any]?) -> [(label: String, description: String)]? {
        guard let input = input,
              let questions = input["questions"] as? [[String: Any]],
              let first = questions.first,
              let options = first["options"] as? [[String: Any]] else {
            return nil
        }
        return options.compactMap { opt in
            guard let label = opt["label"] as? String else { return nil }
            let desc = opt["description"] as? String ?? ""
            return (label: label, description: desc)
        }
    }

    // MARK: - Codex

    private func scanCodexSessions() -> [AgentSession] {
        let pids = findProcesses(named: ["codex"])
        return pids.map { pid in
            AgentSession(
                id: "codex-\(pid)",
                agentType: .codex,
                pid: pid,
                taskName: "Codex session",
                status: .running,
                terminalApp: detectTerminalForProcess(pid: pid)
            )
        }
    }

    // MARK: - Helpers

    private func isProcessRunning(pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    private func findProcesses(named names: [String]) -> [Int32] {
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-axo", "pid,comm"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return [] }

            return output.components(separatedBy: "\n").compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let parts = trimmed.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                let comm = String(parts[1])
                for name in names {
                    let isMatch = comm.hasSuffix("/\(name)") || comm == name
                    let isEmbedded = comm.contains(".cursor/") || comm.contains(".vscode/") || comm.contains("extensions/")
                    if isMatch && !isEmbedded {
                        return Int32(parts[0])
                    }
                }
                return nil
            }
        } catch {
            return []
        }
    }

    private func detectTerminalForProcess(pid: Int32) -> String {
        let terminalApps = ["iTerm2", "Terminal", "Ghostty", "Warp", "Alacritty", "kitty", "Cursor"]
        let workspace = NSWorkspace.shared
        for app in workspace.runningApplications {
            if let name = app.localizedName, terminalApps.contains(name), app.isActive {
                return name
            }
        }
        for app in workspace.runningApplications {
            if let name = app.localizedName, terminalApps.contains(name) {
                return name
            }
        }
        return "Terminal"
    }
}
