import SwiftUI

struct CompactBarView: View {
    @ObservedObject var agentManager: AgentManager
    let onTap: () -> Void

    @State private var isHovered = false

    private let barColor = Color(nsColor: NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1))

    var body: some View {
        HStack(spacing: 8) {
            if agentManager.sessions.isEmpty {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
                Text("No agents")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.gray)
            } else {
                let first = agentManager.sessions[0]

                // Pixel robot icon
                PixelIcon()

                Text(first.taskName)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Spacer()

                // Session count badge
                if agentManager.sessions.count > 1 {
                    Text("\(agentManager.sessions.count)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.15))
                        )
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(barColor)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .onTapGesture {
            onTap()
        }
    }
}
