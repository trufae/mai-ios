import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ChatView: View {
  @EnvironmentObject private var store: AppStore
  @EnvironmentObject private var ttsPlayer: TTSPlayer
  @State private var showingRenameAlert = false
  @State private var showingProviderModelSheet = false
  @State private var showingCompactSheet = false
  @State private var messagePendingDeletion: ChatMessage?
  @State private var messagePendingTrimAndResubmit: ChatMessage?
  @State private var messagePendingRestartFresh: ChatMessage?
  @State private var exportShareFile: ExportedFile?
  @State private var showingAudioExport: Bool = false
  @State private var audioExportError: String?
  @State private var renameDraft = ""
  @State private var userScrolledAfterLastMessage = false
  @State private var pendingScrollToMessageID: UUID?
  @State private var fontSizePinchBase: Double?
  @State private var fontSizePinchAnchor: MessageListPinchAnchor?
  @State private var fontSizePinchViewportY: CGFloat?
  @StateObject private var audioExporter = TTSExporter()
  @StateObject private var liveVoiceSession = LiveVoiceSession()
  private let messageListBottomID = "MessageListBottom"
  let onShowHistory: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      if let providerStatus {
        providerStatusBanner(providerStatus)
      }
      NowSpeakingBar { messageID in
        pendingScrollToMessageID = messageID
      }
      messages
      composer
    }
    .animation(.snappy, value: ttsPlayer.isSpeaking)
    .navigationTitle("")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button(action: onShowHistory) {
          Image(systemName: "sidebar.left")
        }
        .help("Show conversations")
      }
      ToolbarItem(placement: .principal) {
        chatTitle
      }
      ToolbarItem(placement: .topBarTrailing) {
        trailingMenu
      }
    }
    .alert("Change Title", isPresented: $showingRenameAlert) {
      TextField("Chat title", text: $renameDraft)
        .onSubmit {
          renameCurrentConversation()
        }
      Button("Cancel", role: .cancel) {}
      Button("Save") {
        renameCurrentConversation()
      }
    }
    .sheet(isPresented: $showingProviderModelSheet) {
      ConversationModelSettingsView()
        .environmentObject(store)
    }
    .sheet(isPresented: $showingCompactSheet) {
      CompactChatSheet()
        .environmentObject(store)
    }
    .sheet(item: $exportShareFile) { file in
      ActivityShareSheet(activityItems: [file.url])
    }
    .modifier(
      AudioExportPresentations(
        exporter: audioExporter,
        showingAudioExport: $showingAudioExport,
        audioExportError: $audioExportError)
    )
    .alert(
      "Delete this message?",
      isPresented: deleteMessageConfirmationBinding,
      presenting: messagePendingDeletion
    ) { message in
      Button("Cancel", role: .cancel) {
        messagePendingDeletion = nil
      }
      Button("Delete Message", role: .destructive) {
        store.deleteMessage(message)
        messagePendingDeletion = nil
      }
    } message: { _ in
      Text("This message will be removed from the chat. This cannot be undone.")
    }
    .alert(
      "Retry from here?",
      isPresented: trimAndResubmitConfirmationBinding,
      presenting: messagePendingTrimAndResubmit
    ) { message in
      Button("Cancel", role: .cancel) {
        messagePendingTrimAndResubmit = nil
      }
      Button("Retry From Here", role: .destructive) {
        Task { await store.trimAndResubmit(from: message) }
        messagePendingTrimAndResubmit = nil
      }
    } message: { _ in
      Text("Messages after this point will be removed before the response is regenerated.")
    }
    .alert(
      "Restart from here?",
      isPresented: restartFreshConfirmationBinding,
      presenting: messagePendingRestartFresh
    ) { message in
      Button("Cancel", role: .cancel) {
        messagePendingRestartFresh = nil
      }
      Button("Restart From Here", role: .destructive) {
        Task { await store.restartFromScratch(with: message) }
        messagePendingRestartFresh = nil
      }
    } message: { _ in
      Text("All current messages will be removed before starting again from this message.")
    }
  }

  private var chatTitle: some View {
    Menu {
      Button {
        beginRename()
      } label: {
        Label("Change Title...", systemImage: "pencil")
      }
      Divider()
      Button {
        showingProviderModelSheet = true
      } label: {
        Label("Provider & Model", systemImage: "cpu")
      }
      Menu {
        ForEach(store.settings.systemPrompts) { prompt in
          Button {
            store.updateCurrentConversation { conversation in
              conversation.systemPromptID = prompt.id
            }
          } label: {
            if prompt.id == currentSystemPromptID {
              Label(prompt.displayName, systemImage: "checkmark")
            } else {
              Text(prompt.displayName)
            }
          }
        }
      } label: {
        Label("System Prompt", systemImage: "text.bubble")
      }
      Menu {
        Button {
          store.updateCurrentConversation { conversation in
            conversation.languageOverrideIdentifier = nil
          }
        } label: {
          if currentLanguageOverrideIdentifier == nil {
            Label("Defaults", systemImage: "checkmark")
          } else {
            Text("Defaults")
          }
        }
        Divider()
        ForEach(languageMenuOptions, id: \.self) { identifier in
          Button {
            store.updateCurrentConversation { conversation in
              conversation.languageOverrideIdentifier = identifier
            }
          } label: {
            if identifier == currentLanguageOverrideIdentifier {
              Label(SystemLanguageSupport.languageDisplayName(identifier), systemImage: "checkmark")
            } else {
              Text(SystemLanguageSupport.languageDisplayName(identifier))
            }
          }
        }
      } label: {
        Label("Language", systemImage: "globe")
      }
      Divider()
      Button {
        store.toggleOpenAPIServer()
      } label: {
        Label(
          store.isOpenAPIServerActive ? "Stop serving" : "Serve",
          systemImage: store.isOpenAPIServerActive ? "stop.circle" : "network")
      }
      Button {
        showingCompactSheet = true
      } label: {
        Label("Compact Chat", systemImage: "rectangle.compress.vertical")
      }
      .disabled(!canCompactCurrentChat)
    } label: {
      VStack(spacing: 1) {
        Text(store.currentConversation?.displayTitle ?? "Chat")
          .font(.headline)
          .lineLimit(1)
          .foregroundStyle(.primary)
        Text(providerSubtitle)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        if let systemPromptTitle {
          Text(systemPromptTitle)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: 240)
      .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .accessibilityHint("Tap for chat options")
  }

  private var currentSystemPromptID: UUID? {
    store.currentConversation?.systemPromptID ?? store.settings.defaultSystemPromptID
  }

  private var systemPromptName: String? {
    guard let id = currentSystemPromptID,
      let prompt = store.settings.systemPrompts.first(where: { $0.id == id })
    else { return nil }
    return prompt.displayName
  }

  private var systemPromptTitle: String? {
    guard let systemPromptName else { return nil }
    return store.settings.airplaneModeEnabled ? "\(systemPromptName) (offline)" : systemPromptName
  }

  private var currentLanguageOverrideIdentifier: String? {
    store.currentConversation?.effectiveLanguageOverrideIdentifier
  }

  private var languageMenuOptions: [String] {
    SystemLanguageSupport.chatLanguageIdentifiers(including: currentLanguageOverrideIdentifier)
  }

  private var currentToolSettings: NativeToolSettings {
    store.effectiveToolSettings(for: store.currentConversation)
  }

  private var canCompactCurrentChat: Bool {
    guard let conversation = store.currentConversation else { return false }
    if store.isCompacting || store.isResponding { return false }
    let substantive = conversation.messages.filter { msg in
      msg.role != .error
        && !msg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    return substantive.count >= 2
  }

  private var composerPlaceholder: String {
    "Ask anything..."
  }

  private var currentChatIsResponding: Bool {
    guard let id = store.currentConversation?.id else { return false }
    return store.isResponding(in: id)
  }

  private var providerSubtitle: String {
    if store.isCompacting { return "Compacting…" }
    guard let conversation = store.currentConversation else { return "No conversation" }
    let providerName = providerLabel(for: conversation)
    let model = conversation.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    return model.isEmpty ? providerName : "\(providerName) · \(model)"
  }

  private func providerLabel(for conversation: Conversation) -> String {
    switch conversation.provider {
    case .apple:
      return store.appleIntelligenceIsAvailable ? "Apple Intelligence" : "MLX Local"
    case .mlx:
      return "MLX Local"
    case .openAICompatible:
      let endpoint = conversation.endpointID.flatMap { id in
        store.settings.openAIEndpoints.first(where: { $0.id == id })
      }
      return endpoint?.displayName
        ?? AgentTooling.firstNonEmpty(URL(string: endpoint?.baseURL ?? "")?.host)
        ?? OpenAIEndpoint.defaultDisplayName
    }
  }

  private func providerStatusBanner(_ status: (message: String, systemImage: String, color: Color))
    -> some View
  {
    Label(status.message, systemImage: status.systemImage)
      .font(.caption)
      .foregroundStyle(status.color)
      .lineLimit(2)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal)
      .padding(.vertical, 10)
      .background(.ultraThinMaterial)
  }

  private func beginRename() {
    renameDraft = store.currentConversation?.displayTitle ?? ""
    showingRenameAlert = true
  }

  private func renameCurrentConversation() {
    let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    store.updateCurrentConversation { conversation in
      conversation.title = trimmed.isEmpty ? "New chat" : trimmed
    }
    showingRenameAlert = false
  }

  private var trailingMenu: some View {
    Menu {
      Button {
        store.newConversation()
      } label: {
        Label("New Chat", systemImage: "bubble.left.and.text.bubble.right")
      }
      .disabled(currentConversationIsEmpty)
      Divider()
      exportMenuSection
    } label: {
      Image(systemName: "square.and.pencil")
    }
    .buttonStyle(.glass)
  }

  @ViewBuilder
  private var exportMenuSection: some View {
    Section("Export Conversation") {
      ForEach(ConversationExportFormat.allCases) { format in
        Button {
          Task { await shareExport(format) }
        } label: {
          Label(format.displayName, systemImage: format.systemImage)
        }
        .disabled(format == .audio && audioExporter.isExporting)
      }
      .disabled(audioExporter.isExporting)
    }
  }

  @MainActor
  private func shareExport(_ format: ConversationExportFormat) async {
    guard let url = await exportFileURL(for: format) else { return }
    exportShareFile = ExportedFile(url: url)
  }

  @MainActor
  private func exportFileURL(for format: ConversationExportFormat) async -> URL? {
    if format == .audio {
      return await exportAudioFile()
    }
    if format == .debug {
      return await store.exportCurrentConversationDebugJSONFile()
    }
    return store.exportCurrentConversationFile(format: format)
  }

  @MainActor
  private func exportAudioFile() async -> URL? {
    guard let conversation = store.currentConversation else { return nil }
    showingAudioExport = true
    do {
      let url = try ConversationExportFiles.url(for: conversation, format: .audio)
      try await audioExporter.export(
        messages: conversation.messages,
        voices: store.effectiveToolSettings(for: conversation).voices,
        skipTechnicalContent: store.settings.conversation.skipTechnicalContentInTTS,
        to: url)
      showingAudioExport = false
      try? await Task.sleep(for: .milliseconds(250))
      return url
    } catch is CancellationError {
      showingAudioExport = false
      return nil
    } catch {
      showingAudioExport = false
      audioExportError =
        (error as? LocalizedError)?.errorDescription
        ?? error.localizedDescription
      return nil
    }
  }

  private func speakFromHere(_ message: ChatMessage) {
    guard
      let conversation = store.currentConversation,
      let index = conversation.messages.firstIndex(where: { $0.id == message.id })
    else {
      return
    }
    ttsPlayer.speakFromHere(
      messages: Array(conversation.messages[index...]),
      voices: store.effectiveToolSettings(for: conversation).voices,
      openAIEndpoints: store.settings.airplaneModeEnabled ? [] : store.settings.openAIEndpoints,
      skipTechnicalContent: store.settings.conversation.skipTechnicalContentInTTS
    )
  }

  private func editMessage(_ message: ChatMessage, text: String) {
    guard
      let currentText = store.currentConversation?.messages.first(where: { $0.id == message.id })?.text,
      currentText != text
    else {
      return
    }
    store.updateCurrentConversation { conversation in
      guard let index = conversation.messages.firstIndex(where: { $0.id == message.id }) else {
        return
      }
      conversation.messages[index].text = text
    }
  }

  private var providerStatus: (message: String, systemImage: String, color: Color)? {
    if let conversation = store.currentConversation,
      store.settings.airplaneModeEnabled,
      !conversation.provider.isAirplaneModeEligible
    {
      return (
        store.appleIntelligenceIsAvailable
          ? "Airplane Mode is on. Switch this chat to Apple Intelligence or MLX Local."
          : "Airplane Mode is on. Switch this chat to MLX Local.",
        "airplane",
        .orange
      )
    }
    return nil
  }

  private var messages: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(spacing: 14) {
          if currentConversationIsEmpty && liveVoiceSession.previewMessage == nil {
            emptyState
              .containerRelativeFrame(.vertical, alignment: .center)
          } else {
            ForEach(store.currentConversation?.messages ?? []) { message in
              MessageBubble(
                message: message,
                toolSettings: currentToolSettings,
                openAIEndpoints: store.settings.airplaneModeEnabled
                  ? [] : store.settings.openAIEndpoints,
                skipTechnicalContentInTTS: store.settings.conversation.skipTechnicalContentInTTS,
                appearance: store.settings.appearance,
                renderMarkdown: store.settings.renderMarkdownInChat,
                renderImages: store.settings.renderMarkdownImagesInChat,
                onDelete: { messagePendingDeletion = message },
                onEdit: { editedText in editMessage(message, text: editedText) },
                onResubmit: message.role == .user
                  ? { Task { await store.resubmit(message) } }
                  : nil,
                onTrimFromHere: { messagePendingTrimAndResubmit = message },
                onRestartFresh: { messagePendingRestartFresh = message },
                onNewChatWithMessage: { Task { await store.startNewConversation(with: message) } },
                onSpeakFromHere: { speakFromHere(message) },
                showThinking: store.currentConversation?.showThinking ?? false,
                isWaitingForResponse: isWaitingForResponse(message),
                onStreamingTextChange: { _ in
                  guard !userScrolledAfterLastMessage else { return }
                  scrollToBottom(proxy, animated: false)
                }
              )
              .background {
                MessageListAnchorMarker(messageID: message.id)
              }
              .id(message.id)
            }
            if let preview = liveVoiceSession.previewMessage {
              MessageBubble(
                message: preview,
                toolSettings: currentToolSettings,
                openAIEndpoints: store.settings.airplaneModeEnabled
                  ? [] : store.settings.openAIEndpoints,
                appearance: store.settings.appearance,
                renderMarkdown: store.settings.renderMarkdownInChat,
                renderImages: store.settings.renderMarkdownImagesInChat,
                onDelete: {},
                showThinking: store.currentConversation?.showThinking ?? false,
                isWaitingForResponse: false
              )
              .id(preview.id)
            }
          }
          Color.clear
            .frame(height: 1)
            .id(messageListBottomID)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .center)
        .background {
          MessageListPinchGestureBridge(
            onChanged: { magnification, scrollView, location in
              updateMessageFontSize(for: magnification, in: scrollView, at: location)
            },
            onEnded: endMessageFontSizePinch
          )
        }
      }
      .id(store.selectedConversationID)
      .defaultScrollAnchor(.bottom)
      .scrollDismissesKeyboard(.interactively)
      .simultaneousGesture(messageListScrollGesture)
      .onChange(of: lastMessageSnapshot) { old, new in
        if old.conversationID != new.conversationID {
          userScrolledAfterLastMessage = false
          return
        }
        if old.messageID != new.messageID {
          userScrolledAfterLastMessage = false
          scrollToBottom(proxy, animated: true)
          return
        }
        guard old.text != new.text, !userScrolledAfterLastMessage else { return }
        DispatchQueue.main.async {
          scrollToBottom(proxy, animated: false)
        }
      }
      .onChange(of: liveVoiceSession.transcript) { _, _ in
        guard !userScrolledAfterLastMessage else { return }
        scrollToBottom(proxy, animated: false)
      }
      .onChange(of: pendingScrollToMessageID) { _, target in
        guard let target else { return }
        withAnimation(.snappy) {
          proxy.scrollTo(target, anchor: .center)
        }
        pendingScrollToMessageID = nil
      }
    }
  }

  private var deleteMessageConfirmationBinding: Binding<Bool> {
    Binding {
      messagePendingDeletion != nil
    } set: { isPresented in
      if !isPresented {
        messagePendingDeletion = nil
      }
    }
  }
  private var trimAndResubmitConfirmationBinding: Binding<Bool> {
    Binding {
      messagePendingTrimAndResubmit != nil
    } set: { isPresented in
      if !isPresented {
        messagePendingTrimAndResubmit = nil
      }
    }
  }

  private var restartFreshConfirmationBinding: Binding<Bool> {
    Binding {
      messagePendingRestartFresh != nil
    } set: { isPresented in
      if !isPresented {
        messagePendingRestartFresh = nil
      }
    }
  }

  private var currentConversationIsEmpty: Bool {
    store.currentConversation?.messages.isEmpty ?? true
  }

  private struct LastMessageSnapshot: Equatable {
    var conversationID: UUID?
    var messageID: UUID?
    var text: String?
  }

  private var lastMessageSnapshot: LastMessageSnapshot {
    let convo = store.currentConversation
    let last = convo?.messages.last
    return LastMessageSnapshot(conversationID: convo?.id, messageID: last?.id, text: last?.text)
  }

  private func isWaitingForResponse(_ message: ChatMessage) -> Bool {
    guard currentChatIsResponding, message.role == .assistant else { return false }
    return store.currentConversation?.messages.last?.id == message.id
  }

  private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
    if animated {
      withAnimation(.snappy) {
        proxy.scrollTo(messageListBottomID, anchor: .bottom)
      }
    } else {
      proxy.scrollTo(messageListBottomID, anchor: .bottom)
    }
  }

  private var messageListScrollGesture: some Gesture {
    DragGesture(minimumDistance: 8, coordinateSpace: .local)
      .onChanged { value in
        guard abs(value.translation.height) > abs(value.translation.width) else { return }
        userScrolledAfterLastMessage = true
      }
  }

  private func updateMessageFontSize(
    for magnification: CGFloat,
    in scrollView: UIScrollView,
    at contentPoint: CGPoint
  ) {
    let baseSize = fontSizePinchBase ?? store.settings.appearance.fontSize
    fontSizePinchBase = baseSize
    userScrolledAfterLastMessage = true

    let rawSize = baseSize * max(Double(magnification), 0.1)
    let steppedSize =
      (rawSize / AppearanceSettings.fontSizeStep).rounded() * AppearanceSettings.fontSizeStep
    let clampedSize = AppearanceSettings.clampedFontSize(steppedSize)
    guard store.settings.appearance.fontSize != clampedSize else { return }

    // Capture anchor and viewport position once per gesture — reusing them avoids the
    // O(n) UIView tree walk on every tick and prevents anchor drift as fingers move.
    let anchor: MessageListPinchAnchor
    if let cached = fontSizePinchAnchor {
      anchor = cached
    } else {
      anchor = makePinchAnchor(in: scrollView, at: contentPoint)
      fontSizePinchAnchor = anchor
    }
    let viewportY: CGFloat
    if let cached = fontSizePinchViewportY {
      viewportY = cached
    } else {
      viewportY = contentPoint.y - scrollView.contentOffset.y
      fontSizePinchViewportY = viewportY
    }

    store.settings.appearance.fontSize = clampedSize

    preservePinchPosition(
      in: scrollView,
      anchor: anchor,
      viewportY: viewportY)
  }

  private func endMessageFontSizePinch() {
    fontSizePinchBase = nil
    fontSizePinchAnchor = nil
    fontSizePinchViewportY = nil
    store.saveSettings()
  }

  private func preservePinchPosition(
    in scrollView: UIScrollView,
    anchor: MessageListPinchAnchor,
    viewportY: CGFloat
  ) {
    DispatchQueue.main.async {
      scrollView.layoutIfNeeded()
      let targetContentY = resolvedContentY(for: anchor, in: scrollView)
      let targetY = targetContentY - viewportY
      scrollView.setContentOffset(
        CGPoint(x: scrollView.contentOffset.x, y: clampedScrollOffsetY(targetY, in: scrollView)),
        animated: false)
    }
  }

  private func makePinchAnchor(
    in scrollView: UIScrollView,
    at contentPoint: CGPoint
  ) -> MessageListPinchAnchor {
    let fallbackContentHeight = max(scrollView.contentSize.height, 1)
    guard let anchorView = nearestMessageAnchorView(in: scrollView, to: contentPoint) else {
      return MessageListPinchAnchor(
        messageID: nil,
        unitY: 0,
        fallbackContentY: contentPoint.y,
        fallbackContentHeight: fallbackContentHeight)
    }

    let frame = anchorView.convert(anchorView.bounds, to: scrollView)
    let unitY =
      frame.height > 1
      ? min(max((contentPoint.y - frame.minY) / frame.height, 0), 1)
      : 0
    return MessageListPinchAnchor(
      messageID: anchorView.messageID,
      unitY: unitY,
      fallbackContentY: contentPoint.y,
      fallbackContentHeight: fallbackContentHeight)
  }

  private func resolvedContentY(
    for anchor: MessageListPinchAnchor,
    in scrollView: UIScrollView
  ) -> CGFloat {
    if let messageID = anchor.messageID,
      let anchorView = messageAnchorView(with: messageID, in: scrollView)
    {
      let frame = anchorView.convert(anchorView.bounds, to: scrollView)
      if frame.height > 0 {
        return frame.minY + frame.height * anchor.unitY
      }
    }

    let newContentHeight = max(scrollView.contentSize.height, 1)
    return anchor.fallbackContentY * newContentHeight / anchor.fallbackContentHeight
  }

  private func nearestMessageAnchorView(
    in scrollView: UIScrollView,
    to contentPoint: CGPoint
  ) -> MessageListAnchorUIView? {
    var best:
      (view: MessageListAnchorUIView, verticalDistance: CGFloat, horizontalDistance: CGFloat)?

    func visit(_ view: UIView) {
      if let anchorView = view as? MessageListAnchorUIView {
        let frame = anchorView.convert(anchorView.bounds, to: scrollView)
        if frame.width > 0 && frame.height > 0 {
          let verticalDistance: CGFloat
          if frame.minY <= contentPoint.y && contentPoint.y <= frame.maxY {
            verticalDistance = 0
          } else {
            verticalDistance = min(
              abs(contentPoint.y - frame.minY),
              abs(contentPoint.y - frame.maxY))
          }

          let horizontalDistance: CGFloat
          if frame.minX <= contentPoint.x && contentPoint.x <= frame.maxX {
            horizontalDistance = 0
          } else {
            horizontalDistance = min(
              abs(contentPoint.x - frame.minX),
              abs(contentPoint.x - frame.maxX))
          }

          if best == nil
            || verticalDistance < best!.verticalDistance
            || (verticalDistance == best!.verticalDistance
              && horizontalDistance < best!.horizontalDistance)
          {
            best = (anchorView, verticalDistance, horizontalDistance)
          }
        }
      }

      view.subviews.forEach(visit)
    }

    visit(scrollView)
    return best?.view
  }

  private func messageAnchorView(
    with messageID: UUID,
    in rootView: UIView
  ) -> MessageListAnchorUIView? {
    if let anchorView = rootView as? MessageListAnchorUIView,
      anchorView.messageID == messageID
    {
      return anchorView
    }

    for subview in rootView.subviews {
      if let anchorView = messageAnchorView(with: messageID, in: subview) {
        return anchorView
      }
    }
    return nil
  }

  private func clampedScrollOffsetY(_ y: CGFloat, in scrollView: UIScrollView) -> CGFloat {
    let minimumY = -scrollView.adjustedContentInset.top
    let maximumY = max(
      minimumY,
      scrollView.contentSize.height - scrollView.bounds.height
        + scrollView.adjustedContentInset.bottom
    )
    return min(max(y, minimumY), maximumY)
  }

  private var emptyState: some View {
    VStack(spacing: 14) {
      Image(systemName: "bubble.left.and.bubble.right")
        .font(.system(size: 44))
        .foregroundStyle(.secondary)
      Text("Ask anything")
        .font(.title2.weight(.semibold))
      Text("Text-only chat with local history, native tools, Markdown, and switchable providers.")
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
    }
    .padding(32)
    .frame(maxWidth: .infinity, minHeight: 360)
  }

  private var composer: some View {
    ChatComposer(
      store: store,
      placeholder: composerPlaceholder,
      conversationID: store.currentConversation?.id,
      isResponding: currentChatIsResponding,
      liveVoiceSession: liveVoiceSession
    )
  }
}

