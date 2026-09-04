import Foundation
import SwiftTUICLI
import SwiftTUIRuntime
import Testing

@testable import MaiCore
@testable import MaiVisual

private let helloProfile = AgentDefinition(
  id: "main",
  instructions: "Be brief.",
  provider: .hello,
  model: "")

private actor AlwaysApprovalRecorder {
  private(set) var count = 0

  func record() {
    count += 1
  }
}

@MainActor
private func makeWorkspace(
  seed: VisualConversationSeed,
  snapshot: VisualWorkspaceSnapshot? = nil
) async throws -> VisualWorkspace {
  let runtime = AgentRuntime()
  try await runtime.register(HelloProvider())
  return VisualWorkspace(
    launch: VisualLaunch(focusedConversation: seed, snapshot: snapshot),
    runtime: runtime,
    plugins: PluginRegistry(),
    approvals: VisualApprovalHandler())
}

@Test("Pane layout splits, moves focus, closes panes, and keeps focus valid")
func paneLayoutOperations() {
  let a = UUID()
  let b = UUID()
  let c = UUID()
  var layout = PaneLayout(conversation: a)
  #expect(layout.panes == [PaneID(1)])
  #expect(!layout.canCloseFocusedPane)
  let closedSinglePane = layout.closeFocusedPane()
  #expect(!closedSinglePane)

  let second = layout.split(.horizontal, showing: b)
  #expect(layout.focusedPane == second)
  #expect(layout.focusedConversation == b)
  #expect(layout.panes == [PaneID(1), second])

  layout.focusPrevious()
  #expect(layout.focusedPane == PaneID(1))
  let third = layout.split(.vertical, showing: c)
  #expect(layout.panes == [PaneID(1), third, second])
  #expect(layout.conversation(in: third) == c)

  layout.focusNext()
  #expect(layout.focusedPane == second)
  layout.focusNext()
  #expect(layout.focusedPane == PaneID(1))

  let closedFirstPane = layout.closeFocusedPane()
  #expect(closedFirstPane)
  #expect(layout.panes == [third, second])
  #expect(layout.focusedPane == third)

  layout.show(a, in: second)
  #expect(layout.conversation(in: second) == a)
  layout.replaceConversation(a, with: b)
  #expect(layout.conversation(in: second) == b)

  layout.focus(PaneID(42))
  #expect(layout.focusedPane == third)
}

@Test("The workspace runs a conversation and reports its result")
@MainActor
func workspaceSendsMessages() async throws {
  let workspace = try await makeWorkspace(
    seed: VisualConversationSeed(title: "repl", profile: helloProfile))
  let conversation = try #require(workspace.focusedConversation)
  #expect(conversation.visibleMessages.isEmpty)

  conversation.draft = "ping"
  workspace.send(conversation)
  #expect(conversation.isRunning)
  await conversation.runTask?.value

  #expect(!conversation.isRunning)
  #expect(conversation.visibleMessages.map(\.role) == [.user, .assistant])
  #expect(conversation.lastAssistantText == "Hello from MaiCore: ping")
  #expect(conversation.title == "repl")

  let scratch = workspace.makeConversation()
  #expect(scratch.title == "Chat 2")
  scratch.draft = "rename me please"
  workspace.send(scratch)
  await scratch.runTask?.value
  #expect(scratch.title == "rename me please")
}

