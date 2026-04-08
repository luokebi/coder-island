import Foundation

/// A single Codex rollout parser regression test. Each entry is encoded as one
/// JSONL line and fed into `AgentManager.parseCodexState(from:)`.
struct CodexParserTestCase {
    let name: String
    let entries: [[String: Any]]
    let expectedStatus: AgentStatus
    let expectedSubtitleContains: String?
    let note: String?

    init(
        _ name: String,
        entries: [[String: Any]],
        expectedStatus: AgentStatus,
        expectedSubtitleContains: String? = nil,
        note: String? = nil
    ) {
        self.name = name
        self.entries = entries
        self.expectedStatus = expectedStatus
        self.expectedSubtitleContains = expectedSubtitleContains
        self.note = note
    }
}

/// Runs Codex-specific parser tests against synthetic rollout fragments and
/// appends a report to `~/Library/Logs/CoderIsland/codex-parser-tests.log`.
enum CodexParserTests {
    // MARK: - Entry builders

    private static func eventMsg(
        payload: [String: Any],
        ts: String = isoTS(0)
    ) -> [String: Any] {
        [
            "timestamp": ts,
            "type": "event_msg",
            "payload": payload
        ]
    }

    private static func taskStarted(ts: String = isoTS(0)) -> [String: Any] {
        eventMsg(payload: ["type": "task_started"], ts: ts)
    }

    private static func taskComplete(
        lastAgentMessage: String = "Done",
        ts: String = isoTS(0)
    ) -> [String: Any] {
        eventMsg(payload: [
            "type": "task_complete",
            "last_agent_message": lastAgentMessage
        ], ts: ts)
    }

    private static func turnAborted(
        reason: String,
        ts: String = isoTS(0)
    ) -> [String: Any] {
        eventMsg(payload: [
            "type": "turn_aborted",
            "reason": reason
        ], ts: ts)
    }

    private static func userMessage(
        _ message: String,
        ts: String = isoTS(0)
    ) -> [String: Any] {
        eventMsg(payload: [
            "type": "user_message",
            "message": message
        ], ts: ts)
    }

    private static func responseItemFunctionCall(
        name: String,
        ts: String = isoTS(0)
    ) -> [String: Any] {
        [
            "timestamp": ts,
            "type": "response_item",
            "payload": [
                "type": "function_call",
                "name": name,
                "arguments": "{}",
                "call_id": "call_\(UUID().uuidString.prefix(8))"
            ]
        ]
    }

