import Foundation

@MainActor
enum AssistantToolLoop {
  struct ToolRunDetail: Sendable {
    let name: String
    let argumentsJSON: String
    let result: String
    let isError: Bool
  }

  struct IsolatedResult: Sendable {
    let text: String
    let toolRuns: [ToolRunDetail]
  }

  private struct RequestState {
    let definitions: [ToolDefinition]
    let nativeTools: [OpenAITool]?
    let activeMode: ToolCallingMode
    let context: String
    let toolPrompt: String

    var usesTextProtocol: Bool { nativeTools == nil }
  }

  private struct RunOutput {
    let text: String
    let nativeMessages: [OpenAIMessage]
    let completedRuns: [(fingerprint: String, result: String)]
    let parsedCalls: [ParsedToolCall]
    let results: [CallResult]
  }

  private struct CallResult {
    let call: ParsedToolCall
    let result: String
  }

  private struct State {
    var assistantText = ""
    var nativeContinuationMessages: [OpenAIMessage] = []
    var completedToolRuns: [String: String] = [:]
    var debugRoundIndex = 0
    var toolCallCount = 0
    var repairTurnCount = 0

    mutating func append(_ turnText: String) -> String {
      assistantText = assistantText.isEmpty ? turnText : "\(assistantText)\n\n\(turnText)"
      return assistantText
    }

    mutating func applyNativeContinuation(
      _ messages: [OpenAIMessage],
      conversation: Conversation,
      requestState: RequestState
    ) {
      if Self.shouldUseNativeContinuation(conversation: conversation, requestState: requestState),
        !messages.isEmpty
      {
        nativeContinuationMessages.append(contentsOf: messages)
      } else {
        nativeContinuationMessages.removeAll()
      }
    }

    func nativeContinuation(
      conversation: Conversation,
      requestState: RequestState
    ) -> [OpenAIMessage] {
      Self.shouldUseNativeContinuation(conversation: conversation, requestState: requestState)
        ? nativeContinuationMessages : []
    }

    private static func shouldUseNativeContinuation(
      conversation: Conversation,
      requestState: RequestState
    ) -> Bool {
      requestState.activeMode == .native
        && conversation.provider == .openAICompatible
        && requestState.nativeTools != nil
    }
  }

  private enum Outcome {
    case final(String)
    case retry(String)
    case toolRun(RunOutput)
  }

  static func run(
    conversationID: UUID,
    assistantID: UUID,
    baseContext: String,
    store: AppStore
  ) async throws {
    var state = State()
    var didFinish = false
    let maxToolCalls = maxToolCallsPerTurn(store: store)
    let maxRepairTurns = maxRepairTurnsPerTurn(store: store)

    store.clearToolCallingDebugIterations(
      conversationID: conversationID,
      assistantMessageID: assistantID)

    while state.toolCallCount < maxToolCalls && state.repairTurnCount < maxRepairTurns {
      try Task.checkCancellation()
      guard let conversation = store.conversation(withID: conversationID) else { return }
      let requestState = makeRequestState(
        conversation: conversation,
        baseContext: baseContext,
        store: store)
      let promptMessages = debugPromptMessages(
        conversation: conversation,
        requestState: requestState,
        state: state,
        assistantID: assistantID,
        store: store)
      let response = try await requestModelResponse(
        conversation: conversation,
        requestState: requestState,
        state: state,
        assistantID: assistantID,
        store: store)

      let outcome = try await outcome(
        response: response,
        requestState: requestState,
        conversationID: conversationID,
        store: store,
        completedToolRuns: state.completedToolRuns,
        remainingToolCalls: maxToolCalls - state.toolCallCount)

      switch outcome {
      case .final(let turnText):
        store.setAssistantMessage(id: assistantID, text: state.append(turnText), role: .assistant)
        store.assistantResponseCompleted()
        didFinish = true
        return
      case .retry(let feedback):
        state.debugRoundIndex += 1
        state.repairTurnCount += 1
        appendDebugIteration(
          outcome: "retry",
          response: response,
          promptMessages: promptMessages,
          requestState: requestState,
          conversation: conversation,
          assistantID: assistantID,
          roundIndex: state.debugRoundIndex,
          store: store)
        store.setAssistantMessage(id: assistantID, text: state.append(feedback), role: .assistant)
        store.saveConversations()
        state.nativeContinuationMessages.removeAll()
      case .toolRun(let output):
        state.debugRoundIndex += 1
        appendDebugIteration(
          outcome: "toolRun",
          response: response,
          promptMessages: promptMessages,
          requestState: requestState,
          conversation: conversation,
          assistantID: assistantID,
          roundIndex: state.debugRoundIndex,
          store: store,
          parsedCalls: output.parsedCalls,
          results: output.results)
        store.setAssistantMessage(
          id: assistantID, text: state.append(output.text), role: .assistant)
        store.saveConversations()
        for completedRun in output.completedRuns where isSuccessfulToolResult(completedRun.result) {
          state.completedToolRuns[completedRun.fingerprint] = completedRun.result
        }
        state.toolCallCount += output.results.count
        state.applyNativeContinuation(
          output.nativeMessages,
          conversation: conversation,
          requestState: requestState)
      }
    }

    if !didFinish {
      let suffix =
        "\n\nTool loop stopped after \(state.toolCallCount) of \(maxToolCalls) allowed tool call\(maxToolCalls == 1 ? "" : "s") and \(state.repairTurnCount) repair turn\(state.repairTurnCount == 1 ? "" : "s") before the model produced a final answer."
      store.setAssistantMessage(
        id: assistantID,
        text: state.assistantText + suffix,
        role: .assistant)
    }
  }

