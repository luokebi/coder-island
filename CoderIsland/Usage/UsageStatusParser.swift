import Foundation

/// Parses the raw stdout captured from `claude /usage` and `codex /status`
/// PTY runs into a `UsageInfo` snapshot that NotchView can display.
///
/// Both CLIs use TUIs that animate / overdraw, so the captured stream
/// has weird artifacts: missing spaces (cursor positioning eats them),
/// occasional dropped letters (e.g. Claude renders "Resets" but we
/// capture "Reses"), interleaved frame updates, and ANSI cruft. We
/// match leniently with regex anchored on the literal label words and
/// the `%` sign — those survive the cursor antics.
enum UsageStatusParser {

    /// Parse Codex `/status` output. Looks for the two lines:
    ///
    ///     5h limit:     [████....] 100% left (resets 21:54)
    ///     Weekly limit: [████....] 56% left (resets 11:15 on 10 Apr)
    static func parseCodex(_ raw: String) -> UsageInfo? {
        var info = UsageInfo()
        var matched = false

        // 5h limit
        if let m = matchFirst(
            in: raw,
            pattern: #"5h limit:[^\n]*?(\d+)%\s*left[^\n]*?\(resets ([^)]+)\)"#
        ) {
            info.primaryWindowMinutes = 300
            if let pct = Int(m[1]) {
                // Codex shows "X% left" (remaining). Convert back to
                // "% used" so the rest of UsageInfo's semantics hold.
                info.primaryPercentUsed = Double(max(0, 100 - pct))
            }
            info.primaryResetsAt = parseCodexResetTime(m[2])
            matched = true
        }

        // Weekly limit
        if let m = matchFirst(
            in: raw,
            pattern: #"Weekly limit:[^\n]*?(\d+)%\s*left[^\n]*?\(resets ([^)]+)\)"#
        ) {
            info.secondaryWindowMinutes = 7 * 24 * 60
            if let pct = Int(m[1]) {
                info.secondaryPercentUsed = Double(max(0, 100 - pct))
            }
            info.secondaryResetsAt = parseCodexResetTime(m[2])
            matched = true
        }

        // Plan / account (Codex prints "luochuang33@gmail.com (Business)").
        if let m = matchFirst(in: raw, pattern: #"Account:\s+\S+\s+\(([^)]+)\)"#) {
            info.planType = m[1].lowercased()
        }

        return matched ? info : nil
    }

