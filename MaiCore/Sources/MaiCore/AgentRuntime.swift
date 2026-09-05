import Foundation

/// UI-independent orchestration for providers, tools, approvals, MCP tools,
/// and bounded child-agent runs. Hosts own presentation and persistence and
/// observe work through `AgentEvent` values.
public actor AgentRuntime {
  public static let subagentToolName = "spawn_agent"
  public static let agentLaunchToolName = "agent_launch"
  public static let agentStatusToolName = "agent_status"
  public static let agentResultToolName = "agent_result"

  private enum LaunchedSubagentState: String, Sendable {
    case running, completed, failed, cancelled
  }

  private struct LaunchedSubagent: Sendable {
    var agentID: String
    var ownerAgentID: String
    var state: LaunchedSubagentState
    var task: Task<AgentResult, Error>?
    var result: AgentResult?
    var failure: String?
  }

  private struct RegisteredMCP: Sendable {
    var source: any MCPToolSource
    var toolNames: Set<String>
  }

  private var providers: [ProviderID: any ChatProvider] = [:]
  private var tools: [String: any AgentTool] = [:]
  private var agents: [String: AgentDefinition] = [:]
  private var launchedSubagents: [UUID: LaunchedSubagent] = [:]
  private var runningSubagentsByOwner: [String: Int] = [:]
  private var registeredMCPs: [String: RegisteredMCP] = [:]
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
    guard !Self.reservedToolNames.contains(name) else {
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
    let agentTools = try await source.agentTools()
    for tool in agentTools {
      try register(tool: tool, replacingExisting: replacingExistingTools)
    }
    registeredMCPs[catalog.serverID] = RegisteredMCP(
      source: source,
      toolNames: Set(agentTools.map { $0.definition.name }))
    return catalog
  }

  /// Disconnects an MCP source and removes the tools discovered from it.
  @discardableResult
  public func unregisterMCP(serverID: String) async -> Set<String> {
    guard let registration = registeredMCPs.removeValue(forKey: serverID) else { return [] }
    for name in registration.toolNames { tools[name] = nil }
    await registration.source.close()
    return registration.toolNames
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
    let concreteDefinitions = try visibleDefinitions(for: request)
    let definitions =
      request.useToolProxy && !concreteDefinitions.isEmpty
      ? ToolProxy.definitions : concreteDefinitions
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
    var fingerprints = Set<ToolCallKey>()
    var completedToolRuns: [ToolCallKey: String] = [:]

    await emit(.started(context, provider.descriptor))
    while localModelTurns < request.limits.maxModelTurns {
      try Task.checkCancellation()
      guard await budget.claimModelTurn() else {
        throw AgentRuntimeError.limitExceeded("model turns")
      }
      localModelTurns += 1
      await emit(.modelStarted(context, turn: localModelTurns))

      // Once the run's tool budget is spent the model gets no tools and is
      // told to answer, instead of the run failing with a limit error.
      let toolBudgetExhausted =
        !definitions.isEmpty && localToolCalls >= request.limits.maxToolCalls
      var providerMessages = transcript
      if textToolMode != nil || toolBudgetExhausted {
        let insertionIndex =
          providerMessages.firstIndex {
            $0.role != .system && $0.role != .developer
          } ?? providerMessages.endIndex
        let prompt =
          toolBudgetExhausted
          ? Self.toolBudgetExhaustedPrompt
          : textToolPrompt(definitions, mode: textToolMode ?? .text)
        providerMessages.insert(.system(prompt), at: insertionIndex)
      }
      let offersTools = !usesTextToolProtocol && !toolBudgetExhausted
      var providerResponse = try await provider.complete(
        ProviderRequest(
          model: request.model,
          messages: providerMessages,
          tools: offersTools ? definitions : [],
          toolChoice: definitions.isEmpty || !offersTools ? .none : request.toolChoice,
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
      totalUsage = totalUsage.merging(providerResponse.usage)
      if let usage = providerResponse.usage,
        !(await budget.record(tokens: usage.totalTokens))
      {
        throw AgentRuntimeError.limitExceeded("token budget")
      }

      if let textToolMode, !toolBudgetExhausted {
        let decision = AgentToolLoopPolicy.evaluate(
          response: providerResponse.message.text,
          tools: definitions,
          mode: textToolMode,
          completedToolRuns: completedToolRuns,
          remainingToolCalls: request.limits.maxToolCalls - localToolCalls)
        switch decision {
        case .final(let text):
          if text != providerResponse.message.text {
            providerResponse.message = replacingText(in: providerResponse.message, with: text)
          }
          if !text.isEmpty { await emit(.provider(context, .textDelta(text))) }
        case .repair(let feedback):
          providerResponse.message = .assistant(feedback)
          transcript.append(providerResponse.message)
          continue
        case .execute(let parsedCalls):
          let calls = parsedCalls.map(toolCall)
          var content = providerResponse.message.content.filter {
            if case .reasoning = $0 { return true }
            return false
          }
          content.append(contentsOf: calls.map(ContentPart.toolCall))
          providerResponse.message.content = content
          providerResponse.stopReason = .toolCall
          for (index, call) in calls.enumerated() {
            await emit(
              .provider(
                context,
                .toolCallDelta(
                  ToolCallDelta(
                    index: index,
                    id: call.id,
                    name: call.name,
                    argumentsFragment: call.arguments.compactJSONString))))
          }
        }
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
        let result: ToolResult
        if localToolCalls < request.limits.maxToolCalls, await budget.claimToolCall() {
          localToolCalls += 1
          if fingerprints.insert(ToolCallKey(call)).inserted {
            result = try await execute(
              call,
              definitions: concreteDefinitions,
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
        } else {
          result = ToolResult(
            callID: call.id,
            text:
              "Error: the tool call budget for this run (\(request.limits.maxToolCalls)) is exhausted; this call was not executed. Answer with the information already gathered.",
            isError: true)
          await emit(.toolFinished(context, result))
        }
        if !result.isError { completedToolRuns[ToolCallKey(call)] = result.text }
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
    if request.useToolProxy,
      call.name != ToolProxy.listName && call.name != ToolProxy.callName
    {
      let result = ToolResult(
        callID: call.id,
        text: "Error: proxy mode does not expose tool '\(call.name)'.",
        isError: true)
      await emit(.toolFinished(context, result))
      return result
    }
    if request.useToolProxy, call.name == ToolProxy.listName {
      await emit(.toolStarted(context, call))
      let result = ToolResult(
        callID: call.id,
        text: ToolProxy.listTools(
          arguments: call.arguments.objectValue ?? [:], definitions: definitions))
      await emit(.toolFinished(context, result))
      return result
    }

    let resolvedCall: ToolCall
    if request.useToolProxy, call.name == ToolProxy.callName {
      let resolved = ToolProxy.resolveCall(
        arguments: call.arguments.objectValue ?? [:], definitions: definitions)
      guard let target = resolved.call else {
        let result = ToolResult(
          callID: call.id,
          text: resolved.error ?? "Error: invalid proxied tool call.",
          isError: true)
        await emit(.toolFinished(context, result))
        return result
      }
      resolvedCall = ToolCall(
        id: call.id, name: target.name, arguments: .object(target.argumentValues))
    } else {
      resolvedCall = call
    }

    guard let definition = definitions.first(where: { $0.name == resolvedCall.name }) else {
      let result = ToolResult(
        callID: resolvedCall.id,
        text: "Error: tool '\(resolvedCall.name)' is not available to this agent.",
        isError: true)
      await emit(.toolFinished(context, result))
      return result
    }
    if let validationError = ToolSchemaValidator.validate(
      arguments: resolvedCall.arguments,
      definition: definition)
    {
      let result = ToolResult(
        callID: resolvedCall.id,
        text: "Error: \(validationError).",
        isError: true)
      await emit(.toolFinished(context, result))
      return result
    }

    let approvedCall: ToolCall
    if definition.annotations.approval == .automatic {
      approvedCall = resolvedCall
    } else {
      let approval = ApprovalRequest(run: context, tool: definition, call: resolvedCall)
      await emit(.approvalRequested(context, approval))
      let decision = try await approvalHandler.decide(approval)
      await emit(.approvalDecided(context, decision))
      switch decision {
      case .approve(let arguments):
        approvedCall = ToolCall(
          id: resolvedCall.id, name: resolvedCall.name, arguments: arguments)
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
    if resolvedCall.name == Self.subagentToolName {
      return try await executeSubagent(
        approvedCall,
        allowedAgentNames: request.subagentNames,
        parent: context,
        depth: depth,
        budget: budget,
        emit: emit)
    }
    if resolvedCall.name == Self.agentLaunchToolName {
      return await launchSubagent(
        approvedCall,
        allowedAgentNames: request.subagentNames,
        maxConcurrentSubagents: request.limits.maxSubagents,
        parent: context,
        depth: depth,
        budget: budget,
        emit: emit)
    }
    if resolvedCall.name == Self.agentStatusToolName {
      return await pollSubagentStatus(
        approvedCall,
        allowedAgentNames: request.subagentNames,
        parent: context,
        emit: emit)
    }
    if resolvedCall.name == Self.agentResultToolName {
      return try await awaitSubagentResult(
        approvedCall,
        allowedAgentNames: request.subagentNames,
        parent: context,
        emit: emit)
    }
    guard let tool = tools[resolvedCall.name] else {
      let result = ToolResult(
        callID: resolvedCall.id,
        text: "Error: tool '\(resolvedCall.name)' is not registered.",
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
      await budget.releaseSubagent()
      await emit(.childFinished(parent, child: child))
      let result = ToolResult(
        callID: call.id,
        content: subagentResultContent(child))
      await emit(.toolFinished(parent, result))
      return result
    } catch is CancellationError {
      await budget.releaseSubagent()
      throw CancellationError()
    } catch {
      await budget.releaseSubagent()
      let result = ToolResult(
        callID: call.id,
        text: "Error: subagent '\(agentID)' failed: \(error.localizedDescription)",
        isError: true)
      await emit(.toolFinished(parent, result))
      return result
    }
  }

  private func launchSubagent(
    _ call: ToolCall,
    allowedAgentNames: Set<String>,
    maxConcurrentSubagents: Int,
    parent: AgentEventContext,
    depth: Int,
    budget: RunBudget,
    emit: @escaping AgentEventHandler
  ) async -> ToolResult {
    let arguments = call.arguments.objectValue ?? [:]
    let agentID = arguments["agent"]?.stringValue ?? ""
    let prompt = arguments["prompt"]?.stringValue ?? ""
    guard allowedAgentNames.contains(agentID), let definition = agents[agentID] else {
      let result = ToolResult(
        callID: call.id,
        text: "Error: subagent '\(agentID)' is not available.",
        isError: true)
      await emit(.toolFinished(parent, result))
      return result
    }
    guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      let result = ToolResult(
        callID: call.id, text: "Error: subagent prompt is empty.", isError: true)
      await emit(.toolFinished(parent, result))
      return result
    }
    let runningForOwner = runningSubagentsByOwner[parent.agentID, default: 0]
    guard runningForOwner < maxConcurrentSubagents else {
      let result = ToolResult(
        callID: call.id,
        text:
          "Error: orchestrator '\(parent.agentID)' already has \(runningForOwner) background subagents running (limit \(maxConcurrentSubagents)).",
        isError: true)
      await emit(.toolFinished(parent, result))
      return result
    }
    runningSubagentsByOwner[parent.agentID] = runningForOwner + 1
    guard await budget.claimSubagent(depth: depth + 1) else {
      releaseSubagentSlot(ownerAgentID: parent.agentID)
      let result = ToolResult(
        callID: call.id,
        text: "Error: subagent budget or depth limit reached.",
        isError: true)
      await emit(.toolFinished(parent, result))
      return result
    }

    let childRequest = request(for: definition, messages: [.user(prompt)])
    let childContext = AgentEventContext(
      runID: UUID(),
      parentRunID: parent.runID,
      agentID: agentID,
      depth: depth + 1)
    await emit(.childStarted(parent, child: childContext))
    let task = Task {
      do {
        let child = try await runInternal(
          childRequest,
          runID: childContext.runID,
          parentRunID: parent.runID,
          depth: depth + 1,
          budget: budget,
          emit: { _ in })
        await budget.releaseSubagent()
        completeLaunchedSubagent(childContext.runID, result: child)
        return child
      } catch is CancellationError {
        await budget.releaseSubagent()
        failLaunchedSubagent(childContext.runID, state: .cancelled, failure: "Cancelled")
        throw CancellationError()
      } catch {
        await budget.releaseSubagent()
        failLaunchedSubagent(
          childContext.runID, state: .failed, failure: error.localizedDescription)
        throw error
      }
    }
    launchedSubagents[childContext.runID] = LaunchedSubagent(
      agentID: agentID,
      ownerAgentID: parent.agentID,
      state: .running,
      task: task)
    let handle = childContext.runID.uuidString
    let result = ToolResult(
      callID: call.id,
      content: [
        .text(
          "Started subagent '\(agentID)' as \(handle). Poll \(Self.agentStatusToolName), then call \(Self.agentResultToolName) when it is ready."
        )
      ],
      structuredContent: .object([
        "id": .string(handle),
        "agent": .string(agentID),
        "status": .string("running"),
      ]))
    await emit(.toolFinished(parent, result))
    return result
  }

  private func pollSubagentStatus(
    _ call: ToolCall,
    allowedAgentNames: Set<String>,
    parent: AgentEventContext,
    emit: @escaping AgentEventHandler
  ) async -> ToolResult {
    let rawID = call.arguments.objectValue?["id"]?.stringValue
    let jobs: [(UUID, LaunchedSubagent)]
    if let rawID {
      guard let id = UUID(uuidString: rawID),
        let job = launchedSubagents[id],
        job.ownerAgentID == parent.agentID,
        allowedAgentNames.contains(job.agentID)
      else {
        let result = ToolResult(
          callID: call.id,
          text: "Error: subagent run '\(rawID)' is not available.",
          isError: true)
        await emit(.toolFinished(parent, result))
        return result
      }
      jobs = [(id, job)]
    } else {
      jobs = launchedSubagents.compactMap { id, job in
        job.ownerAgentID == parent.agentID && allowedAgentNames.contains(job.agentID)
          ? (id, job) : nil
      }.sorted { $0.0.uuidString < $1.0.uuidString }
    }

    let states = jobs.map { subagentState(id: $0.0, job: $0.1) }
    let summary =
      jobs.isEmpty
      ? "No background subagents."
      : jobs.map { "\($0.0.uuidString): \($0.1.agentID) [\($0.1.state.rawValue)]" }
        .joined(separator: "\n")
    let structuredContent: JSONValue =
      rawID == nil
      ? .object([
        "agents": .array(states),
        "count": .number(Double(states.count)),
      ])
      : states[0]
    let result = ToolResult(
      callID: call.id,
      content: [.text(summary)],
      structuredContent: structuredContent)
    await emit(.toolFinished(parent, result))
    return result
  }

  private func awaitSubagentResult(
    _ call: ToolCall,
    allowedAgentNames: Set<String>,
    parent: AgentEventContext,
    emit: @escaping AgentEventHandler
  ) async throws -> ToolResult {
    let rawID = call.arguments.objectValue?["id"]?.stringValue ?? ""
    guard let id = UUID(uuidString: rawID),
      let job = launchedSubagents[id],
      job.ownerAgentID == parent.agentID,
      allowedAgentNames.contains(job.agentID)
    else {
      let result = ToolResult(
        callID: call.id,
        text: "Error: subagent run '\(rawID)' is not available.",
        isError: true)
      await emit(.toolFinished(parent, result))
      return result
    }

    do {
      let child: AgentResult
      if let completed = job.result {
        child = completed
      } else if let task = job.task {
        child = try await task.value
      } else {
        throw BackgroundSubagentError.failed(job.failure ?? "No result is available")
      }
      launchedSubagents[id] = nil
      let content = subagentResultContent(child)
      let result = ToolResult(
        callID: call.id,
        content: content,
        structuredContent: .object([
          "id": .string(id.uuidString),
          "agent": .string(job.agentID),
          "status": .string("completed"),
        ]))
      await emit(.toolFinished(parent, result))
      return result
    } catch is CancellationError {
      let result = ToolResult(
        callID: call.id,
        text: "Error: subagent '\(job.agentID)' was cancelled.",
        isError: true)
      launchedSubagents[id] = nil
      await emit(.toolFinished(parent, result))
      return result
    } catch {
      launchedSubagents[id] = nil
      let result = ToolResult(
        callID: call.id,
        text: "Error: subagent '\(job.agentID)' failed: \(error.localizedDescription)",
        isError: true)
      await emit(.toolFinished(parent, result))
      return result
    }
  }

  private func completeLaunchedSubagent(_ id: UUID, result: AgentResult) {
    guard var job = launchedSubagents[id] else { return }
    if job.state == .running { releaseSubagentSlot(ownerAgentID: job.ownerAgentID) }
    job.state = .completed
    job.task = nil
    job.result = result
    launchedSubagents[id] = job
  }

  private func failLaunchedSubagent(
    _ id: UUID,
    state: LaunchedSubagentState,
    failure: String
  ) {
    guard var job = launchedSubagents[id] else { return }
    if job.state == .running { releaseSubagentSlot(ownerAgentID: job.ownerAgentID) }
    job.state = state
    job.task = nil
    job.failure = failure
    launchedSubagents[id] = job
  }

  private func releaseSubagentSlot(ownerAgentID: String) {
    let remaining = runningSubagentsByOwner[ownerAgentID, default: 0] - 1
    runningSubagentsByOwner[ownerAgentID] = remaining > 0 ? remaining : nil
  }

  private func subagentState(id: UUID, job: LaunchedSubagent) -> JSONValue {
    var value: [String: JSONValue] = [
      "id": .string(id.uuidString),
      "agent": .string(job.agentID),
      "status": .string(job.state.rawValue),
    ]
    if let failure = job.failure { value["error"] = .string(failure) }
    return .object(value)
  }

  private func subagentResultContent(_ child: AgentResult) -> [ContentPart] {
    let content = child.response.content.filter { part in
      switch part {
      case .toolCall, .toolResult, .reasoning: false
      default: true
      }
    }
    return content.isEmpty ? [.text(child.response.text)] : content
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
      if request.limits.maxSubagents > 0 {
        definitions.append(
          contentsOf: subagentDefinitions(allowedAgentNames: request.subagentNames))
      }
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

  private func subagentDefinitions(allowedAgentNames: Set<String>) -> [ToolDefinition] {
    let names = allowedAgentNames.sorted()
    return [
      subagentDefinition(allowedAgentNames: allowedAgentNames),
      ToolDefinition(
        name: Self.agentLaunchToolName,
        description:
          "Start an isolated child agent in the background and return its run id immediately. Available agents: \(names.joined(separator: ", ")).",
        inputSchema: .object([
          "type": .string("object"),
          "properties": .object([
            "agent": .object([
              "type": .string("string"),
              "enum": .array(names.map(JSONValue.string)),
            ]),
            "prompt": .object([
              "type": .string("string"),
              "description": .string("A self-contained prompt for the child agent."),
            ]),
          ]),
          "required": .array([.string("agent"), .string("prompt")]),
          "additionalProperties": .bool(false),
        ]),
        annotations: ToolAnnotations(
          readOnly: false,
          destructive: false,
          idempotent: false,
          openWorld: true,
          approval: .confirm)),
      ToolDefinition(
        name: Self.agentStatusToolName,
        description:
          "Poll background child-agent state without waiting. Omit id to list all background children owned by this orchestrator.",
        inputSchema: .object([
          "type": .string("object"),
          "properties": .object([
            "id": .object([
              "type": .string("string"),
              "description": .string("Optional run id returned by \(Self.agentLaunchToolName)."),
            ])
          ]),
          "additionalProperties": .bool(false),
        ]),
        annotations: ToolAnnotations(
          readOnly: true,
          destructive: false,
          idempotent: true,
          openWorld: false,
          approval: .automatic)),
      ToolDefinition(
        name: Self.agentResultToolName,
        description:
          "Wait for a child started by \(Self.agentLaunchToolName) and return its final result.",
        inputSchema: .object([
          "type": .string("object"),
          "properties": .object([
            "id": .object([
              "type": .string("string"),
              "description": .string("Run id returned by \(Self.agentLaunchToolName)."),
            ])
          ]),
          "required": .array([.string("id")]),
          "additionalProperties": .bool(false),
        ]),
        annotations: ToolAnnotations(
          readOnly: true,
          destructive: false,
          idempotent: false,
          openWorld: false,
          approval: .automatic)),
    ]
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
      toolCallingStrategy: definition.toolCallingStrategy,
      useToolProxy: definition.useToolProxy)
  }

  static let toolBudgetExhaustedPrompt =
    "The tool call budget for this run is exhausted and no tools are available anymore. Do not call tools; give the final answer using the information already gathered."

  private func textToolPrompt(
    _ definitions: [ToolDefinition],
    mode: ToolCallingMode
  ) -> String {
    "Tools are available through a \(mode.displayName.uppercased()) fallback protocol.\n\n"
      + AgentTooling.promptDescription(
        for: AgentToolLoopPolicy.definitions(includingResponseTool: definitions), mode: mode)
  }

  private func toolCall(_ call: ParsedToolCall) -> ToolCall {
    return ToolCall(
      id: call.toolCallID ?? "text_\(UUID().uuidString)",
      name: call.name,
      arguments: .object(call.argumentValues))
  }

  private func replacingText(in message: AgentMessage, with text: String) -> AgentMessage {
    var message = message
    message.content.removeAll {
      if case .text = $0 { return true }
      if case .toolCall = $0 { return true }
      return false
    }
    if !text.isEmpty { message.content.append(.text(text)) }
    return message
  }
}

extension AgentRuntime {
  fileprivate static let reservedToolNames: Set<String> = [
    subagentToolName, agentLaunchToolName, agentStatusToolName, agentResultToolName,
  ]
}

private enum BackgroundSubagentError: LocalizedError {
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .failed(let message): message
    }
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

  func releaseSubagent() {
    subagents = max(0, subagents - 1)
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
