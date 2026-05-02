import AVFoundation
import Foundation

@MainActor
enum ToolAgentRegistry {
  static func visibleDefinitions(
    for conversation: Conversation,
    settings: AppSettings,
    mcpTools: [UUID: [MCPToolDescriptor]] = [:]
  ) -> [ToolDefinition] {
    let fullDefinitions = definitions(for: conversation, settings: settings, mcpTools: mcpTools)
    guard settings.useToolProxy else { return fullDefinitions }
    return fullDefinitions.isEmpty ? [] : ToolProxy.definitions
  }

  static func definitions(
    for conversation: Conversation,
    settings: AppSettings,
    mcpTools: [UUID: [MCPToolDescriptor]] = [:]
  ) -> [ToolDefinition] {
    var defs: [ToolDefinition] = []
    if conversation.enabledTools.contains(.webSearch) {
      defs.append(contentsOf: WebSearchTool.definitions(settings: settings.toolSettings))
    }
    if conversation.enabledTools.contains(.todo) {
      defs.append(contentsOf: TodoTool.definitions)
    }
    if conversation.enabledTools.contains(.textToSpeech) {
      defs.append(contentsOf: TextToSpeechTool.definitions)
    }
    if conversation.enabledTools.contains(.weather) {
      defs.append(contentsOf: WeatherTool.definitions)
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
    guard !definitions.isEmpty else { return [] }
    return AgentTooling.parseCalls(in: text, tools: definitions)
  }

  static func shouldEnterAgentLoop(for prompt: String, definitions: [ToolDefinition]) -> Bool {
    guard !definitions.isEmpty else { return false }
    let text = prompt.lowercased()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return false }

    let names = Set(definitions.map(\.name))
    if names.contains(WebSearchTool.name) || names.contains(WebSearchTool.fetchName) {
      if containsAny(
        text,
        [
          "search the web", "web search", "look up", "lookup", "browse", "internet",
          "online", "latest", "recent news", "news about", "fetch http", "fetch https",
          "open http", "open https",
        ])
      {
        return true
      }
    }
    if names.contains(WeatherTool.name) {
      if containsAny(
        text,
        [
          "weather", "forecast", "temperature", "rain", "raining", "wind", "humidity",
          "umbrella",
        ])
      {
        return true
      }
    }
    if names.contains(TodoTool.listName) || names.contains(TodoTool.addName)
      || names.contains(TodoTool.doneName)
    {
      if containsAny(
        text,
        [
          "todo", "to-do", "task list", "add a task", "add task", "mark done",
          "mark it done", "check off",
        ])
      {
        return true
      }
    }
    if names.contains(TextToSpeechTool.name) {
      if containsAny(
        text,
        ["speak", "read aloud", "read this aloud", "say this out loud", "text to speech", "tts"])
      {
        return true
      }
    }
    if containsAny(text, ["use a tool", "use the tool", "call a tool", "call the tool", "mcp"]) {
      return true
    }

    let compactPrompt = compactToolMatchKey(text)
    let promptTokens = significantTokens(in: text)
    return definitions.contains { definition in
      if toolNameLikelyMentioned(definition.name, in: compactPrompt) {
        return true
      }
      guard !isBuiltInTool(definition.name) else { return false }
      let searchable = ([definition.name, definition.description]
        + definition.parameters.flatMap { [$0.name, $0.description] })
        .joined(separator: " ")
      return promptTokens.intersection(significantTokens(in: searchable)).count >= 2
    }
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

  private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
    needles.contains { text.contains($0) }
  }

  private static func toolNameLikelyMentioned(_ name: String, in compactPrompt: String) -> Bool {
    let candidates = [
      name,
      name.replacingOccurrences(of: "::", with: " "),
      name.replacingOccurrences(of: "_", with: " "),
      name.replacingOccurrences(of: "-", with: " "),
      name.split(separator: ".").last.map(String.init) ?? name,
      name.components(separatedBy: "::").last ?? name,
    ]
    return candidates.contains { candidate in
      let key = compactToolMatchKey(candidate)
      return key.count >= 4 && compactPrompt.contains(key)
    }
  }

  private static func compactToolMatchKey(_ text: String) -> String {
    text.lowercased().filter { $0.isLetter || $0.isNumber }
  }

  private static func significantTokens(in text: String) -> Set<String> {
    let stopwords: Set<String> = [
      "about", "after", "again", "also", "and", "are", "argument", "arguments", "call",
      "from", "have", "into", "list", "name", "need", "only", "please", "return",
      "that", "the", "this", "tool", "tools", "use", "using", "what", "when", "with",
      "your",
    ]
    let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
      .filter { $0.count >= 4 && !stopwords.contains($0) }
    return Set(words)
  }