    /// Parse Claude `/usage` output. The TUI overdraws columns so the
    /// captured stream has missing spaces and the occasional dropped
    /// letter. Anchor on the strings "Current session" and "Current
    /// week (all models)" then walk forward to the percentage and the
    /// reset clause.
    static func parseClaude(_ raw: String) -> UsageInfo? {
        // Bail fast on the visible error path so we don't try to parse
        // a half-rendered error screen.
        if raw.contains("Failed to load usage") {
            return nil
        }

        var info = UsageInfo()
        var matched = false

        // Locate the byte range of each section so we can scope the
        // reset-time search precisely. Claude renders all three sections
        // (Current session / Current week (all models) / Current week
        // (Sonnet only)) on the same captured "line" with cursor
        // positioning eating spaces between them, so naive forward
        // searching can leak across boundaries.
        let nsRaw = raw as NSString
        let sessionRange = rangeOf(in: raw, pattern: #"Current session"#)
        let weekAllRange = rangeOf(in: raw, pattern: #"Current week\s*\(\s*all models\s*\)"#)
        let weekSonnetRange = rangeOf(in: raw, pattern: #"Current week\s*\(\s*Sonnet"#)
        let extraRange = rangeOf(in: raw, pattern: #"Extra usage"#)
        let escRange = rangeOf(in: raw, pattern: #"Esc to cancel"#)

        // Substring helper: bytes in `raw` between two NSRanges.
        func slice(from start: NSRange?, to end: NSRange?) -> String? {
            guard let s = start, s.location != NSNotFound else { return nil }
            let from = s.location + s.length
            let to: Int
            if let e = end, e.location != NSNotFound, e.location > from {
                to = e.location
            } else {
                to = nsRaw.length
            }
            guard to > from else { return nil }
            return nsRaw.substring(with: NSRange(location: from, length: to - from))
        }

        // First clock-value (`7pm`, `12:30am`, …) inside a substring.
        // This is more robust than anchoring on the literal "Resets"
        // label because Claude's TUI sometimes drops letters from it
        // ("Reses") and the spaces between label and time are gone.
        func firstClockTime(in s: String) -> String? {
            let pattern = #"(\d{1,2}(?::\d{2})?\s*[ap]m)"#
            return matchFirst(in: s, pattern: pattern)?[1]
        }
        // Same but for "Apr 15 at 2pm" / "MMM dd at H[:MM] am/pm".
        func firstDateTime(in s: String) -> String? {
            let pattern = #"(\w{3}\s+\d{1,2}\s+at\s+\d{1,2}(?::\d{2})?\s*[ap]m)"#
            return matchFirst(in: s, pattern: pattern)?[1]
        }

        // ── Current session (5h equivalent) ──
        if sessionRange != nil {
            // Slice from "Current session" to the start of the next section.
            let sessionSlice = slice(
                from: sessionRange,
                to: weekAllRange ?? extraRange ?? escRange
            ) ?? ""
            if let m = matchFirst(in: sessionSlice, pattern: #"(\d+)\s*%\s*used"#) {
                info.primaryWindowMinutes = 300
                if let pct = Int(m[1]) {
                    info.primaryPercentUsed = Double(pct)
                }
                if let clock = firstClockTime(in: sessionSlice) {
                    info.primaryResetsAt = parseClaudeResetTime(clock)
                }
                matched = true
            }
        }

        // ── Current week (all models) → weekly ──
        if weekAllRange != nil {
            let weekSlice = slice(
                from: weekAllRange,
                to: weekSonnetRange ?? extraRange ?? escRange
            ) ?? ""
            if let m = matchFirst(in: weekSlice, pattern: #"(\d+)\s*%\s*used"#) {
                info.secondaryWindowMinutes = 7 * 24 * 60
                if let pct = Int(m[1]) {
                    info.secondaryPercentUsed = Double(pct)
                }
                // Weekly reset is rendered as "Resets Apr 15 at 2pm".
                // Try the date+time form first; fall back to the
                // bare-clock pattern if Claude omits the date for short
                // horizons.
                if let dt = firstDateTime(in: weekSlice) {
                    info.secondaryResetsAt = parseClaudeResetTime(dt)
                } else if let clock = firstClockTime(in: weekSlice) {
                    info.secondaryResetsAt = parseClaudeResetTime(clock)
                }
                matched = true
            }
        }

        // Plan: "Claude Max" appears in the welcome banner.
        if raw.range(of: "Claude Max") != nil {
            info.planType = "max"
        } else if raw.range(of: "Claude Pro") != nil {
            info.planType = "pro"
        }

        return matched ? info : nil
    }

    // MARK: - Time parsing

    /// Codex resets are either:
    ///   "21:54"            (5h limit, today's local time)
    ///   "11:15 on 10 Apr"  (weekly limit, time + day + month)
    static func parseCodexResetTime(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try "HH:mm on D MMM" first (more specific).
        let onPattern = #"(\d{1,2}):(\d{2})\s+on\s+(\d{1,2})\s+(\w{3})"#
        if let m = matchFirst(in: trimmed, pattern: onPattern) {
            let hour = Int(m[1]) ?? 0
            let minute = Int(m[2]) ?? 0
            let day = Int(m[3]) ?? 1
            let monthName = m[4]
            let cal = Calendar(identifier: .gregorian)
            var comps = cal.dateComponents([.year], from: Date())
            comps.month = monthIndex(from: monthName)
            comps.day = day
            comps.hour = hour
            comps.minute = minute
            if let d = cal.date(from: comps) {
                // If the resulting date is in the past (year wrap), bump year.
                if d < Date().addingTimeInterval(-86400) {
                    comps.year = (comps.year ?? 0) + 1
                    return cal.date(from: comps)
                }
                return d
            }
        }

        // Plain "HH:mm" — assume today (or tomorrow if it's already past).
        let timePattern = #"^(\d{1,2}):(\d{2})$"#
        if let m = matchFirst(in: trimmed, pattern: timePattern) {
            let hour = Int(m[1]) ?? 0
            let minute = Int(m[2]) ?? 0
            let cal = Calendar.current
            var comps = cal.dateComponents([.year, .month, .day], from: Date())
            comps.hour = hour
            comps.minute = minute
            if let d = cal.date(from: comps) {
                return d < Date() ? d.addingTimeInterval(86400) : d
            }
        }

        return nil
    }

    /// Claude resets look like "7pm" or "Apr 15 at 2pm" or "2pm".
    /// They may also have stray garbage like "(Asia/Shanghai)" trailing.
    static func parseClaudeResetTime(_ s: String) -> Date? {
        let cleaned = s
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .components(separatedBy: "(").first?  // strip "(Asia/Shanghai)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? s

        // "Apr 15 at 2pm" or "Apr 15 at 2:30pm" — month + day + clock.
        let datePattern = #"(\w{3})\s+(\d{1,2})\s+at\s+(\d{1,2})(?::(\d{2}))?\s*([ap]m)"#
        if let m = matchFirst(in: cleaned, pattern: datePattern) {
            let monthName = m[1]
            let day = Int(m[2]) ?? 1
            var hour = Int(m[3]) ?? 0
            let minute = (m.count > 4 ? Int(m[4]) : nil) ?? 0
            let pm = m.last?.lowercased() == "pm"
            if pm && hour < 12 { hour += 12 }
            if !pm && hour == 12 { hour = 0 }
            let cal = Calendar(identifier: .gregorian)
            var comps = cal.dateComponents([.year], from: Date())
            comps.month = monthIndex(from: monthName)
            comps.day = day
            comps.hour = hour
            comps.minute = minute
            if let d = cal.date(from: comps) {
                if d < Date().addingTimeInterval(-86400) {
                    comps.year = (comps.year ?? 0) + 1
                    return cal.date(from: comps)
                }
                return d
            }
        }

        // Plain "7pm" / "12:30am" — clock only, today or tomorrow.
        let timePattern = #"(\d{1,2})(?::(\d{2}))?\s*([ap]m)"#
        if let m = matchFirst(in: cleaned, pattern: timePattern) {
            var hour = Int(m[1]) ?? 0
            let minute = (m.count > 2 ? Int(m[2]) : nil) ?? 0
            let pm = m.last?.lowercased() == "pm"
            if pm && hour < 12 { hour += 12 }
            if !pm && hour == 12 { hour = 0 }
            let cal = Calendar.current
            var comps = cal.dateComponents([.year, .month, .day], from: Date())
            comps.hour = hour
            comps.minute = minute
            if let d = cal.date(from: comps) {
                return d < Date() ? d.addingTimeInterval(86400) : d
            }
        }

        return nil
    }

    // MARK: - Helpers

    private static func matchFirst(in text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, range: range) else {
            return nil
        }
        var groups: [String] = []
        for i in 0..<match.numberOfRanges {
            let r = match.range(at: i)
            if r.location == NSNotFound {
                groups.append("")
            } else {
                groups.append(nsText.substring(with: r))
            }
        }
        return groups
    }

    private static func substring(after needle: String, in text: String) -> String? {
        guard let r = text.range(of: needle) else { return nil }
        return String(text[r.upperBound...])
    }

    private static func rangeOf(in text: String, pattern: String) -> NSRange? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)
        return regex.firstMatch(in: text, range: full)?.range
    }

    private static func monthIndex(from name: String) -> Int {
        let months = ["jan", "feb", "mar", "apr", "may", "jun",
                      "jul", "aug", "sep", "oct", "nov", "dec"]
        let key = String(name.prefix(3)).lowercased()
        return (months.firstIndex(of: key) ?? 0) + 1
    }
}
