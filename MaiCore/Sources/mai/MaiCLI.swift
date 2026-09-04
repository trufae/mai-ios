import Foundation
import MaiCore
import MaiMCP
import MaiOpenAI
import MaiPluginHost
import MaiStandardTools
import MaiVisionOCR
import MaiVisual

#if os(Linux)
  import Glibc
#else
  import Darwin
#endif

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
  var pluginPaths: [String] = []
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
      case "--plugin":
        pluginPaths.append(try Self.value(after: argument, in: arguments, index: &index))
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

private struct RuntimeSetup {
  var catalogs: [MCPServerCatalog]
  var implicitProviders: [ConfiguredProvider] = []
}

/// What `/visual` needs beyond the REPL session itself.
private struct VisualBridge {
  var approvalHandler: TerminalApprovalHandler
  var configurationPath: String?
  var implicitProviders: [ConfiguredProvider]
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
  var useToolProxy: Bool

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
    useToolProxy = definition.useToolProxy
  }

  init(provider: ProviderID, model: String, instructions: String, stream: Bool) {
    agentID = "main"
    self.provider = provider
    self.model = model
    self.instructions = instructions
    toolNames = Set(
      [
        MaiEchoTool.name,
        MaiCurrentTimeTool.name,
        MaiCalculatorTool.name,
        MaiReadTextFileTool.name,
        MaiWeatherTool.name,
        MaiWebSearchTool.name,
        MaiWebFetchTool.name,
        MaiMastodonTool.name,
      ] + MaiGitHubTool.toolNames)
    subagentNames = []
    self.stream = stream
    limits = .init()
    toolChoice = .automatic
    responseFormat = .text
    options = .init()
    toolCallingStrategy = .automatic
    useToolProxy = false
  }

  var agentDefinition: AgentDefinition {
    AgentDefinition(
      id: agentID,
      instructions: instructions,
      provider: provider,
      model: model,
      toolNames: toolNames,
      subagentNames: subagentNames,
      stream: stream,
      limits: limits,
      toolChoice: toolChoice,
      responseFormat: responseFormat,
      options: options,
      toolCallingStrategy: toolCallingStrategy,
      useToolProxy: useToolProxy)
  }
}

private struct REPLSession {
  var profile: SessionProfile
  var history: AgentTranscript
  var pendingContent: [ContentPart]
  /// Conversations and panes left behind by the last `/visual` session.
  var visualSnapshot: VisualWorkspaceSnapshot?

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

  func visualSeed() -> VisualConversationSeed {
    VisualConversationSeed(
      title: profile.agentID,
      profile: profile.agentDefinition,
      messages: history.messages,
      pendingContent: pendingContent)
  }

  mutating func adopt(_ conversation: VisualConversationSeed) {
    profile = SessionProfile(definition: conversation.profile)
    history.replaceAll(with: conversation.messages)
    pendingContent = conversation.pendingContent
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
  private var delegate: (any ApprovalHandler)?

  init(configuration: ConfiguredApprovals) {
    self.configuration = configuration
  }

  /// Routes `ask` decisions elsewhere while another surface owns the terminal.
  func setDelegate(_ handler: (any ApprovalHandler)?) {
    delegate = handler
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
      if let delegate { return try await delegate.decide(request) }
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
      try await plugins.install(MaiMCPPlugin(), origin: "built-in")
      try await plugins.install(MaiOpenAIPlugin(), origin: "built-in")
      try await plugins.install(MaiVisionOCRPlugin(), origin: "built-in")
      try await plugins.install(MaiStandardToolsPlugin(), origin: "built-in")
      let nativePluginHost = NativePluginHost()
      try await loadNativePlugins(
        options: options,
        loadedConfigurationPath: loaded?.path,
        configuration: configuration,
        host: nativePluginHost,
        registry: plugins)
      try await registerTools(
        in: runtime,
        plugins: plugins,
        configuration: configuration,
        environment: environment)
      let ocrProvider = try await configuredOCRProvider(
        plugins: plugins,
        configuration: configuration,
        environment: environment)
      let setup = try await configureRuntime(
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
        if !succeeded { exit(1) }
        return
      }
      await runREPL(
        session: &session,
        runtime: runtime,
        plugins: plugins,
        ocrProvider: ocrProvider,
        configuration: configuration,
        catalogs: setup.catalogs,
        visual: VisualBridge(
          approvalHandler: approvalHandler,
          configurationPath: loaded?.path,
          implicitProviders: setup.implicitProviders),
        terminal: terminal)
    } catch {
      FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
      exit(2)
    }
  }

