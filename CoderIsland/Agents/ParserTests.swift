import Foundation

/// A single parser regression test: construct a jsonl transcript fragment
/// from `entries`, feed it to `AgentManager.parseLastMessage`, and assert
/// the returned `SessionState` matches the expectations. Each entry is a
/// `[String: Any]` that will be JSON-encoded as one line.
struct ParserTestCase {
    let name: String
    let entries: [[String: Any]]
    let expectedStatus: AgentStatus
    /// If set, the returned subtitle must contain this substring.
    let expectedSubtitleContains: String?
    /// Freeform note shown in the failure report.
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

/// A small pure helper regression test. These cover visibility logic
/// that doesn't need a jsonl fixture but still guards status handling.
struct LogicTestCase {
    let name: String
    let run: () -> Bool
    let note: String?

    init(_ name: String, note: String? = nil, run: @escaping () -> Bool) {
        self.name = name
        self.run = run
        self.note = note
    }
}

/// Runs every parser test case, writes a report to
/// `~/Library/Logs/CoderIsland/parser-tests.log`, and returns a
/// human-readable summary string.
enum ParserTests {
    // MARK: - Entry-building helpers
    //
    // Each helper returns a [String: Any] dictionary that matches the
    // shape Claude Code writes to its session jsonl. We only fill in the
    // fields our parser actually reads — everything else is omitted.

    private static func userText(_ text: String, ts: String = isoTS(0)) -> [String: Any] {
        return [
            "type": "user",
            "timestamp": ts,
            "message": [
                "role": "user",
                "content": [
                    ["type": "text", "text": text]
                ]
            ]
        ]
    }

    private static func userInterrupt(ts: String = isoTS(0)) -> [String: Any] {
        return [
            "type": "user",
            "timestamp": ts,
            "message": [
                "role": "user",
                "content": "[Request interrupted by user for tool use]"
            ]
        ]
    }

    private static func userToolResult(
        toolUseId: String,
        content: String = "ok",
        ts: String = isoTS(0)
    ) -> [String: Any] {
        return [
            "type": "user",
            "timestamp": ts,
            "message": [
                "role": "user",
                "content": [
                    [
                        "type": "tool_result",
                        "tool_use_id": toolUseId,
                        "content": content
                    ]
                ]
            ]
        ]
    }

    private static func assistantThinking(ts: String = isoTS(0)) -> [String: Any] {
        return [
            "type": "assistant",
            "timestamp": ts,
            "uuid": UUID().uuidString,
            "message": [
                "role": "assistant",
                "content": [
                    ["type": "thinking", "thinking": "hmm..."]
                ],
                "stop_reason": NSNull()
            ]
        ]
    }

    private static func assistantToolUse(
        name: String,
        input: [String: Any],
        id: String = "toolu_\(UUID().uuidString.prefix(8))",
        ts: String = isoTS(0)
    ) -> [String: Any] {
        return [
            "type": "assistant",
            "timestamp": ts,
            "uuid": UUID().uuidString,
            "message": [
                "role": "assistant",
                "content": [
                    [
                        "type": "tool_use",
                        "id": id,
                        "name": name,
                        "input": input
                    ]
                ],
                "stop_reason": "tool_use"
            ]
        ]
    }

    private static func assistantTextEndTurn(
        _ text: String,
        ts: String = isoTS(0)
    ) -> [String: Any] {
        return [
            "type": "assistant",
            "timestamp": ts,
            "uuid": UUID().uuidString,
            "message": [
                "role": "assistant",
                "content": [
                    ["type": "text", "text": text]
                ],
                "stop_reason": "end_turn"
            ]
        ]
    }

    /// Claude Code bug case: the final text response is written with a
    /// NULL stop_reason instead of "end_turn". The content is still a
    /// real text block — this should be treated as finished.
    private static func assistantTextNullStop(
        _ text: String,
        ts: String = isoTS(0)
    ) -> [String: Any] {
        return [
            "type": "assistant",
            "timestamp": ts,
            "uuid": UUID().uuidString,
            "message": [
                "role": "assistant",
                "content": [
                    ["type": "text", "text": text]
                ],
                "stop_reason": NSNull()
            ]
        ]
    }

    private static func sidechainAssistantEndTurn(
        _ text: String,
        ts: String = isoTS(0)
    ) -> [String: Any] {
        return [
            "type": "assistant",
            "timestamp": ts,
            "isSidechain": true,
            "uuid": UUID().uuidString,
            "message": [
                "role": "assistant",
                "content": [
                    ["type": "text", "text": text]
                ],
                "stop_reason": "end_turn"
            ]
        ]
    }

