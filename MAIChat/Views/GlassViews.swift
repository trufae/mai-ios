import SwiftUI

extension View {
  func liquidGlass(cornerRadius: CGFloat = 22) -> some View {
    glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
