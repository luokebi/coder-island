import SwiftUI

struct AgentRowView: View {
    @ObservedObject var session: AgentSession
    var hasAskCard: Bool = false
    var hasPendingPermission: Bool = false
    @State private var isHovered = false

    private var isActive: Bool {
        session.status.isActive || hasPendingPermission
    }

    private var isDimmed: Bool {
        session.status.isDimmedInUI && !hasPendingPermission
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Left: pixel icon, vertically centered
            agentIcon

            // Right: 3 lines stacked
            VStack(alignment: .leading, spacing: 3) {
                // Line 1: session name + tags
                HStack(spacing: 6) {
                    Text(session.taskName)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Spacer()

                    HStack(spacing: 4) {
                        TagBadge(text: session.agentType.displayName)
                        TagBadge(text: session.terminalApp, dimmed: true)
                        Text(session.elapsedTimeString)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.7))
                    }
                }

                // Line 2: last user message
                if let userMsg = session.lastUserMessage {
                    Text(userMsg)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }

                // Line 3: current status (tool usage, Done, Ready, etc.)
                if !hasAskCard {
                    statusText
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isHovered ? Color.white.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var agentIcon: some View {
        HStack(spacing: 3) {
            // Agent character
            Group {
                let waitingColor: Color? = (session.status == .waiting || hasPendingPermission) ? .orange : nil
                switch session.agentType {
                case .claudeCode:
                    ClaudePixelChar(isAnimating: isActive, colorOverride: waitingColor)
                        .opacity(isDimmed ? 0.5 : 1)
                case .codex:
                    CodexPixelChar(isAnimating: isActive, colorOverride: waitingColor)
                        .opacity(isDimmed ? 0.5 : 1)
                }
            }
            .scaleEffect(1.2)
            .frame(width: 20, height: 20)

            // Status indicator
            statusEmoji
        }
    }

    @ViewBuilder
    private var statusEmoji: some View {
        let color: Color = {
            if hasPendingPermission || session.status == .waiting {
                return Color.orange
            }
            return isActive
                ? Color(red: 0.3, green: 0.5, blue: 0.95)
                : Color(red: 0.85, green: 0.52, blue: 0.35)
        }()
        let pixels: [(Int, Int)] = {
            // Permission pending overrides normal status with "!"
            if hasPendingPermission {
                return [(1,0),(1,1),(1,2),(1,3),
                        (1,5)]
            }
            switch session.status {
            case .running:
                // ▶ play arrow
                return [(0,0),(0,1),(0,2),(0,3),(0,4),
                        (1,1),(1,2),(1,3),
                        (2,2)]
            case .waiting:
                // ? question mark
                return [(1,0),(2,0),
                        (3,1),
                        (2,2),
                        (1,3),
                        (1,5)]
            case .error:
                // ! exclamation
                return [(1,0),(1,1),(1,2),(1,3),
                        (1,5)]
            case .justFinished, .done, .idle:
                // ▌▌ double cursor blink bar (adjacent columns)
                return [(0,0),(0,1),(0,2),(0,3),(0,4),(0,5),
                        (1,0),(1,1),(1,2),(1,3),(1,4),(1,5)]
            }
        }()
        PixelStatusIcon(pixels: pixels, color: color, blink: isDimmed)
            .opacity(isDimmed ? 0.5 : 1)
    }

    @ViewBuilder
    private var statusText: some View {
        switch session.status {
        case .running:
            if let subtitle = session.subtitle {
                subtitleView(subtitle)
            } else {
                Text("Running...")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.blue)
            }
        case .waiting:
            Text(session.subtitle ?? "Waiting for input...")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.orange)
        case .justFinished, .done:
            HStack(spacing: 6) {
                Text("Just finished")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(nsColor: .systemGreen))
                if let assistantMsg = session.lastAssistantMessage {
                    Text(assistantMsg)
                        .font(.system(size: 11))
                        .foregroundColor(.gray.opacity(0.6))
                        .lineLimit(1)
                }
            }
        case .idle:
            if let assistantMsg = session.lastAssistantMessage {
                Text(assistantMsg)
                    .font(.system(size: 11))
                    .foregroundColor(.gray.opacity(0.6))
                    .lineLimit(1)
            } else {
                Text("Ready")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(nsColor: .systemGreen))
            }
        case .error:
            Text("Error — click to view")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.red)
        }
    }

    @ViewBuilder
    private func subtitleView(_ subtitle: String) -> some View {
        let toolNames = ["Bash", "Edit", "Write", "Read", "Grep", "Glob", "Agent", "Search", "Fetch", "WebFetch", "WebSearch", "exec_command"]
        let parts: (tool: String, content: String?)? = {
            // Check "$" prefix (Bash shorthand)
            if subtitle.hasPrefix("$") {
                return ("Bash", String(subtitle.dropFirst()).trimmingCharacters(in: .whitespaces))
            }
            // Check known tool name prefixes
            for name in toolNames {
                if subtitle.hasPrefix(name) {
                    let rest = String(subtitle.dropFirst(name.count)).trimmingCharacters(in: .whitespaces)
                    return (name, rest.isEmpty ? nil : rest)
                }
            }
            return nil
        }()

        if let parts {
            HStack(spacing: 4) {
                Text(parts.tool)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Color(nsColor: .systemBlue))
                if let content = parts.content {
                    Text(content)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
        } else {
            Text(subtitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.gray)
                .lineLimit(1)
        }
    }

}

