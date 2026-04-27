import Foundation

@MainActor
enum ToolAgentRegistry {
  static func visibleDefinitions(
    for conversation: Conversation,
    settings: AppSettings,
    mcpTools: [UUID: [MCPToolDescriptor]] = [:]
  ) -> [ToolDefinition] {
    let fullDefinitions = definitions(for: conversation, settings: settings, mcpTools: mcpTools)
    guard settings.toolCallingMode == .proxy else { return fullDefinitions }
    return fullDefinitions.isEmpty ? [] : ToolProxy.definitions
  }

  static func definitions(
    for conversation: Conversation,
    settings: AppSettings,
    mcpTools: [UUID: [MCPToolDescriptor]] = [:]
  ) -> [ToolDefinition] {
    var defs: [ToolDefinition] = []
    if conversation.enabledTools.contains(.todo) {
      defs.append(contentsOf: TodoTool.definitions)
    }
    for server in settings.mcpServers
    where server.isEnabled && server.hasValidScheme {
      let tools = mcpTools[server.id] ?? []
      for tool in tools {
        let key = "\(server.id.uuidString):\(tool.name)"
        if conversation.disabledMCPTools.contains(key) { continue }
        let baseDesc =
          tool.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? "MCP tool from \(server.name)."
          : tool.description
        let description: String
        if !tool.parametersJSON.isEmpty {
          description = "\(baseDesc) Input schema: \(tool.parametersJSON)"
        } else {
          description = baseDesc
        }
        defs.append(
          ToolDefinition(
            name: tool.name,
            description: description,
            parameters: AgentTooling.parameters(fromSchemaJSON: tool.parametersJSON),
            inputSchemaJSON: tool.parametersJSON))
      }
    }
    return defs
  }

  static func promptDescription(for definitions: [ToolDefinition]) -> String {
    AgentTooling.promptDescription(for: definitions)
  }

  static func parseCalls(in text: String, definitions: [ToolDefinition]) -> [ParsedToolCall] {
    AgentTooling.parseCalls(in: text, tools: definitions)
  }

  static func normalized(call: ParsedToolCall, definitions: [ToolDefinition]) -> ParsedToolCall {
    let resolver = AgentToolNameResolver(tools: definitions)
    let canonicalName = resolver.canonicalName(for: call.name) ?? call.name
    let definitionByName = Dictionary(uniqueKeysWithValues: definitions.map { ($0.name, $0) })
    let normalizedArguments = AgentTooling.normalizeArguments(
      call.argumentValues, for: definitionByName[canonicalName])
    return ParsedToolCall(
      name: canonicalName,
      arguments: [:],
      argumentValues: normalizedArguments,
      rawBlock: call.rawBlock,
      toolCallID: call.toolCallID,
      apiName: call.apiName)
  }

  static func execute(call: ParsedToolCall, store: AppStore) async -> String {
    let fullDefinitions =
      store.currentConversation.map {
        ToolAgentRegistry.definitions(for: $0, settings: store.settings, mcpTools: store.mcpTools)
      } ?? []
    if store.settings.toolCallingMode == .proxy {
      let normalizedCall = normalized(call: call, definitions: ToolProxy.definitions)
      switch normalizedCall.name {
      case ToolProxy.listName:
        return ToolProxy.listTools(
          arguments: normalizedCall.argumentValues, definitions: fullDefinitions)
      case ToolProxy.callName:
        return await ToolProxy.callTool(
          arguments: normalizedCall.argumentValues, definitions: fullDefinitions, store: store)
      default:
        return
          "Error: proxy mode only exposes '\(ToolProxy.listName)' and '\(ToolProxy.callName)'. Use '\(ToolProxy.callName)' to call enabled tools."
      }
    }

    let normalizedCall = normalized(call: call, definitions: fullDefinitions)
    return await executeConcrete(call: normalizedCall, store: store, definitions: fullDefinitions)
  }

