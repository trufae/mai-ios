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
  @Published var conversationSummaries: [ConversationSummary] = []
  @Published var selectedConversationID: UUID?
  @Published var selectedConversationIDs: Set<UUID> = []
  @Published var settings: AppSettings
  @Published var respondingConversationIDs: Set<UUID> = []

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
  private var conversationIndexByID: [UUID: Int] = [:]
  private var hasLoadedPersistedConversations = false
  private var pendingConversationSave = false
  private var dirtyConversationIDsBeforeLoad: Set<UUID> = []
  private var deletedConversationIDsBeforeLoad: Set<UUID> = []

  init(
    persistence: PersistenceStore = PersistenceStore(),
    streamingTextStore: StreamingTextStore = StreamingTextStore()
  ) {
    self.persistence = persistence
    self.streamingTextStore = streamingTextStore
    settings = persistence.loadSettings()
    conversations = []
    appleAvailabilityMessage = nil
    startFreshConversationForLaunch()
    Task { await loadStartupData() }
  }

  var currentConversation: Conversation? {
    guard let selectedConversationID,
      let index = indexedConversationIndex(for: selectedConversationID)
    else { return nil }
    return conversations[index]
  }

  func newConversation() {
    if let current = currentConversation,
      current.messages.isEmpty
    {
      selectedConversationIDs.removeAll()
      if isDisposableNewConversation(current),
        !conversationUsesNewConversationDefaults(current)
      {
        discardSelectedDisposableConversation()
        createAndSelectNewConversation()
      }
      return
    }
    discardSelectedDisposableConversation()
    createAndSelectNewConversation()
  }

  private func startFreshConversationForLaunch() {
    let conversation = makeNewConversation()
    conversations.insert(conversation, at: 0)
    sortConversations()
    selectedConversationID = conversation.id
    selectedConversationIDs.removeAll()
  }

  private func loadStartupData() async {
    await Task.yield()

    let persistence = self.persistence
    let summaries = await Task.detached(priority: .userInitiated) {
      persistence.loadConversationSummaries()
    }.value
    mergeLoadedSummaries(summaries)

    let availabilityTask = Task.detached(priority: .utility) {
      AppleFoundationProvider.unavailableMessage
    }
    let loadedConversations = await Task.detached(priority: .userInitiated) {
      persistence.loadConversations()
    }.value

    mergeLoadedConversations(loadedConversations)
    appleAvailabilityMessage = await availabilityTask.value
  }

  private func makeNewConversation() -> Conversation {
    let defaultProvider = settings.defaultProviderConfiguration
    var conversation = Conversation()
    conversation.provider = defaultProvider.provider
    conversation.modelID = defaultProvider.modelID
    conversation.endpointID = defaultProvider.endpointID
    if let endpointID = defaultProvider.endpointID,
      let endpoint = settings.openAIEndpoints.first(where: { $0.id == endpointID })
    {
      conversation.reasoningLevel = endpoint.defaultReasoningLevel
    }
    conversation.systemPromptID = settings.defaultSystemPromptID
    conversation.enabledTools = settings.defaultEnabledTools
    conversation.usesStreaming = settings.streamByDefault
    conversation.showThinking = settings.showThinkingByDefault
    return conversation
  }

  private func createAndSelectNewConversation() {
    let conversation = makeNewConversation()
    conversations.insert(conversation, at: 0)
    sortConversations()
    selectedConversationID = conversation.id
    selectedConversationIDs.removeAll()
    saveConversations()
  }

  private func conversationUsesNewConversationDefaults(_ conversation: Conversation) -> Bool {
    let defaults = makeNewConversation()
    return conversation.provider == defaults.provider
      && conversation.endpointID == defaults.endpointID
      && normalizedModelID(conversation.modelID) == normalizedModelID(defaults.modelID)
      && conversation.systemPromptID == defaults.systemPromptID
      && conversation.enabledTools == defaults.enabledTools
      && conversation.usesStreaming == defaults.usesStreaming
      && conversation.showThinking == defaults.showThinking
      && conversation.reasoningLevel == defaults.reasoningLevel
      && conversation.disabledMCPTools == defaults.disabledMCPTools
  }

  private func normalizedModelID(_ modelID: String) -> String {
    modelID.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func selectConversation(id: UUID) async {
    let previousID = selectedConversationID
    await ensureConversationLoaded(id)
    guard indexedConversationIndex(for: id) != nil else { return }
    selectedConversationID = id
    if previousID != id, discardDisposableConversation(id: previousID) {
      saveConversations()
    }
  }

  func toggleArchive(id: UUID) async {
    await ensureConversationLoaded(id)
    guard let index = indexedConversationIndex(for: id) else { return }
    conversations[index].isArchived.toggle()
    conversations[index].updatedAt = Date()
    sortConversations()
    saveConversations()
  }

  func togglePin(id: UUID) async {
    await ensureConversationLoaded(id)
    guard let index = indexedConversationIndex(for: id) else { return }
    conversations[index].isPinned.toggle()
    conversations[index].updatedAt = Date()
    sortConversations()
    saveConversations()
  }

  func cloneConversation(id: UUID) async {
    await ensureConversationLoaded(id)
    guard let conversation = conversation(withID: id) else { return }
    cloneConversation(conversation)
  }

  private func ensureConversationLoaded(_ id: UUID) async {
    guard indexedConversationIndex(for: id) == nil else { return }
    let persistence = self.persistence
    let loadedConversation = await Task.detached(priority: .userInitiated) {
      persistence.loadConversation(id: id)
    }.value
    guard let conversation = loadedConversation else {
      return
    }
    guard indexedConversationIndex(for: id) == nil else { return }
    conversations.append(conversation)
    sortConversations()
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

  func updateCurrentConversation(_ update: (inout Conversation) -> Void) {
    guard let index = currentConversationIndex else { return }
    update(&conversations[index])
    conversations[index].updatedAt = Date()
    upsertSummary(for: conversations[index])
    saveConversations()
  }

  func deleteMessage(_ message: ChatMessage) {
    updateCurrentConversation { conversation in
      conversation.messages.removeAll { $0.id == message.id }
    }
  }

  func clearAllConversations() {
    let archived = conversations.filter(\.isArchived)
    let removedIDs = Set(conversationSummaries.filter { !$0.isArchived }.map(\.id))
    if !hasLoadedPersistedConversations {
      deletedConversationIDsBeforeLoad.formUnion(removedIDs)
    }
    for id in removedIDs {
      responseTasks[id]?.cancel()
      responseTasks[id] = nil
      respondingConversationIDs.remove(id)
    }
    let archivedIDs = Set(archived.map(\.id))
    conversationDrafts = conversationDrafts.filter { archivedIDs.contains($0.key) }
    streamingTextStore.removeAll()
    conversations = archived
    rebuildConversationIndexes()
    conversationSummaries = Self.sortedSummaries(archived.map(ConversationSummary.init))
    selectedConversationID = nil
    selectedConversationIDs.removeAll()
    saveConversations()
    newConversation()
  }

  func toggleArchive(_ conversation: Conversation) {
    guard let index = indexedConversationIndex(for: conversation.id) else { return }
    conversations[index].isArchived.toggle()
    conversations[index].updatedAt = Date()
    sortConversations()
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
    guard let prompt = restartPrompt(from: message) else { return }

    conversations[index].messages.removeAll()
    conversations[index].title = "New chat"
    conversations[index].updatedAt = Date()
    upsertSummary(for: conversations[index])
    saveConversations()

    _ = await send(prompt: prompt)
  }

  func startNewConversation(with message: ChatMessage) async {
    guard let prompt = restartPrompt(from: message) else { return }

    let source = currentConversation
    discardSelectedDisposableConversation()
    var conversation = makeNewConversation()
    if let source {
      conversation.provider = source.provider
      conversation.modelID = source.modelID
      conversation.endpointID = source.endpointID
      conversation.systemPromptID = source.systemPromptID
      conversation.enabledTools = source.enabledTools
      conversation.usesStreaming = source.usesStreaming
      conversation.disabledMCPTools = source.disabledMCPTools
      conversation.reasoningLevel = source.reasoningLevel
      conversation.showThinking = source.showThinking
    }
    conversations.insert(conversation, at: 0)
    sortConversations()
    selectedConversationID = conversation.id
    selectedConversationIDs.removeAll()
    saveConversations()

    _ = await send(prompt: prompt)
  }

  private func restartPrompt(from message: ChatMessage) -> String? {
    let visible = MessageContentFilter.render(message.text).visibleText
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let fallback = MessageContentFilter.promptSafeText(from: message.text)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let prompt = visible.isEmpty ? fallback : visible
    return prompt.isEmpty ? nil : prompt
  }

  func deleteConversations(_ ids: Set<UUID>) {
    if !hasLoadedPersistedConversations {
      deletedConversationIDsBeforeLoad.formUnion(ids)
    }
    for id in ids {
      responseTasks[id]?.cancel()
      responseTasks[id] = nil
      respondingConversationIDs.remove(id)
      conversationDrafts.removeValue(forKey: id)
    }
    conversations.removeAll { ids.contains($0.id) }
    rebuildConversationIndexes()
    removeSummaries(for: ids)
    selectedConversationIDs.removeAll()
    if let selectedConversationID, ids.contains(selectedConversationID) {
      self.selectedConversationID = conversations.first?.id
    }
    if conversations.isEmpty {
      selectedConversationID = nil
      createInitialConversationIfNeeded()
    }
    saveConversations()
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
    if let index = indexedConversationIndex(for: conversation.id) {
      conversations.insert(cloned, at: index)
    } else {
      conversations.insert(cloned, at: 0)
    }
    sortConversations()
    selectedConversationID = cloned.id
    saveConversations()
  }

  func togglePin(_ conversation: Conversation) {
    guard let index = indexedConversationIndex(for: conversation.id) else { return }
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
    upsertSummary(for: conversations[convIndex])
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
    guard let index = indexedConversationIndex(for: conversationID) else { return }
    let conversation = conversations[index]
    let previousToolContextSignature = conversation.lastToolContextSignature
    let toolContext = await ToolContextBuilder.build(
      input: prompt,
      conversation: conversation,
      settings: settings,
      locationService: { self.locationService }
    )
    let trimmedTC = toolContext.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let embed: Bool = {
      guard !trimmedTC.isEmpty else { return false }
      switch mode {
      case .append:
        return previousToolContextSignature != toolContext.signature
      case .replaceLastUser:
        return true
      }
    }()
    let userText =
      embed
      ? "\(prompt)\n\n<tool_context>\n\(trimmedTC)\n</tool_context>"
      : prompt

    guard let i = indexedConversationIndex(for: conversationID) else { return }
    switch mode {
    case .append:
      let userMessage = ChatMessage(role: .user, text: userText)
      conversations[i].messages.append(userMessage)
      conversations[i].refreshTitle(from: prompt)
    case .replaceLastUser:
      if let lastIndex = conversations[i].messages.indices.last {
        conversations[i].messages[lastIndex].text = userText
      }
    }
    conversations[i].lastToolContextSignature = toolContext.signature
    conversations[i].updatedAt = Date()
    upsertSummary(for: conversations[i])
    saveConversations()

    dispatchAssistantTurn(
      conversationID: conversationID, toolContext: embed ? toolContext.text : "")
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
    if let location = messageLocation(for: id) {
      return conversations[location.conversationIndex].messages[location.messageIndex].text
    }
    return ""
  }

  func conversation(withID id: UUID) -> Conversation? {
    guard let index = indexedConversationIndex(for: id) else { return nil }
    return conversations[index]
  }

  func conversationIndex(for id: UUID) -> Int? {
    indexedConversationIndex(for: id)
  }

  func appendAssistantMessage(to conversationID: UUID) -> UUID? {
    guard let index = indexedConversationIndex(for: conversationID) else { return nil }
    let assistantMessage = ChatMessage(role: .assistant, text: "")
    conversations[index].messages.append(assistantMessage)
    conversations[index].updatedAt = Date()
    upsertSummary(for: conversations[index])
    saveConversations()
    return assistantMessage.id
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
      guard let idx = indexedConversationIndex(for: compact.conversationID) else {
        return
      }
      conversations[idx].messages = [
        ChatMessage(role: .system, text: "Conversation summary (compacted):\n\n\(trimmed)")
      ]
      conversations[idx].updatedAt = Date()
      upsertSummary(for: conversations[idx])
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

  func exportCurrentConversationFile(format: ConversationExportFormat) -> URL? {
    guard let conversation = currentConversation else { return nil }
    switch format {
    case .markdown, .json:
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "PocketMaiExports",
        isDirectory: true
      )
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = exportFilename(for: conversation)
        let url = directory.appendingPathComponent(filename).appendingPathExtension(
          format.fileExtension)
        try export(conversation: conversation, format: format).write(
          to: url, atomically: true, encoding: .utf8)
        return url
      } catch {
        errorMessage = "Could not export \(format.displayName): \(error.localizedDescription)"
        return nil
      }
    case .epub:
      return exportCurrentConversationEPUB()
    case .audio:
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
    guard hasLoadedPersistedConversations else {
      pendingConversationSave = true
      dirtyConversationIDsBeforeLoad.formUnion(conversations.map(\.id))
      return
    }
    persistence.saveConversations(conversations)
  }

  private func sortConversations() {
    conversations = Self.sortedConversations(conversations)
    rebuildConversationIndexes()
    rebuildSummariesFromConversations()
  }

  private func mergeLoadedSummaries(_ summaries: [ConversationSummary]) {
    guard !summaries.isEmpty else { return }
    var byID = Dictionary(uniqueKeysWithValues: conversationSummaries.map { ($0.id, $0) })
    for summary in summaries
    where byID[summary.id] == nil && !deletedConversationIDsBeforeLoad.contains(summary.id) {
      byID[summary.id] = summary
    }
    conversationSummaries = Self.sortedSummaries(Array(byID.values))
  }

  private func mergeLoadedConversations(_ loaded: [Conversation]) {
    let loaded = loaded.filter { !deletedConversationIDsBeforeLoad.contains($0.id) }
    var byID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
    for conversation in conversations {
      if dirtyConversationIDsBeforeLoad.contains(conversation.id) || byID[conversation.id] == nil {
        byID[conversation.id] = conversation
      }
    }
    conversations = Self.sortedConversations(Array(byID.values))
    rebuildConversationIndexes()
    rebuildSummariesFromConversations()
    hasLoadedPersistedConversations = true
    if pendingConversationSave {
      pendingConversationSave = false
      saveConversations()
    }
  }

  private func rebuildSummariesFromConversations() {
    let loadedSummaries = conversations.map(ConversationSummary.init)
    var byID = Dictionary(uniqueKeysWithValues: conversationSummaries.map { ($0.id, $0) })
    for summary in loadedSummaries {
      byID[summary.id] = summary
    }
    conversationSummaries = Self.sortedSummaries(Array(byID.values))
  }

  private func upsertSummary(for conversation: Conversation) {
    let summary = ConversationSummary(conversation: conversation)
    if let index = conversationSummaries.firstIndex(where: { $0.id == conversation.id }) {
      conversationSummaries[index] = summary
    } else {
      conversationSummaries.append(summary)
    }
    conversationSummaries = Self.sortedSummaries(conversationSummaries)
  }

  private func removeSummaries(for ids: Set<UUID>) {
    conversationSummaries.removeAll { ids.contains($0.id) }
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

  nonisolated static func sortedSummaries(_ summaries: [ConversationSummary])
    -> [ConversationSummary]
  {
    summaries.sorted { lhs, rhs in
      if lhs.isPinned != rhs.isPinned {
        return lhs.isPinned && !rhs.isPinned
      }
      if lhs.updatedAt != rhs.updatedAt {
        return lhs.updatedAt > rhs.updatedAt
      }
      return lhs.createdAt > rhs.createdAt
    }
  }

  private func discardSelectedDisposableConversation() {
    discardDisposableConversation(id: selectedConversationID)
  }

  @discardableResult
  private func discardDisposableConversation(id: UUID?) -> Bool {
    guard let id,
      let index = indexedConversationIndex(for: id),
      isDisposableNewConversation(conversations[index])
    else {
      return false
    }
    let removedID = id
    conversations.remove(at: index)
    rebuildConversationIndexes()
    removeSummaries(for: [removedID])
    responseTasks[removedID]?.cancel()
    responseTasks[removedID] = nil
    respondingConversationIDs.remove(removedID)
    conversationDrafts.removeValue(forKey: removedID)
    if !hasLoadedPersistedConversations {
      deletedConversationIDsBeforeLoad.insert(removedID)
    }
    return true
  }

  private func isDisposableNewConversation(_ conversation: Conversation) -> Bool {
    guard conversation.messages.isEmpty,
      !respondingConversationIDs.contains(conversation.id),
      conversationDrafts[conversation.id, default: ""].trimmingCharacters(
        in: .whitespacesAndNewlines
      )
      .isEmpty,
      !conversation.isPinned,
      !conversation.isArchived
    else {
      return false
    }
    let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty || title == "New chat"
  }

  private func createInitialConversationIfNeeded() {
    guard conversations.isEmpty else { return }
    let conversation = makeNewConversation()
    conversations.insert(conversation, at: 0)
    sortConversations()
    selectedConversationID = conversation.id
    selectedConversationIDs.removeAll()
  }

  private var currentConversationIndex: Int? {
    guard let selectedConversationID else { return nil }
    return indexedConversationIndex(for: selectedConversationID)
  }

  private func indexedConversationIndex(for id: UUID) -> Int? {
    if let index = conversationIndexByID[id],
      conversations.indices.contains(index),
      conversations[index].id == id
    {
      return index
    }
    rebuildConversationIndexes()
    guard let index = conversationIndexByID[id],
      conversations.indices.contains(index),
      conversations[index].id == id
    else {
      return nil
    }
    return index
  }

  private func rebuildConversationIndexes() {
    var conversationIndexes: [UUID: Int] = [:]
    conversationIndexes.reserveCapacity(conversations.count)

    for (conversationIndex, conversation) in conversations.enumerated() {
      conversationIndexes[conversation.id] = conversationIndex
    }

    conversationIndexByID = conversationIndexes
  }

  private func messageLocation(for id: UUID) -> (conversationIndex: Int, messageIndex: Int)? {
    if let selectedIndex = currentConversationIndex,
      let messageIndex = conversations[selectedIndex].messages.firstIndex(where: { $0.id == id })
    {
      return (selectedIndex, messageIndex)
    }
    for conversationIndex in conversations.indices {
      guard conversationIndex != currentConversationIndex else { continue }
      if let messageIndex = conversations[conversationIndex].messages.firstIndex(where: {
        $0.id == id
      }) {
        return (conversationIndex, messageIndex)
      }
    }
    return nil
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
    // Final / discrete update: write the canonical message first so any
    // re-render observing the streaming buffer being cleared sees the final
    // text in `message.text` instead of the empty placeholder it started with.
    if let location = messageLocation(for: id) {
      let conversationIndex = location.conversationIndex
      let messageIndex = location.messageIndex
      var conversation = conversations[conversationIndex]
      conversation.messages[messageIndex].text = text
      conversation.messages[messageIndex].role = role
      if touch {
        conversation.updatedAt = Date()
      }
      conversations[conversationIndex] = conversation
      upsertSummary(for: conversation)
    }
    streamingTextStore.clear(id: id)
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
    case .epub, .audio:
      return ""
    }
  }

  func exportFilename(for conversation: Conversation) -> String {
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
