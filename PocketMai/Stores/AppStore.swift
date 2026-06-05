import Combine
import Foundation
import SwiftUI
import UIKit

enum EndpointConnectionState: Equatable, Sendable {
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

  var isAvailable: Bool {
    if case .available = self {
      return true
    }
    return false
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

private enum OpenAPIServerAppError: LocalizedError {
  case emptyPrompt
  case unavailable(String)

  var statusCode: Int {
    switch self {
    case .emptyPrompt:
      return 400
    case .unavailable:
      return 503
    }
  }

  var errorDescription: String? {
    switch self {
    case .emptyPrompt:
      return "The request did not include a prompt or user message."
    case .unavailable(let message):
      return message
    }
  }
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
  private static let openAPIServerSystemPromptID = UUID(
    uuidString: "00000000-0000-0000-0000-000000011434")!

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
  @Published var mcpResources: [UUID: [MCPResourceDescriptor]] = [:]
  @Published private(set) var toolCallApprovalRequests: [ToolCallApprovalRequest] = []
  /// Cached Apple Intelligence availability message; nil means available.
  /// Refreshed on app launch and on scene activation, not per-render.
  @Published var appleAvailabilityReport: AppleFoundationAvailabilityReport
  @Published var appleAvailabilityMessage: String?
  @Published var openAPIServerState: OpenAPIServerRuntimeState = .stopped

  let streamingTextStore: StreamingTextStore
  lazy var locationService = LocationService()
  private let responseHaptics = ResponseHaptics()
  private let openAPIServer = OpenAPIServer()
  private let persistence: PersistenceStore
  private var conversationDrafts: [UUID: String] = [:]
  private var conversationIndexByID: [UUID: Int] = [:]
  private var hasLoadedPersistedConversations = false
  private var pendingConversationSave = false
  private var dirtyConversationIDsBeforeLoad: Set<UUID> = []
  private var deletedConversationIDsBeforeLoad: Set<UUID> = []
  private var launchPlaceholderConversationID: UUID?
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

  var appleIntelligenceIsAvailable: Bool {
    appleAvailabilityReport.isAvailable
  }

  var effectiveDefaultProviderConfiguration:
    (provider: ProviderKind, endpointID: UUID?, modelID: String)
  {
    let configuration = settings.defaultProviderConfiguration
    guard configuration.provider == .apple, !appleIntelligenceIsAvailable else {
      return configuration
    }
    return (.mlx, nil, settings.localMLXModelID)
  }

  func newConversation() {
    let inheritedLanguageOverride = currentConversation?.effectiveLanguageOverrideIdentifier
    if let current = currentConversation,
      current.messages.isEmpty
    {
      selectedConversationIDs.removeAll()
      if isDisposableNewConversation(current),
        !conversationUsesNewConversationDefaults(current)
      {
        discardSelectedDisposableConversation()
        createAndSelectNewConversation(languageOverrideIdentifier: inheritedLanguageOverride)
      }
      return
    }
    discardSelectedDisposableConversation()
    createAndSelectNewConversation(languageOverrideIdentifier: inheritedLanguageOverride)
  }

  private func startFreshConversationForLaunch() {
    let conversation = makeNewConversation()
    launchPlaceholderConversationID = conversation.id
    conversations.insert(conversation, at: 0)
    sortConversations()
    setSelectedConversationID(conversation.id, remember: false)
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

    let deviceOnlyApple = settings.airplaneModeEnabled
    let availabilityTask = Task.detached(priority: .utility) {
      AppleFoundationProvider.availabilityReport(deviceOnly: deviceOnlyApple)
    }
    let loadedConversations = await Task.detached(priority: .userInitiated) {
      persistence.loadConversations()
    }.value

    guard generation == dataGeneration else { return }
    mergeLoadedConversations(loadedConversations)
    applyStartupConversationSelectionIfNeeded()
    let availabilityReport = await availabilityTask.value
    applyAppleAvailabilityReport(availabilityReport)
  }

  private func applyStartupConversationSelectionIfNeeded() {
    let placeholderID = launchPlaceholderConversationID
    launchPlaceholderConversationID = nil
    guard settings.startupBehavior == .lastConversation,
      selectedConversationID == placeholderID,
      startupPlaceholderIsStillDisposable(placeholderID),
      let id = startupConversationID(excluding: placeholderID)
    else {
      return
    }
    setSelectedConversationID(id)
    selectedConversationIDs.removeAll()
    _ = discardDisposableConversation(id: placeholderID)
  }

  private func startupPlaceholderIsStillDisposable(_ id: UUID?) -> Bool {
    guard let id,
      let conversation = conversation(withID: id)
    else {
      return true
    }
    return isDisposableNewConversation(conversation)
  }

  private func startupConversationID(excluding excludedID: UUID?) -> UUID? {
    if let rememberedID = settings.lastSelectedConversationID,
      let remembered = conversation(withID: rememberedID),
      isStartupConversationCandidate(remembered, excluding: excludedID, allowArchived: true)
    {
      return rememberedID
    }

    return
      conversations
      .filter { isStartupConversationCandidate($0, excluding: excludedID, allowArchived: false) }
      .max { lhs, rhs in
        if lhs.updatedAt != rhs.updatedAt {
          return lhs.updatedAt < rhs.updatedAt
        }
        return lhs.createdAt < rhs.createdAt
      }?
      .id
  }

  private func isStartupConversationCandidate(
    _ conversation: Conversation,
    excluding excludedID: UUID?,
    allowArchived: Bool
  ) -> Bool {
    conversation.id != excludedID
      && !conversation.messages.isEmpty
      && (allowArchived || !conversation.isArchived)
  }

  private func makeNewConversation() -> Conversation {
    let defaultProvider = effectiveDefaultProviderConfiguration
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
    conversation.enabledMCPServers = settings.defaultEnabledMCPServers
    conversation.enabledMCPTools = settings.defaultEnabledMCPTools
    conversation.usesStreaming = settings.streamByDefault
    conversation.showThinking = settings.showThinkingByDefault
    return conversation
  }

  private func createAndSelectNewConversation(languageOverrideIdentifier: String? = nil) {
    var conversation = makeNewConversation()
    conversation.languageOverrideIdentifier = Conversation.normalizedLanguageOverride(
      languageOverrideIdentifier)
    conversations.insert(conversation, at: 0)
    sortConversations()
    setSelectedConversationID(conversation.id)
    selectedConversationIDs.removeAll()
    saveConversations()
  }

  private func setSelectedConversationID(_ id: UUID?, remember: Bool = true) {
    selectedConversationID = id
    if remember {
      rememberSelectedConversationID(id)
    }
  }

  private func rememberSelectedConversationID(_ id: UUID?) {
    guard settings.lastSelectedConversationID != id else { return }
    settings.lastSelectedConversationID = id
    saveSettings()
  }

  private func conversationUsesNewConversationDefaults(_ conversation: Conversation) -> Bool {
    let defaults = makeNewConversation()
    return conversation.provider == defaults.provider
      && conversation.endpointID == defaults.endpointID
      && normalizedModelID(conversation.modelID) == normalizedModelID(defaults.modelID)
      && conversation.systemPromptID == defaults.systemPromptID
      && conversation.toolsEnabled == defaults.toolsEnabled
      && conversation.enabledTools == defaults.enabledTools
      && conversation.enabledMCPServers == defaults.enabledMCPServers
      && conversation.enabledMCPTools == defaults.enabledMCPTools
      && conversation.usesStreaming == defaults.usesStreaming
      && conversation.showThinking == defaults.showThinking
      && conversation.reasoningLevel == defaults.reasoningLevel
      && conversation.disabledMCPTools == defaults.disabledMCPTools
      && conversation.effectiveLanguageOverrideIdentifier
        == defaults.effectiveLanguageOverrideIdentifier
  }

  private func normalizedModelID(_ modelID: String) -> String {
    modelID.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func selectConversation(id: UUID) async {
    let previousID = selectedConversationID
    await ensureConversationLoaded(id)
    guard indexedConversationIndex(for: id) != nil else { return }
    setSelectedConversationID(id)
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
    normalizeUnavailableAppleProviderIfNeeded()
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

  func setCurrentConversationLanguageOverride(_ identifier: String?) {
    guard currentConversationIndex != nil else { return }
    let normalized = Conversation.normalizedLanguageOverride(identifier)
    updateCurrentConversation { conversation in
      conversation.languageOverrideIdentifier = normalized
    }
    if let normalized {
      settings.recordRecentChatLanguage(normalized)
      saveSettings()
    }
  }

  func deleteMessage(_ message: ChatMessage) {
    guard let index = currentConversationIndex else { return }
    let removedMessages = conversations[index].messages.filter { $0.id == message.id }
    guard !removedMessages.isEmpty else { return }
    conversations[index].messages.removeAll { $0.id == message.id }
    conversations[index].updatedAt = Date()
    upsertSummary(for: conversations[index])
    saveConversations()
    deleteUnreferencedVoiceRecordings(from: removedMessages)
  }

  func clearAllConversations() {
    let archived = conversations.filter(\.isArchived)
    let removedIDs = Set(conversationSummaries.filter { !$0.isArchived }.map(\.id))
    let removedMessages = voiceRecordingMessages(in: removedIDs)
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
    setSelectedConversationID(nil)
    selectedConversationIDs.removeAll()
    saveConversations()
    deleteUnreferencedVoiceRecordings(from: removedMessages)
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
    setSelectedConversationID(nil)
    selectedConversationIDs.removeAll()
    endpointStatuses.removeAll()
    endpointModels.removeAll()
    endpointVoices.removeAll()
    mcpStatuses.removeAll()
    mcpTools.removeAll()
    mcpResources.removeAll()
    Task { await MCPHTTPClient.resetAllSessions() }
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
    guard !cleaned.isEmpty || !message.attachments.isEmpty else { return }
    _ = await send(prompt: cleaned, attachments: message.attachments)
  }

  func restartFromScratch(with message: ChatMessage) async {
    guard !isResponding, let index = currentConversationIndex else { return }
    guard let source = restartSourceMessage(for: message),
      let prompt = restartPrompt(from: source)
    else { return }

    let removedMessages = conversations[index].messages
    conversations[index].messages.removeAll()
    conversations[index].title = "New chat"
    conversations[index].updatedAt = Date()
    upsertSummary(for: conversations[index])
    saveConversations()
    deleteUnreferencedVoiceRecordings(from: removedMessages)

    _ = await send(prompt: prompt, attachments: source.attachments)
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
      conversation.toolsEnabled = source.toolsEnabled
      conversation.enabledTools = source.enabledTools
      conversation.enabledMCPServers = source.enabledMCPServers
      conversation.enabledMCPTools = source.enabledMCPTools
      conversation.usesStreaming = source.usesStreaming
      conversation.disabledMCPTools = source.disabledMCPTools
      conversation.reasoningLevel = source.reasoningLevel
      conversation.showThinking = source.showThinking
      conversation.languageOverrideIdentifier = source.effectiveLanguageOverrideIdentifier
    }
    conversations.insert(conversation, at: 0)
    sortConversations()
    setSelectedConversationID(conversation.id)
    selectedConversationIDs.removeAll()
    saveConversations()

    _ = await send(prompt: prompt, attachments: message.attachments)
  }

  private func restartPrompt(from message: ChatMessage) -> String? {
    let visible = MessageContentFilter.render(message.text).visibleText
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let fallback = MessageContentFilter.promptSafeText(from: message.text)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let prompt = visible.isEmpty ? fallback : visible
    return prompt.isEmpty && message.attachments.isEmpty ? nil : prompt
  }

  private func restartSourceMessage(for message: ChatMessage) -> ChatMessage? {
    if message.role == .user {
      return message
    }
    guard let location = messageLocation(for: message.id) else {
      return message
    }
    let messages = conversations[location.conversationIndex].messages
    guard location.messageIndex > 0 else {
      return message
    }
    return messages[..<location.messageIndex].last(where: { $0.role == .user }) ?? message
  }

  func deleteConversations(_ ids: Set<UUID>) {
    let removedMessages = voiceRecordingMessages(in: ids)
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
      setSelectedConversationID(conversations.first?.id)
    }
    if conversations.isEmpty {
      setSelectedConversationID(nil)
      createInitialConversationIfNeeded()
    }
    saveConversations()
    deleteUnreferencedVoiceRecordings(from: removedMessages)
  }

  private func voiceRecordingMessages(in conversationIDs: Set<UUID>) -> [ChatMessage] {
    guard !conversationIDs.isEmpty else { return [] }
    return conversationIDs.flatMap { id -> [ChatMessage] in
      if let index = indexedConversationIndex(for: id) {
        return conversations[index].messages
      }
      return persistence.loadConversation(id: id)?.messages ?? []
    }
  }

  private func deleteUnreferencedVoiceRecordings(from messages: [ChatMessage]) {
    let candidates = Set(messages.compactMap(Self.normalizedVoiceRecordingFilename))
    guard !candidates.isEmpty else { return }

    let referenced = referencedVoiceRecordingFilenames()
    for filename in candidates.subtracting(referenced) {
      guard let url = PocketMaiDirectories.voiceRecordingURL(filename: filename) else { continue }
      try? FileManager.default.removeItem(at: url)
    }
  }

  private func referencedVoiceRecordingFilenames() -> Set<String> {
    var filenames = Set(
      conversations.flatMap { conversation in
        conversation.messages.compactMap(Self.normalizedVoiceRecordingFilename)
      })
    let loadedIDs = Set(conversations.map(\.id))
    for summary in conversationSummaries where !loadedIDs.contains(summary.id) {
      guard let conversation = persistence.loadConversation(id: summary.id) else { continue }
      filenames.formUnion(conversation.messages.compactMap(Self.normalizedVoiceRecordingFilename))
    }
    return filenames
  }

  private static func normalizedVoiceRecordingFilename(from message: ChatMessage) -> String? {
    guard
      let filename = message.voiceRecordingFilename?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      PocketMaiDirectories.voiceRecordingURL(filename: filename) != nil
    else {
      return nil
    }
    return filename
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
      ChatMessage(
        id: UUID(),
        role: $0.role,
        text: $0.text,
        createdAt: $0.createdAt,
        voiceRecordingFilename: $0.voiceRecordingFilename,
        attachments: $0.attachments)
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
    setSelectedConversationID(cloned.id)
    saveConversations()
  }

  func effectiveConversationSettings(for conversation: Conversation?) -> ConversationSettings {
    settings.conversation.applyingLanguageOverride(from: conversation)
  }

  func effectiveToolSettings(for conversation: Conversation?) -> NativeToolSettings {
    var toolSettings = settings.toolSettings.applyingLanguageOverride(from: conversation)
    if settings.airplaneModeEnabled {
      toolSettings.voices.user = toolSettings.voices.user.withoutOnlineProvider()
      toolSettings.voices.assistant = toolSettings.voices.assistant.withoutOnlineProvider()
    }
    return toolSettings
  }

  func effectiveShowThinking(for conversation: Conversation?) -> Bool {
    guard settings.showThinkingByDefault else { return false }
    return conversation?.showThinking ?? settings.showThinkingByDefault
  }

  func togglePin(_ conversation: Conversation) {
    guard let index = indexedConversationIndex(for: conversation.id) else { return }
    conversations[index].isPinned.toggle()
    conversations[index].updatedAt = Date()
    sortConversations()
    saveConversations()
  }

  func send(
    prompt rawPrompt: String,
    voiceRecordingFilename: String? = nil,
    attachments: [ChatAttachment] = []
  ) async -> Bool {
    let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty || !attachments.isEmpty else { return false }
    if currentConversation == nil {
      newConversation()
    }
    guard let index = currentConversationIndex else { return false }
    let conversationID = conversations[index].id
    normalizeCurrentAppleConversationIfNeeded(index: index)
    guard !respondingConversationIDs.contains(conversationID) else { return false }
    if let message = ChatProviderRouter.preflightMessage(
      conversation: conversations[index], settings: settings)
    {
      errorMessage = message
      return false
    }

    errorMessage = nil
    rememberSelectedConversationID(conversationID)
    await composeUserTurn(
      prompt: prompt,
      conversationID: conversationID,
      mode: .append,
      voiceRecordingFilename: voiceRecordingFilename,
      attachments: attachments)
    return true
  }

  var isOpenAPIServerRunning: Bool {
    openAPIServerState.isRunning
  }

  var isOpenAPIServerActive: Bool {
    openAPIServerState.isActive
  }

  func toggleOpenAPIServer() {
    if isOpenAPIServerActive {
      stopOpenAPIServer()
    } else {
      startOpenAPIServer()
    }
  }

  func startOpenAPIServer() {
    let port = OpenAPIServerSettings.clampedPort(settings.openAPIServer.port)
    if settings.openAPIServer.port != port {
      settings.openAPIServer.port = port
      saveSettings()
    }
    errorMessage = nil
    openAPIServerState = .starting(port)
    openAPIServer.start(
      port: port,
      requestHandler: { [weak self] request in
        guard let self else {
          return .error(statusCode: 503, message: "PocketMai is unavailable.")
        }
        return await self.openAPIServerResponse(for: request)
      },
      stateHandler: { [weak self] state in
        Task { @MainActor [weak self] in
          self?.openAPIServerState = state
          if case .failed(let message) = state {
            self?.errorMessage = "OpenAPI Server: \(message)"
          }
        }
      })
  }

  func stopOpenAPIServer() {
    openAPIServer.stop()
    openAPIServerState = .stopped
  }

  private func openAPIServerResponse(for request: OpenAPIServerHTTPRequest) async
    -> OpenAPIServerHTTPResponse
  {
    if request.method == "OPTIONS" {
      return OpenAPIServerHTTPResponse(
        statusCode: 204, reason: "No Content", headers: [:], body: Data())
    }

    do {
      switch (request.method, request.path) {
      case ("GET", "/"), ("GET", "/health"):
        return .json([
          "status": "ok",
          "server": "PocketMai",
          "model": openAPIServerModelName(),
        ])
      case ("GET", "/api/version"):
        return .json(["version": ConversationExportEnvelope.currentPocketMaiVersion])
      case ("GET", "/api/tags"):
        return ollamaTagsResponse()
      case ("POST", "/api/show"):
        return ollamaShowResponse()
      case ("POST", "/api/chat"):
        let body = try request.decodedBody(OpenAPIServerOllamaChatRequest.self)
        let input = OpenAPIServerCompletionInput(
          model: body.model,
          messages: body.messages,
          prompt: nil,
          system: nil,
          stream: body.stream ?? true)
        let output = try await completeOpenAPIServerRequest(input)
        return ollamaChatResponse(output: output, stream: input.stream)
      case ("POST", "/api/generate"):
        let body = try request.decodedBody(OpenAPIServerOllamaGenerateRequest.self)
        let input = OpenAPIServerCompletionInput(
          model: body.model,
          messages: [],
          prompt: body.prompt,
          system: body.system,
          stream: body.stream ?? true)
        let output = try await completeOpenAPIServerRequest(input)
        return ollamaGenerateResponse(output: output, stream: input.stream)
      case ("GET", "/v1/models"):
        return openAIModelsResponse()
      case ("POST", "/v1/chat/completions"):
        let body = try request.decodedBody(OpenAPIServerOpenAIChatRequest.self)
        let input = OpenAPIServerCompletionInput(
          model: body.model,
          messages: body.messages,
          prompt: nil,
          system: nil,
          stream: body.stream ?? false)
        let output = try await completeOpenAPIServerRequest(input)
        return openAIChatCompletionsResponse(output: output, stream: input.stream)
      default:
        return .error(statusCode: 404, message: "Unsupported endpoint \(request.path).")
      }
    } catch let error as DecodingError {
      return .error(statusCode: 400, message: "Invalid JSON request: \(error.localizedDescription)")
    } catch let error as OpenAPIServerAppError {
      return .error(statusCode: error.statusCode, message: error.localizedDescription)
    } catch {
      return .error(statusCode: 500, message: error.localizedDescription)
    }
  }

  private func completeOpenAPIServerRequest(_ input: OpenAPIServerCompletionInput) async throws
    -> OpenAPIServerCompletionOutput
  {
    switch settings.openAPIServer.conversationScope {
    case .currentChat:
      return try await completeCurrentChatOpenAPIServerRequest(input)
    case .defaultSettings:
      return try await completeDefaultOpenAPIServerRequest(input)
    }
  }

  private func completeCurrentChatOpenAPIServerRequest(
    _ input: OpenAPIServerCompletionInput
  ) async throws -> OpenAPIServerCompletionOutput {
    guard let conversation = currentConversation else {
      throw OpenAPIServerAppError.unavailable("No selected chat is available.")
    }
    return try await completeIsolatedOpenAPIServerRequest(input, baseConversation: conversation)
  }

  private func completeDefaultOpenAPIServerRequest(
    _ input: OpenAPIServerCompletionInput
  ) async throws -> OpenAPIServerCompletionOutput {
    try await completeIsolatedOpenAPIServerRequest(input, baseConversation: makeNewConversation())
  }

  private func completeIsolatedOpenAPIServerRequest(
    _ input: OpenAPIServerCompletionInput,
    baseConversation: Conversation
  ) async throws -> OpenAPIServerCompletionOutput {
    let allowTools = settings.openAPIServer.allowToolExecution
    let requestSettings = openAPIServerRequestSettings(allowTools: allowTools)
    let conversation = openAPIServerRequestConversation(
      from: baseConversation,
      input: input,
      allowTools: allowTools)
    guard !conversation.messages.isEmpty else { throw OpenAPIServerAppError.emptyPrompt }
    guard !input.latestUserText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw OpenAPIServerAppError.emptyPrompt
    }
    if let message = ChatProviderRouter.preflightMessage(
      conversation: conversation,
      settings: requestSettings)
    {
      throw OpenAPIServerAppError.unavailable(message)
    }

    if allowTools {
      let result = try await AssistantToolLoop.runIsolated(
        conversation: conversation,
        settings: requestSettings,
        baseContext: "",
        store: self)
      return OpenAPIServerCompletionOutput(
        text: result.text,
        model: effectiveModelName(for: conversation),
        toolRuns: result.toolRuns.map {
          OpenAPIServerToolRun(
            name: $0.name,
            argumentsJSON: $0.argumentsJSON,
            result: $0.result,
            isError: $0.isError)
        })
    }

    let request = ChatCompletionRequest(
      conversation: conversation,
      settings: requestSettings,
      context: "",
      assistantMessageID: UUID())
    let text = try await ChatProviderRouter.complete(request: request) { _ in }
    return OpenAPIServerCompletionOutput(
      text: text,
      model: effectiveModelName(for: conversation))
  }

  private func openAPIServerRequestConversation(
    from baseConversation: Conversation,
    input: OpenAPIServerCompletionInput,
    allowTools: Bool
  ) -> Conversation {
    var conversation = baseConversation
    conversation.id = UUID()
    conversation.title = "OpenAPI Server"
    conversation.createdAt = Date()
    conversation.updatedAt = Date()
    conversation.messages = input.chatMessagesForProxy()
    conversation.systemPromptID = Self.openAPIServerSystemPromptID
    conversation.usesStreaming = false
    conversation.isPinned = false
    conversation.isArchived = false
    conversation.lastContextSignature = nil
    if !allowTools {
      conversation.toolsEnabled = false
      conversation.enabledTools = []
      conversation.enabledMCPServers = []
      conversation.enabledMCPTools = []
      conversation.disabledMCPTools = []
    }
    if settings.openAPIServer.allowClientOverrides,
      let model = input.model?.trimmingCharacters(in: .whitespacesAndNewlines),
      !model.isEmpty
    {
      conversation.modelID = model
    }
    return conversation
  }

  private func openAPIServerRequestSettings(allowTools: Bool) -> AppSettings {
    var requestSettings = settings
    requestSettings.systemPrompts = [
      SystemPrompt(
        id: Self.openAPIServerSystemPromptID,
        name: "OpenAPI Server",
        text: "")
    ]
    requestSettings.defaultSystemPromptID = Self.openAPIServerSystemPromptID
    requestSettings.memory = ""
    if !allowTools {
      requestSettings.defaultEnabledTools = []
      requestSettings.defaultEnabledMCPServers = []
      requestSettings.defaultEnabledMCPTools = []
      requestSettings.mcpServers = []
    }
    return requestSettings
  }

  private func ollamaTagsResponse() -> OpenAPIServerHTTPResponse {
    let model = openAPIServerModelName()
    return .json([
      "models": [
        [
          "name": model,
          "model": model,
          "modified_at": openAPIServerTimestamp(),
          "size": 0,
          "digest": "pocketmai",
          "details": [
            "parent_model": "",
            "format": "pocketmai",
            "family": "pocketmai",
            "families": ["pocketmai"],
            "parameter_size": "",
            "quantization_level": "",
          ],
        ]
      ]
    ])
  }

  private func ollamaShowResponse() -> OpenAPIServerHTTPResponse {
    .json([
      "license": "",
      "modelfile": "",
      "parameters": "",
      "template": "",
      "details": [
        "parent_model": "",
        "format": "pocketmai",
        "family": "pocketmai",
        "families": ["pocketmai"],
        "parameter_size": "",
        "quantization_level": "",
      ],
      "model_info": [:],
    ])
  }

  private func ollamaChatResponse(
    output: OpenAPIServerCompletionOutput,
    stream: Bool
  ) -> OpenAPIServerHTTPResponse {
    let timestamp = openAPIServerTimestamp()
    if stream {
      let contentChunk = jsonLine([
        "model": output.model,
        "created_at": timestamp,
        "message": ["role": "assistant", "content": output.text],
        "done": false,
      ])
      var done: [String: Any] = [
        "model": output.model,
        "created_at": timestamp,
        "done": true,
        "done_reason": "stop",
      ]
      addOpenAPIServerToolRuns(output, to: &done)
      let doneChunk = jsonLine(done)
      return .text(
        contentChunk + doneChunk,
        contentType: "application/x-ndjson; charset=utf-8")
    }
    var body: [String: Any] = [
      "model": output.model,
      "created_at": timestamp,
      "message": ["role": "assistant", "content": output.text],
      "done": true,
      "done_reason": "stop",
    ]
    addOpenAPIServerToolRuns(output, to: &body)
    return .json(body)
  }

  private func ollamaGenerateResponse(
    output: OpenAPIServerCompletionOutput,
    stream: Bool
  ) -> OpenAPIServerHTTPResponse {
    let timestamp = openAPIServerTimestamp()
    if stream {
      let contentChunk = jsonLine([
        "model": output.model,
        "created_at": timestamp,
        "response": output.text,
        "done": false,
      ])
      var done: [String: Any] = [
        "model": output.model,
        "created_at": timestamp,
        "response": "",
        "done": true,
        "done_reason": "stop",
      ]
      addOpenAPIServerToolRuns(output, to: &done)
      let doneChunk = jsonLine(done)
      return .text(
        contentChunk + doneChunk,
        contentType: "application/x-ndjson; charset=utf-8")
    }
    var body: [String: Any] = [
      "model": output.model,
      "created_at": timestamp,
      "response": output.text,
      "done": true,
      "done_reason": "stop",
    ]
    addOpenAPIServerToolRuns(output, to: &body)
    return .json(body)
  }

  private func openAIModelsResponse() -> OpenAPIServerHTTPResponse {
    .json([
      "object": "list",
      "data": [
        [
          "id": openAPIServerModelName(),
          "object": "model",
          "created": Int(Date().timeIntervalSince1970),
          "owned_by": "pocketmai",
        ]
      ],
    ])
  }

  private func openAIChatCompletionsResponse(
    output: OpenAPIServerCompletionOutput,
    stream: Bool
  ) -> OpenAPIServerHTTPResponse {
    let id = "chatcmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    let created = Int(Date().timeIntervalSince1970)
    if stream {
      let contentChunk = sseLine([
        "id": id,
        "object": "chat.completion.chunk",
        "created": created,
        "model": output.model,
        "choices": [
          [
            "index": 0,
            "delta": ["role": "assistant", "content": output.text],
            "finish_reason": NSNull(),
          ]
        ],
      ])
      var stop: [String: Any] = [
        "id": id,
        "object": "chat.completion.chunk",
        "created": created,
        "model": output.model,
        "choices": [
          [
            "index": 0,
            "delta": [:],
            "finish_reason": "stop",
          ]
        ],
      ]
      addOpenAPIServerToolRuns(output, to: &stop)
      let stopChunk = sseLine(stop)
      return .text(
        contentChunk + stopChunk + "data: [DONE]\n\n",
        contentType: "text/event-stream; charset=utf-8")
    }
    var body: [String: Any] = [
      "id": id,
      "object": "chat.completion",
      "created": created,
      "model": output.model,
      "choices": [
        [
          "index": 0,
          "message": ["role": "assistant", "content": output.text],
          "finish_reason": "stop",
        ]
      ],
    ]
    addOpenAPIServerToolRuns(output, to: &body)
    return .json(body)
  }

  private func addOpenAPIServerToolRuns(
    _ output: OpenAPIServerCompletionOutput,
    to body: inout [String: Any]
  ) {
    guard !output.toolRuns.isEmpty else { return }
    body["pocketmai_tool_calls"] = output.toolRuns.map {
      [
        "name": $0.name,
        "arguments": $0.argumentsJSON,
        "result": $0.result,
        "is_error": $0.isError,
      ] as [String: Any]
    }
  }

  private func openAPIServerModelName(requested: String? = nil) -> String {
    if settings.openAPIServer.allowClientOverrides,
      settings.openAPIServer.conversationScope == .defaultSettings,
      let requested = requested?.trimmingCharacters(in: .whitespacesAndNewlines),
      !requested.isEmpty
    {
      return requested
    }
    if settings.openAPIServer.conversationScope == .currentChat,
      let conversation = currentConversation
    {
      return effectiveModelName(for: conversation)
    }
    let defaults = makeNewConversation()
    return effectiveModelName(for: defaults)
  }

  private func effectiveModelName(for conversation: Conversation) -> String {
    let model = conversation.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    if !model.isEmpty { return model }
    switch conversation.provider {
    case .apple:
      return "apple-intelligence"
    case .mlx:
      return "mlx-local"
    case .openAICompatible:
      guard
        let endpoint = OpenAICompatibleProvider.selectedEndpoint(
          for: conversation,
          settings: settings)
      else {
        return "openai-compatible"
      }
      let endpointModel = endpoint.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
      return endpointModel.isEmpty ? endpoint.displayName : endpointModel
    }
  }

  private func openAPIServerTimestamp() -> String {
    ISO8601DateFormatter().string(from: Date())
  }

  private func jsonLine(_ object: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
      let text = String(data: data, encoding: .utf8)
    else {
      return #"{"error":"Could not encode JSON."}"# + "\n"
    }
    return text + "\n"
  }

  private func sseLine(_ object: Any) -> String {
    "data: \(jsonLine(object))\n"
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
    let removedMessages = Array(conversations[convIndex].messages.dropFirst(cutoff + 1))
    conversations[convIndex].messages = Array(conversations[convIndex].messages.prefix(cutoff + 1))
    conversations[convIndex].updatedAt = Date()
    upsertSummary(for: conversations[convIndex])
    saveConversations()
    deleteUnreferencedVoiceRecordings(from: removedMessages)

    guard let last = conversations[convIndex].messages.last, last.role == .user else { return }
    let prompt = MessageContentFilter.promptSafeText(from: last.text)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty || !last.attachments.isEmpty else { return }

    if let preflight = ChatProviderRouter.preflightMessage(
      conversation: conversations[convIndex], settings: settings)
    {
      errorMessage = preflight
      return
    }

    errorMessage = nil
    await composeUserTurn(
      prompt: prompt,
      conversationID: conversationID,
      mode: .replaceLastUser,
      voiceRecordingFilename: last.voiceRecordingFilename,
      attachments: last.attachments)
  }

  private enum UserTurnMode {
    case append
    case replaceLastUser
  }

  private func composeUserTurn(
    prompt: String,
    conversationID: UUID,
    mode: UserTurnMode,
    voiceRecordingFilename: String? = nil,
    attachments: [ChatAttachment] = []
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
      let userMessage = ChatMessage(
        role: .user,
        text: prompt,
        voiceRecordingFilename: voiceRecordingFilename,
        attachments: attachments)
      conversations[i].messages.append(userMessage)
      let titleSource = MessageContentFilter.render(prompt).visibleText
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let fallbackTitle = attachments.map(\.displayName).joined(separator: ", ")
      conversations[i].refreshTitle(
        from: titleSource.isEmpty
          ? (prompt.isEmpty ? fallbackTitle : prompt)
          : titleSource)
    case .replaceLastUser:
      if let lastIndex = conversations[i].messages.indices.last {
        conversations[i].messages[lastIndex].text = prompt
        conversations[i].messages[lastIndex].voiceRecordingFilename = voiceRecordingFilename
        conversations[i].messages[lastIndex].attachments = attachments
      }
    }
    conversations[i].lastContextSignature = context.signature
    conversations[i].updatedAt = Date()
    upsertSummary(for: conversations[i])
    saveConversations()

    if let idx = indexedConversationIndex(for: conversationID),
      conversations[idx].provider == .mlx,
      settings.mlxAutoCompact
    {
      await autoCompactIfNeeded(conversationID: conversationID)
    }

    dispatchAssistantTurn(
      conversationID: conversationID, context: context.text)
  }

