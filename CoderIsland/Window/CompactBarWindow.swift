import AppKit
import SwiftUI

class CompactBarWindow: NSPanel {
    private let agentManager: AgentManager
    private let onTap: () -> Void

    init(agentManager: AgentManager, onTap: @escaping () -> Void) {
        self.agentManager = agentManager
        self.onTap = onTap

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let screenFrame = screen.frame
        let hasNotch = screen.safeAreaInsets.top > 0
        let menuBarHeight = screenFrame.maxY - screen.visibleFrame.maxY

        // Size the bar to cover the notch/menu bar area
        let barWidth: CGFloat = hasNotch ? 340 : 300
        let barHeight: CGFloat = hasNotch ? max(screen.safeAreaInsets.top, menuBarHeight) : menuBarHeight

        // Center horizontally, pin to the very top of the screen
        let x = screenFrame.midX - barWidth / 2
        let y = screenFrame.maxY - barHeight

        let frame = NSRect(x: x, y: y, width: barWidth, height: barHeight)

        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Above the menu bar so it covers the notch
        self.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        self.isOpaque = false
        self.backgroundColor = NSColor.clear
        self.hasShadow = false
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = false
        self.hidesOnDeactivate = false
        self.becomesKeyOnlyIfNeeded = true
        self.ignoresMouseEvents = false

        let rootView = CompactBarView(agentManager: agentManager, onTap: onTap)
        let hostingView = NSHostingView(rootView: rootView)

        let container = TransparentContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = .clear

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        self.contentView = container
    }

    func show() {
        alphaValue = 1
        orderFrontRegardless()
    }
}
