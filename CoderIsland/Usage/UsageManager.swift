import Foundation
import Combine

/// Periodically probes `claude /usage` and `codex /status` via the
/// `CLIStatusProbe` PTY runner, parses the output with `UsageStatusParser`,
/// and exposes the latest snapshot for the UI.
///
/// Two snapshots, one per provider. The UI's hover popovers read from
/// these directly. A failed or pending probe yields nil for that
/// provider — the popover then says "no usage data" until the next
/// successful refresh.
///
/// Refresh is event-driven: a long timer for background polling, plus
/// an `refreshIfStale()` entry point the UI calls when the user hovers
/// the usage button (so opening the panel triggers a fresh fetch if
/// the cache is older than ~2 min).
@MainActor
final class UsageManager: ObservableObject {
    static let shared = UsageManager()

    @Published private(set) var claudeUsage: UsageInfo?
    @Published private(set) var codexUsage: UsageInfo?
    @Published private(set) var claudeFetchedAt: Date?
    @Published private(set) var codexFetchedAt: Date?
    @Published private(set) var isRefreshing: Bool = false

    /// Background poll interval. Each cycle re-probes both CLIs.
    private let backgroundInterval: TimeInterval = 10 * 60   // 10 min
    /// Hover-driven refresh only fires when the cache is at least
    /// this old. Within this window the user has to click the manual
    /// refresh button to force a re-fetch (covers the common case
    /// where the user just opens the panel briefly).
    private let staleThreshold: TimeInterval = 5 * 60        // 5 min

    private var timer: Timer?
    private var inflight: Task<Void, Never>?

    private init() {}

