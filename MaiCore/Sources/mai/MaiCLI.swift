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
  var statePath: String?
  var historyPath: String?
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
    configPath = environment["PMAI_CONFIG"]
    statePath = environment["PMAI_STATE"]
    historyPath = environment["PMAI_HISTORY"]
    var positional: [String] = []
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--config":
        configPath = try Self.value(after: argument, in: arguments, index: &index)
      case "--state":
        statePath = try Self.value(after: argument, in: arguments, index: &index)
      case "--history":
        historyPath = try Self.value(after: argument, in: arguments, index: &index)
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

struct SessionProfile {
  var agentID: String
  var provider: ProviderID
  var model: String
  var instructions: String
  var toolNames: Set<String>
  var toolGroupNames: Set<String>
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
    toolGroupNames = definition.toolGroupNames
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
    toolGroupNames = ["echo", "datetime", "calculator", "files", "weather", "web", "mastodon", "github"]
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
      toolGroupNames: toolGroupNames,
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

struct REPLSession {
  var id: UUID
  var title: String
  var profile: SessionProfile
  var history: AgentTranscript
  var pendingContent: [ContentPart]
  var createdAt: Date
  var updatedAt: Date
  /// Conversations and panes left behind by the last `/visual` session.
  var visualSnapshot: VisualWorkspaceSnapshot?

  init(
    id: UUID = UUID(),
    title: String? = nil,
    profile: SessionProfile,
    pendingContent: [ContentPart] = [],
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.title = title ?? profile.agentID
    self.profile = profile
    history = AgentTranscript(messages: Self.initialHistory(for: profile))
    self.pendingContent = pendingContent
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  init(chat: AgentChat) {
    id = chat.id
    title = chat.title
    profile = SessionProfile(definition: chat.primaryAgent)
    history = AgentTranscript(messages: chat.messages)
    pendingContent = chat.pendingContent
    createdAt = chat.createdAt
    updatedAt = chat.updatedAt
  }

  var chat: AgentChat {
    AgentChat(
      id: id,
      title: title,
      primaryAgent: profile.agentDefinition,
      messages: history.messages,
      pendingContent: pendingContent,
      createdAt: createdAt,
      updatedAt: updatedAt)
  }

  mutating func reset(profile: SessionProfile? = nil) {
    if let profile { self.profile = profile }
    history.replaceAll(with: Self.initialHistory(for: self.profile))
    pendingContent.removeAll()
    touch()
  }

  mutating func touch() {
    updatedAt = Date()
  }

  func visualSeed() -> VisualConversationSeed {
    VisualConversationSeed(
      id: id,
      title: title,
      profile: profile.agentDefinition,
      messages: history.messages,
      pendingContent: pendingContent)
  }

  mutating func adopt(_ conversation: VisualConversationSeed) {
    id = conversation.id
    title = conversation.title
    profile = SessionProfile(definition: conversation.profile)
    history.replaceAll(with: conversation.messages)
    pendingContent = conversation.pendingContent
    touch()
  }

  private static func initialHistory(for profile: SessionProfile) -> [AgentMessage] {
    let instructions = profile.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    return instructions.isEmpty ? [] : [.system(instructions)]
  }
}

private actor TerminalWriter {
  private var wroteRootDelta = false
  private var rootLineOpen = false
  /// When set, output is collected for another surface instead of hitting the tty.
  private let capturesOutput: Bool
  private var captured: [String] = []

  init(capturesOutput: Bool = false) {
    self.capturesOutput = capturesOutput
  }

  func drainCaptured() -> String {
    let text = captured.joined()
    captured.removeAll()
    return text
  }

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
    if capturesOutput {
      captured.append(value + "\n")
      return
    }
    handle.write(Data((value + "\n").utf8))
  }

  private func write(_ value: String) {
    if capturesOutput {
      captured.append(value)
      return
    }
    FileHandle.standardOutput.write(Data(value.utf8))
  }

  private func status(_ value: String) {
    if capturesOutput {
      captured.append(value + "\n")
      return
    }
    FileHandle.standardError.write(Data((value + "\n").utf8))
  }