@Test("Snapshots resume every conversation and adopt the REPL's focused one")
@MainActor
func workspaceSnapshotRoundTrip() async throws {
  let workspace = try await makeWorkspace(
    seed: VisualConversationSeed(
      title: "repl",
      profile: helloProfile,
      messages: [.system("Be brief."), .user("hi")]))
  workspace.splitFocusedPane(.horizontal)
  #expect(workspace.conversations.count == 2)
  #expect(workspace.layout.panes.count == 2)
  let focused = try #require(workspace.focusedConversation)
  focused.title = "scratch"

  let outcome = workspace.shutdown()
  #expect(outcome.focusedConversation.title == "scratch")
  #expect(outcome.snapshot.conversations.count == 2)
  #expect(!outcome.configurationChanged)
  #expect(outcome.summary.contains("1 other conversation"))

  let replSeed = VisualConversationSeed(
    title: "repl",
    profile: helloProfile,
    messages: [.system("Be brief."), .user("hello again"), .assistant("hey")])
  let resumed = try await makeWorkspace(seed: replSeed, snapshot: outcome.snapshot)
  #expect(resumed.conversations.count == 2)
  #expect(resumed.layout == outcome.snapshot.layout)
  #expect(resumed.focusedConversation?.transcript.messages.last?.text == "hey")
  #expect(resumed.conversations[0].transcript.messages.map(\.text) == ["Be brief.", "hi"])

  let renamed = try #require(resumed.focusedConversation)
  resumed.requestRenameFocusedConversation()
  #expect(resumed.conversationRenameDraft == renamed.title)
  let rename = try #require(resumed.pendingConversationRename)
  resumed.conversationRenameDraft = "Renamed chat"
  resumed.confirmConversationRename(rename)
  #expect(renamed.title == "Renamed chat")
  #expect(resumed.pendingConversationRename == nil)

  let deletedID = resumed.focusedConversation?.id
  resumed.deleteFocusedConversation()
  #expect(resumed.conversations.count == 2)
  let deletion = try #require(resumed.pendingConversationDeletion)
  #expect(deletion.conversationID == deletedID)
  resumed.cancelConversationDeletion()
  #expect(resumed.conversations.count == 2)

  resumed.deleteFocusedConversation()
  resumed.confirmConversationDeletion(try #require(resumed.pendingConversationDeletion))
  #expect(resumed.conversations.count == 1)
  #expect(resumed.pendingConversationDeletion == nil)
  #expect(resumed.layout.panes.count == 2)
  #expect(resumed.focusedConversation?.id == resumed.conversations[0].id)
  resumed.deleteFocusedConversation()
  #expect(resumed.conversations.count == 1)
  #expect(resumed.pendingConversationDeletion == nil)
}

@Test("Registering a provider updates the runtime and the configuration draft")
@MainActor
func workspaceRegistersProviders() async throws {
  let workspace = try await makeWorkspace(
    seed: VisualConversationSeed(title: "repl", profile: helloProfile))
  try await workspace.plugins.install(MaiCoreBuiltinsPlugin())
  await workspace.refreshRegistries()
  #expect(workspace.providers.map(\.id) == [.hello])

  var form = ProviderForm()
  form.id = "greeter"
  form.kind = ConfiguredProviderKind.hello.rawValue
  form.displayName = "Greeter"
  try await workspace.registerProvider(form)
  #expect(workspace.providers.map(\.id) == [ProviderID("greeter"), .hello])
  #expect(workspace.configuration.providers.map(\.id) == ["greeter"])
  #expect(workspace.configurationChanged)

  form.id = ""
  await #expect(throws: VisualWorkspaceError.missingField("Identifier")) {
    try await workspace.registerProvider(form)
  }

  var agent = AgentForm()
  agent.id = "saved"
  workspace.useProvider(ProviderID("greeter"))
  try await workspace.saveFocusedConversationAsAgent(agent)
  #expect(workspace.agents.map(\.id) == ["saved"])
  #expect(workspace.configuration.agents.first?.provider == ProviderID("greeter"))
  #expect(workspace.focusedConversation?.profile.id == "saved")

  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("mai-visual-\(UUID().uuidString)/config.json").path
  workspace.configurationPath = path
  try workspace.saveConfiguration()
  let saved = try MaiConfiguration.load(from: URL(fileURLWithPath: path))
  #expect(saved.agents.map(\.id) == ["saved"])
  #expect(saved.providers.map(\.id) == ["greeter"])
}

@Test("Approvals raised during a run surface in the workspace and resolve the runtime")
@MainActor
func workspaceApprovals() async throws {
  let recorder = AlwaysApprovalRecorder()
  let approvals = VisualApprovalHandler {
    await recorder.record()
  }
  let runtime = AgentRuntime(approvalHandler: approvals)
  let workspace = VisualWorkspace(
    launch: VisualLaunch(
      focusedConversation: VisualConversationSeed(title: "repl", profile: helloProfile)),
    runtime: runtime,
    plugins: PluginRegistry(),
    approvals: approvals)
  await approvals.attach { pending in await workspace.present(pending) }

  let request = ApprovalRequest(
    run: AgentEventContext(runID: UUID(), parentRunID: nil, agentID: "main", depth: 0),
    tool: ToolDefinition(name: "echo", description: "Echo"),
    call: ToolCall(id: "call-1", name: "echo", arguments: .object(["text": .string("hi")])))
  let decision = Task { try await approvals.decide(request) }
  while workspace.pendingApproval == nil { await Task.yield() }
  #expect(workspace.pendingApproval?.request.tool.name == "echo")

  workspace.resolveApproval(.approve(arguments: request.call.arguments))
  #expect(workspace.pendingApproval == nil)
  #expect(try await decision.value == .approve(arguments: request.call.arguments))

  let second = Task { try await approvals.decide(request) }
  while workspace.pendingApproval == nil { await Task.yield() }
  await approvals.detach()
  #expect(try await second.value == .deny(reason: "Visual mode ended before the approval."))
  workspace.approvalSheetDismissed()
  #expect(workspace.pendingApproval == nil)

  await approvals.attach { pending in await workspace.present(pending) }
  let third = Task { try await approvals.decide(request) }
  let fourth = Task { try await approvals.decide(request) }
  while workspace.pendingApprovalCount < 2 { await Task.yield() }
  workspace.resolveApprovalAlways()
  #expect(try await third.value == .approve(arguments: request.call.arguments))
  #expect(try await fourth.value == .approve(arguments: request.call.arguments))
  #expect(await recorder.count == 1)

  let automatic = try await approvals.decide(request)
  #expect(automatic == .approve(arguments: request.call.arguments))
}

@Test("The root view renders the focused conversation without a terminal")
@MainActor
func rootViewRenders() async throws {
  let workspace = try await makeWorkspace(
    seed: VisualConversationSeed(
      title: "planning",
      profile: helloProfile,
      messages: [.system("Be brief."), .user("hi"), .assistant("Hello from MaiCore: hi")]))
  let output = RenderOnce.render(
    VisualRootView(workspace: workspace).frame(height: 30),
    width: 120,
    environment: ["NO_COLOR": "1"],
    isStdoutTTY: false)
  #expect(output.contains("pmai visual"))
  #expect(output.contains("planning"))
  #expect(output.contains("Hello from MaiCore: hi"))
  #expect(output.contains("Conversations"))
  #expect(output.contains("Rename chat"))
  #expect(output.contains("Delete chat"))
  #expect(output.contains("Message (Return sends)"))
}
