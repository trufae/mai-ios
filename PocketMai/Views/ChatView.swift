import SwiftUI
import UIKit

struct ChatView: View {
  @EnvironmentObject private var store: AppStore
  @EnvironmentObject private var ttsPlayer: TTSPlayer
  @State private var showingRenameAlert = false
  @State private var showingProviderModelSheet = false
  @State private var showingCompactConfirmation = false
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
  @StateObject private var audioExporter = TTSExporter()
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
    .background(
      LinearGradient(
        colors: [Color(uiColor: .systemBackground), Color.accentColor.opacity(0.05)],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()
    )
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
      "Resend from here?",
      isPresented: trimAndResubmitConfirmationBinding,
      presenting: messagePendingTrimAndResubmit
    ) { message in
      Button("Cancel", role: .cancel) {
        messagePendingTrimAndResubmit = nil
      }
      Button("Resend From Here", role: .destructive) {
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
      Divider()
      Button {
        showingCompactConfirmation = true
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
        if let systemPromptName {
          Text(systemPromptName)
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
    .confirmationDialog(
      "Compact this chat?",
      isPresented: $showingCompactConfirmation,
      titleVisibility: .visible
    ) {
      Button("Compact Chat", role: .destructive) {
        Task { await store.compactConversation() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "All messages will be replaced with a single AI-generated summary. This cannot be undone."
      )
    }
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
    "Message"
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
      return "Apple Intelligence"
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
    return store.exportCurrentConversationFile(format: format)
  }

  @MainActor
  private func exportAudioFile() async -> URL? {
    guard let conversation = store.currentConversation else { return nil }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PocketMaiExports",
      isDirectory: true
    )
    let url =
      directory
      .appendingPathComponent(store.exportFilename(for: conversation))
      .appendingPathExtension(ConversationExportFormat.audio.fileExtension)
    showingAudioExport = true
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try await audioExporter.export(
        messages: conversation.messages,
        voices: store.settings.toolSettings.voices,
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
      voices: store.settings.toolSettings.voices,
      openAIEndpoints: store.settings.openAIEndpoints
    )
  }

  private var providerStatus: (message: String, systemImage: String, color: Color)? {
    guard store.currentConversation?.provider == .apple,
      let message = store.appleAvailabilityMessage
    else {
      return nil
    }
    return (message, "exclamationmark.triangle", .orange)
  }

  private var messages: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(spacing: 14) {
          if currentConversationIsEmpty {
            emptyState
              .containerRelativeFrame(.vertical, alignment: .center)
          } else {
            ForEach(store.currentConversation?.messages ?? []) { message in
              MessageBubble(
                message: message,
                toolSettings: store.settings.toolSettings,
                openAIEndpoints: store.settings.openAIEndpoints,
                appearance: store.settings.appearance,
                renderMarkdown: store.settings.renderMarkdownInChat,
                onDelete: { messagePendingDeletion = message },
                onResubmit: message.role == .user
                  ? { Task { await store.resubmit(message) } }
                  : nil,
                onTrimFromHere: { messagePendingTrimAndResubmit = message },
                onRestartFresh: { messagePendingRestartFresh = message },
                onNewChatWithMessage: { Task { await store.startNewConversation(with: message) } },
                onSpeakFromHere: { speakFromHere(message) },
                showThinking: store.currentConversation?.showThinking ?? false,
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

    let anchor = makePinchAnchor(in: scrollView, at: contentPoint)
    let viewportY = contentPoint.y - scrollView.contentOffset.y

    store.settings.appearance.fontSize = clampedSize
    store.saveSettings()

    preservePinchPosition(
      in: scrollView,
      anchor: anchor,
      viewportY: viewportY)
  }

  private func endMessageFontSizePinch() {
    fontSizePinchBase = nil
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
    var best: (view: MessageListAnchorUIView, verticalDistance: CGFloat, horizontalDistance: CGFloat)?

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
      scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
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
      isResponding: currentChatIsResponding
    )
    .equatable()
  }
}

private struct ChatComposer: View, Equatable {
  let store: AppStore
  let placeholder: String
  let conversationID: UUID?
  let isResponding: Bool
  @FocusState private var composerFocused: Bool
  @State private var showingToolPicker = false
  @State private var draftText = ""

  nonisolated static func == (lhs: ChatComposer, rhs: ChatComposer) -> Bool {
    lhs.placeholder == rhs.placeholder
      && lhs.conversationID == rhs.conversationID
      && lhs.isResponding == rhs.isResponding
  }

  private var canSubmitDraft: Bool {
    !isResponding && !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var sendButtonColor: Color {
    if isResponding { return .red }
    return canSubmitDraft ? .accentColor : .secondary
  }

  var body: some View {
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
        } else {
          submitDraft()
        }
      } label: {
        Image(systemName: isResponding ? "stop.circle" : "arrow.up.circle")
          .font(.title2)
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(sendButtonColor)
          .frame(width: 24, height: 24)
          .contentShape(Circle())
      }
      .buttonStyle(.glass)
      .disabled(!isResponding && !canSubmitDraft)
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
    let submittedConversationID = conversationID
    draftText = ""
    store.setDraftText("", for: submittedConversationID)
    Task {
      let sent = await store.send(prompt: submitted)
      if !sent {
        draftText = submitted
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
      showingToolPicker.toggle()
    } label: {
      Image(systemName: "plus")
        .font(.title3.weight(.semibold))
        .frame(width: 24, height: 24)
    }
    .buttonStyle(.glass)
    .popover(isPresented: $showingToolPicker, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom)
    {
      ToolPickerPopover()
        .environmentObject(store)
        .presentationCompactAdaptation(.popover)
    }
    .help("Tools")
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

private struct ToolPickerPopover: View {
  @EnvironmentObject private var store: AppStore
  @State private var expandedServerIDs: Set<UUID> = []

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(NativeToolID.allCases.filter { $0 != .memory }) { tool in
          Button {
            toggleNativeTool(tool)
          } label: {
            HStack(spacing: 10) {
              Image(
                systemName: isNativeEnabled(tool) ? "checkmark.circle.fill" : "circle"
              )
              .foregroundStyle(isNativeEnabled(tool) ? Color.accentColor : Color.secondary)
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
    }
    .frame(minWidth: 260, maxHeight: 480)
    .background(.regularMaterial)
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
          Image(systemName: server.isEnabled ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(server.isEnabled ? Color.accentColor : Color.secondary)
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

  private func isNativeEnabled(_ tool: NativeToolID) -> Bool {
    store.currentConversation?.enabledTools.contains(tool) ?? false
  }

  private func toggleNativeTool(_ tool: NativeToolID) {
    store.updateCurrentConversation { conversation in
      if conversation.enabledTools.contains(tool) {
        conversation.enabledTools.remove(tool)
      } else {
        conversation.enabledTools.insert(tool)
      }
    }
  }

  // MARK: - MCP server helpers

  private func toggleServer(_ id: UUID) {
    guard let index = store.settings.mcpServers.firstIndex(where: { $0.id == id }) else { return }
    store.settings.mcpServers[index].isEnabled.toggle()
    store.saveSettings()
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
    "\(serverID.uuidString):\(toolName)"
  }

  private func isMCPToolEnabled(serverID: UUID, toolName: String) -> Bool {
    let key = mcpToolKey(serverID: serverID, toolName: toolName)
    return !(store.currentConversation?.disabledMCPTools.contains(key) ?? false)
  }

  private func toggleMCPTool(serverID: UUID, toolName: String) {
    let key = mcpToolKey(serverID: serverID, toolName: toolName)
    store.updateCurrentConversation { conversation in
      if conversation.disabledMCPTools.contains(key) {
        conversation.disabledMCPTools.remove(key)
      } else {
        conversation.disabledMCPTools.insert(key)
      }
    }
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
            Picker("Provider", selection: providerSelectionBinding) {
              Label("Apple Intelligence", systemImage: "apple.logo")
                .tag(DefaultProviderSelection.apple)
              Label("MLX Local", systemImage: "cpu")
                .tag(DefaultProviderSelection.mlx)
              ForEach(store.settings.openAIEndpoints.filter(\.isEnabled)) { endpoint in
                Label(endpoint.displayName, systemImage: "network")
                  .tag(DefaultProviderSelection.endpoint(endpoint.id))
              }
            }
            .pickerStyle(.menu)
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
    store.currentConversation?.provider ?? .apple
  }

  @ViewBuilder
  private var providerModelControls: some View {
    if provider == .apple {
      EmptyView()
    } else if provider == .mlx {
      mlxModelControls
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
    Picker("Preset", selection: mlxPresetBinding) {
      ForEach(LocalMLXModels.presets, id: \.self) { modelID in
        Text(modelID).tag(modelID)
      }
    }
    .pickerStyle(.menu)

    TextField(
      "Hugging Face MLX repo id", text: modelBinding(default: AppSettings.localMLXDefaultModelID)
    )
    .textInputAutocapitalization(.never)
    .autocorrectionDisabled()
    .font(.callout.monospaced())

    Text(
      "MLX downloads the selected Hugging Face repo on demand and caches it locally. Use MLX-ready repos only."
    )
    .font(.caption)
    .foregroundStyle(.secondary)
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
      return true
    case .mlx:
      return true
    case .openAICompatible:
      return selectedEndpoint != nil
    }
  }

  private var isCurrentProviderModelDefault: Bool {
    guard let conversation = store.currentConversation else { return false }
    let defaults = store.settings.defaultProviderConfiguration
    switch conversation.provider {
    case .apple:
      return defaults.provider == .apple
        && normalizedModel(conversation.modelID) == normalizedModel(defaults.modelID)
    case .mlx:
      let model = effectiveMLXModel(conversation)
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
    if conversation.provider == .openAICompatible && selectedEndpoint == nil {
      return "Choose an enabled endpoint before using these settings as the default."
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
      store.settings.defaultProvider = .apple
      store.settings.appleModelID = conversation.modelID
    case .mlx:
      let model = effectiveMLXModel(conversation)
      store.settings.defaultProvider = .mlx
      if !model.isEmpty {
        store.settings.localMLXModelID = model
      }
    case .openAICompatible:
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
        guard let conversation = store.currentConversation else { return .apple }
        switch conversation.provider {
        case .apple:
          return .apple
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
          return .apple
        }
      },
      set: { newSelection in
        store.updateCurrentConversation { conversation in
          switch newSelection {
          case .apple:
            conversation.provider = .apple
            conversation.endpointID = nil
            conversation.modelID = store.settings.appleModelID
            didSaveDefaults = false
          case .mlx:
            conversation.provider = .mlx
            conversation.endpointID = nil
            conversation.modelID = store.settings.localMLXModelID
            didSaveDefaults = false
          case .endpoint(let id):
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

  private var mlxPresetBinding: Binding<String> {
    Binding(
      get: {
        let model = normalizedModel(store.currentConversation?.modelID ?? "")
        guard LocalMLXModels.presets.contains(model) else {
          return LocalMLXModels.presets.first ?? AppSettings.localMLXDefaultModelID
        }
        return model
      },
      set: { model in
        store.updateCurrentConversation { conversation in
          conversation.modelID = model
        }
        didSaveDefaults = false
      }
    )
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