  private func closeRootLine(force: Bool = false) {
    if rootLineOpen || force {
      if capturesOutput {
        captured.append("\n")
      } else {
        FileHandle.standardOutput.write(Data("\n".utf8))
      }
    }
    rootLineOpen = false
  }
}

private actor TerminalApprovalHandler: ApprovalHandler {
  private let configuration: ConfiguredApprovals
  private var delegate: (any ApprovalHandler)?
  private var yoloEnabled = false

  init(configuration: ConfiguredApprovals) {
    self.configuration = configuration
  }

  /// Routes `ask` decisions elsewhere while another surface owns the terminal.
  func setDelegate(_ handler: (any ApprovalHandler)?) {
    delegate = handler
  }

  func setYOLOEnabled(_ enabled: Bool) {
    yoloEnabled = enabled
  }

  func isYOLOEnabled() -> Bool {
    yoloEnabled
  }

  func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
    if yoloEnabled {
      return .approve(arguments: request.call.arguments)
    }
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
          "Approve \(request.tool.annotations.approval.rawValue) tool '\(request.tool.name)'?\nArguments: \(request.call.arguments.compactJSONString)\n[y]es/[a]lways/[n]o/[e]dit/[c]ancel run: "
            .utf8))
      guard let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      else { return .deny(reason: "No approval response.") }
      switch answer {
      case "y", "yes":
        return .approve(arguments: request.call.arguments)
      case "a", "always":
        yoloEnabled = true
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
      let configurationPath = loaded?.path ?? defaultConfigurationPath
      var configuration = loaded?.configuration
      if var existing = configuration,
        !existing.toolSources.contains(where: {
          $0.kind == MaiStandardToolsPlugin.factoryKind
        })
      {
        existing.toolSources.append(
          ConfiguredToolSource(
            id: "standard-tools",
            kind: MaiStandardToolsPlugin.factoryKind))
        try existing.save(to: URL(fileURLWithPath: configurationPath))
        configuration = existing
      }
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
      if configuration == nil {
        configuration = MaiConfiguration(
          defaultAgent: profile.agentID,
          providers: setup.implicitProviders,
          toolSources: [
            ConfiguredToolSource(
              id: "standard-tools",
              kind: MaiStandardToolsPlugin.factoryKind)
          ],
          agents: [profile.agentDefinition])
        try configuration?.save(to: URL(fileURLWithPath: configurationPath))
      }
      let stateURL = URL(fileURLWithPath: resolvedStatePath(options: options))
      var workspace = try loadChatWorkspace(from: stateURL, initialProfile: profile)
      var session = REPLSession(chat: workspace.selectedChat!)
      session.pendingContent.append(contentsOf: try options.imagePaths.map(imageContent))
      session.touch()
      workspace.upsert(session.chat, selecting: true)
      let terminal = TerminalWriter()

      if let path = loaded?.path {
        await terminal.line("Loaded \(path)", to: .standardError)
      } else {
        await terminal.line("Created \(configurationPath)", to: .standardError)
      }
      if let prompt = options.initialPrompt {
        let succeeded = await submit(
          prompt,
          session: &session,
          runtime: runtime,
          terminal: terminal)
        workspace.upsert(session.chat, selecting: true)
        try workspace.save(to: stateURL)
        if !succeeded { exit(1) }
        return
      }
      await runREPL(
        workspace: &workspace,
        stateURL: stateURL,
        historyURL: URL(fileURLWithPath: resolvedHistoryPath(options: options)),
        runtime: runtime,
        plugins: plugins,
        ocrProvider: ocrProvider,
        configuration: configuration,
        catalogs: setup.catalogs,
        visual: VisualBridge(
          approvalHandler: approvalHandler,
          configurationPath: configurationPath,
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
    workspace: inout AgentChatWorkspace,
    stateURL: URL,
    historyURL: URL,
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
    var session = REPLSession(chat: workspace.selectedChat!)
    let editor = TerminalLineEditor(historyURL: historyURL)
    await terminal.line("pmai — MaiCore agent REPL")
    await terminal.line(
      "Type /help for commands. Chat: \(session.title); agent: \(session.profile.agentID)")

    while true {
      let prompt = "pmai[\(session.title):\(session.profile.agentID)]> "
      guard
        let input = editor.readLine(
          prompt: prompt,
          completions: completionCandidates(
            workspace: workspace,
            configuration: configuration))
      else {
        workspace.upsert(session.chat, selecting: true)
        await saveWorkspace(workspace, to: stateURL, terminal: terminal)
        return
      }
      let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { continue }
      if text.hasPrefix("/") {
        if text == "/chat" || text.hasPrefix("/chat ") {
          workspace.upsert(session.chat, selecting: true)
          await handleWorkspaceChatCommand(
            String(text.dropFirst("/chat".count)).trimmingCharacters(
              in: .whitespacesAndNewlines),
            session: &session,
            workspace: &workspace,
            configuration: configuration,
            terminal: terminal)
          workspace.upsert(session.chat, selecting: true)
          await saveWorkspace(workspace, to: stateURL, terminal: terminal)
          continue
        }
        if text == "/visual" {
          workspace.upsert(session.chat, selecting: true)
          session.visualSnapshot = visualSnapshot(for: workspace)
        }
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
          workspace.upsert(session.chat, selecting: true)
          await saveWorkspace(workspace, to: stateURL, terminal: terminal)
          return
        }
        if text == "/visual", let snapshot = session.visualSnapshot {
          workspace = chatWorkspace(from: snapshot, focusedID: session.id, previous: workspace)
          session = REPLSession(chat: workspace.selectedChat!)
        } else {
          session.touch()
          workspace.upsert(session.chat, selecting: true)
        }
        await saveWorkspace(workspace, to: stateURL, terminal: terminal)
        continue
      }
      _ = await submit(text, session: &session, runtime: runtime, terminal: terminal)
      session.touch()
      workspace.upsert(session.chat, selecting: true)
      await saveWorkspace(workspace, to: stateURL, terminal: terminal)
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
    case "/set":
      await handleSetCommand(
        argument,
        approvalHandler: visual.approvalHandler,
        terminal: terminal)
    case "/providers":
      for provider in await runtime.availableProviders() {
        let selected = provider.id == session.profile.provider ? "*" : " "
        let baseURL = configuration?.providers.first { $0.id == provider.id.rawValue }?.baseURL
          .map { " — \($0.absoluteString)" } ?? ""
        await terminal.line("\(selected) \(provider.id) — \(provider.displayName)\(baseURL)")
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
      let saved = await persistAgentProfile(
        session: session,
        configuration: &configuration,
        configurationPath: visual.configurationPath,
        runtime: runtime,
        terminal: terminal)
      if saved {
        await terminal.line("Provider: \(id) (saved for agent \(session.profile.agentID))")
      }
    case "/model":
      if argument.isEmpty {
        await terminal.line(
          session.profile.model.isEmpty ? "No model selected." : "Model: \(session.profile.model)")
      } else {
        session.profile.model = argument
        let saved = await persistAgentProfile(
          session: session,
          configuration: &configuration,
          configurationPath: visual.configurationPath,
          runtime: runtime,
          terminal: terminal)
        if saved {
          await terminal.line("Model: \(argument) (saved for agent \(session.profile.agentID))")
        }
      }
    case "/agents":
      let agents: [AgentDefinition]
      if let configured = configuration?.agents {
        agents = configured
      } else {
        agents = await runtime.availableAgents()
      }
      if agents.isEmpty { await terminal.line("No configured agents.") }
      for agent in agents {
        let selected = agent.id == session.profile.agentID ? "*" : " "
        let baseURL = configuration?.providers.first { $0.id == agent.provider.rawValue }?.baseURL?
          .absoluteString ?? "-"
        await terminal.line(
          "\(selected) \(agent.id) — \(agent.displayName) [\(agent.provider) \(baseURL) \(agent.model)]")
      }
    case "/agent":
      await handleAgentCommand(
        argument,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: visual.configurationPath,
        terminal: terminal)
    case "/tools":
      await handleToolsCommand(
        argument,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: visual.configurationPath,
        terminal: terminal)
    case "/proxy":
      switch argument.lowercased() {
      case "":
        await terminal.line("Tool proxy: \(session.profile.useToolProxy ? "on" : "off")")
      case "on":
        session.profile.useToolProxy = true
        if await persistAgentProfile(
          session: session,
          configuration: &configuration,
          configurationPath: visual.configurationPath,
          runtime: runtime,
          terminal: terminal)
        {
          await terminal.line("Tool proxy enabled.")
        }
      case "off":
        session.profile.useToolProxy = false
        if await persistAgentProfile(
          session: session,
          configuration: &configuration,
          configurationPath: visual.configurationPath,
          runtime: runtime,
          terminal: terminal)
        {
          await terminal.line("Tool proxy disabled.")
        }
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
        ocrProvider: ocrProvider,
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

  private static func handleAgentCommand(
    _ argument: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(maxSplits: 5, whereSeparator: \Character.isWhitespace).map(
      String.init)
    guard let action = fields.first?.lowercased() else {
      await showAgent(
        session.profile.agentID,
        session: session,
        configuration: configuration,
        terminal: terminal)
      await terminal.line(
        "Usage: /agent [use] ID | /agent add NAME PROVIDER BASE_URL MODEL SYSTEM_PROMPT")
      return
    }

    if action == "add" {
      guard fields.count == 6, let baseURL = URL(string: fields[3]),
        ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""),
        baseURL.host != nil
      else {
        await terminal.line("Usage: /agent add NAME PROVIDER BASE_URL MODEL SYSTEM_PROMPT")
        return
      }
      let name = fields[1]
      let providerID = ProviderID(fields[2])
      var draft = configuration ?? MaiConfiguration()
      var providerChanged = false
      if let index = draft.providers.firstIndex(where: { $0.id == providerID.rawValue }) {
        if let configuredURL = draft.providers[index].baseURL, configuredURL != baseURL {
          await terminal.line(
            "Provider '\(providerID)' already uses \(configuredURL.absoluteString). Use a unique provider ID for \(baseURL.absoluteString).",
            to: .standardError)
          return
        }
        if draft.providers[index].baseURL == nil {
          draft.providers[index].baseURL = baseURL
          providerChanged = true
        }
      } else {
        draft.providers.append(
          ConfiguredProvider(
            id: providerID.rawValue,
            kind: .openAICompatible,
            baseURL: baseURL,
            apiKeyEnvironment: apiKeyEnvironmentName(for: providerID.rawValue)))
        providerChanged = true
      }

      var definition = session.profile.agentDefinition
      definition.id = name
      definition.displayName = name
      definition.provider = providerID
      definition.model = fields[4] == "-" ? "" : fields[4]
      definition.instructions = fields[5] == "-" ? "" : fields[5]
      if let index = draft.agents.firstIndex(where: { $0.id == name }) {
        draft.agents[index] = definition
      } else {
        draft.agents.append(definition)
      }
      if draft.defaultAgent == nil { draft.defaultAgent = name }

      do {
        guard let configurationPath else {
          throw CLIError.configNotFound("No configuration path is available.")
        }
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        if providerChanged,
          let provider = draft.providers.first(where: { $0.id == providerID.rawValue })
        {
          try await runtime.register(
            plugins.makeProvider(
              from: provider,
              environment: ProcessInfo.processInfo.environment),
            replacingExisting: true)
        }
        try await runtime.register(agent: definition, replacingExisting: true)
        configuration = draft
        session.reset(profile: SessionProfile(definition: definition))
        await terminal.line(
          "Agent '\(name)' saved and selected for chat '\(session.title)'. Conversation cleared.")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
      return
    }

    if action == "show" {
      await showAgent(
        fields.count > 1 ? fields[1] : session.profile.agentID,
        session: session,
        configuration: configuration,
        terminal: terminal)
      return
    }

    let selectedID: String
    if action == "use" {
      guard fields.count == 2 else {
        await terminal.line("Usage: /agent use ID")
        return
      }
      selectedID = fields[1]
    } else {
      selectedID = fields[0]
    }
    guard let definition = configuration?.agents.first(where: { $0.id == selectedID }) else {
      await terminal.line("Unknown agent '\(selectedID)'. Use /agents.")
      return
    }
    session.reset(profile: SessionProfile(definition: definition))
    await terminal.line(
      "Agent: \(selectedID). It is now the primary agent for chat '\(session.title)'; conversation cleared."
    )
  }

  private static func showAgent(
    _ id: String,
    session: REPLSession,
    configuration: MaiConfiguration?,
    terminal: TerminalWriter
  ) async {
    let definition =
      configuration?.agents.first(where: { $0.id == id })
      ?? (session.profile.agentID == id ? session.profile.agentDefinition : nil)
    guard let definition else {
      await terminal.line("Unknown agent '\(id)'. Use /agents.")
      return
    }
    let provider = configuration?.providers.first { $0.id == definition.provider.rawValue }
    await terminal.line("Agent: \(definition.id) (\(definition.displayName))")
    await terminal.line("Provider: \(definition.provider)")
    await terminal.line("Base URL: \(provider?.baseURL?.absoluteString ?? "-")")
    await terminal.line("Model: \(definition.model.isEmpty ? "-" : definition.model)")
    await terminal.line(
      "System prompt: \(definition.instructions.isEmpty ? "-" : definition.instructions)")
  }

  @discardableResult
  private static func persistAgentProfile(
    session: REPLSession,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    runtime: AgentRuntime,
    terminal: TerminalWriter
  ) async -> Bool {
    guard var draft = configuration, let configurationPath else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return false
    }
    let definition = session.profile.agentDefinition
    if let index = draft.agents.firstIndex(where: { $0.id == definition.id }) {
      draft.agents[index] = definition
    } else {
      draft.agents.append(definition)
    }
    if draft.defaultAgent == nil { draft.defaultAgent = definition.id }
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      try await runtime.register(agent: definition, replacingExisting: true)
      configuration = draft
      return true
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      return false
    }
  }

  private static func apiKeyEnvironmentName(for providerID: String) -> String {
    if providerID.lowercased() == "openai" { return "OPENAI_API_KEY" }
    let stem = providerID.uppercased().map { character in
      character.isLetter || character.isNumber ? character : "_"
    }
    return String(stem) + "_API_KEY"
  }

  private static func handleToolsCommand(
    _ argument: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(maxSplits: 3, whereSeparator: \Character.isWhitespace).map(
      String.init)
    let action = fields.first?.lowercased() ?? "list"
    let groups: [ToolGroupDefinition]
    do {
      groups = try await toolGroupCatalog(
        runtime: runtime,
        plugins: plugins,
        configuration: configuration)
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      return
    }

    if action == "list" || fields.isEmpty {
      if session.profile.useToolProxy {
        await terminal.line("Tool proxy enabled: models see list-tools and call-tool.")
      }
      for group in groups {
        let enabled = isToolGroupEnabled(group, profile: session.profile) ? "*" : " "
        await terminal.line(
          "\(enabled) \(group.id) — \(group.displayName) [\(group.toolNames.count) tool\(group.toolNames.count == 1 ? "" : "s")]"
        )
      }
      if !session.profile.subagentNames.isEmpty {
        await terminal.line(
          "* subagents — \(session.profile.subagentNames.sorted().joined(separator: ", "))")
      }
      await terminal.line("Use /tools show GROUP to inspect tool names and settings.")
      return
    }

    guard fields.count >= 2, let group = resolveToolGroup(fields[1], in: groups) else {
      await terminal.line(toolHelp)
      return
    }
    switch action {
    case "enable", "on":
      session.profile.toolGroupNames.insert(group.id)
      session.profile.toolNames.formUnion(group.toolNames)
      if await persistAgentProfile(
        session: session,
        configuration: &configuration,
        configurationPath: configurationPath,
        runtime: runtime,
        terminal: terminal)
      {
        await terminal.line("Enabled tool group '\(group.id)' for agent \(session.profile.agentID).")
      }
    case "disable", "off":
      session.profile.toolGroupNames.remove(group.id)
      session.profile.toolNames.subtract(group.toolNames)
      if await persistAgentProfile(
        session: session,
        configuration: &configuration,
        configurationPath: configurationPath,
        runtime: runtime,
        terminal: terminal)
      {
        await terminal.line("Disabled tool group '\(group.id)' for agent \(session.profile.agentID).")
      }
    case "show":
      await terminal.line("\(group.displayName): \(group.description)")
      await terminal.line("Tools: \(group.toolNames.sorted().joined(separator: ", "))")
      let options = configuredOptions(for: group, configuration: configuration)
      for option in group.options {
        let value = options[option.id] ?? option.defaultValue
        await terminal.line("\(option.id) = \(displayedOption(value, kind: option.kind))")
      }
    case "set", "config":
      guard fields.count == 4,
        let option = group.options.first(where: { $0.id == fields[2] }),
        let value = parseToolOption(fields[3], definition: option)
      else {
        await terminal.line("Usage: /tools set GROUP OPTION VALUE")
        return
      }
      await reconfigureToolGroup(
        group,
        option: option.id,
        value: value,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
    case "unset":
      guard fields.count == 3,
        group.options.contains(where: { $0.id == fields[2] })
      else {
        await terminal.line("Usage: /tools unset GROUP OPTION")
        return
      }
      await reconfigureToolGroup(
        group,
        option: fields[2],
        value: nil,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
    default:
      await terminal.line(toolHelp)
    }
  }

  private static func toolGroupCatalog(
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: MaiConfiguration?
  ) async throws -> [ToolGroupDefinition] {
    var groups: [ToolGroupDefinition] = []
    for source in configuration?.toolSources.filter(\.enabled) ?? [] {
      groups.append(
        contentsOf: try await plugins.toolGroups(
          kind: source.kind,
          context: source.context(environment: ProcessInfo.processInfo.environment)))
    }
    let tools = await runtime.availableTools()
    let groupedNames = Set(groups.flatMap(\.toolNames))
    var ungrouped = ToolGroupDefinition.inferred(
      from: tools.filter { !groupedNames.contains($0.name) })
    for index in ungrouped.indices { ungrouped[index].sourceID = "runtime" }
    return (groups + ungrouped).sorted {
      $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
    }
  }

  private static func resolveToolGroup(
    _ selector: String,
    in groups: [ToolGroupDefinition]
  ) -> ToolGroupDefinition? {
    let matches = groups.filter {
      $0.id.caseInsensitiveCompare(selector) == .orderedSame
        || $0.catalogID.caseInsensitiveCompare(selector) == .orderedSame
    }
    return matches.count == 1 ? matches[0] : nil
  }

  private static func isToolGroupEnabled(
    _ group: ToolGroupDefinition,
    profile: SessionProfile
  ) -> Bool {
    profile.toolGroupNames.contains(group.id) || group.toolNames.isSubset(of: profile.toolNames)
  }

  private static func configuredOptions(
    for group: ToolGroupDefinition,
    configuration: MaiConfiguration?
  ) -> [String: JSONValue] {
    let source = configuration?.toolSources.first { $0.id == group.sourceID }
    return Dictionary(
      uniqueKeysWithValues: group.options.compactMap { option in
        source?.options[option.id].map { (option.id, $0) }
          ?? option.defaultValue.map { (option.id, $0) }
      })
  }

  private static func displayedOption(
    _ value: JSONValue?,
    kind: ToolGroupOptionKind
  ) -> String {
    guard let value else { return "-" }
    if kind == .secret { return value.stringValue?.isEmpty == false ? "(configured)" : "-" }
    if let string = value.stringValue { return string }
    if let number = value.numberValue { return String(number) }
    if let boolean = value.boolValue { return String(boolean) }
    return value.compactJSONString
  }

  private static func parseToolOption(
    _ rawValue: String,
    definition: ToolGroupOptionDefinition
  ) -> JSONValue? {
    switch definition.kind {
    case .text, .secret:
      return .string(rawValue)
    case .boolean:
      return booleanSetting(rawValue).map(JSONValue.bool)
    case .number:
      return Double(rawValue).map(JSONValue.number)
    case .choice:
      guard definition.choices.contains(rawValue) else { return nil }
      return .string(rawValue)
    }
  }

  private static func reconfigureToolGroup(
    _ group: ToolGroupDefinition,
    option: String,
    value: JSONValue?,
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard var draft = configuration, let configurationPath,
      let sourceIndex = draft.toolSources.firstIndex(where: { $0.id == group.sourceID })
    else {
      await terminal.line("This runtime-only group has no persistent settings.")
      return
    }
    if let value {
      draft.toolSources[sourceIndex].options[option] = value
    } else {
      draft.toolSources[sourceIndex].options.removeValue(forKey: option)
    }
    let source = draft.toolSources[sourceIndex]
    do {
      let context = source.context(environment: ProcessInfo.processInfo.environment)
      let tools = try await plugins.makeTools(kind: source.kind, context: context)
      let groups = try await plugins.toolGroups(kind: source.kind, context: context)
      let replacement = groups.first(where: { $0.id == group.id })
      for index in draft.agents.indices
      where draft.agents[index].toolGroupNames.contains(group.id)
        || group.toolNames.isSubset(of: draft.agents[index].toolNames)
      {
        draft.agents[index].toolGroupNames.insert(group.id)
        draft.agents[index].toolNames.subtract(group.toolNames)
        if let replacement {
          draft.agents[index].toolNames.formUnion(replacement.toolNames)
        }
      }
      if isToolGroupEnabled(group, profile: session.profile),
        let replacement
      {
        session.profile.toolGroupNames.insert(group.id)
        session.profile.toolNames.subtract(group.toolNames)
        session.profile.toolNames.formUnion(replacement.toolNames)
      }
      let definition = session.profile.agentDefinition
      if let index = draft.agents.firstIndex(where: { $0.id == definition.id }) {
        draft.agents[index] = definition
      } else {
        draft.agents.append(definition)
      }
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      for tool in tools {
        try await runtime.register(tool: tool, replacingExisting: true)
      }
      for agent in draft.agents {
        try await runtime.register(agent: agent, replacingExisting: true)
      }
      configuration = draft
      await terminal.line("Saved \(group.id).\(option).")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  private static func handleSetCommand(
    _ argument: String,
    approvalHandler: TerminalApprovalHandler,
    terminal: TerminalWriter
  ) async {
    let parts = argument.replacingOccurrences(of: "=", with: " ")
      .split(whereSeparator: \Character.isWhitespace)
      .map(String.init)
    guard !parts.isEmpty else {
      let enabled = await approvalHandler.isYOLOEnabled()
      await terminal.line("yolo = \(enabled ? "on" : "off")")
      await terminal.line("Usage: /set yolo <on|off>")
      return
    }
    guard parts[0].lowercased() == "yolo" else {
      await terminal.line("Unknown setting '\(parts[0])'. Available settings: yolo")
      return
    }
    guard parts.count > 1 else {
      let enabled = await approvalHandler.isYOLOEnabled()
      await terminal.line("yolo = \(enabled ? "on" : "off")")
      return
    }
    guard parts.count == 2, let enabled = booleanSetting(parts[1]) else {
      await terminal.line("Usage: /set yolo <on|off>")
      return
    }
    await approvalHandler.setYOLOEnabled(enabled)
    if enabled {
      await terminal.line("YOLO mode enabled for this session; all tool calls are permitted.")
    } else {
      await terminal.line("YOLO mode disabled; configured approval rules restored.")
    }
  }

  private static func booleanSetting(_ value: String) -> Bool? {
    switch value.lowercased() {
    case "1", "true", "yes", "on": true
    case "0", "false", "no", "off": false
    default: nil
    }
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
    ocrProvider: any OCRProvider,
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
      environment: ProcessInfo.processInfo.environment,
      commandHandler: { request in
        await runVisualCommand(
          request,
          runtime: runtime,
          plugins: plugins,
          ocrProvider: ocrProvider,
          visual: visual)
      })
    let approvals = VisualApprovalHandler {
      await visual.approvalHandler.setYOLOEnabled(true)
    }
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

  /// Runs a slash command typed into a visual pane exactly as the REPL would,
  /// on a session built from that pane's conversation, and returns what it
  /// printed together with the conversation it left behind.
  private static func runVisualCommand(
    _ request: VisualCommandRequest,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    ocrProvider: any OCRProvider,
    visual: VisualBridge
  ) async -> VisualCommandOutcome {
    let command =
      request.input.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).first.map(
        String.init) ?? request.input
    switch command {
    case "/visual":
      return VisualCommandOutcome(
        output: "Already in visual mode. /exit or Ctrl+C returns to the REPL.",
        conversation: request.conversation)
    case "/exit", "/quit":
      return VisualCommandOutcome(
        output: "Leaving visual mode.",
        conversation: request.conversation,
        leavesVisualMode: true)
    default:
      break
    }

    var session = REPLSession(
      profile: SessionProfile(definition: request.conversation.profile),
      pendingContent: request.conversation.pendingContent)
    session.history.replaceAll(with: request.conversation.messages)
    var configuration: MaiConfiguration? = request.configuration
    var catalogs = request.catalogs
    let terminal = TerminalWriter(capturesOutput: true)
    _ = await handleCommand(
      request.input,
      session: &session,
      runtime: runtime,
      plugins: plugins,
      ocrProvider: ocrProvider,
      configuration: &configuration,
      catalogs: &catalogs,
      visual: visual,
      terminal: terminal)
    var output = await terminal.drainCaptured()
    if command == "/help" {
      output += "\nIn visual mode, /exit returns to the REPL and the output above closes with Esc."
    }
    if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { output = "Done." }
    var conversation = request.conversation
    conversation.profile = session.profile.agentDefinition
    conversation.messages = session.history.messages
    conversation.pendingContent = session.pendingContent
    return VisualCommandOutcome(output: output, conversation: conversation)
  }

  private static func handleWorkspaceChatCommand(
    _ argument: String,
    session: inout REPLSession,
    workspace: inout AgentChatWorkspace,
    configuration: MaiConfiguration?,
    terminal: TerminalWriter
  ) async {
    let parts = argument.split(maxSplits: 2, whereSeparator: \Character.isWhitespace).map(
      String.init)
    guard let action = parts.first?.lowercased(), !action.isEmpty else {
      await terminal.line(chatHelp)
      return
    }

    switch action {
    case "list", "chats":
      for (index, chat) in workspace.chats.enumerated() {
        let selected = chat.id == workspace.selectedChatID ? "*" : " "
        await terminal.line(
          "\(selected) \(index + 1) \(chat.id.uuidString.prefix(8)) \(chat.title) — agent \(chat.primaryAgent.id), \(chat.messages.count) messages"
        )
      }
    case "new":
      var profile = session.profile
      var title = String(argument.dropFirst(action.count)).trimmingCharacters(
        in: .whitespacesAndNewlines)
      if title.hasPrefix("--agent ") {
        let values = title.split(maxSplits: 2, whereSeparator: \Character.isWhitespace).map(
          String.init)
        guard values.count >= 2,
          let agent = configuration?.agents.first(where: { $0.id == values[1] })
        else {
          await terminal.line("Usage: /chat new [--agent ID] [TITLE]")
          return
        }
        profile = SessionProfile(definition: agent)
        title = values.count == 3 ? values[2] : agent.displayName
      }
      if title.isEmpty { title = "Chat \(workspace.chats.count + 1)" }
      let chat = AgentChat(title: title, primaryAgent: profile.agentDefinition)
      workspace.upsert(chat, selecting: true)
      session = REPLSession(chat: chat)
      await terminal.line("Created and selected chat '\(title)' with agent \(profile.agentID).")
    case "use", "switch":
      let selector = String(argument.dropFirst(action.count)).trimmingCharacters(
        in: .whitespacesAndNewlines)
      guard !selector.isEmpty,
        let chat = resolveChat(selector, in: workspace)
      else {
        await terminal.line("Usage: /chat use INDEX|ID|TITLE")
        return
      }
      _ = workspace.selectChat(id: chat.id)
      session = REPLSession(chat: chat)
      await terminal.line("Switched to '\(chat.title)' (agent \(chat.primaryAgent.id)).")
    case "next", "previous", "prev":
      guard workspace.chats.count > 1,
        let current = workspace.chats.firstIndex(where: { $0.id == workspace.selectedChatID })
      else {
        await terminal.line("There is only one chat.")
        return
      }
      let offset = action == "next" ? 1 : -1
      let index = (current + offset + workspace.chats.count) % workspace.chats.count
      let chat = workspace.chats[index]
      _ = workspace.selectChat(id: chat.id)
      session = REPLSession(chat: chat)
      await terminal.line("Switched to '\(chat.title)' (agent \(chat.primaryAgent.id)).")
    case "rename":
      let title = String(argument.dropFirst(action.count)).trimmingCharacters(
        in: .whitespacesAndNewlines)
      guard !title.isEmpty else {
        await terminal.line("Usage: /chat rename TITLE")
        return
      }
      session.title = title
      session.touch()
      workspace.upsert(session.chat, selecting: true)
      await terminal.line("Chat renamed to '\(title)'.")
    case "close", "delete":
      guard parts.count == 2, parts[1].lowercased() == "confirm" else {
        await terminal.line("Closing a chat is permanent. Confirm with: /chat close confirm")
        return
      }
      guard workspace.chats.count > 1 else {
        await terminal.line("Cannot close the only chat; use /chat clear instead.")
        return
      }
      let oldTitle = session.title
      _ = workspace.removeChat(id: session.id)
      session = REPLSession(chat: workspace.selectedChat!)
      await terminal.line("Closed '\(oldTitle)'; switched to '\(session.title)'.")
    case "messages":
      await handleChatCommand("list", session: &session, terminal: terminal)
    case "log", "edit", "remove", "rm", "undo", "trim", "clear", "help":
      await handleChatCommand(argument, session: &session, terminal: terminal)
    default:
      await terminal.line("Unknown /chat action '\(action)'.\n\n\(chatHelp)")
    }
  }

  private static func resolveChat(
    _ selector: String,
    in workspace: AgentChatWorkspace
  ) -> AgentChat? {
    if let index = Int(selector), workspace.chats.indices.contains(index - 1) {
      return workspace.chats[index - 1]
    }
    if let id = UUID(uuidString: selector) {
      return workspace.chats.first { $0.id == id }
    }
    let idMatches = workspace.chats.filter {
      $0.id.uuidString.lowercased().hasPrefix(selector.lowercased())
    }
    if idMatches.count == 1 { return idMatches[0] }
    let titleMatches = workspace.chats.filter {
      $0.title.caseInsensitiveCompare(selector) == .orderedSame
    }
    return titleMatches.count == 1 ? titleMatches[0] : nil
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

  private static var defaultConfigurationPath: String {
    NSString(string: "~/.config/pmai/config.json").expandingTildeInPath
  }

  private static func resolvedStatePath(options: CLIOptions) -> String {
    NSString(string: options.statePath ?? "~/.config/pmai/chats.json").expandingTildeInPath
  }

  private static func resolvedHistoryPath(options: CLIOptions) -> String {
    NSString(string: options.historyPath ?? "~/.config/pmai/history.json").expandingTildeInPath
  }

  private static func loadChatWorkspace(
    from url: URL,
    initialProfile: SessionProfile
  ) throws -> AgentChatWorkspace {
    if FileManager.default.fileExists(atPath: url.path) {
      var workspace = try AgentChatWorkspace.load(from: url)
      if workspace.selectedChat != nil { return workspace }
      let chat = AgentChat(title: "Chat 1", primaryAgent: initialProfile.agentDefinition)
      workspace.upsert(chat, selecting: true)
      return workspace
    }
    let chat = AgentChat(title: "Chat 1", primaryAgent: initialProfile.agentDefinition)
    return AgentChatWorkspace(chats: [chat], selectedChatID: chat.id)
  }

  private static func saveWorkspace(
    _ workspace: AgentChatWorkspace,
    to url: URL,
    terminal: TerminalWriter
  ) async {
    do {
      try workspace.save(to: url)
    } catch {
      await terminal.line(
        "warning: chats were not saved: \(error.localizedDescription)",
        to: .standardError)
    }
  }

  private static func visualSnapshot(for workspace: AgentChatWorkspace) -> VisualWorkspaceSnapshot {
    let conversations = workspace.chats.map { chat in
      VisualConversationSeed(
        id: chat.id,
        title: chat.title,
        profile: chat.primaryAgent,
        messages: chat.messages,
        pendingContent: chat.pendingContent)
    }
    return VisualWorkspaceSnapshot(
      conversations: conversations,
      layout: PaneLayout(conversation: workspace.selectedChatID ?? conversations[0].id))
  }

  private static func chatWorkspace(
    from snapshot: VisualWorkspaceSnapshot,
    focusedID: UUID,
    previous: AgentChatWorkspace
  ) -> AgentChatWorkspace {
    let previousByID = Dictionary(uniqueKeysWithValues: previous.chats.map { ($0.id, $0) })
    let chats = snapshot.conversations.map { conversation in
      let old = previousByID[conversation.id]
      return AgentChat(
        id: conversation.id,
        title: conversation.title,
        primaryAgent: conversation.profile,
        messages: conversation.messages,
        pendingContent: conversation.pendingContent,
        createdAt: old?.createdAt ?? Date(),
        updatedAt: Date())
    }
    return AgentChatWorkspace(chats: chats, selectedChatID: focusedID)
  }

  private static func completionCandidates(
    workspace: AgentChatWorkspace,
    configuration: MaiConfiguration?
  ) -> [String] {
    var values = [
      "/help", "/exit", "/quit", "/set yolo on", "/set yolo off", "/plugins",
      "/providers", "/models ", "/provider ", "/model ", "/agents", "/agent use ",
      "/agent show ", "/agent add ", "/tools", "/proxy on", "/proxy off", "/mcps",
      "/image tiny ", "/image small ", "/image medium ", "/image big ", "/image full ",
      "/image ocr ", "/copy", "/visual", "/clear", "/chat list", "/chat new ",
      "/chat use ", "/chat next", "/chat previous", "/chat rename ",
      "/chat close confirm", "/chat messages", "/chat log", "/chat edit ",
      "/chat remove ", "/chat undo", "/chat trim ", "/chat clear",
    ]
    for (index, chat) in workspace.chats.enumerated() {
      values.append("/chat use \(index + 1)")
      values.append("/chat use \(chat.id.uuidString.prefix(8))")
      values.append("/chat use \(chat.title)")
    }
    for agent in configuration?.agents ?? [] {
      values.append("/agent use \(agent.id)")
      values.append("/agent show \(agent.id)")
      values.append("/chat new --agent \(agent.id) ")
    }
    for provider in configuration?.providers ?? [] {
      values.append("/provider \(provider.id)")
      values.append("/models \(provider.id)")
    }
    var groupNames = Set(workspace.chats.flatMap(\.primaryAgent.toolGroupNames))
    if configuration?.toolSources.contains(where: {
      $0.enabled && $0.kind == MaiStandardToolsPlugin.factoryKind
    }) == true {
      groupNames.formUnion(
        ["echo", "datetime", "calculator", "files", "weather", "web", "mastodon", "github"])
    }
    for group in groupNames {
      values.append("/tools show \(group)")
      values.append("/tools enable \(group)")
      values.append("/tools disable \(group)")
      values.append("/tools set \(group) ")
    }
    return Array(Set(values))
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
      FileManager.default.currentDirectoryPath + "/pmai.json",
      NSString(string: "~/.config/pmai/config.json").expandingTildeInPath,
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
        ConfiguredToolSource(id: "example-tools", kind: "example", enabled: false),
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
              MaiCalculatorTool.name,
              MaiCurrentTimeTool.name,
              MaiEchoTool.name,
              MaiReadTextFileTool.name,
              MaiWeatherTool.name,
              MaiWebSearchTool.name,
              MaiWebFetchTool.name,
              MaiMastodonTool.name,
            ] + MaiGitHubTool.toolNames),
          toolGroupNames: [
            "echo", "datetime", "calculator", "files", "weather", "web", "mastodon", "github",
          ],
          subagentNames: ["researcher"],
          useToolProxy: true),
        AgentDefinition(
          id: "researcher",
          instructions: "Investigate the delegated task and return a concise result.",
          provider: "openai",
          model: "your-model",
          toolNames: [MaiCurrentTimeTool.name],
          toolGroupNames: ["datetime"]),
      ],
      approvals: ConfiguredApprovals(confirm: .ask, dangerous: .ask))
  }

  private static let replHelp = """
    /set                List mutable session settings
    /set yolo BOOL      Permit all tool calls for this session (on/off)
    /plugins            List statically and dynamically loaded plugins
    /providers          List registered providers
    /models [PROVIDER]  List models from the current or named provider
    /provider ID        Select a provider
    /model NAME         Select a model
    /chat               Create, switch, rename, or edit persistent chats
    /agents             List configured agents
    /agent [use] ID     Set the current chat's primary agent
    /agent add ...      Persist a reusable agent and OpenAI-compatible endpoint
    /tools              List logical tool groups for the current agent
    /proxy [on|off]     Inspect or toggle the shared tool proxy
    /mcps               List connected MCP servers
    /image MODE PATH    Attach at tiny/small/medium/big/full size, or OCR to Markdown
    /copy [N]           Copy the last reply, or the last N messages, to the clipboard
    /visual             Open the terminal workspace: split chats, providers, MCPs, tools
    /clear              Clear conversation history
    /exit               Exit the REPL
    """

  private static let chatHelp = """
    Persistent chat management commands:
      /chat list                    List chats (index, ID, title, primary agent)
      /chat new [TITLE]             Create a chat using the current agent
      /chat new --agent ID [TITLE]  Create a chat using a configured agent
      /chat use INDEX|ID|TITLE      Switch the active chat
      /chat next|previous           Cycle through chats
      /chat rename TITLE            Rename the active chat
      /chat close confirm           Permanently close the active chat
      /chat messages                Display a compact indexed message list
      /chat log           Display the full structured conversation
      /chat edit N TEXT   Replace message N's text; preserve attachments
      /chat remove N      Remove message N
      /chat undo [N]      Remove the last conversation message or message N
      /chat trim N        Keep through message N and remove everything after it
      /chat clear         Clear the conversation and restore configured instructions

    Removing a tool call or result also removes its linked tool transaction.
    """

  private static let toolHelp = """
    Tool group commands:
      /tools list                    List logical tool groups
      /tools show GROUP              Show tools and configurable options
      /tools enable|disable GROUP    Change the current agent's allowed groups
      /tools set GROUP OPTION VALUE  Configure a tool group and reload its tools
      /tools unset GROUP OPTION      Restore an option's default

    Examples:
      /tools enable github
      /tools set mastodon mastodonInstance mastodon.social
      /tools set mastodon mastodonAPIKeyEnvironment MASTODON_API_KEY
      /tools set mastodon mastodonWriteEnabled on
    """

  private static func printUsage() {
    print(
      """
      mai — config-driven MaiCore agent CLI

      Usage:
        mai [options] [message]

      Options:
        --config PATH       load plugins, providers, tools, MCPs, agents, and approvals
        --state PATH        persist chat workspaces at this path (or PMAI_STATE)
        --history PATH      persist editable input history (or PMAI_HISTORY)
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
        --config, PMAI_CONFIG, ./pmai.json, ~/.config/pmai/config.json

      Persistent REPL state:
        ~/.config/pmai/chats.json and ~/.config/pmai/history.json

      Without a config file, the offline hello and OpenAI-compatible providers
      are registered as before.
      """)
  }
}
