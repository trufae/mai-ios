import Foundation

/// UI-independent orchestration for providers, tools, approvals, MCP tools,
/// and bounded child-agent runs. Hosts own presentation and persistence and
/// observe work through `AgentEvent` values.
public actor AgentRuntime {
  public static let subagentToolName = "spawn_agent"

  private var providers: [ProviderID: any ChatProvider] = [:]
  private var tools: [String: any AgentTool] = [:]
  private var agents: [String: AgentDefinition] = [:]
  private let approvalHandler: any ApprovalHandler

  public init(approvalHandler: any ApprovalHandler = DenyInteractiveApprovals()) {
    self.approvalHandler = approvalHandler
  }

  /// Adds any provider implementation to the runtime by its descriptor ID.
  public func register(
    _ provider: any ChatProvider,
    replacingExisting: Bool = false
  ) throws {
    let descriptor = provider.descriptor
    let rawID = descriptor.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rawID.isEmpty else { throw AgentRuntimeError.invalidProviderID }
    guard replacingExisting || providers[descriptor.id] == nil else {
      throw AgentRuntimeError.providerAlreadyRegistered(descriptor.id)
    }
    providers[descriptor.id] = provider
  }

  public func register(
    tool: any AgentTool,
    replacingExisting: Bool = false
  ) throws {
    let name = tool.definition.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw AgentToolError.invalidName }
    guard name != Self.subagentToolName else {
      throw AgentRuntimeError.reservedToolName(name)
    }
    guard replacingExisting || tools[name] == nil else {
      throw AgentToolError.duplicateName(name)
    }
    tools[name] = tool
  }

  public func register(
    agent: AgentDefinition,
    replacingExisting: Bool = false
  ) throws {
    let id = agent.id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty else { throw AgentRuntimeError.invalidAgentID }
    guard replacingExisting || agents[id] == nil else {
      throw AgentRuntimeError.agentAlreadyRegistered(id)
    }
    agents[id] = agent
  }

  @discardableResult
  public func register(
    mcp source: any MCPToolSource,
    replacingExistingTools: Bool = false
  ) async throws -> MCPServerCatalog {
    let catalog = try await source.connect()
    for tool in try await source.agentTools() {
      try register(tool: tool, replacingExisting: replacingExistingTools)
    }
    return catalog
  }

  public func availableProviders() -> [ProviderDescriptor] {
    providers.values.map(\.descriptor).sorted {
      $0.id.rawValue.localizedStandardCompare($1.id.rawValue) == .orderedAscending
    }
  }

  public func availableModels(provider id: ProviderID) async throws -> [ModelDescriptor] {
    guard let provider = providers[id] else {
      throw AgentRuntimeError.providerNotRegistered(id)
    }
    return try await provider.availableModels().sorted {
      $0.id.localizedStandardCompare($1.id) == .orderedAscending
    }
  }

  public func availableTools() -> [ToolDefinition] {
    tools.values.map(\.definition).sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  public func availableAgents() -> [AgentDefinition] {
    agents.values.sorted {
      $0.id.localizedStandardCompare($1.id) == .orderedAscending
    }
  }

  public func run(
    agentID: String,
    messages: [AgentMessage],
    emit: @escaping AgentEventHandler = { _ in }
  ) async throws -> AgentResult {
    guard let definition = agents[agentID] else {
      throw AgentRuntimeError.agentNotRegistered(agentID)
    }
    let request = request(for: definition, messages: messages)
    return try await run(request, emit: emit)
  }

  public func run(
    _ request: AgentRequest,
    emit: @escaping AgentEventHandler = { _ in }
  ) async throws -> AgentResult {
    let budget = RunBudget(limits: request.limits)
    return try await runInternal(
      request,
      runID: UUID(),
      parentRunID: nil,
      depth: 0,
      budget: budget,
      emit: emit)
  }

  private func runInternal(
    _ request: AgentRequest,
    runID: UUID,
    parentRunID: UUID?,
    depth: Int,
    budget: RunBudget,
    emit: @escaping AgentEventHandler
  ) async throws -> AgentResult {
    try Task.checkCancellation()
    guard let provider = providers[request.provider] else {
      throw AgentRuntimeError.providerNotRegistered(request.provider)
    }

    let context = AgentEventContext(
      runID: runID,
      parentRunID: parentRunID,
      agentID: request.agentID,
      depth: depth)
    let definitions = try visibleDefinitions(for: request)
    let supportsNativeTools = provider.descriptor.capabilities.contains(.nativeToolCalling)
    if request.toolCallingStrategy == .native, !definitions.isEmpty, !supportsNativeTools {
      throw AgentRuntimeError.nativeToolCallingUnavailable(request.provider)
    }
    let textToolMode: ToolCallingMode?
    switch request.toolCallingStrategy {
    case .automatic:
      textToolMode = definitions.isEmpty || supportsNativeTools ? nil : .json
    case .native:
      textToolMode = nil
    case .text:
      textToolMode = definitions.isEmpty ? nil : .text
    case .xml:
      textToolMode = definitions.isEmpty ? nil : .xml
    case .json:
      textToolMode = definitions.isEmpty ? nil : .json
    }
    let usesTextToolProtocol = textToolMode != nil
    var transcript = request.messages
    var totalUsage: TokenUsage?
    var localModelTurns = 0
    var localToolCalls = 0
    var fingerprints = Set<String>()

    await emit(.started(context, provider.descriptor))
    while localModelTurns < request.limits.maxModelTurns {
      try Task.checkCancellation()
      guard await budget.claimModelTurn() else {
        throw AgentRuntimeError.limitExceeded("model turns")
      }
      localModelTurns += 1
      await emit(.modelStarted(context, turn: localModelTurns))

      var providerMessages = transcript
      if let textToolMode {
        let insertionIndex =
          providerMessages.firstIndex {
            $0.role != .system && $0.role != .developer
          } ?? providerMessages.endIndex
        providerMessages.insert(
          .system(textToolPrompt(definitions, mode: textToolMode)), at: insertionIndex)
      }
      var providerResponse = try await provider.complete(
        ProviderRequest(
          model: request.model,
          messages: providerMessages,
          tools: usesTextToolProtocol ? [] : definitions,
          toolChoice: definitions.isEmpty || usesTextToolProtocol ? .none : request.toolChoice,
          responseFormat: request.responseFormat,
          options: request.options,
          stream: usesTextToolProtocol ? false : request.stream)
      ) { event in
        if usesTextToolProtocol, case .textDelta = event {
          return
        }
        await emit(.provider(context, event))
      }
      try Task.checkCancellation()
      if let textToolMode,
        let call = textToolCall(
          in: providerResponse.message.text,
          definitions: definitions,
          mode: textToolMode)
      {
        var content = providerResponse.message.content.filter {
          if case .reasoning = $0 { return true }
          return false
        }
        content.append(.toolCall(call))
        providerResponse.message.content = content
        providerResponse.stopReason = .toolCall
        await emit(
          .provider(
            context,
            .toolCallDelta(
              ToolCallDelta(
                index: 0,
                id: call.id,
                name: call.name,
                argumentsFragment: call.arguments.compactJSONString))))
      } else if usesTextToolProtocol, !providerResponse.message.text.isEmpty {
        await emit(.provider(context, .textDelta(providerResponse.message.text)))
      }
      totalUsage = totalUsage.merging(providerResponse.usage)
      if let usage = providerResponse.usage,
        !(await budget.record(tokens: usage.totalTokens))
      {
        throw AgentRuntimeError.limitExceeded("token budget")
      }
      transcript.append(providerResponse.message)

      let calls = providerResponse.message.toolCalls
      if calls.isEmpty {
        let result = AgentResult(
          runID: context.runID,
          agentID: request.agentID,
          provider: request.provider,
          response: providerResponse.message,
          transcript: transcript,
          usage: totalUsage,
          stopReason: providerResponse.stopReason,
          modelTurns: localModelTurns,
          toolCalls: localToolCalls)
        await emit(.finished(context, result))
        return result
      }

      for call in calls {
        try Task.checkCancellation()
        guard localToolCalls < request.limits.maxToolCalls,
          await budget.claimToolCall()
        else {
          throw AgentRuntimeError.limitExceeded("tool calls")
        }
        localToolCalls += 1
        let fingerprint = "\(call.name)\n\(call.arguments.compactJSONString)"
        let result: ToolResult
        if fingerprints.insert(fingerprint).inserted {
          result = try await execute(
            call,
            definitions: definitions,
            request: request,
            context: context,
            modelTurn: localModelTurns,
            depth: depth,
            budget: budget,
            emit: emit)
        } else {
          result = ToolResult(
            callID: call.id,
            text: "Error: refusing to repeat an identical tool call.",
            isError: true)
          await emit(.toolFinished(context, result))
        }
        transcript.append(
          AgentMessage(role: .tool, content: [.toolResult(result)]))
      }
    }
    throw AgentRuntimeError.limitExceeded("model turns")
  }

  private func execute(
    _ call: ToolCall,
    definitions: [ToolDefinition],
    request: AgentRequest,
    context: AgentEventContext,
    modelTurn: Int,
    depth: Int,
    budget: RunBudget,
    emit: @escaping AgentEventHandler
  ) async throws -> ToolResult {
    guard let definition = definitions.first(where: { $0.name == call.name }) else {
      let result = ToolResult(
        callID: call.id,
        text: "Error: tool '\(call.name)' is not available to this agent.",
        isError: true)
      await emit(.toolFinished(context, result))
      return result
    }
    if let validationError = ToolSchemaValidator.validate(
      arguments: call.arguments,
      definition: definition)
    {
      let result = ToolResult(
        callID: call.id,
        text: "Error: \(validationError).",
        isError: true)
      await emit(.toolFinished(context, result))
      return result
    }

    let approvedCall: ToolCall
    if definition.annotations.approval == .automatic {
      approvedCall = call
    } else {
      let approval = ApprovalRequest(run: context, tool: definition, call: call)
      await emit(.approvalRequested(context, approval))
      let decision = try await approvalHandler.decide(approval)
      await emit(.approvalDecided(context, decision))
      switch decision {
      case .approve(let arguments):
        approvedCall = ToolCall(id: call.id, name: call.name, arguments: arguments)
      case .deny(let reason):
        let result = ToolResult(
          callID: call.id,
          text: "Error: tool call denied. \(reason)",
          isError: true)
        await emit(.toolFinished(context, result))
        return result
      case .cancelRun:
        throw CancellationError()
      }
    }

    if let validationError = ToolSchemaValidator.validate(
      arguments: approvedCall.arguments,
      definition: definition)
    {
      let result = ToolResult(
        callID: approvedCall.id,
        text: "Error: approved arguments are invalid: \(validationError).",
        isError: true)
      await emit(.toolFinished(context, result))
      return result
    }
    await emit(.toolStarted(context, approvedCall))
    if call.name == Self.subagentToolName {
      return try await executeSubagent(
        approvedCall,
        allowedAgentNames: request.subagentNames,
        parent: context,
        depth: depth,
        budget: budget,
        emit: emit)
    }
    guard let tool = tools[call.name] else {
      let result = ToolResult(
        callID: call.id,
        text: "Error: tool '\(call.name)' is not registered.",
        isError: true)
      await emit(.toolFinished(context, result))
      return result
    }
    do {
      let output = try await tool.call(
        arguments: approvedCall.arguments,
        context: ToolExecutionContext(run: context, modelTurn: modelTurn))
      let result = ToolResult(
        callID: approvedCall.id,
        content: output.content,
        structuredContent: output.structuredContent,
        isError: output.isError)
      await emit(.toolFinished(context, result))
      return result
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let result = ToolResult(
        callID: approvedCall.id,
        text: "Error: \(error.localizedDescription)",
        isError: true)
      await emit(.toolFinished(context, result))
      return result
    }
  }

  private func executeSubagent(
    _ call: ToolCall,
    allowedAgentNames: Set<String>,
    parent: AgentEventContext,
    depth: Int,
    budget: RunBudget,
    emit: @escaping AgentEventHandler
  ) async throws -> ToolResult {
    let arguments = call.arguments.objectValue ?? [:]
    let agentID = arguments["agent"]?.stringValue ?? ""
    let task = arguments["task"]?.stringValue ?? ""
    guard allowedAgentNames.contains(agentID), let definition = agents[agentID] else {
      let result = ToolResult(
        callID: call.id,
        text: "Error: subagent '\(agentID)' is not available.",
        isError: true)
      await emit(.toolFinished(parent, result))
      return result
    }
    guard !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      let result = ToolResult(
        callID: call.id, text: "Error: subagent task is empty.", isError: true)
      await emit(.toolFinished(parent, result))
      return result
    }
    guard await budget.claimSubagent(depth: depth + 1) else {
      let result = ToolResult(
        callID: call.id,
        text: "Error: subagent budget or depth limit reached.",
        isError: true)
      await emit(.toolFinished(parent, result))
      return result
    }

    let childRequest = request(
      for: definition,
      messages: [.user(task)])
    let childContext = AgentEventContext(
      runID: UUID(),
      parentRunID: parent.runID,
      agentID: agentID,
      depth: depth + 1)
    await emit(.childStarted(parent, child: childContext))
    do {
      let child = try await runInternal(
        childRequest,
        runID: childContext.runID,
        parentRunID: parent.runID,
        depth: depth + 1,
        budget: budget,
        emit: emit)
      await emit(.childFinished(parent, child: child))
      let content = child.response.content.filter { part in
        switch part {
        case .toolCall, .toolResult, .reasoning: false
        default: true
        }
      }
      let result = ToolResult(
        callID: call.id,
        content: content.isEmpty ? [.text(child.response.text)] : content)
      await emit(.toolFinished(parent, result))
      return result
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let result = ToolResult(
        callID: call.id,
        text: "Error: subagent '\(agentID)' failed: \(error.localizedDescription)",
        isError: true)
      await emit(.toolFinished(parent, result))
      return result
    }
  }

  private func visibleDefinitions(for request: AgentRequest) throws -> [ToolDefinition] {
    var definitions: [ToolDefinition] = []
    for name in request.toolNames.sorted() {
      guard let tool = tools[name] else { throw AgentToolError.unavailable(name) }
      definitions.append(tool.definition)
    }
    if !request.subagentNames.isEmpty {
      for name in request.subagentNames where agents[name] == nil {
        throw AgentRuntimeError.agentNotRegistered(name)
      }
      definitions.append(subagentDefinition(allowedAgentNames: request.subagentNames))
    }
    return definitions
  }

  private func subagentDefinition(allowedAgentNames: Set<String>) -> ToolDefinition {
    let names = allowedAgentNames.sorted()
    return ToolDefinition(
      name: Self.subagentToolName,
      description:
        "Run one isolated child agent and return its final result. Available agents: \(names.joined(separator: ", ")).",
      inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
          "agent": .object([
            "type": .string("string"),
            "enum": .array(names.map(JSONValue.string)),
          ]),
          "task": .object([
            "type": .string("string"),
            "description": .string("A self-contained task for the child agent."),
          ]),
        ]),
        "required": .array([.string("agent"), .string("task")]),
        "additionalProperties": .bool(false),
      ]),
      annotations: ToolAnnotations(
        readOnly: false,
        destructive: false,
        idempotent: false,
        openWorld: true,
        approval: .confirm))
  }

  private func request(
    for definition: AgentDefinition,
    messages: [AgentMessage]
  ) -> AgentRequest {
    var transcript = messages
    let instructions = definition.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    if !instructions.isEmpty {
      transcript.insert(.system(instructions), at: 0)
    }
    return AgentRequest(
      agentID: definition.id,
      provider: definition.provider,
      model: definition.model,
      messages: transcript,
      toolNames: definition.toolNames,
      subagentNames: definition.subagentNames,
      toolChoice: definition.toolChoice,
      responseFormat: definition.responseFormat,
      options: definition.options,
      limits: definition.limits,
      stream: definition.stream,
      toolCallingStrategy: definition.toolCallingStrategy)
  }

  private func textToolPrompt(
    _ definitions: [ToolDefinition],
    mode: ToolCallingMode
  ) -> String {
    "Tools are available through a \(mode.displayName.uppercased()) fallback protocol.\n\n"
      + AgentTooling.promptDescription(for: definitions, mode: mode)
  }

  private func textToolCall(
    in response: String,
    definitions: [ToolDefinition],
    mode: ToolCallingMode
  ) -> ToolCall? {
    guard let parsed = AgentTooling.parseCalls(in: response, tools: definitions, mode: mode).first
    else { return nil }
    let resolver = AgentToolNameResolver(tools: definitions)
    let name = resolver.canonicalName(for: parsed.name) ?? parsed.name
    guard let definition = definitions.first(where: { $0.name == name }) else { return nil }
    let arguments = AgentTooling.normalizeArguments(parsed.argumentValues, for: definition)
    return ToolCall(
      id: parsed.toolCallID ?? "text_\(UUID().uuidString)",
      name: name,
      arguments: .object(arguments))
  }
}