// Suppresses parent-driven re-invalidation; @State / @EnvironmentObject / @StateObject still re-trigger body.
extension ChatView: Equatable {
  nonisolated static func == (lhs: Self, rhs: Self) -> Bool { true }
}

private struct ChatComposer: View {
  @EnvironmentObject private var ttsPlayer: TTSPlayer
  @Environment(\.scenePhase) private var scenePhase
  let store: AppStore
  let placeholder: String
  let conversationID: UUID?
  let isResponding: Bool
  @ObservedObject var liveVoiceSession: LiveVoiceSession
  @FocusState private var composerFocused: Bool
  @State private var showingToolMenu = false
  @State private var showingToolPicker = false
  @State private var showingTextFileImporter = false
  @State private var showingImagePicker = false
  @State private var showingCameraPicker = false
  @State private var selectedPhotoItem: PhotosPickerItem?
  @State private var draftText = ""
  @State private var pendingAttachments: [ChatAttachment] = []
  @State private var pendingImageSizePrompt: PendingImageAttachmentImport?
  @State private var attachmentError: String?

  private var canSubmitDraft: Bool {
    !isResponding
      && (!draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !pendingAttachments.isEmpty)
  }

  private var canAttachImage: Bool {
    ProviderVisionSupport.supportsImageInput(
      conversation: store.currentConversation,
      settings: store.settings)
  }

