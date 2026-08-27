import AVFoundation
import Foundation
import UIKit

enum ToolApprovalKind: Sendable {
  case auto
  case confirm
  case dangerous
}

struct BuiltInToolCatalogEntry: Sendable {
  let id: BuiltInToolID
  let toolNames: [String]
  let approvalKind: ToolApprovalKind
}

@MainActor
enum BuiltInToolCatalog {
  static let entries: [BuiltInToolCatalogEntry] = [
    BuiltInToolCatalogEntry(
      id: .datetime,
      toolNames: [DateTimeTool.name],
      approvalKind: .auto),
    BuiltInToolCatalogEntry(
      id: .location,
      toolNames: [LocationTool.name],
      approvalKind: .confirm),
    BuiltInToolCatalogEntry(
      id: .weather,
      toolNames: [WeatherTool.name],
      approvalKind: .auto),
    BuiltInToolCatalogEntry(
      id: .webSearch,
      toolNames: [WebSearchTool.name, WebSearchTool.fetchName],
      approvalKind: .confirm),
    BuiltInToolCatalogEntry(
      id: .todo,
      toolNames: [TodoTool.listName, TodoTool.addName, TodoTool.doneName],
      approvalKind: .confirm),
    BuiltInToolCatalogEntry(
      id: .calculator,
      toolNames: [CalculatorTool.name],
      approvalKind: .auto),
    BuiltInToolCatalogEntry(
      id: .textToSpeech,
      toolNames: [TextToSpeechTool.name],
      approvalKind: .confirm),
    BuiltInToolCatalogEntry(
      id: .files,
      toolNames: [
        FileWorkspaceTool.listName,
        FileWorkspaceTool.readName,
        FileWorkspaceTool.readDocumentName,
        FileWorkspaceTool.readIndexName,
        FileWorkspaceTool.readRangeName,
        FileWorkspaceTool.replaceRangeName,
        FileWorkspaceTool.writeName,
        FileWorkspaceTool.renameName,
        FileWorkspaceTool.deleteName,
      ],
      approvalKind: .dangerous),
    BuiltInToolCatalogEntry(
      id: .calendar,
      toolNames: [CalendarTool.readName, CalendarTool.createName],
      approvalKind: .confirm),
    BuiltInToolCatalogEntry(
      id: .clipboard,
      toolNames: [ClipboardTool.getName, ClipboardTool.setName],
      approvalKind: .confirm),
    BuiltInToolCatalogEntry(
      id: .alarms,
      toolNames: [AlarmTool.setName, AlarmTool.listName, AlarmTool.cancelName],
      approvalKind: .confirm),
    BuiltInToolCatalogEntry(
      id: .webxdc,
      toolNames: WebXDCTool.toolNames,
      approvalKind: .confirm),
  ]

  static func definitions(
    for conversation: Conversation,
    settings: AppSettings
  ) -> [ToolDefinition] {
    entries.flatMap { entry -> [ToolDefinition] in
      guard conversation.enabledTools.contains(entry.id), entry.id.isCallableTool else { return [] }
      guard !(settings.airplaneModeEnabled && entry.id.isDisabledInAirplaneMode) else {
        return []
      }
      return definitions(for: entry.id, conversation: conversation, settings: settings)
    }
  }

  static func isBuiltInToolName(_ name: String) -> Bool {
    entry(containingToolName: name) != nil
  }

  static func approvalKind(forToolName name: String) -> ToolApprovalKind? {
    entry(containingToolName: name)?.approvalKind
  }

