import SwiftUI

struct IslandView: View {
    @ObservedObject var agentManager: AgentManager
    @ObservedObject var viewModel: NotchWindowViewModel

    @State private var isHovered = false
    @State private var hoverTimer: Timer?
    /// Staggered content visibility — content fades in AFTER the shape
    /// finishes expanding, and fades out BEFORE the shape starts collapsing.
    @State private var expandedContentVisible = false
    @State private var compactContentVisible = true
    @State private var showControlMenu = false
    @State private var isGearHovered = false
    @State private var isSettingsHovered = false
    @State private var isSoundHovered = false
    @State private var isQuitHovered = false
    @State private var hoveredUsageButton: AgentType?
    @State private var usagePopoverShowTimer: Timer?
    @State private var usagePopoverDismissTimer: Timer?
    @ObservedObject private var usageManager: UsageManager = .shared
    @AppStorage("soundEnabled") private var soundEnabled: Bool = true
    #if DEBUG
    /// Live-bound to the same UserDefault the Settings toggle writes.
    /// When > 0, the overlay draws a fake camera cutout at this width.
    @AppStorage("debug.simulatedNotchWidth") private var simulatedNotchWidth: Double = 0
    /// Matches the height NotchWindow.resolveNotchGeometry uses (32pt
    /// ≈ MacBook Pro 14"/16" notch height).
    private let simulatedNotchHeight: CGFloat = 32
    #endif

    private let barColor = Color.black
    private let usagePopoverShowDelay: TimeInterval = 0.15
    private let usageButtonSize = CGSize(width: 26, height: 22)
    private let usageButtonSpacing: CGFloat = 12
    private let usageOverlayTopInset: CGFloat = 6
    private let usageOverlayLeadingInset: CGFloat = 12
    private let usagePopoverTopGap: CGFloat = 8
    // Extra padding around the shape so corners + shadow are visible
    static let inset: CGFloat = 24

    /// Compact bar content (icon, name, badge) is invisible to humans
    /// in fullscreen-hidden mode. Note we use 0.001 instead of 0 —
    /// SwiftUI disables hit testing on views with `.opacity(0)`, which
    /// would silently break hover-to-expand. 0.001 is below the human
    /// visibility threshold but keeps SwiftUI delivering events.
    private var compactBarOpacity: Double {
        if viewModel.isExpanded { return 0.001 }
        if viewModel.fullscreenHidden { return 0.001 }
        return 1
    }

    /// The bar background shape disappears completely in
    /// fullscreen-hidden mode (the .background isn't part of the hit
    /// path, so 0 here is fine).
    private var barShapeOpacity: Double {
        if viewModel.fullscreenHidden && !viewModel.isExpanded { return 0 }
        return 1
    }