  private var canTakePicture: Bool {
    canAttachImage && UIImagePickerController.isSourceTypeAvailable(.camera)
  }

  var body: some View {
    Group {
      if liveVoiceSession.isActive {
        voiceControls
      } else {
        textControls
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .simultaneousGesture(composerKeyboardDismissGesture)
    .onAppear {
      draftText = store.draftText(for: conversationID)
    }
    .onChange(of: conversationID) { oldID, newID in
      store.setDraftText(draftText, for: oldID)
      draftText = store.draftText(for: newID)
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .background else { return }
      guard liveVoiceSession.isActive else { return }
      guard !store.settings.conversation.allowsBackgroundVoiceListening else { return }
      Task { @MainActor in
        await stopVoiceAndKeepTranscript(cancelResponse: false, focusComposer: false)
      }
    }
    .fileImporter(
      isPresented: $showingTextFileImporter,
      allowedContentTypes: Self.textAttachmentTypes
    ) { result in
      importTextAttachment(result)
    }
    .photosPicker(
      isPresented: $showingImagePicker,
      selection: $selectedPhotoItem,
      matching: .images
    )
    .onChange(of: selectedPhotoItem) { _, item in
      guard let item else { return }
      Task { await importImageAttachment(item) }
    }
    .sheet(isPresented: $showingCameraPicker) {
      CameraImagePicker(isPresented: $showingCameraPicker) { image in
        importCameraImageAttachment(image)
      }
      .ignoresSafeArea()
    }
    .alert(
      "Attachment failed",
      isPresented: Binding(
        get: { attachmentError != nil },
        set: { if !$0 { attachmentError = nil } }),
      presenting: attachmentError
    ) { _ in
      Button("OK", role: .cancel) { attachmentError = nil }
    } message: { message in
      Text(message)
    }
    .confirmationDialog(
      "Image Size",
      isPresented: Binding(
        get: { pendingImageSizePrompt != nil },
        set: { if !$0 { pendingImageSizePrompt = nil } }),
      titleVisibility: .visible,
      presenting: pendingImageSizePrompt
    ) { pending in
      ForEach(AttachmentImageSize.concreteCases) { size in
        Button(imageSizePromptTitle(for: size)) {
          appendImageAttachment(pending, size: size)
        }
      }
      Button("Cancel", role: .cancel) {
        pendingImageSizePrompt = nil
      }
    } message: { pending in
      Text("Choose the image size for \(pending.filename).")
    }
  }

  private var textControls: some View {
    VStack(alignment: .leading, spacing: 6) {
      if !pendingAttachments.isEmpty {
        pendingAttachmentStrip
      }
      HStack(alignment: .bottom, spacing: 10) {
        toolMenu

        TextField(placeholder, text: draftBinding, axis: .vertical)
          .textFieldStyle(.plain)
          .lineLimit(1...3)
          .submitLabel(.send)
          .padding(.vertical, 5)
          .frame(minHeight: 32, alignment: .center)
          .focused($composerFocused)
          .onSubmit {
            submitDraft()
          }

        Button {
          if let id = conversationID, isResponding {
            store.cancelResponse(in: id)
          } else if canSubmitDraft {
            submitDraft()
          } else {
            liveVoiceSession.start(store: store, ttsPlayer: ttsPlayer)
          }
        } label: {
          Image(systemName: trailingActionSystemImage)
            .font(.title2)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(trailingActionColor)
            .frame(width: 24, height: 24)
            .contentShape(Circle())
        }
        .buttonStyle(.glass)
        .disabled(!isResponding && liveVoiceSession.isActive)
        .help(trailingActionHelp)
      }
    }
  }

  private var pendingAttachmentStrip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(pendingAttachments) { attachment in
          AttachmentPill(attachment: attachment) {
            pendingAttachments.removeAll { $0.id == attachment.id }
          }
        }
      }
      .padding(.horizontal, 34)
    }
  }

  private var trailingActionSystemImage: String {
    if isResponding {
      return "stop.circle"
    }
    if canSubmitDraft {
      return "arrow.up.circle.fill"
    }
    return "mic.circle"
  }

  private var trailingActionColor: Color {
    isResponding ? .red : .accentColor
  }

  private var trailingActionHelp: String {
    if isResponding {
      return "Stop response"
    }
    if canSubmitDraft {
      return "Send message"
    }
    return "Start voice conversation"
  }

  private var voiceControls: some View {
    HStack(spacing: 12) {
      Button {
        liveVoiceSession.togglePauseOrRecord(store: store, ttsPlayer: ttsPlayer)
      } label: {
        Image(systemName: liveVoiceSession.primaryControlSystemImage)
          .font(.title2)
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(Color.accentColor)
          .frame(width: 28, height: 28)
          .contentShape(Circle())
      }
      .buttonStyle(.glass)
      .disabled(liveVoiceSession.state == .requestingPermission)
      .help(liveVoiceSession.primaryControlHelp)

      VStack(alignment: .leading, spacing: 2) {
        Text(liveVoiceSession.state.statusText)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.primary)
        Text(liveVoiceSession.errorMessage ?? voiceStatusDetail)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Button {
        Task { @MainActor in
          await stopVoiceAndKeepTranscript()
        }
      } label: {
        Image(systemName: "xmark.circle.fill")
          .font(.title2)
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(Color.red)
          .frame(width: 28, height: 28)
          .contentShape(Circle())
      }
      .buttonStyle(.glass)
      .help("Stop conversation")
    }
  }

  @MainActor
  private func stopVoiceAndKeepTranscript(
    cancelResponse: Bool = true,
    focusComposer: Bool = true
  ) async {
    let text = await liveVoiceSession.stopForDraft(cancelResponse: cancelResponse)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    draftText = mergedDraftText(appending: text)
    store.setDraftText(draftText, for: conversationID)
    if focusComposer {
      composerFocused = true
    }
  }

  private func mergedDraftText(appending text: String) -> String {
    let current = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !current.isEmpty else { return text }
    return "\(current)\n\(text)"
  }

  private var voiceStatusDetail: String {
    let trimmed = liveVoiceSession.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      return trimmed
    }
    return
      "\(store.settings.conversation.speechRecognitionBackend.displayName) · \(liveVoiceSession.languageIdentifier)"
  }

  private var draftBinding: Binding<String> {
    Binding(
      get: { draftText },
      set: { newText in
        if newText == draftText + "\n" {
          submitDraft()
          return
        }
        draftText = newText
        store.setDraftText(newText, for: conversationID)
      }
    )
  }

  private func submitDraft() {
    guard canSubmitDraft else { return }
    let submitted = draftText
    let submittedAttachments = pendingAttachments
    let submittedConversationID = conversationID
    draftText = ""
    pendingAttachments = []
    store.setDraftText("", for: submittedConversationID)
    Task {
      let sent = await store.send(prompt: submitted, attachments: submittedAttachments)
      if !sent {
        draftText = submitted
        pendingAttachments = submittedAttachments
        store.setDraftText(submitted, for: submittedConversationID)
      }
    }
  }

  private var composerKeyboardDismissGesture: some Gesture {
    DragGesture(minimumDistance: 12, coordinateSpace: .local)
      .onEnded { value in
        guard value.translation.height > 24,
          value.translation.height > abs(value.translation.width)
        else {
          return
        }
        composerFocused = false
      }
  }

  private var toolMenu: some View {
    Button {
      showingToolMenu.toggle()
    } label: {
      Image(systemName: "plus")
        .font(.title3.weight(.semibold))
        .frame(width: 24, height: 24)
    }
    .buttonStyle(.glass)
    .popover(isPresented: $showingToolMenu, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
      toolMenuPopover
        .presentationCompactAdaptation(.popover)
    }
    .popover(isPresented: $showingToolPicker, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom)
    {
      ToolPickerPopover()
        .environmentObject(store)
        .presentationCompactAdaptation(.popover)
    }
    .help("Tools")
  }

  private var toolMenuPopover: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 12) {
        Button {
          openToolPicker()
        } label: {
          toolMenuRowLabel("Tools...", systemImage: "wrench.and.screwdriver")
        }
        .disabled(!toolsEnabled)
        .opacity(toolsEnabled ? 1 : 0.45)
        .buttonStyle(.plain)

        Toggle("", isOn: toolsEnabledBinding)
          .labelsHidden()
          .toggleStyle(.switch)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 9)

      Divider()

      Button {
        showingToolMenu = false
        showingTextFileImporter = true
      } label: {
        toolMenuRowLabel("Add text", systemImage: "doc.text")
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 12)
      .padding(.vertical, 9)

      Button {
        showingToolMenu = false
        showingImagePicker = true
      } label: {
        toolMenuRowLabel("Add image", systemImage: "photo")
      }
      .disabled(!canAttachImage)
      .opacity(canAttachImage ? 1 : 0.45)
      .buttonStyle(.plain)
      .padding(.horizontal, 12)
      .padding(.vertical, 9)

      Button {
        showingToolMenu = false
        showingCameraPicker = true
      } label: {
        toolMenuRowLabel("Take picture", systemImage: "camera")
      }
      .disabled(!canTakePicture)
      .opacity(canTakePicture ? 1 : 0.45)
      .buttonStyle(.plain)
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
    }
    .padding(8)
    .frame(minWidth: 240)
    .background(.regularMaterial)
  }

  private func toolMenuRowLabel(_ title: String, systemImage: String) -> some View {
    HStack(spacing: 10) {
      Image(systemName: systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 18)
      Text(title)
        .foregroundStyle(.primary)
      Spacer()
    }
    .contentShape(Rectangle())
  }

  private func openToolPicker() {
    guard toolsEnabled else { return }
    showingToolMenu = false
    showingToolPicker = true
  }

  private var toolsEnabled: Bool {
    store.currentConversation?.toolsEnabled ?? true
  }

  private var toolsEnabledBinding: Binding<Bool> {
    Binding(
      get: { toolsEnabled },
      set: { enabled in
        showingToolPicker = false
        store.updateCurrentConversation { conversation in
          conversation.toolsEnabled = enabled
        }
      }
    )
  }

  private static var textAttachmentTypes: [UTType] {
    var types: [UTType] = [.plainText, .text]
    if let markdown = UTType(filenameExtension: "md") {
      types.append(markdown)
    }
    return types
  }

  private func importTextAttachment(_ result: Result<URL, Error>) {
    do {
      let url = try result.get()
      let access = url.startAccessingSecurityScopedResource()
      defer {
        if access { url.stopAccessingSecurityScopedResource() }
      }
      let ext = url.pathExtension.lowercased()
      guard ext == "txt" || ext == "md" || ext == "markdown" else {
        attachmentError = "Choose a .txt or .md file."
        return
      }
      let data = try Data(contentsOf: url, options: [.mappedIfSafe])
      guard data.count <= 1_500_000 else {
        attachmentError = "Text attachments are limited to 1.5 MB."
        return
      }
      guard let text = String(data: data, encoding: .utf8) else {
        attachmentError = "The selected file is not UTF-8 text."
        return
      }
      pendingAttachments.append(
        .textFile(
          filename: url.lastPathComponent,
          text: text,
          mimeType: ext == "md" || ext == "markdown" ? "text/markdown" : "text/plain"))
      composerFocused = true
    } catch {
      attachmentError = error.localizedDescription
    }
  }

  @MainActor
  private func importImageAttachment(_ item: PhotosPickerItem) async {
    defer { selectedPhotoItem = nil }
    guard canAttachImage else {
      attachmentError = "The selected provider or model does not support image input."
      return
    }
    do {
      guard let data = try await item.loadTransferable(type: Data.self),
        let image = UIImage(data: data)
      else {
        attachmentError = "Could not read the selected image."
        return
      }
      let filename = "image-\(Int(Date().timeIntervalSince1970)).jpg"
      let imageSize = store.settings.attachmentImageSize
      guard imageSize != .prompt else {
        pendingImageSizePrompt = PendingImageAttachmentImport(filename: filename, image: image)
        return
      }
      appendImageAttachment(image, filename: filename, size: imageSize)
    } catch {
      attachmentError = error.localizedDescription
    }
  }

  @MainActor
  private func importCameraImageAttachment(_ image: UIImage) {
    guard canAttachImage else {
      attachmentError = "The selected provider or model does not support image input."
      return
    }
    let filename = "photo-\(Int(Date().timeIntervalSince1970)).jpg"
    let imageSize = store.settings.attachmentImageSize
    guard imageSize != .prompt else {
      pendingImageSizePrompt = PendingImageAttachmentImport(filename: filename, image: image)
      return
    }
    appendImageAttachment(image, filename: filename, size: imageSize)
  }

  private func appendImageAttachment(
    _ pending: PendingImageAttachmentImport,
    size: AttachmentImageSize
  ) {
    appendImageAttachment(pending.image, filename: pending.filename, size: size)
    pendingImageSizePrompt = nil
  }

  private func appendImageAttachment(_ image: UIImage, filename: String, size: AttachmentImageSize) {
    let resized = resizeImage(image, maxDimension: size.maxDimension)
    guard let output = resized.image.jpegData(compressionQuality: 0.82) else {
      attachmentError = "Could not encode the selected image."
      return
    }
    pendingAttachments.append(
      .image(
        filename: filename,
        data: output,
        width: Int(resized.size.width.rounded()),
        height: Int(resized.size.height.rounded())))
    composerFocused = true
  }

  private func imageSizePromptTitle(for size: AttachmentImageSize) -> String {
    guard let maxDimension = size.maxDimension else {
      return size.displayName
    }
    return "\(size.displayName) (\(maxDimension) px)"
  }

  private func resizeImage(_ image: UIImage, maxDimension: Int?) -> (image: UIImage, size: CGSize) {
    let pixelSize = CGSize(
      width: image.size.width * image.scale,
      height: image.size.height * image.scale)
    guard let maxDimension, max(pixelSize.width, pixelSize.height) > CGFloat(maxDimension) else {
      return (image, pixelSize)
    }
    let scale = CGFloat(maxDimension) / max(pixelSize.width, pixelSize.height)
    let target = CGSize(
      width: max(1, floor(pixelSize.width * scale)),
      height: max(1, floor(pixelSize.height * scale)))
    let renderer = UIGraphicsImageRenderer(size: target)
    let resized = renderer.image { _ in
      image.draw(in: CGRect(origin: .zero, size: target))
    }
    return (resized, target)
  }
}