  static func execute(
    call: ParsedToolCall,
    conversation: Conversation,
    store: AppStore
  ) async -> String? {
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
    case CalculatorTool.name:
      return CalculatorTool.run(arguments: call.argumentValues)
    case WebSearchTool.name:
      guard !store.settings.airplaneModeEnabled else {
        return "Error: web search is disabled while Airplane Mode is enabled."
      }
      return await WebSearchTool.search(
        arguments: call.argumentValues, settings: store.settings)
    case WebSearchTool.fetchName:
      guard !store.settings.airplaneModeEnabled else {
        return "Error: web fetch is disabled while Airplane Mode is enabled."
      }
      return await WebSearchTool.fetch(arguments: call.argumentValues)
    case TextToSpeechTool.name:
      return TextToSpeechTool.speak(
        arguments: call.argumentValues,
        settings: store.effectiveToolSettings(for: conversation),
        skipTechnicalContent: store.effectiveConversationSettings(for: conversation)
          .skipTechnicalContentInTTS,
        openAIEndpoints: store.settings.airplaneModeEnabled ? [] : store.settings.openAIEndpoints)
    case DateTimeTool.name:
      return DateTimeTool.run(settings: store.settings.toolSettings)
    case LocationTool.name:
      return await LocationTool.run(
        settings: store.settings.toolSettings, locationService: { store.locationService })
    case WeatherTool.name:
      guard !store.settings.airplaneModeEnabled else {
        return "Error: weather is disabled while Airplane Mode is enabled."
      }
      return await WeatherTool.run(
        arguments: call.argumentValues,
        settings: store.settings.toolSettings, locationService: { store.locationService })
    case FileWorkspaceTool.listName, FileWorkspaceTool.readName,
      FileWorkspaceTool.readDocumentName, FileWorkspaceTool.readIndexName,
      FileWorkspaceTool.readRangeName, FileWorkspaceTool.replaceRangeName,
      FileWorkspaceTool.writeName, FileWorkspaceTool.renameName, FileWorkspaceTool.deleteName:
      return await executeFileWorkspaceTool(
        name: call.name,
        arguments: call.argumentValues,
        conversation: conversation,
        store: store)
    case CalendarTool.readName:
      return await CalendarTool.readEvents(arguments: call.argumentValues)
    case CalendarTool.createName:
      return await CalendarTool.createEvent(
        arguments: call.argumentValues,
        settings: store.settings.toolSettings)
    case ClipboardTool.getName:
      return ClipboardTool.getText()
    case ClipboardTool.setName:
      return ClipboardTool.setText(arguments: call.argumentValues)
    case AlarmTool.setName:
      return await AlarmTool.set(arguments: call.argumentValues)
    case AlarmTool.listName:
      return AlarmTool.list()
    case AlarmTool.cancelName:
      return AlarmTool.cancel(arguments: call.argumentValues)
    case let name where WebXDCTool.toolNames.contains(name):
      return WebXDCTool.execute(
        name: name, arguments: call.argumentValues, hub: store.webxdcHub)
    default:
      return nil
    }
  }

  private static func executeFileWorkspaceTool(
    name: String,
    arguments: [String: AgentToolArgumentValue],
    conversation: Conversation,
    store: AppStore
  ) async -> String {
    guard fileWorkspaceToolsEnabled(conversation: conversation, settings: store.settings) else {
      return "Error: Files tools are disabled in Files settings."
    }
    let advancedToolNames = [
      FileWorkspaceTool.readIndexName,
      FileWorkspaceTool.readRangeName,
      FileWorkspaceTool.replaceRangeName,
    ]
    if advancedToolNames.contains(name),
      !store.settings.toolSettings.filesAdvancedToolsEnabled
    {
      return "Error: advanced file tools are disabled in Files settings."
    }
    let context: FileWorkspaceContext
    do {
      let resolved = try FileWorkspaceTool.context(for: conversation, settings: store.settings)
      if let refreshed = resolved.refreshedBookmarkData {
        store.refreshWorkingFolderBookmark(
          conversationID: conversation.id, bookmarkData: refreshed)
      }
      context = resolved.context
    } catch {
      let workspaceName = FileWorkspaceTool.workspaceName(
        for: conversation, settings: store.settings)
      return
        "Error: working folder '\(workspaceName)' is no longer accessible. Select it again from the chat's + menu."
    }
    switch name {
    case FileWorkspaceTool.listName:
      return FileWorkspaceService.list(arguments: arguments, in: context)
    case FileWorkspaceTool.readName:
      return FileWorkspaceService.read(arguments: arguments, in: context)
    case FileWorkspaceTool.readDocumentName:
      // Document conversion (PDF text extraction, OCR) can be slow, so it
      // runs off the main actor.
      return await Task.detached {
        FileWorkspaceService.readDocument(arguments: arguments, in: context)
      }.value
    case FileWorkspaceTool.readIndexName:
      return await Task.detached {
        FileWorkspaceService.readIndex(arguments: arguments, in: context)
      }.value
    case FileWorkspaceTool.readRangeName:
      return await Task.detached {
        FileWorkspaceService.readRange(arguments: arguments, in: context)
      }.value
    case FileWorkspaceTool.replaceRangeName:
      return FileWorkspaceService.replaceRange(arguments: arguments, in: context)
    case FileWorkspaceTool.writeName:
      return FileWorkspaceService.write(arguments: arguments, in: context)
    case FileWorkspaceTool.renameName:
      return FileWorkspaceService.rename(arguments: arguments, in: context)
    case FileWorkspaceTool.deleteName:
      return FileWorkspaceService.delete(arguments: arguments, in: context)
    default: return "Error: Unknown Files tool."
    }
  }

  private static func definitions(
    for id: BuiltInToolID,
    conversation: Conversation,
    settings: AppSettings
  ) -> [ToolDefinition] {
    switch id {
    case .datetime:
      return DateTimeTool.definitions
    case .language:
      return []
    case .location:
      return LocationTool.definitions
    case .weather:
      return WeatherTool.definitions
    case .webSearch:
      return WebSearchTool.definitions(settings: settings.toolSettings)
    case .todo:
      return TodoTool.definitions
    case .calculator:
      return CalculatorTool.definitions
    case .textToSpeech:
      return TextToSpeechTool.definitions
    case .files:
      guard settings.toolSettings.filesWorkspaceAccessEnabled else { return [] }
      return FileWorkspaceTool.definitions(
        workspaceName: FileWorkspaceTool.workspaceName(for: conversation, settings: settings),
        includeAdvancedTools: settings.toolSettings.filesAdvancedToolsEnabled)
    case .calendar:
      return CalendarTool.definitions(settings: settings.toolSettings)
    case .clipboard:
      return ClipboardTool.definitions
    case .alarms:
      return AlarmTool.definitions
    case .webxdc:
      return WebXDCTool.definitions
    case .memory:
      return []
    }
  }

  private static func entry(containingToolName name: String) -> BuiltInToolCatalogEntry? {
    entries.first { $0.toolNames.contains(name) }
  }

  private static func fileWorkspaceToolsEnabled(
    conversation: Conversation,
    settings: AppSettings
  ) -> Bool {
    conversation.toolsEnabled
      && conversation.enabledTools.contains(.files)
      && settings.toolSettings.filesWorkspaceAccessEnabled
  }
}

