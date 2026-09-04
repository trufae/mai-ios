import Foundation
import MaiCore
import SwiftTUIRuntime

/// The whole workspace: a title row, the tabbed screens, the key hints, and the
/// approval sheet. Key chords are declared here so they work from every tab.
struct VisualRootView: View {
  @Bindable var workspace: VisualWorkspace
  @Environment(\.clipboardWriteAction) private var clipboardWrite

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      TabView(selection: $workspace.selectedTab) {
        Tab("Chats", badge: "\(workspace.conversations.count)", value: VisualTab.chats) {
          ChatsScreen(workspace: workspace)
        }
        Tab("Providers", badge: "\(workspace.providers.count)", value: VisualTab.providers) {
          ProvidersScreen(workspace: workspace)
        }
        Tab("MCP", badge: "\(workspace.catalogs.count)", value: VisualTab.mcp) {
          MCPScreen(workspace: workspace)
        }
        Tab("Tools", badge: "\(workspace.tools.count)", value: VisualTab.tools) {
          ToolsScreen(workspace: workspace)
        }
        Tab("Agents", badge: "\(workspace.agents.count)", value: VisualTab.agents) {
          AgentsScreen(workspace: workspace)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      Divider()
      footer
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .panel(id: "pmai-visual")
    .keyCommand("New conversation", key: .character("n"), modifiers: .alt) {
      workspace.newConversationInFocusedPane()
    }
    .keyCommand("Split right", key: .character("v"), modifiers: .alt) {
      workspace.splitFocusedPane(.horizontal)
    }
    .keyCommand("Split down", key: .character("s"), modifiers: .alt) {
      workspace.splitFocusedPane(.vertical)
    }
    .keyCommand(
      "Close pane", key: .character("x"), modifiers: .alt,
      isEnabled: workspace.layout.canCloseFocusedPane
    ) {
      workspace.closeFocusedPane()
    }
    .keyCommand("Next pane", key: .arrowRight, modifiers: .alt) { workspace.focusNextPane() }
    .keyCommand("Next pane", key: .arrowDown, modifiers: .alt) { workspace.focusNextPane() }
    .keyCommand("Previous pane", key: .arrowLeft, modifiers: .alt) {
      workspace.focusPreviousPane()
    }
    .keyCommand("Previous pane", key: .arrowUp, modifiers: .alt) {
      workspace.focusPreviousPane()
    }
    .keyCommand("Toggle sidebar", key: .character("b"), modifiers: .alt) {
      workspace.showsSidebar.toggle()
    }
    .keyCommand("Cancel reply", key: .character("k"), modifiers: .alt) {
      workspace.cancelFocusedRun()
    }
    .keyCommand("Copy last reply", key: .character("c"), modifiers: .alt) { copyLastReply() }
    .keyCommand("Chats", key: .character("1"), modifiers: .alt) { workspace.selectedTab = .chats }
    .keyCommand("Providers", key: .character("2"), modifiers: .alt) {
      workspace.selectedTab = .providers
    }
    .keyCommand("MCP", key: .character("3"), modifiers: .alt) { workspace.selectedTab = .mcp }
    .keyCommand("Tools", key: .character("4"), modifiers: .alt) { workspace.selectedTab = .tools }
    .keyCommand("Agents", key: .character("5"), modifiers: .alt) {
      workspace.selectedTab = .agents
    }
    .sheet(
      item: $workspace.pendingApproval,
      onDismiss: { workspace.approvalSheetDismissed() }
    ) { pending in
      ApprovalSheet(pending: pending, workspace: workspace)
    }
    .task { await workspace.refreshRegistries() }
  }

  private var header: some View {
    HStack(spacing: 2) {
      Text("pmai visual").bold().foregroundStyle(.tint)
      if let focused = workspace.focusedConversation {
        Text(focused.title).lineLimit(1).truncationMode(.tail)
        Text(focused.subtitle).foregroundStyle(.muted).lineLimit(1)
      }
      Spacer(minLength: 1)
      if let status = workspace.status {
        Text(status)
          .foregroundStyle(status.hasPrefix("error") ? .danger : .warning)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .padding(.horizontal, 1)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var footer: some View {
    HStack(spacing: 2) {
      Text(footerHint).foregroundStyle(.muted).lineLimit(1).truncationMode(.tail)
      Spacer(minLength: 1)
      Text("Ctrl+C back to REPL").foregroundStyle(.separator)
    }
    .padding(.horizontal, 1)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var footerHint: String {
    switch workspace.selectedTab {
    case .chats:
      "Alt+N new · Alt+V/S split · Alt+X close · Alt+arrows focus · Alt+B sidebar · Alt+C copy · Alt+K cancel · Alt+1-5 tabs"
    case .providers:
      "Register OpenAI-compatible or plugin providers; 'Use' switches the focused chat · Alt+1-5 tabs"
    case .mcp:
      "Connect Streamable HTTP MCP servers; their tools appear in the Tools tab · Alt+1-5 tabs"
    case .tools:
      "Toggle which tools the focused chat may call; register plugin tool sources · Alt+1-5 tabs"
    case .agents:
      "Tune the focused chat, switch agents, or save the chat as a named agent · Alt+1-5 tabs"
    }
  }

  private func copyLastReply() {
    guard let focused = workspace.focusedConversation else { return }
    guard let text = focused.lastAssistantText else {
      workspace.status = "No assistant reply to copy in '\(focused.title)'."
      return
    }
    workspace.status =
      clipboardWrite(text)
      ? "Copied the last reply of '\(focused.title)' to the clipboard."
      : "The terminal does not expose a clipboard; use /copy in the REPL."
  }
}

struct ApprovalSheet: View {
  let pending: VisualApprovalHandler.Pending
  let workspace: VisualWorkspace

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text("Tool approval").bold()
      Text(
        "Agent '\(pending.request.run.agentID)' wants to run \(pending.request.tool.annotations.approval.rawValue) tool '\(pending.request.tool.name)'."
      )
      Text(pending.request.call.arguments.compactJSONString)
        .foregroundStyle(.muted)
        .lineLimit(8)
      HStack(spacing: 2) {
        Button("Approve") {
          workspace.resolveApproval(.approve(arguments: pending.request.call.arguments))
        }
        Button("Deny", role: .destructive) {
          workspace.resolveApproval(.deny(reason: "Denied by user."))
        }
        Button("Cancel run", role: .cancel) {
          workspace.resolveApproval(.cancelRun)
        }
      }
    }
    .padding(1)
    .frame(minWidth: 50, maxWidth: 90, alignment: .leading)
  }
}
