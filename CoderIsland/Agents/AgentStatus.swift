import Foundation
import AppKit
import Darwin

enum AgentType: String, CaseIterable, Identifiable {
    case claudeCode = "claude"
    case codex = "codex"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude"
        case .codex: return "Codex"
        }
    }
}

enum AgentStatus: String {
    case idle
    case running
    case waiting
    case justFinished
    case done
    case error

    var isActive: Bool {
        self == .running || self == .waiting
    }

    var isRecentlyFinished: Bool {
        self == .justFinished || self == .done
    }

    var isDimmedInUI: Bool {
        isRecentlyFinished || self == .idle
    }
}

class AgentSession: ObservableObject, Identifiable {
    private static let warpTabCacheDefaultsKey = "WarpTabCacheByKey"
    private static let warpTabCacheQueue = DispatchQueue(label: "com.coderisland.warpTabCache")
    private static var warpTabCache: [String: Int] = {
        guard let raw = UserDefaults.standard.dictionary(forKey: warpTabCacheDefaultsKey) else {
            return [:]
        }
        var parsed: [String: Int] = [:]
        for (key, value) in raw {
            if let number = value as? NSNumber {
                parsed[key] = number.intValue
            } else if let intValue = value as? Int {
                parsed[key] = intValue
            }
        }
        return parsed
    }()
    private static let ghosttyTabCacheDefaultsKey = "GhosttyTabCacheByKey"
    private static let ghosttyTabCacheQueue = DispatchQueue(label: "com.coderisland.ghosttyTabCache")
    private static var ghosttyTabCache: [String: Int] = {
        guard let raw = UserDefaults.standard.dictionary(forKey: ghosttyTabCacheDefaultsKey) else {
            return [:]
        }
        var parsed: [String: Int] = [:]
        for (key, value) in raw {
            if let number = value as? NSNumber {
                parsed[key] = number.intValue
            } else if let intValue = value as? Int {
                parsed[key] = intValue
            }
        }
        return parsed
    }()

    let id: String
    let agentType: AgentType
    let pid: Int32
    let startTime: Date
    let workingDirectory: String?
    private var cachedTTYPath: String?

    @Published var taskName: String
    @Published var subtitle: String?
    @Published var status: AgentStatus
    @Published var terminalApp: String
    @Published var askQuestion: String?
    @Published var askOptions: [(label: String, description: String)]?
    @Published var lastUserMessage: String?
    @Published var lastAssistantMessage: String?
    @Published var cachedTabNumber: Int?  // Cache the found tab position
    var completionMarker: String?
    var acknowledgedCompletionMarker: String?
    var lastUpdated: Date = Date()

    init(
        id: String = UUID().uuidString,
        agentType: AgentType,
        pid: Int32,
        taskName: String = "Working...",
        subtitle: String? = nil,
        status: AgentStatus = .running,
        terminalApp: String = "Terminal",
        workingDirectory: String? = nil,
        startDate: Date? = nil,
        askQuestion: String? = nil,
        askOptions: [(label: String, description: String)]? = nil,
        lastUserMessage: String? = nil,
        lastAssistantMessage: String? = nil,
        completionMarker: String? = nil
    ) {
        self.id = id
        self.agentType = agentType
        self.pid = pid
        self.startTime = startDate ?? Date()
        self.taskName = taskName
        self.subtitle = subtitle
        self.status = status
        self.terminalApp = terminalApp
        self.workingDirectory = workingDirectory
        self.askQuestion = askQuestion
        self.askOptions = askOptions
        self.lastUserMessage = lastUserMessage
        self.lastAssistantMessage = lastAssistantMessage
        self.completionMarker = completionMarker
    }

    func acknowledgeRecentCompletion() {
        acknowledgedCompletionMarker = completionMarker
        status = .idle
    }

    var elapsedTimeString: String {
        let elapsed = Date().timeIntervalSince(startTime)
        if elapsed < 60 {
            return "\(Int(elapsed))s"
        } else if elapsed < 3600 {
            return "\(Int(elapsed / 60))m"
        } else {
            return "\(Int(elapsed / 3600))h"
        }
    }

