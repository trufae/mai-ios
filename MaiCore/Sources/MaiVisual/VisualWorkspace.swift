import Foundation
import MaiCore
import Observation

#if os(macOS)
  let visualAlternateKeyName = "Option"
#else
  let visualAlternateKeyName = "Alt"
#endif

public struct ProviderForm: Equatable, Sendable {
  public var id = ""
  public var kind = ConfiguredProviderKind.openAICompatible.rawValue
  public var displayName = ""
  public var baseURL = ""
  public var apiKeyEnvironment = ""
  public var apiKey = ""

  public init() {}
}

public struct MCPServerForm: Equatable, Sendable {
  public var id = ""
  public var kind = "streamable-http"
  public var displayName = ""
  public var url = ""
  public var bearerTokenEnvironment = ""
  public var bearerToken = ""
  public var toolNamePrefix = ""
  public var approval = ToolApprovalRequirement.confirm

  public init() {}
}

public struct ToolSourceForm: Equatable, Sendable {
  public var id = ""
  public var kind = ""
  public var displayName = ""
  public var optionsJSON = "{}"

  public init() {}
}

public struct AgentForm: Equatable, Sendable {
  public var id = ""
  public var displayName = ""

  public init() {}
}

public enum VisualWorkspaceError: LocalizedError, Equatable, Sendable {
  case missingField(String)
  case invalidURL(String)
  case invalidOptions(String)
  case noFocusedConversation

  public var errorDescription: String? {
    switch self {
    case .missingField(let name): "\(name) is required."
    case .invalidURL(let value): "'\(value)' is not a valid URL."
    case .invalidOptions(let reason): "Options must be a JSON object: \(reason)"
    case .noFocusedConversation: "No conversation is focused."
    }
  }
}

public struct ConversationActionRequest: Identifiable, Equatable, Sendable {
  public let conversationID: UUID
  public let title: String

  public var id: UUID { conversationID }

  public init(conversationID: UUID, title: String) {
    self.conversationID = conversationID
    self.title = title
  }
}

/// The state behind the visual workspace: conversations, the pane layout, the
/// registries mirrored from the runtime, and the configuration draft edited by
/// the panels. Registration actions update the live runtime immediately and the
/// draft configuration for an explicit save.
@MainActor @Observable
public final class VisualWorkspace {
  @ObservationIgnored let runtime: AgentRuntime
  @ObservationIgnored let plugins: PluginRegistry
  @ObservationIgnored let approvals: VisualApprovalHandler
  public let environment: [String: String]
  public var configuration: MaiConfiguration
  public private(set) var configurationChanged = false
  public private(set) var configurationNeedsSave = false
  public var configurationPath: String
  public private(set) var catalogs: [MCPServerCatalog]
  public private(set) var conversations: [VisualConversation]
  public private(set) var layout: PaneLayout
  public var selectedTab: VisualTab
  public var showsSidebar = true
  public var status: String?
  public private(set) var providers: [ProviderDescriptor] = []
  public private(set) var tools: [ToolDefinition] = []
  public private(set) var agents: [AgentDefinition] = []
  public var pendingApproval: VisualApprovalHandler.Pending?
  public var pendingConversationDeletion: ConversationActionRequest?
  public var pendingConversationRename: ConversationActionRequest?
  public var conversationRenameDraft = ""
  public private(set) var modelCatalog: [ModelDescriptor] = []
  public private(set) var modelCatalogProvider: ProviderID?
  public private(set) var isFetchingModels = false
  private var approvalQueue: [VisualApprovalHandler.Pending] = []
  private var presentedApprovalID: UUID?
  private var conversationCounter: Int

  public var pendingApprovalCount: Int {
    (pendingApproval == nil ? 0 : 1) + approvalQueue.count
  }

