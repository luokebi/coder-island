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
        // spacing 0 for running — the comet trail should look attached
        // to the walking sprite. For static indicators (! / ? / cursor
        // blink) a small 3pt breathing room reads cleaner; otherwise
        // the glyph fuses visually into the sprite.
        let indicatorPad: CGFloat = (session.status == .running && !hasPendingPermission) ? 0 : 3
        HStack(spacing: 0) {
            // Agent character
            Group {
                let waitingColor: Color? = (session.status == .waiting || hasPendingPermission) ? .orange : nil
                ZStack {
                    switch session.agentType {
                    case .claudeCode:
                        ClaudePixelChar(isAnimating: isActive, colorOverride: waitingColor)
                            .opacity(isDimmed ? 0.5 : 1)
                    case .codex:
                        CodexPixelChar(isAnimating: isActive, colorOverride: waitingColor)
                            .opacity(isDimmed ? 0.5 : 1)
                    }
                    // Row-scoped effect: only fire when the event's sessionId
                    // matches this row. nil userInfo sessionId also matches
                    // (covers Settings ▶ preview, which has no session).
                    PixelEffectOverlay(matchSessionId: session.id)
                }
            }
            .scaleEffect(1.2)
            .frame(width: 20, height: 20)

            // Status indicator — flush for running, small gap otherwise.
            statusEmoji
                .padding(.leading, indicatorPad)
        }
    }

    @ViewBuilder
    private var statusEmoji: some View {
        SessionStatusIndicator(
            session: session,
            hasPendingPermission: hasPendingPermission,
            isDimmed: isDimmed
        )
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

// MARK: - Session Status Indicator

/// Right-side status glyph for a session. Running uses the animated
/// CometTrail; other statuses use static pixel icons (! ? cursor blink).
/// Shared between AgentRowView (expanded panel row) and NotchView's
/// compact bar so the two surfaces stay visually consistent.
///
/// IMPORTANT: `session` must be @ObservedObject (not `let`) so this view
/// subscribes to the session's @Published properties. Without that,
/// SwiftUI sees the same AgentSession reference on re-render and skips
/// body invocation — leaving the old branch (e.g. CometTrail from a
/// prior .running) painted after status flips.
struct SessionStatusIndicator: View {
    @ObservedObject var session: AgentSession
    let hasPendingPermission: Bool
    var isDimmed: Bool = false

    var body: some View {
        let color = indicatorColor
        let isRunning = session.status == .running && !hasPendingPermission
        // Wrap in Group + explicit .id so SwiftUI fully tears down the
        // previous branch (e.g. CometTrail's Timer-driven Canvas) when
        // status flips. Without this, we've observed CometTrail pixels
        // lingering visually after a .running -> .justFinished transition.
        Group {
            if isRunning {
                CometTrail(color: color)
                    .opacity(isDimmed ? 0.5 : 1)
            } else {
                PixelStatusIcon(pixels: pixels, color: color, blink: isDimmed)
                    .opacity(isDimmed ? 0.5 : 1)
            }
        }
        .id(viewIdentity)
    }

    /// Distinct identity per effective render path so SwiftUI discards
    /// the old view when the path changes (running → idle, etc.).
    private var viewIdentity: String {
        if hasPendingPermission { return "perm" }
        return "\(session.status.rawValue)-\(isDimmed ? 1 : 0)"
    }

    private var indicatorColor: Color {
        if hasPendingPermission || session.status == .waiting {
            return .orange
        }
        if session.status == .running {
            return Color(red: 0.3, green: 0.5, blue: 0.95)
        }
        // Idle / finished / error: tint with the agent's idle color so it
        // reads as "this one's resting" rather than an alert.
        switch session.agentType {
        case .claudeCode: return Color(red: 0.85, green: 0.52, blue: 0.35)
        case .codex:      return Color(red: 0.25, green: 0.65, blue: 0.38)
        }
    }

    private var pixels: [(Int, Int)] {
        if hasPendingPermission {
            return [(1,0),(1,1),(1,2),(1,3),(1,5)] // !
        }
        switch session.status {
        case .running:
            return [] // handled above via CometTrail
        case .waiting:
            return [(1,0),(2,0),(3,1),(2,2),(1,3),(1,5)] // ?
        case .error:
            return [(1,0),(1,1),(1,2),(1,3),(1,5)] // !
        case .justFinished, .done, .idle:
            return [ // ▌▌ cursor pair
                (0,0),(0,1),(0,2),(0,3),(0,4),(0,5),
                (1,0),(1,1),(1,2),(1,3),(1,4),(1,5),
            ]
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

// MARK: - Orbiting Pixel (alternative running-state icon)

/// A single lit pixel orbiting clockwise around a 3×3 ring, 8 keyframes
/// per revolution. Matches the BreathingPixelBall footprint (8×12pt).
struct OrbitingPixel: View {
    let color: Color
    /// Full revolution duration. 1.2s with 12 frames keeps per-step pacing
    /// identical to the earlier 8-frame/0.8s version.
    var period: Double = 1.2

    @State private var frame: Int = 0
    @State private var timer: Timer?

    private let cell: CGFloat = 2
    private let pix: CGFloat = 1.7

    /// 12 positions tracing the perimeter of a 4×4 ring in the 4×6 grid.
    /// Uses the full width (x 0–3) and rows 1–4, leaving 1 row of padding
    /// top and bottom. Starts top-left and orbits clockwise.
    private static let orbit: [(Int, Int)] = [
        // Top edge (left → right)
        (0, 1), (1, 1), (2, 1), (3, 1),
        // Right edge (top → bottom)
        (3, 2), (3, 3), (3, 4),
        // Bottom edge (right → left)
        (2, 4), (1, 4), (0, 4),
        // Left edge (bottom → top)
        (0, 3), (0, 2),
    ]

    var body: some View {
        Canvas { context, _ in
            let (x, y) = Self.orbit[frame % Self.orbit.count]
            let rect = CGRect(
                x: CGFloat(x) * cell,
                y: CGFloat(y) * cell,
                width: pix, height: pix
            )
            // Render the lit pixel with a faint trailing pixel one step
            // behind so the eye can follow the direction of motion.
            let prev = Self.orbit[(frame - 1 + Self.orbit.count) % Self.orbit.count]
            let trailRect = CGRect(
                x: CGFloat(prev.0) * cell,
                y: CGFloat(prev.1) * cell,
                width: pix, height: pix
            )
            context.fill(Path(trailRect), with: .color(color.opacity(0.3)))
            context.fill(Path(rect), with: .color(color))
        }
        .frame(width: 8, height: 12)
        .shadow(color: color.opacity(0.7), radius: 2)
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
    }

    private func startTimer() {
        stopTimer()
        let step = period / Double(Self.orbit.count)
        timer = Timer.scheduledTimer(withTimeInterval: step, repeats: true) { _ in
            frame = (frame + 1) % Self.orbit.count
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Comet Trail (running-state status icon, motion flavor)

/// A single lit head pixel moving left-to-right along one row, leaving a
/// fading 2-pixel trail behind it. Wraps around so the loop is seamless.
/// Reads as "something is moving / running" — complements the walking sprite.
struct CometTrail: View {
    let color: Color
    /// Full loop period (head traverses the 5 columns once). 0.6s feels
    /// energetic; slow to 0.9s for a calmer "data flowing" vibe.
    var period: Double = 0.6

    @State private var frame: Int = 0
    @State private var timer: Timer?

    private let cell: CGFloat = 2
    private let pix: CGFloat = 1.7
    private let columns = 5
    /// Three stacked streaks with gap rows between them (y 1/3/5 skipping
    /// 0/2/4). Staggered phases + per-row alpha patterns create a sparser,
    /// dithered look rather than a solid blue block.
    /// skipMask: if a position is in the mask, that trail pixel is omitted.
    private let streaks: [(y: Int, phase: Int, skipMask: Set<Int>)] = [
        // Use rows 0/2/4 so the content's vertical center (row 2) lines
        // up with the frame center. With y=1/3/5 (center row 3) the comet
        // rendered visibly lower than neighboring sprites when HStack
        // centered both canvases.
        (0, 0, [1]),     // top: skip 2nd trail pixel so it reads as "head + gap + dot"
        (2, 2, []),      // middle: full 3-pixel trail (main comet)
        (4, 4, [2]),     // bottom: skip 3rd trail pixel
    ]

    /// Per-column trail brightness. Index 0 = head. Three visible pixels
    /// per streak; skipMask above can drop individual positions for a
    /// broken-up dithered feel.
    private static let trailAlphas: [Double] = [1.0, 0.55, 0.25]

    var body: some View {
        Canvas { context, _ in
            for streak in streaks {
                let head = (frame + streak.phase) % columns
                for (offset, alpha) in Self.trailAlphas.enumerated().reversed()
                    where alpha > 0 && !streak.skipMask.contains(offset) {
                    let x = (head - offset + columns) % columns
                    drawPixel(context, x: x, y: streak.y, alpha: alpha)
                }
            }
        }
        // 10pt tall frame matches the content range (rows 0–4 × 2pt = 10pt)
        // so the HStack vertically centers the streaks with the sprite.
        .frame(width: 10, height: 10)
        .shadow(color: color.opacity(0.5), radius: 2)
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
    }

    private func drawPixel(_ context: GraphicsContext, x: Int, y: Int, alpha: Double) {
        let rect = CGRect(
            x: CGFloat(x) * cell,
            y: CGFloat(y) * cell,
            width: pix, height: pix
        )
        context.fill(Path(rect), with: .color(color.opacity(alpha)))
    }

    private func startTimer() {
        stopTimer()
        let step = period / Double(columns)
        timer = Timer.scheduledTimer(withTimeInterval: step, repeats: true) { _ in
            frame = (frame + 1) % columns
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Breathing Pixel Ball (running-state status icon)

/// A tiny pixel ball that cycles small → medium → large → medium → small
/// in discrete keyframes, giving a retro "breathing" feel for the running
/// status indicator. Keeps the 8×12pt footprint so it drops in wherever
/// PixelStatusIcon was used.
struct BreathingPixelBall: View {
    let color: Color
    /// Full cycle period (one expand + contract). 1.0s ≈ resting heart rate.
    var period: Double = 1.0

    @State private var frame: Int = 0
    @State private var timer: Timer?

    private let cell: CGFloat = 2
    private let pix: CGFloat = 1.7

    /// Five ordered keyframes walking from smallest to largest (3×3) and
    /// back. Grid is 5 wide × 6 tall; all frames center on (2, 3).
    private static let keyframes: [[(Int, Int)]] = [
        // 0: single pixel center
        [(2, 3)],
        // 1: small plus (5 px)
        [(2, 2), (1, 3), (2, 3), (3, 3), (2, 4)],
        // 2: full 3×3 block (9 px) — PEAK
        [
            (1, 2), (2, 2), (3, 2),
            (1, 3), (2, 3), (3, 3),
            (1, 4), (2, 4), (3, 4),
        ],
        // 3: plus (5 px)
        [(2, 2), (1, 3), (2, 3), (3, 3), (2, 4)],
        // 4: single pixel (back to small)
        [(2, 3)],
    ]

    var body: some View {
        Canvas { context, _ in
            let pixels = Self.keyframes[frame % Self.keyframes.count]
            for (x, y) in pixels {
                let rect = CGRect(
                    x: CGFloat(x) * cell,
                    y: CGFloat(y) * cell,
                    width: pix, height: pix
                )
                context.fill(Path(rect), with: .color(color))
            }
        }
        // 5-wide grid (x 0–4) so the peak can extend antennae symmetrically
        // on both sides. Height stays 12pt (6 rows) to match the old footprint.
        .frame(width: 10, height: 12)
        // Stronger glow on the fuller frames so the "breath" reads.
        .shadow(color: color.opacity(glowAlpha), radius: glowRadius)
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
    }

    private var glowAlpha: Double {
        switch frame % Self.keyframes.count {
        case 0, 4: return 0.35
        case 1, 3: return 0.65
        default:   return 0.95  // frame 2 peak (3×3)
        }
    }

    private var glowRadius: CGFloat {
        switch frame % Self.keyframes.count {
        case 0, 4: return 1.5
        case 1, 3: return 3
        default:   return 5   // frame 2 peak
        }
    }

    private func startTimer() {
        stopTimer()
        let step = period / Double(Self.keyframes.count)
        timer = Timer.scheduledTimer(withTimeInterval: step, repeats: true) { _ in
            withAnimation(.linear(duration: step * 0.7)) {
                frame = (frame + 1) % Self.keyframes.count
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
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
    /// Logical height of the sprite's pixel grid. Defaults to 7 for the
    /// existing Claude/Codex 8×7 footprint; pass larger for taller sprites
    /// (e.g. the 9×9 Codex cloud design).
    var gridHeight: CGFloat = 7
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

    /// Frame grows to fit the sprite if it's bigger than the baseline 16pt.
    private var frameSide: CGFloat {
        max(16, max(gridWidth, gridHeight) * cell)
    }

    var body: some View {
        Canvas { context, size in
            let ox = (size.width - gridWidth * cell) / 2
            let oy = (size.height - gridHeight * cell) / 2 + bobOffset
            for (x, y) in pixels {
                let rect = CGRect(
                    x: ox + CGFloat(x) * cell,
                    y: oy + CGFloat(y) * cell,
                    width: pix, height: pix
                )
                context.fill(Path(rect), with: .color(baseColor))
            }
        }
        .frame(width: frameSide, height: frameSide)
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
    /// When true, the two eye gaps on row 2 are filled in to simulate
    /// closed eyes. Flipped to true for ~120ms at random intervals by
    /// `scheduleBlink()` so the sprite feels alive when idle.
    @State private var blinkActive = false
    @State private var blinkGeneration = 0

    private static let bodyPixels: [(Int, Int)] = [
        (1,1),(2,1),(3,1),(4,1),(5,1),(6,1),
        (1,2),      (3,2),(4,2),      (6,2),
        (0,3),(1,3),(2,3),(3,3),(4,3),(5,3),(6,3),(7,3),
              (1,4),(2,4),(3,4),(4,4),(5,4),(6,4),
              (1,5),(2,5),(3,5),(4,5),(5,5),(6,5),
    ]

    /// Pixels added to row 2 during a blink — fills the two eye gaps
    /// (x=2 and x=5) so the whole row reads as a single closed band.
    private static let closedEyePixels: [(Int, Int)] = [(2,2), (5,2)]

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
        var px = Self.bodyPixels + feet
        if blinkActive {
            px.append(contentsOf: Self.closedEyePixels)
        }
        return px
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
        .onAppear {
            startWalk()
            startBlink()
        }
        .onChange(of: isAnimating) { _, _ in startWalk() }
        .onChange(of: colorOverride) { _, _ in
            startWalk()
            startBlink()
        }
    }

    // MARK: - Blink

    /// Kicks off the blink loop. Skips blinking when the sprite is in
    /// a color-override state (waiting / permission), since eyes change
    /// would read as alert pulsing and muddy that signal.
    private func startBlink() {
        blinkGeneration += 1
        blinkActive = false
        guard colorOverride == nil else { return }
        scheduleNextBlink(generation: blinkGeneration)
    }

    private func scheduleNextBlink(generation: Int) {
        // 4-6s random wait between blinks — anything shorter reads as
        // nervous, anything longer and you stop perceiving the sprite
        // as alive.
        let wait = Double.random(in: 4...6)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            guard generation == self.blinkGeneration, self.colorOverride == nil else { return }
            self.blinkActive = true
            // ~120ms closed phase, then reopen and queue the next blink.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                guard generation == self.blinkGeneration else { return }
                self.blinkActive = false
                self.scheduleNextBlink(generation: generation)
            }
        }
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

// MARK: - Codex Pixel Character (cloud containing >_ terminal prompt)

/// v2 design inspired by Codex's app-icon treatment — a puffy cloud silhouette
/// wrapping the signature `>_` so the little guy feels like a creature, not
/// just a string of glyphs. Cloud is static, cursor still blinks, whole body
/// bobs via PixelCharEngine.
///
/// Grid: 8 wide × 7 tall. Tweak pixel positions in pixel-editor.html.
struct CodexPixelChar: View {
    let isAnimating: Bool
    var colorOverride: Color? = nil
    var showGlow: Bool = true
    @State private var cursorVisible = true
    @State private var blinkGeneration = 0

    /// Solid 7×7 cloud with `>_` cut out as negative space. Hand-tuned in
    /// pixel-editor.html. The chevron and cursor holes are implicit —
    /// anything NOT in this list is where the `>_` shows through.
    private static let cloudPixels: [(Int, Int)] = [
        // Row 0
        (1,0),(2,0),(3,0),(4,0),(5,0),
        // Row 1 (full width)
        (0,1),(1,1),(2,1),(3,1),(4,1),(5,1),(6,1),
        // Row 2 — hole at (1,2) = `>` top
        (0,2),      (2,2),(3,2),(4,2),(5,2),(6,2),
        // Row 3 — hole at (2,3) = `>` point
        (0,3),(1,3),      (3,3),(4,3),(5,3),(6,3),
        // Row 4 — holes at (1,4), (4,4), (5,4) = `>` bottom + `_` cursor
        (0,4),      (2,4),(3,4),            (6,4),
        // Row 5 (full width)
        (0,5),(1,5),(2,5),(3,5),(4,5),(5,5),(6,5),
        // Row 6
        (1,6),(2,6),(3,6),(4,6),(5,6),
    ]

    /// Cursor blink: the `_` at (4,4)(5,4) shows when these are HOLES. To
    /// hide it mid-blink we fill those holes with cloud color.
    private static let cursorFillPixels: [(Int, Int)] = [(4,4),(5,4)]

    private var allPixels: [(Int, Int)] {
        var px = Self.cloudPixels
        // Blink "off" = cursor holes filled in = underline hidden.
        if isAnimating && !cursorVisible {
            px.append(contentsOf: Self.cursorFillPixels)
        }
        return px
    }

    var body: some View {
        PixelCharEngine(
            isAnimating: isAnimating,
            colorOverride: colorOverride,
            idleColor: Color(red: 0.25, green: 0.65, blue: 0.38),
            gridWidth: 7,
            gridHeight: 7,
            bobAmount: -1.0,
            bobDuration: 0.35,
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