  static func runIsolated(
    conversation initialConversation: Conversation,
    settings: AppSettings,
    baseContext: String,
    store: AppStore
  ) async throws -> IsolatedResult {
    var conversation = initialConversation
    let assistantID = UUID()
    conversation.messages.append(ChatMessage(id: assistantID, role: .assistant, text: ""))

    var state = State()
    var toolRuns: [ToolRunDetail] = []
    let maxToolCalls = maxToolCallsPerTurn(settings: settings)
    let maxRepairTurns = maxRepairTurnsPerTurn(settings: settings)

    while state.toolCallCount < maxToolCalls && state.repairTurnCount < maxRepairTurns {
      try Task.checkCancellation()
      let requestState = makeRequestState(
        conversation: conversation,
        baseContext: baseContext,
        settings: settings,
        mcpTools: store.mcpTools,
        mcpResources: store.mcpResources)
      let response = try await requestModelResponseIsolated(
        conversation: conversation,
        requestState: requestState,
        state: state,
        assistantID: assistantID,
        settings: settings)

      let outcome = try await isolatedOutcome(
        response: response,
        requestState: requestState,
        conversation: conversation,
        settings: settings,
        mcpTools: store.mcpTools,
        mcpResources: store.mcpResources,
        store: store,
        completedToolRuns: state.completedToolRuns,
        remainingToolCalls: maxToolCalls - state.toolCallCount)

      switch outcome {
      case .final(let turnText):
        let text = state.append(turnText)
        updateLocalAssistantMessage(id: assistantID, text: text, conversation: &conversation)
        return IsolatedResult(
          text: userVisibleResponseText(from: text),
          toolRuns: toolRuns)
      case .retry(let feedback):
        state.debugRoundIndex += 1
        state.repairTurnCount += 1
        let text = state.append(feedback)
        updateLocalAssistantMessage(id: assistantID, text: text, conversation: &conversation)
        state.nativeContinuationMessages.removeAll()
      case .toolRun(let output):
        state.debugRoundIndex += 1
        let text = state.append(output.text)
        updateLocalAssistantMessage(id: assistantID, text: text, conversation: &conversation)
        toolRuns.append(
          contentsOf: output.results.map {
            ToolRunDetail(
              name: $0.call.name,
              argumentsJSON: $0.call.argsJSON,
              result: $0.result,
              isError: isToolResultError($0.result))
          })
        for completedRun in output.completedRuns where isSuccessfulToolResult(completedRun.result) {
          state.completedToolRuns[completedRun.fingerprint] = completedRun.result
        }
        state.toolCallCount += output.results.count
        state.applyNativeContinuation(
          output.nativeMessages,
          conversation: conversation,
          requestState: requestState)
      }
    }

    let suffix =
      "\n\nTool loop stopped after \(state.toolCallCount) of \(maxToolCalls) allowed tool call\(maxToolCalls == 1 ? "" : "s") and \(state.repairTurnCount) repair turn\(state.repairTurnCount == 1 ? "" : "s") before the model produced a final answer."
    let text = state.assistantText + suffix
    updateLocalAssistantMessage(id: assistantID, text: text, conversation: &conversation)
    return IsolatedResult(
      text: userVisibleResponseText(from: text),
      toolRuns: toolRuns)
  }

