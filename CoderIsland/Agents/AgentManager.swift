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
    private let traceLogURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/CoderIsland", isDirectory: true)
        .appendingPathComponent("status-trace.log")

    /// Parses Claude Code transcript timestamps like "2026-04-07T07:27:12.576Z".
    static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func startMonitoring() {
        scanForSessions()
        rescheduleScanTimer(interval: 3.0)
    }

    func stopMonitoring() {
        scanTimer?.invalidate()
        scanTimer = nil
    }

    // MARK: - Hook event intake
    //
    // Entry point for Claude Code hook events (PreToolUse / PostToolUse /
    // PostToolUseFailure / Stop / StopFailure / UserPromptSubmit). These
    // give us real-time status updates that would otherwise be delayed by
    // the jsonl polling scan. Called on the main queue from HookServer.
    //
    // Subagent events (with a non-empty `agentId`) are currently ignored
    // here — main-agent-only updates keep the existing session model clean.
    func applyHookEvent(
        eventName: String,
        sessionId: String,
        agentId: String?,
        toolName: String?,
        toolInput: [String: Any]?,
        errorMessage: String?
    ) {
        if agentId != nil && !(agentId ?? "").isEmpty {
            // Subagent event — not tracked yet.
            return
        }
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else {
            // The session hasn't been discovered by the scan yet. Schedule
            // one more scan pass so it shows up on the next tick.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.scanForSessions()
            }
            return
        }
        let session = sessions[idx]
        let oldStatus = session.status
        var reason = "hook=\(eventName)"

        switch eventName {
        case "SessionStart":
            // Codex-only event (Claude Code doesn't fire it on our side).
            // Session was already discovered — the guard above schedules a
            // scan if not. Nothing to mutate here; keep the session as-is
            // and let the periodic scan fill in jsonl-derived state.
            break
        case "PreToolUse":
            if let toolName = toolName {
                session.subtitle = describeToolUsage(tool: toolName, input: toolInput)
                session.status = .running
                reason += " tool=\(toolName)"
            }
        case "PostToolUse":
            // Tool finished successfully — stay in running, let the next
            // PreToolUse or Stop update the subtitle. Keep the prior subtitle
            // so the UI doesn't flicker to "Thinking..." for sub-millisecond
            // gaps between tools.
            session.status = .running
        case "PostToolUseFailure":
            if let toolName = toolName {
                session.subtitle = "Error: \(toolName)"
                reason += " tool=\(toolName)"
            } else {
                session.subtitle = "Tool error"
            }
            session.status = .running
        case "UserPromptSubmit":
            session.subtitle = "Thinking..."
            session.status = .running
            // A new user prompt resets the completion-acknowledged marker so
            // the next Stop event can trigger the completion sound again.
            session.acknowledgedCompletionMarker = nil
            // Mark the submit timestamp so the next ~3s of scans don't
            // mistakenly play a completion sound: the jsonl tail may still
            // show the previous turn's end_turn because the new user prompt
            // hasn't been flushed yet, and we'd otherwise transition
            // .running → .justFinished for stale data.
            session.lastUserPromptSubmitAt = Date()
        case "Stop":
            // Authoritative main-agent completion. Overrides the jsonl
            // end_turn fallback which has historically misfired on
            // sidechain subagent turns.
            session.status = .justFinished
            let marker = "hook-stop:\(sessionId):\(Date().timeIntervalSince1970)"
            session.completionMarker = marker
            // Play the completion sound — but only if we weren't already
            // in a just-finished state (avoid double-firing from races).
            if oldStatus.isActive {
                SoundManager.shared.playTaskComplete()
            }
        case "StopFailure":
            session.status = .error
            if let msg = errorMessage, !msg.isEmpty {
                session.subtitle = "Stop failed: \(msg)"
            } else {
                session.subtitle = "Stop failed"
            }
        default:
            return
        }

        session.lastUpdated = Date()
        traceStatusTransition(
            event: "hook_event",
            session: session,
            oldStatus: oldStatus,
            reason: reason
        )
    }

    func acknowledgeRecentCompletion(sessionId: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }

        let session = sessions[idx]
        let marker = stableCompletionMarker(for: session)
        let oldStatus = session.status

        session.completionMarker = marker
        session.acknowledgedCompletionMarker = marker
        session.status = .idle
        session.lastUpdated = Date()

        let ts = ISO8601DateFormatter().string(from: Date())
        let safeTask = session.taskName.replacingOccurrences(of: "\n", with: "\\n")
        let safeMarker = (marker ?? "-").replacingOccurrences(of: "\n", with: "\\n")
        traceLine("\(ts) [completion_acknowledged] agent=\(session.agentType.rawValue) id=\(session.id) task=\(safeTask) old=\(oldStatus.rawValue) new=idle marker=\(safeMarker)")
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
                    session.completionMarker = self.stableCompletionMarker(for: session)
                    if !self.knownSessionIds.contains(session.id) {
                        self.sessions.append(session)
                        self.knownSessionIds.insert(session.id)
                        self.traceStatusTransition(
                            event: "session_appeared",
                            session: session,
                            oldStatus: nil,
                            reason: "initial scan insert"
                        )
                    } else if let idx = self.sessions.firstIndex(where: { $0.id == session.id }) {
                        let hadAsk = self.sessions[idx].askQuestion != nil
                        let oldStatus = self.sessions[idx].status
                        let oldSubtitle = self.sessions[idx].subtitle
                        let incomingCompletionMarker = self.stableCompletionMarker(for: session)
                        self.sessions[idx].completionMarker = incomingCompletionMarker

                        // Grace window after a UserPromptSubmit hook. The jsonl
                        // write of the new user prompt can lag the hook by up
                        // to a few seconds, so the scan would still see
                        // end_turn as the latest decisive entry and want to
                        // flip us back to .justFinished — playing a spurious
                        // completion sound at the *start* of a new turn.
                        let userPromptGrace: TimeInterval = 5
                        let inUserPromptGrace: Bool = {
                            guard let t = self.sessions[idx].lastUserPromptSubmitAt else { return false }
                            return Date().timeIntervalSince(t) < userPromptGrace
                        }()

                        let effectiveStatus: AgentStatus = {
                            if session.status.isRecentlyFinished,
                               incomingCompletionMarker != nil,
                               self.sessions[idx].acknowledgedCompletionMarker == incomingCompletionMarker {
                                return .idle
                            }
                            // Stickiness: once the Stop hook (or the prior jsonl
                            // end_turn detection) marks us .justFinished, don't
                            // let a subsequent scan regress us to .running just
                            // because the jsonl end_turn hasn't been flushed to
                            // disk yet. Only UserPromptSubmit (a real new turn)
                            // — handled in applyHookEvent — can bring us back
                            // to .running. This prevents a double completion
                            // sound when the Stop hook fires between the final
                            // tool_result and the end_turn disk flush.
                            if self.sessions[idx].status == .justFinished
                                && session.status == .running {
                                return .justFinished
                            }
                            // Symmetric guard: inside the UserPromptSubmit
                            // grace window, don't let the scan flip us back
                            // from .running to .justFinished based on a stale
                            // end_turn entry.
                            if inUserPromptGrace
                                && self.sessions[idx].status == .running
                                && session.status == .justFinished {
                                return .running
                            }
                            return session.status
                        }()
                        self.sessions[idx].status = effectiveStatus
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
                        if effectiveStatus != oldStatus || session.subtitle != oldSubtitle {
                            self.sessions[idx].lastUpdated = Date()
                            self.traceStatusTransition(
                                event: "status_changed",
                                session: self.sessions[idx],
                                oldStatus: oldStatus,
                                reason: session.subtitle ?? "subtitle=nil"
                            )
                        }

                        // Play completion sound only when transitioning from active -> completed
                        if effectiveStatus.isRecentlyFinished && oldStatus.isActive {
                            self.traceStatusTransition(
                                event: "completion_sound",
                                session: self.sessions[idx],
                                oldStatus: oldStatus,
                                reason: session.subtitle ?? "subtitle=nil"
                            )
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
                    let order: [AgentStatus: Int] = [.running: 0, .waiting: 0, .justFinished: 1, .done: 1, .error: 1, .idle: 2]
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

    private func stableCompletionMarker(for session: AgentSession) -> String? {
        if let marker = session.completionMarker, !marker.isEmpty {
            return marker
        }
        guard session.status.isRecentlyFinished else { return nil }

        let task = session.taskName.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = (session.lastUserMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let assistant = (session.lastAssistantMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return "fallback:\(session.agentType.rawValue):\(session.id):\(task):\(user):\(assistant)"
    }

    private func rescheduleScanTimer(interval: TimeInterval) {
        guard abs(currentScanInterval - interval) > 0.01 || scanTimer == nil else { return }
        scanTimer?.invalidate()
        currentScanInterval = interval
        scanTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.scanForSessions()
        }
    }

    private func traceLine(_ line: String) {
        debugLog(line)

        let fm = FileManager.default
        let dir = traceLogURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        if let attrs = try? fm.attributesOfItem(atPath: traceLogURL.path),
           let size = attrs[.size] as? NSNumber,
           size.intValue > 1_000_000 {
            try? fm.removeItem(at: traceLogURL)
        }

        if !fm.fileExists(atPath: traceLogURL.path) {
            fm.createFile(atPath: traceLogURL.path, contents: nil)
        }

        guard let data = (line + "\n").data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: traceLogURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            debugLog("[trace] append failed: \(error.localizedDescription)")
        }
    }

    private func traceStatusTransition(
        event: String,
        session: AgentSession,
        oldStatus: AgentStatus?,
        reason: String
    ) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let safeTask = session.taskName.replacingOccurrences(of: "\n", with: "\\n")
        let safeSubtitle = (session.subtitle ?? "").replacingOccurrences(of: "\n", with: "\\n")
        let safeReason = reason.replacingOccurrences(of: "\n", with: "\\n")
        traceLine("\(ts) [\(event)] agent=\(session.agentType.rawValue) id=\(session.id) task=\(safeTask) old=\(oldStatus?.rawValue ?? "-") new=\(session.status.rawValue) subtitle=\(safeSubtitle) reason=\(safeReason)")
    }

    private func traceParserDecision(
        parser: String,
        source: String,
        status: AgentStatus,
        subtitle: String?,
        reason: String
    ) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let safeSubtitle = (subtitle ?? "").replacingOccurrences(of: "\n", with: "\\n")
        let safeReason = reason.replacingOccurrences(of: "\n", with: "\\n")
        traceLine("\(ts) [parser] parser=\(parser) source=\(source) status=\(status.rawValue) subtitle=\(safeSubtitle) reason=\(safeReason)")
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
                    lastAssistantMessage: state.lastAssistantMessage,
                    completionMarker: state.completionMarker
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
                lastAssistantMessage: state.lastAssistantMessage,
                completionMarker: state.completionMarker
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
        var completionMarker: String?
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

    /// Exposed as `internal` so ParserTests.swift can drive it with
    /// synthetic jsonl fixtures and assert against the result.
    func parseLastMessage(from file: URL) -> SessionState {
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

        // Turn-end signal (authoritative): Claude Code writes a `system`
        // entry with `subtype: "stop_hook_summary"` when the main agent's
        // Stop hook has fired. If this entry is at the TAIL of the jsonl
        // (no user/assistant entries after it), the turn is definitively
        // ended. This handles the case where Claude Code sometimes fails
        // to write the assistant's final `stop_reason: end_turn` field.
        //
        // We walk the tail from the end, skipping other system/meta
        // entries. If we reach a stop_hook_summary before any
        // user/assistant entry, turn ended.
        let hasTrailingStopHookSummary: Bool = {
            for line in allLines.reversed() {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let type = json["type"] as? String
                if type == "system" {
                    if (json["subtype"] as? String) == "stop_hook_summary" {
                        return true
                    }
                    continue
                }
                if type == "user" || type == "assistant" {
                    if json["isSidechain"] as? Bool == true { continue }
                    return false
                }
            }
            return false
        }()

        // Collect recent user/assistant messages for status detection.
        // IMPORTANT: skip isSidechain entries — these come from Task subagents
        // sharing the same jsonl file. A subagent's `stop_reason: end_turn`
        // would otherwise be mistaken for the main session completing and
        // trigger a spurious "Just finished" status + completion sound.
        // Reference: Claude Code 2.1.x src/utils/conversationRecovery.ts:424
        // also skips sidechain when walking conversation tips.
        var recent: [(type: String, json: [String: Any])] = []
        for line in allLines.reversed() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String,
                  type == "user" || type == "assistant" else {
                continue
            }
            if json["isSidechain"] as? Bool == true { continue }
            recent.append((type, json))
            if recent.count >= 8 { break }
        }

        guard !recent.isEmpty else { return SessionState(status: .running) }

        // Find user's latest text message (scan all lines). Skip sidechain
        // (we'll also use this for the stop-hook-summary short-circuit's
        // lastUserMessage + lastAssistantMessage fields, hence moved above).
        // (subagent prompts) for the same reason as the recent loop above.
        let lastUserMsg: String? = {
            for line in allLines.reversed() {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["type"] as? String == "user",
                      json["isSidechain"] as? Bool != true,
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

        func decided(status: AgentStatus, subtitle: String? = nil, reason: String, askQuestion: String? = nil, askOptions: [(label: String, description: String)]? = nil, completionMarker: String? = nil) -> SessionState {
            traceParserDecision(
                parser: "claude",
                source: file.lastPathComponent,
                status: status,
                subtitle: subtitle,
                reason: reason
            )
            return SessionState(
                status: status,
                subtitle: subtitle,
                askQuestion: askQuestion,
                askOptions: askOptions,
                lastUserMessage: lastUserMsg,
                lastAssistantMessage: lastAssistantMsg,
                completionMarker: completionMarker
            )
        }

        // Authoritative turn-end marker: Claude Code wrote a
        // `system.stop_hook_summary` after the last user/assistant entry.
        // This is stronger than stop_reason, which can be missing or wrong.
        if hasTrailingStopHookSummary {
            let lastAssistantEntry = recent.first(where: { $0.type == "assistant" })
            let marker: String? = {
                if let entry = lastAssistantEntry {
                    if let uuid = entry.json["uuid"] as? String { return uuid }
                    if let msg = entry.json["message"] as? [String: Any],
                       let id = msg["id"] as? String { return id }
                    if let ts = entry.json["timestamp"] as? String { return "claude-stop-hook:\(ts)" }
                }
                return nil
            }()
            return decided(
                status: .justFinished,
                reason: "trailing system stop_hook_summary — main agent Stop hook ran",
                completionMarker: marker
            )
        }

        var sawIntermediateAssistant = false

        for (index, entry) in recent.enumerated() {
            if entry.type == "user" {
                let content = entry.json["message"] as? [String: Any]
                let contentValue = content?["content"]
                let isToolResult: Bool
                if let arr = contentValue as? [[String: Any]] {
                    isToolResult = arr.contains { $0["type"] as? String == "tool_result" }
                } else {
                    isToolResult = false
                }

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
                    return decided(status: .idle, reason: "user interrupt marker")
                }

                if isToolResult {
                    if let prev = recent.dropFirst(index + 1).first(where: { $0.type == "assistant" }),
                       let msg = prev.json["message"] as? [String: Any],
                       let contentArray = msg["content"] as? [[String: Any]],
                       let toolUse = contentArray.last(where: { $0["type"] as? String == "tool_use" }),
                       let toolName = toolUse["name"] as? String {
                        let input = toolUse["input"] as? [String: Any]
                        return decided(
                            status: .running,
                            subtitle: describeToolUsage(tool: toolName, input: input),
                            reason: "user tool_result after assistant tool_use=\(toolName)"
                        )
                    }
                    return decided(status: .running, subtitle: "Working...", reason: "user tool_result without matching tool_use")
                }

                return decided(status: .running, subtitle: "Thinking...", reason: "latest decisive entry is plain user message")
            }

            if entry.type == "assistant",
               let message = entry.json["message"] as? [String: Any] {
                let stopReason = message["stop_reason"] as? String

                if stopReason == "end_turn" {
                    let marker = (entry.json["uuid"] as? String)
                        ?? (message["id"] as? String)
                        ?? ((entry.json["timestamp"] as? String).map { "claude-end-turn:\($0)" })
                    return decided(status: .justFinished, reason: "assistant stop_reason=end_turn", completionMarker: marker)
                } else if stopReason == nil {
                    // A null stop_reason doesn't mean "finished". Claude
                    // Code writes intermediate text messages (e.g. "let
                    // me check X" narration before a tool call) with
                    // stop_reason=null too — skipping past is correct
                    // here. Turn-end detection for the "stop_reason
                    // never got written" edge case is handled further
                    // up via the trailing `system subtype=stop_hook_summary`
                    // check, which is the authoritative Claude Code
                    // turn-end marker.
                    sawIntermediateAssistant = true
                    continue
                } else if stopReason == "tool_use" {
                    if let contentArray = message["content"] as? [[String: Any]],
                       let toolUse = contentArray.last(where: { $0["type"] as? String == "tool_use" }),
                       let toolName = toolUse["name"] as? String {
                        let input = toolUse["input"] as? [String: Any]

                        if toolName == "AskUserQuestion" {
                            let hooksEnabled = UserDefaults.standard.bool(forKey: "askHooksEnabled")
                            if hooksEnabled {
                                return decided(status: .waiting, subtitle: "Waiting for answer...", reason: "assistant AskUserQuestion while hooks enabled")
                            }
                            let question = extractQuestion(from: input)
                            let options = extractOptions(from: input)
                            return decided(
                                status: .waiting,
                                subtitle: question,
                                reason: "assistant AskUserQuestion",
                                askQuestion: question,
                                askOptions: options
                            )
                        }
                        // (Removed: time-based "Awaiting permission" heuristic.
                        // It used to flip any tool_use older than 6s (Bash/Agent)
                        // or 2s (other tools) to .waiting on the assumption that
                        // long-stale tool_uses meant Claude was blocked on a
                        // permission prompt. That assumption is wrong now that
                        // we have real PermissionRequest hooks installed:
                        //   - if a tool is genuinely awaiting permission, the
                        //     /permission hook fires synchronously and the
                        //     pendingPermissions banner pops up directly
                        //   - if a Bash command legitimately takes 30+ seconds
                        //     (xcodebuild, npm install, test runs) the old
                        //     heuristic mislabeled it as "Awaiting permission"
                        //     even though nothing was waiting on the user.
                        // The hook path is now the only source of truth for
                        // pending-permission detection.)
                        return decided(
                            status: .running,
                            subtitle: describeToolUsage(tool: toolName, input: input),
                            reason: "assistant stop_reason=tool_use name=\(toolName)"
                        )
                    }
                    return decided(status: .running, subtitle: "Working...", reason: "assistant stop_reason=tool_use without tool payload")
                }
            }
        }

        if sawIntermediateAssistant {
            return decided(status: .running, subtitle: "Thinking...", reason: "only intermediate assistant entries with stop_reason=nil in recent tail")
        }

        return decided(status: .running, reason: "fallback running with no decisive recent entry")
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
                lastAssistantMessage: state.lastAssistantMessage,
                completionMarker: state.completionMarker
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
        var lastTurnAbortReason: String?
        var lastTaskCompleteMarker: String?

        func decided(status: AgentStatus, subtitle: String? = nil, reason: String, completionMarker: String? = nil) -> SessionState {
            traceParserDecision(
                parser: "codex",
                source: URL(fileURLWithPath: path).lastPathComponent,
                status: status,
                subtitle: subtitle,
                reason: reason
            )
            return SessionState(
                status: status,
                subtitle: subtitle,
                lastUserMessage: lastUserMessage,
                lastAssistantMessage: lastAgentMessage,
                completionMarker: completionMarker
            )
        }

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
                    if lastTaskCompleteMarker == nil {
                        lastTaskCompleteMarker = (json["timestamp"] as? String)
                            ?? payload["turn_id"] as? String
                            ?? payload["last_agent_message"] as? String
                    }
                    if let msg = payload["last_agent_message"] as? String, lastAgentMessage == nil {
                        lastAgentMessage = String(msg.prefix(80))
                    }
                } else if payloadType == "turn_aborted" {
                    if lastEventType == nil { lastEventType = "turn_aborted" }
                    if lastTurnAbortReason == nil {
                        lastTurnAbortReason = payload["reason"] as? String
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
                status = .justFinished
                subtitle = nil
            case "turn_aborted":
                if lastTurnAbortReason == "interrupted" {
                    status = .idle
                    subtitle = nil
                } else {
                    status = .error
                    subtitle = "Aborted"
                }
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

        let reason: String = {
            switch lastEventType {
            case "task_complete":
                return "event task_complete"
            case "turn_aborted":
                return "event turn_aborted reason=\(lastTurnAbortReason ?? "unknown")"
            case "task_started":
                return "event task_started"
            default:
                if hasResponseItems {
                    return "response_item fallback"
                }
                return "idle fallback without recent task events"
            }
        }()

        return decided(status: status, subtitle: subtitle, reason: reason, completionMarker: lastTaskCompleteMarker)
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
