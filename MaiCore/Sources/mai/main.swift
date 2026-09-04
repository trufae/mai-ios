import Darwin
import Foundation
import MaiCore
import MaiOpenAI

private struct CLIOptions {
  var configPath: String?
  var agentOverride: String?
  var providerOverride: ProviderID?
  var modelOverride: String?
  var baseURLOverride: URL?
  var apiKeyOverride: String?
  var systemOverride: String?
  var stream = true
  var imagePaths: [String] = []
  var initialPrompt: String?
  var printConfig = false

  init(arguments: [String], environment: [String: String]) throws {
    configPath = environment["MAI_CONFIG"]
    var positional: [String] = []
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--config":
        configPath = try Self.value(after: argument, in: arguments, index: &index)
      case "--agent":
        agentOverride = try Self.value(after: argument, in: arguments, index: &index)
      case "--provider":
        providerOverride = ProviderID(try Self.value(after: argument, in: arguments, index: &index))
      case "--model":
        modelOverride = try Self.value(after: argument, in: arguments, index: &index)
      case "--base-url":
        let value = try Self.value(after: argument, in: arguments, index: &index)
        guard let url = URL(string: value) else { throw CLIError.invalidURL(value) }
        baseURLOverride = url
      case "--api-key":
        apiKeyOverride = try Self.value(after: argument, in: arguments, index: &index)
      case "--system":
        systemOverride = try Self.value(after: argument, in: arguments, index: &index)
      case "--image":
        imagePaths.append(try Self.value(after: argument, in: arguments, index: &index))
      case "--no-stream":
        stream = false
      case "--print-config":
        printConfig = true
      default:
        guard !argument.hasPrefix("-") else { throw CLIError.unknownOption(argument) }
        positional.append(argument)
      }
      index += 1
    }
    if !positional.isEmpty { initialPrompt = positional.joined(separator: " ") }
  }

  private static func value(
    after option: String,
    in arguments: [String],
    index: inout Int
  ) throws -> String {
    index += 1
    guard index < arguments.count else { throw CLIError.missingValue(option) }
    return arguments[index]
  }
}

private enum CLIError: LocalizedError {
  case invalidURL(String)
  case missingValue(String)
  case unknownOption(String)
  case configNotFound(String)
  case noProvider
  case invalidImage(String)

  var errorDescription: String? {
    switch self {
    case .invalidURL(let value): "Invalid URL: \(value)"
    case .missingValue(let option): "Missing value after \(option)."
    case .unknownOption(let option): "Unknown option: \(option)"
    case .configNotFound(let path): "Configuration file not found: \(path)"
    case .noProvider: "No provider is configured."
    case .invalidImage(let path): "Unable to load image: \(path)"
    }
  }
}

private struct SessionProfile {
  var agentID: String
  var provider: ProviderID
  var model: String
  var instructions: String
  var toolNames: Set<String>
  var subagentNames: Set<String>
  var stream: Bool
  var limits: AgentRunLimits
  var toolChoice: ToolChoice
  var responseFormat: ResponseFormat
  var options: GenerationOptions
  var toolCallingStrategy: ToolCallingStrategy

  init(definition: AgentDefinition) {
    agentID = definition.id
    provider = definition.provider
    model = definition.model
    instructions = definition.instructions
    toolNames = definition.toolNames
    subagentNames = definition.subagentNames
    stream = definition.stream
    limits = definition.limits
    toolChoice = definition.toolChoice
    responseFormat = definition.responseFormat
    options = definition.options
    toolCallingStrategy = definition.toolCallingStrategy
  }

  init(provider: ProviderID, model: String, instructions: String, stream: Bool) {
    agentID = "main"
    self.provider = provider
    self.model = model
    self.instructions = instructions
    toolNames = ["echo", "current_time", "read_text_file"]
    subagentNames = []
    self.stream = stream
    limits = .init()
    toolChoice = .automatic
    responseFormat = .text
    options = .init()
    toolCallingStrategy = .automatic
  }
}

private struct REPLSession {
  var profile: SessionProfile
  var history: AgentTranscript
  var pendingContent: [ContentPart]

  init(profile: SessionProfile, pendingContent: [ContentPart] = []) {
    self.profile = profile
    history = AgentTranscript(messages: Self.initialHistory(for: profile))
    self.pendingContent = pendingContent
  }

