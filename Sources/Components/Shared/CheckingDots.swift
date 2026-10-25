import SwiftUI

struct PrettyPrintCheckingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                dots(activeIndex: nil)
            } else {
                PhaseAnimator([0, 1, 2]) { activeIndex in
                    dots(activeIndex: activeIndex)
                } animation: { _ in
                    .easeInOut(duration: 0.18)
                }
            }
        }
        .frame(width: 13, height: 13)
        .accessibilityHidden(true)
    }

    private func dots(activeIndex: Int?) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                let isActive = activeIndex == index

                Circle()
                    .fill(Color.secondary)
                    .frame(width: 3, height: 3)
                    .scaleEffect(activeIndex == nil ? 0.85 : isActive ? 1 : 0.72)
                    .opacity(activeIndex == nil ? 0.7 : isActive ? 1 : 0.35)
            }
        }
    }
}
