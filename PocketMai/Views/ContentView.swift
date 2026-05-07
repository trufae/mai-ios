import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var screenshotService = ChatScreenshotService()
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
          .modifier(SidebarRevealModifier(progress: revealProgress))
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
    .sheet(item: toolCallApprovalBinding) { request in
      ToolCallApprovalView(request: request)
        .environmentObject(store)
        .interactiveDismissDisabled()
    }
    .alert("Error", isPresented: errorBinding) {
      Button("OK") { store.errorMessage = nil }
    } message: {
      Text(store.errorMessage ?? "")
    }
    .background(ChatScreenshotServiceInstaller(service: screenshotService))
    .onAppear {
      screenshotService.store = store
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        store.refreshAppleIntelligenceAvailabilityInBackground()
      }
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

  private var toolCallApprovalBinding: Binding<ToolCallApprovalRequest?> {
    Binding(
      get: { store.activeToolCallApprovalRequest },
      set: { _ in }
    )
  }

  private var errorBinding: Binding<Bool> {
    Binding(
      get: { store.errorMessage != nil },
      set: { if !$0 { store.errorMessage = nil } }
    )
  }
}

private struct ToolCallApprovalView: View {
  @EnvironmentObject private var store: AppStore
  let request: ToolCallApprovalRequest
  @State private var toolCallText: String
  @State private var validationError: String?

  init(request: ToolCallApprovalRequest) {
    self.request = request
    _toolCallText = State(initialValue: request.originalText)
  }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 14) {
        Label(request.callName, systemImage: "wrench.and.screwdriver")
          .font(.headline)
          .lineLimit(2)
        if let conversationTitle = request.conversationTitle {
          Text(conversationTitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        TextEditor(text: $toolCallText)
          .font(.system(.body, design: .monospaced))
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .scrollContentBackground(.hidden)
          .padding(8)
          .frame(minHeight: 260)
          .background(Color(uiColor: .secondarySystemGroupedBackground))
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        if let validationError {
          Text(validationError)
            .font(.footnote)
            .foregroundStyle(.red)
        }
        Spacer(minLength: 0)
      }
      .padding()
      .navigationTitle("Confirm Tool Call")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", role: .cancel) {
            store.cancelToolCallApproval(id: request.id)
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Run") {
            validationError = store.approveToolCall(id: request.id, editedText: toolCallText)
          }
        }
      }
    }
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

private struct SidebarRevealModifier: ViewModifier {
  let progress: CGFloat

  func body(content: Content) -> some View {
    content
      .scaleEffect(scale, anchor: .leading)
  }

  private var clampedProgress: CGFloat {
    min(max(progress, 0), 1)
  }

  private var easedProgress: CGFloat {
    let progress = clampedProgress
    return progress * progress * (3 - 2 * progress)
  }

  private var scale: CGFloat {
    0.88 + easedProgress * 0.12
  }
}