  private static func requestModelResponse(
    conversation: Conversation,
    requestState: RequestState,
    state: State,
    assistantID: UUID,
    store: AppStore
  ) async throws -> String {
    // In the synthesis round (after a tool has run), suppress the tail reminder that says
    // "emit exactly one valid tool call and stop" — small models echo the tool result instead
    // of answering when they see that instruction a second time.
    let tailToolPrompt: String = {
      guard requestState.usesTextProtocol else { return "" }
      return state.completedToolRuns.isEmpty ? requestState.toolPrompt : ""
    }()
    let request = ChatCompletionRequest(
      conversation: conversation,
      settings: store.settings,
      context: requestState.context,
      assistantMessageID: assistantID,
      nativeTools: requestState.nativeTools,
      nativeContinuationMessages: state.nativeContinuation(
        conversation: conversation,
        requestState: requestState),
      hasToolCalling: !requestState.definitions.isEmpty,
      toolPrompt: tailToolPrompt,
      toolPromptInContext: requestState.usesTextProtocol && !requestState.toolPrompt.isEmpty
    )
    let response = try await ChatProviderRouter.complete(request: request) {
      [weak store] streamed in
      let turnText =
        requestState.definitions.isEmpty
        ? AppStore.strippedSpuriousToolCallText(streamed) : streamed
      if request.conversation.usesStreaming {
        store?.assistantStreamPacketReceived()
      }
      store?.setAssistantMessage(
        id: assistantID,
        text: combinedAssistantText(baseline: state.assistantText, turnText: turnText),
        role: .assistant,
        touch: false,
        streaming: true)
    }
    try Task.checkCancellation()
    return requestState.definitions.isEmpty
      ? AppStore.strippedSpuriousToolCallText(response)
      : response
  }

  private static func requestModelResponseIsolated(
    conversation: Conversation,
    requestState: RequestState,
    state: State,
    assistantID: UUID,
    settings: AppSettings
  ) async throws -> String {
    let tailToolPrompt: String = {
      guard requestState.usesTextProtocol else { return "" }
      return state.completedToolRuns.isEmpty ? requestState.toolPrompt : ""
    }()
    let request = ChatCompletionRequest(
      conversation: conversation,
      settings: settings,
      context: requestState.context,
      assistantMessageID: assistantID,
      nativeTools: requestState.nativeTools,
      nativeContinuationMessages: state.nativeContinuation(
        conversation: conversation,
        requestState: requestState),
      hasToolCalling: !requestState.definitions.isEmpty,
      toolPrompt: tailToolPrompt,
      toolPromptInContext: requestState.usesTextProtocol && !requestState.toolPrompt.isEmpty
    )
    let response = try await ChatProviderRouter.complete(request: request) { _ in }
    try Task.checkCancellation()
    return requestState.definitions.isEmpty
      ? AppStore.strippedSpuriousToolCallText(response)
      : response
  }

  private static func outcome(
    response: String,
    requestState: RequestState,
    conversationID: UUID,
    store: AppStore,
    completedToolRuns: [String: String],
    remainingToolCalls: Int
  ) async throws -> Outcome {
    guard !requestState.definitions.isEmpty else { return .final(response) }

    let currentDefinitions = currentVisibleDefinitions(
      conversationID: conversationID,
      store: store)
    let parseDefinitions =
      currentDefinitions.isEmpty ? requestState.definitions : currentDefinitions
    let calls = ToolAgentRegistry.parseCalls(
      in: response,
      definitions: parseDefinitions,
      mode: requestState.activeMode)

    guard !calls.isEmpty else {
      if AgentTooling.containsToolCallMarker(in: response, mode: requestState.activeMode) {
        return .retry(
          AgentTooling.malformedToolCallFeedback(
            from: response,
            mode: requestState.activeMode,
            tools: parseDefinitions
          ).trimmingCharacters(in: .whitespacesAndNewlines))
      }
      if AgentTooling.containsNonToolJSONToolLoopObject(in: response, tools: parseDefinitions) {
        return .retry(
          AgentTooling.nonToolJSONToolLoopFeedback(
            from: response,
            mode: requestState.activeMode,
            tools: parseDefinitions
          ).trimmingCharacters(in: .whitespacesAndNewlines))
      }
      return .final(response)
    }

    if let repeated = repeatedCompletedToolResult(
      calls: calls,
      definitions: parseDefinitions,
      completedToolRuns: completedToolRuns)
    {
      return .final(repeated)
    }
    guard remainingToolCalls > 0 else { return .final(response) }

    let output = try await runToolCalls(
      response: response,
      calls: calls,
      remainingToolCalls: remainingToolCalls,
      parseDefinitions: parseDefinitions,
      mode: requestState.activeMode,
      conversationID: conversationID,
      store: store)
    return .toolRun(output)
  }