    /// Claude Code writes this system entry after its Stop hooks finish
    /// running at the end of a turn. Its presence at the tail is our
    /// authoritative "turn ended" signal, independent of stop_reason.
    private static func systemStopHookSummary(ts: String = isoTS(0)) -> [String: Any] {
        return [
            "type": "system",
            "subtype": "stop_hook_summary",
            "timestamp": ts,
            "hookCount": 0,
            "preventedContinuation": false
        ]
    }

    private static func systemApiError(
        code: String,
        ts: String = isoTS(0)
    ) -> [String: Any] {
        return [
            "type": "system",
            "subtype": "api_error",
            "level": "error",
            "cause": [
                "code": code,
                "path": "https://api.anthropic.com/v1/messages?beta=true",
                "errno": 0
            ],
            "error": [
                "type": NSNull(),
                "cause": [
                    "code": code,
                    "path": "https://api.anthropic.com/v1/messages?beta=true",
                    "errno": 0
                ]
            ],
            "timestamp": ts
        ]
    }

    private static func assistantApiError(
        _ text: String,
        error: String,
        ts: String = isoTS(0)
    ) -> [String: Any] {
        return [
            "type": "assistant",
            "timestamp": ts,
            "isApiErrorMessage": true,
            "error": error,
            "message": [
                "id": UUID().uuidString,
                "model": "<synthetic>",
                "role": "assistant",
                "content": [
                    ["type": "text", "text": text]
                ],
                "stop_reason": "stop_sequence",
                "stop_sequence": "",
                "type": "message"
            ]
        ]
    }

    /// Intermediate assistant text message — Claude Code writes these
    /// between tool calls with `stop_reason: null` (e.g. "let me check
    /// X..." narration before the next Bash/Edit). Used to verify our
    /// parser does NOT treat these as "turn ended".
    private static func assistantIntermediateText(
        _ text: String,
        ts: String = isoTS(0)
    ) -> [String: Any] {
        return [
            "type": "assistant",
            "timestamp": ts,
            "uuid": UUID().uuidString,
            "message": [
                "role": "assistant",
                "content": [
                    ["type": "text", "text": text]
                ],
                "stop_reason": NSNull()
            ]
        ]
    }