    func start() {
        // Read cached rate_limits shortly after launch. This is instant
        // (just a file read) — no child process, no TCC prompts.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await self?.refresh()
        }
        scheduleBackgroundTimer()
    }

    /// Trigger a refresh if either snapshot is older than `staleThreshold`.
    func refreshIfStale() {
        let now = Date()
        let claudeStale = claudeFetchedAt.map { now.timeIntervalSince($0) > staleThreshold } ?? true
        let codexStale = codexFetchedAt.map { now.timeIntervalSince($0) > staleThreshold } ?? true
        if claudeStale || codexStale {
            Task { await refresh() }
        }
    }

    /// Run both probes in parallel and update the published state. If a
    /// probe is already in flight, do nothing (avoid duplicate work).
    func refresh() async {
        guard inflight == nil else { return }
        let task = Task { [weak self] in
            await self?.runRefresh()
            return ()
        }
        inflight = task
        await task.value
        inflight = nil
    }

    private static let traceURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CoderIsland", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage-trace.log")
    }()

    private static func trace(_ msg: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "\(ts) \(msg)\n"
        if !FileManager.default.fileExists(atPath: traceURL.path) {
            FileManager.default.createFile(atPath: traceURL.path, contents: nil)
        }
        if let h = try? FileHandle(forWritingTo: traceURL) {
            defer { try? h.close() }
            try? h.seekToEnd()
            if let d = line.data(using: .utf8) { try? h.write(contentsOf: d) }
        }
    }

    private func runRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        Self.trace("refresh start")

        async let claudeResult = probeClaude()
        async let codexResult = probeCodex()
        let (claude, codex) = await (claudeResult, codexResult)

        if let claude = claude {
            claudeUsage = claude
            claudeFetchedAt = Date()
            Self.trace("claude OK primary=\(claude.primaryPercentUsed.map { String($0) } ?? "nil")% secondary=\(claude.secondaryPercentUsed.map { String($0) } ?? "nil")%")
        } else {
            Self.trace("claude probe returned nil")
        }
        if let codex = codex {
            codexUsage = codex
            codexFetchedAt = Date()
            Self.trace("codex OK primary=\(codex.primaryPercentUsed.map { String($0) } ?? "nil")% secondary=\(codex.secondaryPercentUsed.map { String($0) } ?? "nil")%")
        } else {
            Self.trace("codex probe returned nil")
        }
    }

    private func probeClaude() async -> UsageInfo? {
        // Read rate_limits from the cache file written by our statusLine
        // script. This avoids spawning a `claude` child process which
        // triggers macOS TCC folder-permission prompts.
        let cacheURL = HookInstaller.claudeRateLimitsCache
        guard let data = try? Data(contentsOf: cacheURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Self.trace("claude: no rate_limits cache at \(cacheURL.path)")
            return nil
        }

        var info = UsageInfo()

        // The statusLine JSON has the same shape as Codex token_count
        // rate_limits: { primary: { used_percent, window_minutes, resets_at }, secondary: {...}, plan_type }
        // OR the shape from Claude Code: { five_hour: { percentage }, seven_day: { percentage } }
        // Handle both.
        if let primary = json["primary"] as? [String: Any] {
            info.primaryPercentUsed = primary["used_percent"] as? Double
            info.primaryWindowMinutes = primary["window_minutes"] as? Int
            if let r = primary["resets_at"] as? Double { info.primaryResetsAt = Date(timeIntervalSince1970: r) }
            else if let r = primary["resets_at"] as? Int { info.primaryResetsAt = Date(timeIntervalSince1970: TimeInterval(r)) }
        }
        if let secondary = json["secondary"] as? [String: Any] {
            info.secondaryPercentUsed = secondary["used_percent"] as? Double
            info.secondaryWindowMinutes = secondary["window_minutes"] as? Int
            if let r = secondary["resets_at"] as? Double { info.secondaryResetsAt = Date(timeIntervalSince1970: r) }
            else if let r = secondary["resets_at"] as? Int { info.secondaryResetsAt = Date(timeIntervalSince1970: TimeInterval(r)) }
        }
        // Alternative shape: five_hour / seven_day
        if let fiveHour = json["five_hour"] as? [String: Any], info.primaryPercentUsed == nil {
            info.primaryPercentUsed = (fiveHour["used_percentage"] as? Double) ?? (fiveHour["percentage"] as? Double)
            info.primaryWindowMinutes = 300
            if let r = fiveHour["resets_at"] as? Double { info.primaryResetsAt = Date(timeIntervalSince1970: r) }
            else if let r = fiveHour["resets_at"] as? Int { info.primaryResetsAt = Date(timeIntervalSince1970: TimeInterval(r)) }
        }
        if let sevenDay = json["seven_day"] as? [String: Any], info.secondaryPercentUsed == nil {
            info.secondaryPercentUsed = (sevenDay["used_percentage"] as? Double) ?? (sevenDay["percentage"] as? Double)
            info.secondaryWindowMinutes = 10080
            if let r = sevenDay["resets_at"] as? Double { info.secondaryResetsAt = Date(timeIntervalSince1970: r) }
            else if let r = sevenDay["resets_at"] as? Int { info.secondaryResetsAt = Date(timeIntervalSince1970: TimeInterval(r)) }
        }

        info.planType = json["plan_type"] as? String

        guard info.primaryPercentUsed != nil || info.secondaryPercentUsed != nil else {
            Self.trace("claude: cache present but no rate_limits fields")
            return nil
        }
        Self.trace("claude: read from cache primary=\(info.primaryPercentUsed.map { String($0) } ?? "nil")%")
        return info
    }

    private func probeCodex() async -> UsageInfo? {
        // Codex side uses the OAuth file at ~/.codex/auth.json plus a
        // direct call to chatgpt.com/backend-api/wham/usage — same as
        // CodexBar. Avoids the PTY trust-dialog dance entirely.
        do {
            let snapshot = try await CodexOAuthUsageFetcher.fetch()
            var info = UsageInfo()
            if let p = snapshot.primaryUsedPercent {
                info.primaryPercentUsed = Double(p)
            }
            info.primaryResetsAt = snapshot.primaryResetAt
            if let secs = snapshot.primaryWindowSeconds {
                info.primaryWindowMinutes = secs / 60
            }
            if let p = snapshot.secondaryUsedPercent {
                info.secondaryPercentUsed = Double(p)
            }
            info.secondaryResetsAt = snapshot.secondaryResetAt
            if let secs = snapshot.secondaryWindowSeconds {
                info.secondaryWindowMinutes = secs / 60
            }
            info.planType = snapshot.planType
            Self.trace("codex OAuth fetch ok plan=\(snapshot.planType ?? "?") primary=\(snapshot.primaryUsedPercent ?? -1)% secondary=\(snapshot.secondaryUsedPercent ?? -1)%")
            return info
        } catch {
            Self.trace("codex OAuth fetch failed: \(error)")
            return nil
        }
    }

    private func scheduleBackgroundTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: backgroundInterval,
            repeats: true
        ) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }
}