  private static func isolatedOutcome(
    response: String,
    requestState: RequestState,
    conversation: Conversation,
    settings: AppSettings,
    mcpTools: [UUID: [MCPToolDescriptor]],
    mcpResources: [UUID: [MCPResourceDescriptor]],
    store: AppStore,
    completedToolRuns: [String: String],
    remainingToolCalls: Int
  ) async throws -> Outcome {
    guard !requestState.definitions.isEmpty else { return .final(response) }

    let currentDefinitions = currentVisibleDefinitions(
      conversation: conversation,
      settings: settings,
      mcpTools: mcpTools,
      mcpResources: mcpResources)
    let parseDefinitions =
      currentDefinitions.isEmpty ? requestState.definitions : currentDefinitions
    let calls = ToolAgentRegistry.parseCalls(
      in: response,
      definitions: parseDefinitions,
      mode: requestState.activeMode)

    guard !calls.isEmpty else {
      if AgentTooling.containsToolCallMarker(in: response, mode: requestState.activeMode) {
        return .retry(
          AgentTooling.malformedToolCallFeedback(
            from: response,
            mode: requestState.activeMode,
            tools: parseDefinitions
          ).trimmingCharacters(in: .whitespacesAndNewlines))
      }
      if AgentTooling.containsNonToolJSONToolLoopObject(in: response, tools: parseDefinitions) {
        return .retry(
          AgentTooling.nonToolJSONToolLoopFeedback(
            from: response,
            mode: requestState.activeMode,
            tools: parseDefinitions
          ).trimmingCharacters(in: .whitespacesAndNewlines))
      }
      return .final(response)
    }

    if let repeated = repeatedCompletedToolResult(
      calls: calls,
      definitions: parseDefinitions,
      completedToolRuns: completedToolRuns)
    {
      return .final(repeated)
    }
    guard remainingToolCalls > 0 else { return .final(response) }

    let output = try await runToolCalls(
      response: response,
      calls: calls,
      remainingToolCalls: remainingToolCalls,
      parseDefinitions: parseDefinitions,
      mode: requestState.activeMode,
      conversation: conversation,
      settings: settings,
      mcpTools: mcpTools,
      mcpResources: mcpResources,
      store: store)
    return .toolRun(output)
  }

  private static func runToolCalls(
    response: String,
    calls: [ParsedToolCall],
    remainingToolCalls: Int,
    parseDefinitions: [ToolDefinition],
    mode: ToolCallingMode,
    conversationID: UUID,
    store: AppStore
  ) async throws -> RunOutput {
    var visibleText = response
    var runBlocks: [String] = []
    var results: [CallResult] = []
    var completedRuns: [(fingerprint: String, result: String)] = []
    var executedCount = 0

    for call in calls {
      try Task.checkCancellation()
      visibleText = visibleText.replacingOccurrences(of: call.rawBlock, with: "")
      guard executedCount < remainingToolCalls else { continue }
      let result = try await runToolCall(
        call,
        parseDefinitions: parseDefinitions,
        mode: mode,
        conversationID: conversationID,
        store: store)
      runBlocks.append(ToolAgentRegistry.makeRunBlock(call: result.call, result: result.result))
      results.append(result)
      completedRuns.append((toolCallFingerprint(result.call), result.result))
      executedCount += 1
    }

    let text = ([visibleText.trimmingCharacters(in: .whitespacesAndNewlines)] + runBlocks)
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .joined(separator: "\n\n")
    return RunOutput(
      text: text,
      nativeMessages: nativeMessages(
        assistantContent: visibleText,
        results: results,
        definitions: parseDefinitions,
        mode: mode,
        echoReasoningContent: shouldEchoReasoningContent(
          conversationID: conversationID,
          store: store)),
      completedRuns: completedRuns,
      parsedCalls: calls,
      results: results)
  }