  private static func loadNativePlugins(
    options: CLIOptions,
    loadedConfigurationPath: String?,
    configuration: MaiConfiguration?,
    host: NativePluginHost,
    registry: PluginRegistry
  ) async throws {
    let currentDirectory = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath,
      isDirectory: true)
    let configDirectory =
      loadedConfigurationPath.map {
        URL(fileURLWithPath: $0).deletingLastPathComponent()
      } ?? currentDirectory
    let configured =
      configuration?.plugins.filter(\.enabled).map {
        (entry: $0, baseURL: configDirectory)
      } ?? []
    let commandLine = options.pluginPaths.map {
      (entry: ConfiguredPlugin(path: $0), baseURL: currentDirectory)
    }

    for item in configured + commandLine {
      let expanded = NSString(string: item.entry.path).expandingTildeInPath
      let url = URL(fileURLWithPath: expanded, relativeTo: item.baseURL).standardizedFileURL
      do {
        _ = try await host.loadPlugin(at: url, into: registry)
      } catch {
        if item.entry.required { throw error }
        FileHandle.standardError.write(
          Data(
            "warning: optional plugin '\(url.path)' was not loaded: \(error.localizedDescription)\n"
              .utf8))
      }
    }
  }

  private static func registerTools(
    in runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: MaiConfiguration?,
    environment: [String: String]
  ) async throws {
    let sources = configuration?.toolSources ?? []
    let configuredStandardTools = sources.filter {
      $0.kind == MaiStandardToolsPlugin.factoryKind
    }
    if configuredStandardTools.isEmpty {
      let tools = try await plugins.makeTools(
        kind: MaiStandardToolsPlugin.factoryKind,
        context: PluginFactoryContext(id: "standard-tools", environment: environment))
      for tool in tools { try await runtime.register(tool: tool) }
    } else {
      for source in configuredStandardTools where source.enabled {
        let tools = try await plugins.makeTools(
          kind: source.kind,
          context: source.context(environment: environment))
        for tool in tools { try await runtime.register(tool: tool) }
      }
    }

    for source in sources
    where source.enabled && source.kind != MaiStandardToolsPlugin.factoryKind {
      let tools = try await plugins.makeTools(
        kind: source.kind,
        context: source.context(environment: environment))
      for tool in tools { try await runtime.register(tool: tool) }
    }
  }

  private static func configuredOCRProvider(
    plugins: PluginRegistry,
    configuration: MaiConfiguration?,
    environment: [String: String]
  ) async throws -> any OCRProvider {
    if let configured = configuration?.ocrProviders.first(where: \.enabled) {
      return try await plugins.makeOCRProvider(
        kind: configured.kind,
        context: configured.context(environment: environment))
    }
    return try await plugins.makeOCRProvider(
      kind: "vision",
      context: PluginFactoryContext(id: "vision", environment: environment))
  }

  private static func configureRuntime(
    _ runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: MaiConfiguration?,
    options: CLIOptions,
    environment: [String: String]
  ) async throws -> RuntimeSetup {
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
        let source = try await plugins.makeMCPToolSource(
          kind: server.kind,
          configuration: server,
          environment: environment)
        catalogs.append(try await runtime.register(mcp: source))
      }
      let knownTools = Set(await runtime.availableTools().map(\.name))
      for agent in configuration.agents {
        for name in agent.toolNames where !knownTools.contains(name) {
          throw MaiConfigurationError.unknownTool(agent: agent.id, tool: name)
        }
      }
      return RuntimeSetup(catalogs: catalogs)
    }

    let hello = ConfiguredProvider(id: "hello", kind: .hello)
    try await runtime.register(plugins.makeProvider(from: hello, environment: environment))
    let rawBaseURL =
      options.baseURLOverride?.absoluteString
      ?? environment["MAI_BASE_URL"] ?? environment["OPENAI_BASE_URL"]
      ?? "https://api.openai.com/v1"
    guard let baseURL = URL(string: rawBaseURL) else { throw CLIError.invalidURL(rawBaseURL) }
    let openAI = ConfiguredProvider(
      id: ProviderID.openAI.rawValue,
      kind: .openAICompatible,
      baseURL: baseURL,
      apiKey: options.apiKeyOverride ?? environment["MAI_API_KEY"]
        ?? environment["OPENAI_API_KEY"])
    try await runtime.register(plugins.makeProvider(from: openAI, environment: environment))
    // The visual workspace drafts a configuration from these implicit providers.
    // It references the API key through its environment variable instead of
    // copying the secret into a file.
    var draft = openAI
    draft.apiKey = nil
    draft.apiKeyEnvironment = ["MAI_API_KEY", "OPENAI_API_KEY"].first { environment[$0] != nil }
    return RuntimeSetup(catalogs: [], implicitProviders: [hello, draft])
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
    plugins: PluginRegistry,
    ocrProvider: any OCRProvider,
    configuration: MaiConfiguration?,
    catalogs: [MCPServerCatalog],
    visual: VisualBridge,
    terminal: TerminalWriter
  ) async {
    var configuration = configuration
    var catalogs = catalogs
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
          plugins: plugins,
          ocrProvider: ocrProvider,
          configuration: &configuration,
          catalogs: &catalogs,
          visual: visual,
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
          toolCallingStrategy: profile.toolCallingStrategy,
          useToolProxy: profile.useToolProxy)
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
    plugins: PluginRegistry,
    ocrProvider: any OCRProvider,
    configuration: inout MaiConfiguration?,
    catalogs: inout [MCPServerCatalog],
    visual: VisualBridge,
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
    case "/plugins":
      for plugin in await plugins.installedPlugins() {
        let capabilities = plugin.manifest.capabilities.map(\.rawValue).sorted().joined(
          separator: ", ")
        let origin = plugin.origin.map { " — \($0)" } ?? ""
        await terminal.line(
          "\(plugin.manifest.id) \(plugin.manifest.version) [\(capabilities)]\(origin)")
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
      if session.profile.useToolProxy {
        await terminal.line("Tool proxy enabled: models see list-tools and call-tool.")
      }
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
    case "/proxy":
      switch argument.lowercased() {
      case "":
        await terminal.line("Tool proxy: \(session.profile.useToolProxy ? "on" : "off")")
      case "on":
        session.profile.useToolProxy = true
        await terminal.line("Tool proxy enabled.")
      case "off":
        session.profile.useToolProxy = false
        await terminal.line("Tool proxy disabled.")
      default:
        await terminal.line("Usage: /proxy [on|off]")
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
        session.pendingContent.append(
          try await imageContent(path: path, mode: mode, ocrProvider: ocrProvider))
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
    case "/copy":
      await copyToClipboard(argument, session: session, terminal: terminal)
    case "/visual":
      await runVisualMode(
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        catalogs: &catalogs,
        visual: visual,
        terminal: terminal)
    case "/clear":
      session.reset()
      await terminal.line("Conversation cleared.")
    default:
      await terminal.line("Unknown command. Type /help.")
    }
    return false
  }

  private static func copyToClipboard(
    _ argument: String,
    session: REPLSession,
    terminal: TerminalWriter
  ) async {
    do {
      let selection = try TranscriptCopy.selection(parsing: argument)
      let result = try TranscriptCopy.text(for: selection, in: session.history.messages)
      try SystemClipboard.write(result.text)
      let count = result.messages.count
      let subject =
        selection == .lastAssistantReply
        ? "the last reply" : "\(count) message\(count == 1 ? "" : "s")"
      await terminal.line(
        "Copied \(subject) (\(result.text.count) characters) to the clipboard.")
    } catch let error as TranscriptCopyError {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      if case .invalidCount = error { await terminal.line("Usage: /copy [N]") }
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  /// Hands the terminal to the SwiftTUI workspace and adopts its focused
  /// conversation, registrations, and configuration draft when it returns.
  private static func runVisualMode(
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    catalogs: inout [MCPServerCatalog],
    visual: VisualBridge,
    terminal: TerminalWriter
  ) async {
    guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
      await terminal.line("Visual mode needs an interactive terminal.", to: .standardError)
      return
    }
    let launch = VisualLaunch(
      focusedConversation: session.visualSeed(),
      snapshot: session.visualSnapshot,
      configuration: configuration ?? MaiConfiguration(providers: visual.implicitProviders),
      configurationPath: visual.configurationPath,
      catalogs: catalogs,
      environment: ProcessInfo.processInfo.environment)
    let approvals = VisualApprovalHandler()
    await visual.approvalHandler.setDelegate(approvals)
    do {
      let outcome = try await VisualMode.run(
        launch,
        runtime: runtime,
        plugins: plugins,
        approvals: approvals)
      await visual.approvalHandler.setDelegate(nil)
      session.adopt(outcome.focusedConversation)
      session.visualSnapshot = outcome.snapshot
      catalogs = outcome.catalogs
      if outcome.configurationChanged || configuration != nil {
        configuration = outcome.configuration
      }
      await terminal.line(outcome.summary)
    } catch {
      await visual.approvalHandler.setDelegate(nil)
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
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
    mode: ImageAttachmentMode,
    ocrProvider: any OCRProvider
  ) async throws -> ContentPart {
    let loaded = try loadImage(path: path)
    return try await ImageAttachmentImporter.content(
      data: loaded.data,
      mimeType: loaded.mimeType,
      filename: loaded.url.lastPathComponent,
      mode: mode,
      ocrProvider: mode == .ocr ? ocrProvider : nil)
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

  private static func sampleConfiguration() -> MaiConfiguration {
    MaiConfiguration(
      defaultAgent: "hello",
      plugins: [
        ConfiguredPlugin(path: "./plugins/example.dylib", enabled: false)
      ],
      providers: [
        ConfiguredProvider(id: "hello", kind: .hello),
        ConfiguredProvider(
          id: "openai",
          kind: .openAICompatible,
          baseURL: URL(string: "https://api.openai.com/v1"),
          apiKeyEnvironment: "OPENAI_API_KEY"),
      ],
      toolSources: [
        ConfiguredToolSource(
          id: "standard-tools",
          kind: MaiStandardToolsPlugin.factoryKind,
          options: [
            "webSearchProvider": .string(MaiWebSearchProvider.exa.rawValue),
            "weatherLocation": .string(""),
            "mastodonInstance": .string("mastodon.social"),
            "mastodonAPIKeyEnvironment": .string("MASTODON_API_KEY"),
            "mastodonWriteEnabled": .bool(false),
          ]),
        ConfiguredToolSource(id: "example-tools", kind: "example", enabled: false)
      ],
      ocrProviders: [
        ConfiguredOCRProvider(id: "vision", kind: "vision")
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
          toolNames: Set(
            [
              MaiCurrentTimeTool.name,
              MaiEchoTool.name,
              MaiReadTextFileTool.name,
              MaiWeatherTool.name,
              MaiWebSearchTool.name,
              MaiWebFetchTool.name,
              MaiMastodonTool.name,
            ] + MaiGitHubTool.toolNames),
          subagentNames: ["researcher"],
          useToolProxy: true),
        AgentDefinition(
          id: "researcher",
          instructions: "Investigate the delegated task and return a concise result.",
          provider: "openai",
          model: "your-model",
          toolNames: [MaiCurrentTimeTool.name]),
      ],
      approvals: ConfiguredApprovals(confirm: .ask, dangerous: .ask))
  }

  private static let replHelp = """
    /plugins            List statically and dynamically loaded plugins
    /providers          List registered providers
    /models [PROVIDER]  List models from the current or named provider
    /provider ID        Select a provider
    /model NAME         Select a model
    /chat               Inspect or edit the conversation transcript
    /agents             List configured agents
    /agent ID           Select an agent and clear the conversation
    /tools              List tools available to the current agent
    /proxy [on|off]     Inspect or toggle the shared tool proxy
    /mcps               List connected MCP servers
    /image MODE PATH    Attach at tiny/small/medium/big/full size, or OCR to Markdown
    /copy [N]           Copy the last reply, or the last N messages, to the clipboard
    /visual             Open the terminal workspace: split chats, providers, MCPs, tools
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
        --config PATH       load plugins, providers, tools, MCPs, agents, and approvals
        --plugin PATH       load a native .dylib plugin (repeatable)
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
