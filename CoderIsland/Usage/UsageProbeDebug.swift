import Foundation

/// One-shot debug runner: launches both probes in sequence and dumps
/// the captured text to `~/Library/Logs/CoderIsland/usage-probe-debug.log`.
/// Triggered by `CODER_ISLAND_DEBUG_USAGE_PROBE=1` at app launch.
///
/// We need this because the parser depends on knowing the exact format
/// of `claude /usage` and `codex /status` output, which varies by CLI
/// version. Run this once on a target machine, eyeball the log, write
/// the parser to match.
enum UsageProbeDebug {
    static func runOnce() async {
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CoderIsland", isDirectory: true)
            .appendingPathComponent("usage-probe-debug.log")
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Truncate so each run is self-contained.
        try? "".write(to: logURL, atomically: true, encoding: .utf8)

        var output = "=== UsageProbeDebug @ \(Date()) ===\n\n"

        // ---- Codex ----
        let codexBinary = findCodexBinary() ?? "/Applications/Codex.app/Contents/Resources/codex"
        output += "── Codex probe ──\n"
        output += "binary: \(codexBinary)\n"
        if FileManager.default.isExecutableFile(atPath: codexBinary) {
            let codexResult = await CLIStatusProbe.run(
                binary: codexBinary,
                args: ["-s", "read-only", "-a", "untrusted"],
                inputCommand: "/status",
                stopSubstrings: ["Weekly limit", "Failed to load"],
                timeout: 20
            )
            output += "timedOut: \(codexResult.timedOut), launchFailed: \(codexResult.launchFailed)\n"
            output += "---- raw stdout ----\n"
            output += codexResult.stdout
            output += "\n---- end ----\n\n"
        } else {
            output += "(binary not executable, skipping)\n\n"
        }

        // ---- Claude ----
        let claudeBinary = findClaudeBinary() ?? "/Users/luo/.local/bin/claude"
        output += "── Claude probe ──\n"
        output += "binary: \(claudeBinary)\n"
        if FileManager.default.isExecutableFile(atPath: claudeBinary) {
            let claudeResult = await CLIStatusProbe.run(
                binary: claudeBinary,
                args: [],
                inputCommand: "/usage",
                stopSubstrings: ["Current week", "Current session", "Failed to load usage"],
                timeout: 15
            )
            output += "timedOut: \(claudeResult.timedOut), launchFailed: \(claudeResult.launchFailed)\n"
            output += "---- raw stdout ----\n"
            output += claudeResult.stdout
            output += "\n---- end ----\n\n"
        } else {
            output += "(binary not executable, skipping)\n\n"
        }

        try? output.write(to: logURL, atomically: true, encoding: .utf8)
    }

    /// Find a working `codex` binary path, preferring the bundled
    /// Codex.app copy then PATH.
    static func findCodexBinary() -> String? {
        let candidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex",
            "\(NSHomeDirectory())/.local/bin/codex",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// Find a working `claude` binary path.
    static func findClaudeBinary() -> String? {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// Pick a working directory for the probe child. Both `claude` and
    /// `codex` behave badly when launched in `/` (Claude shows the
    /// "untrusted directory" gate; Codex pops a model picker). The
    /// safest cwd is one of the user's existing **trusted** Claude
    /// projects from `~/.claude.json` — Claude will skip the gate and
    /// Codex sees a real project layout.
    static func trustedProbeCWD() -> URL? {
        let claudeJsonPath = NSHomeDirectory() + "/.claude.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: claudeJsonPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = json["projects"] as? [String: [String: Any]] else {
            return nil
        }
        let fm = FileManager.default
        for (path, config) in projects {
            if config["hasTrustDialogAccepted"] as? Bool == true,
               fm.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}
