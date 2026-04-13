import SwiftUI
import AppKit

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
            if isActive {
                return Color(red: 0.3, green: 0.5, blue: 0.95)
            }
            // Idle: match the agent character's idle color
            switch session.agentType {
            case .claudeCode:
                return Color(red: 0.85, green: 0.52, blue: 0.35)
            case .codex:
                return Color(red: 0.25, green: 0.65, blue: 0.38)
            }
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

        if subtitle == "Thinking..." {
            ThinkingLabel()
        } else if let parts {
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

    private let cell: CGFloat = 2
    private let pix: CGFloat = 1.7

    var body: some View {
        Canvas { context, size in
            guard visible else { return }
            for (x, y) in pixels {
                let rect = CGRect(
                    x: CGFloat(x) * cell,
                    y: CGFloat(y) * cell,
                    width: pix, height: pix
                )
                context.fill(Path(rect), with: .color(color))
            }
        }
        .frame(width: 8, height: 12)
        .shadow(color: color.opacity(0.9), radius: 2)
        .shadow(color: color.opacity(0.6), radius: 4)
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

// MARK: - Shared Pixel Character Engine

/// Shared rendering and animation engine for pixel-art agent characters.
/// Each agent provides its pixel data, idle color, and bob parameters;
/// the engine handles Canvas rendering, bob animation, and lifecycle.
private struct PixelCharEngine: View {
    let isAnimating: Bool
    var colorOverride: Color? = nil
    let idleColor: Color
    let gridWidth: CGFloat
    let bobAmount: CGFloat
    let bobDuration: Double
    let pixels: [(Int, Int)]
    var showGlow: Bool = true

    private let cell: CGFloat = 2
    private let pix: CGFloat = 1.7

    @State private var bobOffset: CGFloat = 0
    @State private var bobId = UUID()

    private var baseColor: Color {
        if let colorOverride { return colorOverride }
        return isAnimating
            ? Color(red: 0.30, green: 0.50, blue: 0.95)
            : idleColor
    }

    var body: some View {
        Canvas { context, size in
            let ox = (size.width - gridWidth * cell) / 2
            let oy = (size.height - 7 * cell) / 2 + bobOffset
            for (x, y) in pixels {
                let rect = CGRect(
                    x: ox + CGFloat(x) * cell,
                    y: oy + CGFloat(y) * cell,
                    width: pix, height: pix
                )
                context.fill(Path(rect), with: .color(baseColor))
            }
        }
        .frame(width: 16, height: 16)
        .shadow(color: showGlow ? baseColor.opacity(0.9) : .clear, radius: 2)
        .shadow(color: showGlow ? baseColor.opacity(0.6) : .clear, radius: 4)
        // Reset the animation identity when state changes so
        // repeatForever doesn't stack on top of a previous one.
        .id(bobId)
        .onAppear { updateBob() }
        .onChange(of: isAnimating) { _, _ in updateBob() }
        .onChange(of: colorOverride) { _, _ in updateBob() }
    }

    private func updateBob() {
        // Changing bobId forces SwiftUI to tear down and recreate the
        // view's animation state, preventing repeatForever from stacking.
        bobId = UUID()
        guard isAnimating else {
            bobOffset = 0
            return
        }
        // Start from 0 then animate to target
        bobOffset = 0
        withAnimation(.easeInOut(duration: bobDuration).repeatForever(autoreverses: true)) {
            bobOffset = bobAmount
        }
    }
}

// MARK: - Claude Code Pixel Character (Claude sparkle/star shape)

struct ClaudePixelChar: View {
    let isAnimating: Bool
    var colorOverride: Color? = nil
    var showGlow: Bool = true
    @State private var walkFrame = 0
    @State private var walkGeneration = 0

    private static let bodyPixels: [(Int, Int)] = [
        (1,1),(2,1),(3,1),(4,1),(5,1),(6,1),
        (1,2),      (3,2),(4,2),      (6,2),
        (0,3),(1,3),(2,3),(3,3),(4,3),(5,3),(6,3),(7,3),
              (1,4),(2,4),(3,4),(4,4),(5,4),(6,4),
              (1,5),(2,5),(3,5),(4,5),(5,5),(6,5),
    ]

    private var allPixels: [(Int, Int)] {
        let isWalking = isAnimating && colorOverride == nil
        let feet: [(Int, Int)]
        if isWalking {
            feet = (walkFrame % 2 == 0)
                ? [(1,6), (5,6)]
                : [(2,6), (6,6)]
        } else {
            feet = [(2,6), (5,6)]
        }
        return Self.bodyPixels + feet
    }

    var body: some View {
        PixelCharEngine(
            isAnimating: isAnimating,
            colorOverride: colorOverride,
            idleColor: Color(red: 0.85, green: 0.52, blue: 0.35),
            gridWidth: 8,
            bobAmount: -1.0,
            bobDuration: 0.25,
            pixels: allPixels,
            showGlow: showGlow
        )
        .onAppear { startWalk() }
        .onChange(of: isAnimating) { _, _ in startWalk() }
        .onChange(of: colorOverride) { _, _ in startWalk() }
    }

    private func startWalk() {
        walkGeneration += 1
        guard isAnimating, colorOverride == nil else {
            walkFrame = 0
            return
        }
        walkLoop(generation: walkGeneration)
    }

    private func walkLoop(generation: Int) {
        guard isAnimating, colorOverride == nil, generation == walkGeneration else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            guard self.isAnimating, self.colorOverride == nil, generation == self.walkGeneration else { return }
            self.walkFrame += 1
            self.walkLoop(generation: generation)
        }
    }
}

// MARK: - Thinking Label (pulsing dots animation)

struct ThinkingLabel: View {
    @State private var dotCount = 0

    var body: some View {
        HStack(spacing: 3) {
            Text("Thinking")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.purple.opacity(0.9))
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    ThinkingDot(index: i)
                }
            }
        }
    }
}

