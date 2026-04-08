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
                // Explicit RGB instead of `Color.white.opacity(...)` so the
                // fill survives older macOS compositors (15.x has been seen
                // to rasterize 9-12% white-over-black as effectively
                // transparent, leaving badges with no visible background).
                RoundedRectangle(cornerRadius: 6)
                    .fill(dimmed
                          ? Color(red: 0.15, green: 0.15, blue: 0.17)
                          : Color(red: 0.19, green: 0.19, blue: 0.21))
            )
    }
}
