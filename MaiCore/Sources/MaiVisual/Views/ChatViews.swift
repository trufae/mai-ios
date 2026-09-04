import Foundation
import MaiCore
import SwiftTUIRuntime

/// The chats tab: a conversation sidebar next to the pane tree.
struct ChatsScreen: View {
  @Bindable var workspace: VisualWorkspace
  @FocusState private var focusedInput: PaneID?

  var body: some View {
    GeometryReader { proxy in
      HStack(alignment: .top, spacing: 0) {
        if workspace.showsSidebar && proxy.size.width >= 72 {
          ConversationSidebar(workspace: workspace)
            .frame(width: 26)
        }
        PaneNodeView(node: workspace.layout.root, workspace: workspace, focusedInput: $focusedInput)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .onAppear { focusedInput = workspace.layout.focusedPane }
    .onChange(of: workspace.layout.focusedPane) { _, pane in focusedInput = pane }
    .onChange(of: focusedInput) { _, pane in
      if let pane { workspace.focus(pane: pane) }
    }
  }
}

struct ConversationSidebar: View {
  let workspace: VisualWorkspace

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Conversations").bold().padding(.horizontal, 1)
      Divider()
      ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(workspace.conversations, id: \.id) { conversation in
            ConversationRow(conversation: conversation, workspace: workspace)
          }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      Divider()
      Button("New chat") { workspace.newConversationInFocusedPane() }
      Button("Clear chat") { workspace.clearFocusedConversation() }
      Button("Delete chat", role: .destructive) { workspace.deleteFocusedConversation() }
        .disabled(workspace.conversations.count <= 1)
    }
    .border(.separator, placement: .outset)
    .frame(maxHeight: .infinity, alignment: .topLeading)
  }
}

private struct ConversationRow: View {
  let conversation: VisualConversation
  let workspace: VisualWorkspace

  var body: some View {
    Button {
      workspace.show(conversation)
    } label: {
      HStack(spacing: 1) {
        Text(marker).foregroundStyle(workspace.isFocused(conversation) ? .tint : .muted)
        Text(conversation.title).lineLimit(1).truncationMode(.tail)
        Spacer(minLength: 0)
        if conversation.isRunning { Spinner() }
      }
    }
    .buttonStyle(.plain)
  }

  private var marker: String {
    if workspace.isFocused(conversation) { return "▶" }
    return workspace.isShown(conversation) ? "·" : " "
  }
}

/// Renders a pane tree node: leaves show conversations, splits nest stacks.
struct PaneNodeView: View {
  let node: PaneNode
  let workspace: VisualWorkspace
  var focusedInput: FocusState<PaneID?>.Binding

  var body: some View {
    switch node {
    case .leaf(let pane, let conversationID):
      if let conversation = workspace.conversation(conversationID) {
        ConversationPaneView(
          pane: pane,
          conversation: conversation,
          workspace: workspace,
          focusedInput: focusedInput)
      } else {
        Text("Missing conversation").foregroundStyle(.danger)
      }
    case .split(let axis, let first, let second):
      switch axis {
      case .horizontal:
        HStack(alignment: .top, spacing: 0) {
          PaneNodeView(node: first, workspace: workspace, focusedInput: focusedInput)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          PaneNodeView(node: second, workspace: workspace, focusedInput: focusedInput)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
      case .vertical:
        VStack(alignment: .leading, spacing: 0) {
          PaneNodeView(node: first, workspace: workspace, focusedInput: focusedInput)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          PaneNodeView(node: second, workspace: workspace, focusedInput: focusedInput)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
      }
    }
  }
}

struct ConversationPaneView: View {
  let pane: PaneID
  @Bindable var conversation: VisualConversation
  let workspace: VisualWorkspace
  var focusedInput: FocusState<PaneID?>.Binding

  private var isFocused: Bool { workspace.layout.focusedPane == pane }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 1) {
        Text(isFocused ? "●" : "○").foregroundStyle(isFocused ? .tint : .separator)
        Text(conversation.title).bold().lineLimit(1).truncationMode(.tail)
        Spacer(minLength: 1)
        Text(conversation.subtitle).foregroundStyle(.muted).lineLimit(1)
        if conversation.isRunning { Spinner() }
      }
      .padding(.horizontal, 1)
      Divider()
      TranscriptView(conversation: conversation)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      Divider()
      HStack(spacing: 1) {
        Text(conversation.isRunning ? "…" : ">").foregroundStyle(.tint)
        TextField(
          conversation.isRunning ? "Replying; Alt+K cancels" : "Message (Return sends)",
          text: $conversation.draft
        )
        .focused(focusedInput, equals: pane)
        .defaultFocus(focusedInput, pane)
        .onSubmit { workspace.send(conversation) }
      }
      .padding(.horizontal, 1)
      if let error = conversation.errorMessage {
        Text(error).foregroundStyle(.danger).lineLimit(2).padding(.horizontal, 1)
      }
    }
    .border(isFocused ? .tint : .separator, placement: .outset)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

struct TranscriptView: View {
  let conversation: VisualConversation

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: 1) {
          if conversation.visibleMessages.isEmpty && conversation.liveReply.isEmpty {
            Text("No messages yet. Type below and press Return.").foregroundStyle(.muted)
          }
          ForEach(conversation.visibleMessages, id: \.id) { message in
            MessageView(message: message)
          }
          if !conversation.liveReply.isEmpty {
            MessageBlock(label: "Assistant", text: conversation.liveReply, isLive: true)
          }
          ForEach(conversation.activity.indices, id: \.self) { index in
            Text(conversation.activity[index]).foregroundStyle(.muted)
          }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 1)
      }
      .onChange(of: conversation.revision) { _ = proxy.scrollTo(edge: .bottom) }
    }
  }
}

struct MessageView: View {
  let message: AgentMessage

  var body: some View {
    MessageBlock(label: label, text: TranscriptCopy.render(message), isLive: false)
  }

  private var label: String {
    switch message.role {
    case .user: "You"
    case .assistant: "Assistant"
    case .tool: "Tool"
    case .system: "System"
    case .developer: "Developer"
    }
  }
}

struct MessageBlock: View {
  let label: String
  let text: String
  let isLive: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(isLive ? "\(label) …" : label).bold().foregroundStyle(labelStyle)
      Text(text.isEmpty ? "(empty)" : text)
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private var labelStyle: SemanticShapeStyle {
    switch label {
    case "You": .tint
    case "Tool": .muted
    default: .success
    }
  }
}
