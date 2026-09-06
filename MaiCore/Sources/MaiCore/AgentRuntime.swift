import Foundation

/// UI-independent orchestration for providers, tools, approvals, MCP tools,
/// and bounded child-agent runs. Hosts own presentation and persistence and
/// observe work through `AgentEvent` values and the shared `AgentSupervisor`.
public actor AgentRuntime {
  public static let agentStartToolName = "agent_start"
  public static let agentStatusToolName = "agent_status"
  public static let agentResultToolName = "agent_result"
  public static let agentStopToolName = "agent_stop"
  /// Earlier spellings of `agent_start`. They are still executed so existing
  /// configurations and fine-tuned providers keep working, but they are no
  /// longer offered: six near-identical tools only confuse a model.
  public static let subagentToolName = "spawn_agent"
  public static let agentLaunchToolName = "agent_launch"

  private struct RegisteredMCP: Sendable {
    var source: any MCPToolSource
    var toolNames: Set<String>
  }

  private var providers: [ProviderID: any ChatProvider] = [:]
  private var tools: [String: any AgentTool] = [:]
  private var agents: [String: AgentDefinition] = [:]
  private var registeredMCPs: [String: RegisteredMCP] = [:]
  private let approvalHandler: any ApprovalHandler
  /// Overrides for the delegation brief and the derived worker's instructions.
  /// Nil keeps the built-in text, so MaiCore works without configuration.
  private var delegationTemplate: String?
  private var workerInstructions: String?
  /// Durable notes added to the system prompt of top-level runs. A child agent
  /// grepping a file does not need the user's standing preferences, so this
  /// never reaches one.
  private var memorySection: String?

  /// The process table every run reports into. Hosts read it for `/agents`,
  /// follow its events for notifications, and stop subtrees through it.
  public nonisolated let supervisor: AgentSupervisor

  public init(
    approvalHandler: any ApprovalHandler = DenyInteractiveApprovals(),
    supervisor: AgentSupervisor = AgentSupervisor()
  ) {
    self.approvalHandler = approvalHandler
    self.supervisor = supervisor
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

  /// Installs the durable memory every top-level run should see, already
  /// wrapped in its envelope by `AgentMemory.promptSection`. Nil removes it.
  public func configureMemory(_ section: String?) {
    memorySection = section?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty
  }

  /// Installs host-configured delegation text. Empty or nil values restore the
  /// built-in template and worker instructions.
  public func configureDelegation(prompt: String?, workerInstructions: String?) {
    delegationTemplate = prompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty
    self.workerInstructions =
      workerInstructions?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty
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

  /// Every registered definition, disabled ones included, so a host can list
  /// and re-enable them. Pass false to see only what can actually be run.
  public func availableAgents(includingDisabled: Bool = true) -> [AgentDefinition] {
    agents.values
      .filter { includingDisabled || $0.isEnabled }
      .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
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

  /// Registers an idle top-level process for a conversation before any turn
  /// runs, so a host can queue messages for it and list it, then pass the pid
  /// to `run(_:process:emit:)` when the first turn starts.
  public func allocateProcess(agentID: String, task: String = "") async -> AgentPID {
    await supervisor.register(
      runID: UUID(),
      parent: nil,
      agentID: agentID,
      displayName: agentID,
      task: task,
      depth: 0)
  }

  /// Runs one turn. Pass the pid an earlier turn returned as `process` to keep
  /// a conversation's identity — and the background children it started —
  /// across turns; a stale or omitted pid starts a fresh process.
  @discardableResult
  public func run(
    _ request: AgentRequest,
    process: AgentPID? = nil,
    emit: @escaping AgentEventHandler = { _ in }
  ) async throws -> AgentResult {
    let budget = RunBudget(limits: request.limits)
    let runID = UUID()
    let task = AgentProcessInfo.oneLine(
      request.messages.last { $0.role == .user }?.text ?? "", limit: 60)
    var resumed: AgentPID?
    if let existing = process, await supervisor.reopen(existing, runID: runID, task: task) {
      resumed = existing
    }
    let pid: AgentPID
    if let resumed {
      pid = resumed
    } else {
      pid = await supervisor.register(
        runID: runID,
        parent: nil,
        agentID: request.agentID,
        displayName: request.agentID,
        task: task,
        depth: 0)
    }
    do {
      let result = try await runInternal(
        request,
        runID: runID,
        pid: pid,
        parentRunID: nil,
        depth: 0,
        budget: budget,
        emit: emit)
      await supervisor.finish(pid, result: result, announce: false)
      return result
    } catch is CancellationError {
      await supervisor.fail(pid, state: .cancelled, message: "Cancelled", announce: false)
      throw CancellationError()
    } catch {
      await supervisor.fail(
        pid, state: .failed, message: error.localizedDescription, announce: false)
      throw error
    }
  }

  /// Where a paused run waits. A person pauses through the supervisor while
  /// the run is inside a model call or a tool; it gets here at the next
  /// boundary and stays until it is resumed or stopped.
  private func holdWhilePaused(_ pid: AgentPID) async throws {
    guard await supervisor.isPaused(pid) else { return }
    // "thinking" or a tool name would describe work that is not happening.
    await supervisor.note(pid, activity: "")
    while await supervisor.isPaused(pid) {
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  private func runInternal(
    _ request: AgentRequest,
    runID: UUID,
    pid: AgentPID,
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
      depth: depth,
      pid: pid)
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
    var repeatedCalls: [ToolCallKey: Int] = [:]
    var completedToolRuns: [ToolCallKey: String] = [:]

    await emit(.started(context, provider.descriptor))
    await supervisor.note(pid, state: .running, transcript: transcript)
    while localModelTurns < request.limits.maxModelTurns {
      try Task.checkCancellation()
      try await holdWhilePaused(pid)
      // Anything a person queued for this process since the last turn joins
      // the conversation here, after the tool results the model is about to
      // read, so a running agent can be steered without stopping it.
      let injected = await supervisor.drainInbox(pid)
      if !injected.isEmpty {
        for message in injected {
          transcript.append(message)
          await emit(.userMessage(context, message))
        }
        await supervisor.note(pid, transcript: transcript)
      }
      guard await budget.claimModelTurn() else {
        throw AgentRuntimeError.limitExceeded("model turns")
      }
      localModelTurns += 1
      await emit(.modelStarted(context, turn: localModelTurns))
      await supervisor.note(pid, modelTurns: localModelTurns, activity: "thinking")

      // Once the run's tool budget is spent the model gets no tools and is
      // told to answer, instead of the run failing with a limit error.
      let toolBudgetExhausted =
        !definitions.isEmpty && localToolCalls >= request.limits.maxToolCalls
      var providerMessages = transcript
      if let memorySection, depth == 0 {
        insertSystem(memorySection, into: &providerMessages)
      }
      if textToolMode != nil || toolBudgetExhausted {
        let prompt =
          toolBudgetExhausted
          ? Self.toolBudgetExhaustedPrompt
          : textToolPrompt(definitions, mode: textToolMode ?? .text)
        insertSystem(prompt, into: &providerMessages)
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
      await supervisor.note(pid, usage: totalUsage)
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
      await supervisor.note(pid, transcript: transcript)

      let calls = providerResponse.message.toolCalls
      if calls.isEmpty {
        // A message that arrived while the model was answering is not left
        // behind for a run that is about to end: the loop goes round once more
        // so the answer takes it into account. A run out of turns ends anyway
        // and leaves the message queued for its host.
        if localModelTurns < request.limits.maxModelTurns,
          await budget.canClaimModelTurn(),
          await supervisor.hasQueuedMessages(pid)
        {
          continue
        }
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
        try await holdWhilePaused(pid)
        let result: ToolResult
        if localToolCalls < request.limits.maxToolCalls, await budget.claimToolCall() {
          localToolCalls += 1
          await supervisor.note(pid, toolCalls: localToolCalls, activity: call.name)
          // Repeating a call is often right — the directory changed, a file
          // was written, a child is being polled — so only a call that keeps
          // coming back with the same arguments is stopped, and never one of
          // the agent tools, which exist to be polled.
          let key = ToolCallKey(call)
          let repeats = repeatedCalls[key, default: 0]
          let pollable = Self.reservedToolNames.contains(Self.canonicalToolName(call.name))
          if pollable || repeats < Self.maximumIdenticalCalls {
            repeatedCalls[key] = repeats + 1
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
            await emit(.toolStarted(context, call))
            result = ToolResult(
              callID: call.id,
              text:
                "Error: this exact call has already run \(repeats) times with the same arguments; change them, or answer with what you have.",
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
        await supervisor.note(pid, transcript: transcript)
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

    // Legacy names resolve to the definition of the tool that replaced them.
    let definitionName = Self.canonicalToolName(resolvedCall.name)
    guard let definition = definitions.first(where: { $0.name == definitionName }) else {
      // A call that never runs is still shown, so the person sees what the
      // model tried rather than an error out of nowhere.
      await emit(.toolStarted(context, resolvedCall))
      let result = ToolResult(
        callID: resolvedCall.id,
        text: "Error: tool '\(resolvedCall.name)' is not available to this agent.",
        isError: true)
      await emit(.toolFinished(context, result))
      return result
    }
    if definitionName == resolvedCall.name,
      let validationError = ToolSchemaValidator.validate(
        arguments: resolvedCall.arguments,
        definition: definition)
    {
      await emit(.toolStarted(context, resolvedCall))
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
      if let pid = context.pid { await supervisor.raise(.approval(approval), for: pid) }
      let decision: ApprovalDecision
      do {
        decision = try await approvalHandler.decide(approval)
      } catch {
        if let pid = context.pid { await supervisor.clearAttention(for: pid) }
        throw error
      }
      if let pid = context.pid { await supervisor.clearAttention(for: pid) }
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

    if definitionName == approvedCall.name,
      let validationError = ToolSchemaValidator.validate(
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
    switch definitionName {
    case Self.agentStartToolName:
      return await startAgent(
        approvedCall,
        legacyName: resolvedCall.name,
        request: request,
        parent: context,
        depth: depth,
        budget: budget,
        emit: emit)
    case Self.agentStatusToolName:
      return await reportAgentStatus(approvedCall, parent: context, emit: emit)
    case Self.agentResultToolName:
      return await collectAgentResult(approvedCall, parent: context, emit: emit)
    case Self.agentStopToolName:
      return await stopAgent(approvedCall, parent: context, emit: emit)
    default:
      break
    }
    guard let tool = tools[approvedCall.name] else {
      let result = ToolResult(
        callID: approvedCall.id,
        text: "Error: tool '\(approvedCall.name)' is not registered.",
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

  // MARK: - The agent_* tool family

  private func startAgent(
    _ call: ToolCall,
    legacyName: String,
    request: AgentRequest,
    parent: AgentEventContext,
    depth: Int,
    budget: RunBudget,
    emit: @escaping AgentEventHandler
  ) async -> ToolResult {
    let arguments = call.arguments.objectValue ?? [:]
    // `spawn_agent` took `task`; `agent_launch` took `prompt`. Both become the
    // task half of a brief with no context and no output contract.
    let brief =
      AgentTaskBrief(arguments: arguments)
      ?? (arguments["prompt"]?.stringValue).map { AgentTaskBrief(task: $0) }
    guard let brief else {
      return await fail(call, "the brief needs a non-empty 'task'.", parent: parent, emit: emit)
    }

    let requestedAgent = arguments["agent"]?.stringValue?.trimmingCharacters(
      in: .whitespacesAndNewlines)
    let narrowedTools = arguments["tools"]?.arrayValue.map { Set($0.compactMap(\.stringValue)) }
    let definition: AgentDefinition
    if let requestedAgent, !requestedAgent.isEmpty {
      guard request.subagentNames.contains(requestedAgent), var named = agents[requestedAgent],
        named.isEnabled
      else {
        return await fail(
          call, "agent '\(requestedAgent)' is not available to this agent.",
          parent: parent, emit: emit)
      }
      if let narrowedTools {
        let allowed = named.toolNames.intersection(narrowedTools)
        if !allowed.isEmpty { named.toolNames = allowed }
      }
      definition = named
    } else if request.toolDelegation.delegatesTools {
      definition = derivedWorker(for: request, narrowedTo: narrowedTools)
    } else {
      return await fail(
        call,
        "no agent was named. Available agents: "
          + request.subagentNames.sorted().joined(separator: ", ") + ".",
        parent: parent, emit: emit)
    }

    let wait = arguments["wait"]?.coercedBoolValue ?? (legacyName != Self.agentLaunchToolName)
    if !wait {
      let running = await supervisor.tree().liveChildren(ofAgent: parent.agentID).count
      guard running < request.limits.maxSubagents else {
        return await fail(
          call,
          "\(parent.agentID) already has \(running) background agent\(running == 1 ? "" : "s") running (limit \(request.limits.maxSubagents)).",
          parent: parent, emit: emit)
      }
    }
    guard await budget.claimSubagent(depth: depth + 1) else {
      return await fail(
        call, "the subagent budget or depth limit for this run is reached.",
        parent: parent, emit: emit)
    }

    let launched = await launch(
      definition: definition,
      brief: brief,
      parent: parent,
      depth: depth,
      budget: budget,
      background: !wait,
      emit: emit)

    guard wait else {
      let result = ToolResult(
        callID: call.id,
        content: [
          .text(
            "Started \(definition.id) as \(launched.pid). Poll \(Self.agentStatusToolName), then \(Self.agentResultToolName) with pid \"\(launched.pid.rawValue)\"."
          )
        ],
        structuredContent: .object([
          "pid": .string(String(launched.pid.rawValue)),
          "agent": .string(definition.id),
          "status": .string("running"),
        ]))
      await emit(.toolFinished(parent, result))
      return result
    }

    do {
      let child = try await withTaskCancellationHandler {
        try await launched.task.value
      } onCancel: {
        launched.task.cancel()
      }
      await supervisor.collect(launched.pid)
      await emit(.childFinished(parent, child: child))
      let result = ToolResult(
        callID: call.id,
        content: childAnswer(child),
        structuredContent: childSummary(launched.pid, agentID: definition.id, result: child))
      await emit(.toolFinished(parent, result))
      return result
    } catch is CancellationError {
      return await fail(
        call, "agent '\(definition.id)' \(launched.pid) was cancelled.",
        parent: parent, emit: emit)
    } catch {
      return await fail(
        call, "agent '\(definition.id)' \(launched.pid) failed: \(error.localizedDescription)",
        parent: parent, emit: emit)
    }
  }

  private func reportAgentStatus(
    _ call: ToolCall,
    parent: AgentEventContext,
    emit: @escaping AgentEventHandler
  ) async -> ToolResult {
    let arguments = call.arguments.objectValue ?? [:]
    let tree = await supervisor.tree()
    guard let callerPID = parent.pid else {
      return await fail(call, "this run has no process table.", parent: parent, emit: emit)
    }
    let rawPID = arguments["pid"]?.coercedStringValue ?? arguments["id"]?.coercedStringValue ?? ""
    let listed: [AgentProcessInfo]
    if rawPID.isEmpty {
      let wholeTree = arguments["tree"]?.coercedBoolValue ?? false
      let descendants = Array(tree.subtree(of: callerPID).dropFirst())
      listed = wholeTree ? descendants : descendants.filter { $0.parent == callerPID }
    } else {
      guard let pid = AgentPID(text: rawPID), tree.isDescendant(pid, of: callerPID),
        let info = tree.info(pid)
      else {
        return await fail(call, "agent \(rawPID) is not one of yours.", parent: parent, emit: emit)
      }
      listed = [info]
    }

    let text =
      listed.isEmpty
      ? "No child agents." : listed.map(\.summaryLine).joined(separator: "\n")
    let result = ToolResult(
      callID: call.id,
      content: [.text(text)],
      structuredContent: .object([
        "agents": .array(listed.map { processJSON($0) }),
        "count": .integer(listed.count),
      ]))
    await emit(.toolFinished(parent, result))
    return result
  }

  private func collectAgentResult(
    _ call: ToolCall,
    parent: AgentEventContext,
    emit: @escaping AgentEventHandler
  ) async -> ToolResult {
    let arguments = call.arguments.objectValue ?? [:]
    let rawPID = arguments["pid"]?.coercedStringValue ?? arguments["id"]?.coercedStringValue ?? ""
    guard let callerPID = parent.pid, let pid = AgentPID(text: rawPID),
      await supervisor.tree().isDescendant(pid, of: callerPID)
    else {
      return await fail(call, "agent \(rawPID) is not one of yours.", parent: parent, emit: emit)
    }
    let wait = arguments["wait"]?.coercedBoolValue ?? true

    if let finished = await supervisor.result(pid) {
      await supervisor.collect(pid)
      let result = ToolResult(
        callID: call.id,
        content: childAnswer(finished),
        structuredContent: childSummary(pid, agentID: finished.agentID, result: finished))
      await emit(.toolFinished(parent, result))
      return result
    }
    guard let handle = await supervisor.handle(pid) else {
      let info = await supervisor.info(pid)
      let reason = info?.failure ?? "it produced no result"
      return await fail(
        call, "agent \(pid) is not available: \(reason).", parent: parent, emit: emit)
    }
    guard wait else {
      let info = await supervisor.info(pid)
      let result = ToolResult(
        callID: call.id,
        content: [.text(info?.summaryLine ?? "\(pid) is still running.")],
        structuredContent: info.map { processJSON($0) })
      await emit(.toolFinished(parent, result))
      return result
    }
    do {
      let child = try await withTaskCancellationHandler {
        try await handle.value
      } onCancel: {
        handle.cancel()
      }
      await supervisor.collect(pid)
      let result = ToolResult(
        callID: call.id,
        content: childAnswer(child),
        structuredContent: childSummary(pid, agentID: child.agentID, result: child))
      await emit(.toolFinished(parent, result))
      return result
    } catch is CancellationError {
      return await fail(call, "agent \(pid) was cancelled.", parent: parent, emit: emit)
    } catch {
      return await fail(
        call, "agent \(pid) failed: \(error.localizedDescription)", parent: parent, emit: emit)
    }
  }

  private func stopAgent(
    _ call: ToolCall,
    parent: AgentEventContext,
    emit: @escaping AgentEventHandler
  ) async -> ToolResult {
    let arguments = call.arguments.objectValue ?? [:]
    let rawPID = arguments["pid"]?.coercedStringValue ?? arguments["id"]?.coercedStringValue ?? ""
    let reason = arguments["reason"]?.stringValue ?? "Stopped by \(parent.agentID)"
    guard let callerPID = parent.pid, let pid = AgentPID(text: rawPID),
      await supervisor.tree().isDescendant(pid, of: callerPID)
    else {
      return await fail(call, "agent \(rawPID) is not one of yours.", parent: parent, emit: emit)
    }
    let stopped = await supervisor.stop(pid, reason: reason)
    let result = ToolResult(
      callID: call.id,
      content: [
        .text(
          "Stopped \(stopped.map(\.description).joined(separator: ", ")).")
      ],
      structuredContent: .object([
        "stopped": .array(stopped.map { .string(String($0.rawValue)) })
      ]))
    await emit(.toolFinished(parent, result))
    return result
  }

  /// Registers a child, starts it, and hands back the handle so the caller
  /// decides whether to wait. Children always run in their own task, so
  /// `agent_stop` kills a blocking child the same way it kills a background one.
  private func launch(
    definition: AgentDefinition,
    brief: AgentTaskBrief,
    parent: AgentEventContext,
    depth: Int,
    budget: RunBudget,
    background: Bool,
    emit: @escaping AgentEventHandler
  ) async -> (pid: AgentPID, task: Task<AgentResult, Error>) {
    let prompt = AgentDelegationPrompt.render(
      brief,
      agent: definition.id,
      workingDirectory: FileManager.default.currentDirectoryPath,
      template: delegationTemplate)
    let childRequest = request(for: definition, messages: [.user(prompt)])
    let childRunID = UUID()
    let childPID = await supervisor.register(
      runID: childRunID,
      parent: parent.pid,
      agentID: definition.id,
      displayName: definition.displayName,
      task: brief.headline,
      depth: depth + 1)
    let childContext = AgentEventContext(
      runID: childRunID,
      parentRunID: parent.runID,
      agentID: definition.id,
      depth: depth + 1,
      pid: childPID)
    await emit(.childStarted(parent, child: childContext))
    // Every child's events reach the host, background or not, tagged with the
    // child's own context and pid. How they are shown — prefixed, folded into
    // one line, or dropped — is the host's call, not the runtime's.
    let task = Task {
      do {
        let child = try await runInternal(
          childRequest,
          runID: childRunID,
          pid: childPID,
          parentRunID: parent.runID,
          depth: depth + 1,
          budget: budget,
          emit: emit)
        await budget.releaseSubagent()
        await supervisor.finish(childPID, result: child, announce: background)
        return child
      } catch is CancellationError {
        await budget.releaseSubagent()
        await supervisor.fail(
          childPID, state: .cancelled, message: "Cancelled", announce: background)
        throw CancellationError()
      } catch {
        await budget.releaseSubagent()
        await supervisor.fail(
          childPID, state: .failed, message: error.localizedDescription, announce: background)
        throw error
      }
    }
    await supervisor.attach(task, to: childPID)
    return (childPID, task)
  }

  /// The agent MaiCore invents when a delegating agent does not name a child:
  /// same provider and model, the parent's tools, and inline delegation so it
  /// actually runs them. Without it, switching delegation on would leave an
  /// agent with no way to do anything.
  private func derivedWorker(
    for request: AgentRequest,
    narrowedTo tools: Set<String>?
  ) -> AgentDefinition {
    var toolNames = request.toolNames
    if let tools {
      let allowed = toolNames.intersection(tools)
      if !allowed.isEmpty { toolNames = allowed }
    }
    return AgentDefinition(
      id: "\(request.agentID).worker",
      displayName: "\(request.agentID) worker",
      instructions: workerInstructions ?? AgentDelegationPrompt.workerInstructions,
      provider: request.provider,
      model: request.model,
      toolNames: toolNames,
      stream: request.stream,
      limits: request.limits,
      options: request.options,
      toolCallingStrategy: request.toolCallingStrategy,
      useToolProxy: request.useToolProxy,
      toolDelegation: .inline)
  }

  private func fail(
    _ call: ToolCall,
    _ message: String,
    parent: AgentEventContext,
    emit: @escaping AgentEventHandler
  ) async -> ToolResult {
    let result = ToolResult(callID: call.id, text: "Error: \(message)", isError: true)
    await emit(.toolFinished(parent, result))
    return result
  }

  private func processJSON(_ info: AgentProcessInfo) -> JSONValue {
    var value: [String: JSONValue] = [
      "pid": .string(String(info.pid.rawValue)),
      "agent": .string(info.agentID),
      "status": .string(info.state.rawValue),
      "turns": .integer(info.modelTurns),
      "tools": .integer(info.toolCalls),
    ]
    if let tokens = info.usage?.totalTokens { value["tokens"] = .integer(tokens) }
    if let failure = info.failure { value["error"] = .string(failure) }
    if let attention = info.attention { value["attention"] = .string(attention.summary) }
    return .object(value)
  }

  private func childSummary(
    _ pid: AgentPID,
    agentID: String,
    result: AgentResult
  ) -> JSONValue {
    var value: [String: JSONValue] = [
      "pid": .string(String(pid.rawValue)),
      "agent": .string(agentID),
      "status": .string("completed"),
      "turns": .integer(result.modelTurns),
      "tools": .integer(result.toolCalls),
    ]
    if let tokens = result.usage?.totalTokens { value["tokens"] = .integer(tokens) }
    return .object(value)
  }

  /// Only the child's answer travels back: its tool traffic and reasoning stay
  /// in the transcript that is about to be discarded.
  private func childAnswer(_ child: AgentResult) -> [ContentPart] {
    let content = child.response.content.filter { part in
      switch part {
      case .toolCall, .toolResult, .reasoning: false
      default: true
      }
    }
    return content.isEmpty ? [.text(child.response.text)] : content
  }

  private func visibleDefinitions(for request: AgentRequest) throws -> [ToolDefinition] {
    for name in request.subagentNames where agents[name] == nil {
      throw AgentRuntimeError.agentNotRegistered(name)
    }
    let mcpToolNames = registeredMCPs.values.reduce(into: Set<String>()) {
      $0.formUnion($1.toolNames)
    }
    let concreteNames = request.toolNames.union(mcpToolNames)
    // A disabled definition stays registered so a host can list it, but it is
    // never offered as a subagent.
    let offeredAgents = request.subagentNames.filter { agents[$0]?.isEnabled == true }
    // Delegation only takes effect where children are actually permitted;
    // otherwise hiding the tools would leave the agent unable to work at all.
    let delegating = request.toolDelegation.delegatesTools && request.limits.maxSubagents > 0
    var definitions: [ToolDefinition] = []
    if !delegating {
      for name in concreteNames.sorted() {
        if let tool = tools[name] { definitions.append(tool.definition) }
      }
    }
    if request.limits.maxSubagents > 0, delegating || !offeredAgents.isEmpty {
      definitions.append(
        contentsOf: agentToolDefinitions(allowedAgentNames: offeredAgents, delegating: delegating))
    }
    return definitions
  }

  private func agentToolDefinitions(
    allowedAgentNames: Set<String>,
    delegating: Bool
  ) -> [ToolDefinition] {
    let names = allowedAgentNames.sorted()
    var startProperties: [String: JSONValue] = [
      "context": .object([
        "type": .string("string"),
        "description": .string(
          "What the agent must know and cannot discover on its own: facts already established, decisions already made, paths already found. It cannot see this conversation."
        ),
      ]),
      "task": .object([
        "type": .string("string"),
        "description": .string("The single thing the agent should do."),
      ]),
      "output": .object([
        "type": .string("string"),
        "description": .string(
          "What to return and in what shape, for example \"a list of file paths, one per line, no prose\". You are the consumer, so be specific."
        ),
      ]),
      "wait": .object([
        "type": .string("boolean"),
        "description": .string(
          "Wait for the answer (default). Pass false to get a pid immediately and collect it later with \(Self.agentResultToolName)."
        ),
      ]),
      "tools": .object([
        "type": .string("array"),
        "items": .object(["type": .string("string")]),
        "description": .string("Optional subset of the agent's tools to allow."),
      ]),
    ]
    if !names.isEmpty {
      let described = names.map { name -> String in
        guard let agent = agents[name] else { return name }
        let purpose =
          agent.description.isEmpty
          ? (agent.displayName == name ? "" : agent.displayName) : agent.description
        return purpose.isEmpty ? name : "\(name) — \(purpose)"
      }
      startProperties["agent"] = .object([
        "type": .string("string"),
        "enum": .array(names.map(JSONValue.string)),
        "description": .string(
          "Which agent to run. \(described.joined(separator: "; "))."
            + (delegating ? " Omit to use a general worker with your own tools." : "")),
      ])
    }

    let startDescription =
      delegating
      ? "Run a task in a child agent. Your tools live there, not here: describe the work and the child does it, so this conversation keeps only the answer."
      : "Run one task in a child agent with a transcript of its own, so its intermediate steps never enter this conversation. Available agents: \(names.joined(separator: ", "))."

    return [
      ToolDefinition(
        name: Self.agentStartToolName,
        description: startDescription,
        inputSchema: .object([
          "type": .string("object"),
          "properties": .object(startProperties),
          "required": .array([.string("task"), .string("output")]),
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
          "List your child agents and what they are doing, without waiting. Omit pid for your direct children; pass tree for the whole subtree.",
        inputSchema: .object([
          "type": .string("object"),
          "properties": .object([
            "pid": .object([
              "type": .string("string"),
              "description": .string(
                "A single agent's pid, as returned by \(Self.agentStartToolName)."),
            ]),
            "tree": .object([
              "type": .string("boolean"),
              "description": .string("Include grandchildren and deeper."),
            ]),
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
          "Take the answer from a child started with wait false. Waits for it to finish unless wait is false.",
        inputSchema: .object([
          "type": .string("object"),
          "properties": .object([
            "pid": .object([
              "type": .string("string"),
              "description": .string("The pid returned by \(Self.agentStartToolName)."),
            ]),
            "wait": .object([
              "type": .string("boolean"),
              "description": .string("Block until it finishes (default true)."),
            ]),
          ]),
          "required": .array([.string("pid")]),
          "additionalProperties": .bool(false),
        ]),
        annotations: ToolAnnotations(
          readOnly: true,
          destructive: false,
          idempotent: false,
          openWorld: false,
          approval: .automatic)),
      ToolDefinition(
        name: Self.agentStopToolName,
        description:
          "Stop a child agent and everything it started, when its answer is no longer needed.",
        inputSchema: .object([
          "type": .string("object"),
          "properties": .object([
            "pid": .object([
              "type": .string("string"),
              "description": .string("The pid to stop."),
            ]),
            "reason": .object([
              "type": .string("string"),
              "description": .string("Why, for the log."),
            ]),
          ]),
          "required": .array([.string("pid")]),
          "additionalProperties": .bool(false),
        ]),
        annotations: ToolAnnotations(
          readOnly: false,
          destructive: false,
          idempotent: true,
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
      useToolProxy: definition.useToolProxy,
      toolDelegation: definition.toolDelegation)
  }

  static let toolBudgetExhaustedPrompt =
    "The tool call budget for this run is exhausted and no tools are available anymore. Do not call tools; give the final answer using the information already gathered."

  /// Adds a system message after the configured instructions and before the
  /// conversation, so run-scoped context never enters the stored transcript.
  private func insertSystem(_ prompt: String, into messages: inout [AgentMessage]) {
    let index =
      messages.firstIndex { $0.role != .system && $0.role != .developer }
      ?? messages.endIndex
    messages.insert(.system(prompt), at: index)
  }

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
  /// How often one call may run with exactly the same arguments in one run
  /// before it is refused as a loop.
  static let maximumIdenticalCalls = 3

  fileprivate static let reservedToolNames: Set<String> = [
    agentStartToolName, agentStatusToolName, agentResultToolName, agentStopToolName,
    subagentToolName, agentLaunchToolName,
  ]

  /// Maps a retired tool name onto the one that replaced it.
  fileprivate static func canonicalToolName(_ name: String) -> String {
    switch name {
    case subagentToolName, agentLaunchToolName: agentStartToolName
    default: name
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
      "Provider '\(provider)' does not support native tool calling. Use automatic, text, xml, or json."
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

  func canClaimModelTurn() -> Bool {
    modelTurns < limits.maxModelTurns
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

extension String {
  fileprivate var nilWhenEmpty: String? { isEmpty ? nil : self }
}
