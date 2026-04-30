import Combine
import Foundation
import SwiftUI
import UIKit

enum EndpointConnectionState: Equatable {
  case unknown
  case checking
  case available
  case failed(String)

  var statusText: String {
    switch self {
    case .unknown: "Not checked"
    case .checking: "Checking"
    case .available: "Connected"
    case .failed: "Failed"
    }
  }

  var statusColor: Color {
    switch self {
    case .unknown: .secondary
    case .checking: .orange
    case .available: .green
    case .failed: .red
    }
  }
}

@MainActor
final class AppStore: ObservableObject {
  @Published var conversations: [Conversation]
  @Published var selectedConversationID: UUID?
  @Published var selectedConversationIDs: Set<UUID> = []
  @Published var settings: AppSettings
  @Published var respondingConversationIDs: Set<UUID> = []
  @Published var isIncognitoMode = false

  private var responseTasks: [UUID: Task<Void, Never>] = [:]

  var isResponding: Bool { !respondingConversationIDs.isEmpty }

  func isResponding(in conversationID: UUID) -> Bool {
    respondingConversationIDs.contains(conversationID)
  }

  func cancelResponse(in conversationID: UUID) {
    responseTasks[conversationID]?.cancel()
  }
  @Published var errorMessage: String?
  @Published var isUpdatingMemory = false
  @Published var isCompacting = false
  @Published var endpointStatuses: [UUID: EndpointConnectionState] = [:]
  @Published var endpointModels: [UUID: [String]] = [:]
  @Published var mcpStatuses: [UUID: EndpointConnectionState] = [:]
  @Published var mcpTools: [UUID: [MCPToolDescriptor]] = [:]
  /// Cached Apple Intelligence availability message; nil means available.
  /// Refreshed on app launch and on scene activation, not per-render.
  @Published var appleAvailabilityMessage: String?

  let streamingTextStore: StreamingTextStore
  lazy var locationService = LocationService()
  private let persistence: PersistenceStore
  private var conversationDrafts: [UUID: String] = [:]

  init(
    persistence: PersistenceStore = PersistenceStore(),
    streamingTextStore: StreamingTextStore = StreamingTextStore()
  ) {
    self.persistence = persistence
    self.streamingTextStore = streamingTextStore
    settings = persistence.loadSettings()
    conversations = Self.sortedConversations(persistence.loadConversations())
    appleAvailabilityMessage = AppleFoundationProvider.unavailableMessage
    startFreshConversationForLaunch()
  }

  var currentConversation: Conversation? {
    guard let selectedConversationID else { return nil }
    return conversations.first(where: { $0.id == selectedConversationID })
  }

  func newConversation(incognito: Bool = false) {
    if let current = currentConversation,
      current.messages.isEmpty,
      current.isIncognito == incognito
    {
      isIncognitoMode = incognito
      selectedConversationIDs.removeAll()
      return
    }
    discardSelectedIncognitoConversation()
    let conversation = makeNewConversation(incognito: incognito)
    conversations.insert(conversation, at: 0)
    sortConversations()
    selectedConversationID = conversation.id
    isIncognitoMode = incognito
    selectedConversationIDs.removeAll()
    saveConversations()
  }

  private func startFreshConversationForLaunch() {
    let conversation = makeNewConversation()
    conversations.insert(conversation, at: 0)
    sortConversations()
    selectedConversationID = conversation.id
    isIncognitoMode = false
    selectedConversationIDs.removeAll()
  }

  private func makeNewConversation(incognito: Bool = false) -> Conversation {
    let endpoint =
      settings.openAIEndpoints.first(where: { $0.id == settings.selectedEndpointID })
      ?? settings.openAIEndpoints.first
    let provider = settings.defaultProvider
    let model = provider == .apple ? settings.appleModelID : (endpoint?.defaultModel ?? "")
    var conversation = Conversation()
    conversation.isIncognito = incognito
    conversation.provider = provider
    conversation.modelID = model
    conversation.endpointID = endpoint?.id
    conversation.systemPromptID = settings.defaultSystemPromptID
    conversation.enabledTools = settings.defaultEnabledTools
    conversation.usesStreaming = settings.streamByDefault
    conversation.showThinking = settings.showThinkingByDefault
    return conversation
  }

  func select(_ conversation: Conversation) {
    selectedConversationID = conversation.id
    isIncognitoMode = conversation.isIncognito
  }