  mutating func reset(profile: SessionProfile? = nil) {
    if let profile { self.profile = profile }
    history.replaceAll(with: Self.initialHistory(for: self.profile))
    pendingContent.removeAll()
  }

  private static func initialHistory(for profile: SessionProfile) -> [AgentMessage] {
    let instructions = profile.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    return instructions.isEmpty ? [] : [.system(instructions)]
  }
}

private actor TerminalWriter {
  private var wroteRootDelta = false
  private var rootLineOpen = false

  func resetResponse() {
    wroteRootDelta = false
    rootLineOpen = false
  }

  func consume(_ event: AgentEvent) {
    switch event {
    case .provider(let context, .textDelta(let text)) where context.depth == 0:
      write(text)
      wroteRootDelta = true
      rootLineOpen = true
    case .toolStarted(let context, let call) where context.depth == 0:
      closeRootLine()
      status("→ tool \(call.name) \(call.arguments.compactJSONString)")
    case .toolFinished(let context, let result) where context.depth == 0:
      status("← tool \(result.isError ? "error" : "done")")
    case .childStarted(_, let child):
      closeRootLine()
      status("↳ child \(child.agentID) [\(child.runID.uuidString.prefix(8))]")
    case .childFinished(_, let child):
      status("↲ child \(child.agentID): \(child.response.text.prefix(100))")
    case .finished(let context, let result) where context.depth == 0:
      if !wroteRootDelta { write(result.response.text) }
      closeRootLine(force: true)
    default:
      break
    }
  }

  func recoverAfterError(_ message: String) {
    closeRootLine()
    status("error: \(message)")
  }

  func prompt(_ value: String) { write(value) }

  func line(_ value: String = "", to handle: FileHandle = .standardOutput) {
    handle.write(Data((value + "\n").utf8))
  }

  private func write(_ value: String) {
    FileHandle.standardOutput.write(Data(value.utf8))
  }

  private func status(_ value: String) {
    FileHandle.standardError.write(Data((value + "\n").utf8))
  }

  private func closeRootLine(force: Bool = false) {
    if rootLineOpen || force { FileHandle.standardOutput.write(Data("\n".utf8)) }
    rootLineOpen = false
  }
}

private actor TerminalApprovalHandler: ApprovalHandler {
  private let configuration: ConfiguredApprovals

  init(configuration: ConfiguredApprovals) {
    self.configuration = configuration
  }

  func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
    let mode =
      request.tool.annotations.approval == .dangerous
      ? configuration.dangerous : configuration.confirm
    switch mode {
    case .allow:
      return .approve(arguments: request.call.arguments)
    case .deny:
      return .deny(reason: "Denied by configuration.")
    case .ask:
      guard isatty(STDIN_FILENO) != 0 else {
        return .deny(reason: "Interactive approval requires a terminal.")
      }
      FileHandle.standardError.write(
        Data(
          "Approve \(request.tool.annotations.approval.rawValue) tool '\(request.tool.name)'?\nArguments: \(request.call.arguments.compactJSONString)\n[y]es/[n]o/[e]dit/[c]ancel run: "
            .utf8))
      guard let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      else { return .deny(reason: "No approval response.") }
      switch answer {
      case "y", "yes":
        return .approve(arguments: request.call.arguments)
      case "e", "edit":
        FileHandle.standardError.write(Data("Replacement JSON arguments: ".utf8))
        guard let raw = readLine(), let data = raw.data(using: .utf8),
          let value = try? JSONDecoder().decode(JSONValue.self, from: data),
          value.objectValue != nil
        else { return .deny(reason: "Edited arguments were not a JSON object.") }
        return .approve(arguments: value)
      case "c", "cancel":
        return .cancelRun
      default:
        return .deny(reason: "Denied by user.")
      }
    }
  }
}

