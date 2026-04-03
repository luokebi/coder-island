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
    case done
    case error
}

class AgentSession: ObservableObject, Identifiable {
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
        lastAssistantMessage: String? = nil
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
        app.activate(options: activateOptions)

        let appName = terminalApp.lowercased()
        if appName.contains("warp") {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) {
                self.writeWarpTabTitleIfPossible()
                self.jumpToWarpTab()
            }
        } else if appName.contains("ghostty") {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) {
                self.jumpToGhosttyTab()
            }
        }
    }

    // MARK: - Ghostty Tab Switching (uses TTY title injection, same as Warp)

    private func jumpToGhosttyTab() {
        let markerTitle = desiredGhosttyTabTitle()
        writeLog("[jumpToGhosttyTab] Called for \(taskName), marker='\(markerTitle)', cached=\(cachedTabNumber ?? -1)")

        // Push current title, then write our marker
        writeTTYSequenceIfPossible("\u{001B}[22;0t", logLabel: "ghosttyPushTitle")  // push
        writeGhosttyTabTitleIfPossible()
        usleep(100000)  // let Ghostty pick up the title

        // Check current tab first
        if matchesGhosttyMarker(markerTitle) {
            writeLog("[jumpToGhosttyTab] Current tab already matches")
            restoreGhosttyTabTitle()
            return
        }

        // Try cached tab
        if let tabNum = cachedTabNumber {
            sendTabSwitchCmd(tabNum)
            usleep(200000)
            if matchesGhosttyMarker(markerTitle) {
                writeLog("[jumpToGhosttyTab] Cached tab \(tabNum) matched")
                restoreGhosttyTabTitle()
                return
            }
            DispatchQueue.main.async { self.cachedTabNumber = nil }
        }

        // Scan all tabs looking for our marker title
        for tab in 1...9 {
            sendTabSwitchCmd(tab)
            usleep(200000)
            if matchesGhosttyMarker(markerTitle) {
                writeLog("[jumpToGhosttyTab] Found at tab \(tab)")
                DispatchQueue.main.async { self.cachedTabNumber = tab }
                restoreGhosttyTabTitle()
                return
            }
        }

        // No match — still restore title
        restoreGhosttyTabTitle()
        writeLog("[jumpToGhosttyTab] No match found")
    }

    private func desiredGhosttyTabTitle() -> String {
        let trimmedTask = taskName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTask = trimmedTask.isEmpty ? "session" : trimmedTask
        let identifier = agentType == .claudeCode ? String(id.prefix(8)) : String(pid)
        return "ci:\(identifier) \(fallbackTask)"
    }

    private func writeGhosttyTabTitleIfPossible() {
        // Push current title, then set our marker (same approach as Warp)
        writeTTYSequenceIfPossible("\u{001B}]0;\(desiredGhosttyTabTitle())\u{0007}", logLabel: "writeGhosttyTitle")
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

    private func sendTabSwitchCmd(_ tabNum: Int) {
        guard let keyCode = getKeyCode(for: String(tabNum)),
              let source = CGEventSource(stateID: .combinedSessionState) else { return }

        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false)

        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand

        cmdDown?.post(tap: .cghidEventTap)
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
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

    private func jumpToWarpTab() {
        let logFile = "/tmp/jump-warp.txt"
        var log = "[jumpToWarpTab] Called for \(taskName), cached=\(cachedTabNumber ?? -1)\n"

        writeLog("[jumpToWarpTab] AXIsProcessTrusted=\(AXIsProcessTrusted())")

        if matchesCurrentWarpTitle() {
            log += "Current front Warp tab already matches\n"
            restoreWarpTabTitleIfPossible()
            try? log.data(using: .utf8)?.write(to: URL(fileURLWithPath: logFile), options: .atomic)
            return
        }

        // Try cached tab first
        if let tabNum = cachedTabNumber {
            log += "Using cached tab \(tabNum)\n"
            sendWarpTabSwitchCmd(tabNum)
            usleep(250000)

            if let title = getWarpWindowTitle() {
                log += "Cached tab title: \(title)\n"
            }

            if matchesCurrentWarpTitle() {
                restoreWarpTabTitleIfPossible()
                try? log.data(using: .utf8)?.write(to: URL(fileURLWithPath: logFile), options: .atomic)
                return
            }

            log += "Cached tab \(tabNum) did not match current title, rescanning\n"
            DispatchQueue.main.async {
                self.cachedTabNumber = nil
            }
        }

        // Try tabs 1-9
        for tab in 1...9 {
            sendWarpTabSwitchCmd(tab)
            usleep(250000)

            if let title = getWarpWindowTitle() {
                log += "Tab \(tab) title: \(title)\n"
            } else {
                log += "Tab \(tab) produced no title\n"
            }

            if matchesCurrentWarpTitle() {
                log += "Found match at tab \(tab)\n"
                DispatchQueue.main.async {
                    self.cachedTabNumber = tab
                }
                restoreWarpTabTitleIfPossible()
                try? log.data(using: .utf8)?.write(to: URL(fileURLWithPath: logFile), options: .atomic)
                return
            }
        }

        restoreWarpTabTitleIfPossible()
        log += "No match found\n"
        try? log.data(using: .utf8)?.write(to: URL(fileURLWithPath: logFile), options: .atomic)
    }

    private func sendWarpTabSwitchCmd(_ tabNum: Int) {
        guard let keyCode = getKeyCode(for: String(tabNum)) else {
            writeLog("[sendWarpTabSwitchCmd] No key code for tab \(tabNum)")
            return
        }

        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            writeLog("[sendWarpTabSwitchCmd] Failed to create CGEventSource")
            return
        }

        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: true)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 55, keyDown: false)

        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand

        cmdDown?.post(tap: .cghidEventTap)
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)

        writeLog("[sendWarpTabSwitchCmd] Sent Cmd+\(tabNum)")
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
}