  func draftText(for conversationID: UUID?) -> String {
    guard let conversationID else { return "" }
    return conversationDrafts[conversationID] ?? ""
  }

  func setDraftText(_ text: String, for conversationID: UUID?) {
    guard let conversationID else { return }
    if text.isEmpty {
      conversationDrafts.removeValue(forKey: conversationID)
    } else {
      conversationDrafts[conversationID] = text
    }
  }

  func toggleIncognitoMode() {
    guard let index = currentConversationIndex else {
      isIncognitoMode.toggle()
      return
    }
    conversations[index].isIncognito.toggle()
    conversations[index].updatedAt = Date()
    isIncognitoMode = conversations[index].isIncognito
    saveConversations()
  }

  func updateCurrentConversation(_ update: (inout Conversation) -> Void) {
    guard let index = currentConversationIndex else { return }
    update(&conversations[index])
    conversations[index].updatedAt = Date()
    saveConversations()
  }

  func deleteMessage(_ message: ChatMessage) {
    updateCurrentConversation { conversation in
      conversation.messages.removeAll { $0.id == message.id }
    }
  }

  func clearAllConversations() {
    let archived = conversations.filter(\.isArchived)
    let removedIDs = Set(conversations.filter { !$0.isArchived }.map(\.id))
    for id in removedIDs {
      responseTasks[id]?.cancel()
      responseTasks[id] = nil
      respondingConversationIDs.remove(id)
    }
    let archivedIDs = Set(archived.map(\.id))
    conversationDrafts = conversationDrafts.filter { archivedIDs.contains($0.key) }
    streamingTextStore.removeAll()
    conversations = archived
    selectedConversationID = nil
    selectedConversationIDs.removeAll()
    isIncognitoMode = false
    saveConversations()
    newConversation()
  }

  func toggleArchive(_ conversation: Conversation) {
    guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
    conversations[index].isArchived.toggle()
    conversations[index].updatedAt = Date()
    sortConversations()
    saveConversations()
  }

  func clearCurrentConversation() {
    guard let index = currentConversationIndex else { return }
    guard !conversations[index].messages.isEmpty else { return }
    conversations[index].messages.removeAll()
    conversations[index].updatedAt = Date()
    saveConversations()
  }

