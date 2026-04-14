import AppKit
import SwiftUI
import Combine

// CoreGraphics private API for detecting fullscreen spaces. Stable
// for ~10 macOS releases and used by every menu-bar utility (Bartender,
// Hidden Bar, etc.). Public space-aware APIs don't exist.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSGetActiveSpace")
private func CGSGetActiveSpace(_ cid: Int32) -> Int

@_silgen_name("CGSSpaceGetType")
private func CGSSpaceGetType(_ cid: Int32, _ sid: Int) -> Int

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

class NotchWindow: NSPanel {
    private let agentManager: AgentManager
    private var clickOutsideMonitor: Any?
    private var mouseMovedGlobalMonitor: Any?
    private var mouseMovedLocalMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private let panelWidth: CGFloat = 600
    private var compactBarWidth: CGFloat = 340
    private var hostingView: ClickThroughHostingView<IslandView>!
    let viewModel: NotchWindowViewModel

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// `UserDefaults` key for the user's preferred display. Stored as
    /// the CGDirectDisplayID (UInt32 fits in Int). 0 = "Automatic".
    static let preferredDisplayKey = "preferredDisplayID"

    /// Picks the screen the notch should live on:
    ///   1. If the user has set a specific display in Settings, use it.
    ///   2. Otherwise prefer the built-in screen (the one with the
    ///      camera notch / safe-area inset).
    ///   3. Fall back to the menu-bar screen.
    ///
    /// If a stored display ID points at a screen that's no longer
    /// connected, reset the stored value to 0 ("Automatic"). This
    /// makes the Settings dropdown reflect the new state and prevents
    /// the notch from teleporting back to the stale choice if the
    /// display is later reconnected — the user has to opt in again.
    static func preferredScreen() -> NSScreen {
        let stored = UserDefaults.standard.integer(forKey: preferredDisplayKey)
        if stored != 0 {
            for screen in NSScreen.screens {
                if let displayID = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? CGDirectDisplayID,
                   Int(displayID) == stored {
                    return screen
                }
            }
            // Stored ID is gone — reset to Automatic.
            UserDefaults.standard.set(0, forKey: preferredDisplayKey)
        }
        if let builtIn = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            return builtIn
        }
        return NSScreen.screens.first ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Returns (id, label) tuples for every connected display, with
    /// "Automatic" prepended. Used by the Settings picker.
    static func availableDisplayChoices() -> [(id: Int, label: String)] {
        var choices: [(id: Int, label: String)] = [(0, "Automatic")]
        for screen in NSScreen.screens {
            guard let displayID = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID else { continue }
            choices.append((Int(displayID), screen.localizedName))
        }
        return choices
    }

