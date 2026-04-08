import AppKit
import SwiftUI
import ApplicationServices

class AppDelegate: NSObject, NSApplicationDelegate {
    private var islandWindow: NotchWindow?
    private let agentManager = AgentManager()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register default values for any UserDefaults key that
        // non-View code reads — `@AppStorage("foo") = true` only
        // affects the SwiftUI binding's initial value, not the
        // underlying UserDefaults, so without this our suppression /
        // settings code reads false until the user first toggles.
        UserDefaults.standard.register(defaults: [
            "smartSuppression": true,
            "showUsageLimits": true,
        ])

        // Optional test hooks: run parser regression tests and log to
        // ~/Library/Logs/CoderIsland/parser-tests.log or
        // ~/Library/Logs/CoderIsland/codex-parser-tests.log. Triggered by
        // launching with env vars or command-line args.
        let env = ProcessInfo.processInfo.environment
        let args = ProcessInfo.processInfo.arguments
        if env["CODER_ISLAND_RUN_PARSER_TESTS"] == "1" || args.contains("--run-parser-tests") {
            let summary = ParserTests.runAll()
            debugLog("[ParserTests] \(summary)")
        }
        if env["CODER_ISLAND_RUN_CODEX_PARSER_TESTS"] == "1" || args.contains("--run-codex-parser-tests") {
            let summary = CodexParserTests.runAll()
            debugLog("[CodexParserTests] \(summary)")
        }
        if env["CODER_ISLAND_DEBUG_USAGE_PROBE"] == "1" || args.contains("--debug-usage-probe") {
            // Fire-and-log: dumps `claude /usage` and `codex /status` raw
            // PTY output to ~/Library/Logs/CoderIsland/usage-probe-debug.log
            // so we can hand-write the parser against the actual format.
            Task.detached(priority: .background) {
                await UsageProbeDebug.runOnce()
            }
        }

        // Sync the cached "Launch at login" pref from the system source
        // of truth — the user may have toggled it off in System Settings
        // → General → Login Items between runs.
        UserDefaults.standard.set(LoginItemHelper.currentlyEnabled(),
                                  forKey: "launchAtLogin")

        requestAccessibilityPermissionIfNeeded()
        registerIslandActions()
        agentManager.startMonitoring()
        showIsland()
        startHookServer()
        UsageManager.shared.start()
    }

    private func requestAccessibilityPermissionIfNeeded() {
        let bundlePath = Bundle.main.bundleURL.path
        let isTrusted = AXIsProcessTrusted()
        debugLog("[Accessibility] bundlePath='\(bundlePath)' trusted=\(isTrusted)")

        guard !isTrusted else { return }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let prompted = AXIsProcessTrustedWithOptions(options)
        debugLog("[Accessibility] prompted trusted=\(prompted)")
    }

    private func showIsland() {
        let window = NotchWindow(agentManager: agentManager)
        window.show()
        islandWindow = window

        // Auto-expand when Claude asks a question
        agentManager.onAskAppeared = { [weak self] in
            SoundManager.shared.playAskQuestion()
            guard let vm = self?.islandWindow?.viewModel, !vm.isExpanded else { return }
            vm.toggle()
        }
    }

    private func registerIslandActions() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettings),
            name: .coderIslandOpenSettings,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(quitApp),
            name: .coderIslandQuitApp,
            object: nil
        )
    }

    private func startHookServer() {
        let server = HookServer.shared
        server.start()

        server.onPermissionRequest = { [weak self] request in
            self?.islandWindow?.viewModel.addPermission(request)
        }

        server.onAskQuestion = { [weak self] request in
            self?.islandWindow?.viewModel.addAsk(request)
        }

        server.onLifecycleEvent = { [weak self] eventName, sessionId, agentId, toolName, toolInput, errorMessage in
            self?.agentManager.applyHookEvent(
                eventName: eventName,
                sessionId: sessionId,
                agentId: agentId,
                toolName: toolName,
                toolInput: toolInput,
                errorMessage: errorMessage
            )
        }

        // Keep hook scripts & settings.json in sync with the current app version.
        // If the user has the toggle on, re-run install() so any script/matcher
        // changes from an app update take effect without manual toggling.
        if UserDefaults.standard.bool(forKey: "askHooksEnabled") {
            HookInstaller.shared.install()
        }
    }

    @objc private func openSettings() {
        islandWindow?.viewModel.collapse()

        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Coder Island Settings"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor.black
        window.contentView = NSHostingView(rootView: SettingsView())
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    @objc private func quitApp() {
        islandWindow?.viewModel.collapse()

        let alert = NSAlert()
        alert.messageText = "Quit Coder Island?"
        alert.informativeText = "This will close Coder Island and stop monitoring sessions."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

extension Notification.Name {
    static let coderIslandOpenSettings = Notification.Name("coderIslandOpenSettings")
    static let coderIslandQuitApp = Notification.Name("coderIslandQuitApp")
    static let coderIslandReevaluateFullscreen = Notification.Name("coderIslandReevaluateFullscreen")
    static let coderIslandReevaluateDisplay = Notification.Name("coderIslandReevaluateDisplay")
}
