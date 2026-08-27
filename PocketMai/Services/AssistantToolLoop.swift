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

  private struct SkippedModelResponse: Error {
    let partialText: String
  }

  private struct State {
    var assistantText = ""
    var nativeContinuationMessages: [OpenAIMessage] = []
    var completedToolRuns: [String: String] = [:]
    var provisionalText = ""
    var debugRoundIndex = 0
    var toolCallCount = 0
    var repairTurnCount = 0

    mutating func append(_ turnText: String) -> String {
      assistantText = assistantText.isEmpty ? turnText : "\(assistantText)\n\n\(turnText)"
      return assistantText
    }

    var displayText: String {
      [assistantText, provisionalText]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    func displayText(appending turnText: String) -> String {
      [displayText, turnText.trimmingCharacters(in: .whitespacesAndNewlines)]
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    mutating func setProvisionalText(_ text: String?) {
      provisionalText = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    mutating func clearProvisionalText() {
      provisionalText = ""
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
    case retry(String, provisionalText: String?)
    case toolRun(RunOutput)
  }

  private enum ResponseAction {
    case final
    case askUser
    case noSolution

    init?(_ rawValue: String) {
      switch rawValue
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "-", with: "_")
      {
      case "final":
        self = .final
      case "ask_user":
        self = .askUser
      case "no_solution":
        self = .noSolution
      default:
        return nil
      }
    }
  }

  private enum ToolLoopResponseTool {
    static let name = "respond"

    static let definition = ToolDefinition(
      name: name,
      description:
        "Optionally return the user-visible response in tool-call form when no more host tool runs are needed.",
      parameters: [
        ToolParameterDef(
          name: "action",
          type: "string",
          description: "One of final, ask_user, or no_solution.",
          required: true),
        ToolParameterDef(
          name: "content",
          type: "string",
          description: "The user-visible response text.",
          required: true),
      ],
      inputSchemaJSON: """
        {"type":"object","properties":{"action":{"type":"string","enum":["final","ask_user","no_solution"],"description":"One of final, ask_user, or no_solution."},"content":{"type":"string","description":"The user-visible response text."}},"required":["action","content"]}
        """)
  }

  static func run(
    conversationID: UUID,
    assistantID: UUID,
    baseContext: String,
    store: AppStore
  ) async throws {
    var activeAssistantID = assistantID
    var state = State()
    var didFinish = false
    let maxToolCalls = maxToolCallsPerTurn(store: store)
    let maxRepairTurns = maxRepairTurnsPerTurn(store: store)

    store.clearToolCallingDebugIterations(
      conversationID: conversationID,
      assistantMessageID: activeAssistantID)

    if let conversation = store.conversation(withID: conversationID) {
      await store.refreshEnabledMCPServers(for: conversation)
    }

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
        assistantID: activeAssistantID,
        store: store)
      let response: String
      do {
        response = try await requestModelResponse(
          conversation: conversation,
          requestState: requestState,
          state: state,
          assistantID: activeAssistantID,
          store: store)
      } catch let skipped as SkippedModelResponse {
        state.clearProvisionalText()
        let partial = skipped.partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        let skippedTurn =
          partial.isEmpty
          ? "[model response skipped by user after timeout]"
          : "\(partial)\n\n[model response skipped by user after timeout]"
        store.setAssistantMessage(
          id: activeAssistantID,
          text: state.append(skippedTurn),
          role: .assistant)
        store.saveConversations()
        if let nextAssistantID = store.injectQueuedUserMessagesAndAppendAssistant(
          in: conversationID)
        {
          activeAssistantID = nextAssistantID
          state = State()
          store.clearToolCallingDebugIterations(
            conversationID: conversationID,
            assistantMessageID: activeAssistantID)
          continue
        }
        if !requestState.definitions.isEmpty {
          state.nativeContinuationMessages.removeAll()
          continue
        }
        store.assistantResponseCompleted()
        didFinish = true
        return
      }

      let outcome = try await outcome(
        response: response,
        requestState: requestState,
        conversationID: conversationID,
        assistantID: activeAssistantID,
        store: store,
        completedToolRuns: state.completedToolRuns,
        baselineText: state.displayText,
        remainingToolCalls: maxToolCalls - state.toolCallCount)

      switch outcome {
      case .final(let turnText):
        if shouldRetryHiddenOnlyFinal(turnText, state: state, maxRepairTurns: maxRepairTurns) {
          state.debugRoundIndex += 1
          state.repairTurnCount += 1
          appendDebugIteration(
            outcome: "retry",
            response: response,
            promptMessages: promptMessages,
            requestState: requestState,
            conversation: conversation,
            assistantID: activeAssistantID,
            roundIndex: state.debugRoundIndex,
            store: store)
          state.setProvisionalText(provisionalDisplayText(from: turnText))
          let canonicalText = state.append(
            missingPostToolActionFeedback(mode: requestState.activeMode))
          store.setAssistantMessage(id: activeAssistantID, text: canonicalText, role: .assistant)
          if !state.provisionalText.isEmpty {
            store.setAssistantMessage(
              id: activeAssistantID,
              text: state.displayText,
              role: .assistant,
              touch: false,
              streaming: true)
          }
          store.saveConversations()
          state.nativeContinuationMessages.removeAll()
          if let nextAssistantID = store.injectQueuedUserMessagesAndAppendAssistant(
            in: conversationID)
          {
            activeAssistantID = nextAssistantID
            state = State()
            store.clearToolCallingDebugIterations(
              conversationID: conversationID,
              assistantMessageID: activeAssistantID)
          }
          continue
        }
        state.clearProvisionalText()
        store.setAssistantMessage(
          id: activeAssistantID,
          text: state.append(turnText),
          role: .assistant)
        if let nextAssistantID = store.injectQueuedUserMessagesAndAppendAssistant(
          in: conversationID)
        {
          activeAssistantID = nextAssistantID
          state = State()
          store.clearToolCallingDebugIterations(
            conversationID: conversationID,
            assistantMessageID: activeAssistantID)
          continue
        }
        store.assistantResponseCompleted()
        didFinish = true
        return
      case .retry(let feedback, let provisionalText):
        state.debugRoundIndex += 1
        state.repairTurnCount += 1
        appendDebugIteration(
          outcome: "retry",
          response: response,
          promptMessages: promptMessages,
          requestState: requestState,
          conversation: conversation,
          assistantID: activeAssistantID,
          roundIndex: state.debugRoundIndex,
          store: store)
        state.setProvisionalText(provisionalText)
        let canonicalText = state.append(feedback)
        store.setAssistantMessage(id: activeAssistantID, text: canonicalText, role: .assistant)
        if !state.provisionalText.isEmpty {
          store.setAssistantMessage(
            id: activeAssistantID,
            text: state.displayText,
            role: .assistant,
            touch: false,
            streaming: true)
        }
        store.saveConversations()
        state.nativeContinuationMessages.removeAll()
        if let nextAssistantID = store.injectQueuedUserMessagesAndAppendAssistant(
          in: conversationID)
        {
          activeAssistantID = nextAssistantID
          state = State()
          store.clearToolCallingDebugIterations(
            conversationID: conversationID,
            assistantMessageID: activeAssistantID)
        }
      case .toolRun(let output):
        state.debugRoundIndex += 1
        appendDebugIteration(
          outcome: "toolRun",
          response: response,
          promptMessages: promptMessages,
          requestState: requestState,
          conversation: conversation,
          assistantID: activeAssistantID,
          roundIndex: state.debugRoundIndex,
          store: store,
          parsedCalls: output.parsedCalls,
          results: output.results)
        store.setAssistantMessage(
          id: activeAssistantID, text: state.append(output.text), role: .assistant)
        if !state.provisionalText.isEmpty {
          store.setAssistantMessage(
            id: activeAssistantID,
            text: state.displayText,
            role: .assistant,
            touch: false,
            streaming: true)
        }
        store.saveConversations()
        for completedRun in output.completedRuns where isSuccessfulToolResult(completedRun.result) {
          state.completedToolRuns[completedRun.fingerprint] = completedRun.result
        }
        state.toolCallCount += output.results.count
        state.applyNativeContinuation(
          output.nativeMessages,
          conversation: conversation,
          requestState: requestState)
        if let nextAssistantID = store.injectQueuedUserMessagesAndAppendAssistant(
          in: conversationID)
        {
          activeAssistantID = nextAssistantID
          state = State()
          store.clearToolCallingDebugIterations(
            conversationID: conversationID,
            assistantMessageID: activeAssistantID)
        }
      }
    }

    if !didFinish {
      let suffix =
        "\n\nTool loop stopped after \(state.toolCallCount) of \(maxToolCalls) allowed tool call\(maxToolCalls == 1 ? "" : "s") and \(state.repairTurnCount) repair turn\(state.repairTurnCount == 1 ? "" : "s") before the model produced a final answer."
      let text =
        state.displayText.isEmpty
        ? suffix.trimmingCharacters(in: .whitespacesAndNewlines) : state.displayText + suffix
      store.setAssistantMessage(
        id: activeAssistantID,
        text: text,
        role: .assistant)
      if let nextAssistantID = store.injectQueuedUserMessagesAndAppendAssistant(
        in: conversationID)
      {
        try await run(
          conversationID: conversationID,
          assistantID: nextAssistantID,
          baseContext: baseContext,
          store: store)
      }
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

    await store.refreshEnabledMCPServers(for: conversation, settings: settings)

    while state.toolCallCount < maxToolCalls && state.repairTurnCount < maxRepairTurns {
      try Task.checkCancellation()
      let requestState = makeRequestState(
        conversation: conversation,
        baseContext: baseContext,
        settings: settings,
        mcpTools: store.mcpTools,
        mcpResources: store.mcpResources,
        mcpStatuses: store.mcpStatuses)
      let response = try await requestModelResponseIsolated(
        conversation: conversation,
        requestState: requestState,
        state: state,
        assistantID: assistantID,
        settings: settings,
        store: store)

      let outcome = try await isolatedOutcome(
        response: response,
        requestState: requestState,
        conversation: conversation,
        settings: settings,
        mcpTools: store.mcpTools,
        mcpResources: store.mcpResources,
        mcpStatuses: store.mcpStatuses,
        store: store,
        completedToolRuns: state.completedToolRuns,
        remainingToolCalls: maxToolCalls - state.toolCallCount)

      switch outcome {
      case .final(let turnText):
        if shouldRetryHiddenOnlyFinal(turnText, state: state, maxRepairTurns: maxRepairTurns) {
          state.debugRoundIndex += 1
          state.repairTurnCount += 1
          let text = state.append(missingPostToolActionFeedback(mode: requestState.activeMode))
          updateLocalAssistantMessage(id: assistantID, text: text, conversation: &conversation)
          state.nativeContinuationMessages.removeAll()
          continue
        }
        state.clearProvisionalText()
        let text = state.append(turnText)
        updateLocalAssistantMessage(id: assistantID, text: text, conversation: &conversation)
        return IsolatedResult(
          text: userVisibleResponseText(from: text),
          toolRuns: toolRuns)
      case .retry(let feedback, _):
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
    let userInputTokens = state.toolCallCount == 0 && state.repairTurnCount == 0
      ? userInputTokenEstimate(in: conversation, before: assistantID)
      : nil
    let request = ChatCompletionRequest(
      conversation: conversation,
      settings: store.settings,
      context: requestState.context,
      assistantMessageID: assistantID,
      userInputTokens: userInputTokens,
      nativeTools: requestState.nativeTools,
      nativeContinuationMessages: state.nativeContinuation(
        conversation: conversation,
        requestState: requestState),
      hasToolCalling: !requestState.definitions.isEmpty,
      toolPrompt: tailToolPrompt,
      toolPromptInContext: requestState.usesTextProtocol && !requestState.toolPrompt.isEmpty
    )
    var latestStreamedResponse = ""
    let response: String
    do {
      response = try await ChatProviderRouter.complete(
        request: request,
        timeoutHandler: timeoutHandler(store: store)
      ) { [weak store] streamed in
        latestStreamedResponse = streamed
        let turnText =
          requestState.definitions.isEmpty
          ? AppStore.strippedSpuriousToolCallText(streamed) : streamed
        store?.receiveStreamingAssistantText(
          state.displayText(appending: turnText),
          for: assistantID,
          vibrate: request.conversation.usesStreaming)
      }
    } catch is LongRunningOperationSkipped {
      let partial =
        requestState.definitions.isEmpty
        ? AppStore.strippedSpuriousToolCallText(latestStreamedResponse)
        : latestStreamedResponse
      throw SkippedModelResponse(partialText: partial)
    }
    try Task.checkCancellation()
    if let stats = UsageStatsStore.shared.pendingStats(for: assistantID) {
      store.attachGenerationStats(stats, toMessage: assistantID)
    }
    return requestState.definitions.isEmpty
      ? AppStore.strippedSpuriousToolCallText(response)
      : response
  }

  private static func requestModelResponseIsolated(
    conversation: Conversation,
    requestState: RequestState,
    state: State,
    assistantID: UUID,
    settings: AppSettings,
    store: AppStore
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
    var latestStreamedResponse = ""
    let response: String
    do {
      response = try await ChatProviderRouter.complete(
        request: request,
        timeoutHandler: timeoutHandler(store: store)
      ) { streamed in
        latestStreamedResponse = streamed
      }
    } catch is LongRunningOperationSkipped {
      let partial =
        requestState.definitions.isEmpty
        ? AppStore.strippedSpuriousToolCallText(latestStreamedResponse)
        : latestStreamedResponse
      return partial.isEmpty
        ? "[model response skipped by user after timeout]"
        : "\(partial)\n\n[model response skipped by user after timeout]"
    }
    try Task.checkCancellation()
    return requestState.definitions.isEmpty
      ? AppStore.strippedSpuriousToolCallText(response)
      : response
  }

  private static func timeoutHandler(store: AppStore) -> LongRunningOperationTimeoutHandler {
    { [weak store] context in
      guard let store else { return .interrupt }
      return await store.requestLongRunningOperationDecision(context)
    }
  }

  /// Counts only the user messages that started this assistant turn, excluding
  /// prior context, tool output, and the generated system prompt.
  private static func userInputTokenEstimate(in conversation: Conversation, before assistantID: UUID)
    -> Int?
  {
    guard let assistantIndex = conversation.messages.firstIndex(where: { $0.id == assistantID }) else {
      return nil
    }
    let turnMessages = conversation.messages[..<assistantIndex]
      .reversed()
      .prefix { $0.role != .assistant }
      .filter { $0.role == .user }
    let characters = turnMessages.reduce(0) { total, message in
      total + MessageContentFilter.promptSafeText(from: message.text).count
    }
    guard characters > 0 else { return nil }
    return GenerationStats.estimatedTokenCount(forCharacterCount: characters)
  }

  private static func outcome(
    response: String,
    requestState: RequestState,
    conversationID: UUID,
    assistantID: UUID,
    store: AppStore,
    completedToolRuns: [String: String],
    baselineText: String,
    remainingToolCalls: Int
  ) async throws -> Outcome {
    guard !requestState.definitions.isEmpty else { return .final(response) }

    let currentDefinitions = currentVisibleDefinitions(
      conversationID: conversationID,
      store: store)
    let hostDefinitions =
      currentDefinitions.isEmpty ? requestState.definitions : currentDefinitions
    let parseDefinitions = toolLoopDefinitions(for: hostDefinitions)
    let calls = ToolAgentRegistry.parseCalls(
      in: response,
      definitions: parseDefinitions,
      mode: requestState.activeMode)

    guard !calls.isEmpty else {
      if let outcome = noToolCallOutcome(
        response: response,
        mode: requestState.activeMode,
        tools: parseDefinitions,
        completedToolRuns: completedToolRuns,
        remainingToolCalls: remainingToolCalls)
      {
        return outcome
      }
      return .final(response)
    }

    if let responseOutcome = responseToolOutcome(
      calls: calls,
      definitions: parseDefinitions,
      mode: requestState.activeMode)
    {
      return responseOutcome
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
      assistantID: assistantID,
      baselineText: baselineText,
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
    mcpStatuses: [UUID: EndpointConnectionState],
    store: AppStore,
    completedToolRuns: [String: String],
    remainingToolCalls: Int
  ) async throws -> Outcome {
    guard !requestState.definitions.isEmpty else { return .final(response) }

    let currentDefinitions = currentVisibleDefinitions(
      conversation: conversation,
      settings: settings,
      mcpTools: mcpTools,
      mcpResources: mcpResources,
      mcpStatuses: mcpStatuses)
    let hostDefinitions =
      currentDefinitions.isEmpty ? requestState.definitions : currentDefinitions
    let parseDefinitions = toolLoopDefinitions(for: hostDefinitions)
    let calls = ToolAgentRegistry.parseCalls(
      in: response,
      definitions: parseDefinitions,
      mode: requestState.activeMode)

    guard !calls.isEmpty else {
      if let outcome = noToolCallOutcome(
        response: response,
        mode: requestState.activeMode,
        tools: parseDefinitions,
        completedToolRuns: completedToolRuns,
        remainingToolCalls: remainingToolCalls)
      {
        return outcome
      }
      return .final(response)
    }

    if let responseOutcome = responseToolOutcome(
      calls: calls,
      definitions: parseDefinitions,
      mode: requestState.activeMode)
    {
      return responseOutcome
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
      mcpStatuses: mcpStatuses,
      store: store)
    return .toolRun(output)
  }

  private static func runToolCalls(
    response: String,
    calls: [ParsedToolCall],
    remainingToolCalls: Int,
    parseDefinitions: [ToolDefinition],
    mode: ToolCallingMode,
    assistantID: UUID,
    baselineText: String,
    conversationID: UUID,
    store: AppStore
  ) async throws -> RunOutput {
    publishPendingToolRuns(
      response: response,
      calls: calls,
      remainingToolCalls: remainingToolCalls,
      parseDefinitions: parseDefinitions,
      assistantID: assistantID,
      baselineText: baselineText,
      store: store)

    var transcriptText = response
    var assistantContent = response
    var appendedRunBlocks: [String] = []
    var results: [CallResult] = []
    var completedRuns: [(fingerprint: String, result: String)] = []
    var executedCount = 0

    for call in calls {
      try Task.checkCancellation()
      // Feedback queued after this provider response takes precedence over
      // tool calls that have not started yet. Already-running tools finish,
      // then the loop injects the feedback before asking the model again.
      guard !store.hasQueuedUserMessages(in: conversationID) else { break }
      replaceFirstOccurrence(of: call.rawBlock, in: &assistantContent, with: "")
      guard executedCount < remainingToolCalls else {
        replaceFirstOccurrence(of: call.rawBlock, in: &transcriptText, with: "")
        continue
      }
      let result = try await runToolCall(
        call,
        parseDefinitions: parseDefinitions,
        mode: mode,
        assistantID: assistantID,
        conversationID: conversationID,
        store: store)
      let runBlock = ToolAgentRegistry.makeRunBlock(call: result.call, result: result.result)
      if !replaceFirstOccurrence(of: call.rawBlock, in: &transcriptText, with: runBlock) {
        appendedRunBlocks.append(runBlock)
      }
      results.append(result)
      completedRuns.append((toolCallFingerprint(result.call), result.result))
      executedCount += 1
      publishToolRunProgress(
        transcriptText: transcriptText,
        appendedRunBlocks: appendedRunBlocks,
        pendingCalls: Array(calls.dropFirst(executedCount)),
        remainingToolCalls: max(0, remainingToolCalls - executedCount),
        parseDefinitions: parseDefinitions,
        assistantID: assistantID,
        baselineText: baselineText,
        store: store)
    }

    let text = ([transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)]
      + appendedRunBlocks)
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .joined(separator: "\n\n")
    return RunOutput(
      text: text,
      nativeMessages: nativeMessages(
        assistantContent: assistantContent,
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

  private static func publishPendingToolRuns(
    response: String,
    calls: [ParsedToolCall],
    remainingToolCalls: Int,
    parseDefinitions: [ToolDefinition],
    assistantID: UUID,
    baselineText: String,
    store: AppStore
  ) {
    let text = pendingToolRunText(
      response: response,
      calls: calls,
      remainingToolCalls: remainingToolCalls,
      parseDefinitions: parseDefinitions)
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    store.setAssistantMessage(
      id: assistantID,
      text: combinedAssistantText(baseline: baselineText, turnText: text),
      role: .assistant,
      touch: false)
    store.saveConversations()
  }

  private static func publishToolRunProgress(
    transcriptText: String,
    appendedRunBlocks: [String],
    pendingCalls: [ParsedToolCall],
    remainingToolCalls: Int,
    parseDefinitions: [ToolDefinition],
    assistantID: UUID,
    baselineText: String,
    store: AppStore
  ) {
    let pendingText = pendingToolRunText(
      response: transcriptText,
      calls: pendingCalls,
      remainingToolCalls: remainingToolCalls,
      parseDefinitions: parseDefinitions)
    let turnText = ([pendingText] + appendedRunBlocks)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
    store.setAssistantMessage(
      id: assistantID,
      text: combinedAssistantText(baseline: baselineText, turnText: turnText),
      role: .assistant,
      touch: false)
    store.saveConversations()
  }

  private static func pendingToolRunText(
    response: String,
    calls: [ParsedToolCall],
    remainingToolCalls: Int,
    parseDefinitions: [ToolDefinition]
  ) -> String {
    var transcriptText = response
    var appendedRunBlocks: [String] = []
    var pendingCount = 0
    for call in calls {
      guard pendingCount < remainingToolCalls else {
        replaceFirstOccurrence(of: call.rawBlock, in: &transcriptText, with: "")
        continue
      }
      let normalizedCall = ToolAgentRegistry.normalized(call: call, definitions: parseDefinitions)
      let runBlock = ToolAgentRegistry.makeRunBlock(
        call: normalizedCall,
        result: "Waiting for host tool result.")
      if !replaceFirstOccurrence(of: call.rawBlock, in: &transcriptText, with: runBlock) {
        appendedRunBlocks.append(runBlock)
      }
      pendingCount += 1
    }
    return ([transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)]
      + appendedRunBlocks)
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .joined(separator: "\n\n")
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
    mcpStatuses: [UUID: EndpointConnectionState],
    store: AppStore
  ) async throws -> RunOutput {
    var transcriptText = response
    var assistantContent = response
    var appendedRunBlocks: [String] = []
    var results: [CallResult] = []
    var completedRuns: [(fingerprint: String, result: String)] = []
    var executedCount = 0

    for call in calls {
      try Task.checkCancellation()
      replaceFirstOccurrence(of: call.rawBlock, in: &assistantContent, with: "")
      guard executedCount < remainingToolCalls else {
        replaceFirstOccurrence(of: call.rawBlock, in: &transcriptText, with: "")
        continue
      }
      let result = try await runToolCall(
        call,
        parseDefinitions: parseDefinitions,
        mode: mode,
        conversation: conversation,
        settings: settings,
        mcpTools: mcpTools,
        mcpResources: mcpResources,
        mcpStatuses: mcpStatuses,
        store: store)
      let runBlock = ToolAgentRegistry.makeRunBlock(call: result.call, result: result.result)
      if !replaceFirstOccurrence(of: call.rawBlock, in: &transcriptText, with: runBlock) {
        appendedRunBlocks.append(runBlock)
      }
      results.append(result)
      completedRuns.append((toolCallFingerprint(result.call), result.result))
      executedCount += 1
    }

    let text = ([transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)]
      + appendedRunBlocks)
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .joined(separator: "\n\n")
    return RunOutput(
      text: text,
      nativeMessages: nativeMessages(
        assistantContent: assistantContent,
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
    assistantID: UUID,
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
    if store.hasQueuedUserMessages(in: conversationID) {
      return CallResult(
        call: approvedCall,
        result: "Error: tool call skipped because the user queued new instructions.")
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

    let timeout = store.settings.mcpRequestTimeoutInterval
    let context = LongRunningOperationContext(
      kind: .toolCall,
      conversationID: conversationID,
      assistantMessageID: assistantID,
      operationName: executableCall.name,
      conversationTitle: store.conversation(withID: conversationID)?.displayTitle,
      timeoutInterval: timeout)
    do {
      let result = try await InteractiveOperationTimeout.run(
        seconds: timeout,
        context: context,
        onTimeout: timeoutHandler(store: store)
      ) {
        await ToolAgentRegistry.execute(
          call: executableCall,
          conversationID: conversationID,
          store: store)
      }
      return CallResult(call: executableCall, result: result)
    } catch is LongRunningOperationSkipped {
      return CallResult(
        call: executableCall,
        result: "Error: tool call skipped by user after timeout.")
    }
  }

  private static func runToolCall(
    _ call: ParsedToolCall,
    parseDefinitions: [ToolDefinition],
    mode: ToolCallingMode,
    conversation: Conversation,
    settings: AppSettings,
    mcpTools: [UUID: [MCPToolDescriptor]],
    mcpResources: [UUID: [MCPResourceDescriptor]],
    mcpStatuses: [UUID: EndpointConnectionState],
    store: AppStore
  ) async throws -> CallResult {
    let currentDefinitions = currentVisibleDefinitions(
      conversation: conversation,
      settings: settings,
      mcpTools: mcpTools,
      mcpResources: mcpResources,
      mcpStatuses: mcpStatuses)
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
      mcpResources: mcpResources,
      mcpStatuses: mcpStatuses)
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

    let timeout = settings.mcpRequestTimeoutInterval
    let context = LongRunningOperationContext(
      kind: .toolCall,
      conversationID: conversation.id,
      assistantMessageID: nil,
      operationName: executableCall.name,
      conversationTitle: conversation.displayTitle,
      timeoutInterval: timeout)
    do {
      let result = try await InteractiveOperationTimeout.run(
        seconds: timeout,
        context: context,
        onTimeout: timeoutHandler(store: store)
      ) {
        await ToolAgentRegistry.execute(
          call: executableCall,
          conversation: conversation,
          store: store)
      }
      return CallResult(call: executableCall, result: result)
    } catch is LongRunningOperationSkipped {
      return CallResult(
        call: executableCall,
        result: "Error: tool call skipped by user after timeout.")
    }
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
      mcpResources: store.mcpResources,
      mcpStatuses: store.mcpStatuses)
  }

  private static func makeRequestState(
    conversation: Conversation,
    baseContext: String,
    settings: AppSettings,
    mcpTools: [UUID: [MCPToolDescriptor]],
    mcpResources: [UUID: [MCPResourceDescriptor]],
    mcpStatuses: [UUID: EndpointConnectionState]
  ) -> RequestState {
    let visibleDefinitions = ToolAgentRegistry.visibleDefinitions(
      for: conversation,
      settings: settings,
      mcpTools: mcpTools,
      mcpResources: mcpResources,
      mcpStatuses: mcpStatuses)
    let loopDefinitions = toolLoopDefinitions(for: visibleDefinitions)
    let nativeTools = nativeToolsIfNeeded(
      conversation: conversation,
      settings: settings,
      definitions: loopDefinitions)
    let activeMode =
      nativeTools == nil
      ? settings.toolCallingMode.textProtocolFallback(for: conversation.provider)
      : .native
    let toolPrompt =
      nativeTools == nil
      ? ToolAgentRegistry.promptDescription(for: loopDefinitions, mode: activeMode)
      : nativeToolLoopPrompt()
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

  private static func toolLoopDefinitions(for definitions: [ToolDefinition]) -> [ToolDefinition] {
    guard !definitions.isEmpty else { return [] }
    return definitions + [ToolLoopResponseTool.definition]
  }

  private static func nativeToolLoopPrompt() -> String {
    """
    When tools are available, use the provided native tools. After a host tool result, call another host tool if another host tool run is needed. If the result is enough, give the final answer directly. Do not describe a future tool call in prose.
    """
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
    let limited = PromptComposer.contextMessages(
      from: conversation,
      settings: store.settings,
      limit: store.settings.contextWindowMode.messageLimit)
    let metadata = MessageMetadataAnnotation.annotations(for: conversation)
    messages.append(
      contentsOf: limited.flatMap { message in
        PromptComposer.contextTranscriptEntries(
          from: message, settings: store.settings, metadataPrefix: metadata[message.id]
        ).map {
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
      mcpResources: store.mcpResources,
      mcpStatuses: store.mcpStatuses)
  }

  private static func currentVisibleDefinitions(
    conversation: Conversation,
    settings: AppSettings,
    mcpTools: [UUID: [MCPToolDescriptor]],
    mcpResources: [UUID: [MCPResourceDescriptor]],
    mcpStatuses: [UUID: EndpointConnectionState]
  ) -> [ToolDefinition] {
    ToolAgentRegistry.visibleDefinitions(
      for: conversation,
      settings: settings,
      mcpTools: mcpTools,
      mcpResources: mcpResources,
      mcpStatuses: mcpStatuses)
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

  private static func noToolCallOutcome(
    response: String,
    mode: ToolCallingMode,
    tools: [ToolDefinition],
    completedToolRuns: [String: String],
    remainingToolCalls: Int
  ) -> Outcome? {
    if AgentTooling.containsToolCallMarker(in: response, mode: mode) {
      return .retry(
        AgentTooling.malformedToolCallFeedback(from: response, mode: mode, tools: tools)
          .trimmingCharacters(in: .whitespacesAndNewlines),
        provisionalText: nil)
    }
    if AgentTooling.containsNonToolJSONToolLoopObject(in: response, tools: tools) {
      return .retry(
        AgentTooling.nonToolJSONToolLoopFeedback(from: response, mode: mode, tools: tools)
          .trimmingCharacters(in: .whitespacesAndNewlines),
        provisionalText: nil)
    }
    guard !completedToolRuns.isEmpty else { return nil }
    if hasVisibleText(response) { return nil }
    guard remainingToolCalls > 0 else { return nil }
    return .retry(
      missingPostToolActionFeedback(mode: mode),
      provisionalText: provisionalDisplayText(from: response))
  }

  private static func shouldRetryHiddenOnlyFinal(
    _ response: String,
    state: State,
    maxRepairTurns: Int
  ) -> Bool {
    state.toolCallCount > 0
      && state.repairTurnCount < maxRepairTurns
      && !hasVisibleText(response)
  }

  private static func responseToolOutcome(
    calls: [ParsedToolCall],
    definitions: [ToolDefinition],
    mode: ToolCallingMode
  ) -> Outcome? {
    let normalizedCalls = calls.map {
      ToolAgentRegistry.normalized(call: $0, definitions: definitions)
    }
    guard normalizedCalls.contains(where: { $0.name == ToolLoopResponseTool.name }) else {
      return nil
    }
    guard normalizedCalls.count == 1, let call = normalizedCalls.first else {
      return .retry(
        invalidResponseToolFeedback(
          mode: mode,
          message:
            "Error: respond must be the only tool call in this assistant turn."),
        provisionalText: nil)
    }
    let actionText = call.argumentValues["action"]?.stringValue ?? ""
    guard ResponseAction(actionText) != nil else {
      return .retry(
        invalidResponseToolFeedback(
          mode: mode,
          message:
            "Error: respond action must be one of final, ask_user, or no_solution."),
        provisionalText: nil)
    }
    let content = (call.argumentValues["content"]?.stringValue ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !content.isEmpty else {
      return .retry(emptyToolResponseFeedback(mode: mode), provisionalText: nil)
    }
    return .final(content)
  }

  private static func provisionalDisplayText(from response: String) -> String? {
    let rendered = MessageContentFilter.render(response)
    let visible = rendered.visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !visible.isEmpty else { return nil }
    return response.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func hasVisibleText(_ response: String) -> Bool {
    !MessageContentFilter.render(response).visibleText
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty
  }

  private static func missingPostToolActionFeedback(mode: ToolCallingMode) -> String {
    AgentTooling.makeRunBlock(
      toolName: "missing_tool_call",
      argumentsJSON: "{}",
      result: missingPostToolActionMessage(mode: mode)
    ).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func emptyToolResponseFeedback(mode: ToolCallingMode) -> String {
    AgentTooling.makeRunBlock(
      toolName: "invalid_respond",
      argumentsJSON: "{}",
      result:
        "Error: respond content is empty. Emit a host tool call if another host tool run is needed, or call respond with non-empty user-visible content."
    ).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func invalidResponseToolFeedback(mode: ToolCallingMode, message: String) -> String
  {
    return AgentTooling.makeRunBlock(
      toolName: "invalid_respond",
      argumentsJSON: "{}",
      result: "\(message)\n\n\(missingPostToolActionMessage(mode: mode))"
    ).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func missingPostToolActionMessage(mode: ToolCallingMode) -> String {
    switch mode {
    case .native:
      return
        "After a host tool result, call one provided native tool if another host tool run is needed, or give the final answer directly if the result is enough. Do not write prose that announces a future tool call."
    case .text, .xml, .json:
      return """
        After a host tool result, give the final answer directly if the result is enough.

        If another host tool run is needed, emit exactly one tool call in the configured \(mode.displayName) format. You may also call \(ToolLoopResponseTool.name) with final content:
        \(responseToolExample(mode: mode))
        """
    }
  }

  private static func responseToolExample(mode: ToolCallingMode) -> String {
    let call = ParsedToolCall(
      name: ToolLoopResponseTool.name,
      arguments: [
        "action": "final",
        "content": "The user-visible answer goes here.",
      ],
      rawBlock: "")
    return AgentTooling.editableToolCallText(for: call, mode: mode)
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
    let normalized = result.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return normalized.hasPrefix("error:") || normalized.hasPrefix("error calling ")
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

  @discardableResult
  private static func replaceFirstOccurrence(
    of target: String,
    in text: inout String,
    with replacement: String
  ) -> Bool {
    guard !target.isEmpty, let range = text.range(of: target) else {
      return false
    }
    text.replaceSubrange(range, with: replacement)
    return true
  }
}