    /// Re-evaluate `preferredScreen()` and move the existing window to
    /// the new screen, recomputing notch geometry. Cheaper and less
    /// risky than tearing down + rebuilding the whole window — keeps
    /// pendingPermissions, pendingAsks, isExpanded etc. intact across
    /// the move.
    func moveToCurrentlyPreferredScreen() {
        let screen = NotchWindow.preferredScreen()
        // No-op if we're already on the right screen.
        if let current = self.screen, current == screen {
            return
        }

        // Recompute the per-screen notch geometry. Mirrors the same
        // logic init() uses: notch screens get a bar sized to clear
        // the camera cutout; non-notch screens use the class default
        // (which is wider than notch ones because nothing constrains
        // it).
        let hasNotch = screen.safeAreaInsets.top > 0
        var notchWidth: CGFloat = 0
        var notchHeight: CGFloat = 0
        if hasNotch {
            notchHeight = screen.safeAreaInsets.top
            if let leftArea = screen.auxiliaryTopLeftArea,
               let rightArea = screen.auxiliaryTopRightArea {
                notchWidth = rightArea.minX - leftArea.maxX
            } else {
                notchWidth = 180
            }
            compactBarWidth = max(250, notchWidth + 80)
        } else {
            compactBarWidth = 340
        }

        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        let barHeight = hasNotch ? max(screen.safeAreaInsets.top, menuBarHeight) : menuBarHeight

        viewModel.notchWidth = notchWidth
        viewModel.notchHeight = notchHeight
        viewModel.topInset = barHeight
        viewModel.compactBarWidth = compactBarWidth
        viewModel.compactBarHeight = barHeight
        viewModel.panelWidth = panelWidth
        viewModel.maxExpandedHeight = screen.frame.height * 0.7 - IslandView.inset

        // Fixed-size window — always at max expanded dimensions.
        let inset = IslandView.inset
        let maxWidth = panelWidth + inset * 2
        let maxHeight = screen.frame.height * 0.7
        let x = screen.frame.midX - maxWidth / 2
        let y = screen.frame.maxY - maxHeight
        let newFrame = NSRect(x: x, y: y, width: maxWidth, height: maxHeight)
        setFrame(newFrame, display: true, animate: false)

        if viewModel.isExpanded {
            updateExpandedContentHeight()
        }

        // Re-evaluate fullscreen hide for the new screen.
        applyFullscreenHidingIfNeeded()
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

        // Fixed-size window: always at max expanded size. All expand/collapse
        // animation is driven by SwiftUI frame changes, not window resize.
        // This keeps the top edge permanently flush with the screen top.
        let inset = IslandView.inset
        let windowWidth = panelWidth + inset * 2
        let windowHeight = screenFrame.height * 0.7
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
        self.acceptsMouseMovedEvents = true
        // Start in "click-through" mode — the TransparentContainerView's
        // tracking area flips this to false only when the cursor enters
        // the visible bar rect, so clicks outside the notch reach the
        // window/app behind us.
        self.ignoresMouseEvents = true

        // Save notch camera region info and sizing for SwiftUI layout.
        viewModel.notchWidth = notchWidth
        viewModel.notchHeight = notchHeight
        viewModel.topInset = barHeight
        viewModel.compactBarWidth = compactBarWidth
        viewModel.compactBarHeight = barHeight
        viewModel.panelWidth = panelWidth
        viewModel.maxExpandedHeight = screenFrame.height * 0.7 - inset

        let rootView = IslandView(agentManager: agentManager, viewModel: viewModel)
        self.hostingView = ClickThroughHostingView(rootView: rootView)

        let container = TransparentContainerView()
        container.wantsLayer = true
        container.layer?.backgroundColor = .clear

        // The window is fixed at max size. Restrict clicks to the
        // currently-visible area (compact bar or expanded panel) so
        // transparent regions pass clicks through to apps below.
        let insetValue = IslandView.inset
        container.allowedHitRectProvider = { [weak self, weak container] in
            guard let self = self, let container = container else { return nil }
            let b = container.bounds
            let vm = self.viewModel

            if vm.isExpanded {
                let visW = vm.panelWidth + insetValue * 2
                let contentH = min(vm.expandedContentHeight + insetValue, vm.maxExpandedHeight + insetValue)
                let x = (b.width - visW) / 2
                let y = b.height - contentH
                return NSRect(x: x, y: y, width: visW, height: contentH)
            }

            // In "Hide in fullscreen" mode — full width strip for easy hover.
            if vm.fullscreenHidden {
                let barH = vm.compactBarHeight
                return NSRect(x: 0, y: b.height - barH, width: b.width, height: barH)
            }

            // Compact bar: centered at top of the window.
            let barW = vm.compactBarWidth + insetValue * 2
            let barH = vm.compactBarHeight + insetValue
            let x = (b.width - barW) / 2
            let y = b.height - barH
            return NSRect(x: x, y: y, width: barW, height: barH)
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

        // When AgentManager sees a hook event that means Claude has
        // moved past a permission/ask prompt, drop any stale banners
        // we're holding for that session.
        agentManager.onSessionPromptsResolved = { [weak self] sessionId in
            self?.viewModel.dismissPendingsForResolvedSession(sessionId: sessionId)
        }

        // Watch for expand/collapse — measure content so SwiftUI can
        // animate the frame. No window resize needed (fixed-size window).
        viewModel.onStateChange = { [weak self] expanded in
            guard let self = self else { return }
            if expanded {
                self.updateExpandedContentHeight()
            }
            // Let cursor-tracking decide ignoresMouseEvents based on
            // whether the cursor is within the visible content area.
            self.syncIgnoresMouseEventsFromCursor()

            // After collapsing, SwiftUI's .onHover won't fire if the
            // cursor is already over the compact bar (no enter transition).
            // Re-check after the collapse animation settles and re-expand
            // if the cursor is still over the bar.
            if !expanded {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self, !self.viewModel.isExpanded else { return }
                    let mouse = NSEvent.mouseLocation
                    if self.currentCompactBarRectInScreen().contains(mouse) {
                        self.viewModel.toggle()
                    }
                }
            }
        }

        // Resize when sessions change (add/remove/replace) OR when an
        // existing AgentSession mutates a layout-affecting field in place
        // (e.g. Codex JSONL polling populates askQuestion on an already-
        // shown session, body text changes length, status flips, etc.).
        //
        // `agentManager.$sessions` only fires for array-level mutations,
        // so we additionally merge each session's own `objectWillChange`
        // publisher. `switchToLatest` throws away the previous merge when
        // the array changes, so child observers are rebuilt on every
        // add/remove without leaking subscriptions. The debounce coalesces
        // burst updates during a single polling pass, and running on the
        // main queue lets the mutation finish before we re-measure —
        // `objectWillChange` fires *before* the value is written.
        agentManager.$sessions
            .map { sessions -> AnyPublisher<Void, Never> in
                let arrayChange = Just(())
                    .setFailureType(to: Never.self)
                    .eraseToAnyPublisher()
                let childChanges = sessions.map { session in
                    session.objectWillChange
                        .map { _ in () }
                        .eraseToAnyPublisher()
                }
                return Publishers.MergeMany([arrayChange] + childChanges)
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            .debounce(for: .milliseconds(16), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self, self.viewModel.isExpanded else { return }
                self.updateExpandedContentHeight()
            }
            .store(in: &cancellables)

        // Setup click detection immediately (don't wait for show())
        setupClickOutsideMonitor()
    }

    func show() {
        alphaValue = 1
        orderFrontRegardless()
        setupClickOutsideMonitor()
        setupMouseTrackingMonitor()
        setupFullscreenMonitor()
        applyFullscreenHidingIfNeeded()
    }

    // MARK: - Hide in fullscreen

    /// Returns true when the currently-active space is a fullscreen
    /// space. Uses CoreGraphics's private `CGSSpaceGetType` — stable
    /// for ~10 macOS releases and what every menu-bar utility uses.
    /// The `frame == visibleFrame` heuristic doesn't work for us
    /// because our notch window has `.canJoinAllSpaces` set, so the
    /// menu bar height we observe stays constant across spaces.
    private func currentSpaceIsFullscreen() -> Bool {
        let sid = CGSGetActiveSpace(CGSMainConnectionID())
        // Type 4 = fullscreen space; 0 = user, 2 = system. The "tile"
        // (Split View) type is also reported as 4.
        return CGSSpaceGetType(CGSMainConnectionID(), sid) == 4
    }

    private func setupFullscreenMonitor() {
        // Active-space change fires when the user enters / leaves a
        // fullscreen app or switches between Mission Control spaces.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyFullscreenHidingIfNeeded()
        }
        // Re-evaluate when the user toggles the setting.
        NotificationCenter.default.addObserver(
            forName: .coderIslandReevaluateFullscreen,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyFullscreenHidingIfNeeded()
        }
        // Re-evaluate when the user picks a different display in
        // Settings, OR when displays are plugged / unplugged
        // (didChangeScreenParameters fires for both).
        NotificationCenter.default.addObserver(
            forName: .coderIslandReevaluateDisplay,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.moveToCurrentlyPreferredScreen()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.moveToCurrentlyPreferredScreen()
        }
    }