  fileprivate static func executeConcrete(
    call: ParsedToolCall, store: AppStore, definitions: [ToolDefinition]
  ) async -> String {
    let normalizedCall = normalized(call: call, definitions: definitions)
    switch normalizedCall.name {
    case TodoTool.listName:
      return TodoTool.list(store: store)
    case TodoTool.addName:
      let title = normalizedCall.arguments["title"] ?? ""
      return TodoTool.add(title: title, store: store)
    case TodoTool.doneName:
      let query =
        normalizedCall.arguments["title_or_id"] ?? normalizedCall.arguments["id"]
        ?? normalizedCall.arguments["title"] ?? ""
      return TodoTool.markDone(query: query, store: store)
    default:
      return await dispatchMCP(call: normalizedCall, store: store)
    }
  }

  private static func dispatchMCP(call: ParsedToolCall, store: AppStore) async -> String {
    let conversationDisabled = store.currentConversation?.disabledMCPTools ?? []
    for server in store.settings.mcpServers
    where server.isEnabled && server.hasValidScheme {
      let tools = store.mcpTools[server.id] ?? []
      guard tools.contains(where: { $0.name == call.name }) else { continue }
      let key = "\(server.id.uuidString):\(call.name)"
      if conversationDisabled.contains(key) {
        return "Error: tool '\(call.name)' is disabled for this conversation."
      }
      do {
        return try await MCPHTTPClient.callTool(
          server: server, name: call.name, arguments: call.argumentValues)
      } catch {
        return "Error calling MCP tool '\(call.name)': \(error.localizedDescription)"
      }
    }
    return "Error: unknown tool '\(call.name)'. Refresh MCP tools in Settings if you expect it."
  }

  static func makeRunBlock(call: ParsedToolCall, result: String) -> String {
    AgentTooling.makeRunBlock(toolName: call.name, argumentsJSON: call.argsJSON, result: result)
  }
}

@MainActor
enum ToolProxy {
  static let listName = "list-tools"
  static let callName = "call-tool"

  static let definitions: [ToolDefinition] = [
    ToolDefinition(
      name: listName,
      description:
        "List enabled tools whose name, description, or argument names match the provided keywords. Call this before call-tool unless the target tool was already listed in the conversation.",
      parameters: [
        ToolParameterDef(
          name: "keywords", type: "string",
          description:
            "Space-separated search keywords for the task, tool name, capability, or argument names.",
          required: true)
      ]
    ),
    ToolDefinition(
      name: callName,
      description:
        "Call one enabled tool by exact name after list-tools has returned it. Pass the selected tool's arguments as a JSON object.",
      parameters: [
        ToolParameterDef(
          name: "name", type: "string",
          description: "Exact tool name returned by list-tools.",
          required: true),
        ToolParameterDef(
          name: "arguments", type: "object",
          description: "JSON object with arguments for the selected tool. Use {} when none.",
          required: true),
      ]
    ),
  ]

  static func listTools(
    arguments: [String: AgentToolArgumentValue], definitions: [ToolDefinition]
  ) -> String {
    let keywords =
      arguments["keywords"]?.stringValue ?? arguments["query"]?.stringValue
      ?? arguments["filter"]?.stringValue ?? ""
    let terms =
      keywords
      .lowercased()
      .split { $0.isWhitespace || $0 == "," }
      .map(String.init)

    let matches = definitions.compactMap {
      definition -> (definition: ToolDefinition, score: Int)? in
      guard !terms.isEmpty else { return (definition, 0) }
      let searchable = searchableText(for: definition)
      let score = terms.reduce(0) { count, term in
        searchable.contains(term) ? count + 1 : count
      }
      return score > 0 ? (definition, score) : nil
    }
    .sorted {
      if $0.score != $1.score { return $0.score > $1.score }
      return $0.definition.name < $1.definition.name
    }

    guard !matches.isEmpty else {
      let suffix =
        keywords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "" : " matching '\(keywords)'"
      return "No enabled tools\(suffix). Try broader keywords."
    }

    return matches.map { match in
      toolSummary(match.definition)
    }.joined(separator: "\n")
  }