    var body: some View {
        let targetWidth = viewModel.isExpanded ? viewModel.panelWidth : viewModel.compactBarWidth
        let targetHeight: CGFloat = viewModel.isExpanded
            ? min(viewModel.expandedContentHeight, viewModel.maxExpandedHeight)
            : viewModel.compactBarHeight

        ZStack(alignment: .top) {
            compactContent
                .allowsHitTesting(!viewModel.isExpanded)
                .onHover { hovering in
                    handleHoverChange(hovering)
                }
                .opacity(compactContentVisible ? compactBarOpacity : 0.001)

            if viewModel.isExpanded {
                expandedContent
                    .onHover { hovering in
                        handleHoverChange(hovering)
                    }
                    .opacity(expandedContentVisible ? 1 : 0)
            }
        }
        .frame(width: targetWidth, height: targetHeight,
               alignment: viewModel.isExpanded ? .top : .center)
        .clipped()
        .padding(.horizontal, Self.inset)
        .padding(.bottom, Self.inset)
        .frame(width: targetWidth + Self.inset * 2, height: targetHeight + Self.inset, alignment: .top)
        .background(
            NotchShape(
                    topCornerRadius: viewModel.isExpanded ? 16 : 8,
                    bottomCornerRadius: viewModel.isExpanded ? 20 : 14
                )
                .fill(barColor)
                .padding(.horizontal, Self.inset)
                .padding(.bottom, Self.inset)
                .shadow(
                    color: (isHovered || viewModel.isExpanded) ? .black.opacity(0.5) : .clear,
                    radius: (isHovered || viewModel.isExpanded) ? 8 : 0, y: 3
                )
                .opacity(barShapeOpacity)
        )
        // Don't pad top — stays flush with screen edge
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        #if DEBUG
        // Simulated hardware notch — visible only when the debug
        // "Simulate notch" setting is on. Renders a solid black
        // rectangle at the top-center at the configured width and
        // height so developers on non-notch Macs can see how the
        // compact bar wraps around a camera cutout. Placed as an
        // overlay so it sits above the bar and animation layers.
        .overlay(alignment: .top) {
            if simulatedNotchWidth > 0 {
                Rectangle()
                    .fill(Color.black)
                    .frame(width: simulatedNotchWidth, height: simulatedNotchHeight)
                    .allowsHitTesting(false)
            }
        }
        #endif
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: viewModel.isExpanded)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: viewModel.expandedContentHeight)
        .onChange(of: viewModel.isExpanded) { expanded in
            if expanded {
                // Compact fades out immediately
                withAnimation(.easeOut(duration: 0.1)) {
                    compactContentVisible = false
                }
                // Expanded content fades in after shape starts growing
                withAnimation(.easeOut(duration: 0.25).delay(0.12)) {
                    expandedContentVisible = true
                }
            } else {
                // Expanded content fades out quickly
                withAnimation(.easeOut(duration: 0.1)) {
                    expandedContentVisible = false
                }
                // Compact fades in after shape finishes shrinking
                withAnimation(.easeOut(duration: 0.25).delay(0.15)) {
                    compactContentVisible = true
                }
            }
        }
    }

    private func handleHoverChange(_ hovering: Bool) {
        withAnimation(.easeInOut(duration: 0.2)) {
            isHovered = hovering
        }
        hoverTimer?.invalidate()

        if hovering {
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
                if !viewModel.isExpanded {
                    viewModel.toggle()
                }
            }
        } else {
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { _ in
                // Don't collapse if there's a pending ask question
                let hasAsk = agentManager.sessions.contains { $0.askQuestion != nil }
                // Don't collapse if the cursor is still over the visible
                // panel. `.onHover(false)` can fire spuriously on the
                // compact view when `.allowsHitTesting` flips off during
                // expand, and the expanded view's `.onHover(true)` doesn't
                // fire when the mouse is already inside it at appear-time
                // — checking the OS cursor position is the reliable signal.
                // Without this, hovering the empty-state compact bar would
                // oscillate: expand → spurious hover(false) → collapse →
                // re-expand (via the onStateChange recovery) → repeat.
                if viewModel.isCursorOverVisibleRect?() == true { return }
                if viewModel.isExpanded && !hasAsk {
                    viewModel.collapse()
                }
            }
        }
    }

    // MARK: - Compact Bar

    private var compactContent: some View {
        HStack(spacing: 6) {
            if agentManager.sessions.isEmpty && viewModel.pendingPermissions.isEmpty {
                // Flank with Spacers so the icon + text stay centered when
                // the HStack fills the full bar width (see frame below).
                Spacer(minLength: 0)
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
                Text("No agents")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.gray)
                Spacer(minLength: 0)
            } else if let first = agentManager.sessions.first {
                // Priority for what to surface in the compact bar:
                // 1) session with a pending permission (hook-based)
                // 2) session that's waiting (ask/permission via jsonl fallback)
                // 3) first session
                let permSession = agentManager.sessions.first { s in
                    viewModel.pendingPermissions.contains { $0.sessionId == s.id }
                }
                let askSession = agentManager.sessions.first(where: { $0.status == .waiting })
                let displaySession = permSession ?? askSession ?? first
                let displayHasPermission = permSession != nil && displaySession.id == permSession?.id

                // Sprite + status indicator — extracted so the subview can
                // @ObservedObject the AgentSession directly. Without that,
                // NotchView only observes `agentManager` and
                // agentManager.sessions[i].status mutations don't trigger
                // a re-render here (class AgentSession is held by
                // reference, array identity is unchanged). Result was
                // compact bar stuck on the old indicator (e.g. CometTrail
                // from a prior .running) after the session transitioned
                // to .justFinished.
                CompactSpriteAndIndicator(
                    session: displaySession,
                    hasPendingPermission: displayHasPermission
                )

                // Task name: only show on non-notch Macs. On notch Macs
                // the name would render behind the camera cutout and be
                // invisible anyway; suppressing it lets the HStack's
                // Spacer pull the right-side badge all the way to the
                // right shoulder instead of crowding near the cutout.
                if !viewModel.hasNotch {
                    Text(displaySession.taskName)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(displaySession.status.isRecentlyFinished ? .gray : .white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 160, alignment: .leading)
                        .layoutPriority(1)
                }

                // Subtitle: hidden on notch Macs (it would render behind the
                // camera cutout anyway). On non-notch Macs it expands to fill
                // all remaining width, text right-aligned so short subtitles
                // sit near the indicator and long ones get the full gap.
                let subtitleInfo: (text: String, color: Color)? = {
                    if displayHasPermission {
                        return ("Permission needed", .orange.opacity(0.85))
                    }
                    if displaySession.status == .waiting {
                        return ("Waiting for answer...", .orange.opacity(0.8))
                    }
                    if displaySession.status.isRecentlyFinished {
                        return ("Just finished", Color(nsColor: .systemGreen).opacity(0.85))
                    }
                    if let subtitle = displaySession.subtitle, !subtitle.isEmpty {
                        return (subtitle, .white.opacity(0.6))
                    }
                    return nil
                }()

                if !viewModel.hasNotch, let sub = subtitleInfo {
                    Text(sub.text)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(sub.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.leading, 8)
                } else {
                    Spacer(minLength: 0)
                }

                // Right indicator: ! for pending permission, ? for ask/waiting, count otherwise
                let hasWaiting = agentManager.sessions.contains { $0.status == .waiting }
                let hasAnyPermission = !viewModel.pendingPermissions.isEmpty
                if hasAnyPermission {
                    PixelStatusIcon(
                        pixels: [(1,0),(1,1),(1,2),(1,3),(1,5)],
                        color: .orange
                    )
                    .scaleEffect(0.9)
                } else if hasWaiting {
                    PixelStatusIcon(
                        pixels: [(1,0),(2,0),(3,1),(2,2),(1,3),(1,5)],
                        color: .orange
                    )
                    .scaleEffect(0.9)
                } else if agentManager.sessions.count > 1 {
                    Text("\(agentManager.sessions.count)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            // Match TagBadge: explicit RGB so the fill
                            // survives older macOS compositors.
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(red: 0.19, green: 0.19, blue: 0.21))
                        )
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // Keep only a small extra inset on notch Macs to avoid over-compressing text.
        .padding(.horizontal, viewModel.hasNotch ? 0 : 0)
        // Fill the full compact bar so the hover area covers the entire
        // visible strip (incl. the wings around the camera cutout) — not
        // just the centered icon/text. `contentShape` makes transparent
        // regions receive hover events.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: - Expanded Panel

    private var orphanPermissions: [PermissionRequest] {
        let activeSessionIds = Set(agentManager.sessions.map(\.id))
        return viewModel.pendingPermissions.filter { !activeSessionIds.contains($0.sessionId) }
    }

    @ViewBuilder
    private func orphanPermissionBanner(_ req: PermissionRequest) -> some View {
        PermissionBannerView(
            request: req,
            onAllow: { viewModel.allowPermission(req.id) },
            onAllowAlways: { viewModel.allowPermissionAlways(req.id) },
            onDeny: { viewModel.denyPermission(req.id) }
        )
    }

    private var expandedContent: some View {
        expandedContentBody
            .contentShape(Rectangle())
            .contextMenu {
                Button("Settings...") {
                    viewModel.collapse()
                    NotificationCenter.default.post(name: .coderIslandOpenSettings, object: nil)
                }
                Button(soundEnabled ? "Mute Sound Effects" : "Unmute Sound Effects") {
                    soundEnabled.toggle()
                }
                Divider()
                Button("Quit Coder Island") {
                    NotificationCenter.default.post(name: .coderIslandQuitApp, object: nil)
                }
            }
    }

    private var expandedContentBody: some View {
        VStack(spacing: 4) {
            Spacer().frame(height: topReservedSpace)

            // Orphan permission banners: requests whose sessionId doesn't match any
            // active session are rendered at the top so they're not lost. Kept
            // OUTSIDE the ScrollView so they stay pinned and can't be scrolled
            // away — they're a critical fallback interaction.
            ForEach(orphanPermissions) { req in
                orphanPermissionBanner(req)
            }

            if agentManager.sessions.isEmpty && viewModel.pendingPermissions.isEmpty && viewModel.pendingAsks.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(agentManager.sessions) { session in
                            SessionCard(session: session, viewModel: viewModel, agentManager: agentManager)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .top)
        .overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                usageButtonsOverlay

                if let hoveredUsageButton {
                    usagePopover(for: hoveredUsageButton, usage: aggregatedUsage(for: hoveredUsageButton))
                        .fixedSize()
                        .onHover { hovering in
                            handleUsageHover(type: hoveredUsageButton, hovering: hovering, source: .popover)
                        }
                        .padding(.leading, usagePopoverLeadingOffset(for: hoveredUsageButton))
                        .padding(.top, usageButtonSize.height + usagePopoverTopGap)
                }
            }
            // Icons sit on the left edge, beside the camera cutout —
            // they don't need to be pushed below it. Use the same
            // small offset for notch and non-notch Macs.
            .padding(.top, usageOverlayTopInset)
            .padding(.leading, usageOverlayLeadingInset)
        }
        .overlay(alignment: .topTrailing) {
            ZStack(alignment: .topTrailing) {
                if showControlMenu {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            showControlMenu = false
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea()
                }

                VStack(alignment: .trailing, spacing: 6) {
                    Button {
                        showControlMenu.toggle()
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(isGearHovered ? Color.white.opacity(0.20) : Color.clear)
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white.opacity(0.95))
                        }
                        .frame(width: 24, height: 20)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isGearHovered = hovering
                    }

                    if showControlMenu {
                        VStack(spacing: 0) {
                            Button {
                                showControlMenu = false
                                viewModel.collapse()
                                NotificationCenter.default.post(name: .coderIslandOpenSettings, object: nil)
                            } label: {
                                HStack(spacing: 0) {
                                    Text("Settings...")
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(isSettingsHovered ? Color.white.opacity(0.16) : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                isSettingsHovered = hovering
                            }

                            Button {
                                showControlMenu = false
                                soundEnabled.toggle()
                            } label: {
                                HStack(spacing: 0) {
                                    Text(soundEnabled ? "Mute Sound Effects" : "Unmute Sound Effects")
                                        .lineLimit(1)
                                        .fixedSize()
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(isSoundHovered ? Color.white.opacity(0.16) : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                isSoundHovered = hovering
                            }

                            Button {
                                showControlMenu = false
                                NotificationCenter.default.post(name: .coderIslandQuitApp, object: nil)
                            } label: {
                                HStack(spacing: 0) {
                                    Text("Quit Coder Island")
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(isQuitHovered ? Color.red.opacity(0.20) : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.red.opacity(0.9))
                            .onHover { hovering in
                                isQuitHovered = hovering
                            }
                        }
                        .padding(6)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .frame(minWidth: 170, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: true)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.black.opacity(0.92))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                                )
                        )
                        .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
                        .padding(.top, 2)
                    }
                }
            }
            .padding(.top, 6)
            .padding(.trailing, 12)
        }
    }

    // MARK: - Usage Buttons (top-left of expanded panel)

    @AppStorage("showUsageLimits") private var showUsageLimits = true
    @AppStorage("showUsageInline") private var showUsageInline = true

    @ViewBuilder
    private var usageButtonsOverlay: some View {
        if showUsageLimits {
            HStack(spacing: usageButtonSpacing) {
                usageButton(for: .claudeCode)
                usageButton(for: .codex)
            }
        }
    }

    @ViewBuilder
    private func usageButton(for type: AgentType) -> some View {
        let usage = aggregatedUsage(for: type)
        let isHovering = hoveredUsageButton == type
        let isAvailable = usage != nil
        let primary: Int? = usage?.primaryPercentUsed.map { max(0, 100 - Int($0.rounded())) }
        let secondary: Int? = usage?.secondaryPercentUsed.map { max(0, 100 - Int($0.rounded())) }

        HStack(spacing: 4) {
            Group {
                switch type {
                case .claudeCode:
                    ClaudePixelChar(isAnimating: false)
                case .codex:
                    CodexPixelChar(isAnimating: false)
                }
            }
            .scaleEffect(0.9)
            .opacity(isAvailable ? 1.0 : 0.35)

            if isAvailable && showUsageInline {
                VStack(alignment: .leading, spacing: 1) {
                    if let p5h = primary {
                        Text("5h \(p5h)%")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    if let pW = secondary {
                        Text(" W \(pW)%")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.35))
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isHovering ? Color.white.opacity(0.15) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onHover { hovering in
            handleUsageHover(type: type, hovering: hovering, source: .icon)
        }
    }

    private enum UsageHoverSource { case icon, popover }

    private func handleUsageHover(type: AgentType, hovering: Bool, source: UsageHoverSource) {
        if hovering {
            usagePopoverShowTimer?.invalidate()
            usagePopoverDismissTimer?.invalidate()
            if source == .icon {
                usageManager.refreshIfStale()
                usagePopoverShowTimer = Timer.scheduledTimer(
                    withTimeInterval: usagePopoverShowDelay, repeats: false
                ) { _ in
                    DispatchQueue.main.async {
                        hoveredUsageButton = type
                    }
                }
            } else {
                usagePopoverShowTimer = nil
                hoveredUsageButton = type
            }
        } else {
            // Defer dismissal a tick so the cursor can travel between
            // the icon and the popover without flicker. If a hover
            // begins on the other element before the timer fires, the
            // hovering branch above invalidates it.
            usagePopoverShowTimer?.invalidate()
            usagePopoverShowTimer = nil
            usagePopoverDismissTimer?.invalidate()
            usagePopoverDismissTimer = Timer.scheduledTimer(
                withTimeInterval: 0.25, repeats: false
            ) { _ in
                DispatchQueue.main.async {
                    hoveredUsageButton = nil
                }
            }
        }
    }

    @ViewBuilder
    private func usagePopover(for type: AgentType, usage: UsageInfo?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row
            HStack(spacing: 6) {
                Image(systemName: "speedometer")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                Text("Rate limits remaining")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
            }

            if let usage = usage {
                rateLimitRow(label: "5h",
                             percentUsed: usage.primaryPercentUsed,
                             resetsAt: usage.primaryResetsAt,
                             windowMinutes: usage.primaryWindowMinutes,
                             style: .time)
                rateLimitRow(label: "Weekly",
                             percentUsed: usage.secondaryPercentUsed,
                             resetsAt: usage.secondaryResetsAt,
                             windowMinutes: usage.secondaryWindowMinutes,
                             style: .date)
            } else {
                Text(type == .claudeCode
                     ? "No usage data yet"
                     : "No active session yet")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 240, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.10, green: 0.10, blue: 0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
    }

    @ViewBuilder
    private var refreshControl: some View {
        if usageManager.isRefreshing {
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.mini)
                .colorInvert()
                .colorMultiply(.white)
                .frame(width: 16, height: 16)
        } else {
            Button {
                Task { await usageManager.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private enum ResetStyle { case time, date }

    @ViewBuilder
    private func rateLimitRow(
        label: String,
        percentUsed: Double?,
        resetsAt: Date?,
        windowMinutes: Int?,
        style: ResetStyle
    ) -> some View {
        // Effective state: if the snapshot's resetsAt is already in the
        // past, the window has rolled over since the last token_count
        // event was written (Codex only writes a new event on the next
        // API call). Treat as fully reset and project the next reset
        // time forward by `windowMinutes`.
        let now = Date()
        let isPastReset: Bool = {
            guard let resets = resetsAt else { return false }
            return resets <= now
        }()
        let effectiveRemaining: Int? = {
            guard let p = percentUsed else { return nil }
            return isPastReset ? 100 : max(0, 100 - Int(p.rounded()))
        }()
        let effectiveReset: Date? = {
            guard let resets = resetsAt else { return nil }
            if !isPastReset { return resets }
            // Project forward by full window cycles until > now.
            guard let wm = windowMinutes, wm > 0 else { return resets }
            let step = TimeInterval(wm * 60)
            var next = resets
            while next <= now { next.addTimeInterval(step) }
            return next
        }()

        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
            Spacer(minLength: 8)
            if let r = effectiveRemaining {
                Text("\(r)%")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
            } else {
                Text("—")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
            }
            if let resets = effectiveReset {
                Text(formatResetTimestamp(resets, style: style))
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(minWidth: 56, alignment: .trailing)
            }
        }
    }

    private func aggregatedUsage(for type: AgentType) -> UsageInfo? {
        switch type {
        case .claudeCode: return usageManager.claudeUsage
        case .codex:      return usageManager.codexUsage
        }
    }

    private func usagePopoverLeadingOffset(for type: AgentType) -> CGFloat {
        switch type {
        case .claudeCode:
            return 0
        case .codex:
            return usageButtonSize.width + usageButtonSpacing
        }
    }

    private func formatResetTimestamp(_ date: Date, style: ResetStyle) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        switch style {
        case .time:
            f.dateFormat = "h:mm a"  // 9:30 PM
        case .date:
            f.dateFormat = "MMM d"   // Apr 10
        }
        return f.string(from: date)
    }

    private var topReservedSpace: CGFloat {
        // Reserve the menu-bar / safe-area strip at the top so the first
        // card clears the camera cutout on notch Macs and the menu-bar
        // area on non-notch Macs. The icon row sits in this same band,
        // off to the sides of the cutout, so no extra space is needed
        // for it on either screen type.
        return max(0, viewModel.topInset - 8)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("🏝")
                .font(.system(size: 32))
            Text("No active agents")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.gray)
            Text("Start Claude Code or Codex CLI\nto see sessions here")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.gray.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

// MARK: - Expanded Sizing View
//
// Mirrors `IslandView.expandedContentBody` *without* the ScrollView so
// `NSHostingView.fittingSize` can report the natural content height.
// `NotchWindow.animateWindowResize` measures this view to decide the
// expanded panel height (then caps at 0.7 * screen). The visible UI uses
// a ScrollView so when the natural height exceeds the cap, content
// scrolls instead of being pushed off the top edge.
//
// Keep this in sync with the visible layout's vertical contributors:
// `Spacer(topReservedSpace)` + orphan banners + (empty state | session
// cards) + `padding(12)`. Horizontal padding is handled by
// `IslandView.inset`; the bottom inset is added by the caller.
// MARK: - NSScrollView Knob-Style Configurator
//
// SwiftUI's overlay-style scroll indicators are nearly invisible on a
// solid-black background because macOS defaults to a dark knob. This
// NSViewRepresentable walks up to the enclosing NSScrollView and sets
// `scrollerKnobStyle = .light` so the scrollbar renders white. It also
// shows/hides the scroller based on hover state.


struct ExpandedSizingView: View {
    let sessions: [AgentSession]
    let orphans: [PermissionRequest]
    let pendingPermissionsCount: Int
    let pendingAsksCount: Int
    let topReservedSpace: CGFloat
    @ObservedObject var viewModel: NotchWindowViewModel
    let agentManager: AgentManager

    var body: some View {
        VStack(spacing: 4) {
            Spacer().frame(height: topReservedSpace)
            ForEach(orphans) { req in
                PermissionBannerView(
                    request: req,
                    onAllow: { },
                    onAllowAlways: { },
                    onDeny: { }
                )
            }
            if sessions.isEmpty && pendingPermissionsCount == 0 && pendingAsksCount == 0 {
                VStack(spacing: 12) {
                    Text("🏝").font(.system(size: 32))
                    Text("No active agents")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                    Text("Start Claude Code or Codex CLI\nto see sessions here")
                        .font(.system(size: 11, design: .monospaced))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ForEach(sessions) { session in
                    SessionCard(session: session, viewModel: viewModel, agentManager: agentManager)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

// MARK: - Session Card (with hover effect)

struct SessionCard: View {
    @ObservedObject var session: AgentSession
    @ObservedObject var viewModel: NotchWindowViewModel
    @ObservedObject var agentManager: AgentManager
    @State private var isHovered = false

    private var hasAsk: Bool {
        viewModel.pendingAsks.contains { $0.sessionId == session.id } || (session.status == .waiting && session.askQuestion != nil)
    }

    private var pendingPermission: PermissionRequest? {
        viewModel.pendingPermissions.first { $0.sessionId == session.id }
    }

    private var hasAttentionCard: Bool {
        hasAsk || pendingPermission != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                session.jumpToTerminal()
                if session.status.isRecentlyFinished {
                    agentManager.acknowledgeRecentCompletion(sessionId: session.id)
                }
                viewModel.collapse()
            } label: {
                AgentRowView(
                    session: session,
                    hasAskCard: hasAttentionCard,
                    hasPendingPermission: pendingPermission != nil
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(PassthroughButtonStyle())

            if let perm = pendingPermission {
                PermissionBannerView(
                    request: perm,
                    onAllow: { viewModel.allowPermission(perm.id) },
                    onAllowAlways: { viewModel.allowPermissionAlways(perm.id) },
                    onDeny: { viewModel.denyPermission(perm.id) }
                )
            } else if let hookAsk = viewModel.pendingAsks.first(where: { $0.sessionId == session.id }) {
                AskCardSwiftUI(
                    question: hookAsk.question,
                    options: hookAsk.options,
                    onSelect: { label in viewModel.answerAsk(hookAsk.id, answer: label) },
                    userMessage: session.lastUserMessage
                )
            } else if session.status == .waiting && session.askQuestion != nil {
                AskCardSwiftUI(
                    question: session.askQuestion ?? "",
                    options: session.askOptions ?? [],
                    onSelect: { _ in session.jumpToTerminal() },
                    showTerminalHint: true,
                    userMessage: session.lastUserMessage
                )
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(hasAttentionCard ? Color.white.opacity(0.15) : Color.clear, lineWidth: 1)
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - Notch Shape

/// Notch shape with concave top corners extending OUTSIDE the rect
/// (connecting to the screen edge) and rounded bottom corners inside.
/// Both radii are animatable for smooth expand/collapse transitions.
struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    init(topCornerRadius: CGFloat = 10, bottomCornerRadius: CGFloat = 14) {
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tr = topCornerRadius
        let br = bottomCornerRadius

        // Start at top-left, OUTSIDE the rect for concave connection
        path.move(to: CGPoint(x: rect.minX - tr, y: rect.minY))

        // Top-left concave corner (curves inward from screen edge)
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + tr),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )

        // Left side down
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - br))

        // Bottom-left rounded corner
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + br, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )

        // Bottom edge
        path.addLine(to: CGPoint(x: rect.maxX - br, y: rect.maxY))

        // Bottom-right rounded corner
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - br),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )

        // Right side up
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + tr))

        // Top-right concave corner (extends OUTSIDE the rect)
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX + tr, y: rect.minY),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }
}

/// A transparent button style that renders its label as-is without any
/// default button chrome. Unlike `onTapGesture`, a `Button` correctly
/// receives the first mouse-down in a `nonactivatingPanel` (NSPanel)
/// even when the app is not focused.
struct PassthroughButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// Compact-bar sprite + status indicator for a single session.
/// Extracted so `@ObservedObject` can subscribe to the AgentSession's
/// @Published properties (status, etc.). Previously rendered inline in
/// NotchView.compactContent, which only observes `agentManager` — array
/// mutations re-render, but AgentSession property mutations (e.g. the
/// Stop hook flipping .running → .justFinished) do not, leaving the
/// comet trail painted until some other parent state happened to change.
struct CompactSpriteAndIndicator: View {
    @ObservedObject var session: AgentSession
    let hasPendingPermission: Bool

    var body: some View {
        let isActive = session.status == .running
            || session.status == .waiting
            || hasPendingPermission
        let waitingColor: Color? = (session.status == .waiting || hasPendingPermission)
            ? .orange
            : nil

        // spacing 0 — indicator reads as attached to the sprite rather
        // than floating in the bar gap.
        HStack(spacing: 0) {
            ZStack {
                if session.agentType == .codex {
                    CodexPixelChar(isAnimating: isActive, colorOverride: waitingColor)
                } else {
                    ClaudePixelChar(isAnimating: isActive, colorOverride: waitingColor)
                }
                // Compact bar takes every sound event (no sessionId
                // filter) since whichever session fires we want the
                // burst to show on the visible sprite.
                PixelEffectOverlay()
            }

            // Compact bar hides the indicator for idle/finished states —
            // the cursor blink ▌▌ doesn't carry useful info when the
            // session is at rest and just adds noise next to the sprite.
            // Running / waiting / permission states are meaningful so
            // keep them visible (comet trail, ?, !).
            if showIndicator {
                SessionStatusIndicator(
                    session: session,
                    hasPendingPermission: hasPendingPermission
                )
            }
        }
    }

    private var showIndicator: Bool {
        if hasPendingPermission { return true }
        switch session.status {
        case .running, .waiting:     return true
        case .justFinished, .done, .idle, .error: return false
        }
    }
}
