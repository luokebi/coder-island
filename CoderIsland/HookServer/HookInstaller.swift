import Foundation

/// Installs Claude Code hooks to communicate with Coder Island
class HookInstaller {
    static let shared = HookInstaller()

    private let hookDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".coder-island/hooks")
    }()

    private let permissionScript = "coder-island-permission"
    private let askScript = "coder-island-ask"

    private init() {}

    func install() {
        createHookScripts()
        registerInClaudeSettings()
    }

    private func createHookScripts() {
        try? FileManager.default.createDirectory(at: hookDir, withIntermediateDirectories: true)

        let permissionContent = """
        #!/bin/bash
        # Coder Island - Permission Hook
        LOG="$HOME/Library/Logs/CoderIsland/permission-hook.log"
        mkdir -p "$(dirname "$LOG")"
        {
          echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
          echo "pid=$$"
        } >> "$LOG"

        INPUT=$(cat)
        echo "INPUT: $INPUT" >> "$LOG"

        # Skip AskUserQuestion — handled by the separate ask hook
        TOOL=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('toolName', d.get('tool_name','')))" 2>/dev/null)
        echo "TOOL=$TOOL" >> "$LOG"
        if [ "$TOOL" = "AskUserQuestion" ]; then
            echo "skip (ask)" >> "$LOG"
            exit 0
        fi

        # The HookServer builds the full hook output JSON for us — we just echo it verbatim.
        RESPONSE=$(echo "$INPUT" | curl -s -X POST http://localhost:\(HookServer.port)/permission \\
            -H "Content-Type: application/json" \\
            -d @- \\
            --max-time 600 2>>"$LOG")
        CURL_EXIT=$?
        echo "curl_exit=$CURL_EXIT" >> "$LOG"
        echo "RESPONSE: $RESPONSE" >> "$LOG"

        if [ $CURL_EXIT -eq 0 ] && [ -n "$RESPONSE" ]; then
            echo "$RESPONSE"
        else
            echo "no response; letting claude prompt normally" >> "$LOG"
        fi
        exit 0
        """

        // AskUserQuestion hook: intercepts elicitation, sends to app, returns user's choice
        let askContent = """
        #!/bin/bash
        # Coder Island - AskUserQuestion Hook
        # Intercepts Claude's questions, shows in Coder Island UI, returns user selection
        INPUT=$(cat)

        # Check if this is an AskUserQuestion by looking for "questions" in the input
        HAS_QUESTIONS=$(echo "$INPUT" | python3 -c "
        import sys,json
        try:
            d=json.load(sys.stdin)
            # Check tool_input or direct questions field
            ti = d.get('tool_input', d)
            if 'questions' in ti:
                print('yes')
            else:
                print('no')
        except:
            print('no')
        " 2>/dev/null)

        if [ "$HAS_QUESTIONS" != "yes" ]; then
            exit 0
        fi

        # Send to Coder Island app and wait for answer
        RESPONSE=$(echo "$INPUT" | curl -s -X POST http://localhost:\(HookServer.port)/ask \\
            -H "Content-Type: application/json" \\
            -d @- \\
            --max-time 300 2>/dev/null)

        if [ $? -eq 0 ] && [ -n "$RESPONSE" ]; then
            echo "$RESPONSE"
            exit 0
        else
            exit 0
        fi
        """

        let permissionPath = hookDir.appendingPathComponent(permissionScript)
        let askPath = hookDir.appendingPathComponent(askScript)

        try? permissionContent.write(to: permissionPath, atomically: true, encoding: .utf8)
        try? askContent.write(to: askPath, atomically: true, encoding: .utf8)

        chmod(permissionPath.path, 0o755)
        chmod(askPath.path, 0o755)

        debugLog("[HookInstaller] Scripts installed at \(hookDir.path)")
    }

    private func registerInClaudeSettings() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let settingsPath = home.appendingPathComponent(".claude/settings.json")

        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsPath),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = existing
        }

        let askHook: [String: Any] = [
            "type": "command",
            "command": hookDir.appendingPathComponent(askScript).path,
            "timeout": 300
        ]

        let permissionHook: [String: Any] = [
            "type": "command",
            "command": hookDir.appendingPathComponent(permissionScript).path,
            "timeout": 300
        ]

        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        // PermissionRequest: ask hook for AskUserQuestion, permission hook for everything else.
        var permEntries = hooks["PermissionRequest"] as? [[String: Any]] ?? []
        permEntries.removeAll { entry in
            (entry["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains("coder-island") == true } ?? false
        }
        permEntries.insert([
            "matcher": "AskUserQuestion",
            "hooks": [askHook]
        ], at: 0)
        permEntries.insert([
            "matcher": "Bash|Edit|MultiEdit|Write|NotebookEdit|Read|Glob|Grep|Task|WebFetch|WebSearch",
            "hooks": [permissionHook]
        ], at: 1)
        hooks["PermissionRequest"] = permEntries
        // Clean up old PreToolUse and Elicitation entries
        for key in ["PreToolUse", "Elicitation"] {
            if var entries = hooks[key] as? [[String: Any]] {
                entries.removeAll { entry in
                    (entry["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains("coder-island") == true } ?? false
                }
                if entries.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = entries }
            }
        }

        settings["hooks"] = hooks

        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: settingsPath)
            debugLog("[HookInstaller] Hooks registered in settings.json")
        }
    }

    func uninstall() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let settingsPath = home.appendingPathComponent(".claude/settings.json")

        guard let data = try? Data(contentsOf: settingsPath),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if var hooks = settings["hooks"] as? [String: Any] {
            // Remove our hooks from PermissionRequest, PreToolUse, Elicitation
            for key in ["PermissionRequest", "PreToolUse", "Elicitation"] {
                if var entries = hooks[key] as? [[String: Any]] {
                    entries.removeAll { entry in
                        (entry["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains("coder-island") == true } ?? false
                    }
                    if entries.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = entries }
                }
            }

            if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        }

        if let writeData = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? writeData.write(to: settingsPath)
            debugLog("[HookInstaller] Hooks removed from settings.json")
        }
    }

    private func chmod(_ path: String, _ mode: mode_t) {
        Foundation.chmod(path, mode)
    }
}