@MainActor
enum ToolAgentRegistry {
  static func visibleDefinitions(
    for conversation: Conversation,
    settings: AppSettings,
    mcpTools: [UUID: [MCPToolDescriptor]] = [:],
    mcpResources: [UUID: [MCPResourceDescriptor]] = [:],
    mcpStatuses: [UUID: EndpointConnectionState] = [:]
  ) -> [ToolDefinition] {
    let fullDefinitions = definitions(
      for: conversation,
      settings: settings,
      mcpTools: mcpTools,
      mcpResources: mcpResources,
      mcpStatuses: mcpStatuses)
    guard settings.useToolProxy else { return fullDefinitions }
    return fullDefinitions.isEmpty ? [] : ToolProxy.definitions
  }

  static func definitions(
    for conversation: Conversation,
    settings: AppSettings,
    mcpTools: [UUID: [MCPToolDescriptor]] = [:],
    mcpResources: [UUID: [MCPResourceDescriptor]] = [:],
    mcpStatuses: [UUID: EndpointConnectionState] = [:]
  ) -> [ToolDefinition] {
    guard conversation.toolsEnabled else { return [] }
    var defs = BuiltInToolCatalog.definitions(
      for: conversation,
      settings: settings)
    var enabledResourceServers: [(server: MCPServer, resources: [MCPResourceDescriptor])] = []
    for server in settings.mcpServers
    where server.isEnabled && server.hasValidEndpointURL
      && conversation.enabledMCPServers.contains(server.id)
      && mcpStatuses[server.id]?.isAvailable == true
    {
      let tools = mcpTools[server.id] ?? []
      for tool in tools {
        let key = MCPToolSelection.key(serverID: server.id, toolName: tool.name)
        guard conversation.enabledMCPTools.contains(key) else { continue }
        let description = cleanedToolDescription(
          tool.description,
          fallback: "MCP tool from \(server.name).")
        defs.append(
          ToolDefinition(
            name: tool.name,
            description: description,
            parameters: AgentTooling.parameters(fromSchemaJSON: tool.parametersJSON),
            inputSchemaJSON: tool.parametersJSON))
      }
      enabledResourceServers.append((server, mcpResources[server.id] ?? []))
    }
    if !enabledResourceServers.isEmpty {
      defs.append(MCPResourceTool.definition(for: enabledResourceServers))
    }
    return defs
  }

  private static func cleanedToolDescription(_ text: String, fallback: String) -> String {
    let cleaned = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return cleaned.isEmpty ? fallback : cleaned
  }

  static func promptDescription(
    for definitions: [ToolDefinition],
    mode: ToolCallingMode
  ) -> String {
    AgentTooling.promptDescription(for: definitions, mode: mode)
  }

  static func parseCalls(
    in text: String,
    definitions: [ToolDefinition],
    mode: ToolCallingMode
  ) -> [ParsedToolCall] {
    guard !definitions.isEmpty else { return [] }
    return AgentTooling.parseCalls(in: text, tools: definitions, mode: mode)
  }

