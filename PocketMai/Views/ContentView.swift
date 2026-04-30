import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var store: AppStore
  @State private var showingSettings = false
  @State private var showingHistory = false
  @State private var historyDragOffset: CGFloat = 0

  var body: some View {
    GeometryReader { proxy in
      let panelWidth = min(max(proxy.size.width * 0.82, 300), 390)
      let panelOffset = clampedHistoryOffset(panelWidth: panelWidth)
      let revealProgress = panelOffset / panelWidth

      ZStack(alignment: .leading) {
        if showingHistory || historyDragOffset > 0 {
          SidebarView(
            showingSettings: $showingSettings,
            onSelectConversation: closeHistoryPanel
          )
          .frame(width: panelWidth)
          .frame(maxHeight: .infinity)
          .background(.regularMaterial)
          .zIndex(0)
        }

        NavigationStack {
          ChatView(
            onShowHistory: {
              withAnimation(.snappy) {
                showingHistory.toggle()
              }
            }
          )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(PanelClipModifier(cornerRadius: panelOffset > 0 ? 28 : 0))
        .shadow(
          color: .black.opacity(Double(revealProgress) * 0.2),
          radius: 24 * revealProgress,
          x: -8 * revealProgress,
          y: 0
        )
        .allowsHitTesting(panelOffset == 0)
        .overlay {
          if panelOffset > 0 {
            Color.black.opacity(0.001)
              .contentShape(Rectangle())
              .onTapGesture {
                closeHistoryPanel()
              }
          }
        }
        .offset(x: panelOffset)
        .scaleEffect(x: 1 - (revealProgress * 0.03), y: 1, anchor: .trailing)
        .zIndex(1)
      }
      .background(Color(uiColor: .systemGroupedBackground))
      .contentShape(Rectangle())
      .simultaneousGesture(historyPanelDragGesture(panelWidth: panelWidth))
    }
    .sheet(isPresented: $showingSettings) {
      SettingsView()
        .environmentObject(store)
    }
    .alert("Error", isPresented: errorBinding) {
      Button("OK") { store.errorMessage = nil }
    } message: {
      Text(store.errorMessage ?? "")
    }
    .tint(store.settings.appearance.tintColor)
    .accentColor(store.settings.appearance.tintColor)
  }

  private func clampedHistoryOffset(panelWidth: CGFloat) -> CGFloat {
    let baseOffset = showingHistory ? panelWidth : 0
    return min(max(baseOffset + historyDragOffset, 0), panelWidth)
  }

  private func closeHistoryPanel() {
    withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) {
      showingHistory = false
      historyDragOffset = 0
    }
  }

  private func historyPanelDragGesture(panelWidth: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 12, coordinateSpace: .local)
      .onChanged { value in
        let horizontal = value.translation.width
        let vertical = abs(value.translation.height)
        guard abs(horizontal) > 12, abs(horizontal) > vertical * 1.4 else { return }

        let baseOffset = showingHistory ? panelWidth : 0
        let draggedOffset = min(max(baseOffset + horizontal, 0), panelWidth)
        historyDragOffset = draggedOffset - baseOffset
      }
      .onEnded { value in
        let horizontal = value.translation.width
        let vertical = abs(value.translation.height)
        guard abs(horizontal) > 12, abs(horizontal) > vertical * 1.4 else {
          historyDragOffset = 0
          return
        }

        let baseOffset = showingHistory ? panelWidth : 0
        let projectedOffset = min(
          max(baseOffset + value.predictedEndTranslation.width, 0), panelWidth)
        withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.86)) {
          showingHistory = projectedOffset > panelWidth * 0.45
          historyDragOffset = 0
        }
      }
  }

  private var errorBinding: Binding<Bool> {
    Binding(
      get: { store.errorMessage != nil },
      set: { if !$0 { store.errorMessage = nil } }
    )
  }
}

private struct PanelClipModifier: ViewModifier {
  let cornerRadius: CGFloat

  func body(content: Content) -> some View {
    if cornerRadius > 0 {
      content.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    } else {
      content
    }
  }
}
