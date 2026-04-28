import SwiftUI

extension View {
  func liquidGlass(cornerRadius: CGFloat = 22) -> some View {
    glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
  }

  func edgeFadeBlur(height: CGFloat = 24) -> some View {
    self
      .overlay(alignment: .top) { EdgeFadeBlur(edge: .top, height: height) }
      .overlay(alignment: .bottom) { EdgeFadeBlur(edge: .bottom, height: height) }
  }
}

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

struct ToolChip: View {
  let title: String
  let systemImage: String
  let isEnabled: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .labelStyle(.titleAndIcon)
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
    .buttonStyle(.glass)
    .tint(isEnabled ? .accentColor : .secondary)
    .accessibilityValue(isEnabled ? "Enabled" : "Disabled")
  }
}