  public init(
    launch: VisualLaunch,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    approvals: VisualApprovalHandler
  ) {
    self.runtime = runtime
    self.plugins = plugins
    self.approvals = approvals
    environment = launch.environment
    configuration = launch.configuration ?? MaiConfiguration()
    configurationPath =
      launch.configurationPath
      ?? NSString(string: "~/.config/pmai/config.json").expandingTildeInPath
    catalogs = launch.catalogs

    if let snapshot = launch.snapshot, !snapshot.conversations.isEmpty {
      let restored = snapshot.conversations.map { VisualConversation(seed: $0) }
      var layout = snapshot.layout
      let ids = Set(restored.map(\.id))
      if !layout.root.leaves.allSatisfy({ ids.contains($0.conversation) }) {
        layout = PaneLayout(conversation: restored[0].id)
      }
      conversations = restored
      self.layout = layout
      selectedTab = snapshot.selectedTab
      conversationCounter = restored.count
      let focusedID = layout.focusedConversation
      restored.first { $0.id == focusedID }?.replace(with: launch.focusedConversation)
    } else {
      let conversation = VisualConversation(seed: launch.focusedConversation)
      conversations = [conversation]
      layout = PaneLayout(conversation: conversation.id)
      selectedTab = .chats
      conversationCounter = 1
    }
  }

  // MARK: Conversations and panes

  public func conversation(_ id: UUID) -> VisualConversation? {
    conversations.first { $0.id == id }
  }

  public var focusedConversation: VisualConversation? {
    conversation(layout.focusedConversation)
  }

  public func isFocused(_ conversation: VisualConversation) -> Bool {
    layout.focusedConversation == conversation.id
  }

  public func isShown(_ conversation: VisualConversation) -> Bool {
    layout.root.leaves.contains { $0.conversation == conversation.id }
  }

  public func refreshRegistries() async {
    providers = await runtime.availableProviders()
    tools = await runtime.availableTools()
    agents = await runtime.availableAgents()
  }

  @discardableResult
  public func makeConversation(profile: AgentDefinition? = nil) -> VisualConversation {
    conversationCounter += 1
    let base =
      profile ?? focusedConversation?.profile ?? conversations.first?.profile
      ?? AgentDefinition(id: "main", instructions: "", provider: .hello, model: "")
    let seed = VisualConversationSeed(
      title: "Chat \(conversationCounter)",
      profile: base,
      messages: VisualConversation.initialHistory(for: base))
    let conversation = VisualConversation(seed: seed, hasCustomTitle: false)
    conversations.append(conversation)
    return conversation
  }

  public func newConversationInFocusedPane() {
    let conversation = makeConversation()
    layout.show(conversation.id, in: layout.focusedPane)
    selectedTab = .chats
  }

  public func show(_ conversation: VisualConversation, in pane: PaneID? = nil) {
    layout.show(conversation.id, in: pane ?? layout.focusedPane)
    selectedTab = .chats
  }

  public func focus(pane: PaneID) { layout.focus(pane) }
  public func focusNextPane() { layout.focusNext() }
  public func focusPreviousPane() { layout.focusPrevious() }

  public func splitFocusedPane(_ axis: SplitAxis) {
    let conversation = makeConversation()
    layout.split(axis, showing: conversation.id)
    selectedTab = .chats
  }

  public func closeFocusedPane() {
    if !layout.closeFocusedPane() { status = "The last pane cannot be closed." }
  }

  private func deleteConversation(_ conversation: VisualConversation) {
    guard conversations.count > 1,
      let index = conversations.firstIndex(where: { $0.id == conversation.id })
    else {
      status = "The last conversation cannot be deleted."
      return
    }
    conversation.cancelRun()
    conversations.remove(at: index)
    let fallback = conversations[min(index, conversations.count - 1)]
    layout.replaceConversation(conversation.id, with: fallback.id)
    status = "Deleted '\(conversation.title)'."
  }

  public func deleteFocusedConversation() {
    guard conversations.count > 1, let focused = focusedConversation else {
      status = "The last conversation cannot be deleted."
      return
    }
    pendingConversationDeletion = ConversationActionRequest(
      conversationID: focused.id,
      title: focused.title)
  }

  public func confirmConversationDeletion(_ request: ConversationActionRequest) {
    guard pendingConversationDeletion?.id == request.id else { return }
    pendingConversationDeletion = nil
    guard let conversation = conversations.first(where: { $0.id == request.conversationID }) else {
      return
    }
    deleteConversation(conversation)
  }

  public func cancelConversationDeletion() {
    pendingConversationDeletion = nil
  }