public enum AgentRuntimeError: LocalizedError, Equatable, Sendable {
  case invalidProviderID
  case providerAlreadyRegistered(ProviderID)
  case providerNotRegistered(ProviderID)
  case invalidAgentID
  case agentAlreadyRegistered(String)
  case agentNotRegistered(String)
  case reservedToolName(String)
  case nativeToolCallingUnavailable(ProviderID)
  case limitExceeded(String)

  public var errorDescription: String? {
    switch self {
    case .invalidProviderID:
      "Provider identifiers cannot be empty."
    case .providerAlreadyRegistered(let id):
      "Provider '\(id)' is already registered."
    case .providerNotRegistered(let id):
      "Provider '\(id)' is not registered."
    case .invalidAgentID:
      "Agent identifiers cannot be empty."
    case .agentAlreadyRegistered(let id):
      "Agent '\(id)' is already registered."
    case .agentNotRegistered(let id):
      "Agent '\(id)' is not registered."
    case .reservedToolName(let name):
      "Tool name '\(name)' is reserved by MaiCore."
    case .nativeToolCallingUnavailable(let provider):
      "Provider '\(provider)' does not support native tool calling. Use the automatic or json strategy."
    case .limitExceeded(let resource):
      "Agent run exceeded its \(resource) limit."
    }
  }
}

