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

private enum ConversationImportError: LocalizedError {
  case unreadableFile
  case invalidJSON
  case titleRequired
  case titleAlreadyExists(String)
  case missingExistingConversation
  case updateNotAvailable

  var errorDescription: String? {
    switch self {
    case .unreadableFile:
      return "Could not read the selected file."
    case .invalidJSON:
      return "The selected file is not a valid PocketMai conversation export."
    case .titleRequired:
      return "Specify a title for the imported conversation."
    case .titleAlreadyExists(let title):
      return "A conversation named \"\(title)\" already exists."
    case .missingExistingConversation:
      return "The matching conversation no longer exists."
    case .updateNotAvailable:
      return "This import cannot update an existing conversation."
    }
  }
}

enum ToolCallApprovalDecision: Sendable {
  case approved(ParsedToolCall)
  case cancelled
  case interrupted
}

private enum ToolCallApprovalParseResult {
  case success(ParsedToolCall)
  case failure(String)
}

struct ToolCallApprovalRequest: Identifiable {
  let id: UUID
  let callName: String
  let originalText: String
  let mode: ToolCallingMode
  let definitions: [ToolDefinition]
  let conversationTitle: String?

  private let continuation: CheckedContinuation<ToolCallApprovalDecision, Never>

  init(
    id: UUID,
    callName: String,
    originalText: String,
    mode: ToolCallingMode,
    definitions: [ToolDefinition],
    conversationTitle: String?,
    continuation: CheckedContinuation<ToolCallApprovalDecision, Never>
  ) {
    self.id = id
    self.callName = callName
    self.originalText = originalText
    self.mode = mode
    self.definitions = definitions
    self.conversationTitle = conversationTitle
    self.continuation = continuation
  }

