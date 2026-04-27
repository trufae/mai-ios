import Combine
import Foundation
import UIKit

enum EndpointConnectionState: Equatable {
  case unknown
  case checking
  case available
  case failed(String)
}

@MainActor
final class AppStore: ObservableObject {
  @Published var conversations: [Conversation]
  @Published var selectedConversationID: UUID?
  @Published var selectedConversationIDs: Set<UUID> = []
  @Published var settings: AppSettings
  @Published var draftText = ""
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

  let locationService = LocationService()
  private let persistence: PersistenceStore
  private let liveActivityManager = LiveActivityManager()

  init(persistence: PersistenceStore = PersistenceStore()) {
    self.persistence = persistence
    settings = persistence.loadSettings()
    conversations = []
    Task.detached { [persistence, weak self] in
      let loaded = persistence.loadConversations()
      let sorted = Self.sortedConversations(loaded)
      await MainActor.run {
        guard let self else { return }
        self.conversations = sorted
        self.selectedConversationID = sorted.first?.id
        if sorted.isEmpty {
          self.newConversation()
        }
      }
    }
  }

  var currentConversation: Conversation? {
    guard let selectedConversationID else { return nil }
    return conversations.first(where: { $0.id == selectedConversationID })
  }

  func newConversation(incognito: Bool = false) {
    discardSelectedIncognitoConversation()
    let endpoint =
      settings.openAIEndpoints.first(where: { $0.id == settings.selectedEndpointID })
      ?? settings.openAIEndpoints.first
    let provider = settings.defaultProvider
    let model = provider == .apple ? settings.appleModelID : (endpoint?.defaultModel ?? "")
    let conversation = Conversation(
      isIncognito: incognito,
      provider: provider,
      modelID: model,
      endpointID: endpoint?.id,
      systemPromptID: settings.defaultSystemPromptID,
      enabledTools: settings.defaultEnabledTools,
      usesStreaming: settings.streamByDefault
    )
    conversations.insert(conversation, at: 0)
    sortConversations()
    selectedConversationID = conversation.id
    isIncognitoMode = incognito
    selectedConversationIDs.removeAll()
    saveConversations()
  }

  func select(_ conversation: Conversation) {
    selectedConversationID = conversation.id
    isIncognitoMode = conversation.isIncognito
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
    for (_, task) in responseTasks { task.cancel() }
    responseTasks.removeAll()
    respondingConversationIDs.removeAll()
    conversations.removeAll()
    selectedConversationID = nil
    selectedConversationIDs.removeAll()
    isIncognitoMode = false
    saveConversations()
    newConversation()
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
    draftText = cleaned
    await send()
  }

  func deleteConversations(_ ids: Set<UUID>) {
    for id in ids {
      responseTasks[id]?.cancel()
      responseTasks[id] = nil
      respondingConversationIDs.remove(id)
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
    let cloned = Conversation(
      id: UUID(),
      title: copyTitle,
      messages: conversation.messages.map { msg in
        ChatMessage(id: UUID(), role: msg.role, text: msg.text, createdAt: msg.createdAt)
      },
      createdAt: now,
      updatedAt: now,
      isIncognito: conversation.isIncognito,
      provider: conversation.provider,
      modelID: conversation.modelID,
      endpointID: conversation.endpointID,
      systemPromptID: conversation.systemPromptID,
      enabledTools: conversation.enabledTools,
      usesStreaming: conversation.usesStreaming,
      isPinned: false,
      disabledMCPTools: conversation.disabledMCPTools,
      reasoningLevel: conversation.reasoningLevel
    )
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

  func send() async {
    let prompt = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else { return }
    if currentConversation == nil {
      newConversation()
    }
    guard let index = currentConversationIndex else { return }
    let conversationID = conversations[index].id
    guard !respondingConversationIDs.contains(conversationID) else { return }
    if let message = ChatProviderRouter.preflightMessage(
      conversation: conversations[index], settings: settings)
    {
      errorMessage = message
      return
    }

    draftText = ""
    errorMessage = nil

    let toolContext = await ToolContextBuilder.build(
      input: prompt,
      conversation: conversations[index],
      settings: settings,
      locationService: locationService
    )
    let userText: String = {
      let trimmed = toolContext.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return prompt }
      return "\(prompt)\n\n<tool_context>\n\(trimmed)\n</tool_context>"
    }()

    guard let i = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
    let userMessage = ChatMessage(role: .user, text: userText)
    conversations[i].messages.append(userMessage)
    conversations[i].refreshTitle(from: prompt)
    conversations[i].updatedAt = Date()
    saveConversations()

    dispatchAssistantTurn(
      conversationID: conversationID, prompt: prompt, toolContext: toolContext)
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

    let toolContext = await ToolContextBuilder.build(
      input: prompt,
      conversation: conversations[convIndex],
      settings: settings,
      locationService: locationService
    )
    let trimmedTC = toolContext.trimmingCharacters(in: .whitespacesAndNewlines)
    let refreshedUserText =
      trimmedTC.isEmpty
      ? prompt
      : "\(prompt)\n\n<tool_context>\n\(trimmedTC)\n</tool_context>"
    if let i = conversations.firstIndex(where: { $0.id == conversationID }),
      let lastIndex = conversations[i].messages.indices.last
    {
      conversations[i].messages[lastIndex].text = refreshedUserText
      saveConversations()
    }

    dispatchAssistantTurn(
      conversationID: conversationID, prompt: prompt, toolContext: toolContext)
  }

  private func dispatchAssistantTurn(
    conversationID: UUID, prompt: String, toolContext: String
  ) {
    respondingConversationIDs.insert(conversationID)
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.runAssistantTurn(
        conversationID: conversationID, prompt: prompt, toolContext: toolContext)
    }
    responseTasks[conversationID] = task
  }