  private func autoCompactIfNeeded(conversationID: UUID) async {
    guard let idx = indexedConversationIndex(for: conversationID) else { return }
    let conversation = conversations[idx]
    guard conversation.messages.count > 3, !isCompacting else { return }

    // Estimate token count at ~3 chars/token; compact when exceeding 75% of the KV window.
    let totalChars = conversation.messages.reduce(0) { $0 + $1.text.count }
    let kvLimit = settings.mlxMaxKVSize.effectiveSize
    guard totalChars > kvLimit * 3 else { return }

    // Summarize all messages except the most recent user message so it is preserved.
    var summaryConversation = conversation
    summaryConversation.messages = Array(conversation.messages.dropLast())
    guard
      let compactReq = await ConversationPromptBuilder.compactRequest(
        conversation: summaryConversation,
        settings: settings)
    else { return }

    isCompacting = true
    defer { isCompacting = false }

    do {
      let summary = try await OneShotPromptRunner.run(compactReq.oneShot, settings: settings)
      let trimmed = MessageContentFilter.promptSafeText(from: summary)
      guard !trimmed.isEmpty else { return }
      guard let i = indexedConversationIndex(for: conversationID) else { return }
      let lastMsg = conversations[i].messages.last
      let removed = Array(conversations[i].messages.dropLast())
      conversations[i].messages = [
        ChatMessage(role: .system, text: "Conversation summary (compacted):\n\n\(trimmed)")
      ]
      if let lastMsg { conversations[i].messages.append(lastMsg) }
      conversations[i].updatedAt = Date()
      upsertSummary(for: conversations[i])
      saveConversations()
      deleteUnreferencedVoiceRecordings(from: removed)
    } catch {
      // Best-effort: proceed without compaction if summarization fails.
    }
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

  func assistantStreamPacketReceived() {
    guard settings.appearance.hapticsEnabled,
      settings.appearance.vibrateOnEveryStreamPacket
    else {
      return
    }
    responseHaptics.streamPacketReceived()
  }

  func assistantResponseCompleted() {
    guard settings.appearance.hapticsEnabled else {
      return
    }
    responseHaptics.responseCompleted()
  }

  func sidebarVisibilitySettled() {
    guard settings.appearance.hapticsEnabled else { return }
    responseHaptics.sidebarVisibilitySettled()
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

  func compactPromptForCurrentConversation() async -> (conversationID: UUID, prompt: String)? {
    guard let conversation = currentConversation else { return nil }
    guard
      let prompt = await ConversationPromptBuilder.compactPrompt(
        conversation: conversation,
        settings: settings)
    else {
      errorMessage = "Nothing to compact yet."
      return nil
    }
    return (conversation.id, prompt)
  }

  func generateCompactSummary(conversationID: UUID, prompt: String) async -> String? {
    guard !isCompacting, !isResponding(in: conversationID) else { return nil }
    guard let index = indexedConversationIndex(for: conversationID) else { return nil }
    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPrompt.isEmpty else {
      errorMessage = "Compact prompt is empty."
      return nil
    }

    let conversation = conversations[index]
    let settingsSnapshot = settings

    isCompacting = true
    defer { isCompacting = false }
    errorMessage = nil

    guard
      let compact = await ConversationPromptBuilder.compactRequest(
        conversation: conversation,
        settings: settingsSnapshot,
        prompt: trimmedPrompt
      )
    else {
      errorMessage = "Nothing to compact yet."
      return nil
    }

    do {
      let summary = try await OneShotPromptRunner.run(compact.oneShot, settings: settingsSnapshot)
      let trimmed = MessageContentFilter.promptSafeText(from: summary)
      guard !trimmed.isEmpty else {
        errorMessage = "Compact returned an empty summary."
        return nil
      }
      return trimmed
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func replaceConversationWithCompactSummary(conversationID: UUID, summary: String) {
    guard let index = indexedConversationIndex(for: conversationID) else { return }
    let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      errorMessage = "Compact summary is empty."
      return
    }

    let removedMessages = conversations[index].messages
    conversations[index].messages = [
      ChatMessage(role: .system, text: "Conversation summary (compacted):\n\n\(trimmed)")
    ]
    conversations[index].updatedAt = Date()
    upsertSummary(for: conversations[index])
    saveConversations()
    deleteUnreferencedVoiceRecordings(from: removedMessages)
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
      setSelectedConversationID(conversation.id)
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

      let replacedMessages = conversations[index].messages
      var conversation = preview.conversation
      conversation.id = conflict.existingID
      conversation.title = conversations[index].title
      conversation.isPinned = conversations[index].isPinned
      conversation.isArchived = conversations[index].isArchived
      conversation.updatedAt = Date()
      conversations[index] = conversation
      sortConversations()
      setSelectedConversationID(conversation.id)
      selectedConversationIDs.removeAll()
      saveConversations()
      deleteUnreferencedVoiceRecordings(from: replacedMessages)
    }
  }

  func exportCurrentConversationEPUB() -> URL? {
    guard let conversation = currentConversation else { return nil }
    return exportConversationEPUB(conversation)
  }

  func exportConversationEPUB(_ conversation: Conversation) -> URL? {
    let data = EPUBExporter.makeEPUB(
      conversation: conversation,
      includeThinking: effectiveShowThinking(for: conversation))
    do {
      let url = try ConversationExportFiles.url(for: conversation, format: .epub)
      try data.write(to: url, options: .atomic)
      return url
    } catch {
      errorMessage = "Could not export ePUB: \(error.localizedDescription)"
      return nil
    }
  }

  func exportCurrentConversationFile(format: ConversationExportFormat) -> URL? {
    guard let conversation = currentConversation else { return nil }
    return exportConversationFile(conversation, format: format)
  }

  func exportConversationFile(id: UUID, format: ConversationExportFormat) async -> URL? {
    await ensureConversationLoaded(id)
    guard let conversation = conversation(withID: id) else { return nil }
    return exportConversationFile(conversation, format: format)
  }

  func exportConversationFile(_ conversation: Conversation, format: ConversationExportFormat)
    -> URL?
  {
    switch format {
    case .markdown, .json, .debug:
      return writeConversationExport(
        conversation: conversation,
        format: format,
        content: export(conversation: conversation, format: format))
    case .epub:
      return exportConversationEPUB(conversation)
    case .audio:
      return nil
    }
  }

  func exportCurrentConversationDebugJSONFile() async -> URL? {
    guard let conversation = currentConversation else { return nil }
    return await exportConversationDebugJSONFile(conversation)
  }

  func exportConversationDebugJSONFile(id: UUID) async -> URL? {
    await ensureConversationLoaded(id)
    guard let conversation = conversation(withID: id) else { return nil }
    return await exportConversationDebugJSONFile(conversation)
  }

  func conversationForExport(id: UUID) async -> Conversation? {
    await ensureConversationLoaded(id)
    return conversation(withID: id)
  }

  func exportConversationDebugJSONFile(_ conversation: Conversation) async -> URL? {
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
    do {
      let url = try ConversationExportFiles.url(
        for: conversation,
        format: format,
        suffix: format == .debug ? "-debug" : "")
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
    await requestToolCallApproval(
      call: call,
      definitions: definitions,
      mode: mode,
      conversationTitle: conversation(withID: conversationID)?.displayTitle)
  }

  func requestToolCallApproval(
    call: ParsedToolCall,
    definitions: [ToolDefinition],
    mode: ToolCallingMode,
    conversationTitle: String?
  ) async -> ToolCallApprovalDecision {
    guard !settings.yoloModeEnabled else { return .approved(call) }

    let normalizedCall = ToolAgentRegistry.normalized(call: call, definitions: definitions)
    let requestID = UUID()
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
    let deviceOnlyApple = settings.airplaneModeEnabled
    let report = await Task.detached(priority: .utility) {
      AppleFoundationProvider.availabilityReport(deviceOnly: deviceOnlyApple)
    }.value
    applyAppleAvailabilityReport(report)
  }

  private func applyAppleAvailabilityReport(_ report: AppleFoundationAvailabilityReport) {
    appleAvailabilityReport = report
    appleAvailabilityMessage = report.unavailableMessage
    normalizeUnavailableAppleProviderIfNeeded()
  }

  func resetMCPStatus(_ id: UUID) {
    mcpStatuses[id] = .unknown
    mcpTools[id] = nil
    mcpResources[id] = nil
    Task { await MCPHTTPClient.resetSession(for: id) }
  }

  func refreshMCP(_ server: MCPServer) async {
    guard !settings.airplaneModeEnabled else {
      mcpTools[server.id] = nil
      mcpResources[server.id] = nil
      mcpStatuses[server.id] = .failed("Airplane mode is enabled.")
      await MCPHTTPClient.resetSession(for: server.id)
      return
    }
    mcpStatuses[server.id] = .checking
    mcpTools[server.id] = nil
    mcpResources[server.id] = nil
    do {
      let catalog = try await MCPHTTPClient.fetchCatalog(server: server)
      mcpTools[server.id] = catalog.tools
      mcpResources[server.id] = catalog.resources
      seedEnabledMCPToolsIfNeeded(serverID: server.id, tools: catalog.tools)
      mcpStatuses[server.id] = .available
    } catch {
      mcpTools[server.id] = nil
      mcpResources[server.id] = nil
      mcpStatuses[server.id] = .failed(error.localizedDescription)
      await MCPHTTPClient.resetSession(for: server.id)
    }
  }

  func refreshEnabledMCPServers(
    for conversation: Conversation,
    settings effectiveSettings: AppSettings? = nil
  ) async {
    let settings = effectiveSettings ?? self.settings
    guard conversation.toolsEnabled else { return }
    guard !settings.airplaneModeEnabled else {
      for server in settings.mcpServers
      where conversation.enabledMCPServers.contains(server.id) {
        mcpTools[server.id] = nil
        mcpResources[server.id] = nil
        mcpStatuses[server.id] = .failed("Airplane mode is enabled.")
        await MCPHTTPClient.resetSession(for: server.id)
      }
      return
    }
    for server in settings.mcpServers
    where server.isEnabled && server.hasValidEndpointURL
      && conversation.enabledMCPServers.contains(server.id)
    {
      await refreshMCP(server)
    }
  }

  func markMCPUnavailable(serverID: UUID, message: String) {
    mcpTools[serverID] = nil
    mcpResources[serverID] = nil
    mcpStatuses[serverID] = .failed(message)
    Task { await MCPHTTPClient.resetSession(for: serverID) }
  }

  private func seedEnabledMCPToolsIfNeeded(serverID: UUID, tools: [MCPToolDescriptor]) {
    guard !tools.isEmpty else { return }
    let prefix = MCPToolSelection.prefix(serverID: serverID)
    let toolKeys = Set(
      tools.map { MCPToolSelection.key(serverID: serverID, toolName: $0.name) })
    var settingsChanged = false
    if settings.defaultEnabledMCPServers.contains(serverID),
      !settings.defaultEnabledMCPTools.contains(where: { $0.hasPrefix(prefix) })
    {
      settings.defaultEnabledMCPTools.formUnion(toolKeys)
      settingsChanged = true
    }

    var conversationsChanged = false
    for index in conversations.indices
    where conversations[index].enabledMCPServers.contains(serverID)
      && !conversations[index].enabledMCPTools.contains(where: { $0.hasPrefix(prefix) })
    {
      conversations[index].enabledMCPTools.formUnion(toolKeys)
      conversationsChanged = true
    }

    if settingsChanged {
      saveSettings()
    }
    if conversationsChanged {
      saveConversations()
    }
  }

  func refreshEndpoint(_ endpoint: OpenAIEndpoint) async {
    guard !settings.airplaneModeEnabled else {
      endpointStatuses[endpoint.id] = .failed("Airplane mode is enabled.")
      endpointModels[endpoint.id] = nil
      endpointVoices[endpoint.id] = nil
      return
    }
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
    guard !settings.airplaneModeEnabled else { return }
    let endpoints = settings.openAIEndpoints.filter(\.isEnabled)
    guard !endpoints.isEmpty else { return }
    for endpoint in endpoints {
      Task { await refreshEndpoint(endpoint) }
    }
  }

  func refreshLocalMLXModels() {
    localMLXModelIDs = LocalMLXModelCache.listRepositoryIDs()
    normalizeDefaultLocalMLXModelIfNeeded()
    normalizeUnavailableAppleProviderIfNeeded()
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

  private func normalizeUnavailableAppleProviderIfNeeded() {
    guard appleAvailabilityReport.kind != .checking, !appleIntelligenceIsAvailable else { return }
    let fallbackModelID = availableLocalMLXModelID(preferred: settings.localMLXModelID) ?? ""
    var settingsChanged = false
    if settings.defaultProvider == .apple {
      settings.defaultProvider = .mlx
      settings.localMLXModelID = fallbackModelID
      settingsChanged = true
    }

    var conversationsChanged = false
    for index in conversations.indices where conversations[index].provider == .apple {
      conversations[index].provider = .mlx
      conversations[index].endpointID = nil
      conversations[index].modelID = fallbackModelID
      conversationsChanged = true
    }

    if settingsChanged {
      saveSettings()
    }
    if conversationsChanged {
      saveConversations()
    }
  }

  private func normalizeCurrentAppleConversationIfNeeded(index: Int) {
    guard conversations.indices.contains(index),
      conversations[index].provider == .apple,
      !appleIntelligenceIsAvailable
    else {
      return
    }
    let fallbackModelID = availableLocalMLXModelID(preferred: settings.localMLXModelID) ?? ""
    conversations[index].provider = .mlx
    conversations[index].endpointID = nil
    conversations[index].modelID = fallbackModelID
    saveConversations()
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
    setSelectedConversationID(conversation.id, remember: false)
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
      && lhs.toolsEnabled == rhs.toolsEnabled
      && lhs.enabledTools == rhs.enabledTools
      && lhs.enabledMCPServers == rhs.enabledMCPServers
      && lhs.enabledMCPTools == rhs.enabledMCPTools
      && lhs.usesStreaming == rhs.usesStreaming
      && lhs.disabledMCPTools == rhs.disabledMCPTools
      && lhs.reasoningLevel == rhs.reasoningLevel
      && lhs.showThinking == rhs.showThinking
      && lhs.lastContextSignature == rhs.lastContextSignature
      && lhs.effectiveLanguageOverrideIdentifier == rhs.effectiveLanguageOverrideIdentifier
      && messageContentsMatch(lhs.messages, rhs.messages)
  }

  private func messageContentsMatch(_ lhs: [ChatMessage], _ rhs: [ChatMessage]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy { lhsMessage, rhsMessage in
      lhsMessage.role == rhsMessage.role
        && lhsMessage.text == rhsMessage.text
        && lhsMessage.createdAt == rhsMessage.createdAt
        && lhsMessage.voiceRecordingFilename == rhsMessage.voiceRecordingFilename
        && lhsMessage.attachments == rhsMessage.attachments
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
      mcpTools: mcpTools,
      mcpResources: mcpResources,
      mcpStatuses: mcpStatuses)
    let visibleDefinitions = ToolAgentRegistry.visibleDefinitions(
      for: conversation,
      settings: settings,
      mcpTools: mcpTools,
      mcpResources: mcpResources,
      mcpStatuses: mcpStatuses)
    let providerNativeToolCalling =
      settings.toolCallingMode == .native
      && conversation.provider.supportsNativeToolCalling
      && !visibleDefinitions.isEmpty
    let effectiveMode =
      providerNativeToolCalling
      ? ToolCallingMode.native
      : settings.toolCallingMode.textProtocolFallback(for: conversation.provider)
    let textToolPrompt =
      providerNativeToolCalling
      ? "" : ToolAgentRegistry.promptDescription(for: visibleDefinitions, mode: effectiveMode)
    let toolPrompt = textToolPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let toolPromptInContext = !providerNativeToolCalling && !toolPrompt.isEmpty
    let nativeToolNames: [String] = {
      guard providerNativeToolCalling else { return [] }
      let resolver = AgentToolNameResolver(tools: visibleDefinitions)
      return visibleDefinitions.map { resolver.apiName(for: $0.name) }
    }()
    let maxToolCalls = min(20, max(1, settings.maxToolCallsPerTurn))
    let maxRepairTurns = min(4, maxToolCalls + 1)
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
      hasTools: hasToolCalling,
      toolPrompt: providerNativeToolCalling ? "" : toolPrompt,
      toolPromptInContext: toolPromptInContext)
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
      textProtocolFallback: settings.toolCallingMode.textProtocolFallback(
        for: conversation.provider
      )
      .rawValue,
      providerNativeToolCalling: providerNativeToolCalling,
      nativeToolCallingUnavailableReason: nativeToolCallingUnavailableReason(
        conversation: conversation,
        hasTools: hasToolCalling),
      toolCatalogInlinedInPrompt: !providerNativeToolCalling && hasToolCalling,
      nativeToolNames: nativeToolNames,
      maxToolCallsPerTurn: maxToolCalls,
      maxRepairTurnsPerTurn: maxRepairTurns,
      yoloModeEnabled: settings.yoloModeEnabled,
      useToolProxy: settings.useToolProxy,
      airplaneModeEnabled: settings.airplaneModeEnabled,
      contextWindowMode: settings.contextWindowMode.rawValue,
      contextWindowMessageLimit: settings.contextWindowMode.messageLimit,
      includeAssistantResponsesInContext: settings.includeAssistantResponsesInContext,
      includeReasoningContentInContext: settings.includeReasoningContentInContext,
      defaultEnabledTools: settings.defaultEnabledTools.map(\.rawValue).sorted(),
      defaultEnabledMCPServers: settings.defaultEnabledMCPServers.map(\.uuidString).sorted(),
      defaultEnabledMCPTools: Array(settings.defaultEnabledMCPTools).sorted(),
      toolsEnabled: conversation.toolsEnabled,
      enabledTools: conversation.enabledTools.map(\.rawValue).sorted(),
      enabledMCPServers: conversation.enabledMCPServers.map(\.uuidString).sorted(),
      enabledMCPTools: Array(conversation.enabledMCPTools).sorted(),
      disabledMCPTools: Array(conversation.disabledMCPTools).sorted(),
      mcpServers: settings.mcpServers.map { server in
        ConversationDebugMCPServer(
          id: server.id,
          name: server.name,
          isEnabled: server.isEnabled,
          hasValidScheme: server.hasValidEndpointURL,
          connectionStatus: (mcpStatuses[server.id] ?? .unknown).statusText)
      },
      nativeToolSettings: debugNativeToolSettings(settings.toolSettings),
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
        messageLimit: settings.contextWindowMode.messageLimit,
        toolPrompt: providerNativeToolCalling ? "" : toolPrompt,
        toolPromptInContext: toolPromptInContext),
      iterations: runtimeIterations.isEmpty ? storedIterations : runtimeIterations,
      notes: [
        "Debug prompt data is reconstructed at export time from current settings.",
        "Runtime iterations are included for tool loops completed in the current app session.",
        "The original per-iteration provider request payload is not persisted across app launches.",
      ])
  }

  private func nativeToolCallingUnavailableReason(
    conversation: Conversation,
    hasTools: Bool
  ) -> String? {
    guard settings.toolCallingMode == .native, hasTools else { return nil }
    guard !conversation.provider.supportsNativeToolCalling else { return nil }
    return
      "\(conversation.provider.displayName) does not expose native tool calling; using \(settings.toolCallingMode.textProtocolFallback(for: conversation.provider).displayName) text fallback."
  }

  private func debugNativeToolSettings(
    _ toolSettings: NativeToolSettings
  ) -> ConversationDebugNativeToolSettings {
    let searXNGURL = toolSettings.webSearchSearXNGURL.trimmingCharacters(
      in: .whitespacesAndNewlines)
    return ConversationDebugNativeToolSettings(
      includeTimeZone: toolSettings.includeTimeZone,
      includeMoonPhase: toolSettings.includeMoonPhase,
      useGPSLocation: toolSettings.useGPSLocation,
      manualLocationConfigured: !toolSettings.manualLocation.trimmingCharacters(
        in: .whitespacesAndNewlines
      ).isEmpty,
      weatherLocationConfigured: !toolSettings.weatherLocation.trimmingCharacters(
        in: .whitespacesAndNewlines
      ).isEmpty,
      webSearchProvider: toolSettings.webSearchProvider.rawValue,
      webSearchSearXNGURLConfigured: !searXNGURL.isEmpty,
      webSearchSearXNGURLHost: URLComponents(string: searXNGURL)?.host,
      webSearchSearXNGUsernameConfigured: !toolSettings.webSearchSearXNGUsername
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      webSearchSearXNGPasswordConfigured: !toolSettings.webSearchSearXNGPassword.isEmpty,
      webSearchFetchingEnabled: toolSettings.webSearchFetchingEnabled,
      filesWorkspaceAccessEnabled: toolSettings.filesWorkspaceAccessEnabled,
      configuredToolFilesCount: toolSettings.files.count,
      todoCount: toolSettings.todos.count)
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
    messageLimit: Int?,
    toolPrompt: String = "",
    toolPromptInContext: Bool = false
  ) -> [ConversationDebugPromptMessage] {
    let limited: [ChatMessage] = {
      if let messageLimit { return Array(conversation.messages.suffix(messageLimit)) }
      return conversation.messages
    }()
    var messages = [ConversationDebugPromptMessage(role: "system", content: systemPrompt)]
    messages.append(
      contentsOf: limited.flatMap { message in
        PromptComposer.contextTranscriptEntries(from: message, settings: settings).map { entry in
          ConversationDebugPromptMessage(
            role: debugRole(displayName: entry.displayName),
            content: entry.content)
        }
      })
    if let reminder = PromptComposer.toolCallingReminder(
      toolPrompt: toolPrompt,
      includeToolPrompt: !toolPromptInContext)
    {
      messages.append(ConversationDebugPromptMessage(role: "user", content: reminder))
    }
    return messages
  }

  private func debugRole(displayName: String) -> String {
    switch displayName {
    case ChatRole.system.displayName:
      return "system"
    case ChatRole.assistant.displayName:
      return "assistant"
    default:
      return "user"
    }
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

  // MARK: - Settings Backup (Import / Export / Clear)

  func exportSettingsBackupFile(scope: SettingsBackupScope, includeAudio: Bool = false) -> URL? {
    let envelope = makeBackupEnvelope(scope: scope, includeAudio: includeAudio)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(envelope) else {
      errorMessage = "Could not encode backup."
      return nil
    }
    do {
      let filename = backupFilename(scope: scope)
      let url = try ConversationExportFiles.url(filename: filename, fileExtension: "json")
      try data.write(to: url, options: .atomic)
      return url
    } catch {
      errorMessage = "Could not write backup: \(error.localizedDescription)"
      return nil
    }
  }

  private func makeBackupEnvelope(scope: SettingsBackupScope, includeAudio: Bool)
    -> SettingsBackupEnvelope
  {
    let exportedConversations: [Conversation]?
    switch scope {
    case .everything, .conversations:
      exportedConversations = conversations
    case .providers, .prompts, .tools:
      exportedConversations = nil
    }
    let attachments =
      includeAudio
      ? collectVoiceRecordingAttachments(from: exportedConversations ?? [])
      : nil

    switch scope {
    case .everything:
      return SettingsBackupEnvelope(
        providers: providersBackup(),
        prompts: promptsBackup(),
        tools: toolsBackup(),
        conversations: exportedConversations,
        voiceRecordings: attachments)
    case .providers:
      return SettingsBackupEnvelope(providers: providersBackup())
    case .prompts:
      return SettingsBackupEnvelope(prompts: promptsBackup())
    case .tools:
      return SettingsBackupEnvelope(tools: toolsBackup())
    case .conversations:
      return SettingsBackupEnvelope(
        conversations: exportedConversations,
        voiceRecordings: attachments)
    }
  }

  private func collectVoiceRecordingAttachments(from conversations: [Conversation])
    -> [SettingsVoiceRecordingAttachment]
  {
    var seen = Set<String>()
    var attachments: [SettingsVoiceRecordingAttachment] = []
    for conversation in conversations {
      for message in conversation.messages {
        guard let filename = Self.normalizedVoiceRecordingFilename(from: message),
          !seen.contains(filename),
          let url = PocketMaiDirectories.voiceRecordingURL(filename: filename),
          let data = try? Data(contentsOf: url)
        else { continue }
        seen.insert(filename)
        attachments.append(
          SettingsVoiceRecordingAttachment(
            filename: filename, dataBase64: data.base64EncodedString()))
      }
    }
    return attachments
  }

  private func providersBackup() -> SettingsProvidersBackup {
    SettingsProvidersBackup(
      endpoints: settings.openAIEndpoints,
      selectedEndpointID: settings.selectedEndpointID,
      defaultProvider: settings.defaultProvider)
  }

  private func promptsBackup() -> SettingsPromptsBackup {
    SettingsPromptsBackup(
      prompts: settings.systemPrompts,
      defaultSystemPromptID: settings.defaultSystemPromptID,
      compactPrompt: settings.compactPrompt)
  }

  private func toolsBackup() -> SettingsToolsBackup {
    SettingsToolsBackup(
      toolSettings: settings.toolSettings,
      mcpServers: settings.mcpServers,
      defaultEnabledTools: settings.defaultEnabledTools,
      defaultEnabledMCPServers: settings.defaultEnabledMCPServers,
      defaultEnabledMCPTools: settings.defaultEnabledMCPTools,
      toolCallingMode: settings.toolCallingMode,
      maxToolCallsPerTurn: settings.maxToolCallsPerTurn,
      yoloModeEnabled: settings.yoloModeEnabled,
      useToolProxy: settings.useToolProxy)
  }

  private func backupFilename(scope: SettingsBackupScope) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let stamp = formatter.string(from: Date())
    let suffix: String
    switch scope {
    case .everything: suffix = "everything"
    case .providers: suffix = "providers"
    case .prompts: suffix = "prompts"
    case .tools: suffix = "tools"
    case .conversations: suffix = "conversations"
    }
    return "PocketMai-\(suffix)-\(stamp)"
  }

  @discardableResult
  func importSettingsBackup(
    from url: URL,
    scope: SettingsBackupScope,
    restoreAudio: Bool = false
  ) throws -> String {
    let access = url.startAccessingSecurityScopedResource()
    defer {
      if access {
        url.stopAccessingSecurityScopedResource()
      }
    }
    guard let data = try? Data(contentsOf: url) else {
      throw SettingsBackupError.unreadableFile
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let envelope = try? decoder.decode(SettingsBackupEnvelope.self, from: data),
      envelope.format == SettingsBackupEnvelope.format
    else {
      throw SettingsBackupError.invalidJSON
    }
    return try applyBackup(envelope, scope: scope, restoreAudio: restoreAudio)
  }

  @discardableResult
  private func applyBackup(
    _ envelope: SettingsBackupEnvelope,
    scope: SettingsBackupScope,
    restoreAudio: Bool
  ) throws -> String {
    var applied: [String] = []

    let wantProviders = scope == .everything || scope == .providers
    let wantPrompts = scope == .everything || scope == .prompts
    let wantTools = scope == .everything || scope == .tools
    let wantConversations = scope == .everything || scope == .conversations

    if wantProviders {
      guard let payload = envelope.providers else {
        if scope == .providers { throw SettingsBackupError.missingSection(.providers) }
        if scope == .everything { /* allow */  } else { /* unreachable */  }
        return ""
      }
      applyProvidersBackup(payload)
      applied.append(
        "\(payload.endpoints.count) provider\(payload.endpoints.count == 1 ? "" : "s")")
    }

    if wantPrompts {
      guard let payload = envelope.prompts else {
        if scope == .prompts { throw SettingsBackupError.missingSection(.prompts) }
        return finishApplyBackup(applied: applied)
      }
      applyPromptsBackup(payload)
      applied.append("\(payload.prompts.count) prompt\(payload.prompts.count == 1 ? "" : "s")")
    }

    if wantTools {
      guard let payload = envelope.tools else {
        if scope == .tools { throw SettingsBackupError.missingSection(.tools) }
        return finishApplyBackup(applied: applied)
      }
      applyToolsBackup(payload)
      applied.append("tool settings")
    }

    if wantConversations {
      guard let payload = envelope.conversations else {
        if scope == .conversations { throw SettingsBackupError.missingSection(.conversations) }
        return finishApplyBackup(applied: applied)
      }
      applyConversationsBackup(payload)
      applied.append("\(payload.count) conversation\(payload.count == 1 ? "" : "s")")

      if restoreAudio, let attachments = envelope.voiceRecordings, !attachments.isEmpty {
        let restored = restoreVoiceRecordings(attachments)
        if restored > 0 {
          applied.append("\(restored) audio file\(restored == 1 ? "" : "s")")
        }
      }
    }

    if scope == .everything && envelope.providers == nil && envelope.prompts == nil
      && envelope.tools == nil && envelope.conversations == nil
    {
      throw SettingsBackupError.missingSection(.everything)
    }

    saveSettings()
    return finishApplyBackup(applied: applied)
  }

  private func restoreVoiceRecordings(_ attachments: [SettingsVoiceRecordingAttachment]) -> Int {
    guard let directory = try? PocketMaiDirectories.ensureVoiceRecordings() else { return 0 }
    var restored = 0
    for attachment in attachments {
      let filename = attachment.filename.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !filename.isEmpty,
        PocketMaiDirectories.voiceRecordingURL(filename: filename) != nil,
        let data = Data(base64Encoded: attachment.dataBase64)
      else { continue }
      let url = directory.appendingPathComponent(filename)
      if (try? data.write(to: url, options: .atomic)) != nil {
        restored += 1
      }
    }
    return restored
  }

  private func finishApplyBackup(applied: [String]) -> String {
    saveSettings()
    if applied.isEmpty {
      return "Nothing to import."
    }
    return "Imported: " + applied.joined(separator: ", ") + "."
  }

  private func applyProvidersBackup(_ payload: SettingsProvidersBackup) {
    settings.openAIEndpoints = payload.endpoints
    if let selected = payload.selectedEndpointID,
      payload.endpoints.contains(where: { $0.id == selected })
    {
      settings.selectedEndpointID = selected
    } else {
      settings.selectedEndpointID = payload.endpoints.first?.id
    }
    if let provider = payload.defaultProvider {
      if provider == .apple && !appleIntelligenceIsAvailable {
        settings.defaultProvider = .mlx
      } else if provider == .openAICompatible && settings.selectedEndpointID == nil {
        settings.defaultProvider = .mlx
      } else {
        settings.defaultProvider = provider
      }
    }
    endpointStatuses.removeAll()
    endpointModels.removeAll()
    endpointVoices.removeAll()
  }

  private func applyPromptsBackup(_ payload: SettingsPromptsBackup) {
    let prompts = payload.prompts.isEmpty ? [AppSettings.defaultSystemPrompt] : payload.prompts
    settings.systemPrompts = prompts
    if let id = payload.defaultSystemPromptID, prompts.contains(where: { $0.id == id }) {
      settings.defaultSystemPromptID = id
    } else {
      settings.defaultSystemPromptID = prompts.first?.id ?? AppSettings.defaultSystemPrompt.id
    }
    if let compactPrompt = payload.compactPrompt {
      settings.compactPrompt = compactPrompt
    }
  }

  private func applyToolsBackup(_ payload: SettingsToolsBackup) {
    settings.toolSettings = payload.toolSettings
    settings.mcpServers = payload.mcpServers
    if let tools = payload.defaultEnabledTools {
      settings.defaultEnabledTools = tools
    }
    if let servers = payload.defaultEnabledMCPServers {
      settings.defaultEnabledMCPServers = servers
    }
    if let mcpTools = payload.defaultEnabledMCPTools {
      settings.defaultEnabledMCPTools = mcpTools
    }
    if let mode = payload.toolCallingMode {
      settings.toolCallingMode = mode
    }
    if let limit = payload.maxToolCallsPerTurn {
      settings.maxToolCallsPerTurn = min(20, max(1, limit))
    }
    if let yolo = payload.yoloModeEnabled {
      settings.yoloModeEnabled = yolo
    }
    if let proxy = payload.useToolProxy {
      settings.useToolProxy = proxy
    }
    mcpStatuses.removeAll()
    mcpTools.removeAll()
    mcpResources.removeAll()
    Task { await MCPHTTPClient.resetAllSessions() }
  }

  private func applyConversationsBackup(_ payload: [Conversation]) {
    let existingByID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
    var merged = conversations
    for var imported in payload {
      if existingByID[imported.id] != nil {
        imported.id = uniqueConversationID()
      }
      imported.updatedAt = Date()
      merged.insert(imported, at: 0)
    }
    conversations = merged
    sortConversations()
    rebuildConversationIndexes()
    conversationSummaries = Self.sortedSummaries(conversations.map(ConversationSummary.init))
    saveConversations()
  }

  // MARK: - Clear actions

  func clearProviderSettings() {
    settings.openAIEndpoints.removeAll()
    settings.selectedEndpointID = nil
    if settings.defaultProvider == .openAICompatible {
      settings.defaultProvider = .mlx
    }
    endpointStatuses.removeAll()
    endpointModels.removeAll()
    endpointVoices.removeAll()
    saveSettings()
  }

  func clearSystemPrompts() {
    settings.systemPrompts = [AppSettings.defaultSystemPrompt]
    settings.defaultSystemPromptID = AppSettings.defaultSystemPrompt.id
    settings.compactPrompt = AppSettings.defaultCompactPrompt
    saveSettings()
  }

  func clearToolSettings() {
    settings.toolSettings = .defaults
    settings.defaultEnabledTools = AppSettings.defaultTools
    settings.defaultEnabledMCPTools = AppSettings.defaultMCPTools
    saveSettings()
  }

  func clearMCPServers() {
    settings.mcpServers.removeAll()
    settings.defaultEnabledMCPServers.removeAll()
    settings.defaultEnabledMCPTools.removeAll()
    mcpStatuses.removeAll()
    mcpTools.removeAll()
    mcpResources.removeAll()
    Task { await MCPHTTPClient.resetAllSessions() }
    saveSettings()
  }

  func clearMemory() {
    settings.memory = ""
    saveSettings()
  }

  @discardableResult
  func clearDownloadedMLXModels() -> String {
    let models = LocalMLXModelCache.listModels()
    var removed = 0
    var failed: [String] = []
    for model in models {
      do {
        try LocalMLXModelCache.delete(model)
        removed += 1
      } catch {
        failed.append(model.repoID)
      }
    }
    refreshLocalMLXModels()
    if !failed.isEmpty {
      return
        "Removed \(removed) model\(removed == 1 ? "" : "s"); failed: \(failed.joined(separator: ", "))."
    }
    return "Removed \(removed) downloaded model\(removed == 1 ? "" : "s")."
  }

  @discardableResult
  func clearFilesWorkspace() -> String {
    let url = PocketMaiDirectories.filesWorkspaceURL
    let fileManager = FileManager.default
    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else {
      return "Workspace is empty."
    }
    var removed = 0
    for entry in entries {
      if (try? fileManager.removeItem(at: entry)) != nil {
        removed += 1
      }
    }
    _ = try? PocketMaiDirectories.ensureFilesWorkspace()
    return "Removed \(removed) workspace item\(removed == 1 ? "" : "s")."
  }
}

enum ConversationExportFiles {
  static func url(
    for conversation: Conversation,
    format: ConversationExportFormat,
    suffix: String = ""
  ) throws -> URL {
    try url(
      filename: filename(for: conversation) + suffix,
      fileExtension: format.fileExtension)
  }

  static func url(filename: String, fileExtension: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PocketMaiExports",
      isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(filename).appendingPathExtension(fileExtension)
  }

  private static func filename(for conversation: Conversation) -> String {
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