  func resume(returning decision: ToolCallApprovalDecision) {
    continuation.resume(returning: decision)
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
  private var responseBackgroundTasks: [UUID: UIBackgroundTaskIdentifier] = [:]
  private var cancelledToolCallApprovalIDs: Set<UUID> = []
  private var toolCallingDebugIterations: [UUID: [ConversationDebugToolIteration]] = [:]

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
  @Published var endpointVoices: [UUID: [String]] = [:]
  @Published var localMLXModelIDs: [String] = []
  @Published var mcpStatuses: [UUID: EndpointConnectionState] = [:]
  @Published var mcpTools: [UUID: [MCPToolDescriptor]] = [:]
  @Published private(set) var toolCallApprovalRequests: [ToolCallApprovalRequest] = []
  /// Cached Apple Intelligence availability message; nil means available.
  /// Refreshed on app launch and on scene activation, not per-render.
  @Published var appleAvailabilityReport: AppleFoundationAvailabilityReport
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
  private var dataGeneration = 0

  init(
    persistence: PersistenceStore = PersistenceStore(),
    streamingTextStore: StreamingTextStore = StreamingTextStore()
  ) {
    self.persistence = persistence
    self.streamingTextStore = streamingTextStore
    settings = persistence.loadSettings()
    conversations = []
    appleAvailabilityReport = .checking
    appleAvailabilityMessage = nil
    refreshLocalMLXModels()
    startFreshConversationForLaunch()
    Task { await loadStartupData() }
    refreshConfiguredEndpointsInBackground()
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
    let generation = dataGeneration
    await Task.yield()

    let persistence = self.persistence
    let summaries = await Task.detached(priority: .userInitiated) {
      persistence.loadConversationSummaries()
    }.value
    guard generation == dataGeneration else { return }
    mergeLoadedSummaries(summaries)

    let availabilityTask = Task.detached(priority: .utility) {
      AppleFoundationProvider.availabilityReport
    }
    let loadedConversations = await Task.detached(priority: .userInitiated) {
      persistence.loadConversations()
    }.value

    guard generation == dataGeneration else { return }
    mergeLoadedConversations(loadedConversations)
    let availabilityReport = await availabilityTask.value
    appleAvailabilityReport = availabilityReport
    appleAvailabilityMessage = availabilityReport.unavailableMessage
  }

  private func makeNewConversation() -> Conversation {
    let defaultProvider = settings.defaultProviderConfiguration
    var conversation = Conversation()
    conversation.provider = defaultProvider.provider
    if defaultProvider.provider == .mlx {
      conversation.modelID = availableLocalMLXModelID(preferred: defaultProvider.modelID) ?? ""
    } else {
      conversation.modelID = defaultProvider.modelID
    }
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

  func loadStoredConversationsForSearch() async {
    guard !hasLoadedPersistedConversations else { return }
    let generation = dataGeneration
    let persistence = self.persistence
    let loadedConversations = await Task.detached(priority: .userInitiated) {
      persistence.loadConversations()
    }.value
    guard generation == dataGeneration, !hasLoadedPersistedConversations else { return }
    mergeLoadedConversations(loadedConversations)
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
      endResponseBackgroundTask(for: id)
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

  func factoryReset() {
    dataGeneration += 1
    for task in responseTasks.values {
      task.cancel()
    }
    responseTasks.removeAll()
    endAllResponseBackgroundTasks()
    respondingConversationIDs.removeAll()
    conversationDrafts.removeAll()
    streamingTextStore.removeAll()
    settings = .defaults
    conversations.removeAll()
    conversationSummaries.removeAll()
    selectedConversationID = nil
    selectedConversationIDs.removeAll()
    endpointStatuses.removeAll()
    endpointModels.removeAll()
    endpointVoices.removeAll()
    mcpStatuses.removeAll()
    mcpTools.removeAll()
    errorMessage = nil
    isUpdatingMemory = false
    isCompacting = false
    hasLoadedPersistedConversations = true
    pendingConversationSave = false
    dirtyConversationIDsBeforeLoad.removeAll()
    deletedConversationIDsBeforeLoad.removeAll()
    rebuildConversationIndexes()
    persistence.factoryReset()
    createInitialConversationIfNeeded()
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
      endResponseBackgroundTask(for: id)
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
    cloned.lastContextSignature = nil
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
    let context = await ContextBuilder.build(
      input: prompt,
      conversation: conversation,
      settings: settings,
      locationService: { self.locationService }
    )

    guard let i = indexedConversationIndex(for: conversationID) else { return }
    switch mode {
    case .append:
      let userMessage = ChatMessage(role: .user, text: prompt)
      conversations[i].messages.append(userMessage)
      conversations[i].refreshTitle(from: prompt)
    case .replaceLastUser:
      if let lastIndex = conversations[i].messages.indices.last {
        conversations[i].messages[lastIndex].text = prompt
      }
    }
    conversations[i].lastContextSignature = context.signature
    conversations[i].updatedAt = Date()
    upsertSummary(for: conversations[i])
    saveConversations()

    dispatchAssistantTurn(
      conversationID: conversationID, context: context.text)
  }

  private func dispatchAssistantTurn(conversationID: UUID, context: String) {
    respondingConversationIDs.insert(conversationID)
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        respondingConversationIDs.remove(conversationID)
        responseTasks[conversationID] = nil
        endResponseBackgroundTask(for: conversationID)
        saveConversations()
      }
      await AssistantTurnRunner.run(
        conversationID: conversationID,
        context: context,
        store: self
      )
    }
    responseTasks[conversationID] = task
    beginResponseBackgroundTask(for: conversationID)
  }

  private func beginResponseBackgroundTask(for conversationID: UUID) {
    endResponseBackgroundTask(for: conversationID)
    let taskID = UIApplication.shared.beginBackgroundTask(withName: "PocketMai assistant response")
    {
      [weak self] in
      Task { @MainActor [weak self] in
        self?.handleResponseBackgroundTaskExpired(for: conversationID)
      }
    }
    guard taskID != .invalid else { return }
    responseBackgroundTasks[conversationID] = taskID
  }

  private func handleResponseBackgroundTaskExpired(for conversationID: UUID) {
    responseTasks[conversationID]?.cancel()
    endResponseBackgroundTask(for: conversationID)
  }

  private func endResponseBackgroundTask(for conversationID: UUID) {
    guard let taskID = responseBackgroundTasks.removeValue(forKey: conversationID),
      taskID != .invalid
    else {
      return
    }
    UIApplication.shared.endBackgroundTask(taskID)
  }

  private func endAllResponseBackgroundTasks() {
    let taskIDs = responseBackgroundTasks.values.filter { $0 != .invalid }
    responseBackgroundTasks.removeAll()
    for taskID in taskIDs {
      UIApplication.shared.endBackgroundTask(taskID)
    }
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

  func previewConversationImport(from url: URL) async throws -> ConversationImportPreview {
    let access = url.startAccessingSecurityScopedResource()
    defer {
      if access {
        url.stopAccessingSecurityScopedResource()
      }
    }
    guard let data = try? Data(contentsOf: url) else {
      throw ConversationImportError.unreadableFile
    }
    let envelope = try Self.decodeConversationImportEnvelope(from: data)

    await loadStoredConversationsForSearch()
    return ConversationImportPreview(
      envelope: envelope,
      conflict: conversationImportConflict(for: envelope.conversation),
      existingTitles: existingConversationImportTitles()
    )
  }

  func importConversation(
    _ preview: ConversationImportPreview,
    resolution: ConversationImportResolution
  ) throws {
    switch resolution {
    case .create(let rawTitle):
      let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty else { throw ConversationImportError.titleRequired }
      if let existing = conversationWithTitle(title) {
        throw ConversationImportError.titleAlreadyExists(existing.displayTitle)
      }

      discardSelectedDisposableConversation()
      var conversation = preview.conversation
      conversation.id = uniqueConversationID()
      conversation.title = title
      conversation.isPinned = false
      conversation.updatedAt = Date()
      conversations.insert(conversation, at: 0)
      sortConversations()
      selectedConversationID = conversation.id
      selectedConversationIDs.removeAll()
      saveConversations()
    case .updateExisting:
      guard let conflict = preview.conflict, !conflict.contentsMatch else {
        throw ConversationImportError.updateNotAvailable
      }
      if selectedConversationID != conflict.existingID {
        discardSelectedDisposableConversation()
      }
      guard let index = indexedConversationIndex(for: conflict.existingID) else {
        throw ConversationImportError.missingExistingConversation
      }

      var conversation = preview.conversation
      conversation.id = conflict.existingID
      conversation.title = conversations[index].title
      conversation.isPinned = conversations[index].isPinned
      conversation.isArchived = conversations[index].isArchived
      conversation.updatedAt = Date()
      conversations[index] = conversation
      sortConversations()
      selectedConversationID = conversation.id
      selectedConversationIDs.removeAll()
      saveConversations()
    }
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
    case .markdown, .json, .debug:
      return writeConversationExport(
        conversation: conversation,
        format: format,
        content: export(conversation: conversation, format: format))
    case .epub:
      return exportCurrentConversationEPUB()
    case .audio:
      return nil
    }
  }

  func exportCurrentConversationDebugJSONFile() async -> URL? {
    guard let conversation = currentConversation else { return nil }
    let latestPrompt =
      conversation.messages.last(where: { $0.role == .user })
      .map { MessageContentFilter.promptSafeText(from: $0.text) } ?? ""
    let context = await ContextBuilder.build(
      input: latestPrompt,
      conversation: conversation,
      settings: settings,
      locationService: { self.locationService })
    return writeConversationExport(
      conversation: conversation,
      format: .debug,
      content: export(conversation: conversation, format: .debug, debugContext: context))
  }

  private func writeConversationExport(
    conversation: Conversation,
    format: ConversationExportFormat,
    content: String
  ) -> URL? {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PocketMaiExports",
      isDirectory: true
    )
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let filename =
        exportFilename(for: conversation)
        + (format == .debug ? "-debug" : "")
      let url = directory.appendingPathComponent(filename).appendingPathExtension(
        format.fileExtension)
      try content.write(to: url, atomically: true, encoding: .utf8)
      return url
    } catch {
      errorMessage = "Could not export \(format.displayName): \(error.localizedDescription)"
      return nil
    }
  }

  func clearToolCallingDebugIterations(conversationID: UUID, assistantMessageID: UUID) {
    toolCallingDebugIterations[conversationID, default: []].removeAll {
      $0.assistantMessageID == assistantMessageID
    }
  }

  func appendToolCallingDebugIteration(
    _ iteration: ConversationDebugToolIteration,
    conversationID: UUID
  ) {
    toolCallingDebugIterations[conversationID, default: []].append(iteration)
  }

  func saveSettings() {
    persistence.saveSettings(settings)
  }

  var activeToolCallApprovalRequest: ToolCallApprovalRequest? {
    toolCallApprovalRequests.first
  }

  func requestToolCallApproval(
    call: ParsedToolCall,
    definitions: [ToolDefinition],
    mode: ToolCallingMode,
    conversationID: UUID
  ) async -> ToolCallApprovalDecision {
    guard !settings.yoloModeEnabled else { return .approved(call) }

    let normalizedCall = ToolAgentRegistry.normalized(call: call, definitions: definitions)
    let requestID = UUID()
    let conversationTitle = conversation(withID: conversationID)?.displayTitle
    let originalText = AgentTooling.editableToolCallText(for: normalizedCall, mode: mode)

    return await withTaskCancellationHandler(
      operation: {
        await withCheckedContinuation { continuation in
          if cancelledToolCallApprovalIDs.remove(requestID) != nil {
            continuation.resume(returning: .cancelled)
            return
          }
          let request = ToolCallApprovalRequest(
            id: requestID,
            callName: normalizedCall.name,
            originalText: originalText,
            mode: mode,
            definitions: definitions,
            conversationTitle: conversationTitle,
            continuation: continuation
          )
          toolCallApprovalRequests.append(request)
        }
      },
      onCancel: {
        Task { @MainActor [weak self] in
          guard let self else { return }
          if !self.resolveToolCallApproval(id: requestID, decision: .cancelled) {
            self.cancelledToolCallApprovalIDs.insert(requestID)
          }
        }
      }
    )
  }

  @discardableResult
  func approveToolCall(id: UUID, editedText: String) -> String? {
    guard let request = toolCallApprovalRequests.first(where: { $0.id == id }) else {
      return "This tool call is no longer pending."
    }
    switch parseApprovedToolCall(editedText, request: request) {
    case .success(let call):
      resolveToolCallApproval(id: id, decision: .approved(call))
      return nil
    case .failure(let message):
      return message
    }
  }

  func cancelToolCallApproval(id: UUID) {
    _ = resolveToolCallApproval(id: id, decision: .cancelled)
  }

  func interruptToolCallApproval(id: UUID) {
    _ = resolveToolCallApproval(id: id, decision: .interrupted)
  }

  @discardableResult
  private func resolveToolCallApproval(id: UUID, decision: ToolCallApprovalDecision) -> Bool {
    guard let index = toolCallApprovalRequests.firstIndex(where: { $0.id == id }) else {
      return false
    }
    let request = toolCallApprovalRequests.remove(at: index)
    request.resume(returning: decision)
    return true
  }

  private func parseApprovedToolCall(
    _ text: String,
    request: ToolCallApprovalRequest
  ) -> ToolCallApprovalParseResult {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .failure("Tool call text cannot be empty.")
    }
    let calls = approvalToolCalls(in: trimmed, request: request)
    guard calls.count == 1 else {
      if calls.isEmpty {
        return .failure("Tool call text must contain one valid tool call.")
      }
      return .failure("Tool call text must contain only one tool call.")
    }

    let normalizedCall = ToolAgentRegistry.normalized(
      call: calls[0],
      definitions: request.definitions
    )
    guard request.definitions.contains(where: { $0.name == normalizedCall.name }) else {
      return .failure("Unknown tool '\(normalizedCall.name)'.")
    }
    if let error = ToolAgentRegistry.requiredArgumentsError(
      call: normalizedCall,
      definitions: request.definitions)
    {
      return .failure(error)
    }
    return .success(normalizedCall)
  }

  private func approvalToolCalls(
    in text: String,
    request: ToolCallApprovalRequest
  ) -> [ParsedToolCall] {
    ToolAgentRegistry.parseCalls(
      in: text,
      definitions: request.definitions,
      mode: request.mode
    )
  }

  func resetEndpointStatus(_ id: UUID) {
    endpointStatuses[id] = .unknown
    endpointModels[id] = nil
    endpointVoices[id] = nil
  }

  func refreshAppleIntelligenceAvailabilityInBackground() {
    Task { await refreshAppleIntelligenceAvailability() }
  }

  func refreshAppleIntelligenceAvailability() async {
    let report = await Task.detached(priority: .utility) {
      AppleFoundationProvider.availabilityReport
    }.value
    appleAvailabilityReport = report
    appleAvailabilityMessage = report.unavailableMessage
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
    async let modelResult = fetchEndpointModelsResult(endpoint)
    async let voiceResult = fetchEndpointVoicesResult(endpoint)
    let results = await (models: modelResult, voices: voiceResult)

    let models = (try? results.models.get()) ?? []
    let voices = (try? results.voices.get()) ?? []

    if !models.isEmpty || !voices.isEmpty {
      endpointModels[endpoint.id] = models
      endpointVoices[endpoint.id] = voices
      endpointStatuses[endpoint.id] = .available
      if let firstModel = models.first,
        let index = settings.openAIEndpoints.firstIndex(where: { $0.id == endpoint.id }),
        settings.openAIEndpoints[index].defaultModel
          .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        settings.openAIEndpoints[index].defaultModel = firstModel
        saveSettings()
      }
    } else {
      endpointModels[endpoint.id] = nil
      endpointVoices[endpoint.id] = nil
      endpointStatuses[endpoint.id] = .failed(endpointRefreshErrorMessage(results))
    }
  }

  func refreshConfiguredEndpointsInBackground() {
    let endpoints = settings.openAIEndpoints.filter(\.isEnabled)
    guard !endpoints.isEmpty else { return }
    for endpoint in endpoints {
      Task { await refreshEndpoint(endpoint) }
    }
  }

  func refreshLocalMLXModels() {
    localMLXModelIDs = LocalMLXModelCache.listRepositoryIDs()
    normalizeDefaultLocalMLXModelIfNeeded()
  }

  func availableLocalMLXModelID(preferred rawPreferred: String? = nil) -> String? {
    guard !localMLXModelIDs.isEmpty else { return nil }
    let candidates = [rawPreferred, settings.localMLXModelID, AppSettings.localMLXDefaultModelID]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return candidates.first { localMLXModelIDs.contains($0) } ?? localMLXModelIDs.first
  }

  private func normalizeDefaultLocalMLXModelIfNeeded() {
    guard settings.defaultProvider == .mlx else { return }
    let current = normalizedModelID(settings.localMLXModelID)
    let next = availableLocalMLXModelID(preferred: current) ?? ""
    guard current != next else { return }
    settings.localMLXModelID = next
    saveSettings()
  }

  private func fetchEndpointModelsResult(_ endpoint: OpenAIEndpoint) async -> Result<
    [String], Error
  > {
    do {
      return .success(try await OpenAICompatibleProvider.fetchModels(endpoint: endpoint))
    } catch {
      return .failure(error)
    }
  }

  private func fetchEndpointVoicesResult(_ endpoint: OpenAIEndpoint) async -> Result<
    [String], Error
  > {
    do {
      return .success(try await OpenAICompatibleProvider.fetchVoices(endpoint: endpoint))
    } catch {
      return .failure(error)
    }
  }

  private func endpointRefreshErrorMessage(
    _ results: (models: Result<[String], Error>, voices: Result<[String], Error>)
  ) -> String {
    let modelMessage = failureMessage(results.models)
    let voiceMessage = failureMessage(results.voices)
    switch (modelMessage, voiceMessage) {
    case (.some(let model), .some(let voice)):
      return "Models: \(model)\nVoices: \(voice)"
    case (.some(let model), .none):
      return model
    case (.none, .some(let voice)):
      return voice
    case (.none, .none):
      return "The endpoint returned no models or voices."
    }
  }

  private func failureMessage(_ result: Result<[String], Error>) -> String? {
    if case .failure(let error) = result {
      return error.localizedDescription
    }
    return nil
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
      "(?im)^\\s*TOOL_CALL\\s*$[\\s\\S]*?(?:^\\s*END_TOOL_CALL\\s*$|\\z)",
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
    endResponseBackgroundTask(for: removedID)
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

  private static func decodeConversationImportEnvelope(
    from data: Data
  ) throws -> ConversationExportEnvelope {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
      let envelope = try decoder.decode(ConversationExportEnvelope.self, from: data)
      guard envelope.format == ConversationExportEnvelope.format else {
        throw ConversationImportError.invalidJSON
      }
      return envelope
    } catch let error as ConversationImportError {
      throw error
    } catch {
      throw ConversationImportError.invalidJSON
    }
  }

  private func conversationImportConflict(
    for importedConversation: Conversation
  ) -> ConversationImportConflict? {
    let title = importedConversation.displayTitle
    let matchingTitleConversations = conversations.filter {
      !isDisposableNewConversation($0)
        && normalizedConversationTitle($0.displayTitle) == normalizedConversationTitle(title)
    }
    guard !matchingTitleConversations.isEmpty else { return nil }
    if let sameContents = matchingTitleConversations.first(where: {
      conversationContentsMatch($0, importedConversation)
    }) {
      return ConversationImportConflict(
        existingID: sameContents.id,
        existingTitle: sameContents.displayTitle,
        contentsMatch: true
      )
    }
    guard let differentContents = matchingTitleConversations.first else { return nil }
    return ConversationImportConflict(
      existingID: differentContents.id,
      existingTitle: differentContents.displayTitle,
      contentsMatch: false
    )
  }

  private func conversationWithTitle(_ title: String) -> Conversation? {
    let normalizedTitle = normalizedConversationTitle(title)
    return conversations.first {
      !isDisposableNewConversation($0)
        && normalizedConversationTitle($0.displayTitle) == normalizedTitle
    }
  }

  private func existingConversationImportTitles() -> [String] {
    conversations.filter { !isDisposableNewConversation($0) }.map(\.displayTitle)
  }

  private func normalizedConversationTitle(_ title: String) -> String {
    title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private func conversationContentsMatch(_ lhs: Conversation, _ rhs: Conversation) -> Bool {
    normalizedConversationTitle(lhs.displayTitle) == normalizedConversationTitle(rhs.displayTitle)
      && lhs.createdAt == rhs.createdAt
      && lhs.provider == rhs.provider
      && lhs.modelID == rhs.modelID
      && lhs.endpointID == rhs.endpointID
      && lhs.systemPromptID == rhs.systemPromptID
      && lhs.enabledTools == rhs.enabledTools
      && lhs.usesStreaming == rhs.usesStreaming
      && lhs.disabledMCPTools == rhs.disabledMCPTools
      && lhs.reasoningLevel == rhs.reasoningLevel
      && lhs.showThinking == rhs.showThinking
      && lhs.lastContextSignature == rhs.lastContextSignature
      && messageContentsMatch(lhs.messages, rhs.messages)
  }

  private func messageContentsMatch(_ lhs: [ChatMessage], _ rhs: [ChatMessage]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy { lhsMessage, rhsMessage in
      lhsMessage.role == rhsMessage.role
        && lhsMessage.text == rhsMessage.text
        && lhsMessage.createdAt == rhsMessage.createdAt
    }
  }

  private func uniqueConversationID() -> UUID {
    var id = UUID()
    while conversationIndexByID[id] != nil {
      id = UUID()
    }
    return id
  }

  private func export(
    conversation: Conversation,
    format: ConversationExportFormat,
    debugContext: ContextBuilder.Output? = nil
  ) -> String {
    switch format {
    case .markdown:
      return conversation.messages.map { message in
        "## \(message.role.displayName)\n\n\(message.text)"
      }.joined(separator: "\n\n")
    case .json, .debug:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      let envelope = ConversationExportEnvelope(
        conversation: conversation,
        toolCallingDebug: format == .debug
          ? toolCallingDebug(for: conversation, context: debugContext) : nil)
      guard let data = try? encoder.encode(envelope),
        let json = String(data: data, encoding: .utf8)
      else {
        return "{}"
      }
      return json
    case .epub, .audio:
      return ""
    }
  }

  private func toolCallingDebug(
    for conversation: Conversation,
    context: ContextBuilder.Output?
  ) -> ConversationToolCallingDebug {
    let fullDefinitions = ToolAgentRegistry.definitions(
      for: conversation,
      settings: settings,
      mcpTools: mcpTools)
    let visibleDefinitions = ToolAgentRegistry.visibleDefinitions(
      for: conversation,
      settings: settings,
      mcpTools: mcpTools)
    let providerNativeToolCalling =
      settings.toolCallingMode == .native
      && conversation.provider.supportsNativeToolCalling
      && !visibleDefinitions.isEmpty
    let effectiveMode =
      providerNativeToolCalling
      ? ToolCallingMode.native : settings.toolCallingMode.textProtocolFallback(for: conversation.provider)
    let textToolPrompt =
      providerNativeToolCalling
      ? "" : ToolAgentRegistry.promptDescription(for: visibleDefinitions, mode: effectiveMode)
    let toolPrompt = textToolPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let nativeToolNames: [String] = {
      guard providerNativeToolCalling else { return [] }
      let resolver = AgentToolNameResolver(tools: visibleDefinitions)
      return visibleDefinitions.map { resolver.apiName(for: $0.name) }
    }()
    let contextPrompt = context?.text ?? ""
    let requestContext = [contextPrompt, toolPrompt]
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
    let systemPrompt = PromptComposer.systemPrompt(settings: settings, conversation: conversation)
    let providerSystemPrompt =
      requestContext.isEmpty ? systemPrompt : "\(systemPrompt)\n\n## Context\n\(requestContext)"
    let hasToolCalling = !visibleDefinitions.isEmpty
    let applePrompt = PromptComposer.applePrompt(
      conversation: conversation,
      settings: settings,
      context: requestContext,
      hasTools: hasToolCalling)
    let messageIDs = Set(conversation.messages.map(\.id))
    let runtimeIterations =
      (toolCallingDebugIterations[conversation.id] ?? [])
      .filter { messageIDs.contains($0.assistantMessageID) }
    let storedIterations = debugToolIterations(in: conversation)

    return ConversationToolCallingDebug(
      selectedMode: settings.toolCallingMode.rawValue,
      selectedModeDisplayName: settings.toolCallingMode.displayName,
      effectiveMode: effectiveMode.rawValue,
      effectiveModeDisplayName: effectiveMode.displayName,
      textProtocolFallback: settings.toolCallingMode.textProtocolFallback(for: conversation.provider)
        .rawValue,
      providerNativeToolCalling: providerNativeToolCalling,
      toolCatalogInlinedInPrompt: !providerNativeToolCalling && hasToolCalling,
      nativeToolNames: nativeToolNames,
      yoloModeEnabled: settings.yoloModeEnabled,
      useToolProxy: settings.useToolProxy,
      contextWindowMode: settings.contextWindowMode.rawValue,
      contextWindowMessageLimit: settings.contextWindowMode.messageLimit,
      enabledTools: conversation.enabledTools.map(\.rawValue).sorted(),
      disabledMCPTools: Array(conversation.disabledMCPTools).sorted(),
      mcpServers: settings.mcpServers.map { server in
        ConversationDebugMCPServer(
          id: server.id,
          name: server.name,
          isEnabled: server.isEnabled,
          hasValidScheme: server.hasValidScheme)
      },
      fullToolDefinitions: debugDefinitions(fullDefinitions),
      visibleToolDefinitions: debugDefinitions(visibleDefinitions),
      toolPrompt: toolPrompt,
      contextPrompt: contextPrompt,
      contextSignature: context?.signature ?? "",
      lastStoredContextSignature: conversation.lastContextSignature,
      systemPrompt: systemPrompt,
      providerSystemPrompt: providerSystemPrompt,
      applePrompt: applePrompt,
      promptMessages: debugPromptMessages(
        conversation: conversation,
        systemPrompt: providerSystemPrompt,
        messageLimit: settings.contextWindowMode.messageLimit),
      iterations: runtimeIterations.isEmpty ? storedIterations : runtimeIterations,
      notes: [
        "Debug prompt data is reconstructed at export time from current settings.",
        "Runtime iterations are included for tool loops completed in the current app session.",
        "The original per-iteration provider request payload is not persisted across app launches.",
      ])
  }

  private func debugDefinitions(
    _ definitions: [ToolDefinition]
  ) -> [ConversationDebugToolDefinition] {
    definitions.map { definition in
      ConversationDebugToolDefinition(
        name: definition.name,
        description: definition.description,
        parameters: definition.parameters.map { parameter in
          ConversationDebugToolParameter(
            name: parameter.name,
            type: parameter.type,
            description: parameter.description,
            required: parameter.required)
        },
        inputSchemaJSON: definition.inputSchemaJSON.trimmingCharacters(in: .whitespacesAndNewlines)
          .isEmpty ? nil : definition.inputSchemaJSON)
    }
  }

  private func debugPromptMessages(
    conversation: Conversation,
    systemPrompt: String,
    messageLimit: Int?
  ) -> [ConversationDebugPromptMessage] {
    let limited: [ChatMessage] = {
      if let messageLimit { return Array(conversation.messages.suffix(messageLimit)) }
      return conversation.messages
    }()
    var messages = [ConversationDebugPromptMessage(role: "system", content: systemPrompt)]
    messages.append(
      contentsOf: limited.compactMap { message in
        let content = MessageContentFilter.conversationContextText(from: message.text)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }
        let role: String
        switch message.role {
        case .user:
          role = "user"
        case .assistant:
          role =
            content.range(of: "<tool_run", options: [.caseInsensitive]) == nil
            ? "assistant" : "user"
        case .system:
          role = "system"
        case .tool, .error:
          role = "user"
        }
        return ConversationDebugPromptMessage(role: role, content: content)
      })
    return messages
  }

  private func debugToolIterations(in conversation: Conversation)
    -> [ConversationDebugToolIteration]
  {
    var iterations: [ConversationDebugToolIteration] = []
    for (messageIndex, message) in conversation.messages.enumerated()
    where message.role == .assistant {
      for rawBlock in toolRunBlocks(in: message.text) {
        let parsed = parseToolRunBlock(rawBlock)
        iterations.append(
          ConversationDebugToolIteration(
            assistantMessageID: message.id,
            assistantMessageIndex: messageIndex,
            roundIndex: iterations.count + 1,
            toolName: parsed.toolName,
            argumentsJSON: parsed.argumentsJSON,
            result: parsed.result,
            isError: parsed.result.trimmingCharacters(in: .whitespacesAndNewlines)
              .lowercased()
              .hasPrefix("error:"),
            rawBlock: rawBlock))
      }
    }
    return iterations
  }

  private func toolRunBlocks(in text: String) -> [String] {
    let pattern = "<tool_run\\b[^>]*>[\\s\\S]*?</tool_run\\s*>"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    else { return [] }
    let nsText = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
      .map { nsText.substring(with: $0.range) }
  }

  private func parseToolRunBlock(_ rawBlock: String) -> (
    toolName: String, argumentsJSON: String, result: String
  ) {
    let body =
      rawBlock
      .replacingOccurrences(
        of: "^<tool_run\\b[^>]*>",
        with: "",
        options: [.regularExpression, .caseInsensitive]
      )
      .replacingOccurrences(
        of: "</tool_run\\s*>$",
        with: "",
        options: [.regularExpression, .caseInsensitive]
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let nsBody = body as NSString
    let headerPattern = #"^([^\n]+?) tool \((.*)\):\s*\n?"#
    guard let regex = try? NSRegularExpression(pattern: headerPattern),
      let match = regex.firstMatch(in: body, range: NSRange(location: 0, length: nsBody.length)),
      match.numberOfRanges == 3
    else {
      return ("unknown", "{}", body)
    }
    let toolName = nsBody.substring(with: match.range(at: 1))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let argumentsJSON = nsBody.substring(with: match.range(at: 2))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let result = nsBody.substring(from: match.range.upperBound)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return (toolName, argumentsJSON, result)
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