@main
private struct MaiCLI {
  static func main() async {
    if CommandLine.arguments.dropFirst().contains(where: { $0 == "--help" || $0 == "-h" }) {
      printUsage()
      return
    }

    do {
      let environment = ProcessInfo.processInfo.environment
      let options = try CLIOptions(
        arguments: Array(CommandLine.arguments.dropFirst()),
        environment: environment)
      if options.printConfig {
        FileHandle.standardOutput.write(try sampleConfiguration().encoded())
        FileHandle.standardOutput.write(Data("\n".utf8))
        return
      }

      let loaded = try loadConfiguration(options: options)
      let configuration = loaded?.configuration
      let approvalHandler = TerminalApprovalHandler(
        configuration: configuration?.approvals ?? .init())
      let runtime = AgentRuntime(approvalHandler: approvalHandler)
      let plugins = PluginRegistry()
      try await plugins.install(MaiCoreBuiltinsPlugin(), origin: "built-in")
      try await plugins.install(MaiOpenAIPlugin(), origin: "built-in")
      try await registerHostTools(in: runtime)
      let catalogs = try await configureRuntime(
        runtime,
        plugins: plugins,
        configuration: configuration,
        options: options,
        environment: environment)
      let profile = try selectedProfile(
        configuration: configuration,
        options: options,
        environment: environment)
      var session = REPLSession(
        profile: profile,
        pendingContent: try options.imagePaths.map(imageContent))
      let terminal = TerminalWriter()

      if let path = loaded?.path {
        await terminal.line("Loaded \(path)", to: .standardError)
      }
      if let prompt = options.initialPrompt {
        let succeeded = await submit(
          prompt,
          session: &session,
          runtime: runtime,
          terminal: terminal)
        if !succeeded { Darwin.exit(1) }
        return
      }
      await runREPL(
        session: &session,
        runtime: runtime,
        configuration: configuration,
        catalogs: catalogs,
        terminal: terminal)
    } catch {
      FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
      Darwin.exit(2)
    }
  }

  private static func configureRuntime(
    _ runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: MaiConfiguration?,
    options: CLIOptions,
    environment: [String: String]
  ) async throws -> [MCPServerCatalog] {
    if let configuration {
      for provider in configuration.providers {
        try await runtime.register(
          plugins.makeProvider(from: provider, environment: environment))
      }
      for agent in configuration.agents {
        try await runtime.register(agent: agent)
      }
      var catalogs: [MCPServerCatalog] = []
      for server in configuration.mcpServers where server.enabled {
        let client = MCPClient(configuration: try server.resolved(environment: environment))
        catalogs.append(try await runtime.register(mcp: client))
      }
      let knownTools = Set(await runtime.availableTools().map(\.name))
      for agent in configuration.agents {
        for name in agent.toolNames where !knownTools.contains(name) {
          throw MaiConfigurationError.unknownTool(agent: agent.id, tool: name)
        }
      }
      return catalogs
    }

    try await runtime.register(
      plugins.makeProvider(
        from: ConfiguredProvider(id: "hello", kind: .hello),
        environment: environment))
    let rawBaseURL =
      options.baseURLOverride?.absoluteString
      ?? environment["MAI_BASE_URL"] ?? environment["OPENAI_BASE_URL"]
      ?? "https://api.openai.com/v1"
    guard let baseURL = URL(string: rawBaseURL) else { throw CLIError.invalidURL(rawBaseURL) }
    try await runtime.register(
      plugins.makeProvider(
        from: ConfiguredProvider(
          id: ProviderID.openAI.rawValue,
          kind: .openAICompatible,
          baseURL: baseURL,
          apiKey: options.apiKeyOverride ?? environment["MAI_API_KEY"]
            ?? environment["OPENAI_API_KEY"]),
        environment: environment))
    return []
  }