private actor RunBudget {
  private let limits: AgentRunLimits
  private var modelTurns = 0
  private var toolCalls = 0
  private var subagents = 0
  private var tokens = 0

  init(limits: AgentRunLimits) {
    self.limits = limits
  }

  func claimModelTurn() -> Bool {
    guard modelTurns < limits.maxModelTurns else { return false }
    modelTurns += 1
    return true
  }

  func claimToolCall() -> Bool {
    guard toolCalls < limits.maxToolCalls else { return false }
    toolCalls += 1
    return true
  }

  func claimSubagent(depth: Int) -> Bool {
    guard depth <= limits.maxSubagentDepth, subagents < limits.maxSubagents else { return false }
    subagents += 1
    return true
  }

  func record(tokens newTokens: Int) -> Bool {
    tokens += max(0, newTokens)
    guard let maximum = limits.maxTotalTokens else { return true }
    return tokens <= maximum
  }
}

extension Optional where Wrapped == TokenUsage {
  fileprivate func merging(_ other: TokenUsage?) -> TokenUsage? {
    guard let other else { return self }
    guard let current = self else { return other }
    return TokenUsage(
      inputTokens: current.inputTokens + other.inputTokens,
      outputTokens: current.outputTokens + other.outputTokens,
      totalTokens: current.totalTokens + other.totalTokens,
      cachedTokens: merge(current.cachedTokens, other.cachedTokens),
      reasoningTokens: merge(current.reasoningTokens, other.reasoningTokens))
  }

  private func merge(_ first: Int?, _ second: Int?) -> Int? {
    guard first != nil || second != nil else { return nil }
    return (first ?? 0) + (second ?? 0)
  }
}