  public func requestRenameFocusedConversation() {
    guard let focused = focusedConversation else { return }
    conversationRenameDraft = focused.title
    pendingConversationRename = ConversationActionRequest(
      conversationID: focused.id,
      title: focused.title)
  }

  public func confirmConversationRename(_ request: ConversationActionRequest) {
    guard pendingConversationRename?.id == request.id else { return }
    let title = conversationRenameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      status = "A chat name is required."
      return
    }
    guard let conversation = conversations.first(where: { $0.id == request.conversationID }) else {
      pendingConversationRename = nil
      return
    }
    conversation.rename(to: title)
    pendingConversationRename = nil
    conversationRenameDraft = ""
    status = "Renamed chat to '\(title)'."
  }

  public func cancelConversationRename() {
    pendingConversationRename = nil
    conversationRenameDraft = ""
  }

  public func clearFocusedConversation() {
    focusedConversation?.resetTranscript()
  }

  public func cancelFocusedRun() {
    guard let focused = focusedConversation, focused.isRunning else { return }
    focused.cancelRun()
    status = "Cancelled the reply in '\(focused.title)'."
  }

  public func send(_ conversation: VisualConversation) {
    let text = conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    guard !conversation.isRunning else {
      status = "'\(conversation.title)' is still replying; \(visualAlternateKeyName)+K cancels it."
      return
    }
    conversation.draft = ""
    conversation.appendUserMessage(text)
    conversation.beginRun()
    let request = conversation.request()
    let runtime = runtime
    conversation.runTask = Task {
      do {
        let result = try await runtime.run(request) { event in
          await conversation.consume(event)
        }
        conversation.finishRun(with: result)
      } catch is CancellationError {
        conversation.failRun("Cancelled.")
      } catch {
        conversation.failRun(error.localizedDescription)
      }
    }
  }

  // MARK: Session settings

  public func useProvider(_ id: ProviderID) {
    guard let focused = focusedConversation else { return }
    useProvider(id, for: focused)
  }

  public func useProvider(_ id: ProviderID, for conversation: VisualConversation) {
    conversation.profile.provider = id
    if modelCatalogProvider != id { modelCatalog = [] }
    persistAgentProfile(for: conversation)
    status = "'\(conversation.title)' now uses provider '\(id)'."
  }

  public func useModel(_ id: String) {
    guard let focused = focusedConversation else { return }
    useModel(id, for: focused)
  }

  public func useModel(_ id: String, for conversation: VisualConversation) {
    conversation.profile.model = id
    persistAgentProfile(for: conversation)
  }

  public func updateInstructions(_ instructions: String, for conversation: VisualConversation) {
    conversation.profile.instructions = instructions
    conversation.applyInstructions()
    persistAgentProfile(for: conversation)
  }

  public func setStreaming(_ enabled: Bool, for conversation: VisualConversation) {
    conversation.profile.stream = enabled
    persistAgentProfile(for: conversation)
  }

  public func setToolProxy(_ enabled: Bool, for conversation: VisualConversation) {
    conversation.profile.useToolProxy = enabled
    persistAgentProfile(for: conversation)
  }

  public func useAgent(_ definition: AgentDefinition) {
    guard let focused = focusedConversation else { return }
    focused.adopt(profile: definition, title: definition.displayName)
    status = "'\(focused.title)' restarted with agent '\(definition.id)'."
    selectedTab = .chats
  }

  public func setTool(_ name: String, allowed: Bool, for conversation: VisualConversation) {
    if allowed {
      conversation.profile.toolNames.insert(name)
    } else {
      conversation.profile.toolNames.remove(name)
    }
    persistAgentProfile(for: conversation)
  }

  public func fetchModels(for provider: ProviderID) async {
    isFetchingModels = true
    defer { isFetchingModels = false }
    do {
      modelCatalog = try await runtime.availableModels(provider: provider)
      modelCatalogProvider = provider
      status =
        modelCatalog.isEmpty
        ? "Provider '\(provider)' returned no models."
        : "Loaded \(modelCatalog.count) models from '\(provider)'."
    } catch {
      modelCatalog = []
      modelCatalogProvider = provider
      status = "error: \(error.localizedDescription)"
    }
  }

  // MARK: Registration

  public func registerProvider(_ form: ProviderForm) async throws {
    let id = try required(form.id, "Identifier")
    let kind = try required(form.kind, "Kind")
    var baseURL: URL?
    let rawURL = form.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if !rawURL.isEmpty {
      guard let url = URL(string: rawURL), url.scheme != nil else {
        throw VisualWorkspaceError.invalidURL(rawURL)
      }
      baseURL = url
    }
    let apiKeyEnvironment = optional(form.apiKeyEnvironment)
    let configured = ConfiguredProvider(
      id: id,
      kind: ConfiguredProviderKind(kind),
      displayName: optional(form.displayName),
      baseURL: baseURL,
      apiKey: apiKeyEnvironment == nil ? optional(form.apiKey) : nil,
      apiKeyEnvironment: apiKeyEnvironment)
    let provider = try await plugins.makeProvider(from: configured, environment: environment)
    try await runtime.register(provider, replacingExisting: true)
    upsert(configured, into: &configuration.providers)
    try saveConfiguration()
    await refreshRegistries()
    status = "Registered provider '\(id)'."
  }

  public func connectMCPServer(_ form: MCPServerForm) async throws {
    let id = try required(form.id, "Identifier")
    let rawURL = try required(form.url, "URL")
    guard let url = URL(string: rawURL), url.scheme != nil else {
      throw VisualWorkspaceError.invalidURL(rawURL)
    }
    let tokenEnvironment = optional(form.bearerTokenEnvironment)
    let configured = ConfiguredMCPServer(
      id: id,
      kind: optional(form.kind) ?? "streamable-http",
      enabled: true,
      displayName: optional(form.displayName),
      url: url,
      bearerToken: tokenEnvironment == nil ? optional(form.bearerToken) : nil,
      bearerTokenEnvironment: tokenEnvironment,
      toolNamePrefix: optional(form.toolNamePrefix),
      defaultApproval: form.approval)
    status = "Connecting to MCP server '\(id)'…"
    let source = try await plugins.makeMCPToolSource(
      kind: configured.kind,
      configuration: configured,
      environment: environment)
    let catalog: MCPServerCatalog
    do {
      catalog = try await runtime.register(mcp: source, replacingExistingTools: true)
    } catch {
      status = nil
      throw error
    }
    catalogs.removeAll { $0.serverID == catalog.serverID }
    catalogs.append(catalog)
    upsert(configured, into: &configuration.mcpServers)
    try saveConfiguration()
    await refreshRegistries()
    status = "Connected MCP server '\(id)' with \(catalog.tools.count) tools."
  }

  public func registerToolSource(_ form: ToolSourceForm) async throws {
    let id = try required(form.id, "Identifier")
    let kind = try required(form.kind, "Kind")
    let options = try parseOptions(form.optionsJSON)
    let configured = ConfiguredToolSource(
      id: id,
      kind: kind,
      enabled: true,
      displayName: optional(form.displayName),
      options: options)
    let tools = try await plugins.makeTools(
      kind: kind,
      context: configured.context(environment: environment))
    for tool in tools {
      try await runtime.register(tool: tool, replacingExisting: true)
    }
    upsert(configured, into: &configuration.toolSources)
    try saveConfiguration()
    await refreshRegistries()
    status = "Registered \(tools.count) tools from '\(id)'."
  }

  public func saveFocusedConversationAsAgent(_ form: AgentForm) async throws {
    guard let focused = focusedConversation else {
      throw VisualWorkspaceError.noFocusedConversation
    }
    let id = try required(form.id, "Identifier")
    var definition = focused.profile
    definition.id = id
    definition.displayName = optional(form.displayName) ?? id
    try await runtime.register(agent: definition, replacingExisting: true)
    upsert(definition, into: &configuration.agents)
    if configuration.defaultAgent == nil {
      configuration.defaultAgent = id
      markConfigurationChanged()
    }
    focused.profile.id = id
    try saveConfiguration()
    await refreshRegistries()
    status = "Saved agent '\(id)'."
  }

  /// Validates the draft and writes it to `configurationPath`.
  public func saveConfiguration() throws {
    let url = URL(fileURLWithPath: configurationPath)
    try configuration.save(to: url)
    configurationNeedsSave = false
    status = "Saved configuration to \(configurationPath)."
  }

  public func configuredProvider(_ id: ProviderID) -> ConfiguredProvider? {
    configuration.providers.first { $0.id == id.rawValue }
  }

  public var disabledMCPServers: [ConfiguredMCPServer] {
    configuration.mcpServers.filter { server in
      !catalogs.contains { $0.serverID == server.id }
    }
  }

  // MARK: Approvals

  func present(_ pending: VisualApprovalHandler.Pending) {
    if pendingApproval == nil {
      pendingApproval = pending
      presentedApprovalID = pending.id
    } else {
      approvalQueue.append(pending)
    }
    status = "Approval requested for tool '\(pending.request.tool.name)'."
  }

  public func resolveApproval(_ decision: ApprovalDecision) {
    guard let id = presentedApprovalID else { return }
    presentedApprovalID = nil
    pendingApproval = nil
    let approvals = approvals
    Task { await approvals.resolve(id, with: decision) }
    status = nil
    presentNextApproval()
  }

  public func resolveApprovalAlways() {
    let pending = [pendingApproval].compactMap { $0 } + approvalQueue
    guard !pending.isEmpty else { return }
    presentedApprovalID = nil
    pendingApproval = nil
    approvalQueue.removeAll()
    let approvals = approvals
    Task { await approvals.resolveAlways(pending) }
    status = "YOLO mode enabled; all tool calls are permitted for this session."
  }

  /// Called when the approval sheet closes without a decision, for example on Escape.
  public func approvalSheetDismissed() {
    guard presentedApprovalID != nil else {
      presentNextApproval()
      return
    }
    resolveApproval(.deny(reason: "Dismissed without approval."))
  }

  private func presentNextApproval() {
    guard pendingApproval == nil, !approvalQueue.isEmpty else { return }
    let next = approvalQueue.removeFirst()
    pendingApproval = next
    presentedApprovalID = next.id
  }

  // MARK: Exit

  public func shutdown() -> VisualOutcome {
    for conversation in conversations { conversation.cancelRun() }
    let focused = focusedConversation ?? conversations[0]
    let others = conversations.count - 1
    var summary = "Back in the REPL with '\(focused.title)'"
    if others > 0 {
      summary += "; \(others) other conversation\(others == 1 ? "" : "s") kept for the next /visual"
    }
    summary += "."
    return VisualOutcome(
      focusedConversation: focused.seed,
      snapshot: VisualWorkspaceSnapshot(
        conversations: conversations.map(\.seed),
        layout: layout,
        selectedTab: selectedTab),
      configuration: configuration,
      configurationChanged: configurationChanged,
      catalogs: catalogs,
      summary: summary)
  }

  // MARK: Helpers

  private func required(_ value: String, _ name: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw VisualWorkspaceError.missingField(name) }
    return trimmed
  }

  private func optional(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func parseOptions(_ json: String) throws -> [String: JSONValue] {
    let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [:] }
    do {
      let value = try JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8))
      guard let object = value.objectValue else {
        throw VisualWorkspaceError.invalidOptions("the top-level value is not an object")
      }
      return object
    } catch let error as VisualWorkspaceError {
      throw error
    } catch {
      throw VisualWorkspaceError.invalidOptions(error.localizedDescription)
    }
  }

  private func upsert<Item: Identifiable>(_ item: Item, into items: inout [Item]) {
    if let index = items.firstIndex(where: { $0.id == item.id }) {
      items[index] = item
    } else {
      items.append(item)
    }
    markConfigurationChanged()
  }

  private func markConfigurationChanged() {
    configurationChanged = true
    configurationNeedsSave = true
  }

  private func persistAgentProfile(for conversation: VisualConversation) {
    let definition = conversation.profile
    upsert(definition, into: &configuration.agents)
    if configuration.defaultAgent == nil {
      configuration.defaultAgent = definition.id
      markConfigurationChanged()
    }
    do {
      try saveConfiguration()
      let runtime = runtime
      Task {
        try? await runtime.register(agent: definition, replacingExisting: true)
      }
    } catch {
      status = "error: \(error.localizedDescription)"
    }
  }
}