private struct ThinkingDot: View {
    let index: Int
    @State private var opacity: Double = 0.3

    var body: some View {
        Circle()
            .fill(Color.purple)
            .frame(width: 4, height: 4)
            .opacity(opacity)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 0.6)
                    .repeatForever(autoreverses: true)
                    .delay(Double(index) * 0.2)
                ) {
                    opacity = 1.0
                }
            }
    }
}

// MARK: - Codex Pixel Character (>_ terminal prompt)

struct CodexPixelChar: View {
    let isAnimating: Bool
    var colorOverride: Color? = nil
    var showGlow: Bool = true
    @State private var cursorVisible = true
    @State private var blinkGeneration = 0

    private static let chevronPixels: [(Int, Int)] = [
        (0,1),
        (1,2),
        (2,3),
        (1,4),
        (0,5),
    ]
    private static let cursorPixels: [(Int, Int)] = [(4,5),(5,5),(6,5)]

    private var allPixels: [(Int, Int)] {
        var px = Self.chevronPixels
        if !isAnimating || cursorVisible {
            px.append(contentsOf: Self.cursorPixels)
        }
        return px
    }

    var body: some View {
        PixelCharEngine(
            isAnimating: isAnimating,
            colorOverride: colorOverride,
            idleColor: Color(red: 0.25, green: 0.65, blue: 0.38),
            gridWidth: 7,
            bobAmount: -1.5,
            bobDuration: 0.5,
            pixels: allPixels,
            showGlow: showGlow
        )
        .onAppear { startBlink() }
        .onChange(of: isAnimating) { _, _ in startBlink() }
    }

    private func startBlink() {
        blinkGeneration += 1
        guard isAnimating else {
            cursorVisible = true
            return
        }
        blinkLoop(generation: blinkGeneration)
    }

    private func blinkLoop(generation: Int) {
        guard isAnimating, generation == blinkGeneration else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard self.isAnimating, generation == self.blinkGeneration else { return }
            self.cursorVisible.toggle()
            self.blinkLoop(generation: generation)
        }
    }
}
