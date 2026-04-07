import AppKit
import SwiftUI
import Combine

class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// Container that strips all backgrounds from the NSHostingView hierarchy
class TransparentContainerView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) { /* draw nothing */ }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Rect in the container's own coordinates where clicks should land on
    /// our content. Points outside are click-through to the window below.
    /// Return `nil` to allow hits anywhere (default / expanded state).
    var allowedHitRectProvider: (() -> NSRect?)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` arrives in the superview's coordinate space; convert to ours.
        let local = convert(point, from: superview)
        if let allowed = allowedHitRectProvider?(), !allowed.contains(local) {
            return nil
        }
        return super.hitTest(point)
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        clearBackgrounds(of: subview)
    }

    override func layout() {
        super.layout()
        for sub in self.descendants {
            clearBackgrounds(of: sub)
        }
    }

    private func clearBackgrounds(of view: NSView) {
        view.wantsLayer = true
        view.layer?.backgroundColor = .clear
        view.layer?.isOpaque = false
        if let effectView = view as? NSVisualEffectView {
            effectView.state = .inactive
            effectView.material = .underWindowBackground
            effectView.alphaValue = 0
        }
    }
}

private extension NSView {
    var descendants: [NSView] {
        subviews + subviews.flatMap { $0.descendants }
    }
}

class NotchWindow: NSWindow {
    private let agentManager: AgentManager
    private var clickOutsideMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private let panelWidth: CGFloat = 500
    private var compactBarWidth: CGFloat = 340
    private var hostingView: ClickThroughHostingView<IslandView>!
    let viewModel: NotchWindowViewModel

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Find the built-in display (has notch), or fall back to main screen
    private static func preferredScreen() -> NSScreen {
        // Prefer the built-in screen (the one with the notch)
        if let builtIn = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return builtIn
        }
        // Fall back to the screen with the menu bar
        return NSScreen.screens.first ?? NSScreen.main ?? NSScreen.screens[0]
    }

    init(agentManager: AgentManager) {
        self.agentManager = agentManager
        self.viewModel = NotchWindowViewModel()
        self.viewModel.agentManager = agentManager

        let screen = NotchWindow.preferredScreen()
        let screenFrame = screen.frame
        let hasNotch = screen.safeAreaInsets.top > 0

        // Calculate notch camera region first so compact width can adapt on notch Macs.
        var notchWidth: CGFloat = 0
        var notchHeight: CGFloat = 0
        if hasNotch {
            notchHeight = screen.safeAreaInsets.top
            if let leftArea = screen.auxiliaryTopLeftArea,
               let rightArea = screen.auxiliaryTopRightArea {
                notchWidth = rightArea.minX - leftArea.maxX
            } else {
                notchWidth = 180  // Fallback: typical MacBook notch width in points
            }

            // Use notch width as the center text lane baseline, plus a little
            // room on both sides for the left icon and right badge.
            compactBarWidth = max(250, notchWidth + 80)
        }

        let menuBarHeight = screenFrame.maxY - screen.visibleFrame.maxY
        let barHeight = hasNotch ? max(screen.safeAreaInsets.top, menuBarHeight) : menuBarHeight

        // Start as compact bar — window is wider/taller than content for corner + shadow visibility
        let inset = IslandView.inset
        let windowWidth = compactBarWidth + inset * 2
        let windowHeight = barHeight + inset  // only bottom inset, top flush
        let compactHorizontalNudge: CGFloat = hasNotch ? 11 : 0
        let x = screenFrame.midX - windowWidth / 2 + compactHorizontalNudge
        let y = screenFrame.maxY - windowHeight
        let frame = NSRect(x: x, y: y, width: windowWidth, height: windowHeight)

        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        self.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        self.isOpaque = false
        self.backgroundColor = NSColor.clear
        self.hasShadow = false
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = false
        self.hidesOnDeactivate = false
        self.acceptsMouseMovedEvents = true
        self.ignoresMouseEvents = false

        // Save notch camera region info for SwiftUI layout.
        viewModel.notchWidth = notchWidth
        viewModel.notchHeight = notchHeight

        let rootView = IslandView(agentManager: agentManager, viewModel: viewModel)
        self.hostingView = ClickThroughHostingView(rootView: rootView)

        let container = TransparentContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = .clear

        // When collapsed, restrict clicks to the visible bar rect so the
        // transparent inset padding around the notch (used only for shadow
        // headroom) doesn't block clicks to whatever window is underneath.
        // When expanded, allow the whole content area (closure returns nil).
        let insetValue = IslandView.inset
        container.allowedHitRectProvider = { [weak self, weak container] in
            guard let self = self, let container = container else { return nil }
            if self.viewModel.isExpanded { return nil }
            // Visible bar: top is flush to window top, has side+bottom insets.
            let b = container.bounds
            return NSRect(
                x: b.minX + insetValue,
                y: b.minY + insetValue,
                width: b.width - insetValue * 2,
                height: b.height - insetValue
            )
        }

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        self.contentView = container

        // Watch for expand/collapse to resize window
        viewModel.onStateChange = { [weak self] expanded in
            self?.animateWindowResize(expanded: expanded)
        }

        // Also resize when sessions change (e.g. ask card appears/disappears)
        agentManager.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self, self.viewModel.isExpanded else { return }
                self.animateWindowResize(expanded: true)
            }
            .store(in: &cancellables)

        // Setup click detection immediately (don't wait for show())
        setupClickOutsideMonitor()
    }

    func show() {
        alphaValue = 1
        orderFrontRegardless()
        setupClickOutsideMonitor()
    }

    private func setupClickOutsideMonitor() {
        guard clickOutsideMonitor == nil else { return }

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.viewModel.isExpanded else { return }

            let hasAsk = self.agentManager.sessions.contains { $0.askQuestion != nil }
            if hasAsk { return }
            if !self.frame.contains(NSEvent.mouseLocation) {
                self.viewModel.collapse()
            }
        }
    }

    private func animateWindowResize(expanded: Bool) {
        let screen = self.screen ?? NotchWindow.preferredScreen()
        let screenFrame = screen.frame
        let hasNotch = screen.safeAreaInsets.top > 0
        let menuBarHeight = screenFrame.maxY - screen.visibleFrame.maxY
        let inset = IslandView.inset

        let targetWidth: CGFloat
        let targetHeight: CGFloat

        if expanded {
            targetWidth = panelWidth + inset * 2

            // Measure fitting size using a detached sizing view to avoid triggering layout
            let sizingView = NSHostingView(rootView: hostingView.rootView)
            sizingView.frame.size.width = targetWidth
            let fitting = sizingView.fittingSize
            targetHeight = min(fitting.height, screenFrame.height * 0.7)
        } else {
            targetWidth = compactBarWidth + inset * 2
            let barH = hasNotch ? max(screen.safeAreaInsets.top, menuBarHeight) : menuBarHeight
            targetHeight = barH + inset
        }

        let topY = screenFrame.maxY
        let compactHorizontalNudge: CGFloat = (!expanded && hasNotch) ? 11 : 0
        let x = screenFrame.midX - targetWidth / 2 + compactHorizontalNudge
        let y = topY - targetHeight
        let newFrame = NSRect(x: x, y: y, width: targetWidth, height: targetHeight)

        // Single smooth animation for width + height together
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.4
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            self.animator().setFrame(newFrame, display: true)
        }
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

// ViewModel shared between window and SwiftUI view
class NotchWindowViewModel: ObservableObject {
    @Published var isExpanded = false
    @Published var pendingPermissions: [PermissionRequest] = []
    @Published var pendingAsks: [AskRequest] = []
    var notchWidth: CGFloat = 0   // 0 = no notch
    var notchHeight: CGFloat = 0

    var hasNotch: Bool { notchHeight > 0 }
    var onStateChange: ((Bool) -> Void)?

    func toggle() {
        isExpanded.toggle()
        onStateChange?(isExpanded)
    }

    func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        onStateChange?(false)
    }

    func addPermission(_ request: PermissionRequest) {
        pendingPermissions.append(request)
        SoundManager.shared.playPermissionNeeded()
        if !isExpanded {
            toggle() // Auto-expand on permission request
        }
        onStateChange?(isExpanded) // Resize window
    }

    func addAsk(_ request: AskRequest) {
        pendingAsks.append(request)
        SoundManager.shared.playAskQuestion()
        if !isExpanded {
            toggle()
        }
        onStateChange?(isExpanded)
    }

    func allowPermission(_ id: String) {
        respondPermissionDeferred(id: id, decision: .allow)
    }

    /// Allow the current request and persist the rule via Claude Code's own
    /// `updatedPermissions` mechanism — no manual settings.json writes needed.
    func allowPermissionAlways(_ id: String) {
        respondPermissionDeferred(id: id, decision: .allowAlways)
    }

    func denyPermission(_ id: String) {
        respondPermissionDeferred(id: id, decision: .deny)
    }

    private func respondPermissionDeferred(id: String, decision: PermissionDecisionKind) {
        // Defer to the next run loop tick to avoid SwiftUI reentrancy:
        // the click handler must return before we mutate @Published state
        // and trigger a window resize (which measures the view tree).
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pendingPermissions.removeAll { $0.id == id }
            HookServer.shared.respondToPermission(requestId: id, decision: decision)
            self.onStateChange?(self.isExpanded)
        }
    }

    func answerAsk(_ id: String, answer: String) {
        // Find the session this ask belongs to and clear its ask data
        let sessionId = pendingAsks.first(where: { $0.id == id })?.sessionId
        pendingAsks.removeAll { $0.id == id }
        HookServer.shared.respondToAsk(requestId: id, answer: answer)

        // Clear JSONL-detected ask for the same session so it doesn't linger
        if let sid = sessionId, let agentManager = agentManager {
            if let idx = agentManager.sessions.firstIndex(where: { $0.id == sid }) {
                agentManager.sessions[idx].askQuestion = nil
                agentManager.sessions[idx].askOptions = nil
            }
        }
        onStateChange?(isExpanded)
    }

    weak var agentManager: AgentManager?
}

/// Writes permission allow-rules into Claude Code's settings files so that
/// "Yes, and don't ask again for ..." persists across future requests.
enum PermissionRuleWriter {
    /// Append the given rule strings to `permissions.allow` in the project-local
    /// settings file (`<cwd>/.claude/settings.local.json`). Falls back to the
    /// user-level `~/.claude/settings.json` if cwd is empty.
    static func addAllowRules(_ rules: [String], cwd: String) {
        guard !rules.isEmpty else { return }

        let target: URL
        if !cwd.isEmpty {
            let dir = URL(fileURLWithPath: cwd).appendingPathComponent(".claude", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            target = dir.appendingPathComponent("settings.local.json")
        } else {
            target = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/settings.json")
        }

        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: target),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = existing
        }

        var permissions = settings["permissions"] as? [String: Any] ?? [:]
        var allow = permissions["allow"] as? [String] ?? []
        for rule in rules where !allow.contains(rule) {
            allow.append(rule)
        }
        permissions["allow"] = allow
        settings["permissions"] = permissions

        if let out = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: target)
            debugLog("[PermissionRuleWriter] Added \(rules) to \(target.path)")
        }
    }
}
