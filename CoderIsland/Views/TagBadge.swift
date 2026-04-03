import SwiftUI

struct TagBadge: View {
    let text: String
    var dimmed: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundColor(.white.opacity(dimmed ? 0.6 : 0.8))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(dimmed ? 0.09 : 0.12))
            )
    }
}
