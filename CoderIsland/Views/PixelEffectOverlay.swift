import SwiftUI

// MARK: - Notification plumbing

extension Notification.Name {
    /// Posted by SoundManager whenever a sound actually plays. userInfo:
    /// - key "category": String (SoundCategory.rawValue)
    /// - key "sessionId": String? (optional session this play is tied to)
    static let coderIslandSoundPlayed = Notification.Name("CoderIslandSoundPlayed")
}

// MARK: - Effect overlay

/// Attaches ephemeral pixel effects on top of an agent sprite when a sound
/// fires. Listens to `.coderIslandSoundPlayed` notifications and spawns a
/// short-lived animation matching the category.
///
/// Place as an overlay on whatever view renders the agent character; sized
/// to align with an 8×7 pixel sprite (16×16pt).
struct PixelEffectOverlay: View {
    /// When non-nil, only react to notifications carrying this sessionId.
    /// Pass nil for the compact bar where a single-sprite preview is shared.
    var matchSessionId: String? = nil

    @State private var activeBurst: UUID? = nil

    var body: some View {
        ZStack {
            if let id = activeBurst {
                StarBurst()
                    .id(id)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: 16, height: 16)
        .onReceive(NotificationCenter.default.publisher(for: .coderIslandSoundPlayed)) { note in
            handle(note)
        }
    }

    private func handle(_ note: Notification) {
        guard let raw = note.userInfo?["category"] as? String,
              let category = SoundCategory(rawValue: raw) else { return }

        if let expected = matchSessionId {
            let incoming = note.userInfo?["sessionId"] as? String
            // Row-level contexts take events targeting them AND global
            // events (incoming nil) like Settings ▶ preview so users see
            // feedback everywhere when testing.
            if let incoming, incoming != expected { return }
        }

        switch category {
        case .taskComplete:
            activeBurst = UUID()
            // Reset the state after the burst's self-duration so a
            // subsequent taskComplete triggers a fresh burst.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                if activeBurst != nil {
                    activeBurst = nil
                }
            }
        default:
            break
        }
    }
}

// MARK: - Star burst

/// A short-lived 3-star pixel effect. Draws three small pixel stars near the
/// sprite origin, floats them upward, fades them out. Auto-lifetime ~1.2s.
private struct StarBurst: View {
    @State private var phase: CGFloat = 0

    // Pixel plus-sign pattern (5 pixels) representing a sparkle/star
    private static let starPixels: [(Int, Int)] = [
        (1, 0),
        (0, 1), (1, 1), (2, 1),
        (1, 2),
    ]

    // Per-star offsets (x, yBase, delay), to stagger the burst.
    private let stars: [(x: CGFloat, yBase: CGFloat, delay: Double)] = [
        (x: -6, yBase: 0,  delay: 0),
        (x:  6, yBase: 2,  delay: 0.10),
        (x:  0, yBase: -2, delay: 0.20),
    ]

    var body: some View {
        ZStack {
            ForEach(0..<stars.count, id: \.self) { i in
                let info = stars[i]
                Canvas { context, size in
                    let cell: CGFloat = 2
                    let pix: CGFloat = 1.7
                    // Center the 3×3 star pattern.
                    let ox = (size.width - 3 * cell) / 2
                    let oy = (size.height - 3 * cell) / 2
                    for (x, y) in Self.starPixels {
                        let rect = CGRect(
                            x: ox + CGFloat(x) * cell,
                            y: oy + CGFloat(y) * cell,
                            width: pix, height: pix
                        )
                        context.fill(Path(rect), with: .color(Color(red: 1.0, green: 0.93, blue: 0.5)))
                    }
                }
                .frame(width: 8, height: 8)
                .shadow(color: Color(red: 1.0, green: 0.93, blue: 0.5).opacity(0.85), radius: 2)
                .offset(x: info.x, y: info.yBase - phase * 14)
                .opacity(max(0, 1 - phase * 1.1))
                .scaleEffect(0.7 + phase * 0.5)
                .task {
                    // Delay this star so the three arrive in a quick sequence.
                    try? await Task.sleep(nanoseconds: UInt64(info.delay * 1_000_000_000))
                    withAnimation(.easeOut(duration: 1.1)) {
                        phase = 1
                    }
                }
            }
        }
        .frame(width: 16, height: 16)
    }
}

// MARK: - Preview

#if DEBUG
private struct _PreviewHost: View {
    @State private var tick = 0
    var body: some View {
        VStack(spacing: 12) {
            Text("Effect preview (tap to fire)")
                .foregroundColor(.white)
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 40, height: 40)
                PixelEffectOverlay()
            }
            Button("Fire taskComplete") {
                NotificationCenter.default.post(
                    name: .coderIslandSoundPlayed,
                    object: nil,
                    userInfo: ["category": "taskComplete"]
                )
                tick += 1
            }
            Text("Fired: \(tick)").foregroundColor(.white)
        }
        .padding(40)
        .frame(width: 320, height: 220)
        .background(Color.black)
    }
}

#Preview {
    _PreviewHost()
}
#endif