  static func shouldEnterAgentLoop(for prompt: String, definitions: [ToolDefinition]) -> Bool {
    !definitions.isEmpty
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

  static func requiredArgumentsError(
    call: ParsedToolCall,
    definitions: [ToolDefinition]
  ) -> String? {
    guard let definition = definitions.first(where: { $0.name == call.name }) else {
      return nil
    }
    let missing = definition.parameters
      .filter(\.required)
      .filter { requiredArgumentIsMissing(call.argumentValues[$0.name]) }
      .map(\.name)
    guard !missing.isEmpty else { return nil }
    let names = missing.map { "'\($0)'" }.joined(separator: ", ")
    let noun = missing.count == 1 ? "argument" : "arguments"
    return "Error: missing required \(noun) \(names) for tool '\(call.name)'."
  }

  private static func requiredArgumentIsMissing(_ value: AgentToolArgumentValue?) -> Bool {
    guard let value else { return true }
    switch value {
    case .null:
      return true
    case .string(let string):
      return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    default:
      return false
    }
  }

  static func execute(
    call: ParsedToolCall,
    conversationID: UUID,
    store: AppStore
  ) async -> String {
    guard let conversation = store.conversation(withID: conversationID) else {
      return "Error: conversation is no longer available."
    }
    return await execute(call: call, conversation: conversation, store: store)
  }

  static func execute(
    call: ParsedToolCall,
    conversation: Conversation,
    store: AppStore
  ) async -> String {
    let fullDefinitions = ToolAgentRegistry.definitions(
      for: conversation,
      settings: store.settings,
      mcpTools: store.mcpTools,
      mcpResources: store.mcpResources,
      mcpStatuses: store.mcpStatuses)
    let visibleDefinitions = ToolAgentRegistry.visibleDefinitions(
      for: conversation,
      settings: store.settings,
      mcpTools: store.mcpTools,
      mcpResources: store.mcpResources,
      mcpStatuses: store.mcpStatuses)
    let visibleCall = normalized(call: call, definitions: visibleDefinitions)
    guard definitionExists(named: visibleCall.name, in: visibleDefinitions) else {
      return unavailableToolError(name: visibleCall.name)
    }

    if store.settings.useToolProxy && !fullDefinitions.isEmpty {
      switch visibleCall.name {
      case ToolProxy.listName:
        return ToolProxy.listTools(
          arguments: visibleCall.argumentValues, definitions: fullDefinitions)
      case ToolProxy.callName:
        return await ToolProxy.callTool(
          arguments: visibleCall.argumentValues,
          definitions: fullDefinitions,
          conversation: conversation,
          store: store)
      default:
        return
          "Error: proxy mode only exposes '\(ToolProxy.listName)' and '\(ToolProxy.callName)'. Use '\(ToolProxy.callName)' to call enabled tools."
      }
    }

    return await executeConcrete(
      call: visibleCall,
      conversation: conversation,
      store: store,
      definitions: fullDefinitions)
  }

  fileprivate static func executeConcrete(
    call: ParsedToolCall,
    conversation: Conversation,
    store: AppStore,
    definitions: [ToolDefinition]
  ) async -> String {
    let normalizedCall = normalized(call: call, definitions: definitions)
    guard definitionExists(named: normalizedCall.name, in: definitions) else {
      return unavailableToolError(name: normalizedCall.name)
    }
    if let result = await BuiltInToolCatalog.execute(
      call: normalizedCall,
      conversation: conversation,
      store: store)
    {
      return result
    }
    if normalizedCall.name == MCPResourceTool.readName {
      return await MCPResourceTool.read(
        arguments: normalizedCall.argumentValues,
        conversation: conversation,
        store: store)
    }
    return await dispatchMCP(call: normalizedCall, conversation: conversation, store: store)
  }

  private static func dispatchMCP(
    call: ParsedToolCall,
    conversation: Conversation,
    store: AppStore
  ) async -> String {
    for server in store.settings.mcpServers
    where server.isEnabled && server.hasValidEndpointURL
      && conversation.enabledMCPServers.contains(server.id)
      && store.mcpStatuses[server.id]?.isAvailable == true
    {
      let tools = store.mcpTools[server.id] ?? []
      guard tools.contains(where: { $0.name == call.name }) else { continue }
      let key = MCPToolSelection.key(serverID: server.id, toolName: call.name)
      if !conversation.enabledMCPTools.contains(key) {
        return "Error: tool '\(call.name)' is disabled for this conversation."
      }
      do {
        let server = try await store.authorizedMCPServer(server)
        return try await MCPHTTPClient.callTool(
          server: server,
          name: call.name,
          arguments: call.argumentValues,
          timeout: InteractiveOperationTimeout.extendedTransportTimeoutInterval)
      } catch {
        if MCPHTTPClient.isAvailabilityFailure(error) {
          store.markMCPUnavailable(serverID: server.id, message: error.localizedDescription)
        }
        return "Error calling MCP tool '\(call.name)': \(error.localizedDescription)"
      }
    }
    return "Error: unknown tool '\(call.name)'. Refresh MCP tools in Settings if you expect it."
  }

  static func definitionExists(named name: String, in definitions: [ToolDefinition]) -> Bool {
    definitions.contains { $0.name == name }
  }

  static func unavailableToolError(name: String) -> String {
    "Error: tool '\(name)' is not available. It may be unknown or disabled for this conversation."
  }

  static func makeRunBlock(call: ParsedToolCall, result: String) -> String {
    AgentTooling.makeRunBlock(toolName: call.name, argumentsJSON: call.argsJSON, result: result)
  }
}

@MainActor
enum MCPResourceTool {
  static let readName = "mcp_read_resource"

  static func definition(
    for servers: [(server: MCPServer, resources: [MCPResourceDescriptor])]
  ) -> ToolDefinition {
    let resourceLines = servers.flatMap { server, resources in
      resources.map { resource in
        let label = resource.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = label.isEmpty ? "" : " - \(label)"
        return "- \(resource.uri)\(suffix) (\(server.name))"
      }
    }
    let listed = resourceLines.prefix(60).joined(separator: "\n")
    let overflow = resourceLines.count > 60 ? "\n- ...and more resources." : ""
    let knownResources =
      listed.isEmpty
      ? "No cached resources are listed yet. Use a known MCP resource URI such as uapi://agent-guide when the matching server is enabled."
      : "Known enabled MCP resources:\n\(listed)\(overflow)"
    return ToolDefinition(
      name: readName,
      description:
        "Read an MCP resource by URI through the matching enabled MCP server. Use this for resource URIs such as uapi://agent-guide. \(knownResources)",
      parameters: [
        ToolParameterDef(
          name: "uri",
          type: "string",
          description: "Exact MCP resource URI, for example uapi://agent-guide.",
          required: true)
      ])
  }

  static func read(
    arguments: [String: AgentToolArgumentValue],
    conversation: Conversation,
    store: AppStore
  ) async -> String {
    let uri =
      arguments["uri"]?.stringValue ?? arguments["url"]?.stringValue
      ?? arguments["resource"]?.stringValue ?? ""
    let trimmedURI = uri.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedURI.isEmpty else {
      return "Error: missing required argument 'uri' for tool '\(readName)'."
    }
    guard let server = resolveServer(for: trimmedURI, conversation: conversation, store: store)
    else {
      let available = availableResourceURIs(conversation: conversation, store: store)
      let suffix =
        available.isEmpty ? "" : " Available resources: \(available.joined(separator: ", "))"
      return "Error: no enabled MCP server can read resource '\(trimmedURI)'.\(suffix)"
    }
    do {
      let server = try await store.authorizedMCPServer(server)
      return try await MCPHTTPClient.readResource(
        server: server,
        uri: trimmedURI,
        timeout: InteractiveOperationTimeout.extendedTransportTimeoutInterval)
    } catch {
      if MCPHTTPClient.isAvailabilityFailure(error) {
        store.markMCPUnavailable(serverID: server.id, message: error.localizedDescription)
      }
      return "Error reading MCP resource '\(trimmedURI)': \(error.localizedDescription)"
    }
  }