    func jumpToTerminal() {
        let workspace = NSWorkspace.shared
        let activateOptions: NSApplication.ActivationOptions = [.activateAllWindows]

        // Map display names back to possible localizedName values
        let nameAliases: [String: [String]] = [
            "VS Code": ["Code", "Visual Studio Code"],
            "iTerm2": ["iTerm2", "iTerm"],
        ]
        let searchNames: [String] = {
            var names = [terminalApp]
            if let aliases = nameAliases[terminalApp] {
                names.append(contentsOf: aliases)
            }
            return names.map { $0.lowercased() }
        }()

        // Find and activate the terminal app
        let matchedApp = workspace.runningApplications.first(where: { app in
            guard let name = app.localizedName?.lowercased() else { return false }
            return searchNames.contains(name)
        }) ?? workspace.runningApplications.first(where: { app in
            guard let name = app.localizedName?.lowercased() else { return false }
            return searchNames.contains { name.contains($0) || $0.contains(name) }
        })

        guard let app = matchedApp else { return }

        let appName = terminalApp.lowercased()
        if appName.contains("warp") {
            app.activate(options: activateOptions)
            let warpPID = app.processIdentifier
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) {
                self.writeWarpTabTitleIfPossible()
                self.jumpToWarpTab(warpPID: warpPID, activateOptions: nil)
            }
            return
        }