  private static func isBuiltInTool(_ name: String) -> Bool {
    switch name {
    case WebSearchTool.name, WebSearchTool.fetchName, WeatherTool.name,
      TodoTool.listName, TodoTool.addName, TodoTool.doneName, TextToSpeechTool.name:
      return true
    default:
      return false
    }
  }

  static func execute(call: ParsedToolCall, store: AppStore) async -> String {
    let fullDefinitions =
      store.currentConversation.map {
        ToolAgentRegistry.definitions(for: $0, settings: store.settings, mcpTools: store.mcpTools)
      } ?? []
    if store.settings.useToolProxy && !fullDefinitions.isEmpty {
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
    case WebSearchTool.name:
      return await WebSearchTool.search(
        arguments: normalizedCall.argumentValues, settings: store.settings)
    case WebSearchTool.fetchName:
      return await WebSearchTool.fetch(arguments: normalizedCall.argumentValues)
    case TextToSpeechTool.name:
      return TextToSpeechTool.speak(
        arguments: normalizedCall.argumentValues,
        settings: store.settings.toolSettings,
        openAIEndpoints: store.settings.openAIEndpoints)
    case DateTimeTool.name:
      return DateTimeTool.run(settings: store.settings.toolSettings)
    case LocationTool.name:
      return await LocationTool.run(
        settings: store.settings.toolSettings, locationService: { store.locationService })
    case WeatherTool.name:
      return await WeatherTool.run(
        settings: store.settings.toolSettings, locationService: { store.locationService })
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
enum WebSearchTool {
  static let name = "web_search"
  static let fetchName = "web_fetch"

  static func definitions(settings: NativeToolSettings) -> [ToolDefinition] {
    var definitions = [
      ToolDefinition(
        name: name,
        description:
          "Search the web only when current or external information is needed. Do not call this for ordinary conversation, writing, coding from provided context, or questions answerable without fresh lookup.",
        parameters: [
          ToolParameterDef(
            name: "query", type: "string",
            description:
              "Focused search query. Use only the information needed for lookup; do not include unrelated chat history.",
            required: true),
          ToolParameterDef(
            name: "provider", type: "string",
            description:
              "Optional provider override: duckDuckGo, wikipedia, ollama, or all. Omit to use the configured default.",
            required: false),
        ])
    ]
    if settings.webSearchFetchingEnabled {
      definitions.append(
        ToolDefinition(
          name: fetchName,
          description:
            "Fetch a specific HTTP or HTTPS URL and return cleaned page text. Use after search when the content of a result page is needed; do not use for files, images, private URLs, or ordinary questions.",
          parameters: [
            ToolParameterDef(
              name: "url", type: "string",
              description: "The full HTTP or HTTPS URL to fetch and clean.",
              required: true)
          ]))
    }
    return definitions
  }

  static func search(arguments: [String: AgentToolArgumentValue], settings: AppSettings) async
    -> String
  {
    let query = (arguments["query"]?.stringValue ?? arguments["q"]?.stringValue ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return "Error: query is required." }
    let provider =
      providerValue(arguments["provider"]?.stringValue)
      ?? settings.toolSettings.webSearchProvider
    guard
      let result = await WebSearchService.searchContext(
        query: query, provider: provider, settings: settings)
    else {
      return "No web results for '\(query)'."
    }
    return result
  }

  static func fetch(arguments: [String: AgentToolArgumentValue]) async -> String {
    let url = (arguments["url"]?.stringValue ?? arguments["uri"]?.stringValue ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !url.isEmpty else { return "Error: url is required." }
    return await WebFetchService.fetchContext(urlString: url)
  }

  private static func providerValue(_ raw: String?) -> WebSearchProvider? {
    let normalized = (raw ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .filter { $0.isLetter || $0.isNumber }
    guard !normalized.isEmpty else { return nil }
    return WebSearchProvider.allCases.first { provider in
      provider.rawValue.lowercased().filter { $0.isLetter || $0.isNumber } == normalized
        || provider.displayName.lowercased().filter { $0.isLetter || $0.isNumber } == normalized
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
    store.settings.toolSettings.todos.append(todo)
    store.saveSettings()
    return "Added: \(trimmed) (id=\(String(todo.id.uuidString.prefix(8))))"
  }

  static func markDone(query: String, store: AppStore) -> String {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return "Error: title_or_id is required." }
    let lower = q.lowercased()
    guard
      let index = store.settings.toolSettings.todos.firstIndex(where: { todo in
        todo.id.uuidString.lowercased().hasPrefix(lower)
          || todo.title.lowercased().contains(lower)
      })
    else {
      return "Error: no todo matched '\(q)'."
    }
    if store.settings.toolSettings.todos[index].isDone {
      return "Already done: \(store.settings.toolSettings.todos[index].title)"
    }
    store.settings.toolSettings.todos[index].isDone = true
    let title = store.settings.toolSettings.todos[index].title
    store.saveSettings()
    return "Marked done: \(title)"
  }
}

@MainActor
enum TextToSpeechTool {
  static let name = "text-to-speech"

  static let definitions: [ToolDefinition] = [
    ToolDefinition(
      name: name,
      description:
        "Speak the provided text aloud on this iOS device using the configured text-to-speech voice.",
      parameters: [
        ToolParameterDef(
          name: "text", type: "string",
          description:
            "Text to speak aloud. Keep it concise unless the user asks for a long reading.",
          required: true),
        ToolParameterDef(
          name: "language", type: "string",
          description:
            "Optional BCP-47 voice language, such as en-US or es-ES. Omit to use the configured default.",
          required: false),
        ToolParameterDef(
          name: "voice", type: "string",
          description:
            "Optional voice identifier. Omit to use the configured default voice.",
          required: false),
        ToolParameterDef(
          name: "rate", type: "number",
          description:
            "Optional speaking rate from 0.0 to 1.0. Omit to use the configured default.",
          required: false),
        ToolParameterDef(
          name: "pitch", type: "number",
          description:
            "Optional pitch multiplier from 0.5 to 2.0. Omit to use the configured default.",
          required: false),
        ToolParameterDef(
          name: "interrupt", type: "boolean",
          description:
            "Whether to stop current speech before speaking this text. Default: true.",
          required: false),
      ])
  ]

  static func speak(
    arguments: [String: AgentToolArgumentValue],
    settings: NativeToolSettings,
    openAIEndpoints: [OpenAIEndpoint] = [],
    role: VoiceRole = .assistant,
    title: String? = nil,
    messageID: UUID? = nil
  ) -> String {
    let text = TTSSpeechTextSanitizer.sanitized(arguments["text"]?.stringValue ?? "")
    guard !text.isEmpty else { return "Error: text is required." }

    let interrupt = arguments["interrupt"]?.boolValue ?? true
    let roleDefaults = settings.voices.settings(for: role)
    let voiceOverride =
      AgentTooling.firstNonEmpty(
        arguments["voice"]?.stringValue,
        arguments["voice_identifier"]?.stringValue)
    let languageOverride = arguments["language"]?.stringValue
    var voice = roleDefaults
    voice.language = languageOverride ?? roleDefaults.language
    voice.rate = arguments["rate"]?.numberValue ?? roleDefaults.rate
    voice.pitch = arguments["pitch"]?.numberValue ?? roleDefaults.pitch
    if let voiceOverride {
      if roleDefaults.provider == .openAICompatible {
        voice.openAIVoice = voiceOverride
      } else {
        voice.voiceIdentifier = voiceOverride
      }
    }
    let selectedVoice = RoleVoiceSettings(
      provider: voice.provider,
      language: languageOverride ?? roleDefaults.language,
      voiceIdentifier: voice.voiceIdentifier,
      openAIEndpointID: voice.openAIEndpointID,
      openAIVoice: voice.openAIVoice,
      rate: arguments["rate"]?.numberValue ?? roleDefaults.rate,
      pitch: arguments["pitch"]?.numberValue ?? roleDefaults.pitch)

    TTSPlayer.shared.speak(
      text: text,
      voice: selectedVoice,
      role: role,
      title: title,
      messageID: messageID,
      openAIEndpoints: openAIEndpoints,
      interrupt: interrupt)
    return "Speaking \(text.count) character\(text.count == 1 ? "" : "s")."
  }
}

@MainActor
enum DateTimeTool {
  static let name = "datetime"

  static let definitions: [ToolDefinition] = [
    ToolDefinition(
      name: name,
      description:
        "Return the current date/time plus optional time zone and moon phase using the user's configured Date & Time options.",
      parameters: []
    )
  ]

  static func run(settings: NativeToolSettings) -> String {
    DateTimeRenderer.render(settings: settings)
  }
}

@MainActor
enum LocationTool {
  static let name = "location"

  static let definitions: [ToolDefinition] = [
    ToolDefinition(
      name: name,
      description:
        "Return the user's current location using GPS or the manually configured location, depending on settings.",
      parameters: []
    )
  ]

  static func run(
    settings: NativeToolSettings,
    locationService: @MainActor () -> LocationService
  ) async -> String {
    await LocationRenderer.render(settings: settings, locationService: locationService)
  }
}

@MainActor
enum WeatherTool {
  static let name = "weather"

  static let definitions: [ToolDefinition] = [
    ToolDefinition(
      name: name,
      description:
        "Get current weather, a 7-day forecast (temperatures, wind, precipitation, chance of rain), and the moon phase for the configured location. Falls back to a secondary provider if the first one fails.",
      parameters: []
    )
  ]

  static func run(
    settings: NativeToolSettings,
    locationService: @MainActor () -> LocationService
  ) async -> String {
    if let report = await WeatherService.report(
      settings: settings, locationService: locationService)
    {
      return report
    }
    return "Weather unavailable."
  }
}
