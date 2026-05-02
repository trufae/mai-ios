import SwiftUI

struct EdgeFadeBlur: View {
  let edge: VerticalEdge
  let height: CGFloat

  var body: some View {
    Rectangle()
      .fill(.ultraThinMaterial)
      .frame(height: height)
      .mask(
        LinearGradient(
          colors: edge == .top ? [.black, .clear] : [.clear, .black],
          startPoint: .top,
          endPoint: .bottom
        )
      )
      .allowsHitTesting(false)
  }
}
