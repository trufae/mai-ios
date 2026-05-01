import SwiftUI
import UIKit

struct ChatView: View {
  @EnvironmentObject private var store: AppStore
  @State private var showingRenameAlert = false
  @State private var showingProviderModelSheet = false
  @State private var showingCompactConfirmation = false
  @State private var showingClearConfirmation = false
  @State private var messagePendingDeletion: ChatMessage?
  @State private var messagePendingTrimAndResubmit: ChatMessage?
  @State private var messagePendingRestartFresh: ChatMessage?
  @State private var exportedEPUB: ExportedEPUB?
  @State private var renameDraft = ""
  @State private var lastStreamingScrollAt = Date.distantPast
  @State private var userScrolledAfterLastMessage = false
  private let messageListBottomID = "MessageListBottom"
  let onShowHistory: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      if let providerStatus {
        providerStatusBanner(providerStatus)
      }
      messages
      composer
    }
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
        Menu {
          Button {
            store.newConversation()
          } label: {
            Label {
              Text("New Chat")
            } icon: {
              Text("💬")
            }
          }
          Button {
            store.newConversation(incognito: true)
          } label: {
            Label {
              Text("New Incognito Chat")
            } icon: {
              Text("👻")
            }
          }
          Divider()
          Section("Export") {
            ForEach(ConversationExportFormat.allCases) { format in
              Button {
                store.copyConversation(format: format)
              } label: {
                Label("Copy as \(format.displayName)", systemImage: format.systemImage)
              }
            }
            Button {
              exportEPUB()
            } label: {
              Label("Export in ePUB", systemImage: "book")
            }
          }
        } label: {
          Image(systemName: "square.and.pencil")
        }
        .buttonStyle(.glass)
      }
    }
    .alert("Rename Chat", isPresented: $showingRenameAlert) {
      TextField("Chat title", text: $renameDraft)
      Button("Cancel", role: .cancel) {}
      Button("Save") {
        renameCurrentConversation()
      }
    }
    .sheet(isPresented: $showingProviderModelSheet) {
      ConversationModelSettingsView()
        .environmentObject(store)
    }
    .sheet(item: $exportedEPUB) { file in
      ActivityShareSheet(activityItems: [file.url])
    }
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
        Label("Rename Chat", systemImage: "pencil")
      }
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
              Label(prompt.name.isEmpty ? "Untitled" : prompt.name, systemImage: "checkmark")
            } else {
              Text(prompt.name.isEmpty ? "Untitled" : prompt.name)
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
      Button(role: .destructive) {
        showingClearConfirmation = true
      } label: {
        Label("Clear Chat", systemImage: "eraser")
      }
      .disabled(!canClearCurrentChat)
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
    .confirmationDialog(
      "Clear this chat?",
      isPresented: $showingClearConfirmation,
      titleVisibility: .visible
    ) {
      Button("Clear Chat", role: .destructive) {
        store.clearCurrentConversation()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "All messages will be removed. The chat itself will remain in the sidebar. This cannot be undone."
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
    let name = prompt.name.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? "Untitled" : name
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

  private var canClearCurrentChat: Bool {
    guard let conversation = store.currentConversation else { return false }
    if store.isResponding || store.isCompacting { return false }
    return !conversation.messages.isEmpty
  }

  private var composerPlaceholder: String {
    (store.currentConversation?.isIncognito ?? false) ? "Incognito message" : "Message"
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
    case .openAICompatible:
      let endpoint = conversation.endpointID.flatMap { id in
        store.settings.openAIEndpoints.first(where: { $0.id == id })
      }
      return AgentTooling.firstNonEmpty(endpoint?.name, URL(string: endpoint?.baseURL ?? "")?.host)
        ?? "Endpoint"
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
  }

  private func exportEPUB() {
    guard let url = store.exportCurrentConversationEPUB() else { return }
    exportedEPUB = ExportedEPUB(url: url)
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
        LazyVStack(spacing: 14) {
          if currentConversationIsEmpty {
            emptyState
              .containerRelativeFrame(.vertical, alignment: .center)
          } else {
            ForEach(store.currentConversation?.messages ?? []) { message in
              MessageBubble(
                message: message,
                toolSettings: store.settings.toolSettings,
                appearance: store.settings.appearance,
                onDelete: { messagePendingDeletion = message },
                onResubmit: message.role == .user
                  ? { Task { await store.resubmit(message) } }
                  : nil,
                onTrimFromHere: { messagePendingTrimAndResubmit = message },
                onRestartFresh: { messagePendingRestartFresh = message },
                showThinking: store.currentConversation?.showThinking ?? false,
                onStreamingTextChange: { _ in
                  guard !userScrolledAfterLastMessage else { return }
                  let now = Date()
                  guard now.timeIntervalSince(lastStreamingScrollAt) >= 0.35 else { return }
                  lastStreamingScrollAt = now
                  scrollToBottom(proxy, animated: false)
                }
              )
              .id(message.id)
            }
          }
          Color.clear
            .frame(height: 1)
            .id(messageListBottomID)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .center)
        .scrollTargetLayout()
      }
      .id(store.selectedConversationID)
      .defaultScrollAnchor(.bottom)
      .scrollDismissesKeyboard(.interactively)
      .overlay(alignment: .top) { EdgeFadeBlur(edge: .top, height: 24) }
      .simultaneousGesture(messageListScrollGesture)
      .onChange(of: lastMessageSnapshot) { old, new in
        guard old.conversationID == new.conversationID else {
          userScrolledAfterLastMessage = false
          return
        }
        if old.messageID != new.messageID {
          userScrolledAfterLastMessage = false
          scrollToBottom(proxy, animated: true)
          return
        }
        guard old.text != new.text else { return }
        guard !userScrolledAfterLastMessage else { return }
        let now = Date()
        guard now.timeIntervalSince(lastStreamingScrollAt) >= 0.35 else { return }
        lastStreamingScrollAt = now
        // Defer one runloop so the post-stream markdown layout is measured
        // before we anchor to the bottom; otherwise we land on the old
        // (plain-Text) bubble height and the new layout overshoots the
        // viewport, leaving a blank gap until the user nudges the scroll.
        DispatchQueue.main.async {
          scrollToBottom(proxy, animated: false)
        }
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
      appearance: store.settings.appearance
    )
    .equatable()
  }
}

private struct ChatComposer: View, Equatable {
  let store: AppStore
  let placeholder: String
  let conversationID: UUID?
  let isResponding: Bool
  let appearance: AppearanceSettings
  @FocusState private var composerFocused: Bool
  @State private var showingToolPicker = false
  @State private var draftText = ""
  @State private var composerHeight: CGFloat = ComposerTextView.singleLineHeight

  nonisolated static func == (lhs: ChatComposer, rhs: ChatComposer) -> Bool {
    lhs.placeholder == rhs.placeholder
      && lhs.conversationID == rhs.conversationID
      && lhs.isResponding == rhs.isResponding
      && lhs.appearance == rhs.appearance
  }

  var body: some View {
    HStack(alignment: .bottom, spacing: 10) {
      toolMenu

      ComposerTextView(
        text: draftBinding,
        height: $composerHeight,
        placeholder: placeholder,
        isFocused: $composerFocused,
        appearance: appearance
      )
      .frame(height: composerHeight)
      .onChange(of: appearance) { _, newAppearance in
        composerHeight = ComposerTextView.singleLineHeight(for: newAppearance)
      }

      Button {
        if let id = conversationID, isResponding {
          store.cancelResponse(in: id)
        } else {
          submitDraft()
        }
      } label: {
        Image(systemName: isResponding ? "stop.circle" : "arrow.up.circle.fill")
          .font(.title2)
      }
      .buttonStyle(.glassProminent)
      .disabled(
        !isResponding
          && draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        draftText = newText
        store.setDraftText(newText, for: conversationID)
      }
    )
  }

  private func submitDraft() {
    guard !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
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
        .frame(width: 32, height: 32)
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

private struct ComposerTextView: UIViewRepresentable {
  @Binding var text: String
  @Binding var height: CGFloat
  var placeholder: String
  var isFocused: FocusState<Bool>.Binding
  var appearance: AppearanceSettings

  static let maxLines: Int = 3
  private static let verticalInset: CGFloat = 7

  static var singleLineHeight: CGFloat {
    lineHeight(for: 1, appearance: .defaults)
  }

  static func singleLineHeight(for appearance: AppearanceSettings) -> CGFloat {
    lineHeight(for: 1, appearance: appearance)
  }

  static func maxComposerHeight(for appearance: AppearanceSettings) -> CGFloat {
    lineHeight(for: maxLines, appearance: appearance)
  }

  private static func lineHeight(for lines: Int, appearance: AppearanceSettings) -> CGFloat {
    let font = appearance.userUIFont
    return ceil(font.lineHeight * CGFloat(lines)) + verticalInset * 2
  }

  func makeUIView(context: Context) -> UITextView {
    let textView = UITextView()
    textView.delegate = context.coordinator
    textView.backgroundColor = .clear
    textView.font = appearance.userUIFont
    textView.adjustsFontForContentSizeCategory = true
    textView.isScrollEnabled = false
    textView.textContainerInset = UIEdgeInsets(
      top: Self.verticalInset, left: 0, bottom: Self.verticalInset, right: 0)
    textView.textContainer.lineFragmentPadding = 0
    textView.returnKeyType = .default
    textView.autocorrectionType = .yes
    textView.smartQuotesType = .no
    textView.smartDashesType = .no
    textView.smartInsertDeleteType = .no
    textView.spellCheckingType = .yes
    textView.keyboardAppearance = .default
    textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    context.coordinator.installPlaceholder(in: textView, text: placeholder)
    return textView
  }

  func updateUIView(_ textView: UITextView, context: Context) {
    context.coordinator.parent = self
    if textView.text != text {
      textView.text = text
      context.coordinator.updatePlaceholderVisibility(for: textView)
    }
    let preferredFont = appearance.userUIFont
    if !fontsMatch(textView.font, preferredFont) {
      textView.font = preferredFont
      context.coordinator.updatePlaceholderFont(textView.font)
    }
    context.coordinator.updatePlaceholderText(placeholder)
    recalculateHeight(textView)
    if isFocused.wrappedValue && !textView.isFirstResponder {
      textView.becomeFirstResponder()
    }
  }

  fileprivate func recalculateHeight(_ textView: UITextView) {
    let width =
      textView.bounds.width > 0
      ? textView.bounds.width
      : textView.textContainer.size.width
    guard width > 0 else { return }
    let fitted = textView.sizeThatFits(
      CGSize(width: width, height: .greatestFiniteMagnitude))
    let minHeight = Self.singleLineHeight(for: appearance)
    let maxHeight = Self.maxComposerHeight(for: appearance)
    let clamped = min(maxHeight, max(minHeight, ceil(fitted.height)))
    let shouldScroll = fitted.height > maxHeight + 0.5
    if textView.isScrollEnabled != shouldScroll {
      textView.isScrollEnabled = shouldScroll
    }
    if abs(clamped - height) > 0.5 {
      DispatchQueue.main.async {
        height = clamped
      }
    }
  }

  private func fontsMatch(_ lhs: UIFont?, _ rhs: UIFont) -> Bool {
    guard let lhs else { return false }
    return lhs.fontName == rhs.fontName && abs(lhs.pointSize - rhs.pointSize) < 0.1
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: ComposerTextView
    private let placeholderLabel = UILabel()

    init(parent: ComposerTextView) {
      self.parent = parent
      super.init()
    }

    func installPlaceholder(in textView: UITextView, text: String) {
      placeholderLabel.font = textView.font
      placeholderLabel.textColor = .placeholderText
      placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
      placeholderLabel.text = text
      textView.addSubview(placeholderLabel)
      NSLayoutConstraint.activate([
        placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
        placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor),
        placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 7),
      ])
      updatePlaceholderVisibility(for: textView)
    }

    func updatePlaceholderText(_ text: String) {
      if placeholderLabel.text != text {
        placeholderLabel.text = text
      }
    }

    func updatePlaceholderFont(_ font: UIFont?) {
      if placeholderLabel.font.fontName != font?.fontName
        || abs(placeholderLabel.font.pointSize - (font?.pointSize ?? 0)) >= 0.1
      {
        placeholderLabel.font = font
      }
    }

    func updatePlaceholderVisibility(for textView: UITextView) {
      placeholderLabel.isHidden = !textView.text.isEmpty
    }

    func textViewDidChange(_ textView: UITextView) {
      parent.text = textView.text
      updatePlaceholderVisibility(for: textView)
      parent.recalculateHeight(textView)
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
      parent.isFocused.wrappedValue = true
    }
  }
}

private struct ExportedEPUB: Identifiable {
  let id = UUID()
  let url: URL
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
              ForEach(store.settings.openAIEndpoints.filter(\.isEnabled)) { endpoint in
                Label(
                  endpoint.name.isEmpty ? "Untitled Endpoint" : endpoint.name,
                  systemImage: "network"
                )
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
            Toggle("Stream responses", isOn: streamingBinding)
          }

          Section {
            Button {
              saveProviderModelAsDefault()
            } label: {
              Label("Save Provider & Model as Default", systemImage: "star")
            }
            .disabled(!canSaveProviderModelAsDefault)
          } footer: {
            if didSaveDefaults {
              Text("Future chats will use this provider and model.")
            }
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

  private var selectedEndpoint: OpenAIEndpoint? {
    guard let conversation = store.currentConversation else { return nil }
    return OpenAICompatibleProvider.selectedEndpoint(for: conversation, settings: store.settings)
  }

  private var canSaveProviderModelAsDefault: Bool {
    guard let conversation = store.currentConversation else { return false }
    switch conversation.provider {
    case .apple:
      return true
    case .openAICompatible:
      return selectedEndpoint != nil
    }
  }

  private func saveProviderModelAsDefault() {
    guard let conversation = store.currentConversation else { return }
    switch conversation.provider {
    case .apple:
      store.settings.defaultProvider = .apple
      store.settings.appleModelID = conversation.modelID
    case .openAICompatible:
      guard let endpoint = selectedEndpoint,
        let index = store.settings.openAIEndpoints.firstIndex(where: { $0.id == endpoint.id })
      else { return }
      let model = conversation.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
      store.settings.defaultProvider = .openAICompatible
      store.settings.selectedEndpointID = endpoint.id
      if !model.isEmpty {
        store.settings.openAIEndpoints[index].defaultModel = model
      }
    }
    store.saveSettings()
    didSaveDefaults = true
  }

  private var providerSelectionBinding: Binding<DefaultProviderSelection> {
    Binding(
      get: {
        guard let conversation = store.currentConversation else { return .apple }
        switch conversation.provider {
        case .apple:
          return .apple
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
