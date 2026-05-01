import Foundation

@MainActor
enum AssistantTurnRunner {
  static func run(
    conversationID: UUID,
    toolContext: String,
    store: AppStore
  ) async {
    guard let assistantID = store.appendAssistantMessage(to: conversationID) else {
      return
    }

    do {
      try await runLoop(
        conversationID: conversationID,
        assistantID: assistantID,
        toolContext: toolContext,
        store: store
      )
    } catch is CancellationError {
      store.markAssistantStopped(id: assistantID)
    } catch {
      let nsError = error as NSError
      if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
        store.markAssistantStopped(id: assistantID)
      } else {
        let text = error.localizedDescription
        store.setAssistantMessage(id: assistantID, text: text, role: .error)
        store.errorMessage = text
      }
    }
  }

  private static func runLoop(
    conversationID: UUID,
    assistantID: UUID,
    toolContext: String,
    store: AppStore
  ) async throws {
    guard let conversation = store.conversation(withID: conversationID) else {
      return
    }

    let agentDefinitions = ToolAgentRegistry.visibleDefinitions(
      for: conversation,
      settings: store.settings,
      mcpTools: store.mcpTools
    )
    let augmentedToolContext = augmentedContext(
      base: toolContext,
      definitions: agentDefinitions
    )
    let nativeTools = nativeToolsIfNeeded(
      conversation: conversation,
      settings: store.settings,
      definitions: agentDefinitions
    )

    if agentDefinitions.isEmpty {
      try await completeWithoutTools(
        conversationID: conversationID,
        assistantID: assistantID,
        toolContext: augmentedToolContext,
        store: store
      )
      return
    }

    var assistantText = ""
    var didFinish = false
    let maxIterations = 8

    for _ in 0..<maxIterations {
      try Task.checkCancellation()
      guard let conversation = store.conversation(withID: conversationID) else {
        return
      }
      let request = ChatCompletionRequest(
        conversation: conversation,
        settings: store.settings,
        toolContext: augmentedToolContext,
        assistantMessageID: assistantID,
        nativeTools: nativeTools,
        hasToolCalling: true
      )
      let baseline = assistantText
      let response = try await ChatProviderRouter.complete(request: request) {
        [weak store] streamed in
        let combined = baseline.isEmpty ? streamed : "\(baseline)\n\n\(streamed)"
        store?.setAssistantMessage(
          id: assistantID,
          text: combined,
          role: .assistant,
          touch: false,
          streaming: true
        )
      }

      try Task.checkCancellation()

      let calls = ToolAgentRegistry.parseCalls(in: response, definitions: agentDefinitions)
      if calls.isEmpty {
        if AgentTooling.containsToolCallMarker(in: response) {
          let feedback = AgentTooling.malformedToolCallFeedback(from: response)
          let turnText = [response, feedback]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
          assistantText = assistantText.isEmpty ? turnText : "\(assistantText)\n\n\(turnText)"
          store.setAssistantMessage(id: assistantID, text: assistantText, role: .assistant)
          store.saveConversations()
          continue
        }
        assistantText = assistantText.isEmpty ? response : "\(assistantText)\n\n\(response)"
        store.setAssistantMessage(id: assistantID, text: assistantText, role: .assistant)
        didFinish = true
        break
      }

      let turnText = try await toolRunText(
        response: response,
        calls: calls,
        definitions: agentDefinitions,
        store: store
      )
      assistantText = assistantText.isEmpty ? turnText : "\(assistantText)\n\n\(turnText)"
      store.setAssistantMessage(id: assistantID, text: assistantText, role: .assistant)
      store.saveConversations()
    }

    if !didFinish {
      let suffix =
        "\n\nTool loop stopped after \(maxIterations) tool rounds before the model produced a final answer."
      store.setAssistantMessage(id: assistantID, text: assistantText + suffix, role: .assistant)
    }
  }

  private static func completeWithoutTools(
    conversationID: UUID,
    assistantID: UUID,
    toolContext: String,
    store: AppStore
  ) async throws {
    guard let conversation = store.conversation(withID: conversationID) else {
      return
    }
    let request = ChatCompletionRequest(
      conversation: conversation,
      settings: store.settings,
      toolContext: toolContext,
      assistantMessageID: assistantID,
      hasToolCalling: false
    )
    let response = try await ChatProviderRouter.complete(request: request) {
      [weak store] streamed in
      let cleaned = AppStore.strippedSpuriousToolCallText(streamed)
      store?.setAssistantMessage(
        id: assistantID,
        text: cleaned,
        role: .assistant,
        touch: false,
        streaming: true
      )
    }
    try Task.checkCancellation()
    let cleaned = AppStore.strippedSpuriousToolCallText(response)
    store.setAssistantMessage(id: assistantID, text: cleaned, role: .assistant)
  }

  private static func toolRunText(
    response: String,
    calls: [ParsedToolCall],
    definitions: [ToolDefinition],
    store: AppStore
  ) async throws -> String {
    var transformed = response
    var runBlocks: [String] = []
    for call in calls {
      try Task.checkCancellation()
      let normalizedCall = ToolAgentRegistry.normalized(call: call, definitions: definitions)
      let result = await ToolAgentRegistry.execute(call: normalizedCall, store: store)
      let runBlock = ToolAgentRegistry.makeRunBlock(call: normalizedCall, result: result)
      transformed = transformed.replacingOccurrences(of: call.rawBlock, with: "")
      runBlocks.append(runBlock)
    }
    return ([transformed.trimmingCharacters(in: .whitespacesAndNewlines)] + runBlocks)
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .joined(separator: "\n\n")
  }

  private static func augmentedContext(
    base: String,
    definitions: [ToolDefinition]
  ) -> String {
    let agentToolPrompt = ToolAgentRegistry.promptDescription(for: definitions)
    guard !agentToolPrompt.isEmpty else { return base }
    return base.isEmpty ? agentToolPrompt : "\(base)\n\n\(agentToolPrompt)"
  }

  private static func nativeToolsIfNeeded(
    conversation: Conversation,
    settings: AppSettings,
    definitions: [ToolDefinition]
  ) -> [OpenAITool]? {
    guard
      settings.toolCallingMode == .native,
      conversation.provider == .openAICompatible,
      !definitions.isEmpty
    else {
      return nil
    }

    let toolNameResolver = AgentToolNameResolver(tools: definitions)
    return definitions.map { def in
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
  }
}
