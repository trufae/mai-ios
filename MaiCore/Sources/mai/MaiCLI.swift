import Foundation
import MaiCore
import MaiMarkdown
import MaiDocuments
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

@_silgen_name("system")
private func posixSystem(_ command: UnsafePointer<CChar>) -> CInt

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
  var maxToolCalls: Int?
  var maxModelTurns: Int?
  var maxSubagents: Int?
  var stream = true
  /// Render replies as markdown; nil follows the configuration and the tty.
  var markdown: Bool?
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
      case "--max-tool-calls":
        maxToolCalls = try Self.count(after: argument, in: arguments, index: &index)
      case "--max-turns", "--max-model-turns":
        maxModelTurns = try Self.count(after: argument, in: arguments, index: &index)
      case "--max-subagents":
        maxSubagents = try Self.count(after: argument, in: arguments, index: &index)
      case "--image":
        imagePaths.append(try Self.value(after: argument, in: arguments, index: &index))
      case "--plugin":
        pluginPaths.append(try Self.value(after: argument, in: arguments, index: &index))
      case "--no-stream":
        stream = false
      case "--markdown":
        markdown = true
      case "--no-markdown":
        markdown = false
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

  private static func count(
    after option: String,
    in arguments: [String],
    index: inout Int
  ) throws -> Int {
    let raw = try value(after: option, in: arguments, index: &index)
    guard let count = Int(raw), count >= 0 else { throw CLIError.invalidCount(option, raw) }
    return count
  }

  /// Applies command-line run limits on top of a configured agent.
  func applyLimitOverrides(to limits: inout AgentRunLimits) {
    if let maxToolCalls { limits.maxToolCalls = max(0, maxToolCalls) }
    if let maxModelTurns { limits.maxModelTurns = max(1, maxModelTurns) }
    if let maxSubagents { limits.maxSubagents = max(0, maxSubagents) }
  }
}

private enum CLIError: LocalizedError {
  case invalidURL(String)
  case missingValue(String)
  case unknownOption(String)
  case invalidCount(String, String)
  case configNotFound(String)
  case noProvider
  case invalidImage(String)

  var errorDescription: String? {
    switch self {
    case .invalidURL(let value): "Invalid URL: \(value)"
    case .missingValue(let option): "Missing value after \(option)."
    case .unknownOption(let option): "Unknown option: \(option)"
    case .invalidCount(let option, let value):
      "\(option) expects a non-negative integer, got '\(value)'."
    case .configNotFound(let path): "Configuration file not found: \(path)"
    case .noProvider: "No provider is configured."
    case .invalidImage(let path): "Unable to load image: \(path)"
    }
  }
}

private enum MCPCommandError: LocalizedError {
  case missingID
  case invalidID(String)
  case duplicateID(String)
  case missingCommand
  case missingOptionValue(String)
  case invalidOption(String)
  case invalidEnvironment
  case invalidTimeout
  case invalidApproval
  case unterminatedQuote
  case danglingEscape

  var errorDescription: String? {
    switch self {
    case .missingID: "Could not infer an MCP name from the command. Use --name ID."
    case .invalidID(let id):
      "Invalid MCP name '\(id)'. Start with a letter or number; "
        + "then use letters, numbers, '.', '_', or '-'."
    case .duplicateID(let id): "An MCP server named '\(id)' is already configured."
    case .missingCommand: "The stdio MCP command is missing."
    case .missingOptionValue(let option): "Missing value after \(option)."
    case .invalidOption(let option): "Unknown MCP option '\(option)'."
    case .invalidEnvironment: "--env expects KEY=VALUE."
    case .invalidTimeout: "--timeout expects a positive number of seconds."
    case .invalidApproval: "--approval expects automatic, confirm, or dangerous."
    case .unterminatedQuote: "The command contains an unterminated quote."
    case .danglingEscape: "The command ends with an incomplete escape."
    }
  }
}

private struct RuntimeSetup {
  var catalogs: [MCPServerCatalog]
  var implicitProviders: [ConfiguredProvider] = []
  var providerBaseURLs: [String: URL] = [:]
}

private func environmentValue(
  _ names: [String],
  in environment: [String: String]
) -> String? {
  names.lazy.compactMap { environment[$0] }.first { !$0.isEmpty }
}

private func environmentName(
  _ names: [String],
  in environment: [String: String]
) -> String? {
  names.first { environment[$0].map { !$0.isEmpty } ?? false }
}

/// What `/visual` needs beyond the REPL session itself.
private struct VisualBridge {
  var approvalHandler: TerminalApprovalHandler
  var configurationPath: String?
  var implicitProviders: [ConfiguredProvider]
  var providerBaseURLs: [String: URL]
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
      ] + MaiFileWorkspaceTool.toolNames + MaiRunTool.toolNames + MaiGitHubTool.toolNames)
    toolGroupNames = [
      "echo", "datetime", "calculator", "files", "run", "weather", "web", "mastodon", "github",
    ]
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
  /// Styles assistant markdown when set; nil prints replies verbatim.
  private var markdown: MarkdownTerminalRenderer?
  private var outputEndedLine = true
  private var toolResultLines = ConfiguredTerminalUI().toolResultLines
  private let colorsStatus: Bool

  init(capturesOutput: Bool = false) {
    self.capturesOutput = capturesOutput
    colorsStatus =
      !capturesOutput && isatty(STDERR_FILENO) != 0
      && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
  }

  func drainCaptured() -> String {
    let text = captured.joined()
    captured.removeAll()
    return text
  }

  /// Installs the renderer for replies. Captured output stays verbatim because
  /// it is shown by surfaces that do not interpret escape sequences.
  func configureMarkdown(_ renderer: MarkdownTerminalRenderer?) {
    markdown = capturesOutput ? nil : renderer
  }

  func configureToolResultLines(_ count: Int) {
    toolResultLines = max(0, count)
  }

  var markdownRenderer: MarkdownTerminalRenderer? { markdown }

  /// Renders a complete text the way replies are rendered.
  func render(_ text: String) -> String {
    markdown?.render(text) ?? text
  }

  func resetResponse() {
    wroteRootDelta = false
    rootLineOpen = false
    markdown?.reset()
  }

  func consume(_ event: AgentEvent) {
    switch event {
    case .modelStarted(let context, let turn) where context.depth == 0 && turn > 1:
      finishReply()
      closeRootLine()
    case .provider(let context, .textDelta(let text)) where context.depth == 0:
      if var renderer = markdown {
        let output = renderer.feed(text)
        markdown = renderer
        write(output)
      } else {
        write(text)
      }
      wroteRootDelta = true
      rootLineOpen = true
    case .toolStarted(let context, let call) where context.depth == 0:
      finishReply()
      closeRootLine()
      status("→ tool \(call.name) \(call.arguments.compactJSONString)", color: 32)
    case .toolFinished(let context, let result) where context.depth == 0:
      status(
        ToolResultPreview.render(result, maxLines: toolResultLines),
        color: result.isError ? 31 : 32)
    case .childStarted(_, let child):
      finishReply()
      closeRootLine()
      status("↳ child \(child.agentID) [\(child.runID.uuidString.prefix(8))]")
    case .childFinished(_, let child):
      status("↲ child \(child.agentID): \(child.response.text.prefix(100))")
    case .finished(let context, let result) where context.depth == 0:
      if wroteRootDelta {
        finishReply()
      } else {
        write(render(result.response.text))
      }
      closeRootLine(force: true)
    default:
      break
    }
  }

  func recoverAfterError(_ message: String) {
    finishReply()
    closeRootLine()
    status("error: \(message)")
  }

  func recoverAfterCancellation() {
    finishReply()
    closeRootLine()
    status("cancelled")
  }

  func prompt(_ value: String) { write(value) }

  func line(_ value: String = "", to handle: FileHandle = .standardOutput) {
    if capturesOutput {
      captured.append(value + "\n")
      return
    }
    handle.write(Data((value + "\n").utf8))
    if handle === FileHandle.standardOutput { outputEndedLine = true }
  }

  /// Writes what the markdown renderer still holds for the current reply.
  private func finishReply() {
    guard var renderer = markdown else { return }
    let output = renderer.flush()
    markdown = renderer
    write(output)
  }

  private func write(_ value: String) {
    guard !value.isEmpty else { return }
    outputEndedLine = value.hasSuffix("\n")
    if capturesOutput {
      captured.append(value)
      return
    }
    FileHandle.standardOutput.write(Data(value.utf8))
  }

  private func status(_ value: String, color: Int? = nil) {
    if capturesOutput {
      captured.append(value + "\n")
      return
    }
    let output: String
    if colorsStatus, let color {
      output = "\u{1B}[\(color)m\(value)\u{1B}[0m"
    } else {
      output = value
    }
    FileHandle.standardError.write(Data((output + "\n").utf8))
  }

  private func closeRootLine(force: Bool = false) {
    if (rootLineOpen || force) && !outputEndedLine {
      write("\n")
    }
    rootLineOpen = false
  }
}