  private static func registerHostTools(in runtime: AgentRuntime) async throws {
    try await runtime.register(
      tool: ClosureTool(
        definition: ToolDefinition(
          name: "echo",
          description: "Return the supplied text.",
          inputSchema: objectSchema(
            properties: ["text": .object(["type": .string("string")])],
            required: ["text"]),
          annotations: ToolAnnotations(
            readOnly: true,
            idempotent: true,
            openWorld: false,
            approval: .automatic))
      ) { arguments, _ in
        ToolOutput(text: arguments.objectValue?["text"]?.stringValue ?? "")
      })
    try await runtime.register(
      tool: ClosureTool(
        definition: ToolDefinition(
          name: "current_time",
          description: "Return the current ISO-8601 date and time.",
          inputSchema: objectSchema(properties: [:], required: []),
          annotations: ToolAnnotations(
            readOnly: true,
            idempotent: false,
            openWorld: false,
            approval: .automatic))
      ) { _, _ in
        ToolOutput(text: ISO8601DateFormatter().string(from: Date()))
      })
    try await runtime.register(
      tool: ClosureTool(
        definition: ToolDefinition(
          name: "read_text_file",
          description: "Read a UTF-8 text file from the CLI host.",
          inputSchema: objectSchema(
            properties: ["path": .object(["type": .string("string")])],
            required: ["path"]),
          annotations: ToolAnnotations(
            readOnly: true,
            idempotent: true,
            openWorld: false,
            approval: .confirm))
      ) { arguments, _ in
        guard let path = arguments.objectValue?["path"]?.stringValue else {
          return ToolOutput(text: "Missing path.", isError: true)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
        guard data.count <= 1_048_576 else {
          return ToolOutput(text: "File exceeds the 1 MiB CLI tool limit.", isError: true)
        }
        guard let text = String(data: data, encoding: .utf8) else {
          return ToolOutput(text: "File is not valid UTF-8.", isError: true)
        }
        return ToolOutput(content: [
          .file(
            FileContent(
              name: URL(fileURLWithPath: path).lastPathComponent, mimeType: "text/plain", text: text
            ))
        ])
      })
  }

  private static func selectedProfile(
    configuration: MaiConfiguration?,
    options: CLIOptions,
    environment: [String: String]
  ) throws -> SessionProfile {
    if let configuration, !configuration.agents.isEmpty {
      let selectedID =
        options.agentOverride ?? configuration.defaultAgent
        ?? configuration.agents.first?.id
      guard let definition = configuration.agents.first(where: { $0.id == selectedID }) else {
        throw MaiConfigurationError.unknownAgent(selectedID ?? "")
      }
      var profile = SessionProfile(definition: definition)
      if let provider = options.providerOverride { profile.provider = provider }
      if let model = options.modelOverride { profile.model = model }
      if let system = options.systemOverride { profile.instructions = system }
      profile.stream = options.stream && profile.stream
      return profile
    }
    return SessionProfile(
      provider: options.providerOverride
        ?? ProviderID(environment["MAI_PROVIDER"] ?? "hello"),
      model: options.modelOverride ?? environment["MAI_MODEL"]
        ?? environment["OPENAI_MODEL"] ?? "",
      instructions: options.systemOverride ?? "You are a helpful, concise assistant.",
      stream: options.stream)
  }

  private static func runREPL(
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: MaiConfiguration?,
    catalogs: [MCPServerCatalog],
    terminal: TerminalWriter
  ) async {
    await terminal.line("mai — MaiCore agent REPL")
    await terminal.line("Type /help for commands. Agent: \(session.profile.agentID)")

    while true {
      await terminal.prompt("mai[\(session.profile.agentID)]> ")
      guard let input = readLine(strippingNewline: true) else {
        await terminal.line()
        return
      }
      let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { continue }
      if text.hasPrefix("/") {
        if await handleCommand(
          text,
          session: &session,
          runtime: runtime,
          configuration: configuration,
          catalogs: catalogs,
          terminal: terminal)
        {
          return
        }
        continue
      }
      _ = await submit(text, session: &session, runtime: runtime, terminal: terminal)
    }
  }

  private static func submit(
    _ text: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    terminal: TerminalWriter
  ) async -> Bool {
    var content: [ContentPart] = [.text(text)]
    content.append(contentsOf: session.pendingContent)
    session.pendingContent.removeAll()
    session.history.append(AgentMessage(role: .user, content: content))
    await terminal.resetResponse()
    do {
      let profile = session.profile
      let result = try await runtime.run(
        AgentRequest(
          agentID: profile.agentID,
          provider: profile.provider,
          model: profile.model,
          messages: session.history.messages,
          toolNames: profile.toolNames,
          subagentNames: profile.subagentNames,
          toolChoice: profile.toolChoice,
          responseFormat: profile.responseFormat,
          options: profile.options,
          limits: profile.limits,
          stream: profile.stream,
          toolCallingStrategy: profile.toolCallingStrategy)
      ) { event in
        await terminal.consume(event)
      }
      session.history.replaceAll(with: result.transcript)
      return true
    } catch {
      await terminal.recoverAfterError(error.localizedDescription)
      return false
    }
  }

  private static func handleCommand(
    _ input: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: MaiConfiguration?,
    catalogs: [MCPServerCatalog],
    terminal: TerminalWriter
  ) async -> Bool {
    let parts = input.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(String.init)
    let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""

    switch parts[0] {
    case "/exit", "/quit":
      return true
    case "/help":
      await terminal.line(replHelp)
    case "/providers":
      for provider in await runtime.availableProviders() {
        let selected = provider.id == session.profile.provider ? "*" : " "
        await terminal.line("\(selected) \(provider.id) — \(provider.displayName)")
      }
    case "/models":
      let providerID = argument.isEmpty ? session.profile.provider : ProviderID(argument)
      do {
        let models = try await runtime.availableModels(provider: providerID)
        if models.isEmpty {
          await terminal.line("Provider '\(providerID)' returned no models.")
        }
        for model in models {
          let selected =
            providerID == session.profile.provider && model.id == session.profile.model
            ? "*" : " "
          let owner = model.ownedBy.map { " — \($0)" } ?? ""
          let label =
            model.displayName == model.id ? model.id : "\(model.id) (\(model.displayName))"
          await terminal.line("\(selected) \(label)\(owner)")
        }
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
    case "/chat":
      await handleChatCommand(argument, session: &session, terminal: terminal)
    case "/provider":
      guard !argument.isEmpty else {
        await terminal.line("Current provider: \(session.profile.provider)")
        return false
      }
      let id = ProviderID(argument)
      guard await runtime.availableProviders().contains(where: { $0.id == id }) else {
        await terminal.line("Unknown provider '\(argument)'. Use /providers.")
        return false
      }
      session.profile.provider = id
      await terminal.line("Provider: \(id)")
    case "/model":
      if argument.isEmpty {
        await terminal.line(
          session.profile.model.isEmpty ? "No model selected." : "Model: \(session.profile.model)")
      } else {
        session.profile.model = argument
        await terminal.line("Model: \(argument)")
      }
    case "/agents":
      let agents = await runtime.availableAgents()
      if agents.isEmpty { await terminal.line("No configured agents.") }
      for agent in agents {
        let selected = agent.id == session.profile.agentID ? "*" : " "
        await terminal.line("\(selected) \(agent.id) — \(agent.displayName)")
      }
    case "/agent":
      guard !argument.isEmpty else {
        await terminal.line("Current agent: \(session.profile.agentID)")
        return false
      }
      guard let definition = configuration?.agents.first(where: { $0.id == argument }) else {
        await terminal.line("Unknown agent '\(argument)'. Use /agents.")
        return false
      }
      session.reset(profile: SessionProfile(definition: definition))
      await terminal.line("Agent: \(argument). Conversation cleared.")
    case "/tools":
      let allowed = session.profile.toolNames.union(
        session.profile.subagentNames.isEmpty ? [] : [AgentRuntime.subagentToolName])
      for tool in await runtime.availableTools()
      where allowed.isEmpty || allowed.contains(tool.name) {
        await terminal.line(
          "\(tool.name) [\(tool.annotations.approval.rawValue)] — \(tool.description)")
      }
      if !session.profile.subagentNames.isEmpty {
        await terminal.line(
          "\(AgentRuntime.subagentToolName) [confirm] — child agents: \(session.profile.subagentNames.sorted().joined(separator: ", "))"
        )
      }
    case "/mcps":
      if catalogs.isEmpty { await terminal.line("No connected MCP servers.") }
      for catalog in catalogs {
        await terminal.line(
          "\(catalog.serverID) — \(catalog.tools.count) tools, \(catalog.resources.count) resources, MCP \(catalog.protocolVersion)"
        )
      }
    case "/image":
      let imageArguments = argument.split(
        maxSplits: 1, whereSeparator: \Character.isWhitespace
      ).map(String.init)
      guard imageArguments.count == 2,
        let mode = ImageAttachmentMode(rawValue: imageArguments[0].lowercased())
      else {
        await terminal.line("Usage: /image <tiny|small|medium|big|full|ocr> PATH")
        return false
      }
      do {
        let path = imageArguments[1].trimmingCharacters(in: .whitespacesAndNewlines)
        session.pendingContent.append(try await imageContent(path: path, mode: mode))
        if mode == .ocr {
          let markdownName = (path as NSString).lastPathComponent
          await terminal.line(
            "OCR text queued as \((markdownName as NSString).deletingPathExtension).md")
        } else {
          await terminal.line("Image queued at \(mode.rawValue) size: \(path)")
        }
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
    case "/clear":
      session.reset()
      await terminal.line("Conversation cleared.")
    default:
      await terminal.line("Unknown command. Type /help.")
    }
    return false
  }

  private static func handleChatCommand(
    _ argument: String,
    session: inout REPLSession,
    terminal: TerminalWriter
  ) async {
    let parts = argument.split(maxSplits: 2, whereSeparator: \Character.isWhitespace).map(
      String.init)
    guard let action = parts.first?.lowercased(), !action.isEmpty else {
      await terminal.line(chatHelp)
      return
    }

    switch action {
    case "list":
      await terminal.line(conversationLog(session: session, full: false))
    case "log":
      await terminal.line(conversationLog(session: session, full: true))
    case "edit":
      guard parts.count == 3, let index = chatIndex(parts[1], count: session.history.count) else {
        await terminal.line("Usage: /chat edit N TEXT")
        return
      }
      do {
        try session.history.editMessage(at: index, text: parts[2])
        await terminal.line("Edited message \(index + 1).")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
    case "remove", "delete", "rm":
      guard parts.count >= 2, let index = chatIndex(parts[1], count: session.history.count) else {
        await terminal.line("Usage: /chat remove N")
        return
      }
      await removeChatMessage(at: index, session: &session, terminal: terminal)
    case "undo":
      let index: Int?
      if parts.count >= 2 {
        index = chatIndex(parts[1], count: session.history.count)
      } else {
        index = session.history.messages.lastIndex(where: { $0.role != .system })
      }
      guard let index else {
        await terminal.line(
          session.history.isEmpty ? "No messages to undo." : "No conversation messages to undo.")
        return
      }
      await removeChatMessage(at: index, session: &session, terminal: terminal)
    case "trim":
      guard parts.count >= 2, let index = chatIndex(parts[1], count: session.history.count) else {
        await terminal.line("Usage: /chat trim N")
        return
      }
      do {
        let removed = try session.history.trim(through: index)
        if removed.isEmpty {
          await terminal.line("Nothing follows message \(index + 1).")
        } else {
          await terminal.line(
            "Trimmed \(removed.count) message\(removed.count == 1 ? "" : "s"); kept through message \(session.history.count)."
          )
        }
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
    case "clear":
      session.reset()
      await terminal.line("Conversation cleared.")
    case "help":
      await terminal.line(chatHelp)
    default:
      await terminal.line("Unknown /chat action '\(action)'.\n\n\(chatHelp)")
    }
  }

  private static func removeChatMessage(
    at index: Int,
    session: inout REPLSession,
    terminal: TerminalWriter
  ) async {
    do {
      let removed = try session.history.removeMessage(at: index)
      let suffix = removed.count == 1 ? "" : " (including linked tool messages)"
      await terminal.line(
        "Removed \(removed.count) message\(removed.count == 1 ? "" : "s")\(suffix).")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  private static func chatIndex(_ raw: String, count: Int) -> Int? {
    guard let value = Int(raw), value > 0, value <= count else { return nil }
    return value - 1
  }

  private static func conversationLog(session: REPLSession, full: Bool) -> String {
    guard !session.history.isEmpty else { return "No conversation messages yet." }
    var lines = [full ? "# Full conversation log" : "Conversation log:"]
    if !full { lines.append("-----------------") }
    for (index, message) in session.history.messages.enumerated() {
      let role = message.role.rawValue.capitalized
      if full {
        lines.append("\n## [\(index + 1)] \(role) (id: \(message.id))")
        lines.append(message.content.map(renderFullContent).joined(separator: "\n"))
        lines.append("--------------------")
      } else {
        lines.append("[\(index + 1)] \(role): \(messagePreview(message))")
      }
    }
    lines.append("\nTotal messages: \(session.history.count)")
    if !session.pendingContent.isEmpty {
      lines.append(
        "Pending for next message: \(session.pendingContent.map(renderCompactContent).joined(separator: ", "))"
      )
    }
    return lines.joined(separator: "\n")
  }

  private static func messagePreview(_ message: AgentMessage) -> String {
    let rendered = message.content.map(renderCompactContent).joined(separator: " ")
      .replacingOccurrences(of: "\n", with: " ")
    guard rendered.count > 120 else { return rendered }
    return String(rendered.prefix(117)) + "..."
  }

  private static func renderCompactContent(_ part: ContentPart) -> String {
    switch part {
    case .text(let text):
      text
    case .image(let image):
      "[image \(image.name ?? image.mimeType)]"
    case .file(let file):
      "[file \(file.name)]"
    case .audio(let audio):
      "[audio \(audio.name ?? audio.mimeType)]"
    case .resource(let resource):
      "[resource \(resource.name ?? resource.uri)]"
    case .reasoning(let reasoning):
      "[reasoning] \(reasoning)"
    case .toolCall(let call):
      "[tool call \(call.name) \(call.arguments.compactJSONString)]"
    case .toolResult(let result):
      "[tool result \(result.callID)\(result.isError ? " error" : "")] \(result.text)"
    }
  }

  private static func renderFullContent(_ part: ContentPart) -> String {
    switch part {
    case .text(let text):
      return text
    case .image(let image):
      return
        "[image name=\(image.name ?? "-") mime=\(image.mimeType) source=\(binarySourceSummary(image.source))]"
    case .file(let file):
      return
        "[file name=\(file.name) mime=\(file.mimeType)\(file.source.map { " source=\(binarySourceSummary($0))" } ?? "")]\(file.text.map { "\n\($0)" } ?? "")"
    case .audio(let audio):
      return
        "[audio name=\(audio.name ?? "-") mime=\(audio.mimeType) source=\(binarySourceSummary(audio.source))]"
    case .resource(let resource):
      return
        "[resource name=\(resource.name ?? "-") uri=\(resource.uri) mime=\(resource.mimeType ?? "-")]\(resource.text.map { "\n\($0)" } ?? "")"
    case .reasoning(let reasoning):
      return "[reasoning]\n\(reasoning)"
    case .toolCall(let call):
      return "[tool call name=\(call.name) id=\(call.id)]\n\(call.arguments.compactJSONString)"
    case .toolResult(let result):
      var value = "[tool result call=\(result.callID) status=\(result.isError ? "error" : "ok")]"
      if !result.content.isEmpty {
        value += "\n" + result.content.map(renderFullContent).joined(separator: "\n")
      }
      if let structured = result.structuredContent {
        value += "\n[structured content]\n\(structured.compactJSONString)"
      }
      return value
    }
  }

  private static func binarySourceSummary(_ source: BinarySource) -> String {
    switch source {
    case .data(let data): "inline:\(data.count)-bytes"
    case .url(let url): url.absoluteString
    }
  }

  private static func loadConfiguration(
    options: CLIOptions
  ) throws -> (configuration: MaiConfiguration, path: String)? {
    if let explicit = options.configPath {
      let expanded = NSString(string: explicit).expandingTildeInPath
      guard FileManager.default.fileExists(atPath: expanded) else {
        throw CLIError.configNotFound(expanded)
      }
      return (try MaiConfiguration.load(from: URL(fileURLWithPath: expanded)), expanded)
    }
    let candidates = [
      FileManager.default.currentDirectoryPath + "/mai.json",
      NSString(string: "~/.config/mai/config.json").expandingTildeInPath,
    ]
    for path in candidates where FileManager.default.fileExists(atPath: path) {
      return (try MaiConfiguration.load(from: URL(fileURLWithPath: path)), path)
    }
    return nil
  }

  private static func imageContent(path: String) throws -> ContentPart {
    let loaded = try loadImage(path: path)
    return .image(
      ImageContent(
        source: .data(loaded.data),
        mimeType: loaded.mimeType,
        name: loaded.url.lastPathComponent))
  }

  private static func imageContent(
    path: String,
    mode: ImageAttachmentMode
  ) async throws -> ContentPart {
    let loaded = try loadImage(path: path)
    return try await ImageAttachmentImporter.content(
      data: loaded.data,
      mimeType: loaded.mimeType,
      filename: loaded.url.lastPathComponent,
      mode: mode,
      ocrProvider: mode == .ocr ? VisionOCRProvider() : nil)
  }

  private static func loadImage(path: String) throws -> (data: Data, url: URL, mimeType: String) {
    let expanded = NSString(string: path).expandingTildeInPath
    let url = URL(fileURLWithPath: expanded)
    guard let data = try? Data(contentsOf: url), !data.isEmpty else {
      throw CLIError.invalidImage(path)
    }
    let mimeType: String
    switch url.pathExtension.lowercased() {
    case "png": mimeType = "image/png"
    case "gif": mimeType = "image/gif"
    case "webp": mimeType = "image/webp"
    case "heic", "heif": mimeType = "image/heic"
    default: mimeType = "image/jpeg"
    }
    return (data, url, mimeType)
  }

  private static func objectSchema(
    properties: [String: JSONValue],
    required: [String]
  ) -> JSONValue {
    .object([
      "type": .string("object"),
      "properties": .object(properties),
      "required": .array(required.map(JSONValue.string)),
      "additionalProperties": .bool(false),
    ])
  }

  private static func sampleConfiguration() -> MaiConfiguration {
    MaiConfiguration(
      defaultAgent: "hello",
      providers: [
        ConfiguredProvider(id: "hello", kind: .hello),
        ConfiguredProvider(
          id: "openai",
          kind: .openAICompatible,
          baseURL: URL(string: "https://api.openai.com/v1"),
          apiKeyEnvironment: "OPENAI_API_KEY"),
      ],
      mcpServers: [
        ConfiguredMCPServer(
          id: "remote",
          enabled: false,
          displayName: "Example MCP",
          url: URL(string: "https://your-mcp.example/mcp")!,
          bearerTokenEnvironment: "MCP_API_KEY",
          toolNamePrefix: "remote",
          defaultApproval: .confirm)
      ],
      agents: [
        AgentDefinition(
          id: "hello",
          instructions: "Exercise the offline MaiCore provider.",
          provider: "hello",
          model: ""),
        AgentDefinition(
          id: "main",
          instructions: "You are a helpful assistant. Use tools when needed.",
          provider: "openai",
          model: "your-model",
          toolNames: ["current_time", "echo", "read_text_file"],
          subagentNames: ["researcher"]),
        AgentDefinition(
          id: "researcher",
          instructions: "Investigate the delegated task and return a concise result.",
          provider: "openai",
          model: "your-model",
          toolNames: ["current_time"]),
      ],
      approvals: ConfiguredApprovals(confirm: .ask, dangerous: .ask))
  }

  private static let replHelp = """
    /providers          List registered providers
    /models [PROVIDER]  List models from the current or named provider
    /provider ID        Select a provider
    /model NAME         Select a model
    /chat               Inspect or edit the conversation transcript
    /agents             List configured agents
    /agent ID           Select an agent and clear the conversation
    /tools              List tools available to the current agent
    /mcps               List connected MCP servers
    /image MODE PATH    Attach at tiny/small/medium/big/full size, or OCR to Markdown
    /clear              Clear conversation history
    /exit               Exit the REPL
    """

  private static let chatHelp = """
    Chat conversation management commands:
      /chat list          Display a compact indexed message list
      /chat log           Display the full structured conversation
      /chat edit N TEXT   Replace message N's text; preserve attachments
      /chat remove N      Remove message N
      /chat undo [N]      Remove the last conversation message or message N
      /chat trim N        Keep through message N and remove everything after it
      /chat clear         Clear the conversation and restore configured instructions

    Removing a tool call or result also removes its linked tool transaction.
    """

  private static func printUsage() {
    print(
      """
      mai — config-driven MaiCore agent CLI

      Usage:
        mai [options] [message]

      Options:
        --config PATH       load providers, MCPs, agents, and approvals from JSON
        --print-config      print a complete example configuration
        --agent ID          select a configured agent
        --provider ID       override the selected provider
        --model NAME        override the selected model
        --base-url URL      ad-hoc OpenAI-compatible endpoint
        --api-key KEY       prefer an environment variable or config reference
        --system TEXT       override agent instructions
        --image PATH        attach an image (repeatable)
        --no-stream         disable response streaming
        -h, --help          show this help

      Config discovery:
        --config, MAI_CONFIG, ./mai.json, ~/.config/mai/config.json

      Without a config file, the offline hello and OpenAI-compatible providers
      are registered as before.
      """)
  }
}