  private static func runToolCalls(
    response: String,
    calls: [ParsedToolCall],
    remainingToolCalls: Int,
    parseDefinitions: [ToolDefinition],
    mode: ToolCallingMode,
    conversation: Conversation,
    settings: AppSettings,
    mcpTools: [UUID: [MCPToolDescriptor]],
    mcpResources: [UUID: [MCPResourceDescriptor]],
    store: AppStore
  ) async throws -> RunOutput {
    var visibleText = response
    var runBlocks: [String] = []
    var results: [CallResult] = []
    var completedRuns: [(fingerprint: String, result: String)] = []
    var executedCount = 0

    for call in calls {
      try Task.checkCancellation()
      visibleText = visibleText.replacingOccurrences(of: call.rawBlock, with: "")
      guard executedCount < remainingToolCalls else { continue }
      let result = try await runToolCall(
        call,
        parseDefinitions: parseDefinitions,
        mode: mode,
        conversation: conversation,
        settings: settings,
        mcpTools: mcpTools,
        mcpResources: mcpResources,
        store: store)
      runBlocks.append(ToolAgentRegistry.makeRunBlock(call: result.call, result: result.result))
      results.append(result)
      completedRuns.append((toolCallFingerprint(result.call), result.result))
      executedCount += 1
    }

    let text = ([visibleText.trimmingCharacters(in: .whitespacesAndNewlines)] + runBlocks)
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .joined(separator: "\n\n")
    return RunOutput(
      text: text,
      nativeMessages: nativeMessages(
        assistantContent: visibleText,
        results: results,
        definitions: parseDefinitions,
        mode: mode,
        echoReasoningContent: shouldEchoReasoningContent(
          conversation: conversation,
          settings: settings)),
      completedRuns: completedRuns,
      parsedCalls: calls,
      results: results)
  }

  private static func runToolCall(
    _ call: ParsedToolCall,
    parseDefinitions: [ToolDefinition],
    mode: ToolCallingMode,
    conversationID: UUID,
    store: AppStore
  ) async throws -> CallResult {
    let currentDefinitions = currentVisibleDefinitions(
      conversationID: conversationID,
      store: store)
    let fallbackCall = ToolAgentRegistry.normalized(call: call, definitions: parseDefinitions)
    guard let normalizedCall = availableCall(call, definitions: currentDefinitions) else {
      return CallResult(
        call: fallbackCall,
        result: ToolAgentRegistry.unavailableToolError(name: fallbackCall.name))
    }

    let approvedCall: ParsedToolCall
    let shouldExecute: Bool
    switch await store.requestToolCallApproval(
      call: normalizedCall,
      definitions: currentDefinitions,
      mode: mode,
      conversationID: conversationID)
    {
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
      return CallResult(call: approvedCall, result: "Error: tool call cancelled by user.")
    }

    let executionDefinitions = currentVisibleDefinitions(
      conversationID: conversationID,
      store: store)
    guard let executableCall = availableCall(approvedCall, definitions: executionDefinitions)
    else {
      let unavailableCall = ToolAgentRegistry.normalized(
        call: approvedCall,
        definitions: currentDefinitions)
      return CallResult(
        call: unavailableCall,
        result: ToolAgentRegistry.unavailableToolError(name: unavailableCall.name))
    }
    if let validationError = ToolAgentRegistry.requiredArgumentsError(
      call: executableCall,
      definitions: executionDefinitions)
    {
      return CallResult(call: executableCall, result: validationError)
    }

    let result = await ToolAgentRegistry.execute(
      call: executableCall,
      conversationID: conversationID,
      store: store)
    return CallResult(call: executableCall, result: result)
  }

  private static func runToolCall(
    _ call: ParsedToolCall,
    parseDefinitions: [ToolDefinition],
    mode: ToolCallingMode,
    conversation: Conversation,
    settings: AppSettings,
    mcpTools: [UUID: [MCPToolDescriptor]],
    mcpResources: [UUID: [MCPResourceDescriptor]],
    store: AppStore
  ) async throws -> CallResult {
    let currentDefinitions = currentVisibleDefinitions(
      conversation: conversation,
      settings: settings,
      mcpTools: mcpTools,
      mcpResources: mcpResources)
    let fallbackCall = ToolAgentRegistry.normalized(call: call, definitions: parseDefinitions)
    guard let normalizedCall = availableCall(call, definitions: currentDefinitions) else {
      return CallResult(
        call: fallbackCall,
        result: ToolAgentRegistry.unavailableToolError(name: fallbackCall.name))
    }

    let approvedCall: ParsedToolCall
    let shouldExecute: Bool
    switch await store.requestToolCallApproval(
      call: normalizedCall,
      definitions: currentDefinitions,
      mode: mode,
      conversationTitle: conversation.displayTitle)
    {
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
      return CallResult(call: approvedCall, result: "Error: tool call cancelled by user.")
    }

    let executionDefinitions = currentVisibleDefinitions(
      conversation: conversation,
      settings: settings,
      mcpTools: mcpTools,
      mcpResources: mcpResources)
    guard let executableCall = availableCall(approvedCall, definitions: executionDefinitions)
    else {
      let unavailableCall = ToolAgentRegistry.normalized(
        call: approvedCall,
        definitions: currentDefinitions)
      return CallResult(
        call: unavailableCall,
        result: ToolAgentRegistry.unavailableToolError(name: unavailableCall.name))
    }
    if let validationError = ToolAgentRegistry.requiredArgumentsError(
      call: executableCall,
      definitions: executionDefinitions)
    {
      return CallResult(call: executableCall, result: validationError)
    }

    let result = await ToolAgentRegistry.execute(
      call: executableCall,
      conversation: conversation,
      store: store)
    return CallResult(call: executableCall, result: result)
  }

