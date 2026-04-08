import SwiftUI

struct IslandView: View {
    @ObservedObject var agentManager: AgentManager
    @ObservedObject var viewModel: NotchWindowViewModel

    @State private var isHovered = false
    @State private var hoverTimer: Timer?
    @State private var showControlMenu = false
    @State private var isGearHovered = false
    @State private var isSettingsHovered = false
    @State private var isQuitHovered = false
    @State private var hoveredUsageButton: AgentType?
    @State private var usagePopoverDismissTimer: Timer?
    @ObservedObject private var usageManager: UsageManager = .shared

    private let barColor = Color.black
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
        ZStack(alignment: .top) {
            compactContent
                .allowsHitTesting(!viewModel.isExpanded)
                .onHover { hovering in
                    handleHoverChange(hovering)
                }
                .opacity(compactBarOpacity)

            if viewModel.isExpanded {
                expandedContent
                    .onHover { hovering in
                        handleHoverChange(hovering)
                    }
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Self.inset)
        .padding(.bottom, Self.inset)
        // Don't pad top — stays flush with screen edge
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            NotchShape(bottomRadius: viewModel.isExpanded ? 18 : 14)
                .fill(barColor)
                .padding(.horizontal, Self.inset)
                .padding(.bottom, Self.inset)
                // Shadow — black only, smaller/softer than before so it
                // doesn't bleed too far into the wallpaper around the panel.
                .shadow(
                    color: (isHovered || viewModel.isExpanded) ? .black.opacity(0.5) : .clear,
                    radius: (isHovered || viewModel.isExpanded) ? 8 : 0, y: 3
                )
                .opacity(barShapeOpacity)
        )
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
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
                Text("No agents")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.gray)
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

                Group {
                    let isActive = displaySession.status == .running || displaySession.status == .waiting || displayHasPermission
                    let waitingColor: Color? = (displaySession.status == .waiting || displayHasPermission) ? .orange : nil
                    if displaySession.agentType == .codex {
                        CodexPixelChar(isAnimating: isActive, colorOverride: waitingColor)
                    } else {
                        ClaudePixelChar(isAnimating: isActive, colorOverride: waitingColor)
                    }
                }

                // Task name: intrinsic width up to a hard cap. Without the
                // cap, a very long session title (e.g. a Codex thread named
                // after the user's whole prompt) would push the subtitle
                // and right-side indicator off the visible bar. maxWidth
                // keeps the name within a predictable slot; layoutPriority
                // lets it win space over the subtitle when both are present.
                Text(displaySession.taskName)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(displaySession.status.isRecentlyFinished ? .gray : .white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 160, alignment: .leading)
                    .layoutPriority(1)

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
        VStack(spacing: 4) {
            Spacer().frame(height: topReservedSpace)

            // Orphan permission banners: requests whose sessionId doesn't match any
            // active session are rendered at the top so they're not lost.
            ForEach(orphanPermissions) { req in
                orphanPermissionBanner(req)
            }

            if agentManager.sessions.isEmpty && viewModel.pendingPermissions.isEmpty && viewModel.pendingAsks.isEmpty {
                emptyState
            } else {
                ForEach(agentManager.sessions) { session in
                    SessionCard(session: session, viewModel: viewModel, agentManager: agentManager)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .top)
        .overlay(alignment: .topLeading) {
            usageButtonsOverlay
                // On notch Macs, push past the camera cutout (~32pt).
                // On non-notch the panel's top sits over the menu bar
                // and a small fixed offset is enough.
                .padding(.top, viewModel.hasNotch ? viewModel.topInset + 4 : 6)
                .padding(.leading, 12)
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
                        .frame(width: 170, alignment: .leading)
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
            .padding(.top, viewModel.hasNotch ? viewModel.topInset + 4 : 6)
            .padding(.trailing, 12)
        }
    }

    // MARK: - Usage Buttons (top-left of expanded panel)

    @AppStorage("showUsageLimits") private var showUsageLimits = true

    @ViewBuilder
    private var usageButtonsOverlay: some View {
        if showUsageLimits {
            HStack(spacing: 6) {
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
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(isHovering ? Color.white.opacity(0.20) : Color.clear)
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
        }
        .frame(width: 26, height: 22)
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onHover { hovering in
            handleUsageHover(type: type, hovering: hovering, source: .icon)
        }
        // Float the popover so it doesn't affect the HStack's layout
        // (otherwise the popover's minWidth pushes the sibling button
        // out of the bar). `.overlay` is sized independently of the
        // anchor view; offset moves it below the button. The popover
        // accepts hover events itself so the cursor can travel from
        // the icon onto the card without dismissing it.
        .overlay(alignment: .topLeading) {
            if isHovering {
                usagePopover(for: type, usage: usage)
                    .fixedSize()
                    .offset(x: 0, y: 28)
                    .onHover { hovering in
                        handleUsageHover(type: type, hovering: hovering, source: .popover)
                    }
            }
        }
    }

    private enum UsageHoverSource { case icon, popover }

    private func handleUsageHover(type: AgentType, hovering: Bool, source: UsageHoverSource) {
        if hovering {
            usagePopoverDismissTimer?.invalidate()
            usagePopoverDismissTimer = nil
            hoveredUsageButton = type
            if source == .icon {
                usageManager.refreshIfStale()
            }
        } else {
            // Defer dismissal a tick so the cursor can travel between
            // the icon and the popover without flicker. If a hover
            // begins on the other element before the timer fires, the
            // hovering branch above invalidates it.
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
                Spacer(minLength: 8)
                refreshControl
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
        // On notch Macs, the camera cutout occupies the top ~32pt and
        // we have to push the icon row below it — that means the
        // session cards also need to start below the icon row, so
        // reserve menu-bar space + icon row height.
        // On non-notch Macs, the icon row visually fits inside the
        // menu-bar area at the top of the panel (the panel sits above
        // the real menu bar), so the original ~16pt of reserved space
        // is enough — adding the icon-row height here would leave a
        // visible empty band above the first card.
        let menuBarSpace = max(0, viewModel.topInset - 8)
        if viewModel.hasNotch {
            let iconRowSpace: CGFloat = 26  // ~22pt icon + ~4pt breathing
            return menuBarSpace + iconRowSpace
        }
        return menuBarSpace
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
            AgentRowView(
                session: session,
                hasAskCard: hasAttentionCard,
                hasPendingPermission: pendingPermission != nil
            )
                .contentShape(Rectangle())
                .onTapGesture {
                    session.jumpToTerminal()
                    if session.status.isRecentlyFinished {
                        agentManager.acknowledgeRecentCompletion(sessionId: session.id)
                    }
                    viewModel.collapse()
                }

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

struct NotchShape: Shape {
    let bottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = bottomRadius
        let tr: CGFloat = 16  // top corner radius
        var path = Path()

        // Start at top-left, offset by top radius
        path.move(to: CGPoint(x: rect.minX - tr, y: rect.minY))

        // Top-left concave corner (curves inward from screen edge)
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + tr),
            control1: CGPoint(x: rect.minX, y: rect.minY),
            control2: CGPoint(x: rect.minX, y: rect.minY)
        )

        // Left side down
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))

        // Bottom-left corner
        path.addCurve(
            to: CGPoint(x: rect.minX + r, y: rect.maxY),
            control1: CGPoint(x: rect.minX, y: rect.maxY - r * 0.45),
            control2: CGPoint(x: rect.minX + r * 0.45, y: rect.maxY)
        )

        // Bottom edge
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))

        // Bottom-right corner
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - r),
            control1: CGPoint(x: rect.maxX - r * 0.45, y: rect.maxY),
            control2: CGPoint(x: rect.maxX, y: rect.maxY - r * 0.45)
        )

        // Right side up
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + tr))

        // Top-right concave corner
        path.addCurve(
            to: CGPoint(x: rect.maxX + tr, y: rect.minY),
            control1: CGPoint(x: rect.maxX, y: rect.minY),
            control2: CGPoint(x: rect.maxX, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }
}
