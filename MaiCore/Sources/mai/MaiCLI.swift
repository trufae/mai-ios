import Foundation
import MaiACP
import MaiCore
import MaiDocuments
import MaiMCP
import MaiMarkdown
import MaiOpenAI
import MaiPluginHost
import MaiStandardTools
import MaiVisionOCR

#if PMAI_HAS_VISUAL
  import MaiVisual
#endif

#if canImport(Android)
  import Android
#elseif canImport(Musl)
  import Musl
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

@_silgen_name("system")
private func posixSystem(_ command: UnsafePointer<CChar>) -> CInt

private struct CLIOptions {
  var configPath: String?
  /// Root holding the project index and shared state; nil follows PMAI_HOME or ~/.pmai.
  var homePath: String?
  /// Directory holding this project's chat files; nil uses .pmai/chats in the project.
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
  /// Permit all tool calls without prompting for this process.
  var yolo = false
  /// Reopen the most recently updated chat instead of starting a fresh one.
  var resume = false
  /// Render replies as markdown; nil follows the configuration and the tty.
  var markdown: Bool?
  var imagePaths: [String] = []
  var pluginPaths: [String] = []
  var initialPrompt: String?
  var printConfig = false
  /// List every known project and exit.
  var listProjects = false
  /// Serve one protocol on stdio instead of the REPL.
  var serve: ServeMode?

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
      case "--home":
        homePath = try Self.value(after: argument, in: arguments, index: &index)
      case "--projects":
        listProjects = true
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
      case "-y", "--yolo":
        yolo = true
      case "--resume", "--continue":
        resume = true
      case "--markdown":
        markdown = true
      case "--no-markdown":
        markdown = false
      case "--print-config":
        printConfig = true
      case "--acp":
        serve = .acp
      case "--mcp":
        serve = .mcp
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

/// A protocol pmai speaks over stdio instead of running its REPL.
enum ServeMode: String, Sendable {
  case acp
  case mcp
}

private enum CLIError: LocalizedError {
  case invalidURL(String)
  case missingValue(String)
  case unknownOption(String)
  case invalidCount(String, String)
  case configNotFound(String)
  case noProvider
  case noProject
  case invalidImage(String)