        if appName.contains("ghostty") {
            app.activate(options: activateOptions)
            let ghosttyPID = app.processIdentifier
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) {
                self.writeGhosttyTabTitleIfPossible()
                self.jumpToGhosttyTab(ghosttyPID: ghosttyPID, activateOptions: nil)
            }
            return
        }

        if appName == "terminal" {
            app.activate(options: activateOptions)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.12) {
                self.writeTerminalTabTitleIfPossible()
                self.jumpToAppleTerminalTabIfPossible()
            }
            return
        }

        if appName.contains("iterm") {
            app.activate(options: activateOptions)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.1) {
                self.jumpToITerm2TabIfPossible()
            }
            return
        }

        app.activate(options: activateOptions)
    }

    // MARK: - Ghostty Tab Switching (uses TTY title injection, same as Warp)

    private func jumpToGhosttyTab(ghosttyPID: pid_t, activateOptions: NSApplication.ActivationOptions?) {
        let markerTitle = desiredGhosttyTabTitle()
        let logFile = "/tmp/jump-ghostty.txt"
        var log = "[jumpToGhosttyTab] Called for \(taskName), marker='\(markerTitle)', cached=\(cachedTabNumber ?? -1), pid=\(ghosttyPID)\n"
        usleep(100000)  // let Ghostty pick up the title
        defer {
            restoreGhosttyTabTitle()
            if let activateOptions {
                activateApplication(pid: ghosttyPID, options: activateOptions)
            }
            try? log.data(using: .utf8)?.write(to: URL(fileURLWithPath: logFile), options: .atomic)
        }

        let expected = normalizedWarpTitle(markerTitle)

        if matchesGhosttyMarker(markerTitle) {
            log += "Already on target Ghostty tab\n"
            return
        }

        // Primary path: direct AX tab button match (no visible multi-switch).
        for _ in 0..<3 {
            if let tabButton = findGhosttyTabButtonByAccessibility(expected: expected),
               pressAXElement(tabButton) {
                usleep(120000)
                if matchesGhosttyMarker(markerTitle) {
                    log += "Matched Ghostty tab via AX press\n"
                    return
                }
            }
            usleep(100000)
        }

        // Fallback: single-hop cached shortcut only, still no full scan.
        if let cachedTab = preferredGhosttyTabCandidates().first {
            log += "Fallback cached single-hop Cmd+\(cachedTab)\n"
            sendTabSwitchCmd(cachedTab, targetPID: ghosttyPID, appLabel: "Ghostty")
            rememberGhosttyTabNumberIfNeeded(cachedTab)
            return
        }

        log += "No AX match and no cached tab\n"
    }

    private func desiredGhosttyTabTitle() -> String {
        let trimmedTask = taskName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTask = trimmedTask.isEmpty ? "session" : trimmedTask
        let identifier = agentType == .claudeCode ? String(id.prefix(8)) : String(pid)
        return "ci:\(identifier) \(fallbackTask)"
    }

    private func writeGhosttyTabTitleIfPossible() {
        // Push current title, then set our marker (same approach as Warp)
        writeTTYSequenceIfPossible("\u{001B}[22;0t\u{001B}]0;\(desiredGhosttyTabTitle())\u{0007}", logLabel: "writeGhosttyTitle")
    }

    private func restoreGhosttyTabTitle() {
        writeTTYSequenceIfPossible("\u{001B}[23;0t", logLabel: "ghosttyPopTitle")  // pop
    }

    private func matchesGhosttyMarker(_ marker: String) -> Bool {
        guard let title = getAppWindowTitle("Ghostty") else { return false }
        let normalizedTitle = normalizedWarpTitle(title)
        let normalizedMarker = normalizedWarpTitle(marker)
        let matched = normalizedTitle == normalizedMarker || normalizedTitle.contains(normalizedMarker)
        if matched {
            writeLog("[matchGhosttyMarker] matched: title='\(title)' marker='\(marker)'")
        }
        return matched
    }

    // MARK: - Shared Tab Helpers

    private func getAppWindowTitle(_ appName: String) -> String? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.lowercased() == appName.lowercased()
        }) else { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        for attribute in ["AXFocusedWindow", "AXMainWindow", "AXWindows"] {
            var value: AnyObject?
            let result = AXUIElementCopyAttributeValue(appElement, attribute as CFString, &value)
            if attribute == "AXWindows", let windows = value as? [AXUIElement], let window = windows.first {
                if let title = copyWindowTitle(window) { return title }
            } else if result == .success, let value {
                let window = unsafeBitCast(value, to: AXUIElement.self)
                if let title = copyWindowTitle(window) { return title }
            }
        }
        return nil
    }

    private func sendTabSwitchCmd(_ tabNum: Int, targetPID: pid_t? = nil, appLabel: String = "Terminal") {
        guard let keyCode = getKeyCode(for: String(tabNum)),
              let source = CGEventSource(stateID: .combinedSessionState) else { return }

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)

        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand

        if let targetPID {
            keyDown?.postToPid(targetPID)
            keyUp?.postToPid(targetPID)
            writeLog("[sendTabSwitchCmd] Sent Cmd+\(tabNum) to \(appLabel) pid=\(targetPID)")
        } else {
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
            writeLog("[sendTabSwitchCmd] Sent Cmd+\(tabNum) globally")
        }
    }

    private func writeLog(_ msg: String) {
        let logPath = "/tmp/coderisland-debug.log"
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(msg)\n"
        if let data = line.data(using: .utf8) {
            let url = URL(fileURLWithPath: logPath)
            if FileManager.default.fileExists(atPath: logPath) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.synchronize()
                    handle.closeFile()
                }
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func jumpToWarpTab(warpPID: pid_t, activateOptions: NSApplication.ActivationOptions?) {
        let logFile = "/tmp/jump-warp.txt"
        var log = "[jumpToWarpTab] Called for \(taskName), cached=\(cachedTabNumber ?? -1), pid=\(warpPID)\n"

        writeLog("[jumpToWarpTab] AXIsProcessTrusted=\(AXIsProcessTrusted())")
        defer {
            restoreWarpTabTitleIfPossible()
            if let activateOptions {
                activateApplication(pid: warpPID, options: activateOptions)
            }
            try? log.data(using: .utf8)?.write(to: URL(fileURLWithPath: logFile), options: .atomic)
        }

        if matchesCurrentWarpTitle() {
            log += "Current front Warp tab already matches\n"
            if let cachedTabNumber {
                rememberWarpTabNumberIfNeeded(cachedTabNumber)
            }
            return
        }

        // Try exact/per-project cache first. This path is always single-hop.
        for tabNum in preferredWarpTabCandidates() {
            log += "Trying cached tab \(tabNum)\n"
            sendWarpTabSwitchCmd(tabNum, targetPID: warpPID)
            usleep(180000)
            if matchesCurrentWarpTitle() {
                log += "Cached tab \(tabNum) matched\n"
                rememberWarpTabNumberIfNeeded(tabNum)
                return
            }
        }

        // Try direct Accessibility-based tab match first (single-hop).
        if let tabElement = findWarpTabElementByAccessibility() {
            log += "Found matching Warp tab via AX, pressing element\n"
            if pressAXElement(tabElement) {
                usleep(180000)
                if matchesCurrentWarpTitle() {
                    log += "AX press matched\n"
                    return
                }
                log += "AX press executed but title mismatch, falling back to scan\n"
            } else {
                log += "AX press failed, falling back to scan\n"
            }
        } else {
            log += "No matching Warp tab found via AX, falling back to scan\n"
        }

        // Try tabs 1-9
        for tab in 1...9 {
            sendWarpTabSwitchCmd(tab, targetPID: warpPID)
            usleep(250000)

            if let title = getWarpWindowTitle() {
                log += "Tab \(tab) title: \(title)\n"
            } else {
                log += "Tab \(tab) produced no title\n"
            }

            if matchesCurrentWarpTitle() {
                log += "Found match at tab \(tab)\n"
                rememberWarpTabNumberIfNeeded(tab)
                return
            }
        }

        rememberWarpTabNumberIfNeeded(nil)
        log += "No match found\n"
    }

    private func sendWarpTabSwitchCmd(_ tabNum: Int, targetPID: pid_t? = nil) {
        guard let keyCode = getKeyCode(for: String(tabNum)) else {
            writeLog("[sendWarpTabSwitchCmd] No key code for tab \(tabNum)")
            return
        }

        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            writeLog("[sendWarpTabSwitchCmd] Failed to create CGEventSource")
            return
        }

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)

        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand

        if let targetPID {
            keyDown?.postToPid(targetPID)
            keyUp?.postToPid(targetPID)
            writeLog("[sendWarpTabSwitchCmd] Sent Cmd+\(tabNum) to pid=\(targetPID)")
        } else {
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
            writeLog("[sendWarpTabSwitchCmd] Sent Cmd+\(tabNum) globally")
        }
    }

    private func matchesCurrentWarpTitle() -> Bool {
        guard let title = getWarpWindowTitle() else { return false }
        let normalizedTitle = normalizedWarpTitle(title)
        let expectedTitle = normalizedWarpTitle(desiredWarpTabTitle())
        let normalizedTask = normalizedWarpTitle(taskName)
        writeLog("[matchesCurrentWarpTitle] title='\(title)' normalized='\(normalizedTitle)' expected='\(expectedTitle)' task='\(normalizedTask)'")

        if normalizedTitle == expectedTitle {
            return true
        }

        if titleLooksLikePath(title) {
            guard let workingDirectory else { return false }
            let cwdMatch = pathTitleMatchesWorkingDirectory(title, workingDirectory: workingDirectory)
            writeLog("[matchesCurrentWarpTitle] pathTitle cwd='\(workingDirectory)' match=\(cwdMatch)")
            return cwdMatch
        }

        let normalizedLabel = normalizedWarpSessionLabel(title)
        return normalizedLabel == normalizedTask
    }

    private func getWarpWindowTitle() -> String? {
        guard let warpApp = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == "Warp" }) else {
            writeLog("[getWarpWindowTitle] Warp not running")
            return nil
        }

        let appElement = AXUIElementCreateApplication(warpApp.processIdentifier)
        for attribute in ["AXFocusedWindow", "AXMainWindow", "AXWindows"] {
            var value: AnyObject?
            let result = AXUIElementCopyAttributeValue(appElement, attribute as CFString, &value)
            writeLog("[getWarpWindowTitle] attribute=\(attribute) result=\(result.rawValue)")

            if attribute == "AXWindows", let windows = value as? [AXUIElement], let window = windows.first {
                if let title = copyWindowTitle(window) {
                    return title
                }
            } else if let value {
                let window = unsafeBitCast(value, to: AXUIElement.self)
                if let title = copyWindowTitle(window) {
                    return title
                }
            }
        }

        writeLog("[getWarpWindowTitle] No accessible window title")
        return nil
    }

    private func copyWindowTitle(_ window: AXUIElement) -> String? {
        var title: AnyObject?
        let result = AXUIElementCopyAttributeValue(window, "AXTitle" as CFString, &title)
        writeLog("[copyWindowTitle] result=\(result.rawValue) title='\((title as? String) ?? "")'")
        return title as? String
    }

    private func findWarpWindowElement() -> AXUIElement? {
        findWindowElement(forAppName: "Warp")
    }

    private func findWindowElement(forAppName appName: String) -> AXUIElement? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var focused: AnyObject?
        if AXUIElementCopyAttributeValue(appElement, "AXFocusedWindow" as CFString, &focused) == .success,
           let window = focused {
            let cf = window as CFTypeRef
            if CFGetTypeID(cf) == AXUIElementGetTypeID() {
                return unsafeBitCast(cf, to: AXUIElement.self)
            }
        }

        var main: AnyObject?
        if AXUIElementCopyAttributeValue(appElement, "AXMainWindow" as CFString, &main) == .success,
           let window = main {
            let cf = window as CFTypeRef
            if CFGetTypeID(cf) == AXUIElementGetTypeID() {
                return unsafeBitCast(cf, to: AXUIElement.self)
            }
        }

        var windows: AnyObject?
        if AXUIElementCopyAttributeValue(appElement, "AXWindows" as CFString, &windows) == .success,
           let array = windows as? [AnyObject] {
            for item in array {
                let cf = item as CFTypeRef
                if CFGetTypeID(cf) == AXUIElementGetTypeID() {
                    return unsafeBitCast(cf, to: AXUIElement.self)
                }
            }
        }

        return nil
    }

    private func findWarpTabElementByAccessibility() -> AXUIElement? {
        guard let window = findWarpWindowElement() else { return nil }

        let expected = normalizedWarpTitle(desiredWarpTabTitle())
        let taskLabel = normalizedWarpTitle(taskName)
        let cwdLabel = workingDirectory.map { normalizedWarpTitle(URL(fileURLWithPath: $0).lastPathComponent) }

        var queue: [AXUIElement] = [window]
        var visited: Set<CFHashCode> = []
        var scanned = 0

        while !queue.isEmpty && scanned < 600 {
            let element = queue.removeFirst()
            scanned += 1

            let hash = CFHash(element)
            if visited.contains(hash) { continue }
            visited.insert(hash)

            if elementSupportsPress(element),
               let rawTitle = axBestTitle(for: element) {
                let normalized = normalizedWarpTitle(rawTitle)
                let matches = normalized == expected
                    || normalized == taskLabel
                    || (cwdLabel != nil && (normalized == cwdLabel! || normalized.contains(cwdLabel!)))
                if matches {
                    writeLog("[findWarpTabElementByAccessibility] matched title='\(rawTitle)'")
                    return element
                }
            }

            queue.append(contentsOf: axChildren(of: element, attribute: "AXTabs"))
            queue.append(contentsOf: axChildren(of: element, attribute: "AXVisibleChildren"))
            queue.append(contentsOf: axChildren(of: element, attribute: "AXChildren"))
            queue.append(contentsOf: axChildren(of: element, attribute: "AXRows"))
            queue.append(contentsOf: axChildren(of: element, attribute: "AXContents"))
        }

        return nil
    }

    private func pressAXElement(_ element: AXUIElement) -> Bool {
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        writeLog("[pressAXElement] result=\(result.rawValue)")
        return result == .success
    }

    private func elementSupportsPress(_ element: AXUIElement) -> Bool {
        var actionsRef: CFArray?
        guard AXUIElementCopyActionNames(element, &actionsRef) == .success,
              let actions = actionsRef as? [String] else { return false }
        return actions.contains(kAXPressAction as String)
    }

    private func axBestTitle(for element: AXUIElement) -> String? {
        if let title = axStringValue(of: element, attribute: "AXTitle"), !title.isEmpty { return title }
        if let desc = axStringValue(of: element, attribute: "AXDescription"), !desc.isEmpty { return desc }
        if let value = axStringValue(of: element, attribute: "AXValue"), !value.isEmpty { return value }
        return nil
    }

    private func axStringValue(of element: AXUIElement, attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func axChildren(of element: AXUIElement, attribute: String) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return [] }

        if let list = value as? [AXUIElement] {
            return list
        }
        if let list = value as? [AnyObject] {
            return list.compactMap { item in
                let cf = item as CFTypeRef
                guard CFGetTypeID(cf) == AXUIElementGetTypeID() else { return nil }
                return unsafeBitCast(cf, to: AXUIElement.self)
            }
        }

        let cf = value as CFTypeRef
        if CFGetTypeID(cf) == AXUIElementGetTypeID() {
            return [unsafeBitCast(cf, to: AXUIElement.self)]
        }
        return []
    }

    private func preferredWarpTabCandidates() -> [Int] {
        var candidates: [Int] = []
        if let cached = cachedTabNumber {
            candidates.append(cached)
        }
        for key in warpTabCacheKeys() {
            if let cached = Self.warpTabCacheQueue.sync(execute: { Self.warpTabCache[key] }) {
                candidates.append(cached)
            }
        }

        var seen: Set<Int> = []
        return candidates.filter { candidate in
            guard (1...9).contains(candidate), !seen.contains(candidate) else { return false }
            seen.insert(candidate)
            return true
        }
    }

    private func preferredGhosttyTabCandidates() -> [Int] {
        var candidates: [Int] = []
        if let cached = cachedTabNumber {
            candidates.append(cached)
        }

        // Read latest persisted cache every time to avoid stale in-memory map.
        if let raw = UserDefaults.standard.dictionary(forKey: Self.ghosttyTabCacheDefaultsKey) {
            var latest: [String: Int] = [:]
            for (key, value) in raw {
                if let number = value as? NSNumber {
                    latest[key] = number.intValue
                } else if let intValue = value as? Int {
                    latest[key] = intValue
                }
            }
            Self.ghosttyTabCacheQueue.sync {
                Self.ghosttyTabCache = latest
            }
        }

        for key in ghosttyTabCacheKeys() {
            if let cached = Self.ghosttyTabCacheQueue.sync(execute: { Self.ghosttyTabCache[key] }) {
                candidates.append(cached)
            }
        }

        var seen: Set<Int> = []
        return candidates.filter { candidate in
            guard (1...9).contains(candidate), !seen.contains(candidate) else { return false }
            seen.insert(candidate)
            return true
        }
    }

    private func warpTabCacheKeys() -> [String] {
        var keys: [String] = []
        let marker = normalizedWarpTitle(desiredWarpTabTitle())
        if !marker.isEmpty {
            keys.append("marker:\(marker)")
        }

        if let workingDirectory {
            let normalizedPath = normalizedWarpTitle(workingDirectory)
            if !normalizedPath.isEmpty {
                keys.append("cwd:\(normalizedPath)")
            }
        }

        let normalizedTask = normalizedWarpTitle(taskName)
        if !normalizedTask.isEmpty {
            keys.append("task:\(normalizedTask)")
        }

        return keys
    }

    private func ghosttyTabCacheKeys() -> [String] {
        var keys: [String] = []
        let marker = normalizedWarpTitle(desiredGhosttyTabTitle())
        if !marker.isEmpty {
            keys.append("marker:\(marker)")
        }

        if let workingDirectory {
            let normalizedPath = normalizedWarpTitle(workingDirectory)
            if !normalizedPath.isEmpty {
                keys.append("cwd:\(normalizedPath)")
            }
        }

        let normalizedTask = normalizedWarpTitle(taskName)
        if !normalizedTask.isEmpty {
            keys.append("task:\(normalizedTask)")
        }

        return keys
    }

    private func rememberWarpTabNumberIfNeeded(_ tab: Int?) {
        DispatchQueue.main.async {
            self.cachedTabNumber = tab
        }

        let keys = warpTabCacheKeys()
        guard !keys.isEmpty else { return }

        guard let tab, (1...9).contains(tab) else {
            Self.warpTabCacheQueue.sync {
                for key in keys {
                    Self.warpTabCache.removeValue(forKey: key)
                }
                UserDefaults.standard.set(Self.warpTabCache, forKey: Self.warpTabCacheDefaultsKey)
            }
            return
        }

        Self.warpTabCacheQueue.sync {
            for key in keys {
                Self.warpTabCache[key] = tab
            }
            UserDefaults.standard.set(Self.warpTabCache, forKey: Self.warpTabCacheDefaultsKey)
        }
    }

    private func rememberGhosttyTabNumberIfNeeded(_ tab: Int?) {
        DispatchQueue.main.async {
            self.cachedTabNumber = tab
        }

        let keys = ghosttyTabCacheKeys()
        guard !keys.isEmpty else { return }

        guard let tab, (1...9).contains(tab) else {
            Self.ghosttyTabCacheQueue.sync {
                for key in keys {
                    Self.ghosttyTabCache.removeValue(forKey: key)
                }
                UserDefaults.standard.set(Self.ghosttyTabCache, forKey: Self.ghosttyTabCacheDefaultsKey)
            }
            return
        }

        Self.ghosttyTabCacheQueue.sync {
            for key in keys {
                Self.ghosttyTabCache[key] = tab
            }
            UserDefaults.standard.set(Self.ghosttyTabCache, forKey: Self.ghosttyTabCacheDefaultsKey)
        }
    }

    private func jumpToAppleTerminalTabIfPossible() {
        let expected = normalizedWarpTitle(desiredTerminalTabTitle())
        let taskLabel = normalizedWarpTitle(taskName)
        let cwdLabel = workingDirectory.map { normalizedWarpTitle(URL(fileURLWithPath: $0).lastPathComponent) }

        for _ in 0..<2 {
            if let tabButton = findTerminalTabButtonByAccessibility(expected: expected, taskLabel: taskLabel, cwdLabel: cwdLabel),
               pressAXElement(tabButton) {
                writeLog("[jumpToAppleTerminalTabIfPossible] matched by AX tab button")
                return
            }
            usleep(120000)
        }

        writeLog("[jumpToAppleTerminalTabIfPossible] No AX tab button matched")
    }

    private func desiredTerminalTabTitle() -> String {
        let trimmedTask = taskName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTask = trimmedTask.isEmpty ? "session" : trimmedTask
        let identifier = agentType == .claudeCode ? String(id.prefix(8)) : String(pid)
        return "ci:\(identifier) \(fallbackTask)"
    }

    private func writeTerminalTabTitleIfPossible() {
        writeTTYSequenceIfPossible("\u{001B}]0;\(desiredTerminalTabTitle())\u{0007}", logLabel: "writeTerminalTitle")
    }

    private func findTerminalTabButtonByAccessibility(expected: String, taskLabel: String, cwdLabel: String?) -> AXUIElement? {
        guard let window = findWindowElement(forAppName: "Terminal") else { return nil }
        var queue: [AXUIElement] = [window]
        var visited: Set<CFHashCode> = []
        var scanned = 0

        while !queue.isEmpty && scanned < 500 {
            let element = queue.removeFirst()
            scanned += 1

            let hash = CFHash(element)
            if visited.contains(hash) { continue }
            visited.insert(hash)

            let role = axStringValue(of: element, attribute: "AXRole") ?? ""
            let subrole = axStringValue(of: element, attribute: "AXSubrole") ?? ""
            if role == "AXRadioButton", subrole == "AXTabButton", elementSupportsPress(element),
               let rawTitle = axBestTitle(for: element) {
                let normalized = normalizedWarpTitle(rawTitle)
                if normalized.contains(expected)
                    || (!taskLabel.isEmpty && normalized.contains(taskLabel))
                    || (cwdLabel != nil && normalized.contains(cwdLabel!)) {
                    writeLog("[findTerminalTabButtonByAccessibility] matched title='\(rawTitle)'")
                    return element
                }
            }

            queue.append(contentsOf: axChildren(of: element, attribute: "AXTabs"))
            queue.append(contentsOf: axChildren(of: element, attribute: "AXVisibleChildren"))
            queue.append(contentsOf: axChildren(of: element, attribute: "AXChildren"))
            queue.append(contentsOf: axChildren(of: element, attribute: "AXRows"))
            queue.append(contentsOf: axChildren(of: element, attribute: "AXContents"))
        }

        return nil
    }

    private func findGhosttyTabButtonByAccessibility(expected: String) -> AXUIElement? {
        guard let window = findWindowElement(forAppName: "Ghostty") else { return nil }
        var queue: [AXUIElement] = [window]
        var visited: Set<CFHashCode> = []
        var scanned = 0

        while !queue.isEmpty && scanned < 500 {
            let element = queue.removeFirst()
            scanned += 1

            let hash = CFHash(element)
            if visited.contains(hash) { continue }
            visited.insert(hash)

            let role = axStringValue(of: element, attribute: "AXRole") ?? ""
            let subrole = axStringValue(of: element, attribute: "AXSubrole") ?? ""
            if role == "AXRadioButton", subrole == "AXTabButton", elementSupportsPress(element),
               let rawTitle = axBestTitle(for: element) {
                let normalized = normalizedWarpTitle(rawTitle)
                if normalized.contains(expected) {
                    writeLog("[findGhosttyTabButtonByAccessibility] matched title='\(rawTitle)'")
                    return element
                }
            }

            queue.append(contentsOf: axChildren(of: element, attribute: "AXTabs"))
            queue.append(contentsOf: axChildren(of: element, attribute: "AXVisibleChildren"))
            queue.append(contentsOf: axChildren(of: element, attribute: "AXChildren"))
            queue.append(contentsOf: axChildren(of: element, attribute: "AXRows"))
            queue.append(contentsOf: axChildren(of: element, attribute: "AXContents"))
        }

        return nil
    }

    private func activateApplication(pid: pid_t, options: NSApplication.ActivationOptions) {
        DispatchQueue.main.async {
            guard let app = NSRunningApplication(processIdentifier: pid) else { return }
            app.activate(options: options)
        }
    }

    private func normalizedWarpTitle(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "·", with: " ")
            .replacingOccurrences(of: "_", with: "-")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func normalizedWarpSessionLabel(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let dotSegments = trimmed
            .components(separatedBy: "·")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !dotSegments.isEmpty {
            let filtered = dotSegments.filter { !looksLikeSessionIdentifier($0) }
            let candidate = filtered.last ?? dotSegments.last!
            return normalizedWarpTitle(candidate)
        }

        let pathComponent = URL(fileURLWithPath: trimmed).lastPathComponent
        let candidate = pathComponent.isEmpty ? trimmed : pathComponent
        return normalizedWarpTitle(candidate)
    }

    private func titleLooksLikePath(_ title: String) -> Bool {
        title.contains("/") || title.contains("~") || title.hasPrefix(".")
    }

    private func pathTitleMatchesWorkingDirectory(_ title: String, workingDirectory: String) -> Bool {
        let normalizedTitle = normalizedWarpTitle(title)
        let normalizedWorkingDirectory = normalizedWarpTitle(workingDirectory)
        let normalizedBasename = normalizedWarpTitle(URL(fileURLWithPath: workingDirectory).lastPathComponent)

        if normalizedTitle == normalizedBasename {
            return true
        }

        let compactTitle = normalizedTitle.replacingOccurrences(of: " ", with: "")
        let compactWorkingDirectory = normalizedWorkingDirectory.replacingOccurrences(of: " ", with: "")
        return compactWorkingDirectory.hasSuffix(compactTitle) || compactWorkingDirectory.contains(compactTitle)
    }

    private func looksLikeSessionIdentifier(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){2,4}$"#
        return trimmed.range(of: pattern, options: .regularExpression) != nil
    }

    private func getKeyCode(for character: String) -> CGKeyCode? {
        let map: [String: CGKeyCode] = [
            "1": 18, "2": 19, "3": 20, "4": 21, "5": 23,
            "6": 22, "7": 26, "8": 28, "9": 25, "0": 29
        ]
        return map[character]
    }

    private func desiredWarpTabTitle() -> String {
        let trimmedTask = taskName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTask = trimmedTask.isEmpty ? "session" : trimmedTask
        let identifier = agentType == .claudeCode ? String(id.prefix(8)) : String(pid)
        return "ci:\(identifier) \(fallbackTask)"
    }

    private func writeWarpTabTitleIfPossible() {
        writeTTYSequenceIfPossible("\u{001B}[22;0t\u{001B}]0;\(desiredWarpTabTitle())\u{0007}", logLabel: "writeWarpTabTitleIfPossible")
    }

    private func restoreWarpTabTitleIfPossible() {
        writeTTYSequenceIfPossible("\u{001B}[23;0t", logLabel: "restoreWarpTabTitleIfPossible")
    }

    private func writeTTYSequenceIfPossible(_ sequence: String, logLabel: String) {
        guard let ttyPath = resolveTTYPath() else {
            writeLog("[\(logLabel)] No tty for pid=\(pid)")
            return
        }

        guard let data = sequence.data(using: .utf8) else { return }

        let fd = open(ttyPath, O_WRONLY | O_NOCTTY)
        if fd == -1 {
            let err = String(cString: strerror(errno))
            writeLog("[\(logLabel)] open failed tty='\(ttyPath)' errno=\(errno) error='\(err)'")
            return
        }

        defer {
            _ = close(fd)
        }

        let result = data.withUnsafeBytes { buffer in
            write(fd, buffer.baseAddress, buffer.count)
        }

        if result >= 0 {
            writeLog("[\(logLabel)] Wrote sequence bytes=\(data.count) tty='\(ttyPath)'")
        } else {
            let err = String(cString: strerror(errno))
            writeLog("[\(logLabel)] write failed tty='\(ttyPath)' errno=\(errno) error='\(err)'")
        }
    }

    private func resolveTTYPath() -> String? {
        if let cachedTTYPath {
            return cachedTTYPath
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", String(pid), "-o", "tty="]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            guard let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !output.isEmpty,
                output != "??" else {
                return nil
            }

            let ttyPath = output.hasPrefix("/dev/") ? output : "/dev/\(output)"
            cachedTTYPath = ttyPath
            return ttyPath
        } catch {
            writeLog("[resolveTTYPath] Failed for pid=\(pid) error='\(error.localizedDescription)'")
            return nil
        }
    }

    private func jumpToITerm2TabIfPossible() {
        guard let ttyPath = resolveTTYPath() else {
            writeLog("[jumpToITerm2TabIfPossible] No tty for pid=\(pid)")
            return
        }

        let ttyBasename = URL(fileURLWithPath: ttyPath).lastPathComponent
        let escapedFull = appleScriptEscaped(ttyPath)
        let escapedBase = appleScriptEscaped(ttyBasename)

        let script = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            set sessionTTY to tty of s
                            if sessionTTY is "\(escapedFull)" or sessionTTY is "\(escapedBase)" or ("/dev/" & sessionTTY) is "\(escapedFull)" then
                                select w
                                select t
                                activate
                                return "matched"
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
        end tell
        return "not-found"
        """

        let result = runOsaScript(script)
        if result.success {
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            writeLog("[jumpToITerm2TabIfPossible] result='\(output)' tty='\(ttyPath)'")
        } else {
            writeLog("[jumpToITerm2TabIfPossible] failed tty='\(ttyPath)' error='\(result.error)'")
        }
    }

    private func runOsaScript(_ script: String) -> (success: Bool, output: String, error: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe

        do {
            try task.run()
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            let output = String(data: stdoutData, encoding: .utf8) ?? ""
            let error = String(data: stderrData, encoding: .utf8) ?? ""
            return (task.terminationStatus == 0, output, error)
        } catch {
            return (false, "", error.localizedDescription)
        }
    }

    private func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
