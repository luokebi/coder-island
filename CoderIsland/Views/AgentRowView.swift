import SwiftUI

struct AgentRowView: View {
    @ObservedObject var session: AgentSession
    var hasAskCard: Bool = false
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Status indicator
            statusIndicator
                .padding(.top, 3)

            // Task info
            VStack(alignment: .leading, spacing: 2) {
                Text(session.taskName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                // Show user message + assistant response for idle/done
                if session.status == .done || session.status == .idle {
                    if let userMsg = session.lastUserMessage {
                        Text(userMsg)
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                            .lineLimit(1)
                    }
                    if let assistantMsg = session.lastAssistantMessage {
                        Text(assistantMsg)
                            .font(.system(size: 10))
                            .foregroundColor(.gray.opacity(0.7))
                            .lineLimit(1)
                    }
                } else if !hasAskCard, let subtitle = session.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }

                if !hasAskCard {
                    statusLink
                }
            }

            Spacer()

            // Right side: tags + time
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    TagBadge(text: session.agentType.displayName)
                    TagBadge(text: session.terminalApp)
                }

                Text(session.elapsedTimeString)
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch session.status {
        case .running:
            ClaudePixelChar(isAnimating: true)
        case .waiting:
            ClaudePixelChar(isAnimating: true)
        case .done:
            ClaudePixelChar(isAnimating: false)
                .opacity(0.5)
        case .error:
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
        case .idle:
            ClaudePixelChar(isAnimating: false)
                .opacity(0.5)
        }
    }

    @ViewBuilder
    private var statusLink: some View {
        switch session.status {
        case .done:
            Text("Done — click to jump")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(Color(nsColor: .systemGreen))
        case .waiting:
            Text("Waiting for input...")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(Color(nsColor: .systemBlue))
        case .error:
            Text("Error — click to view")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(Color(nsColor: .systemRed))
        default:
            EmptyView()
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

// MARK: - Claude Code Pixel Character

struct ClaudePixelChar: View {
    let isAnimating: Bool
    @State private var bobOffset: CGFloat = 0
    @State private var eyeOpen = true
    @State private var legFrame = 0

    private let p: CGFloat = 2

    private var bodyColor: Color {
        isAnimating
            ? Color(red: 0.3, green: 0.5, blue: 0.95)
            : Color(red: 0.85, green: 0.52, blue: 0.35)
    }
    private let eyeColor = Color(red: 0.12, green: 0.1, blue: 0.1)

    var body: some View {
        Canvas { context, size in
            let ox = (size.width - 7 * p) / 2
            let oy = (size.height - 7 * p) / 2 + bobOffset

            let headPixels: [(Int, Int)] = [
                (1,0),(2,0),(3,0),(4,0),(5,0),
                (0,1),(1,1),(2,1),(3,1),(4,1),(5,1),(6,1),
                (0,2),(1,2),(2,2),(3,2),(4,2),(5,2),(6,2),
                (0,3),(1,3),(2,3),(3,3),(4,3),(5,3),(6,3),
                (0,4),(1,4),(2,4),(3,4),(4,4),(5,4),(6,4),
            ]
            for (x, y) in headPixels {
                let rect = CGRect(x: ox + CGFloat(x) * p, y: oy + CGFloat(y) * p, width: p, height: p)
                context.fill(Path(rect), with: .color(bodyColor))
            }

            if eyeOpen {
                let leftEye = CGRect(x: ox + 2 * p, y: oy + 2 * p, width: p, height: p)
                let rightEye = CGRect(x: ox + 4 * p, y: oy + 2 * p, width: p, height: p)
                context.fill(Path(leftEye), with: .color(eyeColor))
                context.fill(Path(rightEye), with: .color(eyeColor))
            }

            let legs: [(Int, Int)]
            if isAnimating && legFrame == 1 {
                legs = [(0,5),(1,5),(5,5),(6,5),(0,6),(6,6)]
            } else {
                legs = [(1,5),(2,5),(4,5),(5,5),(1,6),(2,6),(4,6),(5,6)]
            }
            for (x, y) in legs {
                let rect = CGRect(x: ox + CGFloat(x) * p, y: oy + CGFloat(y) * p, width: p, height: p)
                context.fill(Path(rect), with: .color(bodyColor))
            }
        }
        .frame(width: 16, height: 16)
        .onAppear { startAnimations() }
        .onChange(of: isAnimating) { _, _ in startAnimations() }
    }

    private func startAnimations() {
        guard isAnimating else {
            withAnimation(.easeOut(duration: 0.3)) { bobOffset = 0 }
            eyeOpen = true
            legFrame = 0
            return
        }
        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
            bobOffset = -2
        }
        blinkLoop()
        walkLoop()
    }

    private func blinkLoop() {
        guard isAnimating else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 1.5...3.5)) {
            guard self.isAnimating else { return }
            self.eyeOpen = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.eyeOpen = true
                self.blinkLoop()
            }
        }
    }

    private func walkLoop() {
        guard isAnimating else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard self.isAnimating else { return }
            self.legFrame = self.legFrame == 0 ? 1 : 0
            self.walkLoop()
        }
    }
}
