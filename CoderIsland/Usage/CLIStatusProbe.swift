import Foundation
import Darwin

// `openpty` lives in libutil; declare its prototype so we don't need a
// bridging header. Same trick CodexBar uses.
@_silgen_name("openpty")
private func openpty(
    _ primary: UnsafeMutablePointer<Int32>,
    _ secondary: UnsafeMutablePointer<Int32>,
    _ name: UnsafeMutablePointer<CChar>?,
    _ termp: UnsafeMutablePointer<termios>?,
    _ winp: UnsafeMutablePointer<winsize>?
) -> Int32

/// Spawns a CLI agent (claude / codex) in a real PTY, sends it a slash
/// command (e.g. `/usage` or `/status`), reads stdout until any of the
/// expected stop substrings appears (or timeout), and returns the
/// captured text with ANSI escape sequences stripped.
///
/// Required because both `claude` and `codex` refuse to start when their
/// stdin isn't a TTY (`Error: stdin is not a terminal`). A plain
/// `Process` + `Pipe` won't work; the simpler `script(1)` wrapper also
/// fails because it doesn't respond to the cursor-position query the
/// CLIs send during startup. We DO respond to that query (with a fixed
/// `1;1R` report) so the CLI considers its terminal capabilities
/// negotiated and gets to the prompt where it can read our slash
/// command.
enum CLIStatusProbe {
    /// Set of PIDs currently owned by an in-flight probe. AgentManager
    /// reads this when scanning for Claude/Codex processes so it doesn't
    /// add our short-lived helper children as phantom sessions.
    private static let pidLock = NSLock()
    private static var _probePIDs = Set<pid_t>()

    static func currentProbePIDs() -> Set<pid_t> {
        pidLock.lock()
        defer { pidLock.unlock() }
        return _probePIDs
    }

    private static func addProbePID(_ pid: pid_t) {
        pidLock.lock()
        defer { pidLock.unlock() }
        _probePIDs.insert(pid)
    }

    private static func removeProbePID(_ pid: pid_t) {
        pidLock.lock()
        defer { pidLock.unlock() }
        _probePIDs.remove(pid)
    }

    struct Result {
        let stdout: String
        let timedOut: Bool
        /// True if `binary` couldn't be launched at all.
        let launchFailed: Bool
    }