// MARK: - Pixel Status Icon

struct PixelStatusIcon: View {
    let pixels: [(Int, Int)]
    let color: Color
    var blink: Bool = false
    @State private var visible = true

    private let p: CGFloat = 2

    var body: some View {
        Canvas { context, size in
            guard visible else { return }
            for (x, y) in pixels {
                let rect = CGRect(x: CGFloat(x) * p, y: CGFloat(y) * p, width: p, height: p)
                context.fill(Path(rect), with: .color(color))
            }
        }
        .frame(width: 8, height: 12)
        .onAppear {
            if blink { startBlink() }
        }
    }

    private func startBlink() {
        guard blink else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.visible.toggle()
            self.startBlink()
        }
    }
}

// MARK: - Breathing Dot Animation

struct BreathingDot: View {
    let color: Color
    @State private var isAnimating = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .shadow(color: color.opacity(isAnimating ? 0.8 : 0.2), radius: isAnimating ? 6 : 2)
            .scaleEffect(isAnimating ? 1.15 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    isAnimating = true
                }
            }
    }
}

// MARK: - Pixel Icon (small, for row status)

struct PixelIcon: View {
    var body: some View {
        ClaudePixelChar(isAnimating: false)
            .scaleEffect(0.8)
    }
}

// MARK: - Claude Code Pixel Character (Claude sparkle/star shape)

struct ClaudePixelChar: View {
    let isAnimating: Bool
    var colorOverride: Color? = nil
    @State private var bobOffset: CGFloat = 0
    @State private var glowPhase = 0

    private let p: CGFloat = 2

    private var bodyColor: Color {
        if let colorOverride { return colorOverride }
        return isAnimating
            ? Color(red: 0.3, green: 0.5, blue: 0.95)
            : Color(red: 0.85, green: 0.52, blue: 0.35)
    }

