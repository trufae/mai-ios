import Foundation

@MainActor
enum AssistantTurnRunner {
  private struct ToolRequestState {
    let definitions: [ToolDefinition]
    let nativeTools: [OpenAITool]?
    let activeMode: ToolCallingMode
    let context: String
  }

  private struct ToolRunOutput {
    let text: String
    let nativeMessages: [OpenAIMessage]
  }

  static func run(
    conversationID: UUID,
    context: String,
    store: AppStore
  ) async {
    guard let assistantID = store.appendAssistantMessage(to: conversationID) else {
      return
    }

    do {
      try await runLoop(
        conversationID: conversationID,
        assistantID: assistantID,
        context: context,
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
    context: String,
    store: AppStore
  ) async throws {
    var assistantText = ""
    var nativeContinuationMessages: [OpenAIMessage] = []
    var didFinish = false
    let maxIterations = 8

    for _ in 0..<maxIterations {
      try Task.checkCancellation()
      guard let conversation = store.conversation(withID: conversationID) else {
        return
      }
      let toolState = toolRequestState(
        conversation: conversation,
        baseContext: context,
        store: store)
      if toolState.definitions.isEmpty {
        assistantText = try await completeWithoutTools(
          conversationID: conversationID,
          assistantID: assistantID,
          context: toolState.context,
          baseline: assistantText,
          store: store)
        didFinish = true
        break
      }
      let request = ChatCompletionRequest(
        conversation: conversation,
        settings: store.settings,
        context: toolState.context,
        assistantMessageID: assistantID,
        nativeTools: toolState.nativeTools,
        nativeContinuationMessages: nativeContinuationMessagesIfNeeded(
          nativeContinuationMessages,
          conversation: conversation,
          toolState: toolState),
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

      let currentDefinitions = currentVisibleDefinitions(
        conversationID: conversationID,
        store: store)
      let parseDefinitions =
        currentDefinitions.isEmpty ? toolState.definitions : currentDefinitions
      let calls = ToolAgentRegistry.parseCalls(
        in: response,
        definitions: parseDefinitions,
        mode: toolState.activeMode)
      if calls.isEmpty {
        if AgentTooling.containsToolCallMarker(in: response, mode: toolState.activeMode) {
          let feedback = AgentTooling.malformedToolCallFeedback(
            from: response,
            mode: toolState.activeMode)
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

      let turnOutput = try await toolRunText(
        response: response,
        calls: calls,
        parseDefinitions: parseDefinitions,
        mode: toolState.activeMode,
        conversationID: conversationID,
        store: store
      )
      let turnText = turnOutput.text
      assistantText = assistantText.isEmpty ? turnText : "\(assistantText)\n\n\(turnText)"
      store.setAssistantMessage(id: assistantID, text: assistantText, role: .assistant)
      store.saveConversations()
      if shouldUseNativeContinuation(conversation: conversation, toolState: toolState),
        !turnOutput.nativeMessages.isEmpty
      {
        nativeContinuationMessages.append(contentsOf: turnOutput.nativeMessages)
      } else {
        nativeContinuationMessages.removeAll()
      }
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
    context: String,
    baseline: String = "",
    store: AppStore
  ) async throws -> String {
    guard let conversation = store.conversation(withID: conversationID) else {
      return baseline
    }
    let request = ChatCompletionRequest(
      conversation: conversation,
      settings: store.settings,
      context: context,
      assistantMessageID: assistantID,
      hasToolCalling: false
    )
    let response = try await ChatProviderRouter.complete(request: request) {
      [weak store] streamed in
      let cleaned = AppStore.strippedSpuriousToolCallText(streamed)
      let combined = baseline.isEmpty ? cleaned : "\(baseline)\n\n\(cleaned)"
      store?.setAssistantMessage(
        id: assistantID,
        text: combined,
        role: .assistant,
        touch: false,
        streaming: true
      )
    }
    try Task.checkCancellation()
    let cleaned = AppStore.strippedSpuriousToolCallText(response)
    let combined = baseline.isEmpty ? cleaned : "\(baseline)\n\n\(cleaned)"
    store.setAssistantMessage(id: assistantID, text: combined, role: .assistant)
    return combined
  }

  private static func toolRunText(
    response: String,
    calls: [ParsedToolCall],
    parseDefinitions: [ToolDefinition],
    mode: ToolCallingMode,
    conversationID: UUID,
    store: AppStore
  ) async throws -> ToolRunOutput {
    var transformed = response
    var runBlocks: [String] = []
    var nativeResults: [(call: ParsedToolCall, result: String)] = []
    for call in calls {
      try Task.checkCancellation()
      let currentDefinitions = currentVisibleDefinitions(
        conversationID: conversationID,
        store: store)
      let fallbackCall = ToolAgentRegistry.normalized(
        call: call,
        definitions: parseDefinitions)
      guard let normalizedCall = availableCall(call, definitions: currentDefinitions) else {
        let result = ToolAgentRegistry.unavailableToolError(name: fallbackCall.name)
        let runBlock = ToolAgentRegistry.makeRunBlock(call: fallbackCall, result: result)
        transformed = transformed.replacingOccurrences(of: call.rawBlock, with: "")
        runBlocks.append(runBlock)
        nativeResults.append((fallbackCall, result))
        continue
      }
      let approvedCall: ParsedToolCall
      let shouldExecute: Bool
      switch await store.requestToolCallApproval(
        call: normalizedCall,
        definitions: currentDefinitions,
        mode: mode,
        conversationID: conversationID
      ) {
      case .approved(let call):
        approvedCall = call
        shouldExecute = true
      case .cancelled:
        approvedCall = normalizedCall
        shouldExecute = false
      }
      try Task.checkCancellation()
      let result: String
      let resultCall: ParsedToolCall
      if shouldExecute {
        let executionDefinitions = currentVisibleDefinitions(
          conversationID: conversationID,
          store: store)
        if let executableCall = availableCall(
          approvedCall,
          definitions: executionDefinitions)
        {
          resultCall = executableCall
          result = await ToolAgentRegistry.execute(
            call: executableCall,
            conversationID: conversationID,
            store: store)
        } else {
          let unavailableCall = ToolAgentRegistry.normalized(
            call: approvedCall,
            definitions: currentDefinitions)
          resultCall = unavailableCall
          result = ToolAgentRegistry.unavailableToolError(name: unavailableCall.name)
        }
      } else {
        resultCall = approvedCall
        result = "Error: tool call cancelled by user."
      }
      let runBlock = ToolAgentRegistry.makeRunBlock(call: resultCall, result: result)
      transformed = transformed.replacingOccurrences(of: call.rawBlock, with: "")
      runBlocks.append(runBlock)
      nativeResults.append((resultCall, result))
    }
    let text = ([transformed.trimmingCharacters(in: .whitespacesAndNewlines)] + runBlocks)
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .joined(separator: "\n\n")
    return ToolRunOutput(
      text: text,
      nativeMessages: nativeMessages(
        assistantContent: transformed,
        results: nativeResults,
        definitions: parseDefinitions,
        mode: mode))
  }

  private static func nativeContinuationMessagesIfNeeded(
    _ messages: [OpenAIMessage],
    conversation: Conversation,
    toolState: ToolRequestState
  ) -> [OpenAIMessage] {
    shouldUseNativeContinuation(conversation: conversation, toolState: toolState) ? messages : []
  }

  private static func shouldUseNativeContinuation(
    conversation: Conversation,
    toolState: ToolRequestState
  ) -> Bool {
    toolState.activeMode == .native
      && conversation.provider == .openAICompatible
      && toolState.nativeTools != nil
  }

  private static func nativeMessages(
    assistantContent: String,
    results: [(call: ParsedToolCall, result: String)],
    definitions: [ToolDefinition],
    mode: ToolCallingMode
  ) -> [OpenAIMessage] {
    guard mode == .native, !results.isEmpty else { return [] }
    let resolver = AgentToolNameResolver(tools: definitions)
    let toolCalls = results.compactMap { item -> OpenAIMessageToolCall? in
      guard let id = item.call.toolCallID else { return nil }
      let canonical = resolver.canonicalName(for: item.call.name) ?? item.call.name
      let apiName = item.call.apiName ?? resolver.apiName(for: canonical)
      return OpenAIMessageToolCall(
        id: id,
        function: OpenAIMessageToolCallFunction(
          name: apiName,
          arguments: item.call.argsJSON))
    }
    guard toolCalls.count == results.count else { return [] }
    let assistant = OpenAIMessage(
      role: "assistant",
      content: assistantContent.trimmingCharacters(in: .whitespacesAndNewlines),
      toolCalls: toolCalls)
    let toolMessages = results.compactMap { item -> OpenAIMessage? in
      guard let id = item.call.toolCallID else { return nil }
      return OpenAIMessage(role: "tool", content: item.result, toolCallID: id)
    }
    return [assistant] + toolMessages
  }

  private static func currentVisibleDefinitions(
    conversationID: UUID,
    store: AppStore
  ) -> [ToolDefinition] {
    guard let conversation = store.conversation(withID: conversationID) else { return [] }
    return ToolAgentRegistry.visibleDefinitions(
      for: conversation,
      settings: store.settings,
      mcpTools: store.mcpTools)
  }

  private static func availableCall(
    _ call: ParsedToolCall,
    definitions: [ToolDefinition]
  ) -> ParsedToolCall? {
    let normalizedCall = ToolAgentRegistry.normalized(call: call, definitions: definitions)
    guard ToolAgentRegistry.definitionExists(named: normalizedCall.name, in: definitions) else {
      return nil
    }
    return normalizedCall
  }

  private static func augmentedContext(
    base: String,
    definitions: [ToolDefinition],
    mode: ToolCallingMode
  ) -> String {
    let agentToolPrompt = ToolAgentRegistry.promptDescription(for: definitions, mode: mode)
    guard !agentToolPrompt.isEmpty else { return base }
    return base.isEmpty ? agentToolPrompt : "\(base)\n\n\(agentToolPrompt)"
  }

  private static func toolRequestState(
    conversation: Conversation,
    baseContext: String,
    store: AppStore
  ) -> ToolRequestState {
    let concreteDefinitions = ToolAgentRegistry.definitions(
      for: conversation,
      settings: store.settings,
      mcpTools: store.mcpTools)
    let latestPrompt = latestUserPrompt(in: conversation)
    let shouldUseTools = ToolAgentRegistry.shouldEnterAgentLoop(
      for: latestPrompt,
      definitions: concreteDefinitions)
    let visibleDefinitions =
      shouldUseTools
      ? ToolAgentRegistry.visibleDefinitions(
        for: conversation,
        settings: store.settings,
        mcpTools: store.mcpTools)
      : []
    let nativeTools = nativeToolsIfNeeded(
      conversation: conversation,
      settings: store.settings,
      definitions: visibleDefinitions)
    let activeMode =
      nativeTools == nil ? store.settings.toolCallingMode.textProtocolFallback : .native
    let requestContext = augmentedContext(
      base: baseContext,
      definitions: nativeTools == nil ? visibleDefinitions : [],
      mode: activeMode)
    return ToolRequestState(
      definitions: visibleDefinitions,
      nativeTools: nativeTools,
      activeMode: activeMode,
      context: requestContext)
  }

  private static func latestUserPrompt(in conversation: Conversation) -> String {
    guard let message = conversation.messages.last(where: { $0.role == .user }) else {
      return ""
    }
    return MessageContentFilter.promptSafeText(from: message.text)
  }

  private static func nativeToolsIfNeeded(
    conversation: Conversation,
    settings: AppSettings,
    definitions: [ToolDefinition]
  ) -> [OpenAITool]? {
    guard
      settings.toolCallingMode == .native,
      conversation.provider == .openAICompatible || conversation.provider == .mlx,
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
            inputSchemaJSON: def.inputSchemaJSON,
            parameters: def.parameters)
        )
      )
    }
  }
}