    /// `binary`            absolute path to the CLI executable
    /// `args`              extra args before subcommand (e.g. `["-s","read-only","-a","untrusted"]`)
    /// `inputCommand`      the slash command to send after the CLI is ready (`/status`)
    /// `confirmPalettePrompts`
    ///                     strings (matched fuzzily — lowercased + whitespace
    ///                     stripped) that, when seen in the buffer, get a
    ///                     one-shot Enter pressed to advance past them. Used
    ///                     to dismiss Claude's `/usage` command palette
    ///                     ("Show plan", "Show plan usage limits") and any
    ///                     directory-trust gates that appear before the
    ///                     real prompt.
    /// `periodicEnterEvery`
    ///                     if set, send a bare Enter at this interval after
    ///                     the main command. Helps `/usage` advance through
    ///                     its palette prompts even when we don't have an
    ///                     exact match.
    /// `stopSubstrings`    return as soon as any of these appear in the
    ///                     captured output (also fuzzily matched)
    /// `settleAfterStop`   extra time to keep reading after a stop substring
    ///                     matches, so the panel finishes rendering
    /// `timeout`           hard cap on total runtime in seconds
    /// `cwd`               working directory the child runs in (defaults
    ///                     to `~`; passing a trusted project path avoids
    ///                     the Claude trust gate / Codex model picker)
    static func run(
        binary: String,
        args: [String],
        inputCommand: String,
        confirmPalettePrompts: [String] = [],
        periodicEnterEvery: TimeInterval? = nil,
        stopSubstrings: [String],
        settleAfterStop: TimeInterval = 0.25,
        timeout: TimeInterval,
        cwd: URL? = nil
    ) async -> Result {
        // 1. Allocate a PTY pair.
        var primaryFD: Int32 = 0
        var secondaryFD: Int32 = 0
        var winSize = winsize(ws_row: 50, ws_col: 200, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primaryFD, &secondaryFD, nil, nil, &winSize) == 0 else {
            return Result(stdout: "openpty failed", timedOut: false, launchFailed: true)
        }

        // Make the primary fd non-blocking so reads return immediately
        // when no data is available — we poll in our own loop.
        let flags = fcntl(primaryFD, F_GETFL, 0)
        _ = fcntl(primaryFD, F_SETFL, flags | O_NONBLOCK)

        // 2. Launch the CLI as a Process, wiring its stdin/out/err to the
        // PTY's secondary fd. Process keeps its own reference; we close
        // our copy of secondary so EOF propagates correctly when the
        // child exits.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        // Spawn the CLI inside a sane working directory. The .app
        // inherits cwd `/` from launchd, which (a) makes Claude show
        // its "untrusted directory" gate and (b) puts Codex in a
        // weird Skills menu state. The user's home is always a folder
        // they trust, and both CLIs read it without prompting.
        process.currentDirectoryURL = cwd ?? FileManager.default.homeDirectoryForCurrentUser
        let secondaryHandle = FileHandle(fileDescriptor: secondaryFD, closeOnDealloc: false)
        process.standardInput = secondaryHandle
        process.standardOutput = secondaryHandle
        process.standardError = secondaryHandle

        do {
            try process.run()
        } catch {
            close(primaryFD)
            close(secondaryFD)
            return Result(stdout: "process.run failed: \(error)",
                          timedOut: false,
                          launchFailed: true)
        }

        // Register the child PID so AgentManager's process scan can
        // exclude it (otherwise our short-lived helper child shows up
        // as a phantom session row in the panel).
        let childPID = process.processIdentifier
        addProbePID(childPID)

        // The child has its own copy of secondaryFD now; we don't need
        // ours. Closing it lets read() on primaryFD return EOF when the
        // child exits.
        close(secondaryFD)

        // 3. Drain primary fd, respond to cursor queries, send the slash
        // command, watch for stop tokens.
        let cursorQuery = Data([0x1B, 0x5B, 0x36, 0x6E])  // ESC [ 6 n
        let cursorResponse = Array("\u{1B}[1;1R".utf8)
        // OSC 10 ; ? — query foreground color. OSC 11 — background. Both
        // expected to be answered with `ESC ] 1X ; rgb:RRRR/GGGG/BBBB ESC \`.
        let osc10Query = Data([0x1B, 0x5D, 0x31, 0x30, 0x3B, 0x3F]) // ESC ] 10 ; ?
        let osc11Query = Data([0x1B, 0x5D, 0x31, 0x31, 0x3B, 0x3F])
        let osc10Response = Array("\u{1B}]10;rgb:c7c7/c7c7/c7c7\u{1B}\\".utf8)
        let osc11Response = Array("\u{1B}]11;rgb:0000/0000/0000\u{1B}\\".utf8)
        var lastCursorRespondedAt = Date.distantPast
        var lastOSCRespondedAt = Date.distantPast
        var sentCommand = false
        var lastEnterAt = Date()
        var firedPalettePrompts = Set<String>()
        var buffer = Data()
        let launchedAt = Date()
        let deadline = launchedAt.addingTimeInterval(timeout)
        // Pre-normalize the palette prompt + stop needles once.
        let normalizedPaletteNeedles = confirmPalettePrompts.map {
            (raw: $0, normalized: normalizeForFuzzyMatch($0))
        }
        let normalizedStopNeedles = stopSubstrings.map { normalizeForFuzzyMatch($0) }

        while Date() < deadline {
            // Drain everything currently available.
            var didReadAnything = false
            var tmp = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = tmp.withUnsafeMutableBufferPointer { ptr -> Int in
                    return Darwin.read(primaryFD, ptr.baseAddress, ptr.count)
                }
                if n > 0 {
                    buffer.append(tmp, count: n)
                    didReadAnything = true
                } else {
                    break
                }
            }

            // Respond to terminal capability queries the CLI sends during
            // startup. Codex blocks on the OSC 10/11 (fg/bg color) query;
            // Claude relies on the cursor position query.
            let now = Date()
            if didReadAnything,
               buffer.range(of: cursorQuery) != nil,
               now.timeIntervalSince(lastCursorRespondedAt) > 0.5
            {
                _ = cursorResponse.withUnsafeBufferPointer { ptr in
                    Darwin.write(primaryFD, ptr.baseAddress, ptr.count)
                }
                lastCursorRespondedAt = now
            }
            if didReadAnything,
               (buffer.range(of: osc10Query) != nil || buffer.range(of: osc11Query) != nil),
               now.timeIntervalSince(lastOSCRespondedAt) > 0.5
            {
                _ = osc10Response.withUnsafeBufferPointer { ptr in
                    Darwin.write(primaryFD, ptr.baseAddress, ptr.count)
                }
                _ = osc11Response.withUnsafeBufferPointer { ptr in
                    Darwin.write(primaryFD, ptr.baseAddress, ptr.count)
                }
                lastOSCRespondedAt = now
            }

            // CodexBar-style approach: fixed 2.0s startup wait, then
            // fire the slash command exactly once (as text + Enter in
            // two writes). Drain the buffer first so palette / stop
            // matchers only see post-command output.
            if !sentCommand, now.timeIntervalSince(launchedAt) > 2.0 {
                buffer.removeAll(keepingCapacity: true)
                let textBytes = Array(inputCommand.utf8)
                _ = textBytes.withUnsafeBufferPointer { ptr in
                    Darwin.write(primaryFD, ptr.baseAddress, ptr.count)
                }
                let enter: [UInt8] = [0x0D]
                _ = enter.withUnsafeBufferPointer { ptr in
                    Darwin.write(primaryFD, ptr.baseAddress, ptr.count)
                }
                sentCommand = true
                lastEnterAt = now
            }

            // After the slash command, the CLI may show a command palette
            // (Claude `/usage` shows "Show plan" / "Show plan usage limits"
            // pickers; trust gates / model pickers may also appear). For
            // each known palette prompt, fire Enter once when first seen.
            if sentCommand {
                let normalizedBuffer = normalizeForFuzzyMatch(
                    String(data: buffer, encoding: .utf8) ?? "")
                for needle in normalizedPaletteNeedles
                where !firedPalettePrompts.contains(needle.raw)
                    && normalizedBuffer.contains(needle.normalized) {
                    let enter: [UInt8] = [0x0D]
                    _ = enter.withUnsafeBufferPointer { ptr in
                        Darwin.write(primaryFD, ptr.baseAddress, ptr.count)
                    }
                    firedPalettePrompts.insert(needle.raw)
                    lastEnterAt = now
                }

                // Periodic Enter heartbeat — keeps `/usage` advancing
                // through palettes even when their text differs from
                // our known prompts.
                if let every = periodicEnterEvery,
                   now.timeIntervalSince(lastEnterAt) > every {
                    let enter: [UInt8] = [0x0D]
                    _ = enter.withUnsafeBufferPointer { ptr in
                        Darwin.write(primaryFD, ptr.baseAddress, ptr.count)
                    }
                    lastEnterAt = now
                }
            }

            // Check stop substrings against fuzzy-normalized text
            // (lowercased + whitespace stripped) so cursor-eaten spaces
            // don't break matching.
            if let text = String(data: buffer, encoding: .utf8) {
                let normalized = normalizeForFuzzyMatch(text)
                if normalizedStopNeedles.contains(where: normalized.contains) {
                    // Settle: keep reading for `settleAfterStop` more
                    // seconds so the panel finishes rendering before
                    // we hand it to the parser.
                    let settleDeadline = Date().addingTimeInterval(settleAfterStop)
                    while Date() < settleDeadline {
                        var more = [UInt8](repeating: 0, count: 8192)
                        let n = more.withUnsafeMutableBufferPointer { ptr -> Int in
                            return Darwin.read(primaryFD, ptr.baseAddress, ptr.count)
                        }
                        if n > 0 {
                            buffer.append(more, count: n)
                        }
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                    let final = String(data: buffer, encoding: .utf8) ?? text
                    cleanup(process: process, primaryFD: primaryFD)
                    return Result(stdout: stripANSI(final),
                                  timedOut: false,
                                  launchFailed: false)
                }
            }

            // Brief poll interval — match CodexBar's 120ms.
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        // Timed out.
        let captured = String(data: buffer, encoding: .utf8) ?? ""
        cleanup(process: process, primaryFD: primaryFD)
        return Result(stdout: stripANSI(captured),
                      timedOut: true,
                      launchFailed: false)
    }

    private static func cleanup(process: Process, primaryFD: Int32) {
        let pid = process.processIdentifier
        if process.isRunning {
            process.terminate()
            // Give it a beat to exit gracefully, then SIGKILL.
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
        close(primaryFD)
        removeProbePID(pid)
    }

    /// Lowercase + drop all whitespace for forgiving substring matching.
    /// CodexBar uses the same trick because cursor-positioned TUIs lose
    /// spaces when their output is captured sequentially via PTY (e.g.
    /// "Failed to load usage data" gets squashed to "Failedtoloadusagedata").
    static func normalizeForFuzzyMatch(_ s: String) -> String {
        return String(stripANSI(s).lowercased().filter { !$0.isWhitespace })
    }

    /// Strip CSI escape sequences (ESC [ ... letter). Doesn't try to
    /// handle every esc form — just enough to make the rate-limit text
    /// readable for regex matching.
    static func stripANSI(_ s: String) -> String {
        let pattern = "\u{1B}\\[[?>0-9;]*[a-zA-Z]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return s
        }
        let range = NSRange(location: 0, length: (s as NSString).length)
        return regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }
}