  static func callTool(
    arguments: [String: AgentToolArgumentValue],
    definitions: [ToolDefinition],
    store: AppStore
  ) async -> String {
    let requestedName =
      arguments["name"]?.stringValue ?? arguments["tool_name"]?.stringValue
      ?? arguments["tool"]?.stringValue ?? ""
    let resolver = AgentToolNameResolver(tools: definitions)
    guard let canonicalName = resolver.canonicalName(for: requestedName) else {
      return
        "Error: unknown tool '\(requestedName)'. Call \(listName) first with relevant keywords."
    }
    guard let targetDefinition = definitions.first(where: { $0.name == canonicalName }) else {
      return "Error: unknown tool '\(requestedName)'."
    }
    let toolArguments = argumentsObject(from: arguments["arguments"])
    let normalizedArguments = AgentTooling.normalizeArguments(toolArguments, for: targetDefinition)
    let targetCall = ParsedToolCall(
      name: canonicalName,
      arguments: [:],
      argumentValues: normalizedArguments,
      rawBlock: ""
    )
    return await ToolAgentRegistry.executeConcrete(
      call: targetCall, store: store, definitions: definitions)
  }

  private static func searchableText(for definition: ToolDefinition) -> String {
    ([definition.name, definition.description]
      + definition.parameters.flatMap { [$0.name, $0.type, $0.description] })
      .joined(separator: " ")
      .lowercased()
  }

  private static func toolSummary(_ definition: ToolDefinition) -> String {
    let arguments: String
    if definition.parameters.isEmpty {
      arguments = "no arguments"
    } else {
      arguments = definition.parameters.map { parameter in
        let required = parameter.required ? "required" : "optional"
        let description = parameter.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = description.isEmpty ? "" : " - \(description)"
        return "\(parameter.name) (\(parameter.type), \(required))\(suffix)"
      }.joined(separator: "; ")
    }
    return "- \(definition.name): \(definition.description) Arguments: \(arguments)."
  }

  private static func argumentsObject(
    from value: AgentToolArgumentValue?
  ) -> [String: AgentToolArgumentValue] {
    guard let value else { return [:] }
    switch value {
    case .object(let object):
      return object
    case .string(let string):
      guard let data = string.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return [:] }
      return AgentTooling.argumentValues(object)
    default:
      return [:]
    }
  }
}

@MainActor
enum TodoTool {
  static let listName = "todo_list"
  static let addName = "todo_add"
  static let doneName = "todo_done"

  static let definitions: [ToolDefinition] = [
    ToolDefinition(
      name: listName,
      description: "List all of the user's todos with their short IDs and status (pending/done).",
      parameters: []
    ),
    ToolDefinition(
      name: addName,
      description: "Append a new pending todo to the user's todo list.",
      parameters: [
        ToolParameterDef(
          name: "title", type: "string",
          description: "The text/title of the todo to add", required: true)
      ]
    ),
    ToolDefinition(
      name: doneName,
      description:
        "Mark a pending todo as done. Match by short ID (first 8 chars) or a substring of the title.",
      parameters: [
        ToolParameterDef(
          name: "title_or_id", type: "string",
          description: "Either the short ID (8 hex chars) or a substring of the todo title",
          required: true)
      ]
    ),
  ]

  static func list(store: AppStore) -> String {
    let todos = store.settings.toolSettings.todos
    if todos.isEmpty { return "No todos." }
    return todos.map { todo in
      let id = String(todo.id.uuidString.prefix(8))
      let status = todo.isDone ? "[done]" : "[pending]"
      return "- \(id) \(status) \(todo.title)"
    }.joined(separator: "\n")
  }

  static func add(title: String, store: AppStore) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "Error: title cannot be empty." }
    let todo = TodoItem(title: trimmed)
    var snapshot = store.settings
    snapshot.toolSettings.todos.append(todo)
    store.settings = snapshot
    store.saveSettings()
    return "Added: \(trimmed) (id=\(String(todo.id.uuidString.prefix(8))))"
  }

  static func markDone(query: String, store: AppStore) -> String {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return "Error: title_or_id is required." }
    let lower = q.lowercased()
    var snapshot = store.settings
    if let index = snapshot.toolSettings.todos.firstIndex(where: { todo in
      todo.id.uuidString.lowercased().hasPrefix(lower)
        || todo.title.lowercased().contains(lower)
    }) {
      if snapshot.toolSettings.todos[index].isDone {
        return "Already done: \(snapshot.toolSettings.todos[index].title)"
      }
      snapshot.toolSettings.todos[index].isDone = true
      let title = snapshot.toolSettings.todos[index].title
      store.settings = snapshot
      store.saveSettings()
      return "Marked done: \(title)"
    }
    return "Error: no todo matched '\(q)'."
  }
}
