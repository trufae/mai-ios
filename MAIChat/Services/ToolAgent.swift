import Foundation

struct ToolDefinition: Sendable {
  let name: String
  let description: String
  let parameters: [ToolParameterDef]
}

struct ToolParameterDef: Sendable {
  let name: String
  let type: String
  let description: String
  let required: Bool
}

struct ParsedToolCall: Identifiable, Sendable {
  let id = UUID()
  let name: String
  let arguments: [String: String]
  let rawBlock: String
  let argsJSON: String
}

@MainActor
enum ToolAgentRegistry {
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
          ToolDefinition(name: tool.name, description: description, parameters: []))
      }
    }
    return defs
  }

  static func promptDescription(for definitions: [ToolDefinition]) -> String {
    guard !definitions.isEmpty else { return "" }
    let toolDescriptions = definitions.map { def -> String in
      let params: String
      if def.parameters.isEmpty {
        params = "no arguments"
      } else {
        params = def.parameters.map { p in
          "\(p.name) (\(p.type)\(p.required ? "" : ", optional")): \(p.description)"
        }.joined(separator: "; ")
      }
      return "- \(def.name): \(def.description) Arguments: \(params)."
    }.joined(separator: "\n")

    return """
      ## Available Tools

      \(toolDescriptions)

      ### Tool-call protocol

      To run a tool, emit a single line block (no surrounding text on the same line):
      <tool_call>{"name":"tool_name","arguments":{"arg":"value"}}</tool_call>

      ### Mandatory rules — read carefully

      1. After the closing `</tool_call>`, STOP IMMEDIATELY. Do not write your final answer in the same response. The host executes the tool, replaces the block with `<tool_run>…result…</tool_run>`, and re-invokes you with the real result visible. Only THEN write the answer.
      2. `<tool_run>` blocks are AUTHORITATIVE ground truth. Read the content character-by-character. Do not guess, paraphrase, or summarize from priors. If the result disagrees with your expectations, the result is right.
      3. The final answer is the response that contains NO `<tool_call>` blocks. The loop stops as soon as you produce one.
      4. Use only the listed tool names. Never invent arguments. JSON arguments must be valid JSON on a single line.
      5. Do not re-call a tool whose `<tool_run>` is already in the conversation — read the existing result.
      6. No filler narration between tool calls ("Let me…", "I'll now…"). Emit tool calls or the final answer; nothing else.
      """
  }

  static func parseCalls(in text: String) -> [ParsedToolCall] {
    let pattern = "<tool_call>([\\s\\S]*?)</tool_call>"
    guard
      let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    else { return [] }
    let nsText = text as NSString
    let matches = regex.matches(
      in: text, options: [], range: NSRange(location: 0, length: nsText.length))
    var calls: [ParsedToolCall] = []
    for match in matches {
      guard match.numberOfRanges == 2 else { continue }
      let raw = nsText.substring(with: match.range(at: 0))
      let json = nsText.substring(with: match.range(at: 1))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard let data = json.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { continue }
      guard
        let name = (object["name"] as? String)?
          .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
      else { continue }
      var args: [String: String] = [:]
      if let argsDict = object["arguments"] as? [String: Any] {
        for (k, v) in argsDict {
          args[k] = stringify(v)
        }
      }
      let argsJSON = compactJSON(args)
      calls.append(ParsedToolCall(name: name, arguments: args, rawBlock: raw, argsJSON: argsJSON))
    }
    return calls
  }

  static func execute(call: ParsedToolCall, store: AppStore) async -> String {
    switch call.name {
    case TodoTool.listName:
      return TodoTool.list(store: store)
    case TodoTool.addName:
      let title = call.arguments["title"] ?? ""
      return TodoTool.add(title: title, store: store)
    case TodoTool.doneName:
      let query =
        call.arguments["title_or_id"] ?? call.arguments["id"]
        ?? call.arguments["title"] ?? ""
      return TodoTool.markDone(query: query, store: store)
    default:
      return await dispatchMCP(call: call, store: store)
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
          server: server, name: call.name, arguments: call.arguments)
      } catch {
        return "Error calling MCP tool '\(call.name)': \(error.localizedDescription)"
      }
    }
    return "Error: unknown tool '\(call.name)'. Refresh MCP tools in Settings if you expect it."
  }

  static func makeRunBlock(call: ParsedToolCall, result: String) -> String {
    let header = "\(call.name) tool (\(call.argsJSON)):"
    let body = result.trimmingCharacters(in: .whitespacesAndNewlines)
    return "<tool_run>\n\(header)\n\(body)\n</tool_run>"
  }

  private static func stringify(_ value: Any) -> String {
    if let s = value as? String { return s }
    if let n = value as? NSNumber { return n.stringValue }
    if let b = value as? Bool { return b ? "true" : "false" }
    if let data = try? JSONSerialization.data(withJSONObject: value),
      let s = String(data: data, encoding: .utf8)
    {
      return s
    }
    return String(describing: value)
  }

  private static func compactJSON(_ args: [String: String]) -> String {
    guard !args.isEmpty,
      let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]),
      let s = String(data: data, encoding: .utf8)
    else { return "{}" }
    return s
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