  var errorDescription: String? {
    switch self {
    case .noProject: "No project is open."
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

/// Unlike the other ad-hoc settings, an explicitly exported empty API key is
/// meaningful: it suppresses lower-priority aliases and configured secrets.
private func environmentAPIKey(in environment: [String: String]) -> String? {
  for name in ["PMAI_API_KEY", "MAI_API_KEY", "OPENAI_API_KEY"] {
    if let value = environment[name] { return value }
  }
  return nil
}

private func environmentName(
  _ names: [String],
  in environment: [String: String]
) -> String? {
  names.first { environment[$0].map { !$0.isEmpty } ?? false }
}

/// What `/visual` needs beyond the REPL session itself.
private final class ProviderBaseURLStore: @unchecked Sendable {
  private let lock = NSLock()
  private var urls: [String: URL]

  init(_ urls: [String: URL]) {
    self.urls = urls
  }

  func url(for providerID: String) -> URL? {
    lock.withLock { urls[providerID] }
  }

  func set(_ url: URL, for providerID: String) {
    lock.withLock { urls[providerID] = url }
  }

  func snapshot() -> [String: URL] {
    lock.withLock { urls }
  }
}

private struct VisualBridge {
  var approvalHandler: TerminalApprovalHandler
  var configurationPath: String?
  var implicitProviders: [ConfiguredProvider]
  var providerBaseURLs: ProviderBaseURLStore
  var memory: MemoryState
  var todo: TodoState
}

/// Where the current project's todo list lives. The `todo_*` tools are
/// registered before the project is opened, so they resolve the file through
/// this box on every call; the file itself is the only copy, read fresh each
/// time so edits made in an editor are seen at once.
private final class TodoState: @unchecked Sendable {
  private let lock = NSLock()
  private let home: AgentHome
  private var project: AgentProject?

  init(home: AgentHome) {
    self.home = home
  }

  func focus(project: AgentProject) {
    lock.withLock { self.project = project }
  }

  var url: URL? {
    lock.withLock { project.map { home.todoURL(for: $0) } }
  }

  var current: AgentTodoList {
    url.flatMap { try? AgentTodoList.load(from: $0) } ?? AgentTodoList()
  }

  func save(_ list: AgentTodoList) throws {
    guard let url else { throw CLIError.noProject }
    try list.save(to: url)
  }
}

/// Everything the memory feature needs that outlives one command: where the
/// notes are stored, which chats the `chats_*` tools may reach, and how far.
/// The REPL keeps it current; commands and tools read it.
///
/// The project arrives after the runtime is built, so the tools are registered
/// against this box rather than against a project they cannot see yet.
private final class MemoryState: @unchecked Sendable {
  private let lock = NSLock()
  private let home: AgentHome
  private var project: AgentProject?
  private var currentChatID: UUID?
  private var memory = AgentMemory()
  private var settings = ConfiguredMemory()

  init(home: AgentHome) {
    self.home = home
  }

  /// Adopts the project whose memory this is, loading its notes from disk.
  func adopt(project: AgentProject, settings: ConfiguredMemory) {
    lock.withLock {
      self.project = project
      self.settings = settings
      memory = (try? AgentMemory.load(from: home.memoryURL(for: project))) ?? AgentMemory()
    }
  }

  func focus(project: AgentProject, chatID: UUID?) {
    lock.withLock {
      self.project = project
      currentChatID = chatID
    }
  }

  func apply(_ settings: ConfiguredMemory) {
    lock.withLock { self.settings = settings }
  }

  var current: AgentMemory { lock.withLock { memory } }
  var configuration: ConfiguredMemory { lock.withLock { settings } }
  var readsOtherChats: Bool { lock.withLock { settings.scope != .none } }

  var url: URL? {
    lock.withLock { project.map { home.memoryURL(for: $0) } }
  }

  /// What the runtime should inject, or nil when memory is off or empty.
  var promptSection: String? {
    lock.withLock { settings.enabled ? memory.promptSection : nil }
  }

  func save(_ updated: AgentMemory) throws {
    let url = lock.withLock { () -> URL? in
      memory = updated
      return project.map { home.memoryURL(for: $0) }
    }
    guard let url else { throw CLIError.noProvider }
    try updated.save(to: url)
  }

  func reload() {
    lock.withLock {
      guard let project else { return }
      memory = (try? AgentMemory.load(from: home.memoryURL(for: project))) ?? AgentMemory()
    }
  }

  /// Every chat in the current project, newest first, for `/memory learn --all`.
  func projectChats() -> [MemoryChat] {
    guard let project = lock.withLock({ project }) else { return [] }
    return chats(of: project)
  }

  /// The chats the tools may read: never the one asking, and only this
  /// project unless the scope opens every working directory.
  func reachableChats() -> [MemoryChat] {
    let (project, currentChatID, scope) = lock.withLock {
      (self.project, self.currentChatID, settings.scope)
    }
    guard scope != .none, let project else { return [] }
    var reachable = chats(of: project)
    if scope == .all, let index = try? home.loadProjectIndex() {
      for other in index.orderedProjects where other.id != project.id {
        reachable += chats(of: other)
      }
    }
    return reachable.filter { $0.id != currentChatID }
      .sorted { $0.updatedAt > $1.updatedAt }
  }

  private func chats(of project: AgentProject) -> [MemoryChat] {
    let chats = (try? home.chatStore(for: project).loadChats()) ?? []
    return chats.filter(\.hasConversation)
      .map { MemoryChat($0, scope: project.displayName) }
      .sorted { $0.updatedAt > $1.updatedAt }
  }
}

struct SessionProfile {
  var agentID: String
  var displayName: String
  /// Carried through so writing the chat's agent back to the configuration
  /// never erases the setup's purpose or its enabled state.
  var description: String
  var isEnabled: Bool
  var provider: ProviderID
  var model: String
  var instructions: String
  var systemPrompt: String?
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
  var toolDelegation: AgentToolDelegation

  init(definition: AgentDefinition) {
    agentID = definition.id
    displayName = definition.displayName
    description = definition.description
    isEnabled = definition.isEnabled
    provider = definition.provider
    model = definition.model
    instructions = definition.instructions
    systemPrompt = definition.systemPrompt
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
    toolDelegation = definition.toolDelegation
  }

  init(provider: ProviderID, model: String, instructions: String, stream: Bool) {
    agentID = "main"
    displayName = "main"
    description = ""
    isEnabled = true
    self.provider = provider
    self.model = model
    self.instructions = instructions
    systemPrompt = nil
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
      ] + MaiFileWorkspaceTool.toolNames + MaiRunTool.toolNames + MaiGitHubTool.toolNames
        + MaiTodoTools.toolNames)
    toolGroupNames = [
      "echo", "datetime", "calc", "files", "run", "weather", "web", "mastodon", "github", "todo",
    ]
    subagentNames = []
    self.stream = stream
    limits = .init()
    toolChoice = .automatic
    responseFormat = .text
    options = .init()
    toolCallingStrategy = .automatic
    useToolProxy = false
    toolDelegation = .inline
  }

  var agentDefinition: AgentDefinition {
    AgentDefinition(
      id: agentID,
      displayName: displayName,
      description: description,
      isEnabled: isEnabled,
      instructions: instructions,
      systemPrompt: systemPrompt,
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
      useToolProxy: useToolProxy,
      toolDelegation: toolDelegation)
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
  var isArchived: Bool
  #if PMAI_HAS_VISUAL
    /// Conversations and panes left behind by the last `/visual` session.
    var visualSnapshot: VisualWorkspaceSnapshot?
  #endif

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
    isArchived = false
  }

  init(chat: AgentChat) {
    id = chat.id
    title = chat.title
    profile = SessionProfile(definition: chat.primaryAgent)
    history = AgentTranscript(messages: chat.messages)
    pendingContent = chat.pendingContent
    createdAt = chat.createdAt
    updatedAt = chat.updatedAt
    isArchived = chat.isArchived
  }

  var chat: AgentChat {
    AgentChat(
      id: id,
      title: title,
      primaryAgent: profile.agentDefinition,
      messages: history.messages,
      pendingContent: pendingContent,
      createdAt: createdAt,
      updatedAt: updatedAt,
      isArchived: isArchived)
  }

  /// Names a placeholder chat after its first message; chosen titles stay.
  mutating func refreshTitle(from text: String) {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty || trimmed == AgentChat.placeholderTitle,
      let derived = AgentChat.derivedTitle(from: text)
    else { return }
    title = derived
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

  #if PMAI_HAS_VISUAL
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
  #endif

  private static func initialHistory(for profile: SessionProfile) -> [AgentMessage] {
    let instructions = profile.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    return instructions.isEmpty ? [] : [.system(instructions)]
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
  typealias Prompter = @Sendable (ApprovalRequest) async throws -> ApprovalDecision

  private let configuration: ConfiguredApprovals
  private var delegate: (any ApprovalHandler)?
  private var yoloEnabled: Bool
  /// Asks through the REPL's own prompt while the persistent screen owns the
  /// terminal, so a question from a child agent never fights the line editor
  /// for stdin.
  private var prompter: Prompter?

  init(configuration: ConfiguredApprovals, yoloEnabled: Bool = false) {
    self.configuration = configuration
    self.yoloEnabled = yoloEnabled
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

  func setPrompter(_ prompter: Prompter?) {
    self.prompter = prompter
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
      if let prompter { return try await prompter(request) }
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
struct MaiCLI {
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
      if options.listProjects {
        let home = resolvedHome(options: options, environment: environment)
        print(projectListing(try home.loadProjectIndex(), currentID: nil, now: Date()))
        return
      }

      let loaded = try loadConfiguration(options: options)
      let configurationPath = loaded?.path ?? defaultConfigurationPath
      var configuration = loaded?.configuration
      if var existing = configuration {
        var changed = existing.associateSystemPrompts()
        if !existing.toolSources.contains(where: {
          $0.kind == MaiStandardToolsPlugin.factoryKind
        }) {
          existing.toolSources.append(
            ConfiguredToolSource(
              id: "standard-tools",
              kind: MaiStandardToolsPlugin.factoryKind))
          changed = true
        }
        if changed { try existing.save(to: URL(fileURLWithPath: configurationPath)) }
        configuration = existing
      }
      let approvalHandler = TerminalApprovalHandler(
        configuration: configuration?.approvals ?? .init(),
        yoloEnabled: options.yolo)
      let runtime = AgentRuntime(approvalHandler: approvalHandler)
      let plugins = PluginRegistry()
      try await plugins.install(MaiCoreBuiltinsPlugin(), origin: "built-in")
      try await plugins.install(MaiMCPPlugin(), origin: "built-in")
      try await plugins.install(MaiOpenAIPlugin(), origin: "built-in")
      try await plugins.install(MaiACPPlugin(), origin: "built-in")
      do {
        try await plugins.install(MaiVisionOCRPlugin(), origin: "built-in")
      } catch {
        // OCR is optional: a platform without a usable backend must not stop
        // the CLI from starting.
        FileHandle.standardError.write(
          Data("warning: OCR plugin unavailable: \(error.localizedDescription)\n".utf8))
      }
      try await plugins.install(MaiStandardToolsPlugin(), origin: "built-in")
      let nativePluginHost = NativePluginHost()
      try await loadNativePlugins(
        options: options,
        loadedConfigurationPath: loaded?.path,
        configuration: configuration,
        host: nativePluginHost,
        registry: plugins)
      let memoryState = MemoryState(
        home: resolvedHome(options: options, environment: environment))
      let todoState = TodoState(
        home: resolvedHome(options: options, environment: environment))
      try await registerTools(
        in: runtime,
        plugins: plugins,
        configuration: configuration,
        environment: environment)
      try await registerMemoryTools(in: runtime, state: memoryState)
      try await registerTodoTools(in: runtime, state: todoState)
      try await synchronizeToolGroupSelections(
        configuration: &configuration,
        configurationPath: configurationPath,
        plugins: plugins,
        environment: environment)
      let ocrProvider = await configuredOCRProvider(
        plugins: plugins,
        configuration: configuration,
        environment: environment)
      let setup = try await configureRuntime(
        runtime,
        plugins: plugins,
        configuration: configuration,
        options: options,
        environment: environment)
      var profile = try selectedProfile(
        configuration: configuration,
        options: options,
        environment: environment)
      if configuration == nil {
        var created = MaiConfiguration(
          defaultAgent: profile.agentID,
          providers: setup.implicitProviders,
          toolSources: [
            ConfiguredToolSource(
              id: "standard-tools",
              kind: MaiStandardToolsPlugin.factoryKind)
          ],
          agents: [profile.agentDefinition])
        created.associateSystemPrompts()
        try created.save(to: URL(fileURLWithPath: configurationPath))
        configuration = created
        profile = try selectedProfile(
          configuration: created,
          options: options,
          environment: environment)
      }
      let home = resolvedHome(options: options, environment: environment)
      let project = try home.openProject(
        atWorkingDirectory: URL(
          fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
      memoryState.adopt(project: project, settings: configuration?.memory ?? .init())
      todoState.focus(project: project)
      await runtime.configureMemory(memoryState.promptSection)
      let store = resolvedChatStore(options: options, home: home, project: project)
      importLegacyChats(into: store, project: project, options: options, environment: environment)
      let providerOverride =
        options.providerOverride
        ?? environmentValue(["PMAI_PROVIDER", "MAI_PROVIDER"], in: environment).map {
          ProviderID($0)
        }
      let modelOverride =
        options.modelOverride
        ?? environmentValue(["PMAI_MODEL", "MAI_MODEL", "OPENAI_MODEL"], in: environment)
      var workspace = try loadChatWorkspace(
        from: store,
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
      await terminal.configureToolResultColor(
        configuration?.ui.toolResultForeground ?? ConfiguredTerminalUI().toolResultForeground)
      await terminal.configureSubagentOutput(
        configuration?.ui.subagentOutput ?? ConfiguredTerminalUI().subagentOutput)
      await terminal.configurePromptColor(
        configuration?.ui.promptForeground ?? ConfiguredTerminalUI().promptForeground)

      if let mode = options.serve {
        await runServer(
          mode,
          runtime: runtime,
          approvalHandler: approvalHandler,
          agent: profile.agentDefinition)
        return
      }
      if let path = loaded?.path {
        await terminal.line("Loaded \(path)", to: .standardError)
      } else {
        await terminal.line("Created \(configurationPath)", to: .standardError)
      }
      if let prompt = options.initialPrompt {
        var oneShotProcess: AgentPID?
        let succeeded = await submit(
          prompt,
          session: &session,
          runtime: runtime,
          process: &oneShotProcess,
          terminal: terminal)
        workspace.upsert(session.chat, selecting: true)
        try store.commit(&workspace)
        if !succeeded { exit(1) }
        return
      }
      await runREPL(
        workspace: &workspace,
        store: store,
        home: home,
        project: project,
        historyURL: resolvedHistoryURL(options: options, home: home, environment: environment),
        runtime: runtime,
        plugins: plugins,
        ocrProvider: ocrProvider,
        configuration: configuration,
        catalogs: setup.catalogs,
        visual: VisualBridge(
          approvalHandler: approvalHandler,
          configurationPath: configurationPath,
          implicitProviders: setup.implicitProviders,
          providerBaseURLs: ProviderBaseURLStore(setup.providerBaseURLs),
          memory: memoryState,
          todo: todoState),
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

  /// Tool and group names that changed; agent records saved under the old
  /// name are moved to the new one the next time the configuration is read.
  private static let renamedToolNames = ["calculator": MaiCalculatorTool.name]

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
      let previousGroups = draft.agents[index].toolGroupNames
      for (old, new) in renamedToolNames {
        if draft.agents[index].toolNames.remove(old) != nil {
          draft.agents[index].toolNames.insert(new)
        }
        if draft.agents[index].toolGroupNames.remove(old) != nil {
          draft.agents[index].toolGroupNames.insert(new)
        }
      }
      for groupName in draft.agents[index].toolGroupNames {
        draft.agents[index].toolNames.formUnion(toolsByGroup[groupName] ?? [])
      }
      changed =
        changed || previous != draft.agents[index].toolNames
        || previousGroups != draft.agents[index].toolGroupNames
    }
    guard changed else { return }
    try draft.save(to: URL(fileURLWithPath: configurationPath))
    configuration = draft
  }

  /// Picks the configured OCR backend, falling back to whatever this platform
  /// can offer (Apple Vision, then a local tesseract binary). OCR never blocks
  /// startup: when nothing is usable the returned provider explains why the
  /// first time OCR is requested.
  private static func configuredOCRProvider(
    plugins: PluginRegistry,
    configuration: MaiConfiguration?,
    environment: [String: String]
  ) async -> any OCRProvider {
    var failures: [String] = []
    if let configured = configuration?.ocrProviders.first(where: \.enabled) {
      do {
        return try await plugins.makeOCRProvider(
          kind: configured.kind,
          context: configured.context(environment: environment))
      } catch {
        failures.append(error.localizedDescription)
      }
    }
    var fallbackKinds = [MaiVisionOCRPlugin.preferredFactoryKind]
    for kind in ["vision", TesseractOCRProvider.factoryKind] where !fallbackKinds.contains(kind) {
      fallbackKinds.append(kind)
    }
    for kind in fallbackKinds {
      do {
        return try await plugins.makeOCRProvider(
          kind: kind,
          context: PluginFactoryContext(id: kind, environment: environment))
      } catch {
        failures.append(error.localizedDescription)
      }
    }
    return UnavailableOCRProvider(
      reason: failures.isEmpty
        ? "no OCR provider is registered on this platform."
        : failures.joined(separator: " "))
  }

  /// Exposes the shared `chats_*` tools over this session's reachable chats.
  /// They are registered before configured agents are filtered against the
  /// known tool names, so an agent may list them like any other tool.
  private static func registerMemoryTools(
    in runtime: AgentRuntime,
    state: MemoryState
  ) async throws {
    for definition in MaiMemoryTools.definitions {
      let name = definition.name
      try await runtime.register(
        tool: ClosureTool(definition: definition) { arguments, _ in
          guard state.readsOtherChats else {
            return ToolOutput(
              text:
                "Error: reading other chats is disabled. Enable it with /memory scope project or /memory scope all.",
              isError: true)
          }
          return ToolOutput(
            text: MaiMemoryTools.execute(
              name: name,
              arguments: arguments.objectValue ?? [:],
              chats: state.reachableChats()))
        })
    }
  }

  /// Exposes the shared `todo_*` tools over the current project's list file.
  /// Like the memory tools they are registered before agents are filtered
  /// against the known tool names, so an agent may list them like any other.
  private static func registerTodoTools(
    in runtime: AgentRuntime,
    state: TodoState
  ) async throws {
    for tool in MaiTodoTools.makeTools(url: { state.url }) {
      try await runtime.register(tool: tool)
    }
  }

  /// Runs pmai as a stdio server instead of the REPL: ACP for editors, MCP for
  /// tool callers. Both speak JSON-RPC over stdin/stdout, so no output may go
  /// there but the protocol itself; diagnostics go to stderr.
  private static func runServer(
    _ mode: ServeMode,
    runtime: AgentRuntime,
    approvalHandler: TerminalApprovalHandler,
    agent: AgentDefinition
  ) async {
    let transport = StdioJSONRPCTransport.standardIO()
    switch mode {
    case .acp:
      // Tool approvals belong to the editor, not to a terminal nobody is at.
      let bridge = ACPPermissionBridge()
      await approvalHandler.setDelegate(bridge.approvalHandler)
      let server = ACPServer(runtime: runtime, agent: agent, bridge: bridge)
      FileHandle.standardError.write(
        Data("pmai ACP agent ready (\(agent.id)); waiting for a client on stdio.\n".utf8))
      await server.serve(on: transport)
    case .mcp:
      let server = MCPAgentServer(runtime: runtime, agent: agent)
      FileHandle.standardError.write(
        Data("pmai MCP server ready (\(agent.id)); waiting for a client on stdio.\n".utf8))
      await server.serve(on: transport)
    }
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
      ?? environmentAPIKey(in: environment)

    if let configuration {
      let selectedAgentID =
        options.agentOverride ?? configuration.defaultAgent
        ?? configuration.agents.first?.id
      let selectedProviderID = selectedAgentID.flatMap { selectedAgentID in
        configuration.agents.first { $0.id == selectedAgentID }?.provider.rawValue
      }
      let targetProviderID =
        providerOverride?.rawValue ?? selectedProviderID
        ?? ProviderID.openAI.rawValue
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
      await runtime.configureDelegation(
        prompt: configuration.prompts?.delegation,
        workerInstructions: configuration.prompts?.worker)
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
      if let system = options.systemOverride {
        profile.instructions = system
        profile.systemPrompt = nil
      }
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

  /// What outlives one event of the loop: the turn in flight, who typed text
  /// goes to, and the tool calls waiting for an answer.
  private struct REPLLoop {
    var activeTurn: (task: Task<AgentResult, any Error>, started: ContinuousClock.Instant, pid: AgentPID)?
    var focus: REPLMessageTarget = .main
    var approvals: [(request: ApprovalRequest, reply: REPLApprovalReply)] = []
    var editingApproval: (request: ApprovalRequest, reply: REPLApprovalReply)?
    /// True while the input thread waits for the loop before reading again.
    var readerParked = true
    var exiting = false
  }

  /// Commands that are safe while a turn runs: they read state, or change
  /// things the running request already copied.
  private static let commandsAllowedDuringTurn: Set<String> = [
    "/help", "/queue", "/agents", "/set", "/cwd", "/pwd", "/exit", "/quit", "/todo",
    "/providers", "/models", "/plugins", "/mcps", "/prompts", "/project", "/attach", "/image",
    "/copy",
  ]

  /// The REPL is one loop over one stream of events. Typed lines arrive from
  /// a thread of their own, so the prompt stays on screen while a turn runs;
  /// a turn ending, a tool asking for approval, and a change in the process
  /// table arrive on the same stream. On a terminal the prompt lives on two
  /// reserved rows under the output (`TerminalScreen`); piped input keeps the
  /// one-line-at-a-time behaviour, where a turn finishes before the next line
  /// is read.
  private static func runREPL(
    workspace: inout AgentChatWorkspace,
    store: AgentChatStore,
    home: AgentHome,
    project: AgentProject,
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
    var project = project
    var session = REPLSession(chat: workspace.selectedChat!)
    let editor = TerminalLineEditor(historyURL: historyURL)
    let interruptHandler = TerminalInterruptHandler()
    var announcedAttention: Set<AgentPID> = []
    // One process per chat, not per turn: a background agent started three
    // turns ago is still the current run's child, so it stays collectable,
    // and a message typed while a turn runs has a pid to wait in.
    var chatProcessIDs: [UUID: AgentPID] = [:]
    await terminal.line("pmai — MaiCore agent REPL")
    await terminal.line(
      "Project: \(project.displayName) · \(abbreviatedPath(project.workingDirectory)) · /project shows more"
    )
    await terminal.line(
      "Type /help for commands. \(promptIdentity(session)) · \(session.title)")
    let earlier = workspace.chats.filter { $0.id != session.id && $0.hasConversation }
    if !earlier.isEmpty {
      await terminal.line(
        "\(earlier.count) earlier chat\(earlier.count == 1 ? "" : "s") in this project: /chat list shows them, /chat use N switches."
      )
    }

    let (events, continuation) = AsyncStream<REPLEvent>.makeStream()
    let reader = REPLInputReader(editor: editor, continuation: continuation)
    let screen = TerminalScreen()
    if let screen {
      screen.configure(ui: tintedUI(configuration?.ui ?? .init(), project: project))
      screen.activate()
      TerminalScreen.install(screen)
      editor.install(surface: screen)
      await terminal.attach(screen: screen)
      await visual.approvalHandler.setPrompter { request in
        try await withCheckedThrowingContinuation { pending in
          continuation.yield(.approval(request, REPLApprovalReply(pending)))
        }
      }
    }
    let supervisorFeed = Task {
      for await change in await runtime.supervisor.events() {
        continuation.yield(.supervisor(change))
      }
    }
    var loop = REPLLoop()

    func refreshTerminalSettings() async {
      let ui = tintedUI(configuration?.ui ?? .init(), project: project)
      editor.configure(ui: ui)
      screen?.configure(ui: ui)
      await terminal.configureToolResultLines(ui.toolResultLines)
      await terminal.configureToolResultColor(ui.toolResultForeground)
      await terminal.configureSubagentOutput(ui.subagentOutput)
      await terminal.configurePromptColor(ui.promptForeground)
      visual.memory.focus(project: project, chatID: session.id)
      visual.todo.focus(project: project)
      await runtime.configureMemory(visual.memory.promptSection)
    }

    func statusLine() async -> String {
      var facts: [String] = []
      if let turn = loop.activeTurn {
        let activity = await runtime.supervisor.info(turn.pid)?.activity ?? ""
        facts.append(
          activity.isEmpty || activity == "thinking" ? "thinking" : "running \(activity)")
      }
      let children = await runtime.supervisor.liveProcesses().filter { $0.depth > 0 }
      if !children.isEmpty {
        facts.append("\(children.count) agent\(children.count == 1 ? "" : "s")")
      }
      let queued = await runtime.supervisor.queuedMessages().count
      if queued > 0 { facts.append("\(queued) queued") }
      if case .agent(let pid) = loop.focus { facts.append("→ agent#\(pid.rawValue)") }
      if let editing = loop.editingApproval {
        facts.append("json for \(editing.request.tool.name)?")
      } else if let waiting = loop.approvals.first {
        let who = waiting.request.run.pid.map { "agent#\($0.rawValue) " } ?? ""
        facts.append("approve? \(who)\(waiting.request.tool.name) [y/a/n/e/c]")
      }
      let detail = facts.isEmpty ? "" : " · " + facts.joined(separator: " · ")
      // The title goes last so a narrow terminal truncates it, not the status.
      return
        "\(project.displayName) \(promptIdentity(session))\(detail) · \(promptContextStatus(session)) · \(session.title)"
    }

    func promptText() -> String {
      if loop.editingApproval != nil { return "json> " }
      if let waiting = loop.approvals.first {
        let who = waiting.request.run.pid.map { "#\($0.rawValue) " } ?? ""
        return "approve \(who)\(waiting.request.tool.name)? [y/a/n/e/c] "
      }
      if case .agent(let pid) = loop.focus { return "agent#\(pid.rawValue)> " }
      return "pmai> "
    }

    func refreshStatus() async {
      guard let screen else { return }
      screen.setStatus(await statusLine())
    }

    /// Lets the input thread read the next line. Settings that the editor
    /// reads are refreshed here, while the thread is parked and cannot race.
    func releaseReader(workspace: AgentChatWorkspace) async {
      guard loop.readerParked, !loop.exiting else { return }
      await refreshTerminalSettings()
      if screen == nil {
        // Announcing while the classic editor owns the row would corrupt it,
        // so on a plain terminal this happens between prompts.
        await announceAgentAttention(
          runtime: runtime, announced: &announcedAttention, terminal: terminal)
      }
      let status = await statusLine()
      screen?.setStatus(status)
      loop.readerParked = false
      reader.resume(
        with: REPLInputReader.Prompt(
          text: promptText(),
          completions: completionCandidates(workspace: workspace, configuration: configuration),
          separator: screen == nil ? status : nil))
    }

    /// On a plain terminal a turn owns the screen, so the next line waits for
    /// it; on the persistent screen the prompt is always open.
    func releaseIfIdle(workspace: AgentChatWorkspace) async {
      if screen != nil || loop.activeTurn == nil {
        await releaseReader(workspace: workspace)
      }
    }

    func mainProcess() async -> AgentPID {
      if let pid = chatProcessIDs[session.id] { return pid }
      let pid = await runtime.allocateProcess(agentID: session.profile.agentID, task: session.title)
      chatProcessIDs[session.id] = pid
      return pid
    }

    /// Starts one turn with whatever is queued for the chat followed by the
    /// texts just typed. The turn runs in its own task; the loop hears about
    /// its end as an event.
    func startTurn(_ texts: [String]) async {
      let pid = await mainProcess()
      var messages = await runtime.supervisor.drainInbox(pid)
      messages.append(contentsOf: texts.map { AgentMessage.user($0) })
      guard !messages.isEmpty else { return }
      if !session.pendingContent.isEmpty {
        messages[0].content.append(contentsOf: session.pendingContent)
        session.pendingContent.removeAll()
      }
      for message in messages { session.history.append(message) }
      session.refreshTitle(from: messages[0].text)
      await terminal.resetResponse()
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
        useToolProxy: profile.useToolProxy,
        toolDelegation: profile.toolDelegation)
      let task = Task {
        try await runtime.run(request, process: pid) { event in
          await terminal.consume(event)
        }
      }
      interruptHandler.activate { task.cancel() }
      loop.activeTurn = (task, ContinuousClock.now, pid)
      Task {
        let outcome: Result<AgentResult, any Error>
        do {
          outcome = .success(try await task.value)
        } catch {
          outcome = .failure(error)
        }
        continuation.yield(.turnFinished(outcome))
      }
      await refreshStatus()
    }

    /// Sends typed text where it belongs: to the chat as a new turn when it
    /// is idle, or into an inbox the running agent reads at its next turn.
    func deliver(_ text: String, to target: REPLMessageTarget) async {
      switch target {
      case .main:
        guard loop.activeTurn != nil else {
          await startTurn([text])
          return
        }
        let pid = await mainProcess()
        await runtime.supervisor.post(.user(text), to: pid)
        let waiting = await runtime.supervisor.queuedMessages(for: pid).count
        await terminal.note(
          "queued (\(waiting) waiting): it joins the conversation at the next model turn · /queue")
      case .agent(let pid):
        guard let info = await runtime.supervisor.info(pid) else {
          await terminal.note("No agent #\(pid.rawValue). /agents tree lists the running ones.")
          return
        }
        if info.depth == 0 {
          await deliver(text, to: .main)
          return
        }
        guard !info.state.isTerminal else {
          await terminal.note(
            "agent#\(pid.rawValue) (\(info.agentID)) has finished; /agents log \(pid.rawValue) shows what it did."
          )
          if loop.focus == .agent(pid) { loop.focus = .main }
          return
        }
        await runtime.supervisor.post(.user(text), to: pid)
        let waiting = await runtime.supervisor.queuedMessages(for: pid).count
        await terminal.note(
          "queued for agent#\(pid.rawValue) (\(info.agentID)) (\(waiting) waiting): delivered at its next model turn"
        )
      }
      await refreshStatus()
    }

    /// Treats a typed line as the answer to the approval at the head of the
    /// queue when it reads as one; anything else stays an ordinary line and
    /// the question keeps waiting.
    func answerApproval(_ text: String) async -> Bool {
      if let editing = loop.editingApproval {
        loop.editingApproval = nil
        if let data = text.data(using: .utf8),
          let value = try? JSONDecoder().decode(JSONValue.self, from: data),
          value.objectValue != nil
        {
          editing.reply.resume(with: .approve(arguments: value))
          await terminal.note("approved \(editing.request.tool.name) with the edited arguments")
        } else {
          editing.reply.resume(with: .deny(reason: "Edited arguments were not a JSON object."))
          await terminal.note("denied \(editing.request.tool.name): the arguments were not a JSON object")
        }
        return true
      }
      guard let waiting = loop.approvals.first else { return false }
      let tool = waiting.request.tool.name
      switch text.lowercased() {
      case "y", "yes":
        waiting.reply.resume(with: .approve(arguments: waiting.request.call.arguments))
        await terminal.note("approved \(tool)")
      case "a", "always":
        await visual.approvalHandler.setYOLOEnabled(true)
        waiting.reply.resume(with: .approve(arguments: waiting.request.call.arguments))
        await terminal.note("approved \(tool); YOLO mode is on for this session")
      case "n", "no":
        waiting.reply.resume(with: .deny(reason: "Denied by user."))
        await terminal.note("denied \(tool)")
      case "e", "edit":
        loop.approvals.removeFirst()
        loop.editingApproval = waiting
        await terminal.note("Type the replacement JSON arguments for \(tool):")
        return true
      case "c", "cancel":
        waiting.reply.resume(with: .cancelRun)
        await terminal.note("cancelling the run that asked for \(tool)")
      default:
        return false
      }
      loop.approvals.removeFirst()
      return true
    }

    func handleFocus(_ argument: String) async {
      let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else {
        switch loop.focus {
        case .main:
          await terminal.line("Messages go to this chat. /agents focus PID sends them to a running agent.")
        case .agent(let pid):
          await terminal.line("Messages go to agent#\(pid.rawValue). /agents focus main returns to the chat.")
        }
        return
      }
      guard let target = focusTarget(trimmed) else {
        await terminal.line("Usage: /agents focus <PID|main>")
        return
      }
      switch target {
      case .main:
        loop.focus = .main
        await terminal.line("Messages go to this chat again.")
      case .agent(let pid):
        guard let info = await runtime.supervisor.info(pid) else {
          await terminal.line("No agent #\(pid.rawValue). /agents tree lists the running ones.")
          return
        }
        guard info.depth > 0, !info.state.isTerminal else {
          await terminal.line(
            info.depth == 0
              ? "agent#\(pid.rawValue) is this chat; /agents focus main is the same thing."
              : "agent#\(pid.rawValue) (\(info.agentID)) has finished; pick a running one from /agents tree."
          )
          return
        }
        loop.focus = .agent(pid)
        await terminal.line(
          "Messages go to agent#\(pid.rawValue) (\(info.agentID)) until /agents focus main; @main TEXT still reaches the chat."
        )
      }
    }

    reader.start()
    await releaseReader(workspace: workspace)

    events: for await event in events {
      switch event {
      case .line(let raw, let heredoc):
        loop.readerParked = true
        let text = heredoc ? raw : raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          await releaseIfIdle(workspace: workspace)
          continue
        }
        if !heredoc, await answerApproval(text) {
          await refreshStatus()
          await releaseIfIdle(workspace: workspace)
          continue
        }
        if !heredoc, let addressed = addressedMessage(text) {
          await deliver(addressed.body, to: addressed.target)
          await releaseIfIdle(workspace: workspace)
          continue
        }
        if !heredoc, text.hasPrefix("/") {
          let command = text.split(maxSplits: 1, whereSeparator: \Character.isWhitespace)
          let name = String(command[0])
          let argument =
            command.count > 1
            ? command[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
          if name == "/queue" {
            let main = await mainProcess()
            await handleQueueCommand(
              argument, focus: loop.focus, main: main, runtime: runtime, terminal: terminal)
            await refreshStatus()
            await releaseIfIdle(workspace: workspace)
            continue
          }
          if name == "/agents" || name == "/agent",
            argument == "focus" || argument.hasPrefix("focus ")
          {
            await handleFocus(String(argument.dropFirst("focus".count)))
            await refreshStatus()
            await releaseIfIdle(workspace: workspace)
            continue
          }
          if name == "/exit" || name == "/quit" {
            loop.exiting = true
            if let turn = loop.activeTurn {
              turn.task.cancel()
              continue
            }
            break events
          }
          if loop.activeTurn != nil, !commandsAllowedDuringTurn.contains(name) {
            await terminal.note(
              "\(name) waits for the running turn; Ctrl+C cancels it. Messages typed now are queued."
            )
            await releaseIfIdle(workspace: workspace)
            continue
          }
          if name == "/project" {
            await handleProjectCommand(
              argument,
              project: &project,
              home: home,
              store: store,
              terminal: terminal)
            await releaseIfIdle(workspace: workspace)
            continue
          }
          if name == "/chat" {
            workspace.upsert(session.chat, selecting: true)
            await handleWorkspaceChatCommand(
              argument,
              session: &session,
              workspace: &workspace,
              runtime: runtime,
              configuration: configuration,
              terminal: terminal)
            workspace.upsert(session.chat, selecting: true)
            await saveWorkspace(&workspace, store: store, terminal: terminal)
            await releaseIfIdle(workspace: workspace)
            continue
          }
          #if PMAI_HAS_VISUAL
            if text == "/visual" {
              workspace.upsert(session.chat, selecting: true)
              session.visualSnapshot = visualSnapshot(for: workspace)
            }
          #endif
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
            loop.exiting = true
            break events
          }
          #if PMAI_HAS_VISUAL
            if text == "/visual", let snapshot = session.visualSnapshot {
              workspace = chatWorkspace(from: snapshot, focusedID: session.id, previous: workspace)
              session = REPLSession(chat: workspace.selectedChat!)
            } else {
              session.touch()
              workspace.upsert(session.chat, selecting: true)
            }
          #else
            session.touch()
            workspace.upsert(session.chat, selecting: true)
          #endif
          await saveWorkspace(&workspace, store: store, terminal: terminal)
          await releaseIfIdle(workspace: workspace)
          continue
        }
        await deliver(text, to: loop.focus)
        await releaseIfIdle(workspace: workspace)

      case .interrupt:
        loop.readerParked = true
        if let turn = loop.activeTurn {
          turn.task.cancel()
        } else if let waiting = loop.approvals.first {
          loop.approvals.removeFirst()
          waiting.reply.fail(CancellationError())
        } else if loop.editingApproval != nil {
          loop.editingApproval?.reply.resume(with: .deny(reason: "Edit cancelled."))
          loop.editingApproval = nil
        } else if screen != nil {
          await terminal.note("Nothing to cancel. /exit or Ctrl+D quits.")
        }
        await refreshStatus()
        await releaseIfIdle(workspace: workspace)

      case .endOfFile:
        loop.readerParked = true
        loop.exiting = true
        if let turn = loop.activeTurn {
          turn.task.cancel()
          continue
        }
        break events

      case .turnFinished(let outcome):
        interruptHandler.deactivate()
        let turn = loop.activeTurn
        loop.activeTurn = nil
        var succeeded = false
        switch outcome {
        case .success(let result):
          session.history.replaceAll(with: result.transcript)
          succeeded = true
        case .failure(let error):
          if error is CancellationError || interruptHandler.interruptedActiveOperation() {
            await terminal.recoverAfterCancellation()
          } else {
            await terminal.recoverAfterError(error.localizedDescription)
          }
        }
        if let turn { await terminal.note("took \(elapsedDescription(since: turn.started))") }
        session.touch()
        workspace.upsert(session.chat, selecting: true)
        await saveWorkspace(&workspace, store: store, terminal: terminal)
        if loop.exiting { break events }
        if let turn {
          let waiting = await runtime.supervisor.queuedMessages(for: turn.pid).count
          if waiting > 0, succeeded {
            // Typed after the run's last look at its inbox: it becomes the
            // next turn right away, the way it would have joined this one.
            await startTurn([])
          } else if waiting > 0 {
            await terminal.note(
              "\(waiting) queued message\(waiting == 1 ? "" : "s") still waiting: /queue shows them; they go with your next message."
            )
          }
        }
        await refreshStatus()
        await releaseIfIdle(workspace: workspace)

      case .approval(let request, let reply):
        loop.approvals.append((request, reply))
        await terminal.approvalRequest(request)
        await refreshStatus()

      case .supervisor(let change):
        switch change {
        case .finished(let info) where info.depth > 0:
          await terminal.processEnded(info)
          if loop.focus == .agent(info.pid) {
            loop.focus = .main
            await terminal.note("agent#\(info.pid.rawValue) has ended; messages go to this chat again.")
          }
        case .attention where screen != nil:
          await announceAgentAttention(
            runtime: runtime, announced: &announcedAttention, terminal: terminal,
            skippingApprovals: true)
        default:
          break
        }
        await refreshStatus()
      }
    }

    for waiting in loop.approvals { waiting.reply.fail(CancellationError()) }
    loop.editingApproval?.reply.fail(CancellationError())
    reader.stop()
    supervisorFeed.cancel()
    continuation.finish()
    await visual.approvalHandler.setPrompter(nil)
    workspace.upsert(session.chat, selecting: true)
    await saveWorkspace(&workspace, store: store, terminal: terminal, closing: true)
    await terminal.attach(screen: nil)
    editor.install(surface: nil)
    TerminalScreen.install(nil)
    screen?.deactivate()
  }

  /// Reports background agents that are waiting on somebody, once each. A
  /// process that stops asking and asks again is announced again.
  private static func announceAgentAttention(
    runtime: AgentRuntime,
    announced: inout Set<AgentPID>,
    terminal: TerminalWriter,
    skippingApprovals: Bool = false
  ) async {
    // On the persistent screen an approval is already a question at the
    // prompt, so only the other kinds of attention need a line here.
    let waiting = await runtime.supervisor.processesNeedingAttention().filter { process in
      guard skippingApprovals, case .approval = process.attention else { return true }
      return false
    }
    let pids = Set(waiting.map(\.pid))
    announced.formIntersection(pids)
    for process in waiting where !announced.contains(process.pid) {
      announced.insert(process.pid)
      let verb =
        switch process.attention {
        case .approval: "needs approval"
        case .input: "is waiting for you"
        case .error: "stopped"
        case .finished: "finished"
        case nil: "changed"
        }
      await terminal.line(
        "agent \(process.pid) (\(process.agentID)) \(verb): "
          + "\(process.attention?.summary ?? "")  ·  /agents log \(process.pid.rawValue)")
    }
  }

  private static func submit(
    _ text: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    process: inout AgentPID?,
    terminal: TerminalWriter,
    interruptHandler: TerminalInterruptHandler? = nil
  ) async -> Bool {
    var content: [ContentPart] = [.text(text)]
    content.append(contentsOf: session.pendingContent)
    session.pendingContent.removeAll()
    session.history.append(AgentMessage(role: .user, content: content))
    session.refreshTitle(from: text)
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
        useToolProxy: profile.useToolProxy,
        toolDelegation: profile.toolDelegation)
      let existingProcess = process
      let task = Task {
        try await runtime.run(request, process: existingProcess) { event in
          await terminal.consume(event)
        }
      }
      interruptHandler?.activate { task.cancel() }
      defer { interruptHandler?.deactivate() }
      let result = try await task.value
      process = await runtime.supervisor.tree().processes.first { $0.runID == result.runID }?.pid
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

  /// The agent and model a chat runs on, as `[agent] model`. The provider
  /// stands in while no model is selected.
  private static func promptIdentity(_ session: REPLSession) -> String {
    let profile = session.profile
    let model = profile.model.isEmpty ? profile.provider.rawValue : profile.model
    return "[\(profile.agentID)] \(model)"
  }

  /// How long a turn took, as `5s`, `1m4s`, or `2h3m4s`.
  private static func elapsedDescription(since start: ContinuousClock.Instant) -> String {
    let parts = (ContinuousClock.now - start).components
    let total = Int(parts.seconds) + (parts.attoseconds >= 500_000_000_000_000_000 ? 1 : 0)
    guard total >= 1 else { return "<1s" }
    let (hours, minutes, seconds) = (total / 3600, total % 3600 / 60, total % 60)
    if hours > 0 { return "\(hours)h\(minutes)m\(seconds)s" }
    if minutes > 0 { return "\(minutes)m\(seconds)s" }
    return "\(seconds)s"
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
    return "\(messageLabel) ~\(compactTokenCount(estimatedTokens)) tok"
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
      switch argument.lowercased() {
      case "":
        await terminal.line(replHelp)
      case "set", "/set":
        await terminal.line(setHelp)
      case "memory", "/memory":
        await terminal.line(memoryHelp)
      case "todo", "/todo":
        await terminal.line(todoHelp)
      case "agents", "agent", "/agents", "/agent":
        await terminal.line(agentsHelp)
      case "chat", "/chat":
        await terminal.line(chatHelp)
      case "edit", "/edit":
        await terminal.line(editHelp)
      case "tools", "/tools":
        await terminal.line(toolHelp)
      case "queue", "/queue":
        await terminal.line(queueHelp)
      default:
        await terminal.line(
          "Unknown help topic '\(argument)'. Try /help, or /help set, memory, agents, chat, edit, tools, or queue."
        )
      }
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
          (visual.providerBaseURLs.url(for: provider.id.rawValue)
          ?? configuration?.providers.first { $0.id == provider.id.rawValue }?.baseURL)
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
    case "/todo":
      await handleTodoCommand(argument, todo: visual.todo, terminal: terminal)
    case "/memory":
      await handleMemoryCommand(
        argument,
        session: session,
        runtime: runtime,
        memory: visual.memory,
        configuration: &configuration,
        configurationPath: visual.configurationPath,
        terminal: terminal)
    case "/prompts":
      await showPrompts(session: session, configuration: configuration, terminal: terminal)
    case "/prompt":
      await handlePromptCommand(
        argument,
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: visual.configurationPath,
        terminal: terminal)
    case "/chat":
      await handleChatCommand(
        argument,
        session: &session,
        runtime: runtime,
        compactPrompt: configuration?.prompts?.compact,
        terminal: terminal)
    case "/edit":
      await handleEditCommand(
        argument,
        session: &session,
        runtime: runtime,
        memory: visual.memory,
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
        providerBaseURLs: visual.providerBaseURLs,
        terminal: terminal)
    case "/baseurl":
      await handleBaseURLCommand(
        argument,
        currentProvider: session.profile.provider,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: visual.configurationPath,
        providerBaseURLs: visual.providerBaseURLs,
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
      await handleAgentsCommand(
        argument,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: visual.configurationPath,
        providerBaseURLs: visual.providerBaseURLs,
        terminal: terminal)
    case "/agent":
      await handleAgentCommand(
        argument,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: visual.configurationPath,
        providerBaseURLs: visual.providerBaseURLs.snapshot(),
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
    #if PMAI_HAS_VISUAL
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
    #endif
    case "/clear":
      session.reset()
      await terminal.line("Conversation cleared.")
    case "/queue":
      await terminal.line("The message queue lives at the terminal prompt.\n" + queueHelp)
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

  private static func resolvedSystemPromptName(
    _ requested: String,
    configuration: MaiConfiguration?
  ) -> String? {
    let names = configuration?.prompts?.system.keys ?? [String: String]().keys
    if names.contains(requested) { return requested }
    let matches = names.filter { $0.caseInsensitiveCompare(requested) == .orderedSame }
    return matches.count == 1 ? matches[0] : nil
  }

  /// `/todo` in full: the same list the `todo_*` tools drive, for the person
  /// at the keyboard. Every action reads the file afresh, so the list an
  /// agent just changed is what gets shown or edited.
  private static func handleTodoCommand(
    _ argument: String,
    todo: TodoState,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(
      String.init)
    let action = fields.first?.lowercased() ?? ""
    let rest = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    var list = todo.current

    switch action {
    case "", "show", "list":
      await terminal.line(list.listing)

    case "add":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /todo add TEXT")
        return
      }
      await terminal.line(
        MaiTodoTools.execute(
          name: MaiTodoTools.addName, arguments: ["title": .string(rest)], list: &list))
      await storeTodo(list, in: todo, terminal: terminal)

    case "done", "check":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /todo done NUMBER|TEXT")
        return
      }
      await terminal.line(
        MaiTodoTools.execute(
          name: MaiTodoTools.doneName, arguments: ["task": .string(rest)], list: &list))
      await storeTodo(list, in: todo, terminal: terminal)

    case "edit":
      guard
        let edited = await editTemporaryText(
          list.markdown, suffix: AgentTodoList.filename, terminal: terminal)
      else { return }
      await storeTodo(AgentTodoList(markdown: edited), in: todo, terminal: terminal)

    case "clear":
      await storeTodo(AgentTodoList(), in: todo, terminal: terminal)

    case "path":
      await terminal.line(todo.url?.path ?? AgentTodoList.filename)

    default:
      await terminal.line(todoHelp)
    }
  }

  private static func storeTodo(
    _ list: AgentTodoList,
    in todo: TodoState,
    terminal: TerminalWriter
  ) async {
    do {
      try todo.save(list)
      await terminal.line(
        list.isEmpty
          ? "Todo list cleared."
          : "Todo list saved to \(todo.url?.path ?? AgentTodoList.filename) (\(list.pendingCount) pending, \(list.doneCount) done)."
      )
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  /// `/memory` in full: read it, edit it, extend it from what was said, and
  /// decide how far the chat tools may look.
  private static func handleMemoryCommand(
    _ argument: String,
    session: REPLSession,
    runtime: AgentRuntime,
    memory: MemoryState,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(
      String.init)
    let action = fields.first?.lowercased() ?? ""
    let rest = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    let settings = memory.configuration

    switch action {
    case "", "show":
      let current = memory.current
      let state = settings.enabled ? "on" : "off"
      await terminal.line(
        "Memory: \(state) · scope \(settings.scope.rawValue) · \(current.lineCount) line\(current.lineCount == 1 ? "" : "s")"
      )
      await terminal.line(current.isEmpty ? "(empty)" : current.text)

    case "edit":
      guard
        let edited = await editTemporaryText(
          memory.current.text, suffix: "memory.md", terminal: terminal)
      else { return }
      await store(
        AgentMemory(text: edited), in: memory, runtime: runtime, terminal: terminal)

    case "set", "replace":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /memory set TEXT")
        return
      }
      await store(AgentMemory(text: rest), in: memory, runtime: runtime, terminal: terminal)

    case "add", "append":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /memory add TEXT")
        return
      }
      var updated = memory.current
      updated.append(rest)
      await store(updated, in: memory, runtime: runtime, terminal: terminal)

    case "clear", "forget":
      await store(AgentMemory(), in: memory, runtime: runtime, terminal: terminal)

    case "reload":
      memory.reload()
      await runtime.configureMemory(memory.promptSection)
      await terminal.line("Reloaded \(memory.url?.path ?? AgentMemory.filename).")

    case "learn":
      await learnMemory(
        rest,
        session: session,
        runtime: runtime,
        memory: memory,
        promptTemplate: configuration?.prompts?.memory,
        terminal: terminal)

    case "scope":
      guard !rest.isEmpty else {
        await terminal.line("Memory scope: \(settings.scope.rawValue)")
        return
      }
      guard let scope = MemoryScope(rawValue: rest.lowercased()) else {
        await terminal.line("Usage: /memory scope <none|project|all>")
        return
      }
      await persistMemorySettings(
        ConfiguredMemory(enabled: settings.enabled, scope: scope),
        memory: memory,
        configuration: &configuration,
        configurationPath: configurationPath,
        note:
          "The chat tools now read \(scope == .none ? "nothing" : scope.displayName.lowercased()).",
        terminal: terminal)

    case "on", "off":
      await persistMemorySettings(
        ConfiguredMemory(enabled: action == "on", scope: settings.scope),
        memory: memory,
        configuration: &configuration,
        configurationPath: configurationPath,
        note:
          action == "on"
          ? "Memory is added to the system prompt again."
          : "Memory is kept but no longer sent to the model.",
        terminal: terminal)
      await runtime.configureMemory(memory.promptSection)

    default:
      await terminal.line(memoryHelp)
    }
  }

  private static func store(
    _ updated: AgentMemory,
    in memory: MemoryState,
    runtime: AgentRuntime,
    terminal: TerminalWriter
  ) async {
    do {
      try memory.save(updated)
      await runtime.configureMemory(memory.promptSection)
      await terminal.line(
        updated.isEmpty
          ? "Memory cleared."
          : "Memory saved to \(memory.url?.path ?? AgentMemory.filename) (\(updated.lineCount) line\(updated.lineCount == 1 ? "" : "s"))."
      )
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  private static func persistMemorySettings(
    _ settings: ConfiguredMemory,
    memory: MemoryState,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    note: String,
    terminal: TerminalWriter
  ) async {
    memory.apply(settings)
    guard var draft = configuration, let configurationPath else {
      await terminal.line("\(note) (not saved: no writable configuration is active.)")
      return
    }
    draft.memory = settings
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      configuration = draft
      await terminal.line(note)
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  /// Folds conversations into the notes. The model is given what is already
  /// known and returns the merged set, so learning never silently forgets.
  private static func learnMemory(
    _ argument: String,
    session: REPLSession,
    runtime: AgentRuntime,
    memory: MemoryState,
    promptTemplate: String?,
    terminal: TerminalWriter
  ) async {
    var focus = argument
    var everyChat = false
    for flag in ["--all", "-a"] where focus == flag || focus.hasPrefix(flag + " ") {
      everyChat = true
      focus = String(focus.dropFirst(flag.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let chats =
      everyChat ? memory.projectChats() : [MemoryChat(session.chat, scope: session.title)]
    let transcript = AgentMemoryPrompt.transcript(of: chats)
    guard !transcript.isEmpty else {
      await terminal.line(
        everyChat ? "No conversations in this project yet." : "Nothing said in this chat yet.")
      return
    }
    if let template = promptTemplate,
      let missing = AgentMemoryPrompt.missingPlaceholder(in: template)
    {
      await terminal.line(
        "error: The memory prompt must contain \(missing). Edit it with /edit memory-prompt.",
        to: .standardError)
      return
    }

    let existing = memory.current
    let profile = session.profile
    let request = AgentRequest(
      agentID: profile.agentID,
      provider: profile.provider,
      model: profile.model,
      messages: [
        .user(
          AgentMemoryPrompt.render(
            existing: existing,
            transcript: transcript,
            focus: focus,
            template: promptTemplate))
      ],
      toolChoice: .none,
      options: profile.options,
      limits: profile.limits,
      stream: false)
    await terminal.line(
      "Learning from \(everyChat ? "\(chats.count) chat\(chats.count == 1 ? "" : "s")" : "this chat")…"
    )
    do {
      let result = try await runtime.run(request) { _ in }
      let learned = MessageContentFilter.promptSafeText(from: result.response.text)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !learned.isEmpty else {
        await terminal.line("Nothing durable to remember; memory is unchanged.")
        return
      }
      await store(AgentMemory(text: learned), in: memory, runtime: runtime, terminal: terminal)
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  private static func showPrompts(
    session: REPLSession,
    configuration: MaiConfiguration?,
    terminal: TerminalWriter
  ) async {
    let compact = configuration?.prompts?.compact?.trimmingCharacters(
      in: .whitespacesAndNewlines)
    let delegation = configuration?.prompts?.delegation?.trimmingCharacters(
      in: .whitespacesAndNewlines)
    let worker = configuration?.prompts?.worker?.trimmingCharacters(in: .whitespacesAndNewlines)
    let memoryPrompt = configuration?.prompts?.memory?.trimmingCharacters(
      in: .whitespacesAndNewlines)
    var lines = [
      "Prompts:",
      "  compact     compact     \(compact?.isEmpty == false ? "custom" : "built-in")",
      "  delegation  delegation  \(delegation?.isEmpty == false ? "custom" : "built-in")",
      "  worker      delegation  \(worker?.isEmpty == false ? "custom" : "built-in")",
      "  memory      memory      \(memoryPrompt?.isEmpty == false ? "custom" : "built-in")",
    ]
    let prompts = configuration?.prompts?.system ?? [:]
    for name in prompts.keys.sorted() {
      let selected = session.profile.systemPrompt == name ? "*" : " "
      let agents = configuration?.agents.filter { $0.systemPrompt == name }.map(\.id).sorted() ?? []
      let usage = agents.isEmpty ? "unused" : "agents: \(agents.joined(separator: ", "))"
      lines.append("\(selected) \(name)  system  \(usage)")
    }
    if prompts.isEmpty { lines.append("  No named system prompts.") }
    await terminal.line(lines.joined(separator: "\n"))
  }

  private static func handlePromptCommand(
    _ argument: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    let requested = argument.trimmingCharacters(in: .whitespacesAndNewlines)
    if requested.isEmpty {
      let name = session.profile.systemPrompt ?? "inline"
      await terminal.line("System prompt for agent '\(session.profile.agentID)': \(name)")
      await terminal.line(
        session.profile.instructions.isEmpty ? "(empty)" : session.profile.instructions)
      return
    }
    guard
      let name = resolvedSystemPromptName(requested, configuration: configuration),
      let instructions = configuration?.prompts?.system[name]
    else {
      await terminal.line("Unknown system prompt '\(requested)'. Use /prompts.")
      return
    }
    let previous = session.profile.instructions
    do {
      try applySystemInstructions(instructions, replacing: previous, session: &session)
      session.profile.systemPrompt = name
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      return
    }
    if await persistAgentProfile(
      session: session,
      configuration: &configuration,
      configurationPath: configurationPath,
      runtime: runtime,
      terminal: terminal)
    {
      await terminal.line(
        "Agent '\(session.profile.agentID)' now uses system prompt '\(name)'.")
    }
  }

  private static func applySystemInstructions(
    _ instructions: String,
    replacing previous: String,
    session: inout REPLSession
  ) throws {
    session.profile.instructions = instructions
    if let index = session.history.messages.firstIndex(where: {
      $0.role == .system && $0.text == previous
    }) {
      if instructions.isEmpty {
        _ = try session.history.removeMessage(at: index)
      } else {
        try session.history.editMessage(at: index, text: instructions)
      }
    } else if !instructions.isEmpty {
      session.history.replaceAll(with: [.system(instructions)] + session.history.messages)
    }
    session.touch()
  }

  private static func editSystemPrompt(
    named requested: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard var draft = configuration, let configurationPath else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return
    }
    let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      await terminal.line("Usage: /edit prompt [NAME]")
      return
    }
    let name = resolvedSystemPromptName(trimmed, configuration: draft) ?? trimmed
    var prompts = draft.prompts ?? ConfiguredPrompts()
    let previous = prompts.system[name] ?? ""
    guard
      let edited = await editTemporaryText(
        previous, suffix: "system-prompt.md", terminal: terminal)
    else { return }
    let instructions = edited.trimmingCharacters(in: .whitespacesAndNewlines)
    prompts.system[name] = instructions
    draft.prompts = prompts
    for index in draft.agents.indices where draft.agents[index].systemPrompt == name {
      draft.agents[index].instructions = instructions
    }
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      configuration = draft
      for agent in draft.agents where agent.systemPrompt == name {
        try await runtime.register(agent: agent, replacingExisting: true)
      }
      if session.profile.systemPrompt == name {
        try applySystemInstructions(
          instructions, replacing: session.profile.instructions, session: &session)
      }
      await terminal.line("System prompt '\(name)' saved to \(configurationPath).")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
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
    memory: MemoryState,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    let target = argument.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else {
      await terminal.line(editHelp)
      return
    }
    let fields = target.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(
      String.init)
    let action = fields[0].lowercased()
    let actionArgument = fields.count == 2 ? fields[1] : ""

    switch action {
    case "prompt", "system":
      await editSystemPrompt(
        named: actionArgument.isEmpty
          ? session.profile.systemPrompt ?? session.profile.agentID : actionArgument,
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)

    case "compact":
      guard var draft = configuration, let configurationPath else {
        await terminal.line("error: No writable configuration is active.", to: .standardError)
        return
      }
      let previous = draft.prompts?.compact ?? defaultCompactPrompt
      guard
        let edited = await editTemporaryText(
          previous, suffix: "compact-prompt.md", terminal: terminal)
      else { return }
      let candidate = edited.trimmingCharacters(in: .whitespacesAndNewlines)
      guard candidate.isEmpty || candidate.contains("{{transcript}}") else {
        await terminal.line(
          "error: The compact prompt must contain {{transcript}}; no changes were saved.",
          to: .standardError)
        return
      }
      let customPrompt =
        candidate.isEmpty || candidate == defaultCompactPrompt ? nil : candidate
      var prompts = draft.prompts ?? ConfiguredPrompts()
      prompts.compact = customPrompt
      draft.prompts = prompts
      do {
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        configuration = draft
        await terminal.line(
          customPrompt == nil
            ? "Compact prompt restored to the built-in default."
            : "Compact prompt saved to \(configurationPath).")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }

    case "memory":
      guard
        let edited = await editTemporaryText(
          memory.current.text, suffix: "memory.md", terminal: terminal)
      else { return }
      await store(AgentMemory(text: edited), in: memory, runtime: runtime, terminal: terminal)

    case "memory-prompt", "learn":
      guard var draft = configuration, let configurationPath else {
        await terminal.line("error: No writable configuration is active.", to: .standardError)
        return
      }
      var prompts = draft.prompts ?? ConfiguredPrompts()
      guard
        let edited = await editTemporaryText(
          prompts.memory ?? AgentMemoryPrompt.template,
          suffix: "memory-prompt.md",
          terminal: terminal)
      else { return }
      let candidate = edited.trimmingCharacters(in: .whitespacesAndNewlines)
      if let missing = AgentMemoryPrompt.missingPlaceholder(in: candidate) {
        await terminal.line(
          "error: The memory prompt must contain \(missing); no changes were saved.",
          to: .standardError)
        return
      }
      prompts.memory =
        candidate.isEmpty || candidate == AgentMemoryPrompt.template ? nil : candidate
      draft.prompts = prompts
      do {
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        configuration = draft
        await terminal.line(
          prompts.memory == nil
            ? "The memory prompt was restored to the built-in default."
            : "The memory prompt was saved to \(configurationPath).")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }

    case "delegation", "worker":
      guard var draft = configuration, let configurationPath else {
        await terminal.line("error: No writable configuration is active.", to: .standardError)
        return
      }
      var prompts = draft.prompts ?? ConfiguredPrompts()
      let isBrief = action == "delegation"
      let builtIn =
        isBrief ? AgentDelegationPrompt.template : AgentDelegationPrompt.workerInstructions
      let previous = (isBrief ? prompts.delegation : prompts.worker) ?? builtIn
      guard
        let edited = await editTemporaryText(
          previous, suffix: "\(action)-prompt.md", terminal: terminal)
      else { return }
      let candidate = edited.trimmingCharacters(in: .whitespacesAndNewlines)
      if isBrief, let missing = AgentDelegationPrompt.missingPlaceholder(in: candidate) {
        await terminal.line(
          "error: The delegation prompt must contain \(missing); no changes were saved.",
          to: .standardError)
        return
      }
      let custom = candidate.isEmpty || candidate == builtIn ? nil : candidate
      if isBrief { prompts.delegation = custom } else { prompts.worker = custom }
      draft.prompts = prompts
      do {
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        await runtime.configureDelegation(
          prompt: prompts.delegation, workerInstructions: prompts.worker)
        configuration = draft
        await terminal.line(
          custom == nil
            ? "The \(action) prompt was restored to the built-in default."
            : "The \(action) prompt was saved to \(configurationPath).")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }

    case "config":
      guard let configurationPath else {
        await terminal.line("error: No writable configuration is active.", to: .standardError)
        return
      }
      let url = URL(fileURLWithPath: configurationPath)
      guard await launchEditor(at: url, terminal: terminal) else { return }
      do {
        var editedConfiguration = try MaiConfiguration.load(from: url)
        if editedConfiguration.associateSystemPrompts() {
          try editedConfiguration.save(to: url)
        }
        for agent in editedConfiguration.agents {
          try await runtime.register(agent: agent, replacingExisting: true)
        }
        await runtime.configureDelegation(
          prompt: editedConfiguration.prompts?.delegation,
          workerInstructions: editedConfiguration.prompts?.worker)
        if let agent = editedConfiguration.agents.first(where: {
          $0.id == session.profile.agentID
        }) {
          session.profile.limits = agent.limits
          session.profile.toolCallingStrategy = agent.toolCallingStrategy
          session.profile.toolDelegation = agent.toolDelegation
          session.profile.systemPrompt = agent.systemPrompt
          try applySystemInstructions(
            agent.instructions,
            replacing: session.profile.instructions,
            session: &session)
        }
        configuration = editedConfiguration
        await terminal.line(
          "Configuration saved. Agent limits and tool-calling strategy were applied; "
            + "restart pmai to apply provider, plugin, tool, or MCP changes.")
      } catch {
        await terminal.line(
          "error: The edited configuration was not loaded: \(error.localizedDescription)",
          to: .standardError)
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
        guard let edited = await editTemporaryData(data, suffix: "mcps.json", terminal: terminal)
        else {
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
      if let name = resolvedSystemPromptName(target, configuration: configuration) {
        await editSystemPrompt(
          named: name,
          session: &session,
          runtime: runtime,
          configuration: &configuration,
          configurationPath: configurationPath,
          terminal: terminal)
        return
      }
      guard let index = editableMessageIndex(target, in: session.history) else {
        await terminal.line("Unknown edit target '\(target)'.\n\n\(editHelp)")
        return
      }
      let message = session.history[index]
      guard
        let edited = await editTemporaryText(message.text, suffix: "message.md", terminal: terminal)
      else { return }
      do {
        try session.history.editMessage(at: index, text: edited)
        await terminal.line("Edited message \(index + 1) (id: \(message.id)).")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
    }
  }

  private static func editableMessageIndex(_ target: String, in transcript: AgentTranscript) -> Int?
  {
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
    var waitStatus: CInt = -1
    let launch = { waitStatus = shellCommand.withCString(posixSystem) }
    if let screen = TerminalScreen.current {
      screen.suspendTerminal(launch)
    } else {
      launch()
    }
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
    providerBaseURLs: ProviderBaseURLStore,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(whereSeparator: \Character.isWhitespace).map(String.init)
    guard !fields.isEmpty else {
      let baseURL =
        providerBaseURLs.url(for: session.profile.provider.rawValue)?.absoluteString
        ?? configuration?.providers.first {
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
        providerBaseURLs: providerBaseURLs,
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
    providerBaseURLs: ProviderBaseURLStore,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(whereSeparator: \Character.isWhitespace).map(String.init)
    guard !fields.isEmpty else {
      let configuredURL = configuration?.providers.first {
        $0.id == currentProvider.rawValue
      }?.baseURL
      let effectiveURL = providerBaseURLs.url(for: currentProvider.rawValue) ?? configuredURL
      var detail = effectiveURL?.absoluteString ?? "-"
      if let effectiveURL, let configuredURL, effectiveURL != configuredURL {
        detail += " (runtime override; configured: \(configuredURL.absoluteString))"
      }
      await terminal.line("Base URL for '\(currentProvider)': \(detail)")
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
      providerBaseURLs.set(baseURL, for: providerID.rawValue)
      await terminal.line("Provider '\(providerID)' base URL set to \(baseURL.absoluteString).")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  /// `/agents` covers both halves of the model: the definitions people switch
  /// between, and the processes started from them.
  private static func handleAgentsCommand(
    _ argument: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    providerBaseURLs: ProviderBaseURLStore,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(maxSplits: 2, whereSeparator: \Character.isWhitespace).map(
      String.init)
    let action = fields.first?.lowercased() ?? ""

    switch action {
    case "", "list":
      await listAgentDefinitions(
        session: session,
        runtime: runtime,
        configuration: configuration,
        providerBaseURLs: providerBaseURLs,
        terminal: terminal)
      if action.isEmpty {
        let lines = await agentTreeLines(runtime: runtime)
        if !lines.isEmpty {
          await terminal.line("")
          await terminal.line(lines.joined(separator: "\n"))
        }
      }

    case "tree", "ps":
      let lines = await agentTreeLines(runtime: runtime)
      await terminal.line(lines.isEmpty ? "No agents are running." : lines.joined(separator: "\n"))

    case "log":
      guard fields.count >= 2, let pid = AgentPID(text: fields[1]) else {
        await terminal.line("Usage: /agents log PID")
        return
      }
      let messages = await runtime.supervisor.transcript(pid)
      guard !messages.isEmpty else {
        let known = await runtime.supervisor.info(pid) != nil
        await terminal.line(
          known ? "\(pid) has not produced a transcript yet." : "No agent \(pid).")
        return
      }
      var lines: [String] = []
      for (index, message) in messages.enumerated() {
        lines.append("## [\(index + 1)] \(message.role.rawValue.capitalized)")
        lines.append(message.content.map { renderFullContent($0) }.joined(separator: "\n"))
      }
      await terminal.line(lines.joined(separator: "\n"))

    case "kill", "stop":
      guard fields.count >= 2, let pid = AgentPID(text: fields[1]) else {
        await terminal.line("Usage: /agents kill PID [REASON]")
        return
      }
      guard await runtime.supervisor.info(pid) != nil else {
        await terminal.line("No agent \(pid).")
        return
      }
      let reason = fields.count > 2 ? fields[2] : "Stopped from the REPL"
      let stopped = await runtime.supervisor.stop(pid, reason: reason)
      await terminal.line(
        "Stopped \(stopped.map(\.description).joined(separator: ", ")).")

    case "enable", "disable":
      guard fields.count >= 2 else {
        await terminal.line("Usage: /agents \(action) ID")
        return
      }
      await setAgentEnabled(
        fields[1],
        enabled: action == "enable",
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)

    case "describe":
      guard fields.count >= 2 else {
        await terminal.line("Usage: /agents describe ID [TEXT]")
        return
      }
      await describeAgent(
        fields[1],
        text: fields.count > 2 ? fields[2] : nil,
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)

    case "use", "show", "add", "acp":
      await handleAgentCommand(
        argument,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: configurationPath,
        providerBaseURLs: providerBaseURLs.snapshot(),
        terminal: terminal)

    default:
      await terminal.line(agentsHelp)
    }
  }

  private static func listAgentDefinitions(
    session: REPLSession,
    runtime: AgentRuntime,
    configuration: MaiConfiguration?,
    providerBaseURLs: ProviderBaseURLStore,
    terminal: TerminalWriter
  ) async {
    let agents: [AgentDefinition]
    if let configured = configuration?.agents {
      agents = configured
    } else {
      agents = await runtime.availableAgents()
    }
    guard !agents.isEmpty else {
      await terminal.line("No configured agents.")
      return
    }
    for agent in agents {
      let isCurrent = agent.id == session.profile.agentID
      let displayed = isCurrent ? session.profile.agentDefinition : agent
      let baseURL =
        providerBaseURLs.url(for: displayed.provider.rawValue)?.absoluteString
        ?? configuration?.providers.first { $0.id == displayed.provider.rawValue }?.baseURL?
        .absoluteString ?? "-"
      let marker = isCurrent ? "*" : (displayed.isEnabled ? " " : "-")
      var line =
        "\(marker) \(displayed.id) — \(displayed.displayName) [\(displayed.provider) \(baseURL) \(displayed.model)]"
      if displayed.toolDelegation.delegatesTools { line += " delegating" }
      if !displayed.isEnabled { line += " (disabled)" }
      await terminal.line(line)
      if !displayed.description.isEmpty {
        await terminal.line("    \(displayed.description)")
      }
    }
  }

  private static func agentTreeLines(runtime: AgentRuntime) async -> [String] {
    let tree = await runtime.supervisor.tree()
    guard !tree.isEmpty else { return [] }
    return ["Running agents:"] + tree.lines() + [agentTreeTotal(tree)]
  }

  /// One row summing what the whole tree has spent so far.
  static func agentTreeTotal(_ tree: AgentProcessTree) -> String {
    let turns = tree.processes.reduce(0) { $0 + $1.modelTurns }
    let tools = tree.processes.reduce(0) { $0 + $1.toolCalls }
    let tokens = tree.processes.reduce(0) { $0 + ($1.usage?.totalTokens ?? 0) }
    return
      "Total: \(turns) turn\(turns == 1 ? "" : "s"), \(tools) tool\(tools == 1 ? "" : "s"), \(tokens) token\(tokens == 1 ? "" : "s")"
  }

  private static func setAgentEnabled(
    _ id: String,
    enabled: Bool,
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard var draft = configuration, let configurationPath,
      let index = draft.agents.firstIndex(where: { $0.id == id })
    else {
      await terminal.line("Unknown agent '\(id)', or no writable configuration is active.")
      return
    }
    guard enabled || draft.agents[index].id != session.profile.agentID else {
      await terminal.line(
        "Agent '\(id)' is the one this chat uses. Switch with /agent use ID before disabling it.")
      return
    }
    draft.agents[index].isEnabled = enabled
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      try await runtime.register(agent: draft.agents[index], replacingExisting: true)
      configuration = draft
      await terminal.line("Agent '\(id)' \(enabled ? "enabled" : "disabled").")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  private static func describeAgent(
    _ id: String,
    text: String?,
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard var draft = configuration, let configurationPath,
      let index = draft.agents.firstIndex(where: { $0.id == id })
    else {
      await terminal.line("Unknown agent '\(id)', or no writable configuration is active.")
      return
    }
    guard let text else {
      let existing = draft.agents[index].description
      await terminal.line(existing.isEmpty ? "Agent '\(id)' has no description." : existing)
      return
    }
    draft.agents[index].description = text.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      try await runtime.register(agent: draft.agents[index], replacingExisting: true)
      if session.profile.agentID == id { session.touch() }
      configuration = draft
      await terminal.line("Described agent '\(id)'.")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  /// `/agent acp` registers an external ACP agent as a provider-backed agent,
  /// so it is selectable and spawnable like any other. `list` shows the builtin
  /// catalog and what is installed; `add NAME [COMMAND ARGS...]` persists one,
  /// defaulting the command from the catalog when only a known name is given.
  private static func handleAgentACPCommand(
    _ fields: [String],
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    let sub = fields.first?.lowercased() ?? "list"
    switch sub {
    case "list", "":
      for agent in ACPCatalog.agents {
        let mark = agent.isInstalled ? "\u{2705}" : "\u{274C}"
        let configured = configuration?.providers.contains { $0.id == agent.id } == true
        await terminal.line(
          "\(mark) \(agent.id) — \(agent.summary)\(configured ? " [configured]" : "")")
      }
      await terminal.line(
        "Add one with /agent acp add NAME [COMMAND ARG ...]; a known name needs no command.")

    case "add":
      let rest = Array(fields.dropFirst())
      guard let name = rest.first else {
        await terminal.line("Usage: /agent acp add NAME [COMMAND ARG ...]")
        return
      }
      let provider: ConfiguredProvider
      if rest.count >= 2 {
        var options: [String: JSONValue] = ["command": .string(rest[1])]
        let args = Array(rest.dropFirst(2))
        if !args.isEmpty { options["args"] = .array(args.map(JSONValue.string)) }
        provider = ConfiguredProvider(
          id: name, kind: ACPConfiguredProviderFactory.providerKind, displayName: name,
          options: options)
      } else if let catalog = ACPCatalog.agent(name) {
        provider = catalog.configuredProvider()
        if !catalog.isInstalled, let install = catalog.install {
          await terminal.line("note: '\(name)' is not installed. Install it with: \(install)")
        }
      } else {
        await terminal.line(
          "Unknown ACP agent '\(name)'. Give a command, or use a catalog name (/agent acp list).")
        return
      }
      await registerACPAgent(
        provider,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)

    default:
      await terminal.line("Usage: /agent acp [list|add NAME [COMMAND ARG ...]]")
    }
  }

  /// Persists an ACP provider and a same-named agent, registers both live, and
  /// selects the agent for the current chat — the same shape `/agent add` uses.
  private static func registerACPAgent(
    _ provider: ConfiguredProvider,
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard var draft = configuration, let configurationPath else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return
    }
    if let index = draft.providers.firstIndex(where: { $0.id == provider.id }) {
      draft.providers[index] = provider
    } else {
      draft.providers.append(provider)
    }
    let definition = AgentDefinition(
      id: provider.id,
      displayName: provider.displayName ?? provider.id,
      description: ACPCatalog.agent(provider.id)?.summary ?? "External ACP agent.",
      instructions: "",
      provider: ProviderID(provider.id),
      model: provider.id)
    if let index = draft.agents.firstIndex(where: { $0.id == definition.id }) {
      draft.agents[index] = definition
    } else {
      draft.agents.append(definition)
    }
    do {
      let built = try await plugins.makeProvider(
        from: provider, environment: ProcessInfo.processInfo.environment)
      try await runtime.register(built, replacingExisting: true)
      try await runtime.register(agent: definition, replacingExisting: true)
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      configuration = draft
      session.reset(profile: SessionProfile(definition: definition))
      await terminal.line(
        "ACP agent '\(provider.id)' registered and selected for this chat. It runs like any other agent."
      )
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

    if action == "acp" {
      await handleAgentACPCommand(
        Array(fields.dropFirst()),
        session: &session,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
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
      let promptName = draft.agents.first(where: { $0.id == name })?.systemPrompt ?? name
      definition.systemPrompt = promptName
      var prompts = draft.prompts ?? ConfiguredPrompts()
      prompts.system[promptName] = definition.instructions
      draft.prompts = prompts
      if let index = draft.agents.firstIndex(where: { $0.id == name }) {
        draft.agents[index] = definition
      } else {
        draft.agents.append(definition)
      }
      for index in draft.agents.indices
      where draft.agents[index].systemPrompt == definition.systemPrompt {
        draft.agents[index].instructions = definition.instructions
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
      providerBaseURLs[definition.provider.rawValue]
      ?? configuration?.providers.first { $0.id == definition.provider.rawValue }?.baseURL
    await terminal.line("Agent: \(definition.id) (\(definition.displayName))")
    await terminal.line("Provider: \(definition.provider)")
    await terminal.line("Base URL: \(baseURL?.absoluteString ?? "-")")
    await terminal.line("Model: \(definition.model.isEmpty ? "-" : definition.model)")
    await terminal.line("Tool calling: \(definition.toolCallingStrategy.rawValue)")
    await terminal.line("System prompt: \(definition.systemPrompt ?? "inline")")
    await terminal.line(
      "Instructions: \(definition.instructions.isEmpty ? "-" : definition.instructions)")
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
    if let promptName = definition.systemPrompt {
      var prompts = draft.prompts ?? ConfiguredPrompts()
      prompts.system[promptName] = definition.instructions
      draft.prompts = prompts
      for index in draft.agents.indices where draft.agents[index].systemPrompt == promptName {
        draft.agents[index].instructions = definition.instructions
      }
    }
    if let index = draft.agents.firstIndex(where: { $0.id == definition.id }) {
      draft.agents[index] = definition
    } else {
      draft.agents.append(definition)
    }
    if draft.defaultAgent == nil { draft.defaultAgent = definition.id }
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      let affectedAgents =
        definition.systemPrompt.map { promptName in
          draft.agents.filter { $0.systemPrompt == promptName }
        } ?? [definition]
      for agent in affectedAgents {
        try await runtime.register(agent: agent, replacingExisting: true)
      }
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
        await terminal.line(
          "Enabled tool group '\(group.id)' for agent \(session.profile.agentID).")
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
        await terminal.line(
          "Disabled tool group '\(group.id)' for agent \(session.profile.agentID).")
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
      await terminal.line("delegation = \(session.profile.toolDelegation.rawValue)")
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
    if delegationSettingKeys.contains(key) {
      await setToolDelegation(
        parts: parts,
        session: &session,
        runtime: runtime,
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

    let colorKeys = [
      "ui.bgline", "ui.fgcolor", "ui.bgcolor", "ui.fgprompt", "ui.bgprompt",
      "ui.fgtoolresult",
    ]
    let booleanKeys = ["ui.bold", "ui.markdown"]
    let countKeys = ["ui.toolresultlines"]
    let levelKeys = ["ui.subagents"]
    guard
      colorKeys.contains(key) || booleanKeys.contains(key) || countKeys.contains(key)
        || levelKeys.contains(key)
    else {
      await terminal.line(
        "Unknown setting '\(parts[0])'. Available settings: yolo, delegation, toolCallingStrategy, limits.maxToolCalls, limits.maxModelTurns, limits.maxSubagents, limits.maxSubagentDepth, ui.bgline, ui.fgcolor, ui.bgcolor, ui.fgprompt, ui.bgprompt, ui.fgtoolresult, ui.bold, ui.markdown, ui.toolResultLines, ui.subagents"
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
      let value: Int
      if parts[1].lowercased() == "all" {
        value = -1
      } else if let count = Int(parts[1]), count >= 0 {
        value = count
      } else {
        await terminal.line("Usage: /set ui.toolResultLines <all|N>")
        return
      }
      ui.toolResultLines = value
      await terminal.configureToolResultLines(value)
    } else if levelKeys.contains(key) {
      guard let level = SubagentOutputLevel(rawValue: parts[1].lowercased()) else {
        await terminal.line(
          "Usage: /set ui.subagents <\(SubagentOutputLevel.allCases.map(\.rawValue).joined(separator: "|"))>"
        )
        return
      }
      ui.subagentOutput = level
      await terminal.configureSubagentOutput(level)
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
      case "ui.fgtoolresult":
        ui.toolResultForeground = color
        await terminal.configureToolResultColor(color)
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
    "limits.maxsubagentdepth": "limits.maxSubagentDepth",
  ]

  private static let delegationSettingKeys: Set<String> = [
    "delegation", "tools.delegation", "tooldelegation", "subagents",
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
    for key in [
      "limits.maxToolCalls", "limits.maxModelTurns", "limits.maxSubagents",
      "limits.maxSubagentDepth",
    ] {
      await terminal.line("\(key) = \(limitValue(key, in: limits))")
    }
  }

  private static func limitValue(_ key: String, in limits: AgentRunLimits) -> Int {
    switch key {
    case "limits.maxToolCalls": limits.maxToolCalls
    case "limits.maxSubagents": limits.maxSubagents
    case "limits.maxSubagentDepth": limits.maxSubagentDepth
    default: limits.maxModelTurns
    }
  }

  /// Moves where the current agent's tools run. Turning delegation on with no
  /// subagent budget would silently do nothing, so it raises the budget too.
  private static func setToolDelegation(
    parts: [String],
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard parts.count > 1 else {
      await terminal.line("delegation = \(session.profile.toolDelegation.rawValue)")
      return
    }
    let raw = parts[1].lowercased()
    let mode: AgentToolDelegation? =
      switch raw {
      case "off", "none", "self", "inline": .inline
      case "on", "child", "subagent", "subagents": .subagent
      default: nil
      }
    guard parts.count == 2, let mode else {
      await terminal.line("Usage: /set delegation <off|subagent>")
      return
    }
    session.profile.toolDelegation = mode
    var raised = false
    if mode == .subagent, session.profile.limits.maxSubagents < 1 {
      session.profile.limits.maxSubagents = 1
      raised = true
    }
    session.touch()
    var notes = [
      mode == .subagent
        ? "Tool calls now run in a child agent; this chat keeps only their answers."
        : "Tool calls now run in this chat."
    ]
    if raised { notes.append("Raised limits.maxSubagents to 1.") }
    guard var draft = configuration, let configurationPath,
      let index = draft.agents.firstIndex(where: { $0.id == session.profile.agentID })
    else {
      await terminal.line(
        (["Set delegation = \(mode.rawValue) for this chat."] + notes).joined(separator: " "))
      return
    }
    draft.agents[index].toolDelegation = mode
    draft.agents[index].limits = session.profile.limits
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      try await runtime.register(agent: session.profile.agentDefinition, replacingExisting: true)
      configuration = draft
      await terminal.line(
        (["Set delegation = \(mode.rawValue) for agent '\(session.profile.agentID)'."] + notes)
          .joined(separator: " "))
    } catch {
      await terminal.line(
        "Set delegation = \(mode.rawValue) for this chat; could not save the configuration: \(error.localizedDescription)",
        to: .standardError)
    }
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
    let current = limitValue(key, in: limits)
    guard parts.count > 1 else {
      await terminal.line("\(key) = \(current)")
      return
    }
    guard parts.count == 2, let value = Int(parts[1]), value >= 0 else {
      await terminal.line("Usage: /set \(key) N  (a non-negative integer)")
      return
    }
    switch key {
    case "limits.maxToolCalls": limits.maxToolCalls = value
    case "limits.maxSubagents": limits.maxSubagents = value
    case "limits.maxSubagentDepth": limits.maxSubagentDepth = value
    default: limits.maxModelTurns = max(1, value)
    }
    session.profile.limits = limits
    session.touch()
    let applied = limitValue(key, in: limits)
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
      "ui.fgtoolresult", "ui.markdown", "ui.toolResultLines", "ui.subagents",
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
    case "ui.fgtoolresult": value = ui.toolResultForeground
    case "ui.bold": return ui.bold ? "on" : "off"
    case "ui.markdown": return ui.markdown ? "on" : "off"
    case "ui.toolresultlines": return ui.toolResultLines < 0 ? "all" : String(ui.toolResultLines)
    case "ui.subagents": return ui.subagentOutput.rawValue
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

  #if PMAI_HAS_VISUAL
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
      let screen = TerminalScreen.current
      screen?.deactivate()
      defer { screen?.resume() }
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
      if request.input.trimmingCharacters(in: .whitespacesAndNewlines) == "/help" {
        output +=
          "\nIn visual mode, /exit returns to the REPL and the output above closes with Esc."
      }
      if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { output = "Done." }
      var conversation = request.conversation
      conversation.profile = session.profile.agentDefinition
      conversation.messages = session.history.messages
      conversation.pendingContent = session.pendingContent
      return VisualCommandOutcome(output: output, conversation: conversation)
    }
  #endif

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
    let rest = String(argument.dropFirst(action.count)).trimmingCharacters(
      in: .whitespacesAndNewlines)

    switch action {
    case "list", "chats", "ls":
      guard let scope = ChatListScope(rest) else {
        await terminal.line("Usage: /chat list [active|archived|all]")
        return
      }
      await terminal.line(chatListing(workspace, scope: scope, selectedID: session.id))
    case "new":
      var profile = session.profile
      var title = rest
      var explicitAgent = false
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
        title = values.count == 3 ? values[2] : ""
        explicitAgent = true
      }
      if title.isEmpty, !explicitAgent, session.chat.isDisposable {
        await terminal.line("Already in a new chat.")
        return
      }
      let chat = workspace.startNewChat(
        primaryAgent: profile.agentDefinition,
        title: title.isEmpty ? nil : title)
      session = REPLSession(chat: chat)
      await terminal.line("Started chat '\(chat.displayTitle)' with agent \(profile.agentID).")
    case "use", "switch", "open":
      guard !rest.isEmpty, let chat = resolveChat(rest, in: workspace) else {
        await terminal.line("Usage: /chat use INDEX|ID|TITLE")
        return
      }
      guard chat.id != session.id else {
        await terminal.line("Already in '\(chat.displayTitle)'.")
        return
      }
      await switchSession(
        to: chat, session: &session, workspace: &workspace, configuration: configuration,
        terminal: terminal)
    case "next", "previous", "prev":
      let ordered = workspace.orderedChats
      guard ordered.count > 1,
        let current = ordered.firstIndex(where: { $0.id == session.id })
      else {
        await terminal.line("There is only one chat.")
        return
      }
      let offset = action == "next" ? 1 : -1
      let chat = ordered[(current + offset + ordered.count) % ordered.count]
      await switchSession(
        to: chat, session: &session, workspace: &workspace, configuration: configuration,
        terminal: terminal)
    case "info", "show":
      guard let chat = rest.isEmpty ? session.chat : resolveChat(rest, in: workspace) else {
        await terminal.line("Usage: /chat info [INDEX|ID|TITLE]")
        return
      }
      await terminal.line(chatInfo(chat, workspace: workspace, selectedID: session.id))
    case "rename":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /chat rename TITLE")
        return
      }
      session.title = rest
      session.touch()
      workspace.upsert(session.chat, selecting: true)
      await terminal.line("Chat renamed to '\(rest)'.")
    case "archive":
      guard let chat = rest.isEmpty ? session.chat : resolveChat(rest, in: workspace) else {
        await terminal.line("Usage: /chat archive [INDEX|ID|TITLE]")
        return
      }
      guard !chat.isArchived else {
        await terminal.line("'\(chat.displayTitle)' is already archived.")
        return
      }
      guard !chat.isDisposable else {
        await terminal.line("'\(chat.displayTitle)' is empty; there is nothing to archive.")
        return
      }
      guard chat.id == session.id else {
        workspace.setArchived(true, id: chat.id)
        await terminal.line("Archived '\(chat.displayTitle)'.")
        return
      }
      session.isArchived = true
      session.touch()
      workspace.upsert(session.chat, selecting: true)
      session = REPLSession(
        chat: workspace.startNewChat(primaryAgent: session.profile.agentDefinition))
      await terminal.line("Archived '\(chat.displayTitle)' and started a new chat.")
    case "unarchive", "restore":
      guard let chat = rest.isEmpty ? session.chat : resolveChat(rest, in: workspace) else {
        await terminal.line("Usage: /chat unarchive INDEX|ID|TITLE")
        return
      }
      guard chat.isArchived else {
        await terminal.line("'\(chat.displayTitle)' is not archived.")
        return
      }
      if chat.id == session.id {
        session.isArchived = false
        session.touch()
        workspace.upsert(session.chat, selecting: true)
      } else {
        workspace.setArchived(false, id: chat.id)
      }
      await terminal.line("Restored '\(chat.displayTitle)' to the active chats.")
    case "close", "delete":
      guard parts.count == 2, parts[1].lowercased() == "confirm" else {
        await terminal.line("Closing a chat is permanent. Confirm with: /chat close confirm")
        return
      }
      let closed = session.chat
      _ = workspace.removeChat(id: closed.id)
      if let next = workspace.activeChats.first ?? workspace.orderedChats.first {
        _ = workspace.selectChat(id: next.id)
        session = REPLSession(
          chat: chatApplyingConfiguredAgentSettings(next, configuration: configuration))
        await terminal.line("Closed '\(closed.displayTitle)'; switched to '\(session.title)'.")
      } else {
        session = REPLSession(
          chat: workspace.startNewChat(primaryAgent: session.profile.agentDefinition))
        await terminal.line("Closed '\(closed.displayTitle)'; started a new chat.")
      }
    case "messages":
      await handleChatCommand(
        "list",
        session: &session,
        runtime: runtime,
        compactPrompt: configuration?.prompts?.compact,
        terminal: terminal)
    case "log", "edit", "remove", "rm", "undo", "trim", "compact", "clear", "help":
      await handleChatCommand(
        argument,
        session: &session,
        runtime: runtime,
        compactPrompt: configuration?.prompts?.compact,
        terminal: terminal)
    default:
      await terminal.line("Unknown /chat action '\(action)'.\n\n\(chatHelp)")
    }
  }

  private static func switchSession(
    to chat: AgentChat,
    session: inout REPLSession,
    workspace: inout AgentChatWorkspace,
    configuration: MaiConfiguration?,
    terminal: TerminalWriter
  ) async {
    _ = workspace.selectChat(id: chat.id)
    session = REPLSession(
      chat: chatApplyingConfiguredAgentSettings(chat, configuration: configuration))
    let status = chat.isArchived ? ", archived" : ""
    await terminal.line(
      "Switched to '\(chat.displayTitle)' (agent \(chat.primaryAgent.id)\(status)).")
  }

  private enum ChatListScope {
    case active, archived, all

    init?(_ raw: String) {
      switch raw.lowercased() {
      case "", "all": self = .all
      case "active", "open": self = .active
      case "archived", "archive", "old": self = .archived
      default: return nil
      }
    }
  }

  /// Chats grouped the way the PocketMai sidebar groups them: active chats
  /// under Today / Yesterday / This week / Last week / date headers, newest
  /// first, then the archived ones. Indexes match `/chat use N`.
  private static func handleProjectCommand(
    _ argument: String,
    project: inout AgentProject,
    home: AgentHome,
    store: AgentChatStore,
    terminal: TerminalWriter
  ) async {
    let parts = argument.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(
      String.init)
    let action = parts.first?.lowercased() ?? "info"
    let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""

    switch action {
    case "info", "show":
      await terminal.line(projectInfo(project, home: home, store: store))
    case "list", "ls", "projects":
      do {
        await terminal.line(
          projectListing(try home.loadProjectIndex(), currentID: project.id, now: Date()))
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
    case "name", "rename":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /project name NAME")
        return
      }
      project.rename(to: rest)
      await saveProject(
        project, home: home, terminal: terminal,
        success: "Project renamed to '\(project.displayName)'.")
    case "tint", "color", "colour":
      let presets = AgentProjectTint.presetNames.joined(separator: ", ")
      guard !rest.isEmpty else {
        await terminal.line(
          "Tint: \(project.tint?.rawValue ?? "none"). Presets: \(presets); or #RRGGBB; none clears it."
        )
        return
      }
      if ["none", "off", "default", "-"].contains(rest.lowercased()) {
        project.tint = nil
        await saveProject(project, home: home, terminal: terminal, success: "Project tint cleared.")
        return
      }
      guard let tint = AgentProjectTint(rawValue: rest) else {
        await terminal.line("Unknown tint '\(rest)'. Use one of \(presets), or #RRGGBB.")
        return
      }
      project.tint = tint
      await saveProject(
        project, home: home, terminal: terminal, success: "Project tint set to \(tint.rawValue).")
    case "forget":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /project forget INDEX|PATH|NAME")
        return
      }
      do {
        let index = try home.loadProjectIndex()
        guard let target = resolveProject(rest, in: index) else {
          await terminal.line("No project matches '\(rest)'. /project list shows them.")
          return
        }
        guard target.id != project.id else {
          await terminal.line("'\(target.displayName)' is the open project; it stays listed.")
          return
        }
        _ = try home.forgetProject(id: target.id)
        await terminal.line(
          "Forgot '\(target.displayName)'. Its files in \(target.workingDirectory) were left alone."
        )
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
    case "help":
      await terminal.line(projectHelp)
    default:
      await terminal.line("Unknown /project action '\(action)'.\n\n\(projectHelp)")
    }
  }

  private static func saveProject(
    _ project: AgentProject,
    home: AgentHome,
    terminal: TerminalWriter,
    success: String
  ) async {
    do {
      try home.saveProject(project)
      await terminal.line(success)
    } catch {
      await terminal.line(
        "warning: the project was not saved: \(error.localizedDescription)", to: .standardError)
    }
  }

  private static func resolveProject(_ selector: String, in index: AgentProjectIndex)
    -> AgentProject?
  {
    let ordered = index.orderedProjects
    if let number = Int(selector), number >= 1, number <= ordered.count {
      return ordered[number - 1]
    }
    let path = AgentProject.standardizedPath(selector)
    if let match = index.project(atWorkingDirectory: path) { return match }
    let lowered = selector.lowercased()
    if let match = ordered.first(where: { $0.id.uuidString.lowercased().hasPrefix(lowered) }) {
      return match
    }
    return ordered.first { $0.displayName.lowercased() == lowered }
  }

  private static func projectInfo(
    _ project: AgentProject,
    home: AgentHome,
    store: AgentChatStore
  ) -> String {
    let summaries = (try? store.loadSummaries()) ?? []
    let archived = summaries.filter(\.isArchived).count
    let nameNote =
      project.hasCustomName ? "" : " (from the directory; /project name NAME renames it)"
    return [
      "Name:      \(project.displayName)\(nameNote)",
      "Directory: \(project.workingDirectory)",
      "Tint:      \(project.tint?.rawValue ?? "none")",
      "Chats:     \(summaries.count - archived) active, \(archived) archived",
      "Storage:   \(store.directoryURL.path)",
      "Index:     \(home.projectIndexURL.path)",
      "ID:        \(project.id.uuidString)",
      "Created:   \(ChatDatePresentation.timestamp(project.createdAt))",
      "Opened:    \(ChatDatePresentation.timestamp(project.lastOpenedAt))",
    ].joined(separator: "\n")
  }

  private static func projectListing(
    _ index: AgentProjectIndex,
    currentID: UUID?,
    now: Date
  ) -> String {
    let projects = index.orderedProjects
    guard !projects.isEmpty else {
      return "No projects yet. pmai registers the directory it is started in."
    }
    var lines = ["Projects, most recently opened first:"]
    for (offset, project) in projects.enumerated() {
      let marker = project.id == currentID ? "*" : " "
      let number = offset < 9 ? " \(offset + 1)" : "\(offset + 1)"
      var notes: [String] = []
      if let tint = project.tint { notes.append(tint.rawValue) }
      if !project.workingDirectoryExists { notes.append("missing") }
      lines.append(
        [
          "\(marker) \(number)", padded(project.displayName, width: 24),
          padded(abbreviatedPath(project.workingDirectory), width: 44),
          padded(notes.joined(separator: ", "), width: 12),
          ChatDatePresentation.compactTimestamp(project.lastOpenedAt, relativeTo: now),
        ].joined(separator: "  "))
    }
    return lines.joined(separator: "\n")
  }

  /// Shortens a path the way shells print it: `~` for home, and the head
  /// elided when it is still too long, keeping the tail people recognize.
  private static func abbreviatedPath(_ path: String, width: Int = 44) -> String {
    var shown = path
    let home = NSHomeDirectory()
    if shown == home {
      shown = "~"
    } else if shown.hasPrefix(home + "/") {
      shown = "~" + shown.dropFirst(home.count)
    }
    guard shown.count > width else { return shown }
    return "…" + shown.suffix(width - 1)
  }

  private static func chatListing(
    _ workspace: AgentChatWorkspace,
    scope: ChatListScope,
    selectedID: UUID?,
    now: Date = Date()
  ) -> String {
    let ordered = workspace.orderedChats
    var lines: [String] = []
    func append(_ chats: [AgentChat], header: (AgentChat) -> String) {
      var previous: String?
      for chat in chats {
        let title = header(chat)
        if title != previous {
          lines.append(title)
          previous = title
        }
        let index = (ordered.firstIndex { $0.id == chat.id } ?? 0) + 1
        lines.append(chatRow(chat, index: index, selected: chat.id == selectedID, now: now))
      }
    }
    if scope != .archived {
      let active = workspace.activeChats
      if active.isEmpty { lines.append("No active chats.") }
      append(active) { ChatDatePresentation.groupTitle(for: $0.updatedAt, relativeTo: now) }
    }
    if scope != .active {
      let archived = workspace.archivedChats
      if archived.isEmpty, scope == .archived { lines.append("No archived chats.") }
      append(archived) { _ in "Archived" }
    }
    return lines.joined(separator: "\n")
  }

  private static func chatRow(_ chat: AgentChat, index: Int, selected: Bool, now: Date) -> String {
    let marker = selected ? "*" : " "
    let number = index < 10 ? " \(index)" : "\(index)"
    let count = chat.conversationMessages.count
    let size = count == 0 ? "empty" : "\(count) msg"
    return [
      "\(marker) \(number)", String(chat.id.uuidString.prefix(8)),
      padded(chat.displayTitle, width: 40), padded(chat.primaryAgent.id, width: 10),
      padded(size, width: 8),
      ChatDatePresentation.compactTimestamp(chat.updatedAt, relativeTo: now),
    ].joined(separator: "  ")
  }

  private static func chatInfo(
    _ chat: AgentChat,
    workspace: AgentChatWorkspace,
    selectedID: UUID?
  ) -> String {
    let index = (workspace.orderedChats.firstIndex { $0.id == chat.id } ?? 0) + 1
    let count = chat.conversationMessages.count
    var status = chat.isArchived ? "archived" : "active"
    if chat.id == selectedID { status += ", current" }
    var lines = [
      "Title:    \(chat.displayTitle)",
      "Index:    \(index)",
      "ID:       \(chat.id.uuidString)",
      "Agent:    \(chat.primaryAgent.id) (\(chat.primaryAgent.provider) / \(chat.primaryAgent.model))",
      "Messages: \(count) conversation, \(chat.messages.count) total",
      "Started:  \(ChatDatePresentation.timestamp(chat.createdAt))",
      "Updated:  \(ChatDatePresentation.timestamp(chat.updatedAt)) (\(ChatDatePresentation.groupTitle(for: chat.updatedAt)))",
      "Status:   \(status)",
    ]
    if !chat.pendingContent.isEmpty {
      lines.append("Pending:  \(chat.pendingContent.count) attachment(s) queued")
    }
    return lines.joined(separator: "\n")
  }

  private static func padded(_ text: String, width: Int) -> String {
    let count = text.count
    guard count <= width else { return String(text.prefix(width - 3)) + "..." }
    return text + String(repeating: " ", count: width - count)
  }

  private static func resolveChat(
    _ selector: String,
    in workspace: AgentChatWorkspace
  ) -> AgentChat? {
    let ordered = workspace.orderedChats
    if let index = Int(selector), ordered.indices.contains(index - 1) {
      return ordered[index - 1]
    }
    if let id = UUID(uuidString: selector) {
      return ordered.first { $0.id == id }
    }
    let idMatches = ordered.filter {
      $0.id.uuidString.lowercased().hasPrefix(selector.lowercased())
    }
    if idMatches.count == 1 { return idMatches[0] }
    let titleMatches = ordered.filter {
      $0.displayTitle.caseInsensitiveCompare(selector) == .orderedSame
    }
    return titleMatches.count == 1 ? titleMatches[0] : nil
  }

  private static func handleChatCommand(
    _ argument: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    compactPrompt: String?,
    terminal: TerminalWriter
  ) async {
    let parts = argument.split(maxSplits: 2, whereSeparator: \Character.isWhitespace).map(
      String.init)
    guard let action = parts.first?.lowercased(), !action.isEmpty else {
      await terminal.line(chatHelp)
      return
    }
    let actionArgument = String(argument.dropFirst(parts[0].count))
      .trimmingCharacters(in: .whitespacesAndNewlines)

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
        await terminal.line("Usage: /chat edit INDEX TEXT")
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
        await terminal.line("Usage: /chat remove INDEX")
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
        await terminal.line("Usage: /chat trim INDEX")
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
      await compactChat(
        focus: actionArgument,
        promptTemplate: compactPrompt,
        session: &session,
        runtime: runtime,
        terminal: terminal)
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

  private static let defaultCompactPrompt = """
    Compact the transcript below into durable context for continuing the same chat.

    Output only the compacted context. Do not include hidden reasoning, XML tags, prompt scaffolding, or commentary about the task.

    Preserve:
    - User goals, preferences, constraints, and decisions
    - Important names, projects, files, commands, code snippets, errors, and results
    - Current state, unresolved questions, and next steps

    Drop greetings, filler, repeated text, tool protocol blocks, and implementation details that no longer matter. Write concise bullets grouped by topic when useful.
    {{focus}}

    Transcript:

    {{transcript}}
    """

  /// Ask the selected model for durable context using the configured prompt
  /// template, then replace the transcript while retaining system instructions.
  private static func compactChat(
    focus: String,
    promptTemplate: String?,
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

    let focusInstructions =
      focus.isEmpty
      ? ""
      : """
      The user supplied this focus for compaction:

      <compaction-focus>
      \(focus)
      </compaction-focus>

      Prioritize context relevant to that focus while retaining essential state needed to continue the work.
      """
    let configuredTemplate = promptTemplate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let template = configuredTemplate.isEmpty ? defaultCompactPrompt : configuredTemplate
    guard template.contains("{{transcript}}") else {
      await terminal.line(
        "error: The compact prompt must contain {{transcript}}. Edit it with /edit compact.",
        to: .standardError)
      return
    }
    var prompt = template.replacingOccurrences(of: "{{focus}}", with: focusInstructions)
    prompt = prompt.replacingOccurrences(
      of: "{{transcript}}",
      with: entries.joined(separator: "\n\n---\n\n"))
    if !focusInstructions.isEmpty, !template.contains("{{focus}}") {
      prompt += "\n\n" + focusInstructions
    }
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
      let summary =
        result.transcript.last(where: { $0.role == .assistant })?.text
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
    guard let value = Int(raw), value != 0 else { return nil }
    let index = value > 0 ? value - 1 : count + value
    return (0..<count).contains(index) ? index : nil
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

  /// Where pmai kept chats and history before projects existed.
  private static let legacyStateDirectory = "~/.config/pmai"

  private static func resolvedHome(options: CLIOptions, environment: [String: String])
    -> AgentHome
  {
    if let path = options.homePath {
      return AgentHome(
        rootURL: URL(
          fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true))
    }
    return AgentHome.resolve(environment: environment)
  }

  /// Pre-project state is adopted only into the default home: a relocated
  /// home is a deliberate fresh setup, and scratch runs must not touch the
  /// files under the real home directory.
  private static func usesDefaultHome(options: CLIOptions, environment: [String: String])
    -> Bool
  {
    options.homePath == nil
      && (environment[AgentHome.environmentVariable] ?? "").trimmingCharacters(
        in: .whitespacesAndNewlines
      ).isEmpty
  }

  private static func resolvedChatStore(
    options: CLIOptions,
    home: AgentHome,
    project: AgentProject
  ) -> AgentChatStore {
    if let path = options.statePath {
      return AgentChatStore(
        directoryURL: URL(
          fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true))
    }
    return home.chatStore(for: project)
  }

  /// The shared input history, copied once from its pre-project location.
  private static func resolvedHistoryURL(
    options: CLIOptions,
    home: AgentHome,
    environment: [String: String]
  ) -> URL {
    if let path = options.historyPath {
      return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    }
    let url = home.historyURL
    let legacy = URL(
      fileURLWithPath: NSString(string: "\(legacyStateDirectory)/history.json")
        .expandingTildeInPath)
    if usesDefaultHome(options: options, environment: environment),
      !FileManager.default.fileExists(atPath: url.path),
      FileManager.default.fileExists(atPath: legacy.path)
    {
      try? FileManager.default.createDirectory(at: home.rootURL, withIntermediateDirectories: true)
      try? FileManager.default.copyItem(at: legacy, to: url)
    }
    return url
  }

  /// Adopts the single-file workspace pmai kept before projects existed into
  /// the first project started afterwards, then sets the file aside so it is
  /// imported only once.
  private static func importLegacyChats(
    into store: AgentChatStore,
    project: AgentProject,
    options: CLIOptions,
    environment: [String: String]
  ) {
    guard options.statePath == nil, usesDefaultHome(options: options, environment: environment)
    else { return }
    let legacy = URL(
      fileURLWithPath: NSString(string: "\(legacyStateDirectory)/chats.json").expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: legacy.path) else { return }
    do {
      var workspace = try AgentChatWorkspace.load(from: legacy)
      let count = workspace.chats.filter { !$0.isDisposable }.count
      try store.commit(&workspace)
      let imported = legacy.appendingPathExtension("imported")
      try? FileManager.default.removeItem(at: imported)
      try FileManager.default.moveItem(at: legacy, to: imported)
      FileHandle.standardError.write(
        Data(
          "Imported \(count) earlier chat\(count == 1 ? "" : "s") from \(legacy.path) into project '\(project.displayName)'.\n"
            .utf8))
    } catch {
      FileHandle.standardError.write(
        Data(
          "warning: earlier chats in \(legacy.path) were not imported: \(error.localizedDescription)\n"
            .utf8))
    }
  }

  /// A project tint colors the prompt so the terminal shows which project is open.
  private static func tintedUI(_ ui: ConfiguredTerminalUI, project: AgentProject)
    -> ConfiguredTerminalUI
  {
    guard let tint = project.tint else { return ui }
    var tinted = ui
    tinted.promptForeground = tint.hex
    return tinted
  }

  private static func loadChatWorkspace(
    from store: AgentChatStore,
    initialProfile: SessionProfile,
    configuredAgents: [AgentDefinition],
    providerOverride: ProviderID?,
    modelOverride: String?,
    options: CLIOptions
  ) throws -> AgentChatWorkspace {
    var workspace = try store.loadWorkspace { error in
      FileHandle.standardError.write(
        Data("warning: skipped a chat file. \(error.localizedDescription)\n".utf8))
    }
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
    // Like the PocketMai app, every launch opens a fresh chat and keeps the
    // earlier ones one `/chat use` away; `--resume` reopens the latest instead.
    if options.resume, let recent = workspace.mostRecentActiveChat {
      workspace.selectChat(id: recent.id)
      return workspace
    }
    workspace.startNewChat(primaryAgent: initialProfile.agentDefinition)
    return workspace
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
      applyConfiguredAgentSettings(configured, to: &chat)
      workspace.upsert(chat)
    }
  }

  private static func applyConfiguredAgentSettings(
    _ configured: AgentDefinition,
    to chat: inout AgentChat
  ) {
    let previousInstructions = chat.primaryAgent.instructions
    chat.primaryAgent.limits = configured.limits
    chat.primaryAgent.toolCallingStrategy = configured.toolCallingStrategy
    chat.primaryAgent.instructions = configured.instructions
    chat.primaryAgent.systemPrompt = configured.systemPrompt
    guard previousInstructions != configured.instructions else { return }
    var transcript = AgentTranscript(messages: chat.messages)
    if let index = transcript.messages.firstIndex(where: {
      $0.role == .system && $0.text == previousInstructions
    }) {
      if configured.instructions.isEmpty {
        _ = try? transcript.removeMessage(at: index)
      } else {
        _ = try? transcript.editMessage(at: index, text: configured.instructions)
      }
    } else if !configured.instructions.isEmpty {
      transcript.replaceAll(with: [.system(configured.instructions)] + transcript.messages)
    }
    chat.messages = transcript.messages
  }

  private static func chatApplyingConfiguredAgentSettings(
    _ chat: AgentChat,
    configuration: MaiConfiguration?
  ) -> AgentChat {
    guard
      let configured = configuration?.agents.first(where: { $0.id == chat.primaryAgent.id })
    else { return chat }
    var chat = chat
    applyConfiguredAgentSettings(configured, to: &chat)
    return chat
  }

  /// Commits the workspace to the project's chat store. The selected
  /// placeholder stays in memory while the REPL runs and is dropped when it
  /// closes; the store never writes a placeholder, so an empty chat leaves no
  /// file behind however the process ends.
  private static func saveWorkspace(
    _ workspace: inout AgentChatWorkspace,
    store: AgentChatStore,
    terminal: TerminalWriter,
    closing: Bool = false
  ) async {
    workspace.removeDisposableChats(keeping: closing ? nil : workspace.selectedChatID)
    do {
      try store.commit(&workspace)
    } catch {
      await terminal.line(
        "warning: chats were not saved: \(error.localizedDescription)",
        to: .standardError)
    }
  }

  #if PMAI_HAS_VISUAL
    private static func visualSnapshot(for workspace: AgentChatWorkspace) -> VisualWorkspaceSnapshot
    {
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
        let untouched =
          old.map {
            $0.title == conversation.title && $0.primaryAgent == conversation.profile
              && $0.messages == conversation.messages
              && $0.pendingContent == conversation.pendingContent
          } ?? false
        return AgentChat(
          id: conversation.id,
          title: conversation.title,
          primaryAgent: conversation.profile,
          messages: conversation.messages,
          pendingContent: conversation.pendingContent,
          createdAt: old?.createdAt ?? Date(),
          updatedAt: untouched ? old!.updatedAt : Date(),
          isArchived: old?.isArchived ?? false)
      }
      return AgentChatWorkspace(chats: chats, selectedChatID: focusedID)
    }
  #endif

  private static func completionCandidates(
    workspace: AgentChatWorkspace,
    configuration: MaiConfiguration?
  ) -> [String] {
    var values = [
      "/help", "/help set", "/exit", "/quit", "/set yolo on", "/set yolo off", "/set ui.",
      "/help memory", "/help agents", "/help chat", "/help edit", "/help tools",
      "/agent acp list", "/agent acp add ", "/agents acp list",
      "/memory", "/memory edit", "/memory learn", "/memory learn --all", "/memory add ",
      "/memory clear", "/memory on", "/memory off", "/memory scope none",
      "/memory scope project", "/memory scope all", "/edit memory", "/edit memory-prompt",
      "/help todo", "/todo", "/todo add ", "/todo done ", "/todo edit", "/todo clear",
      "/todo path",
      "/set limits.", "/set limits.maxToolCalls ", "/set limits.maxModelTurns ",
      "/set limits.maxSubagents ",
      "/set toolCallingStrategy automatic", "/set toolCallingStrategy native",
      "/set toolCallingStrategy text", "/set toolCallingStrategy xml",
      "/set toolCallingStrategy json",
      "/set ui.bgline rgb:024", "/set ui.bgline none", "/set ui.fgprompt yellow",
      "/set ui.fgcolor none", "/set ui.bgcolor none", "/set ui.bgprompt none",
      "/set ui.fgtoolresult yellow",
      "/set ui.bold on", "/set ui.bold off", "/set ui.markdown on", "/set ui.markdown off",
      "/set ui.toolResultLines all", "/set ui.toolResultLines ",
      "/cwd", "/pwd", "/cd ", "/plugins",
      "/providers", "/models ", "/provider ", "/baseurl ", "/model ", "/prompts", "/prompt",
      "/agents", "/agents tree", "/agents log ", "/agents kill ", "/agents focus ",
      "/agents focus main", "/queue", "/queue push ", "/queue pop", "/queue flush",
      "/help queue", "/set ui.subagents all", "/set ui.subagents tools",
      "/set ui.subagents stats", "/set ui.subagents none",
      "/agent use ",
      "/agent show ", "/agent add ", "/tools", "/proxy on", "/proxy off", "/mcp list",
      "/mcp add ", "/mcp enable ", "/mcp disable ",
      "/edit prompt", "/edit compact", "/edit config", "/edit mcps", "/chat compact ",
      "/image tiny ", "/image small ", "/image medium ", "/image big ", "/image full ",
      "/image ocr ", "/attach ", "/attach clear", "/copy", "/clear", "/chat list",
      "/chat list active", "/chat list archived", "/chat list all", "/chat new ",
      "/chat use ", "/chat next", "/chat previous", "/chat info", "/chat rename ",
      "/chat archive", "/chat unarchive ", "/chat close confirm", "/chat messages",
      "/chat log", "/chat edit ", "/chat remove ", "/chat undo", "/chat trim ",
      "/chat clear", "/project", "/project info", "/project list", "/project name ",
      "/project tint ", "/project tint none", "/project forget ",
    ]
    for tint in AgentProjectTint.presetNames {
      values.append("/project tint \(tint)")
    }
    #if PMAI_HAS_VISUAL
      values.append("/visual")
    #endif
    for (index, chat) in workspace.orderedChats.enumerated() {
      values.append("/chat use \(index + 1)")
      values.append("/chat use \(chat.id.uuidString.prefix(8))")
      values.append("/chat use \(chat.displayTitle)")
      values.append("/chat info \(index + 1)")
      values.append(chat.isArchived ? "/chat unarchive \(index + 1)" : "/chat archive \(index + 1)")
    }
    for agent in configuration?.agents ?? [] {
      values.append("/agent use \(agent.id)")
      values.append("/agent show \(agent.id)")
      values.append("/chat new --agent \(agent.id) ")
    }
    for name in configuration?.prompts?.system.keys.sorted() ?? [] {
      values.append("/prompt \(name)")
      values.append("/edit prompt \(name)")
      values.append("/edit \(name)")
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
        [
          "echo", "datetime", "calc", "files", "run", "weather", "web", "mastodon", "github",
          "todo",
        ])
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
        ConfiguredOCRProvider(
          id: MaiVisionOCRPlugin.preferredFactoryKind,
          kind: MaiVisionOCRPlugin.preferredFactoryKind)
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
          defaultApproval: .confirm),
      ],
      agents: [
        AgentDefinition(
          id: "hello",
          description: "Offline smoke test; no tools and no network.",
          instructions: "Exercise the offline MaiCore provider.",
          systemPrompt: "hello",
          provider: "hello",
          model: ""),
        AgentDefinition(
          id: "main",
          description: "General assistant with the full tool set.",
          instructions: "You are a helpful assistant. Use tools when needed.",
          systemPrompt: "main",
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
            ] + MaiFileWorkspaceTool.toolNames + MaiRunTool.toolNames + MaiGitHubTool.toolNames
              + MaiTodoTools.toolNames),
          toolGroupNames: [
            "echo", "datetime", "calc", "files", "run", "weather", "web", "mastodon",
            "github", "todo",
          ],
          subagentNames: ["researcher"],
          limits: AgentRunLimits(maxSubagents: 4),
          useToolProxy: true),
        AgentDefinition(
          id: "researcher",
          description: "Investigates one question and answers in a few lines.",
          instructions: "Investigate the delegated task and return a concise result.",
          systemPrompt: "researcher",
          provider: "openai",
          model: "your-model",
          toolNames: [MaiCurrentTimeTool.name],
          toolGroupNames: ["datetime"]),
      ],
      prompts: ConfiguredPrompts(
        delegation: AgentDelegationPrompt.template,
        worker: AgentDelegationPrompt.workerInstructions,
        memory: AgentMemoryPrompt.template,
        system: [
          "hello": "Exercise the offline MaiCore provider.",
          "main": "You are a helpful assistant. Use tools when needed.",
          "researcher": "Investigate the delegated task and return a concise result.",
        ]),
      memory: ConfiguredMemory(),
      approvals: ConfiguredApprovals(confirm: .ask, dangerous: .ask))
  }

  private static let visualHelp: String = {
    #if PMAI_HAS_VISUAL
      "/visual             Open the terminal workspace: split chats, providers, MCPs, tools\n"
    #else
      ""
    #endif
  }()

  private static let replHelp = """
    /set [SETTING VALUE]   Show or change settings; /help set lists them
    /cwd                  Print the current working directory
    /cd PATH              Change the current working directory
    /plugins            List statically and dynamically loaded plugins
    /providers          List registered providers
    /models [PROVIDER]  List models from the current or named provider
    /provider ID       Select a provider
    /baseurl URL       Change the current provider endpoint
    /model NAME         Select a model
    /memory             Show, edit, learn, or scope this project's durable memory
    /todo               Show, add to, tick off, or edit this project's todo list
    /prompts            List reusable prompts and their agent associations
    /prompt [NAME]      Show or select the current agent's system prompt
    /chat               List, switch, archive, rename, or edit this project's chats
    /project            Show, list, rename, or tint the project (the start directory)
    /edit TARGET        Edit a prompt, config, MCP list, or message in $EDITOR
    /agents             List agent setups and the running agent tree
    /agents tree        Show running agents as a tree of pids
    /agents kill PID    Stop a running agent and everything it started
    /agents log PID     Print a running or finished agent's own transcript
    /agents focus PID   Send what you type to a running agent (focus main returns)
    /queue              List, push, pop, or flush messages waiting for an agent
    /agents enable|disable ID   Park an agent setup without deleting it
    /agents describe ID TEXT    Set the purpose a model reads when picking agents
    /agent [use] ID     Set the current chat's primary agent
    /agent add ...      Persist a reusable agent and OpenAI-compatible endpoint
    /agent acp ...      Register an external ACP agent (gemini, claude, codex, ...)
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
    \(visualHelp)/clear              Clear conversation history
    /exit               Exit the REPL

    Input: <<WORD starts a multiline message ending at WORD alone
           Up/Down or Ctrl+P/N history · Ctrl+R reverse search · Ctrl+A/E beginning/end
           Ctrl+W delete word · Ctrl+C cancel run · Ctrl+Z suspend
           The prompt stays open while a turn runs: a message typed then is queued and
           joins the conversation at the next model turn. @PID TEXT reaches one agent.
           Child agents print in blocks prefixed agent#PID; /set ui.subagents picks how much.
    """

  private static let setHelp = """
    Settings commands:
      /set                         List current settings and their values
      /set yolo BOOL               Permit all tool calls for this session (on/off)
      /set toolCallingStrategy MODE  Use automatic/native tools, or text/XML/JSON emulation
      /set delegation MODE         Run this agent's tools inline, or in a subagent
      /set limits.                 List the tool, turn, and subagent limits
      /set limits.maxToolCalls N   Tool calls allowed per run
      /set limits.maxModelTurns N  Model turns allowed per run
      /set limits.maxSubagents N   Child agents allowed at once (0 disables delegation)
      /set limits.maxSubagentDepth N  Maximum depth of the agent tree
      /set ui.                     List terminal UI settings
      /set ui.bgline COLOR         Set the input-line background
      /set ui.fgcolor COLOR        Set the input foreground
      /set ui.bgcolor COLOR        Set the input background
      /set ui.fgprompt COLOR       Set the prompt foreground
      /set ui.bgprompt COLOR       Set the prompt background
      /set ui.fgtoolresult COLOR   Set successful tool-result output color
      /set ui.bold BOOL            Render input in bold (on/off)
      /set ui.markdown BOOL        Render replies as styled markdown (on/off)
      /set ui.toolResultLines <all|N>  Show all or the first N result lines (0 hides them)
      /set ui.subagents LEVEL      What child agents print: all, tools, stats, or none

    YOLO mode lasts for this session. Agent and UI settings are persisted in the
    active configuration. COLOR accepts a named ANSI color, rgb:RGB, or none.
    """

  private static let chatHelp = """
    Persistent chat management commands:
      /chat list [active|archived|all]  List chats by day, newest first; archived last
      /chat new [TITLE]             Start a fresh chat using the current agent
      /chat new --agent ID [TITLE]  Start a fresh chat using a configured agent
      /chat use INDEX|ID|TITLE      Switch to a chat by list index, ID prefix, or title
      /chat next|previous           Cycle through chats
      /chat info [INDEX|ID|TITLE]   Show a chat's agent, size, and timestamps
      /chat rename TITLE            Rename the active chat
      /chat archive [INDEX|ID|TITLE]  Archive a chat; archiving the active one starts fresh
      /chat unarchive INDEX|ID|TITLE  Return an archived chat to the active list
      /chat close confirm           Permanently close the active chat
      /chat messages                Display a compact indexed message list
      /chat log           Display the full structured conversation
      /chat edit INDEX TEXT  Replace a message's text; preserve attachments
      /chat remove INDEX  Remove a message
      /chat undo [INDEX]  Remove the last conversation message or selected message
      /chat trim INDEX    Keep through the selected message; remove newer messages
      /chat compact [FOCUS]  Summarize the chat, prioritizing what FOCUS says to preserve
      /chat clear         Clear the conversation and restore configured instructions

    Message indexes are 1-based. Negative indexes count back from the end;
    -1 selects the last message, -2 the second-to-last, and so on.
    Removing a tool call or result also removes its linked tool transaction.
    pmai opens a fresh chat on every launch and names it after the first
    message; chats that never received a message are never written. Start
    with --resume to reopen the most recently updated chat instead. Chats
    belong to the project rooted at the start directory; /project shows it.
    """

  private static let projectHelp = """
    Project commands (a project is the directory pmai was started in):
      /project [info]          Show the project's name, tint, directory, and chat counts
      /project list            List every project pmai has been started in, recent first
      /project name NAME       Rename the project; the directory name is the default
      /project tint COLOR      Color the prompt: a preset such as mint, or #RRGGBB; none clears it
      /project forget INDEX|PATH|NAME  Drop another project from the list; its files stay

    Chats live in .pmai/chats inside the project directory; the list of
    projects lives in ~/.pmai/projects.json (or under $PMAI_HOME). /cd changes
    where tools run, not which project the chats belong to.
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
    /edit prompt [NAME]      Edit/create a named system prompt (current when omitted)
    /edit NAME               Edit an existing named system prompt
    /edit compact            Edit the global chat-compaction prompt template
    /edit memory             Edit this project's durable memory notes
    /edit memory-prompt      Edit the template /memory learn uses
    /edit delegation         Edit the brief template child agents receive
    /edit worker             Edit the instructions of the derived worker agent
    /edit config             Edit the active configuration file
    /edit mcps               Edit the configured MCP server list as JSON
    /edit N|MESSAGE_ID       Edit conversation message N or its full message ID

    The compact and memory templates must contain {{transcript}}; {{focus}} and
    {{memory}} are optional. The delegation template must contain {{task}};
    {{context}}, {{output}}, {{agent}}, and {{cwd}} are optional.
    Clearing it restores the built-in default. Uses $EDITOR, then $VISUAL, then
    vim. Agent limits and tool-calling strategy apply immediately; provider,
    plugin, tool, and MCP changes require a restart.
    """

  private static let memoryHelp = """
    Durable notes about you, kept per project in .pmai/memory.md and added to
    the system prompt of this chat — never of the subagents it starts.

      /memory                    Show the notes and how they are configured
      /memory edit               Edit them in $EDITOR (same as /edit memory)
      /memory learn [FOCUS]      Fold this chat into the notes, keeping what is known
      /memory learn --all [FOCUS]  Fold every chat in this project into them
      /memory add TEXT           Append one note
      /memory set TEXT           Replace every note
      /memory clear              Forget everything
      /memory reload             Re-read the file after editing it elsewhere
      /memory on|off             Whether the notes reach the model
      /memory scope MODE         Chats the chats_* tools may read

    MODE is none, project, or all; all crosses working directories. The tools
    are chats_list, chats_search, chats_read, and chats_read_document; enable
    them for an agent with /tools enable chats. Edit the learning prompt with
    /edit memory-prompt.
    """

  private static let todoHelp = """
    The project's todo list, kept in .pmai/todo.md as a Markdown task list the
    agent plans with and ticks off through the todo_list, todo_add, and
    todo_done tools. It survives across chats, and editing the file by hand
    is fine: every command and tool call reads it afresh.

      /todo                      Show the list, numbered
      /todo add TEXT             Append one pending item
      /todo done NUMBER|TEXT     Mark an item done by number or title fragment
      /todo edit                 Edit the list in $EDITOR
      /todo clear                Remove every item
      /todo path                 Print where the file lives

    Enable the tools for an agent with /tools enable todo.
    """

  private static let agentsHelp = """
    Agent commands. A definition is a saved setup — provider, model, system
    prompt, tools, and limits — that you switch between; a process is one run
    started from a definition, addressed by its pid.

      /agents                    List definitions, then the running process tree
      /agents list               Definitions only
      /agents tree               The running process tree only
      /agents use ID             Switch this chat to a definition
      /agents show [ID]          Show one definition in full
      /agents describe ID TEXT   Set the one-line purpose a model reads to pick it
      /agents enable|disable ID  Park a definition without deleting it
      /agents acp [list]         List external ACP agents and what is installed
      /agents acp add NAME [CMD ARG ...]  Register an ACP agent as a usable agent
      /agents log PID            Print a running or finished agent's own transcript
      /agents kill PID [REASON]  Stop an agent and everything it started
      /agents focus PID|main     Send what you type to one running agent, or back to the chat

    While agents run, what you type is queued for them and read at their next
    model turn: /queue lists it, @PID TEXT addresses one agent once. Their
    output prints in blocks prefixed agent#PID; /set ui.subagents picks how much.

    Where tools run is per definition: /set delegation subagent moves them into
    a child so this chat keeps only the answers. /set limits.maxSubagents and
    /set limits.maxSubagentDepth bound the tree.
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
        --home DIR          keep the project index and shared state in DIR (or PMAI_HOME)
        --state DIR         keep this project's chats in DIR, not ./.pmai/chats (or PMAI_STATE)
        --history PATH      persist editable input history (or PMAI_HISTORY)
        --projects          list every project pmai has been started in, then exit
        --plugin PATH       load a native .dylib plugin (repeatable)
        --print-config      print a complete example configuration
        --acp               serve pmai as an ACP agent on stdio (for IDEs)
        --mcp               serve pmai as an MCP server on stdio (one prompt tool)
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
        -y, --yolo          permit all tool calls without prompting for this session
        --resume            reopen the most recently updated chat instead of a fresh one
        --markdown          render replies as markdown even when piped
        --no-markdown       print replies verbatim
        -h, --help          show this help

      Config discovery:
        --config, PMAI_CONFIG, ./pmai.json, ~/.config/pmai/config.json

      Persistent REPL state:
        Chats belong to the project rooted at the current directory and are
        kept one file per chat in ./.pmai/chats; ~/.pmai/projects.json lists
        every project and ~/.pmai/history.json holds the input history.

      Without a config file, the offline hello and OpenAI-compatible providers
      are registered as before.
      """)
  }
}
