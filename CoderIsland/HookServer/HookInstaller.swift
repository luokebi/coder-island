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
    private let eventScript = "coder-island-event"
    private let statusLineScript = "coder-island-statusline"

    /// Cache directory for statusLine data (rate limits etc.)
    static let cacheDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".coder-island/cache")
    }()
    /// Path where the statusLine script writes Claude rate_limits JSON.
    static let claudeRateLimitsCache: URL = {
        cacheDir.appendingPathComponent("claude-rl.json")
    }()

    /// Claude Code lifecycle hook event names. The event relay script is
    /// registered under each of these keys in ~/.claude/settings.json.
    /// Keep in sync with AgentManager.applyHookEvent.
    private let eventHookNames: [String] = [
        "PreToolUse",
        "PostToolUse",
        "PostToolUseFailure",
        "UserPromptSubmit",
        "Stop",
        "StopFailure",
    ]

    /// Codex hook event names (from codex-rs/app-server-protocol HookEventName).
    /// Codex only exposes 5 events total — keys are PascalCase in the JSON
    /// hooks file (same as Claude). PreToolUse/PostToolUse currently only
    /// fire for the Bash tool inside Codex.
    private let codexEventHookNames: [String] = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "Stop",
    ]

    /// Path to Codex's hook configuration (separate from Claude Code's
    /// ~/.claude/settings.json). Codex reads this when `codex_hooks = true`
    /// is set in ~/.codex/config.toml.
    private var codexHooksFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/hooks.json")
    }

    private init() {}

    func install() {
        createHookScripts()
        registerInClaudeSettings()
        registerInCodexSettings()
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

        // Generic event relay: forwards PreToolUse / PostToolUse /
        // PostToolUseFailure / Stop / StopFailure / UserPromptSubmit payloads
        // to HookServer /event. These are fire-and-forget from Claude Code's
        // perspective — we reply with an empty `{}` hookSpecificOutput so
        // Claude never blocks on us. Short timeout so a crashed app doesn't
        // slow the user down.
        let eventContent = """
        #!/bin/bash
        # Coder Island - Lifecycle Event Relay
        INPUT=$(cat)
        RESPONSE=$(echo "$INPUT" | curl -s -X POST http://localhost:\(HookServer.port)/event \\
            -H "Content-Type: application/json" \\
            -d @- \\
            --max-time 3 2>/dev/null)
        if [ $? -eq 0 ] && [ -n "$RESPONSE" ]; then
            echo "$RESPONSE"
        fi
        exit 0
        """

        // StatusLine script: Claude Code calls this on every assistant
        // message with JSON on stdin containing rate_limits. We extract
        // and cache it so the app can read usage without spawning a
        // child process (which would trigger TCC folder prompts).
        let cacheDir = HookInstaller.cacheDir.path
        let rlCache = HookInstaller.claudeRateLimitsCache.path
        let statusLineContent = """
        #!/bin/bash
        input=$(cat)
        _rl=$(echo "$input" | python3 -c "
        import sys,json
        try:
            d=json.load(sys.stdin)
            rl=d.get('rate_limits')
            if rl: print(json.dumps(rl))
        except: pass
        " 2>/dev/null)
        if [ -n "$_rl" ]; then
            mkdir -p "\(cacheDir)"
            echo "$_rl" > "\(rlCache)"
        fi
        """

        let permissionPath = hookDir.appendingPathComponent(permissionScript)
        let askPath = hookDir.appendingPathComponent(askScript)
        let eventPath = hookDir.appendingPathComponent(eventScript)
        let statusLinePath = hookDir.appendingPathComponent(statusLineScript)

        try? permissionContent.write(to: permissionPath, atomically: true, encoding: .utf8)
        try? askContent.write(to: askPath, atomically: true, encoding: .utf8)
        try? eventContent.write(to: eventPath, atomically: true, encoding: .utf8)
        try? statusLineContent.write(to: statusLinePath, atomically: true, encoding: .utf8)

        chmod(permissionPath.path, 0o755)
        chmod(askPath.path, 0o755)
        chmod(eventPath.path, 0o755)
        chmod(statusLinePath.path, 0o755)

        debugLog("[HookInstaller] Scripts installed at \(hookDir.path)")
    }

    /// Rewrite the statusLine script to chain to an existing command
    /// (e.g. vibe-island's statusLine) so both apps receive the data.
    /// Also saves the original command so uninstall can restore it.
    private func rewriteStatusLineScript(chainTo originalCmd: String) {
        let cacheDir = HookInstaller.cacheDir.path
        let rlCache = HookInstaller.claudeRateLimitsCache.path
        let chainFile = hookDir.appendingPathComponent("statusline-chain-to")

        // Save original command for uninstall restore
        try? originalCmd.write(to: chainFile, atomically: true, encoding: .utf8)

        let content = """
        #!/bin/bash
        input=$(cat)
        _rl=$(echo "$input" | python3 -c "
        import sys,json
        try:
            d=json.load(sys.stdin)
            rl=d.get('rate_limits')
            if rl: print(json.dumps(rl))
        except: pass
        " 2>/dev/null)
        if [ -n "$_rl" ]; then
            mkdir -p "\(cacheDir)"
            echo "$_rl" > "\(rlCache)"
        fi
        # Chain to original statusLine
        echo "$input" | \(originalCmd)
        """

        let path = hookDir.appendingPathComponent(statusLineScript)
        try? content.write(to: path, atomically: true, encoding: .utf8)
        chmod(path.path, 0o755)
        debugLog("[HookInstaller] statusLine chained to \(originalCmd)")
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

        let eventHook: [String: Any] = [
            "type": "command",
            "command": hookDir.appendingPathComponent(eventScript).path,
            "timeout": 5
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

        // Register the event relay under each lifecycle hook key. Matcher `*`
        // catches every tool for the tool-scoped events; Stop/StopFailure/
        // UserPromptSubmit don't use matchers but the field is harmless.
        for key in eventHookNames {
            var entries = hooks[key] as? [[String: Any]] ?? []
            // Drop any previous coder-island entries so repeat installs don't accumulate.
            entries.removeAll { entry in
                (entry["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains("coder-island") == true } ?? false
            }
            entries.append([
                "matcher": "*",
                "hooks": [eventHook]
            ])
            hooks[key] = entries
        }

        // Clean up legacy Elicitation entries (superseded).
        if var entries = hooks["Elicitation"] as? [[String: Any]] {
            entries.removeAll { entry in
                (entry["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains("coder-island") == true } ?? false
            }
            if entries.isEmpty { hooks.removeValue(forKey: "Elicitation") } else { hooks["Elicitation"] = entries }
        }

        settings["hooks"] = hooks

        // Register our statusLine wrapper. If another statusLine already
        // exists (e.g. vibe-island), we save its command and chain to it
        // from our script so both work.
        let statusLinePath = hookDir.appendingPathComponent(statusLineScript).path
        let existingStatusLine = settings["statusLine"] as? [String: Any]
        let existingCmd = existingStatusLine?["command"] as? String
        if existingCmd != nil && existingCmd?.contains("coder-island") != true {
            // Rewrite our script to chain to the original
            rewriteStatusLineScript(chainTo: existingCmd!)
        }
        settings["statusLine"] = [
            "type": "command",
            "command": statusLinePath
        ]

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
            unregisterFromCodexSettings()
            return
        }

        if var hooks = settings["hooks"] as? [String: Any] {
            let keysToClean: [String] = ["PermissionRequest", "Elicitation"] + eventHookNames
            for key in keysToClean {
                if var entries = hooks[key] as? [[String: Any]] {
                    entries.removeAll { entry in
                        (entry["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains("coder-island") == true } ?? false
                    }
                    if entries.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = entries }
                }
            }

            if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        }

        // Restore original statusLine or remove ours
        if let sl = settings["statusLine"] as? [String: Any],
           let cmd = sl["command"] as? String,
           cmd.contains("coder-island") {
            let chainFile = hookDir.appendingPathComponent("statusline-chain-to")
            if let original = try? String(contentsOf: chainFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               !original.isEmpty {
                settings["statusLine"] = ["type": "command", "command": original]
            } else {
                settings.removeValue(forKey: "statusLine")
            }
            try? FileManager.default.removeItem(at: chainFile)
        }

        if let writeData = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? writeData.write(to: settingsPath)
            debugLog("[HookInstaller] Hooks removed from settings.json")
        }

        unregisterFromCodexSettings()
    }

    // MARK: - Codex hook registration

    /// Append coder-island's event relay entries to ~/.codex/hooks.json while
    /// preserving any existing entries (e.g. vibe-island hooks installed by
    /// another app). Safe to call repeatedly — we dedupe by command path.
    private func registerInCodexSettings() {
        let hooksPath = codexHooksFileURL
        let dir = hooksPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: hooksPath),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]

        let eventHook: [String: Any] = [
            "type": "command",
            "command": hookDir.appendingPathComponent(eventScript).path,
            "timeout": 5
        ]

        for key in codexEventHookNames {
            var entries = hooks[key] as? [[String: Any]] ?? []
            // Remove any previous coder-island entries under this key so
            // repeat installs don't accumulate duplicates. vibe-island and
            // other third-party entries are preserved.
            entries.removeAll { entry in
                (entry["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains("coder-island") == true } ?? false
            }
            // PreToolUse / PostToolUse / SessionStart support matchers
            // (regex); UserPromptSubmit and Stop ignore the field. Use "*"
            // for the matcher-aware events and omit it otherwise — matches
            // Codex's own documented shape.
            var entry: [String: Any] = ["hooks": [eventHook]]
            if key == "PreToolUse" || key == "PostToolUse" || key == "SessionStart" {
                entry["matcher"] = "*"
            }
            entries.append(entry)
            hooks[key] = entries
        }

        root["hooks"] = hooks

        if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: hooksPath)
            debugLog("[HookInstaller] Codex hooks registered in \(hooksPath.path)")
        }
    }

    /// Remove coder-island's entries from ~/.codex/hooks.json while leaving
    /// third-party entries (vibe-island etc.) alone.
    private func unregisterFromCodexSettings() {
        let hooksPath = codexHooksFileURL
        guard let data = try? Data(contentsOf: hooksPath),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if var hooks = root["hooks"] as? [String: Any] {
            for key in codexEventHookNames {
                if var entries = hooks[key] as? [[String: Any]] {
                    entries.removeAll { entry in
                        (entry["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains("coder-island") == true } ?? false
                    }
                    if entries.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = entries }
                }
            }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        }

        if let writeData = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? writeData.write(to: hooksPath)
            debugLog("[HookInstaller] Codex hooks removed from \(hooksPath.path)")
        }
    }

    private func chmod(_ path: String, _ mode: mode_t) {
        Foundation.chmod(path, mode)
    }
}