  private static func makeRequestState(
    conversation: Conversation,
    baseContext: String,
    store: AppStore
  ) -> RequestState {
    makeRequestState(
      conversation: conversation,
      baseContext: baseContext,
      settings: store.settings,
      mcpTools: store.mcpTools,
      mcpResources: store.mcpResources)
  }

  private static func makeRequestState(
    conversation: Conversation,
    baseContext: String,
    settings: AppSettings,
    mcpTools: [UUID: [MCPToolDescriptor]],
    mcpResources: [UUID: [MCPResourceDescriptor]]
  ) -> RequestState {
    let visibleDefinitions = ToolAgentRegistry.visibleDefinitions(
      for: conversation,
      settings: settings,
      mcpTools: mcpTools,
      mcpResources: mcpResources)
    let nativeTools = nativeToolsIfNeeded(
      conversation: conversation,
      settings: settings,
      definitions: visibleDefinitions)
    let activeMode =
      nativeTools == nil
      ? settings.toolCallingMode.textProtocolFallback(for: conversation.provider)
      : .native
    let promptDefinitions = nativeTools == nil ? visibleDefinitions : []
    let toolPrompt = ToolAgentRegistry.promptDescription(
      for: promptDefinitions,
      mode: activeMode)
    let requestContext = [baseContext, toolPrompt]
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
    return RequestState(
      definitions: visibleDefinitions,
      nativeTools: nativeTools,
      activeMode: activeMode,
      context: requestContext,
      toolPrompt: toolPrompt)
  }

  private static func nativeToolsIfNeeded(
    conversation: Conversation,
    settings: AppSettings,
    definitions: [ToolDefinition]
  ) -> [OpenAITool]? {
    guard
      settings.toolCallingMode == .native,
      conversation.provider.supportsNativeToolCalling,
      !definitions.isEmpty
    else {
      return nil
    }

    let resolver = AgentToolNameResolver(tools: definitions)
    return definitions.map { def in
      OpenAITool(
        function: OpenAIFunctionSpec(
          name: resolver.apiName(for: def.name),
          description:
            def.description
            + (resolver.apiName(for: def.name) == def.name
              ? "" : " Original tool name: \(def.name)."),
          parameters: OpenAIFunctionSchema(
            inputSchemaJSON: def.inputSchemaJSON,
            parameters: def.parameters)))
    }
  }

