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
            let toolName = json["toolName"] as? String ?? "Unknown"
            let toolInput = json["toolInput"] as? [String: Any] ?? [:]
            let inputDesc = describeToolInput(tool: toolName, input: toolInput)

            let request = PermissionRequest(
                id: requestId,
                sessionId: sessionId,
                toolName: toolName,
                description: inputDesc,
                toolInput: toolInput
            )

            pendingRequests[requestId] = PendingRequest(connection: connection, type: .permission)

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

            pendingRequests[requestId] = PendingRequest(connection: connection, type: .ask)
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

    func respondToPermission(requestId: String, allow: Bool) {
        queue.async {
            guard let pending = self.pendingRequests.removeValue(forKey: requestId) else { return }
            let decision = allow ? "allow" : "deny"
            let responseBody = "{\"permissionDecision\":\"\(decision)\"}"
            self.sendResponse(connection: pending.connection, statusCode: 200, body: responseBody)
        }
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
            return input["command"] as? String ?? "Run command"
        case "Write":
            return "Write to \(input["file_path"] as? String ?? "file")"
        case "Edit":
            return "Edit \(input["file_path"] as? String ?? "file")"
        case "Read":
            return "Read \(input["file_path"] as? String ?? "file")"
        default:
            return "\(tool)"
        }
    }
}

// MARK: - Data models

struct PermissionRequest: Identifiable {
    let id: String
    let sessionId: String
    let toolName: String
    let description: String
    let toolInput: [String: Any]
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
}

private enum RequestType {
    case permission
    case ask
}