private struct PendingImageAttachmentImport {
  let filename: String
  let image: UIImage
}

private struct CameraImagePicker: UIViewControllerRepresentable {
  @Binding var isPresented: Bool
  let onImagePicked: (UIImage) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(isPresented: $isPresented, onImagePicked: onImagePicked)
  }

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.mediaTypes = [UTType.image.identifier]
    picker.allowsEditing = false
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

  final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
    @Binding private var isPresented: Bool
    private let onImagePicked: (UIImage) -> Void

    init(isPresented: Binding<Bool>, onImagePicked: @escaping (UIImage) -> Void) {
      _isPresented = isPresented
      self.onImagePicked = onImagePicked
    }

    func imagePickerController(
      _ picker: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
      isPresented = false
      guard let image = info[.originalImage] as? UIImage else { return }
      onImagePicked(image)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      isPresented = false
    }
  }
}

private struct AttachmentPill: View {
  let attachment: ChatAttachment
  let onRemove: () -> Void

  var body: some View {
    if attachment.kind == .image {
      imageAttachmentPill
    } else {
      textAttachmentPill
    }
  }

  private var textAttachmentPill: some View {
    HStack(spacing: 6) {
      Image(systemName: "doc.text")
        .foregroundStyle(.secondary)
      Text(attachment.displayName)
        .font(.caption)
        .lineLimit(1)
      removeButton
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private var imageAttachmentPill: some View {
    HStack(spacing: 7) {
      imageThumbnail
      Text(dimensionsLabel)
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
      removeButton
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 5)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .accessibilityLabel("\(attachment.displayName), \(dimensionsLabel)")
  }

  @ViewBuilder
  private var imageThumbnail: some View {
    if let image = image {
      Image(uiImage: image)
        .resizable()
        .interpolation(.high)
        .aspectRatio(contentMode: .fill)
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    } else {
      Image(systemName: "photo")
        .foregroundStyle(.secondary)
        .frame(width: 40, height: 40)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
  }

  private var removeButton: some View {
    Button(action: onRemove) {
      Image(systemName: "xmark.circle.fill")
        .foregroundStyle(.secondary)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Remove attachment")
  }

  private var dimensionsLabel: String {
    if let width = attachment.width, let height = attachment.height {
      return "\(width)x\(height)"
    }
    if let image {
      let width = Int((image.size.width * image.scale).rounded())
      let height = Int((image.size.height * image.scale).rounded())
      return "\(width)x\(height)"
    }
    return "Image"
  }

  private var image: UIImage? {
    guard attachment.kind == .image,
      let dataBase64 = attachment.dataBase64,
      let data = Data(base64Encoded: dataBase64)
    else {
      return nil
    }
    return UIImage(data: data)
  }
}

private struct MessageListPinchAnchor {
  let messageID: UUID?
  let unitY: CGFloat
  let fallbackContentY: CGFloat
  let fallbackContentHeight: CGFloat
}

private final class MessageListAnchorUIView: UIView {
  var messageID: UUID

  init(messageID: UUID) {
    self.messageID = messageID
    super.init(frame: .zero)
    backgroundColor = .clear
    isUserInteractionEnabled = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

private struct MessageListAnchorMarker: UIViewRepresentable {
  let messageID: UUID

  func makeUIView(context: Context) -> MessageListAnchorUIView {
    MessageListAnchorUIView(messageID: messageID)
  }

  func updateUIView(_ view: MessageListAnchorUIView, context: Context) {
    view.messageID = messageID
  }
}

private struct MessageListPinchGestureBridge: UIViewRepresentable {
  var onChanged: (CGFloat, UIScrollView, CGPoint) -> Void
  var onEnded: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onChanged: onChanged, onEnded: onEnded)
  }

  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.backgroundColor = .clear
    view.isUserInteractionEnabled = false
    DispatchQueue.main.async {
      context.coordinator.installIfNeeded(from: view)
    }
    return view
  }

  func updateUIView(_ view: UIView, context: Context) {
    context.coordinator.onChanged = onChanged
    context.coordinator.onEnded = onEnded
    DispatchQueue.main.async {
      context.coordinator.installIfNeeded(from: view)
    }
  }

  static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
    coordinator.uninstall()
  }

  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var onChanged: (CGFloat, UIScrollView, CGPoint) -> Void
    var onEnded: () -> Void

    private weak var scrollView: UIScrollView?
    private weak var hostView: UIView?
    private var pinchGesture: UIPinchGestureRecognizer?
    private var originalShowsVerticalScrollIndicator: Bool?
    private var originalShowsHorizontalScrollIndicator: Bool?

    init(
      onChanged: @escaping (CGFloat, UIScrollView, CGPoint) -> Void,
      onEnded: @escaping () -> Void
    ) {
      self.onChanged = onChanged
      self.onEnded = onEnded
    }

    func installIfNeeded(from view: UIView) {
      hostView = view
      guard let target = findScrollView(from: view) else { return }
      guard target !== scrollView || pinchGesture == nil else { return }

      uninstall()

      let gesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
      gesture.cancelsTouchesInView = false
      gesture.delaysTouchesBegan = false
      gesture.delaysTouchesEnded = false
      gesture.delegate = self
      target.addGestureRecognizer(gesture)
      scrollView = target
      pinchGesture = gesture
    }

    func uninstall() {
      restoreScrollIndicators()
      if let pinchGesture, let scrollView {
        scrollView.removeGestureRecognizer(pinchGesture)
      }
      pinchGesture = nil
      scrollView = nil
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
      guard let scrollView else { return }
      switch recognizer.state {
      case .began:
        hideScrollIndicators(in: scrollView)
        onChanged(recognizer.scale, scrollView, recognizer.location(in: scrollView))
      case .changed:
        onChanged(recognizer.scale, scrollView, recognizer.location(in: scrollView))
      case .ended, .cancelled, .failed:
        restoreScrollIndicators()
        onEnded()
      default:
        break
      }
    }

    private func hideScrollIndicators(in scrollView: UIScrollView) {
      if originalShowsVerticalScrollIndicator == nil {
        originalShowsVerticalScrollIndicator = scrollView.showsVerticalScrollIndicator
      }
      if originalShowsHorizontalScrollIndicator == nil {
        originalShowsHorizontalScrollIndicator = scrollView.showsHorizontalScrollIndicator
      }
      scrollView.showsVerticalScrollIndicator = false
      scrollView.showsHorizontalScrollIndicator = false
    }

    private func restoreScrollIndicators() {
      guard let scrollView else { return }
      if let originalShowsVerticalScrollIndicator {
        scrollView.showsVerticalScrollIndicator = originalShowsVerticalScrollIndicator
      }
      if let originalShowsHorizontalScrollIndicator {
        scrollView.showsHorizontalScrollIndicator = originalShowsHorizontalScrollIndicator
      }
      originalShowsVerticalScrollIndicator = nil
      originalShowsHorizontalScrollIndicator = nil
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      guard let pinch = gestureRecognizer as? UIPinchGestureRecognizer else { return true }
      return pinch.numberOfTouches >= 2
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      true
    }

    private func findScrollView(from view: UIView) -> UIScrollView? {
      if let ancestor = ancestorScrollView(from: view) {
        return ancestor
      }
      guard let window = view.window else { return nil }
      let frame = view.convert(view.bounds, to: window)
      let center = CGPoint(x: frame.midX, y: frame.midY)
      return largestScrollView(containing: center, in: window)
    }

    private func ancestorScrollView(from view: UIView) -> UIScrollView? {
      var current = view.superview
      while let candidate = current {
        if let scrollView = candidate as? UIScrollView {
          return scrollView
        }
        current = candidate.superview
      }
      return nil
    }

    private func largestScrollView(containing point: CGPoint, in root: UIView) -> UIScrollView? {
      var best: (scrollView: UIScrollView, area: CGFloat)?

      func visit(_ view: UIView) {
        guard !view.isHidden, view.alpha > 0.01 else { return }
        if let scrollView = view as? UIScrollView {
          let frame = scrollView.convert(scrollView.bounds, to: root)
          if frame.contains(point) {
            let area = frame.width * frame.height
            if best == nil || area > best!.area {
              best = (scrollView, area)
            }
          }
        }
        view.subviews.forEach(visit)
      }

      visit(root)
      return best?.scrollView
    }
  }
}

private struct ExportedFile: Identifiable {
  let id = UUID()
  let url: URL
}

private struct AudioExportPresentations: ViewModifier {
  @ObservedObject var exporter: TTSExporter
  @Binding var showingAudioExport: Bool
  @Binding var audioExportError: String?