  private func runAssistantTurn(
    conversationID: UUID, prompt: String, toolContext: String
  ) async {
    defer {
      respondingConversationIDs.remove(conversationID)
      responseTasks[conversationID] = nil
      saveConversations()
    }

    guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }

    let assistantMessage = ChatMessage(role: .assistant, text: "")
    conversations[index].messages.append(assistantMessage)
    conversations[index].updatedAt = Date()
    let assistantID = assistantMessage.id
    saveConversations()
    liveActivityManager.start(conversation: conversations[index])

    do {
      let agentDefinitions = ToolAgentRegistry.visibleDefinitions(
        for: conversations[index], settings: settings, mcpTools: mcpTools)
      let agentToolPrompt = ToolAgentRegistry.promptDescription(for: agentDefinitions)
      var augmentedToolContext = toolContext
      if !agentToolPrompt.isEmpty {
        if augmentedToolContext.isEmpty {
          augmentedToolContext = agentToolPrompt
        } else {
          augmentedToolContext += "\n\n" + agentToolPrompt
        }
      }

      var assistantText = ""
      var didFinish = false
      let toolNameResolver = AgentToolNameResolver(tools: agentDefinitions)

      let nativeTools: [OpenAITool]? = {
        guard
          settings.toolCallingMode == .native,
          conversations[index].provider == .openAICompatible,
          !agentDefinitions.isEmpty
        else { return nil }
        return agentDefinitions.map { def in
          OpenAITool(
            function: OpenAIFunctionSpec(
              name: toolNameResolver.apiName(for: def.name),
              description:
                def.description
                + (toolNameResolver.apiName(for: def.name) == def.name
                  ? "" : " Original tool name: \(def.name)."),
              parameters: OpenAIFunctionSchema(
                properties: Dictionary(
                  uniqueKeysWithValues: def.parameters.map { p in
                    (
                      p.name,
                      OpenAIPropertySpec(type: p.type, description: p.description)
                    )
                  }),
                required: def.parameters.filter(\.required).map(\.name)
              )
            )
          )
        }
      }()

      if agentDefinitions.isEmpty {
        guard let i = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        let request = ChatCompletionRequest(
          conversation: conversations[i],
          settings: settings,
          toolContext: augmentedToolContext,
          assistantMessageID: assistantID
        )
        let response = try await ChatProviderRouter.complete(request: request) {
          [weak self] streamed in
          self?.setAssistantMessage(
            id: assistantID, text: streamed, role: .assistant, touch: false)
        }
        try Task.checkCancellation()
        setAssistantMessage(id: assistantID, text: response, role: .assistant)
        await liveActivityManager.end(finalText: response)
        return
      }

      let maxIterations = 8
      for iteration in 0..<maxIterations {
        try Task.checkCancellation()
        guard let i = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        let request = ChatCompletionRequest(
          conversation: conversations[i],
          settings: settings,
          toolContext: augmentedToolContext,
          assistantMessageID: assistantID,
          nativeTools: nativeTools
        )
        let baseline = assistantText
        let response = try await ChatProviderRouter.complete(request: request) {
          [weak self] streamed in
          let combined = baseline.isEmpty ? streamed : "\(baseline)\n\n\(streamed)"
          self?.setAssistantMessage(
            id: assistantID, text: combined, role: .assistant, touch: false)
        }

        try Task.checkCancellation()

        let calls = ToolAgentRegistry.parseCalls(in: response, definitions: agentDefinitions)
        if calls.isEmpty {
          assistantText = assistantText.isEmpty ? response : "\(assistantText)\n\n\(response)"
          setAssistantMessage(id: assistantID, text: assistantText, role: .assistant)
          didFinish = true
          await liveActivityManager.end(finalText: assistantText)
          break
        }

        var transformed = response
        var runBlocks: [String] = []
        for call in calls {
          try Task.checkCancellation()
          let normalizedCall = ToolAgentRegistry.normalized(
            call: call, definitions: agentDefinitions)
          let result = await ToolAgentRegistry.execute(call: normalizedCall, store: self)
          let runBlock = ToolAgentRegistry.makeRunBlock(call: normalizedCall, result: result)
          if let range = transformed.range(of: call.rawBlock) {
            transformed.removeSubrange(range)
          } else {
            transformed = transformed.replacingOccurrences(of: call.rawBlock, with: "")
          }
          runBlocks.append(runBlock)
        }
        let turnText = ([transformed.trimmingCharacters(in: .whitespacesAndNewlines)] + runBlocks)
          .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
          .joined(separator: "\n\n")
        assistantText = assistantText.isEmpty ? turnText : "\(assistantText)\n\n\(turnText)"
        setAssistantMessage(id: assistantID, text: assistantText, role: .assistant)
        saveConversations()
      }

      if !didFinish {
        let suffix =
          "\n\nTool loop stopped after \(maxIterations) tool rounds before the model produced a final answer."
        setAssistantMessage(id: assistantID, text: assistantText + suffix, role: .assistant)
        await liveActivityManager.end(finalText: assistantText)
      }
    } catch is CancellationError {
      let current = currentTextOfMessage(id: assistantID)
      let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        setAssistantMessage(id: assistantID, text: "[stopped]", role: .error)
      } else {
        setAssistantMessage(
          id: assistantID, text: "\(current)\n\n[stopped]", role: .assistant)
      }
      await liveActivityManager.end(finalText: "[stopped]")
    } catch {
      let nsError = error as NSError
      if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
        let current = currentTextOfMessage(id: assistantID)
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
          setAssistantMessage(id: assistantID, text: "[stopped]", role: .error)
        } else {
          setAssistantMessage(
            id: assistantID, text: "\(current)\n\n[stopped]", role: .assistant)
        }
        await liveActivityManager.end(finalText: "[stopped]")
      } else {
        let text = error.localizedDescription
        setAssistantMessage(id: assistantID, text: text, role: .error)
        errorMessage = text
        await liveActivityManager.end(finalText: text)
      }
    }
  }

  private func currentTextOfMessage(id: UUID) -> String {
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
    let conversationID = conversation.id
    let substantive = conversation.messages.filter { msg in
      msg.role != .error
        && !msg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard substantive.count >= 2 else {
      errorMessage = "Nothing to compact yet."
      return
    }

    isCompacting = true
    defer { isCompacting = false }
    errorMessage = nil

    let transcript =
      substantive
      .map { "\($0.role.displayName): \($0.text)" }
      .joined(separator: "\n\n")

    let model: String = {
      let m = conversation.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
      if !m.isEmpty { return m }
      if conversation.provider == .apple { return settings.appleModelID }
      if let endpoint = settings.openAIEndpoints.first(where: { $0.id == conversation.endpointID })
      {
        return endpoint.defaultModel
      }
      return ""
    }()

    var summaryConversation = Conversation(
      title: "Compact",
      provider: conversation.provider,
      modelID: model,
      endpointID: conversation.endpointID,
      enabledTools: [],
      usesStreaming: false
    )
    summaryConversation.messages = [
      ChatMessage(
        role: .user,
        text: """
          Summarize the following conversation into a concise, information-preserving brief that can serve as context for continuing the chat. Preserve names, decisions, code snippets, file paths, error messages, and any unresolved questions. Drop greetings and filler. Use short paragraphs or bullets. Do not address the user; write in third person.

          \(transcript)
          """
      )
    ]
    let request = ChatCompletionRequest(
      conversation: summaryConversation,
      settings: settings,
      toolContext: "",
      assistantMessageID: UUID()
    )
    do {
      let summary = try await ChatProviderRouter.complete(request: request) { _ in }
      let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        errorMessage = "Compact returned an empty summary."
        return
      }
      guard let idx = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
      let replacement = ChatMessage(
        role: .system,
        text: "Conversation summary (compacted):\n\n\(trimmed)"
      )
      conversations[idx].messages = [replacement]
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

    let transcript =
      conversations
      .filter { !$0.isIncognito }
      .flatMap { conversation in
        conversation.messages.map { "\($0.role.displayName): \($0.text)" }
      }
      .joined(separator: "\n")
    guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

    var memoryConversation = Conversation(
      title: "Memory update",
      provider: settings.defaultProvider,
      modelID: settings.defaultProvider == .apple
        ? settings.appleModelID : (settings.openAIEndpoints.first?.defaultModel ?? ""),
      endpointID: settings.selectedEndpointID,
      enabledTools: [],
      usesStreaming: false
    )
    memoryConversation.messages = [
      ChatMessage(
        role: .user,
        text:
          """
          Extract only durable, useful user memories from these conversations. Keep facts concise. Include preferences, names, age, cities, projects, and recurring instructions. Ignore one-off tasks and sensitive secrets.

          \(transcript)
          """
      )
    ]
    let request = ChatCompletionRequest(
      conversation: memoryConversation,
      settings: settings,
      toolContext: "",
      assistantMessageID: UUID()
    )
    do {
      let memory = try await ChatProviderRouter.complete(request: request) { _ in }
      settings.memory = memory.trimmingCharacters(in: .whitespacesAndNewlines)
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

  private func setAssistantMessage(
    id: UUID, text: String, role: ChatRole, touch: Bool = true
  ) {
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
}