    private static func isoTS(_ offsetSeconds: TimeInterval) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date().addingTimeInterval(offsetSeconds))
    }

    // MARK: - Test cases

    static func allCases() -> [ParserTestCase] {
        var cases: [ParserTestCase] = []

        cases.append(ParserTestCase(
            "empty transcript",
            entries: [],
            expectedStatus: .running,
            note: "no user/assistant yet → default running"
        ))

        cases.append(ParserTestCase(
            "user prompt only",
            entries: [userText("你好", ts: isoTS(-10))],
            expectedStatus: .running,
            expectedSubtitleContains: "Thinking",
            note: "user message + no assistant response yet"
        ))

        cases.append(ParserTestCase(
            "assistant running a Bash tool",
            entries: [
                userText("run ls", ts: isoTS(-10)),
                assistantToolUse(
                    name: "Bash",
                    input: ["command": "ls -la"],
                    ts: isoTS(-2)
                )
            ],
            expectedStatus: .running,
            expectedSubtitleContains: "ls -la"
        ))

        cases.append(ParserTestCase(
            "tool_result after a Bash tool_use",
            entries: [
                userText("run ls", ts: isoTS(-10)),
                assistantToolUse(
                    name: "Bash",
                    input: ["command": "ls -la"],
                    id: "toolu_abc",
                    ts: isoTS(-5)
                ),
                userToolResult(toolUseId: "toolu_abc", ts: isoTS(-4))
            ],
            expectedStatus: .running,
            expectedSubtitleContains: "ls -la",
            note: "still running — tool finished but turn not yet ended"
        ))

        cases.append(ParserTestCase(
            "normal turn end with end_turn",
            entries: [
                userText("你好", ts: isoTS(-10)),
                assistantTextEndTurn("你好！有什么可以帮你的？", ts: isoTS(-5))
            ],
            expectedStatus: .justFinished,
            note: "standard case: text + stop_reason=end_turn"
        ))

        // The Claude Code bug we just fixed (codes session): final text
        // written with stop_reason=null, but the authoritative turn-end
        // signal is the trailing `system stop_hook_summary` entry.
        cases.append(ParserTestCase(
            "BUG FIX: trailing stop_hook_summary treats turn as finished",
            entries: [
                userText("nvm list", ts: isoTS(-60)),
                assistantToolUse(
                    name: "Bash",
                    input: ["command": "source ~/.nvm/nvm.sh && nvm list"],
                    id: "toolu_nvm",
                    ts: isoTS(-55)
                ),
                userToolResult(toolUseId: "toolu_nvm", ts: isoTS(-50)),
                assistantTextNullStop(
                    "已安装的 Node 版本:\n- v20.9.0\n- v24.13.0",
                    ts: isoTS(-45)
                ),
                systemStopHookSummary(ts: isoTS(-44))
            ],
            expectedStatus: .justFinished,
            note: "Claude Code sometimes writes final text with null stop_reason — rely on trailing stop_hook_summary"
        ))

        cases.append(ParserTestCase(
            "intermediate thinking should NOT be treated as finished",
            entries: [
                userText("hmm", ts: isoTS(-10)),
                assistantThinking(ts: isoTS(-5))
            ],
            expectedStatus: .running,
            note: "thinking-only block with null stop_reason → keep scanning, no text yet"
        ))

        // Regression: intermediate narration text between tool calls
        // MUST NOT trigger "turn finished". This was the bug in the
        // previous fix — Claude's mid-turn text was being mistaken for
        // the final response, playing the completion sound at every
        // message the user saw.
        cases.append(ParserTestCase(
            "REGRESSION: intermediate text between tool calls stays running",
            entries: [
                userText("analyze this", ts: isoTS(-30)),
                assistantIntermediateText(
                    "让我先看下这个文件",
                    ts: isoTS(-20)
                ),
                assistantToolUse(
                    name: "Read",
                    input: ["file_path": "/tmp/x.txt"],
                    id: "toolu_r",
                    ts: isoTS(-1)
                )
            ],
            expectedStatus: .running,
            expectedSubtitleContains: "Read",
            note: "Claude writes narration text with stop_reason=null between tool calls — must NOT be treated as finished without a trailing stop_hook_summary"
        ))

        // The stop_hook_summary must be at the TAIL to count. If there
        // are further user/assistant entries after it, the turn has
        // since resumed (or it was a subagent summary) and should be
        // ignored.
        cases.append(ParserTestCase(
            "stop_hook_summary followed by new user prompt → running",
            entries: [
                assistantTextEndTurn("done!", ts: isoTS(-60)),
                systemStopHookSummary(ts: isoTS(-55)),
                userText("another question", ts: isoTS(-5))
            ],
            expectedStatus: .running,
            expectedSubtitleContains: "Thinking",
            note: "new user message overrides the earlier stop_hook_summary"
        ))

        cases.append(ParserTestCase(
            "synthetic api error at tail becomes error",
            entries: [
                userText("continue", ts: isoTS(-20)),
                systemApiError(code: "UNKNOWN_CERTIFICATE_VERIFICATION_ERROR", ts: isoTS(-5)),
                assistantApiError(
                    "Your account does not have access to Claude Code. Please run /login.",
                    error: "authentication_failed",
                    ts: isoTS(-4)
                )
            ],
            expectedStatus: .error,
            expectedSubtitleContains: "/login",
            note: "Claude can end a turn with api_error + synthetic assistant error instead of stop_hook_summary"
        ))

        cases.append(ParserTestCase(
            "interrupted user message",
            entries: [
                userText("go", ts: isoTS(-20)),
                assistantToolUse(
                    name: "Bash",
                    input: ["command": "sleep 100"],
                    ts: isoTS(-15)
                ),
                userInterrupt(ts: isoTS(-10))
            ],
            expectedStatus: .idle,
            note: "user interrupt marker → .idle"
        ))

        cases.append(ParserTestCase(
            "sidechain end_turn does NOT leak into main session",
            entries: [
                userText("run sub", ts: isoTS(-5)),
                assistantToolUse(
                    name: "Bash",
                    input: ["command": "ls"],
                    ts: isoTS(-2)  // recent — avoid stale-tool_use permission heuristic
                ),
                // Subagent finishes its own turn
                sidechainAssistantEndTurn("sub done", ts: isoTS(-1))
            ],
            expectedStatus: .running,
            expectedSubtitleContains: "ls",
            note: "sidechain end_turn should be filtered — parent is still mid-tool"
        ))

        return cases
    }

    static func logicCases() -> [LogicTestCase] {
        let now = Date()

        return [
            LogicTestCase(
                "Codex desktop running state stays visible",
                note: "running/waiting should never depend on startup grace"
            ) {
                AgentManager.shouldShowDesktopCodexThread(
                    state: AgentManager.SessionState(status: .running),
                    threadUpdatedAt: nil,
                    now: now,
                    monitorStartedAt: now.addingTimeInterval(-60)
                )
            },
            LogicTestCase(
                "Codex desktop startup grace shows recently updated finished thread",
                note: "avoids a startup gap before the active rollout writes task_started"
            ) {
                AgentManager.shouldShowDesktopCodexThread(
                    state: AgentManager.SessionState(status: .justFinished),
                    threadUpdatedAt: now.addingTimeInterval(-3),
                    now: now,
                    monitorStartedAt: now.addingTimeInterval(-2)
                )
            },
            LogicTestCase(
                "Codex desktop recent finished thread survives startup grace",
                note: "the newest desktop thread should remain visible after completion"
            ) {
                AgentManager.shouldShowDesktopCodexThread(
                    state: AgentManager.SessionState(status: .justFinished),
                    threadUpdatedAt: now.addingTimeInterval(-3),
                    now: now,
                    monitorStartedAt: now.addingTimeInterval(-30)
                )
            },
            LogicTestCase(
                "Codex desktop old finished thread still stays visible",
                note: "the newest desktop thread should not disappear just because it has been finished for a while"
            ) {
                AgentManager.shouldShowDesktopCodexThread(
                    state: AgentManager.SessionState(status: .justFinished),
                    threadUpdatedAt: now.addingTimeInterval(-300),
                    now: now,
                    monitorStartedAt: now.addingTimeInterval(-30)
                )
            },
            LogicTestCase(
                "Codex desktop error thread also stays visible",
                note: "the newest desktop thread should keep showing an error state until replaced"
            ) {
                AgentManager.shouldShowDesktopCodexThread(
                    state: AgentManager.SessionState(status: .error),
                    threadUpdatedAt: now.addingTimeInterval(-600),
                    now: now,
                    monitorStartedAt: now.addingTimeInterval(-2)
                )
            }
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

    /// Run all parser test cases against a fresh AgentManager instance.
    /// Writes a detailed log and returns a short summary suitable for
    /// printing to the console or a dialog.
    @discardableResult
    static func runAll() -> String {
        let manager = AgentManager()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("coder-island-parser-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var results: [TestResult] = []
        for testCase in allCases() {
            let result = runOne(manager: manager, tempDir: tempDir, testCase: testCase)
            results.append(result)
        }
        for testCase in logicCases() {
            results.append(runLogicOne(testCase: testCase))
        }

        let passed = results.filter(\.passed).count
        let failed = results.count - passed
        let summary = "Parser tests: \(passed)/\(results.count) passed, \(failed) failed"

        writeReport(results: results, summary: summary)
        return summary
    }

    private static func runOne(
        manager: AgentManager,
        tempDir: URL,
        testCase: ParserTestCase
    ) -> TestResult {
        let fixtureURL = tempDir.appendingPathComponent("\(UUID().uuidString).jsonl")
        do {
            let lines = try testCase.entries.map { entry -> String in
                let data = try JSONSerialization.data(
                    withJSONObject: entry,
                    options: [.fragmentsAllowed]
                )
                guard let s = String(data: data, encoding: .utf8) else {
                    throw NSError(domain: "ParserTests", code: 0)
                }
                return s
            }
            let body = lines.joined(separator: "\n")
            try body.write(to: fixtureURL, atomically: true, encoding: .utf8)
        } catch {
            return TestResult(
                name: testCase.name,
                passed: false,
                expected: "<fixture encoded ok>",
                actual: "fixture encode error: \(error)",
                note: testCase.note
            )
        }

        let state = manager.parseLastMessage(from: fixtureURL)
        let actualDescription: String = {
            let sub = state.subtitle ?? "<nil>"
            return "status=\(state.status.rawValue) subtitle=\(sub)"
        }()

        var passed = state.status == testCase.expectedStatus
        if let needle = testCase.expectedSubtitleContains {
            if !(state.subtitle ?? "").contains(needle) {
                passed = false
            }
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
            .appendingPathComponent("parser-tests.log")
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var lines: [String] = []
        lines.append("=== ParserTests.runAll @ \(ISO8601DateFormatter().string(from: Date())) ===")
        lines.append(summary)
        lines.append("")
        for r in results {
            let icon = r.passed ? "✅" : "❌"
            lines.append("\(icon) \(r.name)")
            lines.append("    expected: \(r.expected)")
            lines.append("    actual:   \(r.actual)")
            if let note = r.note {
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

    private static func runLogicOne(testCase: LogicTestCase) -> TestResult {
        let passed = testCase.run()
        return TestResult(
            name: testCase.name,
            passed: passed,
            expected: "logic helper returns true",
            actual: passed ? "logic helper returned true" : "logic helper returned false",
            note: testCase.note
        )
    }
}
