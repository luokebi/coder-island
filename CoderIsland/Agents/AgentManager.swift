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
    private var currentScanInterval: TimeInterval = 3.0
    private var knownSessionIds: Set<String> = []
    private let claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    private let codexDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")

    func startMonitoring() {
        scanForSessions()
        rescheduleScanTimer(interval: 3.0)
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
                        let oldStatus = self.sessions[idx].status
                        let oldSubtitle = self.sessions[idx].subtitle
                        self.sessions[idx].status = session.status
                        self.sessions[idx].taskName = session.taskName
                        self.sessions[idx].subtitle = session.subtitle
                        self.sessions[idx].terminalApp = session.terminalApp
                        // Clear ask when no longer waiting (e.g. interrupted)
                        if session.status != .waiting {
                            self.sessions[idx].askQuestion = nil
                            self.sessions[idx].askOptions = nil
                        } else {
                            self.sessions[idx].askQuestion = session.askQuestion
                            self.sessions[idx].askOptions = session.askOptions
                        }
                        self.sessions[idx].lastUserMessage = session.lastUserMessage
                        self.sessions[idx].lastAssistantMessage = session.lastAssistantMessage

                        // Bump lastUpdated when state actually changes
                        if session.status != oldStatus || session.subtitle != oldSubtitle {
                            self.sessions[idx].lastUpdated = Date()
                        }

                        // Play completion sound only when transitioning from active -> done
                        if session.status == .done && (oldStatus == .running || oldStatus == .waiting) {
                            SoundManager.shared.playTaskComplete()
                        }

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

                // Sort: running first, then done/error, then idle
                // Within same priority, most recently active first
                self.sessions.sort { a, b in
                    let order: [AgentStatus: Int] = [.running: 0, .waiting: 0, .done: 1, .idle: 2, .error: 1]
                    let oa = order[a.status] ?? 2
                    let ob = order[b.status] ?? 2
                    if oa != ob { return oa < ob }
                    return a.lastUpdated > b.lastUpdated
                }

                // Adaptive polling:
                // - 1s when there are active sessions (running/waiting)
                // - 3s when everything is idle
                let hasActiveSession = self.sessions.contains { session in
                    session.status == .running || session.status == .waiting
                }
                self.rescheduleScanTimer(interval: hasActiveSession ? 1.0 : 3.0)
            }
        }
    }

    private func rescheduleScanTimer(interval: TimeInterval) {
        guard abs(currentScanInterval - interval) > 0.01 || scanTimer == nil else { return }
        scanTimer?.invalidate()
        currentScanInterval = interval
        scanTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.scanForSessions()
        }
    }

    // MARK: - Claude Code

    private func scanClaudeCodeSessions() -> [AgentSession] {
        var sessions: [AgentSession] = []
        var knownPids: Set<Int32> = []

        // Part 1: Standard Claude Code sessions (from session files)
        let sessionsDir = claudeDir.appendingPathComponent("sessions")
        if let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil
        ) {
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

                knownPids.insert(Int32(pid))

                let cwd = json["cwd"] as? String ?? ""
                let startedAt = (json["startedAt"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
                let sessionName = json["name"] as? String
                let taskName = sessionName ?? cwd.components(separatedBy: "/").last ?? "Claude session"

                let state = readSessionState(sessionId: sessionId)
                let terminal = detectTerminalForProcess(pid: Int32(pid))

                sessions.append(AgentSession(
                    id: sessionId,
                    agentType: .claudeCode,
                    pid: Int32(pid),
                    taskName: taskName,
                    subtitle: state.subtitle,
                    status: state.status,
                    terminalApp: terminal,
                    workingDirectory: cwd,
                    startDate: Date(timeIntervalSince1970: startedAt / 1000),
                    askQuestion: state.askQuestion,
                    askOptions: state.askOptions,
                    lastUserMessage: state.lastUserMessage,
                    lastAssistantMessage: state.lastAssistantMessage
                ))
            }
        }

        // Part 2: Embedded Claude Code (Cursor, VS Code extensions)
        // These don't write session files, so discover via process scanning
        let embeddedPids = findEmbeddedClaudeProcesses()
        for pid in embeddedPids where !knownPids.contains(pid) {
            let cwd = getProcessCWD(pid: pid)
            let taskName = cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent } ?? "Claude session"
            let terminal = detectTerminalForProcess(pid: pid)

            // Try to find JSONL for state by matching CWD to projects dir
            var state = SessionState(status: .running, subtitle: "Working...")
            if let cwd = cwd {
                let projectKey = cwd.replacingOccurrences(of: "/", with: "-")
                let projectDir = claudeDir.appendingPathComponent("projects").appendingPathComponent(projectKey)
                if let jsonlFiles = try? FileManager.default.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey]),
                   let newest = jsonlFiles.filter({ $0.pathExtension == "jsonl" })
                    .sorted(by: { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast >
                        (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast })
                    .first {
                    state = parseLastMessage(from: newest)
                }
            }

            sessions.append(AgentSession(
                id: "embedded-claude-\(pid)",
                agentType: .claudeCode,
                pid: pid,
                taskName: taskName,
                subtitle: state.subtitle,
                status: state.status,
                terminalApp: terminal,
                workingDirectory: cwd,
                lastUserMessage: state.lastUserMessage,
                lastAssistantMessage: state.lastAssistantMessage
            ))
        }

        return sessions
    }

    /// Find claude processes running inside editors (Cursor, VS Code)
    private func findEmbeddedClaudeProcesses() -> [Int32] {
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
                let isClaudeMatch = comm.hasSuffix("/claude") || comm == "claude"
                let isEmbedded = comm.contains(".cursor/") || comm.contains(".vscode/") || comm.contains("extensions/")
                if isClaudeMatch && isEmbedded {
                    return Int32(parts[0])
                }
                return nil
            }
        } catch {
            return []
        }
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

        // No JSONL file = session at prompt, no conversation started yet
        return SessionState(status: .idle)
    }

    private func parseLastMessage(from file: URL) -> SessionState {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return SessionState(status: .running)
        }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()

        // Parse all entries from tail: recent (for status) + userMsg search
        // Use 128KB for user message search, tool_result entries can be very large
        let bigReadSize: UInt64 = min(fileSize, 131072)
        handle.seek(toFileOffset: fileSize - bigReadSize)
        let tailData = handle.readDataToEndOfFile()

        guard let tail = String(data: tailData, encoding: .utf8) else {
            return SessionState(status: .running)
        }

        let allLines = tail.components(separatedBy: "\n").filter { !$0.isEmpty }

        // Collect recent user/assistant messages for status detection
        var recent: [(type: String, json: [String: Any])] = []
        for line in allLines.reversed() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String,
                  type == "user" || type == "assistant" else {
                continue
            }
            recent.append((type, json))
            if recent.count >= 8 { break }
        }

        guard let last = recent.first else { return SessionState(status: .running) }

        // Find user's latest text message (scan all lines)
        let lastUserMsg: String? = {
            for line in allLines.reversed() {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["type"] as? String == "user",
                      let msg = json["message"] as? [String: Any] else { continue }
                let content = msg["content"]
                if let text = content as? String {
                    return "You: \(String(text.prefix(50)))"
                }
                if let arr = content as? [[String: Any]] {
                    let hasToolResult = arr.contains { $0["type"] as? String == "tool_result" }
                    if hasToolResult { continue }
                    if let textBlock = arr.first(where: { $0["type"] as? String == "text" }),
                       let text = textBlock["text"] as? String {
                        return "You: \(String(text.prefix(50)))"
                    }
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

            // Check for interrupt marker
            let isInterrupted: Bool = {
                if let text = contentValue as? String {
                    return text.contains("interrupted")
                }
                if let arr = contentValue as? [[String: Any]] {
                    return arr.contains { item in
                        (item["text"] as? String)?.contains("interrupted") == true
                    }
                }
                return false
            }()
            if isInterrupted {
                return SessionState(status: .done, lastUserMessage: lastUserMsg, lastAssistantMessage: lastAssistantMsg)
            }

            if isToolResult {
                // Find the most recent assistant message to describe what tool is running
                if let prev = recent.dropFirst().first(where: { $0.type == "assistant" }),
                   let msg = prev.json["message"] as? [String: Any],
                   let contentArray = msg["content"] as? [[String: Any]],
                   let toolUse = contentArray.last(where: { $0["type"] as? String == "tool_use" }),
                   let toolName = toolUse["name"] as? String {
                    let input = toolUse["input"] as? [String: Any]
                    return SessionState(status: .running, subtitle: describeToolUsage(tool: toolName, input: input), lastUserMessage: lastUserMsg, lastAssistantMessage: lastAssistantMsg)
                }
                return SessionState(status: .running, subtitle: "Working...", lastUserMessage: lastUserMsg, lastAssistantMessage: lastAssistantMsg)
            }

            // User sent a message, Claude is processing
            return SessionState(status: .running, subtitle: "Thinking...", lastUserMessage: lastUserMsg, lastAssistantMessage: lastAssistantMsg)
        }

        if last.type == "assistant",
           let message = last.json["message"] as? [String: Any] {
            let stopReason = message["stop_reason"] as? String

            if stopReason == "end_turn" {
                return SessionState(status: .done, lastUserMessage: lastUserMsg, lastAssistantMessage: lastAssistantMsg)
            } else if stopReason == nil {
                // No stop_reason = still streaming or thinking (intermediate assistant entry)
                // Claude Code writes assistant entries with stop_reason=nil during thinking phase
                // These should always be treated as running, never done
                return SessionState(status: .running, subtitle: "Thinking...", lastUserMessage: lastUserMsg, lastAssistantMessage: lastAssistantMsg)
            } else if stopReason == "tool_use" {
                if let contentArray = message["content"] as? [[String: Any]],
                   let toolUse = contentArray.last(where: { $0["type"] as? String == "tool_use" }),
                   let toolName = toolUse["name"] as? String {
                    let input = toolUse["input"] as? [String: Any]

                    if toolName == "AskUserQuestion" {
                        let hooksEnabled = UserDefaults.standard.bool(forKey: "askHooksEnabled")
                        if hooksEnabled {
                            return SessionState(status: .waiting, subtitle: "Waiting for answer...", lastUserMessage: lastUserMsg, lastAssistantMessage: lastAssistantMsg)
                        }
                        let question = extractQuestion(from: input)
                        let options = extractOptions(from: input)
                        return SessionState(
                            status: .waiting, subtitle: question,
                            askQuestion: question, askOptions: options,
                            lastUserMessage: lastUserMsg, lastAssistantMessage: lastAssistantMsg
                        )
                    }
                    return SessionState(status: .running, subtitle: describeToolUsage(tool: toolName, input: input), lastUserMessage: lastUserMsg, lastAssistantMessage: lastAssistantMsg)
                }
                return SessionState(status: .running, subtitle: "Working...", lastUserMessage: lastUserMsg, lastAssistantMessage: lastAssistantMsg)
            }
            return SessionState(status: .running, subtitle: "Thinking...", lastUserMessage: lastUserMsg, lastAssistantMessage: lastAssistantMsg)
        }

        return SessionState(status: .running, lastUserMessage: lastUserMsg, lastAssistantMessage: lastAssistantMsg)
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
        // 混合策略：
        // 1. Codex Desktop session: 只在 app-server 进程在运行时才显示，取最新的一个
        // 2. CLI codex session: 从运行中的 codex 进程发现，每个进程一个 session

        let allCodexPids = findProcesses(named: ["codex"])
        guard !allCodexPids.isEmpty else { return [] }

        // 判断 Codex Desktop app-server 是否在运行
        let desktopRunning = allCodexPids.contains { pid in
            getProcessArgs(pid: pid).contains("app-server")
        }

        // 找出 CLI agent 进程（排除 app-server 和 Electron Helper）
        let cliAgentPids = allCodexPids.filter { pid in
            let args = getProcessArgs(pid: pid)
            return !args.contains("app-server") && !args.contains("Codex Helper")
        }

        // 从 sqlite 读取 session 信息（用于匹配和状态检测）
        let dbPath = codexDir.appendingPathComponent("state_5.sqlite").path
        let threads = readCodexThreads(dbPath: dbPath)

        var sessions: [AgentSession] = []
        var usedSessionIds: Set<String> = []

        // --- Part 1: Codex Desktop session ---
        if desktopRunning {
            if let desktopThread = threads.first(where: { $0.source == "vscode" }),
               FileManager.default.fileExists(atPath: desktopThread.rolloutPath) {
                let state = parseCodexState(from: desktopThread.rolloutPath)
                sessions.append(AgentSession(
                    id: desktopThread.id,
                    agentType: .codex,
                    pid: 0,
                    taskName: cleanCodexThreadName(desktopThread.title),
                    subtitle: state.subtitle,
                    status: state.status,
                    terminalApp: "Codex",
                    workingDirectory: desktopThread.cwd,
                    startDate: desktopThread.createdAt,
                    lastUserMessage: state.lastUserMessage,
                    lastAssistantMessage: state.lastAssistantMessage
                ))
                usedSessionIds.insert(desktopThread.id)
            }
        }

        // --- Part 2: CLI codex sessions (每个进程一个) ---
        // 第一遍：用 lsof 精确匹配（rollout 文件直接打开的进程）
        var pidToRollout: [Int32: (path: String, sid: String)] = [:]
        for pid in cliAgentPids {
            let directRollouts = findActiveCodexRollouts(pids: [pid])
            if let path = directRollouts.first {
                let filename = URL(fileURLWithPath: path).lastPathComponent
                if let range = filename.range(of: #"[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}"#, options: .regularExpression) {
                    let sid = String(filename[range])
                    if !usedSessionIds.contains(sid) {
                        pidToRollout[pid] = (path: path, sid: sid)
                        usedSessionIds.insert(sid)
                    }
                }
            }
        }

        // 第二遍：为剩余进程做 CWD 匹配
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for pid in cliAgentPids {
            var rolloutPath = pidToRollout[pid]?.path
            var sessionId = pidToRollout[pid]?.sid
            var cwd: String?

            let pidCwd = getProcessCWD(pid: pid)
            let parentCwd: String? = getParentPid(of: pid).flatMap { getProcessCWD(pid: $0) }
            cwd = [pidCwd, parentCwd].compactMap { $0 }.first { $0 != home } ?? pidCwd

            if rolloutPath == nil {
                // Only try CWD matching if we have a specific project directory (not home)
                let hasMeaningfulCwd = (cwd != nil && cwd != home) || (pidCwd != nil && pidCwd != home) || (parentCwd != nil && parentCwd != home)
                if hasMeaningfulCwd {
                    for thread in threads where !usedSessionIds.contains(thread.id) && thread.source != "vscode" {
                        if thread.cwd == cwd || thread.cwd == pidCwd || thread.cwd == parentCwd {
                            if FileManager.default.fileExists(atPath: thread.rolloutPath) {
                                rolloutPath = thread.rolloutPath
                                sessionId = thread.id
                                cwd = cwd ?? thread.cwd
                                usedSessionIds.insert(thread.id)
                                break
                            }
                        }
                    }
                }
            }

            // 解析状态
            let state: SessionState
            let displayName: String
            if let path = rolloutPath {
                state = parseCodexState(from: path)
                let meta = readCodexSessionMeta(path: path)
                cwd = cwd ?? meta.cwd
                if let sid = sessionId,
                   let thread = threads.first(where: { $0.id == sid }) {
                    displayName = cleanCodexThreadName(thread.title)
                } else {
                    displayName = cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent } ?? "Codex"
                }
            } else {
                state = SessionState(status: .idle)
                displayName = cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent } ?? "Codex"
            }

            sessions.append(AgentSession(
                id: sessionId ?? "codex-\(pid)",
                agentType: .codex,
                pid: pid,
                taskName: displayName,
                subtitle: state.subtitle,
                status: state.status,
                terminalApp: detectTerminalForProcess(pid: pid),
                workingDirectory: cwd,
                startDate: nil,
                lastUserMessage: state.lastUserMessage,
                lastAssistantMessage: state.lastAssistantMessage
            ))
        }

        return sessions
    }

    struct CodexThread {
        let id: String
        let rolloutPath: String
        let cwd: String
        let title: String
        let source: String
        let createdAt: Date?
    }

    private func readCodexThreads(dbPath: String) -> [CodexThread] {
        // 用 JSON 输出避免 title 含 | 导致字段错位
        let task = Process()
        task.launchPath = "/usr/bin/sqlite3"
        task.arguments = ["-json", dbPath, "SELECT id, rollout_path, cwd, title, source, created_at FROM threads WHERE archived=0 ORDER BY updated_at DESC LIMIT 10;"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

            return rows.compactMap { row -> CodexThread? in
                guard let id = row["id"] as? String,
                      let rolloutPath = row["rollout_path"] as? String,
                      let cwd = row["cwd"] as? String,
                      let title = row["title"] as? String,
                      let source = row["source"] as? String else { return nil }
                let createdAt: Date? = {
                    if let ts = row["created_at"] as? TimeInterval {
                        return Date(timeIntervalSince1970: ts)
                    }
                    return nil
                }()
                return CodexThread(
                    id: id, rolloutPath: rolloutPath, cwd: cwd,
                    title: title, source: source, createdAt: createdAt
                )
            }
        } catch { return [] }
    }

    private func findCodexRolloutFile(sessionId: String) -> String? {
        // Search the sessions directory for a rollout file matching this session ID
        let sessionsDir = codexDir.appendingPathComponent("sessions")
        let fm = FileManager.default

        // Try recent year/month/day directories (most recent first)
        guard let years = try? fm.contentsOfDirectory(atPath: sessionsDir.path) else { return nil }
        for year in years.sorted().reversed() {
            let yearDir = sessionsDir.appendingPathComponent(year)
            guard let months = try? fm.contentsOfDirectory(atPath: yearDir.path) else { continue }
            for month in months.sorted().reversed() {
                let monthDir = yearDir.appendingPathComponent(month)
                guard let days = try? fm.contentsOfDirectory(atPath: monthDir.path) else { continue }
                for day in days.sorted().reversed() {
                    let dayDir = monthDir.appendingPathComponent(day)
                    guard let files = try? fm.contentsOfDirectory(atPath: dayDir.path) else { continue }
                    for file in files where file.contains(sessionId) && file.hasSuffix(".jsonl") {
                        return dayDir.appendingPathComponent(file).path
                    }
                }
            }
        }
        return nil
    }

    struct CodexMeta {
        var cwd: String?
        var startDate: Date?
        var source: String?
    }

    private func readCodexSessionMeta(path: String) -> CodexMeta {
        guard let handle = FileHandle(forReadingAtPath: path) else { return CodexMeta() }
        defer { handle.closeFile() }

        // Read first 4KB to find session_meta
        let data = handle.readData(ofLength: 4096)
        guard let text = String(data: data, encoding: .utf8) else { return CodexMeta() }

        let firstLine = text.components(separatedBy: "\n").first ?? ""
        guard let lineData = firstLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              json["type"] as? String == "session_meta",
              let payload = json["payload"] as? [String: Any] else { return CodexMeta() }

        let cwd = payload["cwd"] as? String
        let source = payload["source"] as? String
        var startDate: Date?
        if let ts = payload["timestamp"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            startDate = formatter.date(from: ts)
        }

        return CodexMeta(cwd: cwd, startDate: startDate, source: source)
    }

    private func parseCodexState(from path: String) -> SessionState {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return SessionState(status: .running)
        }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        let readSize: UInt64 = min(fileSize, 131072)  // 128KB to handle long sessions
        handle.seek(toFileOffset: fileSize - readSize)
        let tailData = handle.readDataToEndOfFile()

        guard let tail = String(data: tailData, encoding: .utf8) else {
            return SessionState(status: .running)
        }

        let lines = tail.components(separatedBy: "\n").filter { !$0.isEmpty }

        var lastEventType: String?
        var lastAgentMessage: String?
        var lastUserMessage: String?
        var lastToolCall: String?
        var hasResponseItems = false
        var hasUserMessageAfterComplete = false
        var foundTaskComplete = false

        // Parse from the end to find the most recent state
        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String,
                  let payload = json["payload"] as? [String: Any] else { continue }

            if type == "event_msg" {
                let payloadType = payload["type"] as? String
                if payloadType == "task_complete" {
                    if lastEventType == nil { lastEventType = "task_complete" }
                    foundTaskComplete = true
                    if let msg = payload["last_agent_message"] as? String, lastAgentMessage == nil {
                        lastAgentMessage = String(msg.prefix(80))
                    }
                } else if payloadType == "task_started" {
                    if lastEventType == nil { lastEventType = "task_started" }
                } else if payloadType == "user_message" || payloadType == "agent_message" {
                    let msg = payload["message"] as? String
                    if payloadType == "user_message" {
                        if lastUserMessage == nil {
                            lastUserMessage = msg.map { String($0.prefix(80)) }
                        }
                        // user_message AFTER task_complete means new task started
                        if !foundTaskComplete {
                            hasUserMessageAfterComplete = true
                        }
                    } else if payloadType == "agent_message" && lastAgentMessage == nil {
                        lastAgentMessage = msg.map { String($0.prefix(80)) }
                    }
                }
            } else if type == "response_item" {
                hasResponseItems = true
                if let itemType = payload["type"] as? String, itemType == "function_call" {
                    if lastToolCall == nil {
                        let name = payload["name"] as? String ?? "tool"
                        lastToolCall = name
                    }
                }
            }

            // Stop once we have enough context
            if lastEventType != nil && lastAgentMessage != nil && lastUserMessage != nil { break }
        }

        let status: AgentStatus
        let subtitle: String?

        // If user sent a message after the last task_complete, a new task is active
        if lastEventType == "task_complete" && hasUserMessageAfterComplete {
            if let tool = lastToolCall {
                status = .running
                subtitle = tool
            } else {
                status = .running
                subtitle = "Thinking..."
            }
        } else {
            switch lastEventType {
            case "task_complete":
                status = .done
                subtitle = nil
            case "task_started":
                if let tool = lastToolCall {
                    status = .running
                    subtitle = tool
                } else {
                    status = .running
                    subtitle = "Thinking..."
                }
            default:
                // No task event found — check if there's active work
                if hasResponseItems {
                    // Has response items = actively working (task_started might be outside tail)
                    status = .running
                    subtitle = lastToolCall ?? "Thinking..."
                } else {
                    status = .idle
                    subtitle = nil
                }
            }
        }

        return SessionState(
            status: status,
            subtitle: subtitle,
            lastUserMessage: lastUserMessage,
            lastAssistantMessage: lastAgentMessage
        )
    }

    private func cleanCodexThreadName(_ name: String) -> String {
        // Thread names can contain junk like '}]}]}' from truncation
        var cleaned = name
        // Remove trailing JSON-like artifacts
        if let range = cleaned.range(of: #"[}\]]{2,}"#, options: .regularExpression) {
            cleaned = String(cleaned[..<range.lowerBound])
        }
        return String(cleaned.prefix(50)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func findActiveCodexRollouts(pids: [Int32]) -> [String] {
        guard !pids.isEmpty else { return [] }
        let pidArgs = pids.map { String($0) }.joined(separator: ",")
        let task = Process()
        task.launchPath = "/usr/sbin/lsof"
        task.arguments = ["-p", pidArgs, "-Fn"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return [] }
            var paths: [String] = []
            for line in output.components(separatedBy: "\n") {
                if line.hasPrefix("n") && line.contains("rollout-") && line.hasSuffix(".jsonl") {
                    let path = String(line.dropFirst())
                    if !paths.contains(path) { paths.append(path) }
                }
            }
            return paths
        } catch { return [] }
    }

    private func getProcessArgs(pid: Int32) -> String {
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-p", String(pid), "-o", "args="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch { return "" }
    }

    private func getProcessCWD(pid: Int32) -> String? {
        let task = Process()
        task.launchPath = "/usr/sbin/lsof"
        task.arguments = ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            for line in output.components(separatedBy: "\n") {
                if line.hasPrefix("n/") {
                    return String(line.dropFirst()) // Remove 'n' prefix
                }
            }
        } catch {}
        return nil
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

    private func getParentPid(of pid: Int32) -> Int32? {
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-p", String(pid), "-o", "ppid="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let ppid = Int32(output), ppid > 1 {
                return ppid
            }
        } catch {}
        return nil
    }

    private func detectTerminalForProcess(pid: Int32) -> String {
        // Display names for terminal apps
        let terminalApps = ["iTerm2", "Terminal", "Ghostty", "Warp", "Alacritty", "kitty", "Cursor", "Codex"]
        // Extra keywords for comm name matching (e.g. iTermServer → iTerm2, Code Helper → VS Code)
        let terminalAliases: [String: String] = [
            "iterm": "iTerm2",
            "code helper": "VS Code",
            "visual studio code": "VS Code",
        ]
        let workspace = NSWorkspace.shared

        let matchAppName: (String) -> String? = { name in
            if terminalApps.contains(name) { return name }
            let lower = name.lowercased()
            for (alias, display) in terminalAliases {
                if lower.contains(alias) { return display }
            }
            return nil
        }

        // First, check if the process itself is a known terminal/app
        if let processApp = workspace.runningApplications.first(where: { $0.processIdentifier == pid }) {
            if let name = processApp.localizedName, let matched = matchAppName(name) {
                return matched
            }
        }

        // Strategy 1: Walk up the process tree (works when terminal PID is a direct ancestor)
        var currentPid = pid
        var visited: Set<Int32> = [pid]
        let maxDepth = 10

        for _ in 0..<maxDepth {
            guard let ppid = getParentPid(of: currentPid) else { break }
            if visited.contains(ppid) { break }
            visited.insert(ppid)

            if let parentApp = workspace.runningApplications.first(where: { $0.processIdentifier == ppid }) {
                if let name = parentApp.localizedName, let matched = matchAppName(name) {
                    return matched
                }
            }

            let task = Process()
            task.launchPath = "/bin/ps"
            task.arguments = ["-p", String(ppid), "-o", "comm="]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            if let _ = try? task.run() {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    let commName = output.components(separatedBy: "/").last ?? output
                    let commLower = commName.lowercased()
                    // Check aliases first (e.g. iTermServer → iTerm2) to avoid
                    // "Terminal" falsely matching "iTermServer"
                    for (alias, app) in terminalAliases {
                        if commLower.contains(alias) {
                            return app
                        }
                    }
                    for app in terminalApps {
                        if commLower.contains(app.lowercased()) {
                            return app
                        }
                    }
                }
            }

            currentPid = ppid
        }

        // Strategy 2: TTY-based detection
        // On macOS, terminal apps (Terminal.app, iTerm2, Warp, etc.) are NOT direct
        // ancestors in the process tree. The chain is: TerminalApp → forkpty → login → shell → process,
        // but ppid walks: process → shell → login → launchd, skipping the GUI app.
        // Instead, find the process's TTY and match it against running terminal app children.
        if let tty = getProcessTTY(pid: pid) {
            // Get all PIDs on the same TTY
            let ttyPids = getPidsOnTTY(tty)
            // Check which running terminal app owns any process on this TTY
            for app in workspace.runningApplications {
                guard let name = app.localizedName, terminalApps.contains(name) else { continue }
                // Walk children of this app to see if any share the TTY
                let appPid = app.processIdentifier
                if ttyPids.contains(appPid) {
                    return name
                }
                // Check if any process on this TTY has this app as an ancestor
                for ttyPid in ttyPids {
                    if isAncestor(appPid, of: ttyPid) {
                        return name
                    }
                }
            }
        }

        return "Terminal"
    }

    private func getProcessTTY(pid: Int32) -> String? {
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-p", String(pid), "-o", "tty="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty, output != "??" {
                return output
            }
        } catch {}
        return nil
    }

    private func getPidsOnTTY(_ tty: String) -> Set<Int32> {
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-t", tty, "-o", "pid="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8) else { return [] }
            let pids = output.components(separatedBy: "\n").compactMap { line -> Int32? in
                Int32(line.trimmingCharacters(in: .whitespaces))
            }
            return Set(pids)
        } catch {
            return []
        }
    }

    private func isAncestor(_ ancestorPid: Int32, of pid: Int32) -> Bool {
        var current = pid
        var visited: Set<Int32> = [pid]
        for _ in 0..<15 {
            guard let ppid = getParentPid(of: current) else { return false }
            if ppid == ancestorPid { return true }
            if visited.contains(ppid) { return false }
            visited.insert(ppid)
            current = ppid
        }
        return false
    }
}