  func body(content: Content) -> some View {
    content
      .sheet(isPresented: $showingAudioExport) {
        AudioExportProgressView(exporter: exporter) {
          exporter.cancel()
        }
      }
      .alert(
        "Audio export failed",
        isPresented: Binding(
          get: { audioExportError != nil },
          set: { if !$0 { audioExportError = nil } }),
        presenting: audioExportError
      ) { _ in
        Button("OK", role: .cancel) { audioExportError = nil }
      } message: { message in
        Text(message)
      }
  }
}

private struct AudioExportProgressView: View {
  @ObservedObject var exporter: TTSExporter
  let onCancel: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "waveform")
        .font(.system(size: 32))
        .foregroundStyle(.secondary)
      ProgressView(value: exporter.progress)
        .progressViewStyle(.linear)
      Text(exporter.phase)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Button("Cancel", role: .cancel, action: onCancel)
    }
    .padding(24)
    .frame(maxWidth: .infinity)
    .presentationDetents([.height(220)])
    .interactiveDismissDisabled()
  }
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
  let activityItems: [Any]

  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
  }

  func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct CompactChatSheet: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var store: AppStore
  @State private var conversationID: UUID?
  @State private var prompt = ""
  @State private var summary = ""
  @State private var statusText: String?
  @State private var isLoadingPrompt = false
  @State private var showingPromptEditor = false
  @State private var showingReplaceConfirmation = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Button {
            showingPromptEditor.toggle()
          } label: {
            Label(
              showingPromptEditor ? "Hide Compact Prompt" : "Edit Compact Prompt",
              systemImage: showingPromptEditor ? "eye.slash" : "square.and.pencil")
          }
          .disabled(isLoadingPrompt || store.isCompacting || prompt.isEmpty)

          if showingPromptEditor {
            TextEditor(text: $prompt)
              .frame(minHeight: 220)
              .font(.callout.monospaced())
              .autocorrectionDisabled()
          }
        }

        Section {
          Button {
            Task { await generateSummary() }
          } label: {
            if store.isCompacting {
              HStack {
                ProgressView()
                Text("Compacting...")
              }
            } else {
              Label("Generate Compact Summary", systemImage: "rectangle.compress.vertical")
            }
          }
          .disabled(
            isLoadingPrompt || store.isCompacting
              || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

          TextEditor(text: $summary)
            .frame(minHeight: 260)
            .font(.callout)
            .autocorrectionDisabled()
            .overlay(alignment: .topLeading) {
              if summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Generated summary")
                  .foregroundStyle(.tertiary)
                  .padding(.top, 8)
                  .padding(.leading, 5)
                  .allowsHitTesting(false)
              }
            }

          if let statusText {
            Text(statusText)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } footer: {
          Text("Review and edit the compacted summary before replacing the conversation.")
        }

        Section {
          Button(role: .destructive) {
            showingReplaceConfirmation = true
          } label: {
            Label("Replace Conversation With Summary", systemImage: "arrow.triangle.2.circlepath")
          }
          .disabled(
            conversationID == nil
              || summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .navigationTitle("Compact Chat")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
          }
          .accessibilityLabel("Close")
        }
      }
      .task {
        await loadPrompt()
      }
      .alert("Replace conversation?", isPresented: $showingReplaceConfirmation) {
        Button("Cancel", role: .cancel) {}
        Button("Replace Conversation", role: .destructive) {
          replaceConversation()
        }
      } message: {
        Text(
          "All current messages in this conversation will be replaced by the compacted summary. This cannot be undone."
        )
      }
    }
  }

  private func loadPrompt() async {
    guard prompt.isEmpty, conversationID == nil else { return }
    isLoadingPrompt = true
    statusText = "Loading compact prompt..."
    defer { isLoadingPrompt = false }

    if let draft = await store.compactPromptForCurrentConversation() {
      conversationID = draft.conversationID
      prompt = draft.prompt
      statusText = nil
    } else {
      statusText = store.errorMessage ?? "Nothing to compact yet."
    }
  }

  private func generateSummary() async {
    guard let conversationID else { return }
    statusText = nil
    guard
      let generated = await store.generateCompactSummary(
        conversationID: conversationID,
        prompt: prompt
      )
    else {
      statusText = store.errorMessage ?? "Could not generate compact summary."
      return
    }
    summary = generated
    statusText = "Compact summary generated."
  }

  private func replaceConversation() {
    guard let conversationID else { return }
    store.replaceConversationWithCompactSummary(conversationID: conversationID, summary: summary)
    dismiss()
  }
}

