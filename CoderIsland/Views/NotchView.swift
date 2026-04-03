import SwiftUI

struct IslandView: View {
    @ObservedObject var agentManager: AgentManager
    @ObservedObject var viewModel: NotchWindowViewModel

    @State private var isHovered = false
    @State private var hoverTimer: Timer?

    private let barColor = Color.black
    // Extra padding around the shape so corners + shadow are visible
    static let inset: CGFloat = 24

    var body: some View {
        ZStack(alignment: .top) {
            compactContent
                .opacity(viewModel.isExpanded ? 0 : 1)

            if viewModel.isExpanded {
                expandedContent
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
                // Shadow — black only
                .shadow(
                    color: (isHovered || viewModel.isExpanded) ? .black.opacity(0.8) : .clear,
                    radius: (isHovered || viewModel.isExpanded) ? 12 : 0, y: 4
                )
        )
        .onHover { hovering in
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
    }

    // MARK: - Compact Bar

    private var compactContent: some View {
        HStack(spacing: 8) {
            if agentManager.sessions.isEmpty && viewModel.pendingPermissions.isEmpty {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
                Text("No agents")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.gray)
            } else if !viewModel.pendingPermissions.isEmpty {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 8, height: 8)
                Text("\(viewModel.pendingPermissions.count) permission")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.orange)
            } else if let first = agentManager.sessions.first {
                // Check if any session has a pending ask
                let askSession = agentManager.sessions.first(where: { $0.status == .waiting })
                let displaySession = askSession ?? first

                Group {
                    let isActive = displaySession.status == .running || displaySession.status == .waiting
                    let waitingColor: Color? = displaySession.status == .waiting ? .orange : nil
                    if displaySession.agentType == .codex {
                        CodexPixelChar(isAnimating: isActive, colorOverride: waitingColor)
                    } else {
                        ClaudePixelChar(isAnimating: isActive, colorOverride: waitingColor)
                    }
                }

                Text(displaySession.taskName)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(displaySession.status == .done ? .gray : .white)
                    .lineLimit(1)

                if displaySession.status == .waiting {
                    Text("Waiting for answer...")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.orange.opacity(0.8))
                        .lineLimit(1)
                } else if displaySession.status != .done, let subtitle = displaySession.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                }

                Spacer()

                // Show ? instead of count when any session is waiting
                let hasWaiting = agentManager.sessions.contains { $0.status == .waiting }
                if hasWaiting {
                    PixelStatusIcon(
                        pixels: [(1,0),(2,0),(3,1),(2,2),(1,3),(1,5)],
                        color: .orange
                    )
                    .scaleEffect(0.9)
                } else if agentManager.sessions.count > 1 {
                    Text("\(agentManager.sessions.count)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.12))
                        )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        // On notch Macs: avoid the camera area in compact mode
        .padding(.horizontal, viewModel.hasNotch ? max(0, viewModel.notchWidth / 2 - 60) : 0)
    }

    // MARK: - Expanded Panel

    private var expandedContent: some View {
        VStack(spacing: 4) {
            if viewModel.hasNotch {
                Spacer().frame(height: viewModel.notchHeight - 8)
            }

            // Hook-based permission requests
            ForEach(viewModel.pendingPermissions) { req in
                PermissionBannerView(
                    request: req,
                    onAllow: { viewModel.allowPermission(req.id) },
                    onDeny: { viewModel.denyPermission(req.id) }
                )
            }

            if agentManager.sessions.isEmpty && viewModel.pendingPermissions.isEmpty && viewModel.pendingAsks.isEmpty {
                emptyState
            } else {
                ForEach(agentManager.sessions) { session in
                    SessionCard(session: session, viewModel: viewModel)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .top)
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
    @State private var isHovered = false

    private var hasAsk: Bool {
        viewModel.pendingAsks.contains { $0.sessionId == session.id } || (session.status == .waiting && session.askQuestion != nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            AgentRowView(session: session, hasAskCard: hasAsk)
                .contentShape(Rectangle())
                .onTapGesture {
                    session.jumpToTerminal()
                    if session.status == .done {
                        session.status = .idle
                    }
                    viewModel.collapse()
                }

            if let hookAsk = viewModel.pendingAsks.first(where: { $0.sessionId == session.id }) {
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
                .stroke(hasAsk ? Color.white.opacity(0.15) : Color.clear, lineWidth: 1)
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
