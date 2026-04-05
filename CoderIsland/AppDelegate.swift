import AppKit
import SwiftUI
import ApplicationServices

class AppDelegate: NSObject, NSApplicationDelegate {
    private var islandWindow: NotchWindow?
    private let agentManager = AgentManager()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestAccessibilityPermissionIfNeeded()
        registerIslandActions()
        agentManager.startMonitoring()
        showIsland()
        startHookServer()
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
}