  private static func resolveServer(
    for uri: String,
    conversation: Conversation,
    store: AppStore
  ) -> MCPServer? {
    let enabledServers = store.settings.mcpServers.filter {
      $0.isEnabled && $0.hasValidEndpointURL && conversation.enabledMCPServers.contains($0.id)
        && store.mcpStatuses[$0.id]?.isAvailable == true
    }
    if let exact = enabledServers.first(where: { server in
      (store.mcpResources[server.id] ?? []).contains { $0.uri == uri }
    }) {
      return exact
    }
    if let scheme = URLComponents(string: uri)?.scheme?.lowercased(),
      let byScheme = enabledServers.first(where: { schemeMatches(scheme, serverName: $0.name) })
    {
      return byScheme
    }
    return enabledServers.count == 1 ? enabledServers.first : nil
  }

  private static func availableResourceURIs(
    conversation: Conversation,
    store: AppStore
  ) -> [String] {
    store.settings.mcpServers
      .filter {
        $0.isEnabled && conversation.enabledMCPServers.contains($0.id)
          && store.mcpStatuses[$0.id]?.isAvailable == true
      }
      .flatMap { store.mcpResources[$0.id] ?? [] }
      .map(\.uri)
      .sorted()
  }

  private static func normalizedScheme(_ name: String) -> String {
    name.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "." || $0 == "-" }
  }

  private static func schemeMatches(_ scheme: String, serverName: String) -> Bool {
    if normalizedScheme(serverName) == scheme {
      return true
    }
    return serverName.lowercased()
      .split { !$0.isLetter && !$0.isNumber && $0 != "+" && $0 != "." && $0 != "-" }
      .contains { $0 == scheme }
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
        "Search enabled tools by capability, tool name, or argument name.",
      parameters: [
        ToolParameterDef(
          name: "keywords", type: "string",
          description: "Space-separated task, tool, capability, or argument keywords.",
          required: true)
      ]
    ),
    ToolDefinition(
      name: callName,
      description:
        "Call one enabled tool by exact name with JSON arguments.",
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
    conversation: Conversation,
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
      call: targetCall,
      conversation: conversation,
      store: store,
      definitions: definitions)
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
enum FileWorkspaceTool {
  static let listName = "files_list"
  static let readName = "files_read"
  static let readDocumentName = "files_read_document"
  static let readIndexName = "files_read_index"
  static let readRangeName = "files_read_range"
  static let replaceRangeName = "files_replace_range"
  static let writeName = "files_write"
  static let renameName = "files_rename"
  static let deleteName = "files_delete"

  /// The working folder the Files tools operate in for this conversation:
  /// the chat's own selection, else the chat folder's default, else nil for
  /// the built-in FilesData workspace.
  static func workingFolderReference(
    for conversation: Conversation,
    settings: AppSettings
  ) -> WorkingFolderReference? {
    conversation.workingFolder
      ?? settings.conversationFolderDefaults[conversation.folderID]?.workingFolder
  }

  static func workspaceName(for conversation: Conversation, settings: AppSettings) -> String {
    workingFolderReference(for: conversation, settings: settings)?.displayName
      ?? FileWorkspaceService.defaultWorkspaceName
  }

  static func context(
    for conversation: Conversation,
    settings: AppSettings
  ) throws -> (context: FileWorkspaceContext, refreshedBookmarkData: Data?) {
    guard let reference = workingFolderReference(for: conversation, settings: settings) else {
      return (try FileWorkspaceContext.filesData(), nil)
    }
    let resolved = try WorkingFolderAccess.resolve(reference)
    return (
      FileWorkspaceContext.custom(rootURL: resolved.url, displayName: reference.displayName),
      resolved.refreshedBookmarkData
    )
  }

