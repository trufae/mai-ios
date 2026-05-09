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

  private struct ToolCallResult {
    let call: ParsedToolCall
    let result: String
  }

  private struct LoopState {
    var assistantText = ""
    var nativeContinuationMessages: [OpenAIMessage] = []

    mutating func append(_ turnText: String) -> String {
      assistantText =
        assistantText.isEmpty ? turnText : "\(assistantText)\n\n\(turnText)"
      return assistantText
    }

    mutating func applyNativeContinuation(
      _ messages: [OpenAIMessage],
      conversation: Conversation,
      toolState: ToolRequestState
    ) {
      if AssistantTurnRunner.shouldUseNativeContinuation(
        conversation: conversation,
        toolState: toolState),
        !messages.isEmpty
      {
        nativeContinuationMessages.append(contentsOf: messages)
      } else {
        nativeContinuationMessages.removeAll()
      }
    }

    func nativeContinuationForRequest(
      conversation: Conversation,
      toolState: ToolRequestState
    ) -> [OpenAIMessage] {
      AssistantTurnRunner.shouldUseNativeContinuation(
        conversation: conversation, toolState: toolState)
        ? nativeContinuationMessages : []
    }
  }

  private enum TurnOutcome {
    case final(String)
    case retry(String)
    case toolRun(ToolRunOutput)
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
    var state = LoopState()
    var didFinish = false
    let maxIterations = 8

    agentLoop: for _ in 0..<maxIterations {
      try Task.checkCancellation()
      guard let conversation = store.conversation(withID: conversationID) else {
        return
      }
      let toolState = toolRequestState(
        conversation: conversation,
        baseContext: context,
        store: store)
      let response = try await requestModelResponse(
        conversation: conversation,
        toolState: toolState,
        state: state,
        assistantID: assistantID,
        store: store)

      try Task.checkCancellation()

      let outcome = try await turnOutcome(
        response: response,
        toolState: toolState,
        conversationID: conversationID,
        store: store)

      switch outcome {
      case .final(let turnText):
        let text = state.append(turnText)
        store.setAssistantMessage(id: assistantID, text: text, role: .assistant)
        didFinish = true
        break agentLoop
      case .retry(let turnText):
        let text = state.append(turnText)
        store.setAssistantMessage(id: assistantID, text: text, role: .assistant)
        store.saveConversations()
        state.nativeContinuationMessages.removeAll()
      case .toolRun(let output):
        let text = state.append(output.text)
        store.setAssistantMessage(id: assistantID, text: text, role: .assistant)
        store.saveConversations()
        state.applyNativeContinuation(
          output.nativeMessages,
          conversation: conversation,
          toolState: toolState)
      }
    }

    if !didFinish {
      let suffix =
        "\n\nTool loop stopped after \(maxIterations) tool rounds before the model produced a final answer."
      store.setAssistantMessage(
        id: assistantID, text: state.assistantText + suffix, role: .assistant)
    }
  }

  private static func requestModelResponse(
    conversation: Conversation,
    toolState: ToolRequestState,
    state: LoopState,
    assistantID: UUID,
    store: AppStore
  ) async throws -> String {
    let request = ChatCompletionRequest(
      conversation: conversation,
      settings: store.settings,
      context: toolState.context,
      assistantMessageID: assistantID,
      nativeTools: toolState.nativeTools,
      nativeContinuationMessages: state.nativeContinuationForRequest(
        conversation: conversation,
        toolState: toolState),
      hasToolCalling: !toolState.definitions.isEmpty
    )
    let response = try await ChatProviderRouter.complete(request: request) {
      [weak store] streamed in
      let turnText =
        toolState.definitions.isEmpty
        ? AppStore.strippedSpuriousToolCallText(streamed)
        : streamed
      let combined = combinedAssistantText(
        baseline: state.assistantText,
        turnText: turnText)
      store?.setAssistantMessage(
        id: assistantID,
        text: combined,
        role: .assistant,
        touch: false,
        streaming: true
      )
    }
    try Task.checkCancellation()
    return toolState.definitions.isEmpty
      ? AppStore.strippedSpuriousToolCallText(response)
      : response
  }

  private static func turnOutcome(
    response: String,
    toolState: ToolRequestState,
    conversationID: UUID,
    store: AppStore
  ) async throws -> TurnOutcome {
    guard !toolState.definitions.isEmpty else {
      return .final(response)
    }

    let currentDefinitions = currentVisibleDefinitions(
      conversationID: conversationID,
      store: store)
    let parseDefinitions =
      currentDefinitions.isEmpty ? toolState.definitions : currentDefinitions
    let calls = ToolAgentRegistry.parseCalls(
      in: response,
      definitions: parseDefinitions,
      mode: toolState.activeMode)
    guard !calls.isEmpty else {
      if AgentTooling.containsToolCallMarker(in: response, mode: toolState.activeMode) {
        return .retry(malformedToolCallTurnText(response: response, mode: toolState.activeMode))
      }
      return .final(response)
    }

    let output = try await toolRunText(
      response: response,
      calls: calls,
      parseDefinitions: parseDefinitions,
      mode: toolState.activeMode,
      conversationID: conversationID,
      store: store)
    return .toolRun(output)
  }

  private static func malformedToolCallTurnText(
    response: String,
    mode: ToolCallingMode
  ) -> String {
    let feedback = AgentTooling.malformedToolCallFeedback(from: response, mode: mode)
    return [response, feedback]
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
  }

  private static func combinedAssistantText(baseline: String, turnText: String) -> String {
    baseline.isEmpty ? turnText : "\(baseline)\n\n\(turnText)"
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
    var nativeResults: [ToolCallResult] = []
    for call in calls {
      try Task.checkCancellation()
      let result = try await runToolCall(
        call,
        parseDefinitions: parseDefinitions,
        mode: mode,
        conversationID: conversationID,
        store: store)
      let runBlock = ToolAgentRegistry.makeRunBlock(call: result.call, result: result.result)
      transformed = transformed.replacingOccurrences(of: call.rawBlock, with: "")
      runBlocks.append(runBlock)
      nativeResults.append(result)
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

  private static func runToolCall(
    _ call: ParsedToolCall,
    parseDefinitions: [ToolDefinition],
    mode: ToolCallingMode,
    conversationID: UUID,
    store: AppStore
  ) async throws -> ToolCallResult {
    let currentDefinitions = currentVisibleDefinitions(
      conversationID: conversationID,
      store: store)
    let fallbackCall = ToolAgentRegistry.normalized(
      call: call,
      definitions: parseDefinitions)
    guard let normalizedCall = availableCall(call, definitions: currentDefinitions) else {
      return ToolCallResult(
        call: fallbackCall,
        result: ToolAgentRegistry.unavailableToolError(name: fallbackCall.name))
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

    guard shouldExecute else {
      return ToolCallResult(call: approvedCall, result: "Error: tool call cancelled by user.")
    }

    let executionDefinitions = currentVisibleDefinitions(
      conversationID: conversationID,
      store: store)
    guard let executableCall = availableCall(approvedCall, definitions: executionDefinitions)
    else {
      let unavailableCall = ToolAgentRegistry.normalized(
        call: approvedCall,
        definitions: currentDefinitions)
      return ToolCallResult(
        call: unavailableCall,
        result: ToolAgentRegistry.unavailableToolError(name: unavailableCall.name))
    }

    let result = await ToolAgentRegistry.execute(
      call: executableCall,
      conversationID: conversationID,
      store: store)
    return ToolCallResult(call: executableCall, result: result)
  }

  nonisolated private static func shouldUseNativeContinuation(
    conversation: Conversation,
    toolState: ToolRequestState
  ) -> Bool {
    toolState.activeMode == .native
      && conversation.provider == .openAICompatible
      && toolState.nativeTools != nil
  }

  private static func nativeMessages(
    assistantContent: String,
    results: [ToolCallResult],
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