    var body: some View {
        Canvas { context, size in
            let ox = (size.width - 8 * p) / 2
            let oy = (size.height - 7 * p) / 2 + bobOffset

            // Clawd character — matching Claude Code CLI mascot
            // #      #   ← ear tips (1px, clearly separate)
            // ##    ##   ← ear bases (2px, gap in middle)
            // ########   ← head (full width, ears connect)
            // # #### #   ← face with eyes
            // ########   ← body
            //  ######    ← lower body
            //   #  #     ← feet
            let bodyPixels: [(Int, Int)] = [
                // Row 1: head
                      (1,1),(2,1),(3,1),(4,1),(5,1),(6,1),
                // Row 2: eyes
                      (1,2),      (3,2),(4,2),      (6,2),
                // Row 3: body (widest)
                (0,3),(1,3),(2,3),(3,3),(4,3),(5,3),(6,3),(7,3),
                // Row 4: body
                      (1,4),(2,4),(3,4),(4,4),(5,4),(6,4),
                // Row 5: body lower
                      (1,5),(2,5),(3,5),(4,5),(5,5),(6,5),
                // Row 6: feet
                            (2,6),                  (5,6),
            ]
            for (x, y) in bodyPixels {
                let rect = CGRect(x: ox + CGFloat(x) * p, y: oy + CGFloat(y) * p, width: p, height: p)
                context.fill(Path(rect), with: .color(bodyColor))
            }

            // Glow accent on ears when animating
            if isAnimating {
                let glowPixels: [[(Int, Int)]] = [
                    [(1,1), (6,1)],  // head edges glow
                    [(0,3), (7,3)],  // body sides glow
                ]
                let activeGlow = glowPixels[glowPhase % glowPixels.count]
                for (x, y) in activeGlow {
                    let rect = CGRect(x: ox + CGFloat(x) * p, y: oy + CGFloat(y) * p, width: p, height: p)
                    context.fill(Path(rect), with: .color(.white.opacity(0.4)))
                }
            }
        }
        .frame(width: 16, height: 16)
        .onAppear { startAnimations() }
        .onChange(of: isAnimating) { _, _ in startAnimations() }
    }

    private func startAnimations() {
        guard isAnimating else {
            withAnimation(.easeOut(duration: 0.3)) { bobOffset = 0 }
            glowPhase = 0
            return
        }
        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
            bobOffset = -1.5
        }
        glowLoop()
    }

    private func glowLoop() {
        guard isAnimating else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard self.isAnimating else { return }
            self.glowPhase += 1
            self.glowLoop()
        }
    }
}

// MARK: - Codex Pixel Character (>_ terminal prompt)

struct CodexPixelChar: View {
    let isAnimating: Bool
    var colorOverride: Color? = nil
    @State private var bobOffset: CGFloat = 0
    @State private var cursorVisible = true

    private let p: CGFloat = 2

    private var bodyColor: Color {
        if let colorOverride { return colorOverride }
        return isAnimating
            ? Color(red: 0.3, green: 0.5, blue: 0.95)    // blue when active (same as Claude)
            : Color(red: 0.25, green: 0.65, blue: 0.38)   // muted green when idle
    }

    var body: some View {
        Canvas { context, size in
            let ox = (size.width - 7 * p) / 2
            let oy = (size.height - 7 * p) / 2 + bobOffset

            // > arrow part
            // *
            //   *
            //     *
            //   *
            // *
            let arrow: [(Int, Int)] = [
                (0,1),
                (1,2),
                (2,3),
                (1,4),
                (0,5),
            ]
            for (x, y) in arrow {
                let rect = CGRect(x: ox + CGFloat(x) * p, y: oy + CGFloat(y) * p, width: p, height: p)
                context.fill(Path(rect), with: .color(bodyColor))
            }

            // _ underscore cursor
            if !isAnimating || cursorVisible {
                let cursor: [(Int, Int)] = [
                    (4,5),(5,5),(6,5),
                ]
                for (x, y) in cursor {
                    let rect = CGRect(x: ox + CGFloat(x) * p, y: oy + CGFloat(y) * p, width: p, height: p)
                    context.fill(Path(rect), with: .color(bodyColor))
                }
            }
        }
        .frame(width: 16, height: 16)
        .onAppear { startAnimations() }
        .onChange(of: isAnimating) { _, _ in startAnimations() }
    }

    private func startAnimations() {
        guard isAnimating else {
            withAnimation(.easeOut(duration: 0.3)) { bobOffset = 0 }
            cursorVisible = true
            return
        }
        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
            bobOffset = -1.5
        }
        blinkLoop()
    }

    private func blinkLoop() {
        guard isAnimating else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard self.isAnimating else { return }
            self.cursorVisible.toggle()
            self.blinkLoop()
        }
    }
}