private struct ToolPickerPopover: View {
  @EnvironmentObject private var store: AppStore
  @State private var expandedServerIDs: Set<UUID> = []

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(BuiltInToolID.allCases.filter { $0 != .memory }) { tool in
          Button {
            toggleBuiltInTool(tool)
          } label: {
            HStack(spacing: 10) {
              Image(
                systemName: isBuiltInToolEnabled(tool) ? "checkmark.circle.fill" : "circle"
              )
              .foregroundStyle(isBuiltInToolEnabled(tool) ? Color.accentColor : Color.secondary)
              Image(systemName: tool.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
              Text(tool.displayName)
                .foregroundStyle(.primary)
              Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(store.settings.airplaneModeEnabled && tool.isDisabledInAirplaneMode)
          .opacity(store.settings.airplaneModeEnabled && tool.isDisabledInAirplaneMode ? 0.5 : 1)
        }

        if !store.settings.mcpServers.isEmpty {
          Divider().padding(.vertical, 4)
          Text("MCP Servers")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)

          ForEach(store.settings.mcpServers) { server in
            mcpServerRow(server)
          }
        }
      }
      .padding(8)
      .disabled(!toolsEnabled)
      .opacity(toolsEnabled ? 1 : 0.5)
    }
    .frame(minWidth: 260, maxHeight: 480)
    .background(.regularMaterial)
  }

  private var toolsEnabled: Bool {
    store.currentConversation?.toolsEnabled ?? true
  }

  @ViewBuilder
  private func mcpServerRow(_ server: MCPServer) -> some View {
    let tools = store.mcpTools[server.id] ?? []
    let status = store.mcpStatuses[server.id] ?? .unknown
    let expanded = expandedServerIDs.contains(server.id)

    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Button {
          toggleServer(server.id)
        } label: {
          Image(systemName: isMCPServerEnabled(server.id) ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isMCPServerEnabled(server.id) ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)

        Image(systemName: serverStatusIcon(status))
          .imageScale(.small)
          .foregroundStyle(serverStatusColor(status))
          .frame(width: 16)

        Text(server.name.isEmpty ? "Untitled MCP" : server.name)
          .foregroundStyle(.primary)
          .lineLimit(1)

        Spacer()

        if !tools.isEmpty {
          Text("\(tools.count)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Button {
          if tools.isEmpty {
            Task { await store.refreshMCP(server) }
          } else {
            withAnimation(.snappy) {
              if expanded {
                expandedServerIDs.remove(server.id)
              } else {
                expandedServerIDs.insert(server.id)
              }
            }
          }
        } label: {
          if isCheckingServer(server.id) {
            ProgressView().controlSize(.small)
          } else if tools.isEmpty {
            Image(systemName: "arrow.clockwise")
              .imageScale(.small)
              .foregroundStyle(.secondary)
          } else {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
              .imageScale(.small)
              .foregroundStyle(.tertiary)
          }
        }
        .buttonStyle(.plain)
        .frame(width: 24, height: 24)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .contentShape(Rectangle())

      if expanded && !tools.isEmpty {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(tools) { tool in
            Button {
              toggleMCPTool(serverID: server.id, toolName: tool.name)
            } label: {
              HStack(spacing: 8) {
                Image(
                  systemName: isMCPToolEnabled(serverID: server.id, toolName: tool.name)
                    ? "checkmark.circle.fill" : "circle"
                )
                .imageScale(.small)
                .foregroundStyle(
                  isMCPToolEnabled(serverID: server.id, toolName: tool.name)
                    ? Color.accentColor : Color.secondary
                )
                Text(tool.name)
                  .font(.callout)
                  .foregroundStyle(.primary)
                  .lineLimit(1)
                Spacer()
              }
              .padding(.leading, 38)
              .padding(.trailing, 12)
              .padding(.vertical, 6)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
  }

  // MARK: - Native tool helpers

  private func isBuiltInToolEnabled(_ tool: BuiltInToolID) -> Bool {
    store.currentConversation?.enabledTools.contains(tool) ?? false
  }

  private func toggleBuiltInTool(_ tool: BuiltInToolID) {
    guard toolsEnabled else { return }
    guard !(store.settings.airplaneModeEnabled && tool.isDisabledInAirplaneMode) else {
      return
    }
    let nextValue = !isBuiltInToolEnabled(tool)
    store.updateCurrentConversation { conversation in
      if nextValue {
        conversation.enabledTools.insert(tool)
      } else {
        conversation.enabledTools.remove(tool)
      }
    }
    if nextValue {
      store.settings.defaultEnabledTools.insert(tool)
    } else {
      store.settings.defaultEnabledTools.remove(tool)
    }
    store.saveSettings()
  }

  // MARK: - MCP server helpers

  private func toggleServer(_ id: UUID) {
    guard toolsEnabled else { return }
    let nextValue = !isMCPServerEnabled(id)
    let keys = mcpToolKeys(serverID: id)
    let prefix = MCPToolSelection.prefix(serverID: id)
    store.updateCurrentConversation { conversation in
      if nextValue {
        conversation.enabledMCPServers.insert(id)
        conversation.enabledMCPTools.formUnion(keys)
      } else {
        conversation.enabledMCPServers.remove(id)
        conversation.enabledMCPTools = Set(
          conversation.enabledMCPTools.filter { !$0.hasPrefix(prefix) })
      }
    }
    if nextValue {
      store.settings.defaultEnabledMCPServers.insert(id)
      store.settings.defaultEnabledMCPTools.formUnion(keys)
    } else {
      store.settings.defaultEnabledMCPServers.remove(id)
      store.settings.defaultEnabledMCPTools = Set(
        store.settings.defaultEnabledMCPTools.filter { !$0.hasPrefix(prefix) })
    }
    store.saveSettings()
  }

  private func isMCPServerEnabled(_ id: UUID) -> Bool {
    store.currentConversation?.enabledMCPServers.contains(id)
      ?? store.settings.defaultEnabledMCPServers.contains(id)
  }

  private func isCheckingServer(_ id: UUID) -> Bool {
    if case .checking = store.mcpStatuses[id] {
      return true
    }
    return false
  }

  private func serverStatusIcon(_ status: EndpointConnectionState) -> String {
    switch status {
    case .unknown: return "circle"
    case .checking: return "arrow.triangle.2.circlepath"
    case .available: return "checkmark.circle.fill"
    case .failed: return "exclamationmark.circle.fill"
    }
  }

  private func serverStatusColor(_ status: EndpointConnectionState) -> Color {
    switch status {
    case .unknown: return .secondary
    case .checking: return .orange
    case .available: return .green
    case .failed: return .red
    }
  }

  private func mcpToolKey(serverID: UUID, toolName: String) -> String {
    MCPToolSelection.key(serverID: serverID, toolName: toolName)
  }

  private func mcpToolKeys(serverID: UUID) -> Set<String> {
    Set(
      (store.mcpTools[serverID] ?? []).map {
        mcpToolKey(serverID: serverID, toolName: $0.name)
      })
  }

  private func isMCPToolEnabled(serverID: UUID, toolName: String) -> Bool {
    let key = mcpToolKey(serverID: serverID, toolName: toolName)
    return store.currentConversation?.enabledMCPTools.contains(key)
      ?? store.settings.defaultEnabledMCPTools.contains(key)
  }

  private func toggleMCPTool(serverID: UUID, toolName: String) {
    guard toolsEnabled else { return }
    let key = mcpToolKey(serverID: serverID, toolName: toolName)
    let prefix = MCPToolSelection.prefix(serverID: serverID)
    let nextValue = !isMCPToolEnabled(serverID: serverID, toolName: toolName)
    store.updateCurrentConversation { conversation in
      if nextValue {
        conversation.enabledMCPServers.insert(serverID)
        conversation.enabledMCPTools.insert(key)
      } else {
        conversation.enabledMCPTools.remove(key)
        if !conversation.enabledMCPTools.contains(where: { $0.hasPrefix(prefix) }) {
          conversation.enabledMCPServers.remove(serverID)
        }
      }
    }
    if nextValue {
      store.settings.defaultEnabledMCPServers.insert(serverID)
      store.settings.defaultEnabledMCPTools.insert(key)
    } else {
      store.settings.defaultEnabledMCPTools.remove(key)
      if !store.settings.defaultEnabledMCPTools.contains(where: { $0.hasPrefix(prefix) }) {
        store.settings.defaultEnabledMCPServers.remove(serverID)
      }
    }
    store.saveSettings()
  }
}

private struct ConversationModelSettingsView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @State private var didSaveDefaults = false
  @State private var modelFilter = ""

  var body: some View {
    NavigationStack {
      Form {
        if store.currentConversation == nil {
          ContentUnavailableView("No Chat Selected", systemImage: "bubble.left")
        } else {
          Section("Provider") {
            Menu {
              if store.appleIntelligenceIsAvailable {
                Button {
                  providerSelectionBinding.wrappedValue = .apple
                } label: {
                  Label("Apple Intelligence", systemImage: "apple.logo")
                }
              }
              Button {
                providerSelectionBinding.wrappedValue = .mlx
              } label: {
                Label("MLX Local", systemImage: "cpu")
              }
              if !store.settings.airplaneModeEnabled {
                ForEach(store.settings.openAIEndpoints.filter(\.isEnabled)) { endpoint in
                  Button {
                    providerSelectionBinding.wrappedValue = .endpoint(endpoint.id)
                  } label: {
                    Label(endpoint.displayName, systemImage: "network")
                  }
                }
              }
            } label: {
              HStack {
                Text("Provider")
                Spacer()
                Label(providerMenuTitle, systemImage: providerMenuIcon)
                  .foregroundStyle(
                    selectedProviderIsBlockedByAirplaneMode ? .secondary : Color.accentColor)
              }
            }
            providerModelControls
          }

          Section {
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Label("Reasoning", systemImage: reasoningBinding.wrappedValue.systemImage)
                  .contentTransition(.symbolEffect(.replace))
                Spacer()
                Text(reasoningBinding.wrappedValue.displayName)
                  .foregroundStyle(.secondary)
                  .contentTransition(.numericText())
                  .animation(.snappy, value: reasoningBinding.wrappedValue)
              }
              Slider(
                value: reasoningSliderBinding,
                in: 0...Double(ReasoningLevel.allCases.count - 1),
                step: 1
              )
            }
          }

          Section {
            Toggle("Show thinking", isOn: showThinkingBinding)
            Toggle("Use memory", isOn: useMemoryBinding)
            Toggle("Stream responses", isOn: streamingBinding)
          }

          Section {
            Button {
              saveProviderModelAsDefault()
            } label: {
              Label(
                providerModelDefaultButtonTitle,
                systemImage: isCurrentProviderModelDefault ? "checkmark.circle" : "star"
              )
            }
            .disabled(!canSaveProviderModelAsDefault)
          } footer: {
            Text(providerModelDefaultFooterText)
          }
        }
      }
      .navigationTitle("Chat Settings")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  private var provider: ProviderKind {
    guard let provider = store.currentConversation?.provider else { return .mlx }
    if provider == .apple, !store.appleIntelligenceIsAvailable {
      return .mlx
    }
    return provider
  }

  private var selectedProviderIsBlockedByAirplaneMode: Bool {
    store.settings.airplaneModeEnabled && !provider.isAirplaneModeEligible
  }

  private var providerMenuTitle: String {
    if selectedProviderIsBlockedByAirplaneMode {
      return "Unavailable Offline"
    }
    switch provider {
    case .apple:
      return store.appleIntelligenceIsAvailable ? "Apple Intelligence" : "MLX Local"
    case .mlx:
      return "MLX Local"
    case .openAICompatible:
      return selectedEndpoint?.displayName ?? "OpenAI Compatible"
    }
  }

  private var providerMenuIcon: String {
    if selectedProviderIsBlockedByAirplaneMode { return "network.slash" }
    switch provider {
    case .apple:
      return store.appleIntelligenceIsAvailable ? "apple.logo" : "cpu"
    case .mlx:
      return "cpu"
    case .openAICompatible:
      return "network"
    }
  }

  @ViewBuilder
  private var providerModelControls: some View {
    if provider == .apple {
      EmptyView()
    } else if provider == .mlx {
      mlxModelControls
    } else if selectedProviderIsBlockedByAirplaneMode {
      Text(
        store.appleIntelligenceIsAvailable
          ? "Airplane Mode is on. Switch to Apple Intelligence or MLX Local."
          : "Airplane Mode is on. Switch to MLX Local."
      )
        .foregroundStyle(.secondary)
    } else if let endpoint = selectedEndpoint {
      let models = store.endpointModels[endpoint.id] ?? []
      if models.isEmpty {
        TextField("Model", text: modelBinding(default: endpoint.defaultModel))
          .textInputAutocapitalization(.never)
      } else {
        FilteredModelPicker(
          selection: modelBinding(default: endpoint.defaultModel),
          filter: $modelFilter,
          models: models
        )
      }

      HStack {
        endpointStatusLabel(store.endpointStatuses[endpoint.id] ?? .unknown)
        Spacer()
        Button {
          Task { await store.refreshEndpoint(endpoint) }
        } label: {
          Label("Refresh Models", systemImage: "arrow.clockwise")
        }
        .disabled(isChecking(endpoint))
      }
    } else {
      Text("Add and enable an endpoint in Settings.")
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var mlxModelControls: some View {
    let modelIDs = store.localMLXModelIDs
    Group {
      if modelIDs.isEmpty {
        Text("No downloaded MLX models")
          .foregroundStyle(.secondary)
      } else {
        Picker("Model", selection: mlxModelBinding) {
          ForEach(modelIDs, id: \.self) { modelID in
            Text(modelID).tag(modelID)
          }
        }
        .pickerStyle(.menu)
      }

      Button {
        store.refreshLocalMLXModels()
        ensureCurrentMLXModelSelectionIsAvailable()
      } label: {
        Label("Refresh Models", systemImage: "arrow.clockwise")
      }

      Text(
        "Only downloaded MLX models are shown. Manage downloads in Settings > Providers "
          + "> Local MLX LLM."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .onAppear {
      store.refreshLocalMLXModels()
      ensureCurrentMLXModelSelectionIsAvailable()
    }
    .onChange(of: store.localMLXModelIDs) { _, _ in
      ensureCurrentMLXModelSelectionIsAvailable()
    }
  }

  private var selectedEndpoint: OpenAIEndpoint? {
    guard let conversation = store.currentConversation else { return nil }
    return OpenAICompatibleProvider.selectedEndpoint(for: conversation, settings: store.settings)
  }

  private var canSaveProviderModelAsDefault: Bool {
    guard let conversation = store.currentConversation else { return false }
    if isCurrentProviderModelDefault { return false }
    switch conversation.provider {
    case .apple:
      return store.appleIntelligenceIsAvailable
    case .mlx:
      return !store.localMLXModelIDs.isEmpty
    case .openAICompatible:
      guard !store.settings.airplaneModeEnabled else { return false }
      return selectedEndpoint != nil
    }
  }

  private var isCurrentProviderModelDefault: Bool {
    guard let conversation = store.currentConversation else { return false }
    let defaults = store.effectiveDefaultProviderConfiguration
    switch conversation.provider {
    case .apple:
      return defaults.provider == .apple
        && normalizedModel(conversation.modelID) == normalizedModel(defaults.modelID)
    case .mlx:
      let model =
        store.availableLocalMLXModelID(preferred: effectiveMLXModel(conversation))
        ?? effectiveMLXModel(conversation)
      return defaults.provider == .mlx
        && normalizedModel(model) == normalizedModel(defaults.modelID)
    case .openAICompatible:
      guard let endpoint = selectedEndpoint else { return false }
      let model = effectiveConversationModel(conversation, endpoint: endpoint)
      return defaults.provider == .openAICompatible
        && defaults.endpointID == endpoint.id
        && normalizedModel(model) == normalizedModel(defaults.modelID)
    }
  }

  private var providerModelDefaultButtonTitle: String {
    isCurrentProviderModelDefault ? "Using app defaults" : "Use as default"
  }

  private var providerModelDefaultFooterText: String {
    if isCurrentProviderModelDefault {
      return "These provider and model settings already match the app defaults."
    }
    guard let conversation = store.currentConversation else { return "" }
    if conversation.provider == .openAICompatible && store.settings.airplaneModeEnabled {
      return "Airplane Mode is on. OpenAI-compatible providers cannot be used as defaults."
    }
    if conversation.provider == .openAICompatible && selectedEndpoint == nil {
      return "Choose an enabled endpoint before using these settings as the default."
    }
    if conversation.provider == .mlx && store.localMLXModelIDs.isEmpty {
      return "Download an MLX model before using MLX as the default."
    }
    if didSaveDefaults {
      return "Future chats will use this provider and model."
    }
    return "Make these provider and model settings the default for new chats."
  }

  private func saveProviderModelAsDefault() {
    guard let conversation = store.currentConversation else { return }
    switch conversation.provider {
    case .apple:
      guard store.appleIntelligenceIsAvailable else {
        return
      }
      store.settings.defaultProvider = .apple
      store.settings.appleModelID = conversation.modelID
    case .mlx:
      let model =
        store.availableLocalMLXModelID(preferred: effectiveMLXModel(conversation))
        ?? effectiveMLXModel(conversation)
      store.settings.defaultProvider = .mlx
      if !model.isEmpty {
        store.settings.localMLXModelID = model
      }
    case .openAICompatible:
      guard !store.settings.airplaneModeEnabled else { return }
      guard let endpoint = selectedEndpoint,
        let index = store.settings.openAIEndpoints.firstIndex(where: { $0.id == endpoint.id })
      else { return }
      let model = effectiveConversationModel(conversation, endpoint: endpoint)
      store.settings.defaultProvider = .openAICompatible
      store.settings.selectedEndpointID = endpoint.id
      if !model.isEmpty {
        store.settings.openAIEndpoints[index].defaultModel = model
      }
    }
    store.saveSettings()
    didSaveDefaults = true
  }

  private func effectiveConversationModel(
    _ conversation: Conversation, endpoint: OpenAIEndpoint
  ) -> String {
    let model = normalizedModel(conversation.modelID)
    return model.isEmpty ? normalizedModel(endpoint.defaultModel) : model
  }

  private func effectiveMLXModel(_ conversation: Conversation) -> String {
    let model = normalizedModel(conversation.modelID)
    return model.isEmpty ? normalizedModel(store.settings.localMLXModelID) : model
  }

  private func normalizedModel(_ model: String) -> String {
    model.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var providerSelectionBinding: Binding<DefaultProviderSelection> {
    Binding(
      get: {
        guard let conversation = store.currentConversation else { return .mlx }
        switch conversation.provider {
        case .apple:
          return store.appleIntelligenceIsAvailable ? .apple : .mlx
        case .mlx:
          return .mlx
        case .openAICompatible:
          if let id = conversation.endpointID,
            store.settings.openAIEndpoints.contains(where: { $0.id == id })
          {
            return .endpoint(id)
          }
          if let first = store.settings.openAIEndpoints.first(where: \.isEnabled) {
            return .endpoint(first.id)
          }
          return .mlx
        }
      },
      set: { newSelection in
        let needsMLXModel: Bool = {
          switch newSelection {
          case .apple:
            return !store.appleIntelligenceIsAvailable
          case .mlx:
            return true
          case .endpoint:
            return false
          }
        }()
        let selectedMLXModelID: String? = {
          guard needsMLXModel else { return nil }
          store.refreshLocalMLXModels()
          return store.availableLocalMLXModelID(preferred: store.settings.localMLXModelID)
        }()
        store.updateCurrentConversation { conversation in
          switch newSelection {
          case .apple:
            guard store.appleIntelligenceIsAvailable else {
              conversation.provider = .mlx
              conversation.endpointID = nil
              conversation.modelID = selectedMLXModelID ?? ""
              didSaveDefaults = false
              return
            }
            conversation.provider = .apple
            conversation.endpointID = nil
            conversation.modelID = store.settings.appleModelID
            didSaveDefaults = false
          case .mlx:
            conversation.provider = .mlx
            conversation.endpointID = nil
            conversation.modelID = selectedMLXModelID ?? ""
            didSaveDefaults = false
          case .endpoint(let id):
            guard !store.settings.airplaneModeEnabled else {
              didSaveDefaults = false
              return
            }
            conversation.provider = .openAICompatible
            conversation.endpointID = id
            if let endpoint = store.settings.openAIEndpoints.first(where: { $0.id == id }),
              !endpoint.defaultModel.isEmpty
            {
              conversation.modelID = endpoint.defaultModel
            }
            didSaveDefaults = false
          }
        }
      }
    )
  }

  private var mlxModelBinding: Binding<String> {
    Binding(
      get: {
        let model = normalizedModel(store.currentConversation?.modelID ?? "")
        return store.availableLocalMLXModelID(preferred: model) ?? ""
      },
      set: { model in
        guard store.localMLXModelIDs.contains(model) else { return }
        store.updateCurrentConversation { conversation in
          conversation.modelID = model
        }
        didSaveDefaults = false
      }
    )
  }

  private func ensureCurrentMLXModelSelectionIsAvailable() {
    guard provider == .mlx else {
      return
    }
    let currentModel = normalizedModel(store.currentConversation?.modelID ?? "")
    guard
      let model = store.availableLocalMLXModelID(preferred: store.currentConversation?.modelID)
    else {
      guard !currentModel.isEmpty else { return }
      store.updateCurrentConversation { conversation in
        conversation.modelID = ""
      }
      return
    }
    guard currentModel != model else { return }
    store.updateCurrentConversation { conversation in
      conversation.modelID = model
    }
  }

  private func modelBinding(default defaultModel: String) -> Binding<String> {
    Binding(
      get: {
        let model = store.currentConversation?.modelID ?? ""
        return model.isEmpty ? defaultModel : model
      },
      set: { model in
        store.updateCurrentConversation { conversation in
          conversation.modelID = model
        }
        didSaveDefaults = false
      }
    )
  }

  private var streamingBinding: Binding<Bool> {
    Binding(
      get: { store.currentConversation?.usesStreaming ?? true },
      set: { usesStreaming in
        store.updateCurrentConversation { conversation in
          conversation.usesStreaming = usesStreaming
        }
      }
    )
  }

  private var showThinkingBinding: Binding<Bool> {
    Binding(
      get: { store.currentConversation?.showThinking ?? false },
      set: { showThinking in
        store.updateCurrentConversation { conversation in
          conversation.showThinking = showThinking
        }
      }
    )
  }

  private var useMemoryBinding: Binding<Bool> {
    Binding(
      get: { store.currentConversation?.enabledTools.contains(.memory) ?? false },
      set: { useMemory in
        store.updateCurrentConversation { conversation in
          if useMemory {
            conversation.enabledTools.insert(.memory)
          } else {
            conversation.enabledTools.remove(.memory)
          }
        }
      }
    )
  }

  private var reasoningBinding: Binding<ReasoningLevel> {
    Binding(
      get: { store.currentConversation?.reasoningLevel ?? .automatic },
      set: { level in
        store.updateCurrentConversation { conversation in
          conversation.reasoningLevel = level
        }
      }
    )
  }

  private var reasoningSliderBinding: Binding<Double> {
    Binding(
      get: {
        Double(ReasoningLevel.allCases.firstIndex(of: reasoningBinding.wrappedValue) ?? 0)
      },
      set: { value in
        let cases = ReasoningLevel.allCases
        let index = max(0, min(cases.count - 1, Int(value.rounded())))
        reasoningBinding.wrappedValue = cases[index]
      }
    )
  }

  private func endpointStatusLabel(_ status: EndpointConnectionState) -> some View {
    let icon = status == .checking ? "arrow.triangle.2.circlepath" : "circle.fill"
    return Label(status.statusText, systemImage: icon)
      .foregroundStyle(status.statusColor)
  }

  private func isChecking(_ endpoint: OpenAIEndpoint) -> Bool {
    if case .checking = store.endpointStatuses[endpoint.id] {
      return true
    }
    return false
  }
}
