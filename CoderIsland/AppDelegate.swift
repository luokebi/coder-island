import AppKit
import SwiftUI
import ApplicationServices

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var islandWindow: NotchWindow?
    private let agentManager = AgentManager()
    private var statusMenu: NSMenu?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestAccessibilityPermissionIfNeeded()
        setupStatusItem()
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

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "island.fill", accessibilityDescription: "Coder Island")
                ?? createPixelIcon()
            button.action = #selector(handleStatusItemClick)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Coder Island", action: #selector(quitApp), keyEquivalent: "q"))
        self.statusMenu = menu
    }

    private func showIsland() {
        let window = NotchWindow(agentManager: agentManager)
        window.show()
        islandWindow = window

        // Auto-expand when Claude asks a question
        agentManager.onAskAppeared = { [weak self] in
            guard let vm = self?.islandWindow?.viewModel, !vm.isExpanded else { return }
            vm.toggle()
        }
    }

    @objc private func handleStatusItemClick() {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            if let menu = statusMenu {
                statusItem.menu = menu
                statusItem.button?.performClick(nil)
                DispatchQueue.main.async { self.statusItem.menu = nil }
            }
            return
        }

        // Left click: toggle expand/collapse
        islandWindow?.viewModel.toggle()
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
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Coder Island Settings"
        window.contentView = NSHostingView(rootView: SettingsView())
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func createPixelIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.systemGreen.setFill()
            let path = NSBezierPath()
            path.appendRoundedRect(
                NSRect(x: 2, y: 4, width: 14, height: 6),
                xRadius: 2, yRadius: 2
            )
            path.fill()
            NSColor.systemBrown.setFill()
            NSBezierPath(rect: NSRect(x: 8, y: 10, width: 2, height: 4)).fill()
            NSColor.systemGreen.setFill()
            let leaf = NSBezierPath(ovalIn: NSRect(x: 5, y: 13, width: 8, height: 4))
            leaf.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