  func resubmit(_ message: ChatMessage) async {
    guard message.role == .user, !isResponding else { return }
    let cleaned = MessageContentFilter.promptSafeText(from: message.text)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return }
    _ = await send(prompt: cleaned)
  }

  func restartFromScratch(with message: ChatMessage) async {
    guard !isResponding, let index = currentConversationIndex else { return }
    let visible = MessageContentFilter.render(message.text).visibleText
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let fallback = MessageContentFilter.promptSafeText(from: message.text)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let prompt = visible.isEmpty ? fallback : visible
    guard !prompt.isEmpty else { return }

    conversations[index].messages.removeAll()
    conversations[index].title = "New chat"
    conversations[index].updatedAt = Date()
    saveConversations()

    _ = await send(prompt: prompt)
  }

  func deleteConversations(_ ids: Set<UUID>) {
    for id in ids {
      responseTasks[id]?.cancel()
      responseTasks[id] = nil
      respondingConversationIDs.remove(id)
      conversationDrafts.removeValue(forKey: id)
    }
    conversations.removeAll { ids.contains($0.id) }
    selectedConversationIDs.removeAll()
    if let selectedConversationID, ids.contains(selectedConversationID) {
      self.selectedConversationID = conversations.first?.id
    }
    if conversations.isEmpty {
      selectedConversationID = nil
      newConversation()
    }
    syncIncognitoModeWithSelection()
    saveConversations()
  }

  func deleteConversation(_ conversation: Conversation) {
    deleteConversations([conversation.id])
  }

  func cloneConversation(_ conversation: Conversation) {
    let now = Date()
    let copyTitle: String = {
      let trimmed = conversation.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty || trimmed == "New chat" {
        return "New chat (Copy)"
      }
      return "\(trimmed) (Copy)"
    }()
    var cloned = conversation
    cloned.id = UUID()
    cloned.title = copyTitle
    cloned.messages = conversation.messages.map {
      ChatMessage(id: UUID(), role: $0.role, text: $0.text, createdAt: $0.createdAt)
    }
    cloned.createdAt = now
    cloned.updatedAt = now
    cloned.isPinned = false
    cloned.lastToolContextSignature = nil
    cloned.isArchived = false
    if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
      conversations.insert(cloned, at: index)
    } else {
      conversations.insert(cloned, at: 0)
    }
    sortConversations()
    selectedConversationID = cloned.id
    isIncognitoMode = cloned.isIncognito
    saveConversations()
  }

  func togglePin(_ conversation: Conversation) {
    guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
    conversations[index].isPinned.toggle()
    conversations[index].updatedAt = Date()
    sortConversations()
    saveConversations()
  }

  func send(prompt rawPrompt: String) async -> Bool {
    let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else { return false }
    if currentConversation == nil {
      newConversation()
    }
    guard let index = currentConversationIndex else { return false }
    let conversationID = conversations[index].id
    guard !respondingConversationIDs.contains(conversationID) else { return false }
    if let message = ChatProviderRouter.preflightMessage(
      conversation: conversations[index], settings: settings)
    {
      errorMessage = message
      return false
    }

    errorMessage = nil
    await composeUserTurn(prompt: prompt, conversationID: conversationID, mode: .append)
    return true
  }

  func trimAndResubmit(from message: ChatMessage) async {
    guard let convIndex = currentConversationIndex else { return }
    let conversationID = conversations[convIndex].id
    guard !respondingConversationIDs.contains(conversationID) else { return }
    guard
      let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == message.id })
    else { return }

    let cutoff: Int = message.role == .user ? msgIndex : msgIndex - 1
    guard cutoff >= 0 else { return }
    conversations[convIndex].messages = Array(conversations[convIndex].messages.prefix(cutoff + 1))
    conversations[convIndex].updatedAt = Date()
    saveConversations()

    guard let last = conversations[convIndex].messages.last, last.role == .user else { return }
    let prompt = MessageContentFilter.promptSafeText(from: last.text)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else { return }

    if let preflight = ChatProviderRouter.preflightMessage(
      conversation: conversations[convIndex], settings: settings)
    {
      errorMessage = preflight
      return
    }

    errorMessage = nil
    await composeUserTurn(
      prompt: prompt, conversationID: conversationID, mode: .replaceLastUser)
  }

  private enum UserTurnMode {
    case append
    case replaceLastUser
  }

  private func composeUserTurn(
    prompt: String, conversationID: UUID, mode: UserTurnMode
  ) async {
    guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
    let toolContext = await ToolContextBuilder.build(
      input: prompt,
      conversation: conversations[index],
      settings: settings,
      locationService: { self.locationService }
    )
    let trimmedTC = toolContext.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let embed: Bool = {
      guard !trimmedTC.isEmpty else { return false }
      switch mode {
      case .append:
        return conversations[index].lastToolContextSignature != toolContext.signature
      case .replaceLastUser:
        return true
      }
    }()
    let userText =
      embed
      ? "\(prompt)\n\n<tool_context>\n\(trimmedTC)\n</tool_context>"
      : prompt

    guard let i = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
    switch mode {
    case .append:
      conversations[i].messages.append(ChatMessage(role: .user, text: userText))
      conversations[i].refreshTitle(from: prompt)
    case .replaceLastUser:
      if let lastIndex = conversations[i].messages.indices.last {
        conversations[i].messages[lastIndex].text = userText
      }
    }
    conversations[i].lastToolContextSignature = toolContext.signature
    conversations[i].updatedAt = Date()
    saveConversations()

    dispatchAssistantTurn(conversationID: conversationID, toolContext: embed ? toolContext.text : "")
  }

  private func dispatchAssistantTurn(conversationID: UUID, toolContext: String) {
    respondingConversationIDs.insert(conversationID)
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        respondingConversationIDs.remove(conversationID)
        responseTasks[conversationID] = nil
        saveConversations()
      }
      await AssistantTurnRunner.run(
        conversationID: conversationID,
        toolContext: toolContext,
        store: self
      )
    }
    responseTasks[conversationID] = task
  }

  func markAssistantStopped(id: UUID) {
    let current = currentTextOfMessage(id: id)
    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      setAssistantMessage(id: id, text: "[stopped]", role: .error)
    } else {
      setAssistantMessage(
        id: id, text: "\(current)\n\n[stopped]", role: .assistant)
    }
  }

  private func currentTextOfMessage(id: UUID) -> String {
    if let streaming = streamingTextStore.currentText(for: id) { return streaming }
    for conversation in conversations {
      if let message = conversation.messages.first(where: { $0.id == id }) {
        return message.text
      }
    }
    return ""
  }

  func compactConversation() async {
    guard !isCompacting, !isResponding else { return }
    guard let index = currentConversationIndex else { return }
    let conversation = conversations[index]
    let settingsSnapshot = settings

    isCompacting = true
    defer { isCompacting = false }
    errorMessage = nil

    guard
      let compact = await ConversationPromptBuilder.compactRequest(
        conversation: conversation,
        settings: settingsSnapshot
      )
    else {
      errorMessage = "Nothing to compact yet."
      return
    }

    do {
      let summary = try await OneShotPromptRunner.run(compact.oneShot, settings: settingsSnapshot)
      let trimmed = MessageContentFilter.promptSafeText(from: summary)
      guard !trimmed.isEmpty else {
        errorMessage = "Compact returned an empty summary."
        return
      }
      guard let idx = conversations.firstIndex(where: { $0.id == compact.conversationID }) else {
        return
      }
      conversations[idx].messages = [
        ChatMessage(role: .system, text: "Conversation summary (compacted):\n\n\(trimmed)")
      ]
      conversations[idx].updatedAt = Date()
      saveConversations()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func updateMemoryFromConversations() async {
    guard !isUpdatingMemory else { return }
    isUpdatingMemory = true
    defer { isUpdatingMemory = false }

    let conversationsSnapshot = conversations
    let settingsSnapshot = settings
    guard
      let prompt = await ConversationPromptBuilder.memoryUpdateRequest(
        conversations: conversationsSnapshot,
        settings: settingsSnapshot
      )
    else {
      return
    }

    do {
      let memory = try await OneShotPromptRunner.run(prompt, settings: settingsSnapshot)
      settings.memory = MessageContentFilter.promptSafeText(from: memory)
      saveSettings()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func importToolFile(from url: URL) {
    let access = url.startAccessingSecurityScopedResource()
    defer {
      if access {
        url.stopAccessingSecurityScopedResource()
      }
    }
    guard let data = try? Data(contentsOf: url) else { return }
    let excerpt =
      String(data: data.prefix(24_000), encoding: .utf8) ?? "Binary file: \(data.count) bytes"
    settings.toolSettings.files.append(ToolFile(name: url.lastPathComponent, excerpt: excerpt))
    saveSettings()
  }

  func copyMessage(_ message: ChatMessage) {
    UIPasteboard.general.string = message.text
  }

  func copyConversation(format: ConversationExportFormat) {
    guard let conversation = currentConversation else { return }
    UIPasteboard.general.string = export(conversation: conversation, format: format)
  }

  func exportCurrentConversationEPUB() -> URL? {
    guard let conversation = currentConversation else { return nil }
    let data = EPUBExporter.makeEPUB(conversation: conversation)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PocketMaiExports",
      isDirectory: true
    )
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let filename = exportFilename(for: conversation)
      let url = directory.appendingPathComponent(filename).appendingPathExtension("epub")
      try data.write(to: url, options: .atomic)
      return url
    } catch {
      errorMessage = "Could not export ePUB: \(error.localizedDescription)"
      return nil
    }
  }

  func saveSettings() {
    persistence.saveSettings(settings)
  }

  func resetEndpointStatus(_ id: UUID) {
    endpointStatuses[id] = .unknown
    endpointModels[id] = nil
  }

  func resetMCPStatus(_ id: UUID) {
    mcpStatuses[id] = .unknown
    mcpTools[id] = nil
  }

  func refreshMCP(_ server: MCPServer) async {
    mcpStatuses[server.id] = .checking
    do {
      let tools = try await MCPHTTPClient.fetchTools(server: server)
      mcpTools[server.id] = tools
      mcpStatuses[server.id] = .available
    } catch {
      mcpTools[server.id] = nil
      mcpStatuses[server.id] = .failed(error.localizedDescription)
    }
  }

  func refreshEndpoint(_ endpoint: OpenAIEndpoint) async {
    endpointStatuses[endpoint.id] = .checking
    do {
      let models = try await OpenAICompatibleProvider.fetchModels(endpoint: endpoint)
      endpointModels[endpoint.id] = models
      endpointStatuses[endpoint.id] = .available
      if let firstModel = models.first,
        let index = settings.openAIEndpoints.firstIndex(where: { $0.id == endpoint.id }),
        settings.openAIEndpoints[index].defaultModel
          .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        settings.openAIEndpoints[index].defaultModel = firstModel
        saveSettings()
      }
    } catch {
      endpointModels[endpoint.id] = nil
      endpointStatuses[endpoint.id] = .failed(error.localizedDescription)
    }
  }

  func saveConversations() {
    persistence.saveConversations(conversations)
  }

  private func sortConversations() {
    conversations = Self.sortedConversations(conversations)
  }

  nonisolated static func strippedSpuriousToolCallText(_ text: String) -> String {
    guard AgentTooling.containsToolCallMarker(in: text) else { return text }
    let patterns = [
      "<\\s*tool_call\\b[^>]*>[\\s\\S]*?<\\s*/\\s*tool_call\\s*>",
      "<\\s*tool_call\\b[^>]*>[\\s\\S]*$",
      "<\\s*/\\s*tool_call\\s*>",
    ]
    var result = text
    for pattern in patterns {
      result = result.replacingOccurrences(
        of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
    }
    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return "(model attempted a tool call but no tools are enabled.)"
    }
    return trimmed + "\n\n_(stripped spurious tool_call: no tools are enabled.)_"
  }

  nonisolated static func sortedConversations(_ conversations: [Conversation]) -> [Conversation] {
    conversations.sorted { lhs, rhs in
      if lhs.isPinned != rhs.isPinned {
        return lhs.isPinned && !rhs.isPinned
      }
      if lhs.updatedAt != rhs.updatedAt {
        return lhs.updatedAt > rhs.updatedAt
      }
      return lhs.createdAt > rhs.createdAt
    }
  }

  private func discardSelectedIncognitoConversation() {
    guard let selectedConversationID,
      let index = conversations.firstIndex(where: { $0.id == selectedConversationID }),
      conversations[index].isIncognito
    else {
      return
    }
    let removedID = selectedConversationID
    conversations.remove(at: index)
    responseTasks[removedID]?.cancel()
    responseTasks[removedID] = nil
    respondingConversationIDs.remove(removedID)
  }

  private func syncIncognitoModeWithSelection() {
    isIncognitoMode = currentConversation?.isIncognito ?? false
  }

  private var currentConversationIndex: Int? {
    guard let selectedConversationID else { return nil }
    return conversations.firstIndex(where: { $0.id == selectedConversationID })
  }

  func setAssistantMessage(
    id: UUID, text: String, role: ChatRole, touch: Bool = true, streaming: Bool = false
  ) {
    if streaming {
      // Token-rate updates land in a side buffer so `conversations` is not
      // republished per token. Bubbles read from this buffer when present.
      enqueueStreamingText(text, for: id)
      return
    }
    // Final / discrete update: commit to `conversations` and clear any
    // streaming buffer so bubbles fall back to the canonical message text.
    streamingTextStore.clear(id: id)
    guard
      let conversationIndex = conversations.firstIndex(where: { conversation in
        conversation.messages.contains(where: { $0.id == id })
      }),
      let messageIndex = conversations[conversationIndex].messages.firstIndex(where: { $0.id == id }
      )
    else {
      return
    }
    var conversation = conversations[conversationIndex]
    conversation.messages[messageIndex].text = text
    conversation.messages[messageIndex].role = role
    if touch {
      conversation.updatedAt = Date()
    }
    conversations[conversationIndex] = conversation
  }

  private func enqueueStreamingText(_ text: String, for id: UUID) {
    streamingTextStore.enqueue(text, for: id)
  }

  private func export(conversation: Conversation, format: ConversationExportFormat) -> String {
    switch format {
    case .markdown:
      return conversation.messages.map { message in
        "## \(message.role.displayName)\n\n\(message.text)"
      }.joined(separator: "\n\n")
    case .plainText:
      return conversation.messages.map { message in
        "\(message.role.displayName):\n\(message.text)"
      }.joined(separator: "\n\n")
    case .json:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      guard let data = try? encoder.encode(conversation),
        let json = String(data: data, encoding: .utf8)
      else {
        return "{}"
      }
      return json
    }
  }

  private func exportFilename(for conversation: Conversation) -> String {
    let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
      .union(.newlines)
      .union(.controlCharacters)
    let title = conversation.displayTitle
      .components(separatedBy: invalid)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let base = title.isEmpty ? "Chat" : title
    return String(base.prefix(80))
  }
}