    private func applyFullscreenHidingIfNeeded() {
        let enabled = UserDefaults.standard.bool(forKey: "hideInFullscreen")
        let shouldHide = enabled && currentSpaceIsFullscreen()
        // Don't touch alphaValue — we want hover events on the bar
        // location to still expand the panel. The view-model flag
        // tells NotchView to render the compact bar invisibly while
        // keeping its hit area intact, so the user can still move
        // their cursor to the notch and have it pop open.
        if viewModel.fullscreenHidden != shouldHide {
            viewModel.fullscreenHidden = shouldHide
        }
        debugLog("[hideFullscreen] enabled=\(enabled) fs=\(shouldHide)")
    }

    private func setupClickOutsideMonitor() {
        guard clickOutsideMonitor == nil else { return }

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.viewModel.isExpanded else { return }

            let hasAsk = self.agentManager.sessions.contains { $0.askQuestion != nil }
            if hasAsk { return }

            // Check against the visible expanded area, not the full (fixed) window.
            let mouse = NSEvent.mouseLocation
            let inset = IslandView.inset
            let visW = self.viewModel.panelWidth + inset * 2
            let contentH = min(self.viewModel.expandedContentHeight + inset, self.viewModel.maxExpandedHeight + inset)
            let f = self.frame
            let visRect = NSRect(
                x: f.midX - visW / 2,
                y: f.maxY - contentH,
                width: visW,
                height: contentH
            )
            if !visRect.contains(mouse) {
                self.viewModel.collapse()
            }
        }
    }

    /// Dynamically toggle `ignoresMouseEvents` based on whether the cursor
    /// is over the visible bar rect. Needed because a borderless transparent
    /// window otherwise captures clicks in its entire frame, including the
    /// 24pt inset padding around the notch. NSTrackingArea doesn't work here
    /// — `ignoresMouseEvents = true` also blocks tracking area events — so
    /// we poll the global mouse position via NSEvent monitors.
    private func setupMouseTrackingMonitor() {
        // Global monitor fires when cursor moves outside any focused
        // window of our app. Local fires when moving over our own window.
        // Together they cover all cases.
        let handler: (NSEvent?) -> Void = { [weak self] _ in
            self?.syncIgnoresMouseEventsFromCursor()
        }
        if mouseMovedGlobalMonitor == nil {
            mouseMovedGlobalMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved]
            ) { event in handler(event) }
        }
        if mouseMovedLocalMonitor == nil {
            mouseMovedLocalMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved]
            ) { event in
                handler(event)
                return event
            }
        }
        // Initialize once — if the cursor is already sitting over the bar
        // at launch, the first event might be delayed until the user moves.
        syncIgnoresMouseEventsFromCursor()
    }

    /// Compute the visible content rect in screen coordinates and set
    /// ignoresMouseEvents accordingly. Both compact and expanded states
    /// only respond to mouse events within their visible area — the
    /// rest of the fixed-size window is click-through.
    private func syncIgnoresMouseEventsFromCursor() {
        let mouse = NSEvent.mouseLocation  // screen coordinates

        if viewModel.isExpanded {
            let visRect = currentExpandedRectInScreen()
            let shouldIgnore = !visRect.contains(mouse)
            if self.ignoresMouseEvents != shouldIgnore {
                self.ignoresMouseEvents = shouldIgnore
            }
            return
        }

        let barRect = currentCompactBarRectInScreen()
        let shouldIgnore = !barRect.contains(mouse)
        if self.ignoresMouseEvents != shouldIgnore {
            self.ignoresMouseEvents = shouldIgnore
        }
    }

    /// The visible expanded panel area in screen coordinates.
    private func currentExpandedRectInScreen() -> NSRect {
        let f = self.frame
        let inset = IslandView.inset
        let visW = viewModel.panelWidth + inset * 2
        let contentH = min(viewModel.expandedContentHeight + inset, viewModel.maxExpandedHeight + inset)
        let x = f.midX - visW / 2
        let y = f.maxY - contentH
        return NSRect(x: x, y: y, width: visW, height: contentH)
    }

    /// The visible compact bar within the fixed-size window, in screen
    /// coordinates. Bar is centered horizontally, flush with the top.
    private func currentCompactBarRectInScreen() -> NSRect {
        let f = self.frame
        if viewModel.fullscreenHidden {
            let barH = viewModel.compactBarHeight
            return NSRect(x: f.minX, y: f.maxY - barH, width: f.width, height: barH)
        }
        let barW = viewModel.compactBarWidth
        let barH = viewModel.compactBarHeight
        let x = f.midX - barW / 2
        let y = f.maxY - barH
        return NSRect(x: x, y: y, width: barW, height: barH)
    }

    /// Builds an `ExpandedSizingView` (the no-ScrollView mirror of the
    /// expanded panel content) and returns its natural fitting height for
    /// the given content width. Used to size the expanded window so it
    /// snugs to its content up to the 0.7×screen cap.
    private func measureExpandedContentHeight(width: CGFloat) -> CGFloat {
        let activeIds = Set(agentManager.sessions.map(\.id))
        let orphans = viewModel.pendingPermissions.filter { !activeIds.contains($0.sessionId) }
        let topReserved = max(0, viewModel.topInset - 8)
        let sizingRoot = ExpandedSizingView(
            sessions: agentManager.sessions,
            orphans: orphans,
            pendingPermissionsCount: viewModel.pendingPermissions.count,
            pendingAsksCount: viewModel.pendingAsks.count,
            topReservedSpace: topReserved,
            viewModel: viewModel,
            agentManager: agentManager
        )
        // Use `NSHostingController.sizeThatFits(in:)` — the Apple-sanctioned
        // way to measure a SwiftUI subtree's intrinsic height for a given
        // width. `NSHostingView.fittingSize` returns an unwrapped height
        // for multi-line `Text` content (wrapping doesn't happen until a
        // proper layout pass runs), which is why the expanded panel used
        // to clip ask cards whose question text wrapped to a second line.
        let controller = NSHostingController(rootView: sizingRoot)
        let target = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        return controller.sizeThatFits(in: target).height
    }

    /// Measure the expanded content and publish the height so SwiftUI
    /// can animate the visible frame. Called on expand and whenever
    /// content changes while expanded.
    private func updateExpandedContentHeight() {
        let fittingHeight = measureExpandedContentHeight(width: panelWidth)
        viewModel.expandedContentHeight = fittingHeight
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = mouseMovedGlobalMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = mouseMovedLocalMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

// ViewModel shared between window and SwiftUI view
class NotchWindowViewModel: ObservableObject {
    @Published var isExpanded = false
    @Published var pendingPermissions: [PermissionRequest] = []
    @Published var pendingAsks: [AskRequest] = []
    /// Set by `NotchWindow.applyFullscreenHidingIfNeeded` when the
    /// "Hide in fullscreen" setting is on AND the active space is a
    /// fullscreen one. NotchView reads this to render the compact
    /// bar invisibly while keeping its hit area live so the user can
    /// still hover-to-expand.
    @Published var fullscreenHidden: Bool = false
    /// Measured height of expanded content (excluding bottom inset).
    /// Updated by NotchWindow when content changes while expanded.
    @Published var expandedContentHeight: CGFloat = 200
    var notchWidth: CGFloat = 0   // 0 = no notch
    var notchHeight: CGFloat = 0
    /// Vertical space reserved at the top of the expanded panel so content
    /// clears the menu bar area (and the camera cutout on notch Macs).
    /// Computed once by `NotchWindow.init` from `max(safeAreaInsets.top, menuBarHeight)`.
    var topInset: CGFloat = 0
    /// Compact bar dimensions (set by NotchWindow from screen geometry).
    var compactBarWidth: CGFloat = 340
    var compactBarHeight: CGFloat = 37
    /// Expanded panel width (constant).
    var panelWidth: CGFloat = 600
    /// Maximum expanded height (screen * 0.7 minus inset).
    var maxExpandedHeight: CGFloat = 500

    var hasNotch: Bool { notchHeight > 0 }
    var onStateChange: ((Bool) -> Void)?

    /// Shared SwiftUI animation used for content changes while expanded.
    static let expandAnimation: Animation = .spring(response: 0.4, dampingFraction: 0.85)

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
        withAnimation(Self.expandAnimation) {
            pendingPermissions.append(request)
        }
        SoundManager.shared.playPermissionNeeded()
        if !isExpanded && !shouldSuppressAutoExpand(forSessionId: request.sessionId) {
            toggle() // Auto-expand on permission request
        }
        onStateChange?(isExpanded) // Resize window
    }

    func addAsk(_ request: AskRequest) {
        withAnimation(Self.expandAnimation) {
            pendingAsks.append(request)
        }
        SoundManager.shared.playAskQuestion()
        if !isExpanded && !shouldSuppressAutoExpand(forSessionId: request.sessionId) {
            toggle()
        }
        onStateChange?(isExpanded)
    }

    /// "Smart suppression" — when the user is already looking at the
    /// terminal window of the session that's asking, the notch popping
    /// out adds noise on top of what they can already see. Skip the
    /// auto-expand in that case (the request is still added to the
    /// pending list and the sound still plays). Toggle is at
    /// SettingsView → "Smart suppression".
    private func shouldSuppressAutoExpand(forSessionId sessionId: String) -> Bool {
        guard UserDefaults.standard.bool(forKey: "smartSuppression") else {
            debugLog("[smartSuppress] disabled by setting")
            return false
        }
        guard let session = agentManager?.sessions.first(where: { $0.id == sessionId }) else {
            debugLog("[smartSuppress] no session match for sid=\(sessionId.prefix(8))")
            return false
        }
        guard let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName else {
            debugLog("[smartSuppress] no frontmost app")
            return false
        }
        let suppress = (frontmost == session.terminalApp)
        debugLog("[smartSuppress] sid=\(sessionId.prefix(8)) terminal=\(session.terminalApp) frontmost=\(frontmost) → suppress=\(suppress)")
        return suppress
    }

    /// Drop any banners we're holding for `sessionId` because Claude
    /// has clearly moved past the prompt. Called by AgentManager when
    /// it sees a hook event for the session that's not the originating
    /// PermissionRequest / AskUserQuestion (e.g. PostToolUse, Stop,
    /// UserPromptSubmit). Covers the case where the user answered the
    /// prompt directly in the CLI fallback UI instead of clicking the
    /// Coder Island banner — without this, the stale banner sits
    /// forever.
    func dismissPendingsForResolvedSession(sessionId: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let beforePerm = self.pendingPermissions.count
            let beforeAsk = self.pendingAsks.count
            withAnimation(Self.expandAnimation) {
                self.pendingPermissions.removeAll { $0.sessionId == sessionId }
                self.pendingAsks.removeAll { $0.sessionId == sessionId }
            }
            let removed = (beforePerm - self.pendingPermissions.count)
                        + (beforeAsk - self.pendingAsks.count)
            if removed > 0 {
                self.onStateChange?(self.isExpanded)
            }
        }
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
            withAnimation(Self.expandAnimation) {
                self.pendingPermissions.removeAll { $0.id == id }
            }
            HookServer.shared.respondToPermission(requestId: id, decision: decision)
            self.onStateChange?(self.isExpanded)
        }
    }

    func answerAsk(_ id: String, answer: String) {
        // Find the session this ask belongs to and clear its ask data
        let sessionId = pendingAsks.first(where: { $0.id == id })?.sessionId
        withAnimation(Self.expandAnimation) {
            pendingAsks.removeAll { $0.id == id }
        }
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
