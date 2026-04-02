import SwiftUI
import Combine

class NotchViewModel: ObservableObject {
    @Published var isExpanded = true
    @Published var hoveredAgentId: String?

    func toggleExpanded() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            isExpanded.toggle()
        }
    }
}
