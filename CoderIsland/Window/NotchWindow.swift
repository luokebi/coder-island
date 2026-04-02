import AppKit
import SwiftUI
import Combine

// Container that strips all backgrounds from the NSHostingView hierarchy
class TransparentContainerView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) { /* draw nothing */ }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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

class NotchWindow: NSPanel {
    private let agentManager: AgentManager
    private var clickOutsideMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private let panelWidth: CGFloat = 500
    private let barWidth: CGFloat = 340
    private var hostingView: NSHostingView<IslandView>!
    let viewModel: NotchWindowViewModel

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
        let menuBarHeight = screenFrame.maxY - screen.visibleFrame.maxY
        let barHeight = hasNotch ? max(screen.safeAreaInsets.top, menuBarHeight) : menuBarHeight

        // Start as compact bar — window is wider/taller than content for corner + shadow visibility
        let inset = IslandView.inset
        let windowWidth = barWidth + inset * 2
        let windowHeight = barHeight + inset  // only bottom inset, top flush
        let x = screenFrame.midX - windowWidth / 2
        let y = screenFrame.maxY - windowHeight
        let frame = NSRect(x: x, y: y, width: windowWidth, height: windowHeight)

        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
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
        self.becomesKeyOnlyIfNeeded = true

        // Calculate notch camera region (relative to center of bar)
        var notchWidth: CGFloat = 0
        var notchHeight: CGFloat = 0
        if hasNotch {
            notchHeight = screen.safeAreaInsets.top
            // Derive notch width from auxiliary areas
            if let leftArea = screen.auxiliaryTopLeftArea,
               let rightArea = screen.auxiliaryTopRightArea {
                // Notch is the gap between left and right auxiliary areas
                notchWidth = rightArea.minX - leftArea.maxX
            } else {
                notchWidth = 180  // Fallback: typical MacBook notch width in points
            }
        }
        viewModel.notchWidth = notchWidth
        viewModel.notchHeight = notchHeight

        let rootView = IslandView(agentManager: agentManager, viewModel: viewModel)
        self.hostingView = NSHostingView(rootView: rootView)

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
    }

    func show() {
        alphaValue = 1
        orderFrontRegardless()
        setupClickOutsideMonitor()
    }

    private func setupClickOutsideMonitor() {
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, self.viewModel.isExpanded else { return }
            // Don't collapse if there's a pending ask question
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
            targetWidth = barWidth + inset * 2
            let barH = hasNotch ? max(screen.safeAreaInsets.top, menuBarHeight) : menuBarHeight
            targetHeight = barH + inset
        }

        let topY = screenFrame.maxY
        let x = screenFrame.midX - targetWidth / 2
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
        if !isExpanded {
            toggle() // Auto-expand on permission request
        }
        onStateChange?(isExpanded) // Resize window
    }

    func addAsk(_ request: AskRequest) {
        pendingAsks.append(request)
        if !isExpanded {
            toggle()
        }
        onStateChange?(isExpanded)
    }

    func allowPermission(_ id: String) {
        pendingPermissions.removeAll { $0.id == id }
        HookServer.shared.respondToPermission(requestId: id, allow: true)
        onStateChange?(isExpanded)
    }

    func denyPermission(_ id: String) {
        pendingPermissions.removeAll { $0.id == id }
        HookServer.shared.respondToPermission(requestId: id, allow: false)
        onStateChange?(isExpanded)
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
