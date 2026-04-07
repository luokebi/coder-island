import Foundation
import Network

/// Lightweight HTTP server that receives Claude Code hook requests
/// and waits for UI responses before replying.
class HookServer {
    static let shared = HookServer()
    static let port: UInt16 = 19876

    private var listener: NWListener?
    private var pendingRequests = [String: PendingRequest]()
    private let queue = DispatchQueue(label: "com.coderisland.hookserver")

    /// Published for UI to observe
    var onPermissionRequest: ((PermissionRequest) -> Void)?
    var onAskQuestion: ((AskRequest) -> Void)?

    private init() {}

    func start() {
        do {
            let params = NWParameters.tcp
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: HookServer.port)!)
            listener?.newConnectionHandler = { [weak self] conn in
                self?.handleConnection(conn)
            }
            listener?.start(queue: queue)
            debugLog("[HookServer] Started on port \(HookServer.port)")
        } catch {
            debugLog("[HookServer] Failed to start: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Handle incoming connections

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self = self, let data = data else {
                connection.cancel()
                return
            }

            let raw = String(data: data, encoding: .utf8) ?? ""
            debugLog("[HookServer] Received: \(raw.prefix(200))")

            // Parse HTTP request - extract body after \r\n\r\n
            let body: String
            if let range = raw.range(of: "\r\n\r\n") {
                body = String(raw[range.upperBound...])
            } else {
                body = raw
            }

            // Parse the path
            let path = raw.split(separator: " ").dropFirst().first.map(String.init) ?? "/"

            self.handleRequest(path: path, body: body, connection: connection)
        }
    }

    private func handleRequest(path: String, body: String, connection: NWConnection) {
        debugLog("[HookServer] path=\(path) bodyLen=\(body.count)")
        guard let bodyData = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            debugLog("[HookServer] JSON parse failed, body: \(body.prefix(200))")
            sendResponse(connection: connection, statusCode: 400, body: "{\"error\":\"invalid json\"}")
            return
        }

        let requestId = UUID().uuidString
        let sessionId = json["session_id"] as? String ?? json["sessionId"] as? String ?? "unknown"

        switch path {
        case "/permission":
            // Dump full payload once so we can see what fields Claude Code actually sends.
            HookServer.dumpPayload(path: "/permission", body: body)

            // Claude Code hooks emit snake_case (tool_name/tool_input); accept camelCase too.
            let toolName = (json["tool_name"] as? String)
                ?? (json["toolName"] as? String)
                ?? "Unknown"
            let toolInput = (json["tool_input"] as? [String: Any])
                ?? (json["toolInput"] as? [String: Any])
                ?? [:]
            let inputDesc = describeToolInput(tool: toolName, input: toolInput)
            let cwd = json["cwd"] as? String ?? ""

            // Parse permission_suggestions — Claude Code provides the exact rules
            // that "allow and don't ask again" should add to settings.
            var allowSuggestion: PermissionSuggestion? = nil
            if let suggestions = json["permission_suggestions"] as? [[String: Any]] {
                for suggestion in suggestions {
                    guard (suggestion["type"] as? String) == "addRules",
                          (suggestion["behavior"] as? String) == "allow",
                          let rulesRaw = suggestion["rules"] as? [[String: Any]] else { continue }
                    let rules: [(toolName: String, ruleContent: String)] = rulesRaw.compactMap { r in
                        guard let tn = r["toolName"] as? String else { return nil }
                        let content = r["ruleContent"] as? String ?? ""
                        return (toolName: tn, ruleContent: content)
                    }
                    if !rules.isEmpty {
                        allowSuggestion = PermissionSuggestion(
                            destination: suggestion["destination"] as? String ?? "localSettings",
                            behavior: "allow",
                            rules: rules
                        )
                        break
                    }
                }
            }

            let request = PermissionRequest(
                id: requestId,
                sessionId: sessionId,
                toolName: toolName,
                description: inputDesc,
                toolInput: toolInput,
                cwd: cwd,
                allowSuggestion: allowSuggestion
            )

            pendingRequests[requestId] = PendingRequest(
                connection: connection,
                type: .permission,
                allowSuggestion: allowSuggestion
            )

            DispatchQueue.main.async {
                self.onPermissionRequest?(request)
            }

        case "/ask":
            let toolInput = json["tool_input"] as? [String: Any] ?? json
            var question = "Question from Claude"
            var header = ""
            var options: [(label: String, description: String)] = []

            if let questions = toolInput["questions"] as? [[String: Any]],
               let first = questions.first {
                question = first["question"] as? String ?? question
                header = first["header"] as? String ?? ""
                if let opts = first["options"] as? [[String: Any]] {
                    options = opts.compactMap { opt in
                        guard let label = opt["label"] as? String else { return nil }
                        return (label: label, description: opt["description"] as? String ?? "")
                    }
                }
            }

            let request = AskRequest(
                id: requestId,
                sessionId: sessionId,
                question: header.isEmpty ? question : "[\(header)] \(question)",
                header: header,
                options: options
            )

            pendingRequests[requestId] = PendingRequest(connection: connection, type: .ask, allowSuggestion: nil)
            debugLog("[HookServer] Ask request created: id=\(requestId) q=\(question) opts=\(options.count)")

            DispatchQueue.main.async {
                debugLog("[HookServer] Calling onAskQuestion callback")
                self.onAskQuestion?(request)
            }

        default:
            sendResponse(connection: connection, statusCode: 404, body: "{\"error\":\"not found\"}")
        }
    }

    // MARK: - Respond to pending requests

    /// Respond to a pending permission request with the user's decision.
    /// The body sent back is the *final* hook JSON that the shell script will
    /// echo verbatim to Claude Code — it must conform to Claude's
    /// `hookSpecificOutput.decision` schema for `PermissionRequest`.
    func respondToPermission(requestId: String, decision: PermissionDecisionKind) {
        queue.async {
            guard let pending = self.pendingRequests.removeValue(forKey: requestId) else { return }
            let body = HookServer.buildPermissionHookOutput(
                decision: decision,
                suggestion: pending.allowSuggestion
            )
            self.sendResponse(connection: pending.connection, statusCode: 200, body: body)
        }
    }

    /// Back-compat shim so older callers still compile.
    func respondToPermission(requestId: String, allow: Bool) {
        respondToPermission(requestId: requestId, decision: allow ? .allow : .deny)
    }

    /// Build the exact JSON that a PermissionRequest hook must return to Claude Code.
    /// Schema reference (Claude Code 2.1.x src/types/hooks.ts):
    ///   hookSpecificOutput.hookEventName = "PermissionRequest"
    ///   hookSpecificOutput.decision.behavior = "allow" | "deny"
    ///   (allow) decision.updatedPermissions?: PermissionUpdate[]
    ///   (deny)  decision.message?: string
    static func buildPermissionHookOutput(
        decision: PermissionDecisionKind,
        suggestion: PermissionSuggestion?
    ) -> String {
        var decisionObj: [String: Any] = [:]
        switch decision {
        case .allow:
            decisionObj["behavior"] = "allow"
        case .allowAlways:
            decisionObj["behavior"] = "allow"
            if let suggestion = suggestion {
                // Claude Code's permissionUpdateSchema shape: addRules with rules array
                let rules: [[String: String]] = suggestion.rules.map { rule in
                    ["toolName": rule.toolName, "ruleContent": rule.ruleContent]
                }
                let update: [String: Any] = [
                    "type": "addRules",
                    "rules": rules,
                    "behavior": "allow",
                    "destination": suggestion.destination
                ]
                decisionObj["updatedPermissions"] = [update]
            }
        case .deny:
            decisionObj["behavior"] = "deny"
            decisionObj["message"] = "Denied in Coder Island"
        }

        let output: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decisionObj
            ]
        ]

        if let data = try? JSONSerialization.data(withJSONObject: output, options: []),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }

    func respondToAsk(requestId: String, answer: String) {
        queue.async {
            guard let pending = self.pendingRequests.removeValue(forKey: requestId) else { return }
            let escaped = answer
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            // Return both the result and the original answer for the hook script
            let responseBody = "{\"result\":\"\(escaped)\"}"
            self.sendResponse(connection: pending.connection, statusCode: 200, body: responseBody)
        }
    }

    /// Store the header for a pending ask so the hook can use it in the response
    private var askHeaders = [String: String]()

    func setAskHeader(requestId: String, header: String) {
        askHeaders[requestId] = header
    }

    // MARK: - HTTP response

    private func sendResponse(connection: NWConnection, statusCode: Int, body: String) {
        let status = statusCode == 200 ? "200 OK" : "\(statusCode) Error"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        let data = response.data(using: .utf8)!
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Helpers

    private func describeToolInput(tool: String, input: [String: Any]) -> String {
        switch tool {
        case "Bash":
            if let cmd = input["command"] as? String { return "$ \(cmd)" }
            return "Run command"
        case "Write":
            return "Write \(shortPath(input["file_path"] as? String))"
        case "Edit", "MultiEdit":
            return "Edit \(shortPath(input["file_path"] as? String))"
        case "Read":
            return "Read \(shortPath(input["file_path"] as? String))"
        case "NotebookEdit":
            return "Edit notebook \(shortPath(input["notebook_path"] as? String))"
        case "Glob":
            return "Glob \(input["pattern"] as? String ?? "")"
        case "Grep":
            let pattern = input["pattern"] as? String ?? ""
            let path = input["path"] as? String ?? ""
            return path.isEmpty ? "Grep \"\(pattern)\"" : "Grep \"\(pattern)\" in \(shortPath(path))"
        case "WebFetch":
            if let url = input["url"] as? String {
                let prompt = input["prompt"] as? String ?? ""
                return prompt.isEmpty ? "Fetch \(url)" : "Fetch \(url) — \(prompt)"
            }
            return "Fetch URL"
        case "WebSearch":
            return "Search: \(input["query"] as? String ?? "")"
        case "Task":
            if let desc = input["description"] as? String {
                let prompt = (input["prompt"] as? String) ?? ""
                return prompt.isEmpty ? "Agent: \(desc)" : "Agent: \(desc) — \(prompt)"
            }
            return "Run subagent"
        default:
            // Fallback: show any short scalar fields so we don't just say the tool name
            let scalars = input.compactMap { key, value -> String? in
                if let s = value as? String, !s.isEmpty { return "\(key)=\(s)" }
                return nil
            }
            let joined = scalars.prefix(3).joined(separator: " ")
            return joined.isEmpty ? tool : "\(tool) \(joined)"
        }
    }

    /// Append raw hook payloads to ~/Library/Logs/CoderIsland/hook-payloads.log for inspection.
    static func dumpPayload(path: String, body: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CoderIsland", isDirectory: true)
            .appendingPathComponent("hook-payloads.log")
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "\(ts) \(path)\n\(body)\n---\n"
        guard let data = line.data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {}
    }

    private func shortPath(_ path: String?) -> String {
        guard let path = path, !path.isEmpty else { return "file" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Data models

struct PermissionRequest: Identifiable {
    let id: String
    let sessionId: String
    let toolName: String
    let description: String
    let toolInput: [String: Any]
    /// The cwd of the Claude Code session — used when writing project-local settings.
    var cwd: String = ""
    /// Suggestions from Claude Code about what "allow and don't ask again" should add.
    var allowSuggestion: PermissionSuggestion? = nil
}

/// A single persist-rule suggestion from Claude Code's PermissionRequest hook payload.
struct PermissionSuggestion {
    let destination: String  // e.g. "localSettings"
    let behavior: String     // e.g. "allow"
    let rules: [(toolName: String, ruleContent: String)]

    /// The human-readable tail of the first rule, used in button labels.
    /// e.g. "WebFetch domain:www.baidu.com" → "www.baidu.com"
    var displayHint: String {
        guard let first = rules.first else { return "" }
        let content = first.ruleContent
        if content.isEmpty { return first.toolName }
        // Strip common prefixes like "domain:" or "path:"
        if let colonIdx = content.firstIndex(of: ":") {
            return String(content[content.index(after: colonIdx)...])
        }
        return content
    }

    /// Rules formatted for Claude Code's `permissions.allow` array in settings.
    /// Each entry is `"<toolName>(<ruleContent>)"`, or `"<toolName>"` if no content.
    var formattedRules: [String] {
        rules.map { rule in
            rule.ruleContent.isEmpty ? rule.toolName : "\(rule.toolName)(\(rule.ruleContent))"
        }
    }
}

struct AskRequest: Identifiable {
    let id: String
    let sessionId: String
    let question: String
    let header: String
    var options: [(label: String, description: String)] = []
}

private struct PendingRequest {
    let connection: NWConnection
    let type: RequestType
    /// For permission requests, the suggestion payload we received — needed to
    /// build `updatedPermissions` when the user picks "allow and don't ask again".
    let allowSuggestion: PermissionSuggestion?
}

private enum RequestType {
    case permission
    case ask
}

/// What the user picked in the Coder Island permission banner.
enum PermissionDecisionKind {
    case allow        // once
    case allowAlways  // allow + persist via updatedPermissions
    case deny
}