  private static func nativeMessages(
    assistantContent: String,
    results: [CallResult],
    definitions: [ToolDefinition],
    mode: ToolCallingMode,
    echoReasoningContent: Bool
  ) -> [OpenAIMessage] {
    guard mode == .native, !results.isEmpty else { return [] }
    let resolver = AgentToolNameResolver(tools: definitions)
    let toolCalls = results.compactMap { item -> OpenAIMessageToolCall? in
      guard let id = item.call.toolCallID else { return nil }
      let canonical = resolver.canonicalName(for: item.call.name) ?? item.call.name
      let apiName = item.call.apiName ?? resolver.apiName(for: canonical)
      return OpenAIMessageToolCall(
        id: id,
        function: OpenAIMessageToolCallFunction(name: apiName, arguments: item.call.argsJSON))
    }
    guard toolCalls.count == results.count else { return [] }

    let content = MessageContentFilter.conversationContextText(from: assistantContent)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let assistant = OpenAIMessage(
      role: "assistant",
      content: content,
      reasoningContent: PromptComposer.reasoningContent(
        from: assistantContent,
        echoReasoningContent: echoReasoningContent),
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
    requestState: RequestState,
    conversation: Conversation,
    assistantID: UUID,
    roundIndex: Int,
    store: AppStore,
    parsedCalls: [ParsedToolCall] = [],
    results: [CallResult] = []
  ) {
    let firstCall = results.first?.call ?? parsedCalls.first
    let firstResult = results.first?.result ?? "Error: invalid tool call response."
    let resultText =
      results.isEmpty
      ? firstResult
      : results.map { "\($0.call.name) tool (\($0.call.argsJSON)):\n\($0.result)" }
        .joined(separator: "\n\n")
    let parsedDebugCalls = parsedCalls.map {
      ConversationDebugParsedToolCall(
        name: $0.name,
        argumentsJSON: $0.argsJSON,
        rawBlock: $0.rawBlock)
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
      effectiveMode: requestState.activeMode.rawValue,
      maxToolCallsPerTurn: maxToolCallsPerTurn(store: store),
      maxRepairTurnsPerTurn: maxRepairTurnsPerTurn(store: store),
      yoloModeEnabled: store.settings.yoloModeEnabled,
      useToolProxy: store.settings.useToolProxy,
      nativeToolCallingUnavailableReason: nativeToolCallingUnavailableReason(
        conversation: conversation,
        settings: store.settings,
        hasTools: !requestState.definitions.isEmpty),
      requestContext: requestState.context,
      toolPrompt: requestState.toolPrompt,
      nativeToolNames: requestState.nativeTools?.map { $0.function.name } ?? [],
      visibleToolDefinitions: requestState.definitions.map(debugDefinition),
      promptMessages: promptMessages,
      rawModelResponse: response,
      parsedToolCalls: parsedDebugCalls,
      outcome: outcome,
      toolName: firstCall?.name ?? "invalid_tool_call",
      argumentsJSON: firstCall?.argsJSON ?? "{}",
      result: resultText,
      isError: firstResult.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .hasPrefix("error:"),
      rawBlock: response)
    store.appendToolCallingDebugIteration(iteration, conversationID: conversation.id)
  }

  private static func debugPromptMessages(
    conversation: Conversation,
    requestState: RequestState,
    state: State,
    assistantID: UUID,
    store: AppStore
  ) -> [ConversationDebugPromptMessage] {
    let tailToolPrompt: String = {
      guard requestState.usesTextProtocol else { return "" }
      return state.completedToolRuns.isEmpty ? requestState.toolPrompt : ""
    }()
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
            context: requestState.context,
            hasTools: !requestState.definitions.isEmpty,
            toolPrompt: tailToolPrompt,
            toolPromptInContext: requestState.usesTextProtocol && !requestState.toolPrompt.isEmpty)
        ),
      ]
    }
    if conversation.provider == .openAICompatible,
      let endpoint = OpenAICompatibleProvider.selectedEndpoint(
        for: conversation,
        settings: store.settings)
    {
      let model = conversation.modelID.isEmpty ? endpoint.defaultModel : conversation.modelID
      return PromptComposer.openAIMessages(
        conversation: conversation,
        settings: store.settings,
        context: requestState.context,
        model: model,
        endpoint: endpoint,
        excludingMessageID: state.nativeContinuationMessages.isEmpty ? nil : assistantID,
        nativeContinuationMessages: state.nativeContinuation(
          conversation: conversation,
          requestState: requestState),
        toolPrompt: tailToolPrompt,
        toolPromptInContext: requestState.usesTextProtocol && !requestState.toolPrompt.isEmpty
      ).map(debugPromptMessage)
    }

    let baseSystem = PromptComposer.systemPrompt(
      settings: store.settings,
      conversation: conversation)
    let systemContent =
      requestState.context.isEmpty
      ? baseSystem
      : "\(baseSystem)\n\n## Context\n\(requestState.context)"
    var messages = [ConversationDebugPromptMessage(role: "system", content: systemContent)]
    let limited: [ChatMessage] = {
      if let limit = store.settings.contextWindowMode.messageLimit {
        return Array(conversation.messages.suffix(limit))
      }
      return conversation.messages
    }()
    messages.append(
      contentsOf: limited.flatMap { message in
        PromptComposer.contextTranscriptEntries(from: message, settings: store.settings).map {
          ConversationDebugPromptMessage(
            role: debugRole(displayName: $0.displayName),
            content: $0.content)
        }
      })
    if let reminder = PromptComposer.toolCallingReminder(
      toolPrompt: tailToolPrompt,
      includeToolPrompt: !(requestState.usesTextProtocol && !requestState.toolPrompt.isEmpty))
    {
      messages.append(ConversationDebugPromptMessage(role: "user", content: reminder))
    }
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
      content: message.textContent,
      reasoningContent: message.reasoningContent,
      toolCallsJSON: toolCallsJSON,
      toolCallID: message.toolCallID)
  }

  private static func debugRole(displayName: String) -> String {
    switch displayName {
    case ChatRole.system.displayName:
      return "system"
    case ChatRole.assistant.displayName:
      return "assistant"
    default:
      return "user"
    }
  }

  private static func currentVisibleDefinitions(
    conversationID: UUID,
    store: AppStore
  ) -> [ToolDefinition] {
    guard let conversation = store.conversation(withID: conversationID) else { return [] }
    return ToolAgentRegistry.visibleDefinitions(
      for: conversation,
      settings: store.settings,
      mcpTools: store.mcpTools,
      mcpResources: store.mcpResources)
  }

  private static func currentVisibleDefinitions(
    conversation: Conversation,
    settings: AppSettings,
    mcpTools: [UUID: [MCPToolDescriptor]],
    mcpResources: [UUID: [MCPResourceDescriptor]]
  ) -> [ToolDefinition] {
    ToolAgentRegistry.visibleDefinitions(
      for: conversation,
      settings: settings,
      mcpTools: mcpTools,
      mcpResources: mcpResources)
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

  private static func debugModelName(for conversation: Conversation, store: AppStore) -> String {
    if conversation.provider == .openAICompatible,
      conversation.modelID.isEmpty,
      let endpoint = OpenAICompatibleProvider.selectedEndpoint(
        for: conversation,
        settings: store.settings)
    {
      return endpoint.defaultModel
    }
    return conversation.modelID
  }

  private static func maxToolCallsPerTurn(store: AppStore) -> Int {
    maxToolCallsPerTurn(settings: store.settings)
  }

  private static func maxToolCallsPerTurn(settings: AppSettings) -> Int {
    min(20, max(1, settings.maxToolCallsPerTurn))
  }

  private static func maxRepairTurnsPerTurn(store: AppStore) -> Int {
    maxRepairTurnsPerTurn(settings: store.settings)
  }

  private static func maxRepairTurnsPerTurn(settings: AppSettings) -> Int {
    min(4, maxToolCallsPerTurn(settings: settings) + 1)
  }

  private static func nativeToolCallingUnavailableReason(
    conversation: Conversation,
    settings: AppSettings,
    hasTools: Bool
  ) -> String? {
    guard settings.toolCallingMode == .native, hasTools else { return nil }
    guard !conversation.provider.supportsNativeToolCalling else { return nil }
    return
      "\(conversation.provider.displayName) does not expose native tool calling; using \(settings.toolCallingMode.textProtocolFallback(for: conversation.provider).displayName) text fallback."
  }

  private static func debugDefinition(
    _ definition: ToolDefinition
  ) -> ConversationDebugToolDefinition {
    ConversationDebugToolDefinition(
      name: definition.name,
      description: definition.description,
      parameters: definition.parameters.map {
        ConversationDebugToolParameter(
          name: $0.name,
          type: $0.type,
          description: $0.description,
          required: $0.required)
      },
      inputSchemaJSON: definition.inputSchemaJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty ? nil : definition.inputSchemaJSON)
  }

  private static func toolCallFingerprint(_ call: ParsedToolCall) -> String {
    "\(call.name)\n\(call.argsJSON)"
  }

  private static func isSuccessfulToolResult(_ result: String) -> Bool {
    !isToolResultError(result)
  }

  private static func isToolResultError(_ result: String) -> Bool {
    result.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .hasPrefix("error:")
  }

  private static func shouldEchoReasoningContent(
    conversationID: UUID,
    store: AppStore
  ) -> Bool {
    guard let conversation = store.conversation(withID: conversationID) else {
      return false
    }
    return OpenAICompatibleProvider.shouldEchoReasoningContent(
      conversation: conversation,
      settings: store.settings)
  }

  private static func shouldEchoReasoningContent(
    conversation: Conversation,
    settings: AppSettings
  ) -> Bool {
    OpenAICompatibleProvider.shouldEchoReasoningContent(
      conversation: conversation,
      settings: settings)
  }

  private static func updateLocalAssistantMessage(
    id: UUID,
    text: String,
    conversation: inout Conversation
  ) {
    guard let index = conversation.messages.firstIndex(where: { $0.id == id }) else {
      return
    }
    conversation.messages[index].text = text
  }

  private static func userVisibleResponseText(from text: String) -> String {
    let visible = MessageContentFilter.render(text).visibleText
    return visible.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : visible
  }

  private static func combinedAssistantText(baseline: String, turnText: String) -> String {
    baseline.isEmpty ? turnText : "\(baseline)\n\n\(turnText)"
  }
}