  static func definitions(
    workspaceName name: String,
    includeAdvancedTools: Bool
  ) -> [ToolDefinition] {
    var definitions = [
      ToolDefinition(
        name: listName,
        description: "List a folder inside the working folder '\(name)'.",
        parameters: [
          ToolParameterDef(
            name: "path", type: "string",
            description: "Folder path inside \(name). Omit for the root folder.",
            required: false)
        ]
      ),
      ToolDefinition(
        name: readName,
        description: "Read a UTF-8 text file from the working folder '\(name)'.",
        parameters: [
          ToolParameterDef(
            name: "path", type: "string",
            description: "File path inside \(name).",
            required: true),
          ToolParameterDef(
            name: "max_bytes", type: "number",
            description: "Maximum bytes to return. Default: 120000.",
            required: false),
          ToolParameterDef(
            name: "offset", type: "number",
            description: "Byte offset to continue reading a large file. Default: 0.",
            required: false),
        ]
      ),
      ToolDefinition(
        name: readDocumentName,
        description:
          "Read a document from the working folder '\(name)' as text: Word (.docx) and PDF files are converted to Markdown, JSON files to an indented outline, anything else is read as UTF-8 text.",
        parameters: [
          ToolParameterDef(
            name: "path", type: "string",
            description: "File path inside \(name).",
            required: true),
          ToolParameterDef(
            name: "max_bytes", type: "number",
            description: "Maximum bytes to return. Default: 120000.",
            required: false),
          ToolParameterDef(
            name: "offset", type: "number",
            description: "Byte offset into the converted text to continue reading. Default: 0.",
            required: false),
        ]
      ),
      ToolDefinition(
        name: writeName,
        description:
          "Write or append text to a file, or create a folder, in the working folder '\(name)'.",
        parameters: [
          ToolParameterDef(
            name: "path", type: "string",
            description: "File or folder path in \(name).",
            required: true),
          ToolParameterDef(
            name: "content", type: "string",
            description: "Text to write. Required unless create_directory is true.",
            required: false),
          ToolParameterDef(
            name: "append", type: "boolean",
            description: "Append instead of replacing. Default: false.",
            required: false),
          ToolParameterDef(
            name: "create_directory", type: "boolean",
            description: "Create a folder instead of writing a file. Default: false.",
            required: false),
        ]
      ),
      ToolDefinition(
        name: renameName,
        description:
          "Rename or move a file or folder inside the working folder '\(name)'.",
        parameters: [
          ToolParameterDef(
            name: "path", type: "string",
            description: "Current path in \(name).",
            required: true),
          ToolParameterDef(
            name: "new_path", type: "string",
            description: "New path in \(name).",
            required: true),
        ]
      ),
      ToolDefinition(
        name: deleteName,
        description:
          "Delete a file or folder inside the working folder '\(name)'.",
        parameters: [
          ToolParameterDef(
            name: "path", type: "string",
            description: "File or folder path in \(name).",
            required: true),
          ToolParameterDef(
            name: "recursive", type: "boolean",
            description: "Delete non-empty folders. Default: false.",
            required: false),
        ]
      ),
    ]
    if includeAdvancedTools {
      definitions.append(contentsOf: advancedDefinitions(workspaceName: name))
    }
    return definitions
  }

  private static func advancedDefinitions(workspaceName name: String) -> [ToolDefinition] {
    [
      ToolDefinition(
        name: readIndexName,
        description:
          "List an index of a file in the working folder '\(name)' with 1-based line numbers: function and type names for source code, headings for Markdown and converted documents (.docx, .pdf), keys for JSON.",
        parameters: [
          ToolParameterDef(
            name: "path", type: "string",
            description: "File path inside \(name).",
            required: true)
        ]
      ),
      ToolDefinition(
        name: readRangeName,
        description:
          "Read a numbered range of lines from a file in the working folder '\(name)'. Word, PDF, and JSON files are converted like files_read_document, so line numbers match files_read_index.",
        parameters: [
          ToolParameterDef(
            name: "path", type: "string",
            description: "File path inside \(name).",
            required: true),
          ToolParameterDef(
            name: "start_line", type: "number",
            description: "First line to read, 1-based. Default: 1.",
            required: false),
          ToolParameterDef(
            name: "end_line", type: "number",
            description: "Last line to read, inclusive. Default: start_line + 199.",
            required: false),
        ]
      ),
      ToolDefinition(
        name: replaceRangeName,
        description:
          "Replace a 1-based inclusive line range of a UTF-8 text file in the working folder '\(name)'. Use end_line = start_line - 1 to insert before start_line; empty content deletes the range. Not available for converted documents (.docx, .pdf, .json).",
        parameters: [
          ToolParameterDef(
            name: "path", type: "string",
            description: "File path inside \(name).",
            required: true),
          ToolParameterDef(
            name: "start_line", type: "number",
            description: "First line to replace, 1-based.",
            required: true),
          ToolParameterDef(
            name: "end_line", type: "number",
            description: "Last line to replace, inclusive. Default: start_line.",
            required: false),
          ToolParameterDef(
            name: "content", type: "string",
            description:
              "New text for the range; may contain multiple lines. Omit to delete the range.",
            required: false),
        ]
      ),
    ]
  }
}

@MainActor
enum CalendarTool {
  static let readName = "calendar_read_events"
  static let createName = "calendar_create_event"

  static func definitions(settings: NativeToolSettings) -> [ToolDefinition] {
    var definitions = [
      ToolDefinition(
        name: readName,
        description:
          "Read calendar events for a handy date phrase, one date, or an explicit date range. Returns limited event details only.",
        parameters: [
          ToolParameterDef(
            name: "range",
            type: "string",
            description:
              "Handy range phrase: today, tomorrow, yesterday, week, week ahead, this week, next week, this month, next month. The host converts this to local YYYY-MM-DD boundaries. Default: today.",
            required: false),
          ToolParameterDef(
            name: "date",
            type: "string",
            description:
              "One local date to read: YYYY-MM-DD, today, tomorrow, or yesterday. Omit when using range or start_date/end_date.",
            required: false),
          ToolParameterDef(
            name: "start_date",
            type: "string",
            description:
              "Range start as YYYY-MM-DD, ISO 8601 date-time, today, tomorrow, or yesterday. Required with end_date for a custom range.",
            required: false),
          ToolParameterDef(
            name: "end_date",
            type: "string",
            description:
              "Range end as YYYY-MM-DD, ISO 8601 date-time, today, tomorrow, or yesterday. Required with start_date for a custom range.",
            required: false),
        ])
    ]
    if settings.calendarEventCreationEnabled {
      definitions.append(
        ToolDefinition(
          name: createName,
          description:
            "Create one calendar event. Only available when Calendar event creation is enabled in Settings.",
          parameters: [
            ToolParameterDef(
              name: "title",
              type: "string",
              description: "Event title.",
              required: true),
            ToolParameterDef(
              name: "start_date",
              type: "string",
              description: "Event start as YYYY-MM-DD, ISO 8601 date-time, today, tomorrow, or yesterday.",
              required: true),
            ToolParameterDef(
              name: "end_date",
              type: "string",
              description: "Event end as YYYY-MM-DD, ISO 8601 date-time, today, tomorrow, or yesterday.",
              required: true),
            ToolParameterDef(
              name: "all_day",
              type: "boolean",
              description: "Create an all-day event. Default: false.",
              required: false),
            ToolParameterDef(
              name: "location",
              type: "string",
              description: "Event location. Omit unless the user specified one.",
              required: false),
            ToolParameterDef(
              name: "notes",
              type: "string",
              description: "Short event notes. Omit unless the user specified notes.",
              required: false),
          ]))
    }
    return definitions
  }