private final class TerminalInterruptHandler: @unchecked Sendable {
  private let source: DispatchSourceSignal
  private let lock = NSLock()
  private var cancellation: (@Sendable () -> Void)?
  private var interrupted = false

  init() {
    signal(SIGINT, SIG_IGN)
    source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    source.setEventHandler { [weak self] in self?.interrupt() }
    source.resume()
  }

  deinit {
    source.cancel()
    signal(SIGINT, SIG_DFL)
  }

  func activate(cancellation: @escaping @Sendable () -> Void) {
    lock.withLock {
      interrupted = false
      self.cancellation = cancellation
    }
  }

  func deactivate() {
    lock.withLock { cancellation = nil }
  }

  func interruptedActiveOperation() -> Bool {
    lock.withLock { interrupted }
  }

  private func interrupt() {
    let action = lock.withLock { () -> (@Sendable () -> Void)? in
      guard let cancellation else { return nil }
      interrupted = true
      return cancellation
    }
    action?()
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
          "Approve \(request.tool.annotations.approval.rawValue) tool '\(request.tool.name)'?\nArguments: \(request.call.arguments.compactJSONString)\n"
            .utf8))
      let editor = TerminalLineEditor()
      editor.configure(
        ui: ConfiguredTerminalUI(backgroundLine: "", promptForeground: "yellow"))
      guard
        let answer = editor.readLine(
          prompt: "[y]es/[a]lways/[n]o/[e]dit/[c]ancel run: ", completions: [])?
          .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      else { return .deny(reason: "No approval response.") }
      if editor.wasInterrupted { throw CancellationError() }
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
      try await synchronizeToolGroupSelections(
        configuration: &configuration,
        configurationPath: configurationPath,
        plugins: plugins,
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
      let providerOverride =
        options.providerOverride
        ?? environmentValue(["PMAI_PROVIDER", "MAI_PROVIDER"], in: environment).map {
          ProviderID($0)
        }
      let modelOverride =
        options.modelOverride
        ?? environmentValue(["PMAI_MODEL", "MAI_MODEL", "OPENAI_MODEL"], in: environment)
      var workspace = try loadChatWorkspace(
        from: stateURL,
        initialProfile: profile,
        configuredAgents: configuration?.agents ?? [],
        providerOverride: providerOverride,
        modelOverride: modelOverride,
        options: options)
      var session = REPLSession(chat: workspace.selectedChat!)
      session.pendingContent.append(contentsOf: try options.imagePaths.map(imageContent))
      session.touch()
      workspace.upsert(session.chat, selecting: true)
      let terminal = TerminalWriter()
      await terminal.configureMarkdown(
        markdownRenderer(
          enabled: options.markdown ?? configuration?.ui.markdown ?? true,
          forced: options.markdown == true,
          environment: environment))
      await terminal.configureToolResultLines(
        configuration?.ui.toolResultLines ?? ConfiguredTerminalUI().toolResultLines)

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
          implicitProviders: setup.implicitProviders,
          providerBaseURLs: setup.providerBaseURLs),
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

  /// Tool names remain in the agent record for provider/runtime portability;
  /// group names let a host expand newly added plugin tools without requiring
  /// users to toggle an already enabled group off and on again.
  private static func synchronizeToolGroupSelections(
    configuration: inout MaiConfiguration?,
    configurationPath: String,
    plugins: PluginRegistry,
    environment: [String: String]
  ) async throws {
    guard var draft = configuration else { return }
    var toolsByGroup: [String: Set<String>] = [:]
    for source in draft.toolSources where source.enabled {
      for group in try await plugins.toolGroups(
        kind: source.kind,
        context: source.context(environment: environment))
      {
        toolsByGroup[group.id, default: []].formUnion(group.toolNames)
      }
    }
    var changed = false
    for index in draft.agents.indices {
      let previous = draft.agents[index].toolNames
      for groupName in draft.agents[index].toolGroupNames {
        draft.agents[index].toolNames.formUnion(toolsByGroup[groupName] ?? [])
      }
      changed = changed || previous != draft.agents[index].toolNames
    }
    guard changed else { return }
    try draft.save(to: URL(fileURLWithPath: configurationPath))
    configuration = draft
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
    let providerOverride =
      options.providerOverride
      ?? environmentValue(["PMAI_PROVIDER", "MAI_PROVIDER"], in: environment).map {
        ProviderID($0)
      }
    let rawBaseURL =
      options.baseURLOverride?.absoluteString
      ?? environmentValue(
        ["PMAI_BASE_URL", "MAI_BASE_URL", "OPENAI_BASE_URL"], in: environment)
    let baseURLOverride: URL?
    if let rawBaseURL {
      guard let url = URL(string: rawBaseURL) else { throw CLIError.invalidURL(rawBaseURL) }
      baseURLOverride = url
    } else {
      baseURLOverride = nil
    }
    let apiKeyOverride =
      options.apiKeyOverride
      ?? environmentValue(
        ["PMAI_API_KEY", "MAI_API_KEY", "OPENAI_API_KEY"], in: environment)

    if let configuration {
      let targetProviderID = providerOverride?.rawValue ?? ProviderID.openAI.rawValue
      var providerBaseURLs: [String: URL] = [:]
      for configuredProvider in configuration.providers {
        var provider = configuredProvider
        if provider.id == targetProviderID {
          if let baseURLOverride { provider.baseURL = baseURLOverride }
          if let apiKeyOverride {
            provider.apiKey = apiKeyOverride
            provider.apiKeyEnvironment = nil
          }
        }
        providerBaseURLs[provider.id] = provider.baseURL
        try await runtime.register(
          plugins.makeProvider(from: provider, environment: environment))
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
      for var agent in configuration.agents {
        agent.toolNames.formIntersection(knownTools)
        try await runtime.register(agent: agent)
      }
      return RuntimeSetup(catalogs: catalogs, providerBaseURLs: providerBaseURLs)
    }

    let hello = ConfiguredProvider(id: "hello", kind: .hello)
    try await runtime.register(plugins.makeProvider(from: hello, environment: environment))
    let baseURL = baseURLOverride ?? URL(string: "https://api.openai.com/v1")!
    let openAI = ConfiguredProvider(
      id: ProviderID.openAI.rawValue,
      kind: .openAICompatible,
      baseURL: baseURL,
      apiKey: apiKeyOverride)
    try await runtime.register(plugins.makeProvider(from: openAI, environment: environment))
    // The visual workspace drafts a configuration from these implicit providers.
    // It references the API key through its environment variable instead of
    // copying the secret into a file.
    var draft = openAI
    draft.apiKey = nil
    draft.apiKeyEnvironment = environmentName(
      ["PMAI_API_KEY", "MAI_API_KEY", "OPENAI_API_KEY"], in: environment)
    return RuntimeSetup(
      catalogs: [],
      implicitProviders: [hello, draft],
      providerBaseURLs: [openAI.id: baseURL])
  }

  private static func selectedProfile(
    configuration: MaiConfiguration?,
    options: CLIOptions,
    environment: [String: String]
  ) throws -> SessionProfile {
    let providerOverride =
      options.providerOverride
      ?? environmentValue(["PMAI_PROVIDER", "MAI_PROVIDER"], in: environment).map {
        ProviderID($0)
      }
    let modelOverride =
      options.modelOverride
      ?? environmentValue(["PMAI_MODEL", "MAI_MODEL", "OPENAI_MODEL"], in: environment)
    if let configuration, !configuration.agents.isEmpty {
      let selectedID =
        options.agentOverride ?? configuration.defaultAgent
        ?? configuration.agents.first?.id
      guard let definition = configuration.agents.first(where: { $0.id == selectedID }) else {
        throw MaiConfigurationError.unknownAgent(selectedID ?? "")
      }
      var profile = SessionProfile(definition: definition)
      if let providerOverride { profile.provider = providerOverride }
      if let modelOverride { profile.model = modelOverride }
      if let system = options.systemOverride { profile.instructions = system }
      profile.stream = options.stream && profile.stream
      options.applyLimitOverrides(to: &profile.limits)
      return profile
    }
    var profile = SessionProfile(
      provider: providerOverride ?? "hello",
      model: modelOverride ?? "",
      instructions: options.systemOverride ?? "You are a helpful, concise assistant.",
      stream: options.stream)
    options.applyLimitOverrides(to: &profile.limits)
    return profile
  }

  /// A renderer for replies on this terminal, or nil to print them verbatim.
  /// Output that is not a terminal stays verbatim unless rendering is forced.
  private static func markdownRenderer(
    enabled: Bool,
    forced: Bool,
    environment: [String: String]
  ) -> MarkdownTerminalRenderer? {
    guard enabled, forced || isatty(STDOUT_FILENO) != 0 else { return nil }
    let detected = MarkdownTerminalEnvironment.detect(environment)
    return MarkdownTerminalRenderer(
      theme: detected.theme,
      options: MarkdownLayoutOptions(
        width: TerminalLineEditor.terminalColumns(), unicode: detected.unicode),
      widthProvider: { TerminalLineEditor.terminalColumns() })
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
    let interruptHandler = TerminalInterruptHandler()
    await terminal.line("pmai — MaiCore agent REPL")
    await terminal.line(
      "Type /help for commands. Chat: \(session.title); agent: \(session.profile.agentID)")

    while true {
      let ui = configuration?.ui ?? .init()
      editor.configure(ui: ui)
      await terminal.configureToolResultLines(ui.toolResultLines)
      let promptStatus =
        "\(session.title) · agent: \(session.profile.agentID) · \(promptContextStatus(session))"
      guard
        let input = editor.readLine(
          prompt: "pmai> ",
          completions: completionCandidates(
            workspace: workspace,
            configuration: configuration),
          separator: promptStatus)
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
            runtime: runtime,
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
      _ = await submit(
        text,
        session: &session,
        runtime: runtime,
        terminal: terminal,
        interruptHandler: interruptHandler)
      session.touch()
      workspace.upsert(session.chat, selecting: true)
      await saveWorkspace(workspace, to: stateURL, terminal: terminal)
    }
  }

  private static func submit(
    _ text: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    terminal: TerminalWriter,
    interruptHandler: TerminalInterruptHandler? = nil
  ) async -> Bool {
    var content: [ContentPart] = [.text(text)]
    content.append(contentsOf: session.pendingContent)
    session.pendingContent.removeAll()
    session.history.append(AgentMessage(role: .user, content: content))
    await terminal.resetResponse()
    do {
      let profile = session.profile
      let request = AgentRequest(
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
      let task = Task {
        try await runtime.run(request) { event in
          await terminal.consume(event)
        }
      }
      interruptHandler?.activate { task.cancel() }
      defer { interruptHandler?.deactivate() }
      let result = try await task.value
      session.history.replaceAll(with: result.transcript)
      return true
    } catch {
      if error is CancellationError || interruptHandler?.interruptedActiveOperation() == true {
        await terminal.recoverAfterCancellation()
        return false
      }
      await terminal.recoverAfterError(error.localizedDescription)
      return false
    }
  }

  /// A fast, deliberately approximate context indicator. Providers tokenize
  /// differently and do not all expose their context-window size, so showing
  /// an estimate is more honest than implying an exact percentage.
  private static func promptContextStatus(_ session: REPLSession) -> String {
    let characters = session.history.messages.reduce(0) { total, message in
      total + message.content.reduce(0) { $0 + renderFullContent($1).utf8.count }
    }
    let estimatedTokens = (characters + 2) / 3
    let messageLabel = "\(session.history.count) msg"
    return "\(messageLabel) · ~\(compactTokenCount(estimatedTokens)) tok"
  }

  private static func compactTokenCount(_ count: Int) -> String {
    guard count >= 1_000 else { return String(count) }
    let tenths = (count + 50) / 100
    return "\(tenths / 10).\(tenths % 10)k"
  }

  private static func changeWorkingDirectory(_ argument: String, terminal: TerminalWriter) async {
    let path = argument.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else {
      await terminal.line("Usage: /cd PATH")
      return
    }
    let expanded = NSString(string: path).expandingTildeInPath
    let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let target = URL(fileURLWithPath: expanded, relativeTo: current).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      await terminal.line("error: Not a directory: \(target.path)", to: .standardError)
      return
    }
    guard FileManager.default.changeCurrentDirectoryPath(target.path) else {
      await terminal.line("error: Could not change directory to \(target.path)", to: .standardError)
      return
    }
    await terminal.line(FileManager.default.currentDirectoryPath)
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
    case "/cwd", "/pwd":
      await terminal.line(FileManager.default.currentDirectoryPath)
    case "/cd":
      await changeWorkingDirectory(argument, terminal: terminal)
    case "/set":
      await handleSetCommand(
        argument,
        session: &session,
        runtime: runtime,
        approvalHandler: visual.approvalHandler,
        configuration: &configuration,
        configurationPath: visual.configurationPath,
        terminal: terminal)
    case "/providers":
      for provider in await runtime.availableProviders() {
        let selected = provider.id == session.profile.provider ? "*" : " "
        let baseURL =
          (configuration?.providers.first { $0.id == provider.id.rawValue }?.baseURL
          ?? visual.providerBaseURLs[provider.id.rawValue])
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
      await handleChatCommand(argument, session: &session, runtime: runtime, terminal: terminal)
    case "/edit":
      await handleEditCommand(
        argument,
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: visual.configurationPath,
        terminal: terminal)
    case "/provider":
      await handleProviderCommand(
        argument,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: visual.configurationPath,
        terminal: terminal)
    case "/baseurl":
      await handleBaseURLCommand(
        argument,
        currentProvider: session.profile.provider,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: visual.configurationPath,
        terminal: terminal)
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
        let displayedAgent = selected == "*" ? session.profile.agentDefinition : agent
        let baseURL =
          configuration?.providers.first { $0.id == displayedAgent.provider.rawValue }?.baseURL?
          .absoluteString
          ?? visual.providerBaseURLs[displayedAgent.provider.rawValue]?.absoluteString ?? "-"
        await terminal.line(
          "\(selected) \(displayedAgent.id) — \(displayedAgent.displayName) [\(displayedAgent.provider) \(baseURL) \(displayedAgent.model)]"
        )
      }
    case "/agent":
      await handleAgentCommand(
        argument,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: visual.configurationPath,
        providerBaseURLs: visual.providerBaseURLs,
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
    case "/mcp":
      await handleMCPCommand(
        argument,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: visual.configurationPath,
        catalogs: &catalogs,
        terminal: terminal)
    case "/mcps":
      await handleMCPCommand(
        "list",
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: visual.configurationPath,
        catalogs: &catalogs,
        terminal: terminal)
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
    case "/attach":
      await attachDocument(
        argument, session: &session, ocrProvider: ocrProvider, terminal: terminal)
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

  private static func handleMCPCommand(
    _ argument: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    catalogs: inout [MCPServerCatalog],
    terminal: TerminalWriter
  ) async {
    let pieces = argument.split(
      maxSplits: 1, whereSeparator: \Character.isWhitespace
    ).map(String.init)
    let action = pieces.first?.lowercased() ?? "list"
    switch action {
    case "", "list":
      let configured = configuration?.mcpServers ?? []
      let connected = Dictionary(uniqueKeysWithValues: catalogs.map { ($0.serverID, $0) })
      if configured.isEmpty, catalogs.isEmpty {
        await terminal.line("No configured MCP servers.")
        return
      }
      for server in configured {
        let transport =
          server.kind == "stdio"
          ? server.command ?? "stdio" : server.url?.absoluteString ?? server.kind
        let state: String
        if !server.enabled {
          state = "disabled"
        } else if let catalog = connected[server.id] {
          state =
            "connected — \(catalog.tools.count) tools, \(catalog.resources.count) resources, MCP \(catalog.protocolVersion)"
        } else {
          state = "not connected"
        }
        await terminal.line("\(server.id) — \(transport) [\(state)]")
      }
      let configuredIDs = Set(configured.map(\.id))
      for catalog in catalogs where !configuredIDs.contains(catalog.serverID) {
        await terminal.line(
          "\(catalog.serverID) — \(catalog.tools.count) tools, \(catalog.resources.count) resources, MCP \(catalog.protocolVersion) [connected]"
        )
      }

    case "add":
      guard let rawAddArguments = pieces.dropFirst().first else {
        await terminal.line(mcpCommandHelp)
        return
      }
      guard var draft = configuration, let configurationPath else {
        await terminal.line("error: No writable configuration is active.", to: .standardError)
        return
      }
      do {
        let server = try parseStdioMCPAddArguments(rawAddArguments)
        guard !draft.mcpServers.contains(where: { $0.id == server.id }) else {
          throw MCPCommandError.duplicateID(server.id)
        }
        let source = try await plugins.makeMCPToolSource(
          kind: server.kind,
          configuration: server,
          environment: ProcessInfo.processInfo.environment)
        let toolsBefore = Set(await runtime.availableTools().map(\.name))
        let catalog = try await runtime.register(mcp: source)
        let addedTools = Set(await runtime.availableTools().map(\.name)).subtracting(toolsBefore)

        draft.mcpServers.append(server)
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        configuration = draft
        catalogs.append(catalog)
        await terminal.line(
          "Added and connected stdio MCP '\(server.id)'; enabled all \(addedTools.count) tools for every agent."
        )
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }

    case "enable":
      guard pieces.count == 2 else {
        await terminal.line(mcpCommandHelp)
        return
      }
      let id = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
      guard var draft = configuration, let configurationPath,
        let serverIndex = draft.mcpServers.firstIndex(where: { $0.id == id })
      else {
        await terminal.line("error: MCP server '\(id)' is not configured.", to: .standardError)
        return
      }
      if catalogs.contains(where: { $0.serverID == id }) {
        await terminal.line("MCP server '\(id)' is already enabled and connected.")
        return
      }
      do {
        var server = draft.mcpServers[serverIndex]
        server.enabled = true
        let source = try await plugins.makeMCPToolSource(
          kind: server.kind,
          configuration: server,
          environment: ProcessInfo.processInfo.environment)
        let toolsBefore = Set(await runtime.availableTools().map(\.name))
        let catalog = try await runtime.register(mcp: source)
        let addedTools = Set(await runtime.availableTools().map(\.name)).subtracting(toolsBefore)
        draft.mcpServers[serverIndex] = server
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        configuration = draft
        catalogs.append(catalog)
        await terminal.line(
          "Enabled and connected MCP '\(id)'; enabled all \(addedTools.count) tools for every agent."
        )
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }

    case "disable":
      guard pieces.count == 2 else {
        await terminal.line(mcpCommandHelp)
        return
      }
      let id = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
      guard var draft = configuration, let configurationPath,
        let serverIndex = draft.mcpServers.firstIndex(where: { $0.id == id })
      else {
        await terminal.line("error: MCP server '\(id)' is not configured.", to: .standardError)
        return
      }
      if !draft.mcpServers[serverIndex].enabled {
        await terminal.line("MCP server '\(id)' is already disabled.")
        return
      }
      let namespace = mcpNamespace(for: draft.mcpServers[serverIndex])
      let registeredTools = Set(await runtime.availableTools().map(\.name))
      let removedTools = registeredTools.filter { $0.hasPrefix("\(namespace)::") }
      draft.mcpServers[serverIndex].enabled = false
      for index in draft.agents.indices {
        draft.agents[index].toolNames.subtract(removedTools)
      }
      var profile = session.profile
      profile.toolNames.subtract(removedTools)
      do {
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        _ = await runtime.unregisterMCP(serverID: id)
        for agent in draft.agents {
          try await runtime.register(agent: agent, replacingExisting: true)
        }
        session.profile = profile
        configuration = draft
        catalogs.removeAll { $0.serverID == id }
        await terminal.line("Disabled MCP '\(id)' and removed \(removedTools.count) live tools.")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }

    default:
      await terminal.line(mcpCommandHelp)
    }
  }

  private static func mcpNamespace(for server: ConfiguredMCPServer) -> String {
    let prefix = server.toolNamePrefix?.trimmingCharacters(in: .whitespacesAndNewlines)
    return prefix.flatMap { $0.isEmpty ? nil : $0 } ?? server.id
  }

  private static func parseStdioMCPAddArguments(_ arguments: String) throws
    -> ConfiguredMCPServer
  {
    let words = try shellWords(arguments)
    guard !words.isEmpty else { throw MCPCommandError.missingCommand }
    var environment: [String: String] = [:]
    var workingDirectory: String?
    var timeout: TimeInterval?
    var prefix: String?
    var approval = ToolApprovalRequirement.confirm
    var id: String?
    let separatorIndex = words.firstIndex(of: "--")
    let optionWords: ArraySlice<String>
    let commandWords: ArraySlice<String>
    if let separatorIndex {
      var optionsStart = words.startIndex
      if optionsStart < separatorIndex, !words[optionsStart].hasPrefix("-") {
        id = words[optionsStart]
        optionsStart += 1
      }
      optionWords = words[optionsStart..<separatorIndex]
      commandWords = words[words.index(after: separatorIndex)...]
    } else {
      optionWords = []
      commandWords = words[...]
    }

    var index = optionWords.startIndex
    while index < optionWords.endIndex {
      switch optionWords[index] {
      case "--name":
        index += 1
        guard index < optionWords.endIndex else {
          throw MCPCommandError.missingOptionValue("--name")
        }
        id = optionWords[index]
        index += 1
      case "--env":
        index += 1
        guard index < optionWords.endIndex,
          let separator = optionWords[index].firstIndex(of: "="),
          separator != optionWords[index].startIndex
        else { throw MCPCommandError.invalidEnvironment }
        environment[String(optionWords[index][..<separator])] = String(
          optionWords[index][optionWords[index].index(after: separator)...])
        index += 1
      case "--cwd":
        index += 1
        guard index < optionWords.endIndex else {
          throw MCPCommandError.missingOptionValue("--cwd")
        }
        workingDirectory = optionWords[index]
        index += 1
      case "--timeout":
        index += 1
        guard index < optionWords.endIndex,
          let value = TimeInterval(optionWords[index]), value > 0
        else {
          throw MCPCommandError.invalidTimeout
        }
        timeout = value
        index += 1
      case "--prefix":
        index += 1
        guard index < optionWords.endIndex else {
          throw MCPCommandError.missingOptionValue("--prefix")
        }
        prefix = optionWords[index]
        index += 1
      case "--approval":
        index += 1
        guard index < optionWords.endIndex,
          let value = ToolApprovalRequirement(rawValue: optionWords[index].lowercased())
        else { throw MCPCommandError.invalidApproval }
        approval = value
        index += 1
      default:
        throw MCPCommandError.invalidOption(optionWords[index])
      }
    }
    guard let command = commandWords.first, !command.isEmpty else {
      throw MCPCommandError.missingCommand
    }
    let inferredID = URL(fileURLWithPath: command).lastPathComponent
    let resolvedID = id ?? inferredID
    guard !resolvedID.isEmpty else { throw MCPCommandError.missingID }
    guard isValidMCPID(resolvedID) else { throw MCPCommandError.invalidID(resolvedID) }
    return ConfiguredMCPServer(
      id: resolvedID,
      kind: "stdio",
      command: command,
      args: Array(commandWords.dropFirst()),
      env: environment,
      cwd: workingDirectory,
      timeout: timeout,
      toolNamePrefix: prefix,
      defaultApproval: approval)
  }

  private static func isValidMCPID(_ id: String) -> Bool {
    guard id != ".", id != "..",
      id.first.map({ $0.isLetter || $0.isNumber }) == true
    else {
      return false
    }
    return id.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
  }

  private static func shellWords(_ input: String) throws -> [String] {
    enum Quote { case single, double }
    var words: [String] = []
    var word = ""
    var quote: Quote?
    var escaped = false
    var started = false
    for character in input {
      if escaped {
        word.append(character)
        escaped = false
        started = true
        continue
      }
      if character == "\\", quote != .single {
        escaped = true
        started = true
        continue
      }
      if character == "'", quote != .double {
        quote = quote == .single ? nil : .single
        started = true
        continue
      }
      if character == "\"", quote != .single {
        quote = quote == .double ? nil : .double
        started = true
        continue
      }
      if character.isWhitespace, quote == nil {
        if started {
          words.append(word)
          word = ""
          started = false
        }
        continue
      }
      word.append(character)
      started = true
    }
    guard quote == nil else { throw MCPCommandError.unterminatedQuote }
    guard !escaped else { throw MCPCommandError.danglingEscape }
    if started { words.append(word) }
    return words
  }

  /// Opens a text value from the active REPL session in the user's terminal
  /// editor. Transcript and configuration edits deliberately go through the
  /// same core types used by the iOS app and the persistent chat workspace.
  private static func handleEditCommand(
    _ argument: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    let target = argument.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else {
      await terminal.line(editHelp)
      return
    }

    switch target.lowercased() {
    case "prompt", "system":
      let previousInstructions = session.profile.instructions
      guard let edited = await editTemporaryText(
        previousInstructions, suffix: "prompt.txt", terminal: terminal)
      else { return }
      session.profile.instructions = edited.trimmingCharacters(in: .whitespacesAndNewlines)
      if let index = session.history.messages.firstIndex(where: {
        $0.role == .system && $0.text == previousInstructions
      }) {
        do {
          if session.profile.instructions.isEmpty {
            _ = try session.history.removeMessage(at: index)
          } else {
            try session.history.editMessage(at: index, text: session.profile.instructions)
          }
        } catch {
          await terminal.line("error: \(error.localizedDescription)", to: .standardError)
          return
        }
      } else if !session.profile.instructions.isEmpty {
        session.history.replaceAll(with: [.system(session.profile.instructions)] + session.history.messages)
      }
      if await persistAgentProfile(
        session: session,
        configuration: &configuration,
        configurationPath: configurationPath,
        runtime: runtime,
        terminal: terminal)
      {
        await terminal.line("System prompt updated.")
      }

    case "config":
      guard let configurationPath else {
        await terminal.line("error: No writable configuration is active.", to: .standardError)
        return
      }
      let url = URL(fileURLWithPath: configurationPath)
      guard await launchEditor(at: url, terminal: terminal) else { return }
      do {
        let editedConfiguration = try MaiConfiguration.load(from: url)
        for agent in editedConfiguration.agents {
          try await runtime.register(agent: agent, replacingExisting: true)
        }
        if let agent = editedConfiguration.agents.first(where: {
          $0.id == session.profile.agentID
        }) {
          session.profile.limits = agent.limits
          session.profile.toolCallingStrategy = agent.toolCallingStrategy
          session.touch()
        }
        configuration = editedConfiguration
        await terminal.line(
          "Configuration saved. Agent limits and tool-calling strategy were applied; "
            + "restart pmai to apply provider, plugin, tool, or MCP changes.")
      } catch {
        await terminal.line("error: The edited configuration was not loaded: \(error.localizedDescription)", to: .standardError)
      }

    case "mcps", "mcp":
      guard var draft = configuration, let configurationPath else {
        await terminal.line("error: No writable configuration is active.", to: .standardError)
        return
      }
      do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(draft.mcpServers)
        guard let edited = await editTemporaryData(data, suffix: "mcps.json", terminal: terminal) else {
          return
        }
        draft.mcpServers = try JSONDecoder().decode([ConfiguredMCPServer].self, from: edited)
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        configuration = draft
        await terminal.line("MCP configuration saved. Restart pmai to reconnect MCP servers.")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }

    default:
      guard let index = editableMessageIndex(target, in: session.history) else {
        await terminal.line("Unknown edit target '\(target)'.\n\n\(editHelp)")
        return
      }
      let message = session.history[index]
      guard let edited = await editTemporaryText(message.text, suffix: "message.md", terminal: terminal)
      else { return }
      do {
        try session.history.editMessage(at: index, text: edited)
        await terminal.line("Edited message \(index + 1) (id: \(message.id)).")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
    }
  }

  private static func editableMessageIndex(_ target: String, in transcript: AgentTranscript) -> Int? {
    if let index = chatIndex(target, count: transcript.count) { return index }
    return transcript.index(ofMessageID: target)
  }

  private static func editTemporaryText(
    _ text: String, suffix: String, terminal: TerminalWriter
  ) async -> String? {
    guard let data = text.data(using: .utf8),
      let edited = await editTemporaryData(data, suffix: suffix, terminal: terminal)
    else { return nil }
    guard let result = String(data: edited, encoding: .utf8) else {
      await terminal.line("error: Editor output must be UTF-8 text.", to: .standardError)
      return nil
    }
    return result
  }

  private static func editTemporaryData(
    _ data: Data, suffix: String, terminal: TerminalWriter
  ) async -> Data? {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("pmai-edit-\(UUID().uuidString)-\(suffix)")
    do {
      try data.write(to: url, options: .atomic)
      defer { try? FileManager.default.removeItem(at: url) }
      guard await launchEditor(at: url, terminal: terminal) else { return nil }
      return try Data(contentsOf: url)
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      return nil
    }
  }

  private static func launchEditor(at url: URL, terminal: TerminalWriter) async -> Bool {
    let environment = ProcessInfo.processInfo.environment
    let preferredEditor = environment["EDITOR"] ?? environment["VISUAL"] ?? "vim"
    let editor = preferredEditor.trimmingCharacters(in: .whitespacesAndNewlines)
    let command = editor.isEmpty ? "vim" : editor
    FileHandle.standardOutput.synchronizeFile()
    FileHandle.standardError.synchronizeFile()
    let shellCommand = "\(command) \(shellQuote(url.path))"
    let waitStatus = shellCommand.withCString(posixSystem)
    guard waitStatus != -1 else {
      await terminal.line(
        "error: Could not launch editor '\(command)': \(String(cString: strerror(errno)))",
        to: .standardError)
      return false
    }
    let exitStatus = waitStatus & 0x7f == 0 ? (waitStatus >> 8) & 0xff : 128 + (waitStatus & 0x7f)
    guard exitStatus == 0 else {
      await terminal.line(
        "error: Editor exited with status \(exitStatus).", to: .standardError)
      return false
    }
    return true
  }

  private static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
  }

  private static func handleProviderCommand(
    _ argument: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(whereSeparator: \Character.isWhitespace).map(String.init)
    guard !fields.isEmpty else {
      let baseURL =
        configuration?.providers.first {
          $0.id == session.profile.provider.rawValue
        }?.baseURL?.absoluteString ?? "-"
      await terminal.line("Current provider: \(session.profile.provider) — \(baseURL)")
      await terminal.line("Use /baseurl URL to change its endpoint.")
      return
    }

    if ["baseurl", "url"].contains(fields[0].lowercased()) {
      await handleBaseURLCommand(
        fields.dropFirst().joined(separator: " "),
        currentProvider: session.profile.provider,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
      return
    }

    let selectedID = fields[0].lowercased() == "use" && fields.count == 2 ? fields[1] : fields[0]
    let id = ProviderID(selectedID)
    guard await runtime.availableProviders().contains(where: { $0.id == id }) else {
      await terminal.line("Unknown provider '\(selectedID)'. Use /providers.")
      return
    }
    session.profile.provider = id
    let saved = await persistAgentProfile(
      session: session,
      configuration: &configuration,
      configurationPath: configurationPath,
      runtime: runtime,
      terminal: terminal)
    if saved {
      await terminal.line("Provider: \(id) (saved for agent \(session.profile.agentID))")
    }
  }

  private static func handleBaseURLCommand(
    _ argument: String,
    currentProvider: ProviderID,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(whereSeparator: \Character.isWhitespace).map(String.init)
    guard !fields.isEmpty else {
      let baseURL =
        configuration?.providers.first {
          $0.id == currentProvider.rawValue
        }?.baseURL?.absoluteString ?? "-"
      await terminal.line("Base URL for '\(currentProvider)': \(baseURL)")
      await terminal.line("Usage: /baseurl URL")
      return
    }

    guard fields.count == 1 else {
      await terminal.line("Usage: /baseurl URL")
      return
    }
    let providerID = currentProvider
    let rawURL = fields[0]
    guard let baseURL = URL(string: rawURL),
      ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""),
      baseURL.host != nil
    else {
      await terminal.line("Invalid provider URL '\(rawURL)'; use an http:// or https:// URL.")
      return
    }
    guard var draft = configuration,
      let index = draft.providers.firstIndex(where: { $0.id == providerID.rawValue })
    else {
      await terminal.line("Unknown configured provider '\(providerID)'. Use /providers.")
      return
    }
    guard let configurationPath else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return
    }
    draft.providers[index].baseURL = baseURL
    do {
      let provider = try await plugins.makeProvider(
        from: draft.providers[index],
        environment: ProcessInfo.processInfo.environment)
      try await runtime.register(provider, replacingExisting: true)
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      configuration = draft
      await terminal.line("Provider '\(providerID)' base URL set to \(baseURL.absoluteString).")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  private static func handleAgentCommand(
    _ argument: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    providerBaseURLs: [String: URL],
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(maxSplits: 5, whereSeparator: \Character.isWhitespace).map(
      String.init)
    guard let action = fields.first?.lowercased() else {
      await showAgent(
        session.profile.agentID,
        session: session,
        configuration: configuration,
        providerBaseURLs: providerBaseURLs,
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
        providerBaseURLs: providerBaseURLs,
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
    providerBaseURLs: [String: URL],
    terminal: TerminalWriter
  ) async {
    let definition =
      session.profile.agentID == id
      ? session.profile.agentDefinition : configuration?.agents.first(where: { $0.id == id })
    guard let definition else {
      await terminal.line("Unknown agent '\(id)'. Use /agents.")
      return
    }
    let baseURL =
      configuration?.providers.first { $0.id == definition.provider.rawValue }?.baseURL
      ?? providerBaseURLs[definition.provider.rawValue]
    await terminal.line("Agent: \(definition.id) (\(definition.displayName))")
    await terminal.line("Provider: \(definition.provider)")
    await terminal.line("Base URL: \(baseURL?.absoluteString ?? "-")")
    await terminal.line("Model: \(definition.model.isEmpty ? "-" : definition.model)")
    await terminal.line("Tool calling: \(definition.toolCallingStrategy.rawValue)")
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
    if let integer = value.intValue { return String(integer) }
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
    session: inout REPLSession,
    runtime: AgentRuntime,
    approvalHandler: TerminalApprovalHandler,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    let parts = argument.replacingOccurrences(of: "=", with: " ")
      .split(whereSeparator: \Character.isWhitespace)
      .map(String.init)
    guard !parts.isEmpty else {
      let enabled = await approvalHandler.isYOLOEnabled()
      await terminal.line("yolo = \(enabled ? "on" : "off")")
      await listLimitSettings(session.profile.limits, terminal: terminal)
      await terminal.line("toolCallingStrategy = \(session.profile.toolCallingStrategy.rawValue)")
      await listUISettings(configuration?.ui ?? .init(), terminal: terminal)
      return
    }
    let key = parts[0].lowercased()
    let displayedKey = key == "ui.toolresultlines" ? "ui.toolResultLines" : key
    if key == "ui" || key == "ui." {
      await listUISettings(configuration?.ui ?? .init(), terminal: terminal)
      return
    }
    if key == "limits" || key == "limits." {
      await listLimitSettings(session.profile.limits, terminal: terminal)
      return
    }
    if let limitKey = limitSettingKeys[key] {
      await setLimit(
        limitKey,
        parts: parts,
        session: &session,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
      return
    }
    if toolCallingStrategyKeys.contains(key) {
      await setToolCallingStrategy(
        parts: parts,
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
      return
    }
    if key == "yolo" {
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
      return
    }

    let colorKeys = ["ui.bgline", "ui.fgcolor", "ui.bgcolor", "ui.fgprompt", "ui.bgprompt"]
    let booleanKeys = ["ui.bold", "ui.markdown"]
    let countKeys = ["ui.toolresultlines"]
    guard colorKeys.contains(key) || booleanKeys.contains(key) || countKeys.contains(key) else {
      await terminal.line(
        "Unknown setting '\(parts[0])'. Available settings: yolo, toolCallingStrategy, limits.maxToolCalls, limits.maxModelTurns, limits.maxSubagents, ui.bgline, ui.fgcolor, ui.bgcolor, ui.fgprompt, ui.bgprompt, ui.bold, ui.markdown, ui.toolResultLines"
      )
      return
    }
    var ui = configuration?.ui ?? .init()
    guard parts.count > 1 else {
      await terminal.line("\(displayedKey) = \(uiSetting(key, in: ui))")
      return
    }
    guard parts.count == 2 else {
      await terminal.line("Usage: /set \(key) VALUE")
      return
    }
    if countKeys.contains(key) {
      guard let value = Int(parts[1]), value >= 0 else {
        await terminal.line("Usage: /set ui.toolResultLines N  (a non-negative integer)")
        return
      }
      ui.toolResultLines = value
      await terminal.configureToolResultLines(value)
    } else if booleanKeys.contains(key) {
      guard let enabled = booleanSetting(parts[1]) else {
        await terminal.line("Usage: /set \(key) <on|off>")
        return
      }
      if key == "ui.bold" {
        ui.bold = enabled
      } else {
        ui.markdown = enabled
        await terminal.configureMarkdown(
          markdownRenderer(
            enabled: enabled, forced: false, environment: ProcessInfo.processInfo.environment))
      }
    } else {
      guard let color = TerminalLineEditor.normalizedColor(parts[1]) else {
        await terminal.line(
          "Unknown color '\(parts[1])'. Use a named ANSI color, rgb:RGB, or none.")
        return
      }
      switch key {
      case "ui.bgline": ui.backgroundLine = color
      case "ui.fgcolor": ui.foreground = color
      case "ui.bgcolor": ui.background = color
      case "ui.fgprompt": ui.promptForeground = color
      case "ui.bgprompt": ui.promptBackground = color
      default: break
      }
    }
    guard var draft = configuration, let configurationPath else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return
    }
    draft.ui = ui
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      configuration = draft
      await terminal.line("Set \(displayedKey) = \(uiSetting(key, in: ui)).")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  /// Lowercased `/set` keys mapped to their canonical spelling.
  private static let limitSettingKeys = [
    "limits.maxtoolcalls": "limits.maxToolCalls",
    "limits.maxmodelturns": "limits.maxModelTurns",
    "limits.maxsubagents": "limits.maxSubagents",
  ]

  private static let toolCallingStrategyKeys: Set<String> = [
    "toolcallingstrategy", "toolcallingmode", "toolcalling", "tools.mode",
  ]

  private static func setToolCallingStrategy(
    parts: [String],
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard parts.count > 1 else {
      await terminal.line("toolCallingStrategy = \(session.profile.toolCallingStrategy.rawValue)")
      return
    }
    let rawValue = parts[1].lowercased()
    let strategy =
      rawValue == "auto" ? ToolCallingStrategy.automatic : ToolCallingStrategy(rawValue: rawValue)
    guard parts.count == 2, let strategy else {
      await terminal.line(
        "Usage: /set toolCallingStrategy <automatic|native|text|xml|json>")
      return
    }
    session.profile.toolCallingStrategy = strategy
    session.touch()
    guard var draft = configuration, let configurationPath,
      let index = draft.agents.firstIndex(where: { $0.id == session.profile.agentID })
    else {
      await terminal.line("Set toolCallingStrategy = \(strategy.rawValue) for this chat.")
      return
    }
    draft.agents[index].toolCallingStrategy = strategy
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      try await runtime.register(agent: session.profile.agentDefinition, replacingExisting: true)
      configuration = draft
      await terminal.line(
        "Set toolCallingStrategy = \(strategy.rawValue) for agent '\(session.profile.agentID)'.")
    } catch {
      await terminal.line(
        "Set toolCallingStrategy = \(strategy.rawValue) for this chat; could not save the configuration: \(error.localizedDescription)",
        to: .standardError)
    }
  }

  private static func listLimitSettings(_ limits: AgentRunLimits, terminal: TerminalWriter) async {
    await terminal.line("limits.maxToolCalls = \(limits.maxToolCalls)")
    await terminal.line("limits.maxModelTurns = \(limits.maxModelTurns)")
    await terminal.line("limits.maxSubagents = \(limits.maxSubagents)")
  }

  /// Changes one run limit for the current chat and, when the chat uses a
  /// configured agent, persists it into that agent's definition.
  private static func setLimit(
    _ key: String,
    parts: [String],
    session: inout REPLSession,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    var limits = session.profile.limits
    let current: Int
    switch key {
    case "limits.maxToolCalls": current = limits.maxToolCalls
    case "limits.maxSubagents": current = limits.maxSubagents
    default: current = limits.maxModelTurns
    }
    guard parts.count > 1 else {
      await terminal.line("\(key) = \(current)")
      return
    }
    guard parts.count == 2, let value = Int(parts[1]), value >= 0 else {
      await terminal.line("Usage: /set \(key) N  (a non-negative integer)")
      return
    }
    if key == "limits.maxToolCalls" {
      limits.maxToolCalls = value
    } else if key == "limits.maxSubagents" {
      limits.maxSubagents = value
    } else {
      limits.maxModelTurns = max(1, value)
    }
    session.profile.limits = limits
    session.touch()
    let applied: Int
    switch key {
    case "limits.maxToolCalls": applied = limits.maxToolCalls
    case "limits.maxSubagents": applied = limits.maxSubagents
    default: applied = limits.maxModelTurns
    }
    guard var draft = configuration, let configurationPath,
      let index = draft.agents.firstIndex(where: { $0.id == session.profile.agentID })
    else {
      await terminal.line("Set \(key) = \(applied) for this chat.")
      return
    }
    draft.agents[index].limits = limits
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      configuration = draft
      await terminal.line("Set \(key) = \(applied) for agent '\(session.profile.agentID)'.")
    } catch {
      await terminal.line(
        "Set \(key) = \(applied) for this chat; could not save the configuration: \(error.localizedDescription)",
        to: .standardError)
    }
  }

  private static func listUISettings(_ ui: ConfiguredTerminalUI, terminal: TerminalWriter) async {
    for key in [
      "ui.bgline", "ui.fgcolor", "ui.bgcolor", "ui.fgprompt", "ui.bgprompt", "ui.bold",
      "ui.markdown", "ui.toolResultLines",
    ] {
      await terminal.line("\(key) = \(uiSetting(key, in: ui))")
    }
  }

  private static func uiSetting(_ key: String, in ui: ConfiguredTerminalUI) -> String {
    let value: String
    switch key.lowercased() {
    case "ui.bgline": value = ui.backgroundLine
    case "ui.fgcolor": value = ui.foreground
    case "ui.bgcolor": value = ui.background
    case "ui.fgprompt": value = ui.promptForeground
    case "ui.bgprompt": value = ui.promptBackground
    case "ui.bold": return ui.bold ? "on" : "off"
    case "ui.markdown": return ui.markdown ? "on" : "off"
    case "ui.toolresultlines": return String(ui.toolResultLines)
    default: return "-"
    }
    return value.isEmpty ? "none" : value
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

  /// `/attach PATH` converts a document to text the model can read and queues it
  /// for the next message; `/attach clear` drops everything queued so far.
  private static func attachDocument(
    _ argument: String,
    session: inout REPLSession,
    ocrProvider: any OCRProvider,
    terminal: TerminalWriter
  ) async {
    var trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      await terminal.line("Usage: /attach PATH | /attach clear")
      await terminal.line(
        "Word and PDF files become Markdown, JSON becomes an outline, text files attach as they are, and images attach at medium size."
      )
      return
    }
    if trimmed.lowercased() == "clear" {
      let count = session.pendingContent.count
      session.pendingContent.removeAll()
      await terminal.line(
        count == 0
          ? "No pending attachments."
          : "Dropped \(count) pending attachment\(count == 1 ? "" : "s").")
      return
    }
    if trimmed.count >= 2, let first = trimmed.first, first == "\"" || first == "'",
      trimmed.last == first
    {
      trimmed = String(trimmed.dropFirst().dropLast())
    }
    let path = NSString(string: trimmed).expandingTildeInPath
    let url = URL(fileURLWithPath: path)
    do {
      if DocumentAttachmentImporter.kind(forFilename: url.lastPathComponent) == .image {
        session.pendingContent.append(
          try await imageContent(path: path, mode: .medium, ocrProvider: ocrProvider))
        await terminal.line(
          "Image queued at medium size: \(url.lastPathComponent). Use /image for other sizes or OCR."
        )
        return
      }
      let attachment = try DocumentAttachmentImporter.attachment(at: url)
      session.pendingContent.append(attachment.content)
      var message = "Attached \(attachment.name) (\(attachment.characterCount) characters"
      if let note = attachment.note { message += ", \(note)" }
      message += "); it is sent with the next message."
      await terminal.line(message)
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
    runtime: AgentRuntime,
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
      session = REPLSession(chat: chatApplyingConfiguredAgentSettings(chat, configuration: configuration))
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
      session = REPLSession(chat: chatApplyingConfiguredAgentSettings(chat, configuration: configuration))
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
      session = REPLSession(
        chat: chatApplyingConfiguredAgentSettings(
          workspace.selectedChat!, configuration: configuration))
      await terminal.line("Closed '\(oldTitle)'; switched to '\(session.title)'.")
    case "messages":
      await handleChatCommand("list", session: &session, runtime: runtime, terminal: terminal)
    case "log", "edit", "remove", "rm", "undo", "trim", "compact", "clear", "help":
      await handleChatCommand(argument, session: &session, runtime: runtime, terminal: terminal)
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
    runtime: AgentRuntime,
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
      let renderer = await terminal.markdownRenderer
      await terminal.line(
        conversationLog(session: session, full: true) { text in
          guard let renderer else { return text }
          var rendered = renderer.render(text)
          while rendered.hasSuffix("\n") { rendered.removeLast() }
          return rendered
        })
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
    case "compact":
      await compactChat(session: &session, runtime: runtime, terminal: terminal)
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

  /// CLI counterpart to the iOS compaction flow: ask the selected model for a
  /// durable summary, then replace the transcript while retaining the active
  /// agent's system instructions.
  private static func compactChat(
    session: inout REPLSession,
    runtime: AgentRuntime,
    terminal: TerminalWriter
  ) async {
    let entries = session.history.messages.compactMap { message -> String? in
      guard message.role == .user || message.role == .assistant else { return nil }
      let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return nil }
      return "\(message.role == .user ? "User" : "Assistant"):\n\(text)"
    }
    guard entries.count >= 2 else {
      await terminal.line("Nothing to compact yet.")
      return
    }

    let prompt = """
      Compact the transcript below into durable context for continuing the same chat.

      Output only the compacted context. Do not include hidden reasoning, XML tags, prompt scaffolding, or commentary about the task.

      Preserve:
      - User goals, preferences, constraints, and decisions
      - Important names, projects, files, commands, code snippets, errors, and results
      - Current state, unresolved questions, and next steps

      Drop greetings, filler, repeated text, tool protocol blocks, and implementation details that no longer matter. Write concise bullets grouped by topic when useful.

      Transcript:

      \(entries.joined(separator: "\n\n---\n\n"))
      """
    let profile = session.profile
    let request = AgentRequest(
      agentID: profile.agentID,
      provider: profile.provider,
      model: profile.model,
      messages: [.user(prompt)],
      toolNames: [],
      subagentNames: [],
      toolChoice: .none,
      responseFormat: .text,
      options: profile.options,
      limits: profile.limits,
      stream: false,
      toolCallingStrategy: .automatic,
      useToolProxy: false)
    await terminal.line("Compacting conversation…")
    do {
      let result = try await runtime.run(request) { _ in }
      let summary = result.transcript.last(where: { $0.role == .assistant })?.text
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !summary.isEmpty else {
        await terminal.line("error: Compact returned an empty summary.", to: .standardError)
        return
      }
      var compacted: [AgentMessage] = []
      if !profile.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        compacted.append(.system(profile.instructions))
      }
      compacted.append(.system("Conversation summary (compacted):\n\n\(summary)"))
      session.history.replaceAll(with: compacted)
      session.pendingContent.removeAll()
      session.touch()
      await terminal.line("Conversation compacted into a summary.")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  private static func chatIndex(_ raw: String, count: Int) -> Int? {
    guard let value = Int(raw), value > 0, value <= count else { return nil }
    return value - 1
  }

  private static func conversationLog(
    session: REPLSession,
    full: Bool,
    renderText: (String) -> String = { $0 }
  ) -> String {
    guard !session.history.isEmpty else { return "No conversation messages yet." }
    var lines = [full ? "# Full conversation log" : "Conversation log:"]
    if !full { lines.append("-----------------") }
    for (index, message) in session.history.messages.enumerated() {
      let role = message.role.rawValue.capitalized
      if full {
        lines.append("\n## [\(index + 1)] \(role) (id: \(message.id))")
        lines.append(
          message.content.map { renderFullContent($0, renderText: renderText) }
            .joined(separator: "\n"))
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

  private static func renderFullContent(
    _ part: ContentPart,
    renderText: (String) -> String = { $0 }
  ) -> String {
    switch part {
    case .text(let text):
      return renderText(text)
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
        value += "\n" + result.content.map { renderFullContent($0) }.joined(separator: "\n")
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
    initialProfile: SessionProfile,
    configuredAgents: [AgentDefinition],
    providerOverride: ProviderID?,
    modelOverride: String?,
    options: CLIOptions
  ) throws -> AgentChatWorkspace {
    if FileManager.default.fileExists(atPath: url.path) {
      var workspace = try AgentChatWorkspace.load(from: url)
      if workspace.selectedChat != nil {
        synchronizeConfiguredAgentSettings(in: &workspace, agents: configuredAgents)
        let overridesLimits =
          options.maxToolCalls != nil || options.maxModelTurns != nil
          || options.maxSubagents != nil
        if providerOverride != nil || modelOverride != nil || overridesLimits {
          for var chat in workspace.chats {
            if let providerOverride { chat.primaryAgent.provider = providerOverride }
            if let modelOverride { chat.primaryAgent.model = modelOverride }
            options.applyLimitOverrides(to: &chat.primaryAgent.limits)
            workspace.upsert(chat)
          }
        }
        return workspace
      }
      let chat = AgentChat(title: "Chat 1", primaryAgent: initialProfile.agentDefinition)
      workspace.upsert(chat, selecting: true)
      return workspace
    }
    let chat = AgentChat(title: "Chat 1", primaryAgent: initialProfile.agentDefinition)
    return AgentChatWorkspace(chats: [chat], selectedChatID: chat.id)
  }

  /// Chat files retain an agent snapshot for portability, but reusable agent
  /// controls are configured in pmai.json. Refreshing them prevents an old
  /// chat from masking or overwriting newer `/edit config` and `/set` values.
  private static func synchronizeConfiguredAgentSettings(
    in workspace: inout AgentChatWorkspace,
    agents: [AgentDefinition]
  ) {
    let configuredByID = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
    for var chat in workspace.chats {
      guard let configured = configuredByID[chat.primaryAgent.id] else { continue }
      chat.primaryAgent.limits = configured.limits
      chat.primaryAgent.toolCallingStrategy = configured.toolCallingStrategy
      workspace.upsert(chat)
    }
  }

  private static func chatApplyingConfiguredAgentSettings(
    _ chat: AgentChat,
    configuration: MaiConfiguration?
  ) -> AgentChat {
    guard
      let configured = configuration?.agents.first(where: { $0.id == chat.primaryAgent.id })
    else { return chat }
    var chat = chat
    chat.primaryAgent.limits = configured.limits
    chat.primaryAgent.toolCallingStrategy = configured.toolCallingStrategy
    return chat
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
      "/help", "/exit", "/quit", "/set yolo on", "/set yolo off", "/set ui.",
      "/set limits.", "/set limits.maxToolCalls ", "/set limits.maxModelTurns ",
      "/set limits.maxSubagents ",
      "/set toolCallingStrategy automatic", "/set toolCallingStrategy native",
      "/set toolCallingStrategy text", "/set toolCallingStrategy xml",
      "/set toolCallingStrategy json",
      "/set ui.bgline rgb:024", "/set ui.bgline none", "/set ui.fgprompt yellow",
      "/set ui.fgcolor none", "/set ui.bgcolor none", "/set ui.bgprompt none",
      "/set ui.bold on", "/set ui.bold off", "/set ui.markdown on", "/set ui.markdown off",
      "/set ui.toolResultLines ",
      "/cwd", "/pwd", "/cd ", "/plugins",
      "/providers", "/models ", "/provider ", "/baseurl ", "/model ", "/agents",
      "/agent use ",
      "/agent show ", "/agent add ", "/tools", "/proxy on", "/proxy off", "/mcp list",
      "/mcp add ", "/mcp enable ", "/mcp disable ",
      "/edit prompt", "/edit config", "/edit mcps", "/chat compact",
      "/image tiny ", "/image small ", "/image medium ", "/image big ", "/image full ",
      "/image ocr ", "/attach ", "/attach clear", "/copy", "/visual", "/clear", "/chat list",
      "/chat new ",
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
        ["echo", "datetime", "calculator", "files", "run", "weather", "web", "mastodon", "github"])
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
          defaultApproval: .confirm),
        ConfiguredMCPServer(
          id: "local",
          kind: "stdio",
          enabled: false,
          displayName: "Example local MCP",
          command: "your-mcp-server",
          args: ["--stdio"],
          cwd: ".",
          toolNamePrefix: "local",
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
            ] + MaiFileWorkspaceTool.toolNames + MaiRunTool.toolNames + MaiGitHubTool.toolNames),
          toolGroupNames: [
            "echo", "datetime", "calculator", "files", "run", "weather", "web", "mastodon", "github",
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
    /set                   List mutable session and terminal UI settings
    /set yolo BOOL         Permit all tool calls for this session (on/off)
    /set toolCallingStrategy MODE  Use automatic/native tools, or text/XML/JSON emulation
    /set limits.           Show the tool call and model turn limits per run
    /set limits.maxToolCalls N   Tool calls allowed per run (persisted for the agent)
    /set limits.maxModelTurns N  Model turns allowed per run (persisted for the agent)
    /set ui.markdown BOOL  Render replies as styled markdown (on/off)
    /set ui.toolResultLines N  Show the first N lines of each tool result (0 hides them)
    /cwd                  Print the current working directory
    /cd PATH              Change the current working directory
    /set ui.               List terminal UI settings
    /set ui.SETTING VALUE  Set colors or bold input and persist the change
    /plugins            List statically and dynamically loaded plugins
    /providers          List registered providers
    /models [PROVIDER]  List models from the current or named provider
    /provider ID       Select a provider
    /baseurl URL       Change the current provider endpoint
    /model NAME         Select a model
    /chat               Create, switch, rename, or edit persistent chats
    /edit TARGET        Edit a prompt, config, MCP list, or message in $EDITOR
    /agents             List configured agents
    /agent [use] ID     Set the current chat's primary agent
    /agent add ...      Persist a reusable agent and OpenAI-compatible endpoint
    /tools              List logical tool groups for the current agent
    /proxy [on|off]     Inspect or toggle the shared tool proxy
    /mcp list           List configured MCP servers and connection state
    /mcp add ...        Add, connect, persist, and enable a stdio MCP server
    /mcp enable ID      Connect and enable a configured MCP server
    /mcp disable ID     Disconnect and disable a configured MCP server
    /image MODE PATH    Attach at tiny/small/medium/big/full size, or OCR to Markdown
    /attach PATH        Attach a Word, PDF, JSON, or text file as Markdown/plain text
    /attach clear       Drop the attachments queued for the next message
    /copy [N]           Copy the last reply, or the last N messages, to the clipboard
    /visual             Open the terminal workspace: split chats, providers, MCPs, tools
    /clear              Clear conversation history
    /exit               Exit the REPL

    Input: Ctrl+A/E beginning/end · Ctrl+W delete word · Ctrl+C cancel run · Ctrl+Z suspend
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
      /chat compact        Replace the chat with a model-generated context summary
      /chat clear         Clear the conversation and restore configured instructions

    Removing a tool call or result also removes its linked tool transaction.
    """

  private static let mcpCommandHelp = """
    MCP commands:
      /mcp list
      /mcp enable ID
      /mcp disable ID
      /mcp add COMMAND [ARG ...]
      /mcp add [--name ID] [--env KEY=VALUE] [--cwd PATH] [--timeout SECONDS]
               [--prefix PREFIX] [--approval MODE] -- COMMAND [ARG ...]

    MODE is automatic, confirm, or dangerous. Quotes and backslash escapes are
    supported. Without --name, the command's basename becomes the server name.
    The server is connected immediately, saved in the normal mcpServers
    configuration, and all of its tools are enabled for every agent.

    Examples:
      /mcp add r2mcp
      /mcp add --name weather -- npx -y weather-mcp
    """

  private static let editHelp = """
    /edit prompt             Edit the current agent's system prompt
    /edit config             Edit the active configuration file
    /edit mcps               Edit the configured MCP server list as JSON
    /edit N|MESSAGE_ID       Edit conversation message N or its full message ID

    Uses $EDITOR, then $VISUAL, then vim. Agent limits and tool-calling strategy
    apply immediately; provider, plugin, tool, and MCP changes require a restart.
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
        --max-tool-calls N  tool calls allowed per run (default 50)
        --max-turns N       model turns allowed per run (default 50)
        --max-subagents N   concurrent background agents (default 0/off)
        --image PATH        attach an image (repeatable)
        --no-stream         disable response streaming
        --markdown          render replies as markdown even when piped
        --no-markdown       print replies verbatim
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
