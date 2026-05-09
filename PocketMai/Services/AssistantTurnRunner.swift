import Foundation

@MainActor
enum AssistantTurnRunner {
  private struct ToolRequestState {
    let definitions: [ToolDefinition]
    let nativeTools: [OpenAITool]?
    let activeMode: ToolCallingMode
    let context: String
    let toolPrompt: String
  }

  private struct ToolRunOutput {
    let text: String
    let nativeMessages: [OpenAIMessage]
    let completedRuns: [(fingerprint: String, result: String)]
    let parsedCalls: [ParsedToolCall]
    let results: [ToolCallResult]
  }

  private struct ToolCallResult {
    let call: ParsedToolCall
    let result: String
  }

  private struct LoopState {
    var assistantText = ""
    var nativeContinuationMessages: [OpenAIMessage] = []
    var completedToolRuns: [String: String] = [:]
    var debugRoundIndex = 0

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
    store.clearToolCallingDebugIterations(
      conversationID: conversationID,
      assistantMessageID: assistantID)

    agentLoop: for _ in 0..<maxIterations {
      try Task.checkCancellation()
      guard let conversation = store.conversation(withID: conversationID) else {
        return
      }
      let toolState = toolRequestState(
        conversation: conversation,
        baseContext: context,
        store: store)
      let promptMessages = debugPromptMessages(
        conversation: conversation,
        toolState: toolState,
        state: state,
        assistantID: assistantID,
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
        store: store,
        completedToolRuns: state.completedToolRuns)

      switch outcome {
      case .final(let turnText):
        let text = state.append(turnText)
        store.setAssistantMessage(id: assistantID, text: text, role: .assistant)
        didFinish = true
        break agentLoop
      case .retry(let turnText):
        state.debugRoundIndex += 1
        appendDebugIteration(
          outcome: "retry",
          response: response,
          promptMessages: promptMessages,
          toolState: toolState,
          conversation: conversation,
          assistantID: assistantID,
          roundIndex: state.debugRoundIndex,
          store: store)
        let text = state.append(turnText)
        store.setAssistantMessage(id: assistantID, text: text, role: .assistant)
        store.saveConversations()
        state.nativeContinuationMessages.removeAll()
      case .toolRun(let output):
        state.debugRoundIndex += 1
        appendDebugIteration(
          outcome: "toolRun",
          response: response,
          promptMessages: promptMessages,
          toolState: toolState,
          conversation: conversation,
          assistantID: assistantID,
          roundIndex: state.debugRoundIndex,
          store: store,
          parsedCalls: output.parsedCalls,
          results: output.results)
        let text = state.append(output.text)
        store.setAssistantMessage(id: assistantID, text: text, role: .assistant)
        store.saveConversations()
        for completedRun in output.completedRuns
        where isSuccessfulToolResult(completedRun.result) {
          state.completedToolRuns[completedRun.fingerprint] = completedRun.result
        }
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
    store: AppStore,
    completedToolRuns: [String: String]
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
        return .retry(
          malformedToolCallTurnText(
            response: response,
            mode: toolState.activeMode,
            definitions: parseDefinitions))
      }
      return .final(response)
    }
    if let repeatedResult = repeatedCompletedToolResult(
      calls: calls,
      definitions: parseDefinitions,
      completedToolRuns: completedToolRuns)
    {
      return .final(repeatedResult)
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
    mode: ToolCallingMode,
    definitions: [ToolDefinition]
  ) -> String {
    let feedback = AgentTooling.malformedToolCallFeedback(
      from: response,
      mode: mode,
      tools: definitions)
    return feedback.trimmingCharacters(in: .whitespacesAndNewlines)
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
    var completedRuns: [(fingerprint: String, result: String)] = []
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
      completedRuns.append((toolCallFingerprint(result.call), result.result))
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
        mode: mode),
      completedRuns: completedRuns,
      parsedCalls: calls,
      results: nativeResults)
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
    case .interrupted:
      throw CancellationError()
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
    if let validationError = ToolAgentRegistry.requiredArgumentsError(
      call: executableCall,
      definitions: executionDefinitions)
    {
      return ToolCallResult(call: executableCall, result: validationError)
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

  private static func appendDebugIteration(
    outcome: String,
    response: String,
    promptMessages: [ConversationDebugPromptMessage],
    toolState: ToolRequestState,
    conversation: Conversation,
    assistantID: UUID,
    roundIndex: Int,
    store: AppStore,
    parsedCalls: [ParsedToolCall] = [],
    results: [ToolCallResult] = []
  ) {
    let firstCall = results.first?.call ?? parsedCalls.first
    let firstResult = results.first?.result ?? "Error: invalid tool call response."
    let resultText =
      results.isEmpty
      ? firstResult
      : results.map { "\($0.call.name) tool (\($0.call.argsJSON)):\n\($0.result)" }
        .joined(separator: "\n\n")
    let toolName = firstCall?.name ?? "invalid_tool_call"
    let argumentsJSON = firstCall?.argsJSON ?? "{}"
    let parsedDebugCalls = parsedCalls.map { call in
      ConversationDebugParsedToolCall(
        name: call.name,
        argumentsJSON: call.argsJSON,
        rawBlock: call.rawBlock)
    }
    let iteration = ConversationDebugToolIteration(
      assistantMessageID: assistantID,
      assistantMessageIndex: conversation.messages.firstIndex(where: { $0.id == assistantID })
        ?? -1,
      roundIndex: roundIndex,
      source: "runtime",
      createdAt: Date(),
      provider: conversation.provider.rawValue,
      model: debugModelName(for: conversation, store: store),
      selectedMode: store.settings.toolCallingMode.rawValue,
      effectiveMode: toolState.activeMode.rawValue,
      requestContext: toolState.context,
      toolPrompt: toolState.toolPrompt,
      nativeToolNames: toolState.nativeTools?.map { $0.function.name } ?? [],
      promptMessages: promptMessages,
      rawModelResponse: response,
      parsedToolCalls: parsedDebugCalls,
      outcome: outcome,
      toolName: toolName,
      argumentsJSON: argumentsJSON,
      result: resultText,
      isError: firstResult.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .hasPrefix("error:"),
      rawBlock: response)
    store.appendToolCallingDebugIteration(iteration, conversationID: conversation.id)
  }

  private static func debugPromptMessages(
    conversation: Conversation,
    toolState: ToolRequestState,
    state: LoopState,
    assistantID: UUID,
    store: AppStore
  ) -> [ConversationDebugPromptMessage] {
    if conversation.provider == .apple {
      return [
        ConversationDebugPromptMessage(
          role: "system",
          content: PromptComposer.systemPrompt(settings: store.settings, conversation: conversation)
        ),
        ConversationDebugPromptMessage(
          role: "user",
          content: PromptComposer.applePrompt(
            conversation: conversation,
            settings: store.settings,
            context: toolState.context,
            hasTools: !toolState.definitions.isEmpty)),
      ]
    }
    if conversation.provider == .openAICompatible,
      let endpoint = OpenAICompatibleProvider.selectedEndpoint(
        for: conversation,
        settings: store.settings)
    {
      let model =
        conversation.modelID.isEmpty ? endpoint.defaultModel : conversation.modelID
      return PromptComposer.openAIMessages(
        conversation: conversation,
        settings: store.settings,
        context: toolState.context,
        model: model,
        endpoint: endpoint,
        excludingMessageID: state.nativeContinuationMessages.isEmpty ? nil : assistantID,
        nativeContinuationMessages: state.nativeContinuationForRequest(
          conversation: conversation,
          toolState: toolState)
      ).map(debugPromptMessage)
    }

    let baseSystem = PromptComposer.systemPrompt(
      settings: store.settings, conversation: conversation)
    let systemContent =
      toolState.context.isEmpty
      ? baseSystem
      : "\(baseSystem)\n\n## Context\n\(toolState.context)"
    var messages = [ConversationDebugPromptMessage(role: "system", content: systemContent)]
    let limited: [ChatMessage] = {
      if let limit = store.settings.contextWindowMode.messageLimit {
        return Array(conversation.messages.suffix(limit))
      }
      return conversation.messages
    }()
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

  private static func debugPromptMessage(
    from message: OpenAIMessage
  ) -> ConversationDebugPromptMessage {
    let toolCallsJSON: String?
    if let toolCalls = message.toolCalls,
      let data = try? JSONEncoder().encode(toolCalls),
      let json = String(data: data, encoding: .utf8)
    {
      toolCallsJSON = json
    } else {
      toolCallsJSON = nil
    }
    return ConversationDebugPromptMessage(
      role: message.role,
      content: message.content ?? "",
      toolCallsJSON: toolCallsJSON,
      toolCallID: message.toolCallID)
  }

  private static func debugModelName(for conversation: Conversation, store: AppStore) -> String {
    if conversation.provider == .openAICompatible,
      conversation.modelID.isEmpty,
      let endpoint = OpenAICompatibleProvider.selectedEndpoint(
        for: conversation, settings: store.settings)
    {
      return endpoint.defaultModel
    }
    return conversation.modelID
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

  private static func toolRequestState(
    conversation: Conversation,
    baseContext: String,
    store: AppStore
  ) -> ToolRequestState {
    let visibleDefinitions = ToolAgentRegistry.visibleDefinitions(
      for: conversation,
      settings: store.settings,
      mcpTools: store.mcpTools)
    let nativeTools = nativeToolsIfNeeded(
      conversation: conversation,
      settings: store.settings,
      definitions: visibleDefinitions)
    let activeMode =
      nativeTools == nil ? store.settings.toolCallingMode.textProtocolFallback : .native
    let promptDefinitions = nativeTools == nil ? visibleDefinitions : []
    let toolPrompt = ToolAgentRegistry.promptDescription(
      for: promptDefinitions,
      mode: activeMode)
    let requestContext = [baseContext, toolPrompt]
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
    return ToolRequestState(
      definitions: visibleDefinitions,
      nativeTools: nativeTools,
      activeMode: activeMode,
      context: requestContext,
      toolPrompt: toolPrompt)
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
            inputSchemaJSON: def.inputSchemaJSON,
            parameters: def.parameters)
        )
      )
    }
  }

  private static func repeatedCompletedToolResult(
    calls: [ParsedToolCall],
    definitions: [ToolDefinition],
    completedToolRuns: [String: String]
  ) -> String? {
    guard !calls.isEmpty, !completedToolRuns.isEmpty else { return nil }
    let results = calls.compactMap { call -> String? in
      let normalizedCall = ToolAgentRegistry.normalized(call: call, definitions: definitions)
      guard ToolAgentRegistry.definitionExists(named: normalizedCall.name, in: definitions) else {
        return nil
      }
      return completedToolRuns[toolCallFingerprint(normalizedCall)]
    }
    guard results.count == calls.count, !results.isEmpty else { return nil }
    return
      results
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
  }

  private static func toolCallFingerprint(_ call: ParsedToolCall) -> String {
    "\(call.name)\n\(call.argsJSON)"
  }

  private static func isSuccessfulToolResult(_ result: String) -> Bool {
    !result.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .hasPrefix("error:")
  }
}