  static func readEvents(arguments: [String: AgentToolArgumentValue]) async -> String {
    await CalendarEventService.readEvents(arguments: arguments)
  }

  static func createEvent(
    arguments: [String: AgentToolArgumentValue],
    settings: NativeToolSettings
  ) async -> String {
    await CalendarEventService.createEvent(arguments: arguments, settings: settings)
  }
}

@MainActor
enum ClipboardTool {
  static let getName = "clipboard_get_text"
  static let setName = "clipboard_set_text"

  static let definitions: [ToolDefinition] = [
    ToolDefinition(
      name: getName,
      description: "Read the current text content of the system clipboard.",
      parameters: []
    ),
    ToolDefinition(
      name: setName,
      description: "Replace the system clipboard content with the given text.",
      parameters: [
        ToolParameterDef(
          name: "text", type: "string",
          description: "Text to place on the clipboard.",
          required: true)
      ]
    ),
  ]

  static func getText() -> String {
    guard UIPasteboard.general.hasStrings else {
      return "The clipboard has no text content."
    }
    guard let text = UIPasteboard.general.string, !text.isEmpty else {
      return "The clipboard has no text content."
    }
    return text
  }

  static func setText(arguments: [String: AgentToolArgumentValue]) -> String {
    let text =
      arguments["text"]?.stringValue ?? arguments["content"]?.stringValue
      ?? arguments["value"]?.stringValue ?? ""
    guard !text.isEmpty else { return "Error: text is required." }
    UIPasteboard.general.string = text
    return "Copied \(text.count) characters to the clipboard."
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
          "Search the web for current or external information.",
        parameters: [
          ToolParameterDef(
            name: "query", type: "string",
            description: "Focused search query without unrelated chat history.",
            required: true)
        ])
    ]
    if settings.webSearchFetchingEnabled {
      definitions.append(
        ToolDefinition(
          name: fetchName,
          description:
            "Fetch one HTTP or HTTPS URL and return cleaned page text.",
          parameters: [
            ToolParameterDef(
              name: "url", type: "string",
              description: "Full HTTP or HTTPS URL.",
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
    let provider = settings.toolSettings.webSearchProvider
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
}

@MainActor
enum TodoTool {
  static let listName = "todo_list"
  static let addName = "todo_add"
  static let doneName = "todo_done"

  static let definitions: [ToolDefinition] = [
    ToolDefinition(
      name: listName,
      description: "List todos with short IDs and status.",
      parameters: []
    ),
    ToolDefinition(
      name: addName,
      description: "Add a pending todo.",
      parameters: [
        ToolParameterDef(
          name: "title", type: "string",
          description: "Todo title.", required: true)
      ]
    ),
    ToolDefinition(
      name: doneName,
      description: "Mark a todo done by short ID or title substring.",
      parameters: [
        ToolParameterDef(
          name: "title_or_id", type: "string",
          description: "Short ID or title substring.",
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
enum CalculatorTool {
  static let name = "calculator"

  static let definitions: [ToolDefinition] = [
    ToolDefinition(
      name: name,
      description:
        "Evaluate a numeric math expression with parentheses using +, -, *, /, and unary signs.",
      parameters: [
        ToolParameterDef(
          name: "expression", type: "string",
          description: "Math expression to evaluate, such as (2 + 3) * 4 / 5.",
          required: true)
      ])
  ]

  static func run(arguments: [String: AgentToolArgumentValue]) -> String {
    let expression =
      arguments["expression"]?.stringValue ?? arguments["expr"]?.stringValue
      ?? arguments["input"]?.stringValue ?? ""
    let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "Error: expression is required." }

    do {
      var parser = CalculatorParser(trimmed)
      let result = try parser.parse()
      return format(result)
    } catch {
      return "Error: invalid expression: \(error.localizedDescription)"
    }
  }

  private static func format(_ value: Double) -> String {
    guard value.isFinite else { return "Error: calculation result is not finite." }
    if value.rounded() == value && value <= Double(Int64.max) && value >= Double(Int64.min) {
      return String(Int64(value))
    }
    return String(format: "%.15g", value)
  }
}

private struct CalculatorParser {
  private let text: String
  private var index: String.Index

  init(_ text: String) {
    self.text = text
    self.index = text.startIndex
  }

  mutating func parse() throws -> Double {
    let value = try parseExpression()
    skipWhitespace()
    guard index == text.endIndex else {
      throw CalculatorParserError("unexpected '\(text[index])'")
    }
    guard value.isFinite else {
      throw CalculatorParserError("result is not finite")
    }
    return value
  }

  private mutating func parseExpression() throws -> Double {
    var value = try parseTerm()
    while true {
      if consume("+") {
        value += try parseTerm()
      } else if consume("-") {
        value -= try parseTerm()
      } else {
        return value
      }
    }
  }

  private mutating func parseTerm() throws -> Double {
    var value = try parseFactor()
    while true {
      if consume("*") {
        value *= try parseFactor()
      } else if consume("/") {
        let divisor = try parseFactor()
        guard divisor != 0 else { throw CalculatorParserError("division by zero") }
        value /= divisor
      } else {
        return value
      }
    }
  }

  private mutating func parseFactor() throws -> Double {
    skipWhitespace()
    if consume("+") {
      return try parseFactor()
    }
    if consume("-") {
      return -(try parseFactor())
    }
    if consume("(") {
      let value = try parseExpression()
      guard consume(")") else { throw CalculatorParserError("expected ')'") }
      return value
    }
    return try parseNumber()
  }

  private mutating func parseNumber() throws -> Double {
    skipWhitespace()
    let start = index
    var hasDigit = false

    while let char = current, char.isNumber {
      hasDigit = true
      advance()
    }
    if consumeRaw(".") {
      while let char = current, char.isNumber {
        hasDigit = true
        advance()
      }
    }
    guard hasDigit else { throw CalculatorParserError("expected number") }

    if let char = current, char == "e" || char == "E" {
      let exponentStart = index
      advance()
      _ = consumeRaw("+") || consumeRaw("-")
      var hasExponentDigit = false
      while let char = current, char.isNumber {
        hasExponentDigit = true
        advance()
      }
      guard hasExponentDigit else {
        index = exponentStart
        throw CalculatorParserError("expected exponent digits")
      }
    }

    let raw = String(text[start..<index])
    guard let value = Double(raw), value.isFinite else {
      throw CalculatorParserError("invalid number '\(raw)'")
    }
    return value
  }

  private var current: Character? {
    index < text.endIndex ? text[index] : nil
  }

  private mutating func skipWhitespace() {
    while let char = current, char.isWhitespace {
      advance()
    }
  }

  private mutating func consume(_ char: Character) -> Bool {
    skipWhitespace()
    return consumeRaw(char)
  }

  private mutating func consumeRaw(_ char: Character) -> Bool {
    guard current == char else { return false }
    advance()
    return true
  }

  private mutating func advance() {
    index = text.index(after: index)
  }
}

private struct CalculatorParserError: LocalizedError {
  let message: String

  init(_ message: String) {
    self.message = message
  }

  var errorDescription: String? { message }
}

@MainActor
enum TextToSpeechTool {
  static let name = "text-to-speech"

  static let definitions: [ToolDefinition] = [
    ToolDefinition(
      name: name,
      description:
        "Speak text aloud on this device.",
      parameters: [
        ToolParameterDef(
          name: "text", type: "string",
          description: "Text to speak.",
          required: true),
        ToolParameterDef(
          name: "language", type: "string",
          description: "BCP-47 language, such as en-US or es-ES.",
          required: false),
        ToolParameterDef(
          name: "voice", type: "string",
          description: "Voice identifier.",
          required: false),
        ToolParameterDef(
          name: "rate", type: "number",
          description: "Speaking rate from 0.0 to 1.0.",
          required: false),
        ToolParameterDef(
          name: "pitch", type: "number",
          description: "Pitch multiplier from 0.5 to 2.0.",
          required: false),
        ToolParameterDef(
          name: "interrupt", type: "boolean",
          description: "Stop current speech first. Default: true.",
          required: false),
      ])
  ]

  static func speak(
    arguments: [String: AgentToolArgumentValue],
    settings: NativeToolSettings,
    skipTechnicalContent: Bool = true,
    openAIEndpoints: [OpenAIEndpoint] = [],
    role: VoiceRole = .assistant,
    title: String? = nil,
    messageID: UUID? = nil
  ) -> String {
    let text = TTSSpeechTextSanitizer.sanitized(
      arguments["text"]?.stringValue ?? "",
      skipTechnicalContent: skipTechnicalContent)
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
      skipTechnicalContent: skipTechnicalContent,
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
        "Return current date/time using configured options.",
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
        "Return GPS or manually configured location.",
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
        "Return current weather and 7-day forecast. Use location when the user asks about a specific city or place; omit it for the configured/current location.",
      parameters: [
        ToolParameterDef(
          name: "location",
          type: "string",
          description:
            "City, place, or latitude/longitude requested by the user, such as Madrid or 40.4168,-3.7038. Omit for the configured/current location.",
          required: false)
      ]
    )
  ]

  static func run(
    arguments: [String: AgentToolArgumentValue],
    settings: NativeToolSettings,
    locationService: @MainActor () -> LocationService
  ) async -> String {
    let requestedLocation =
      arguments["location"]?.stringValue ?? arguments["city"]?.stringValue
      ?? arguments["place"]?.stringValue ?? arguments["query"]?.stringValue
      ?? arguments["q"]?.stringValue
    if let report = await WeatherService.report(
      requestedLocation: requestedLocation,
      settings: settings,
      locationService: locationService)
    {
      return report
    }
    return "Weather unavailable."
  }
}