    private static func isoTS(_ offsetSeconds: TimeInterval) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date().addingTimeInterval(offsetSeconds))
    }

    // MARK: - Test cases

    static func allCases() -> [CodexParserTestCase] {
        [
            CodexParserTestCase(
                "empty rollout",
                entries: [],
                expectedStatus: .idle,
                note: "no recent task events and no response items -> idle"
            ),

            CodexParserTestCase(
                "task_started only",
                entries: [
                    taskStarted(ts: isoTS(-5))
                ],
                expectedStatus: .running,
                expectedSubtitleContains: "Thinking",
                note: "active turn without a visible function_call keeps the generic thinking subtitle"
            ),

            CodexParserTestCase(
                "response_item fallback keeps session running",
                entries: [
                    responseItemFunctionCall(name: "shell_command", ts: isoTS(-2))
                ],
                expectedStatus: .running,
                expectedSubtitleContains: "shell_command",
                note: "task_started may be outside the tail; a recent function_call is still active work"
            ),

            CodexParserTestCase(
                "task_started plus latest function_call shows tool name",
                entries: [
                    taskStarted(ts: isoTS(-8)),
                    responseItemFunctionCall(name: "apply_patch", ts: isoTS(-1))
                ],
                expectedStatus: .running,
                expectedSubtitleContains: "apply_patch"
            ),

            CodexParserTestCase(
                "normal task_complete",
                entries: [
                    taskStarted(ts: isoTS(-10)),
                    taskComplete(lastAgentMessage: "All set", ts: isoTS(-1))
                ],
                expectedStatus: .justFinished,
                note: "task_complete is the authoritative completion signal in Codex rollouts"
            ),

            CodexParserTestCase(
                "task_complete followed by a new prompt stays running",
                entries: [
                    taskComplete(lastAgentMessage: "Done", ts: isoTS(-20)),
                    userMessage("Please continue", ts: isoTS(-5)),
                    responseItemFunctionCall(name: "shell_command", ts: isoTS(-1))
                ],
                expectedStatus: .running,
                expectedSubtitleContains: "shell_command",
                note: "a newer user_message overrides the earlier completion marker"
            ),

            CodexParserTestCase(
                "interrupted turn_aborted becomes idle",
                entries: [
                    taskStarted(ts: isoTS(-6)),
                    turnAborted(reason: "interrupted", ts: isoTS(-1))
                ],
                expectedStatus: .idle
            ),

            CodexParserTestCase(
                "non-interrupted turn_aborted becomes error",
                entries: [
                    taskStarted(ts: isoTS(-6)),
                    turnAborted(reason: "tool_error", ts: isoTS(-1))
                ],
                expectedStatus: .error,
                expectedSubtitleContains: "Aborted"
            )
        ]
    }

    // MARK: - Runner

    struct TestResult {
        let name: String
        let passed: Bool
        let expected: String
        let actual: String
        let note: String?
    }

    @discardableResult
    static func runAll() -> String {
        let manager = AgentManager()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("coder-island-codex-parser-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var results: [TestResult] = []
        for testCase in allCases() {
            results.append(runOne(manager: manager, tempDir: tempDir, testCase: testCase))
        }

        let passed = results.filter(\.passed).count
        let failed = results.count - passed
        let summary = "Codex parser tests: \(passed)/\(results.count) passed, \(failed) failed"

        writeReport(results: results, summary: summary)
        return summary
    }

    private static func runOne(
        manager: AgentManager,
        tempDir: URL,
        testCase: CodexParserTestCase
    ) -> TestResult {
        let fixtureURL = tempDir.appendingPathComponent("\(UUID().uuidString).jsonl")
        do {
            let lines = try testCase.entries.map { entry -> String in
                let data = try JSONSerialization.data(
                    withJSONObject: entry,
                    options: [.fragmentsAllowed]
                )
                guard let s = String(data: data, encoding: .utf8) else {
                    throw NSError(domain: "CodexParserTests", code: 0)
                }
                return s
            }
            try lines.joined(separator: "\n").write(
                to: fixtureURL,
                atomically: true,
                encoding: .utf8
            )
        } catch {
            return TestResult(
                name: testCase.name,
                passed: false,
                expected: "<fixture encoded ok>",
                actual: "fixture encode error: \(error)",
                note: testCase.note
            )
        }

        let state = manager.parseCodexState(from: fixtureURL.path)
        let actualDescription = "status=\(state.status.rawValue) subtitle=\(state.subtitle ?? "<nil>")"

        var passed = state.status == testCase.expectedStatus
        if let needle = testCase.expectedSubtitleContains,
           !(state.subtitle ?? "").contains(needle) {
            passed = false
        }

        var expectedDescription = "status=\(testCase.expectedStatus.rawValue)"
        if let needle = testCase.expectedSubtitleContains {
            expectedDescription += " subtitle contains '\(needle)'"
        }

        return TestResult(
            name: testCase.name,
            passed: passed,
            expected: expectedDescription,
            actual: actualDescription,
            note: testCase.note
        )
    }

    private static func writeReport(results: [TestResult], summary: String) {
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CoderIsland", isDirectory: true)
            .appendingPathComponent("codex-parser-tests.log")
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var lines: [String] = []
        lines.append("=== CodexParserTests.runAll @ \(ISO8601DateFormatter().string(from: Date())) ===")
        lines.append(summary)
        lines.append("")
        for result in results {
            let icon = result.passed ? "✅" : "❌"
            lines.append("\(icon) \(result.name)")
            lines.append("    expected: \(result.expected)")
            lines.append("    actual:   \(result.actual)")
            if let note = result.note {
                lines.append("    note:     \(note)")
            }
        }
        lines.append("")
        let content = lines.joined(separator: "\n") + "\n"

        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            if let data = content.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        }
    }
}
