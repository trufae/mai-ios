import Foundation
import MaiCore
import SwiftTUIRuntime

/// The chats tab: a conversation sidebar next to the pane tree.
struct ChatsScreen: View {
  @Bindable var workspace: VisualWorkspace
  @FocusState private var focusedInput: PaneID?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ChatToolbar(workspace: workspace)
      Divider()
      GeometryReader { proxy in
        HStack(alignment: .top, spacing: 0) {
          if workspace.showsSidebar && proxy.size.width >= 72 {
            ConversationSidebar(workspace: workspace)
              .frame(width: 26)
          }
          PaneNodeView(
            node: workspace.layout.root, workspace: workspace, focusedInput: $focusedInput
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }
    .onAppear { focusedInput = workspace.layout.focusedPane }
    .onChange(of: workspace.layout.focusedPane) { _, pane in focusedInput = pane }
    .onChange(of: focusedInput) { _, pane in
      if let pane { workspace.focus(pane: pane) }
    }
  }
}

/// Portable pane controls: buttons reach every terminal through Tab, Return,
/// and the mouse, unlike Alt chords.
struct ChatToolbar: View {
  let workspace: VisualWorkspace
  @Environment(\.clipboardWriteAction) private var clipboardWrite

  var body: some View {
    HStack(spacing: 1) {
      Button("Menu ^K") { workspace.showsCommandMenu = true }
      Button("New") { workspace.newConversationInFocusedPane() }
      Button("Split →") { workspace.splitFocusedPane(.horizontal) }
      Button("Split ↓") { workspace.splitFocusedPane(.vertical) }
      Button("Close pane") { workspace.closeFocusedPane() }
        .disabled(!workspace.layout.canCloseFocusedPane)
      Button("Next pane") { workspace.focusNextPane() }
        .disabled(workspace.layout.panes.count < 2)
      Button("Copy reply") { workspace.copyLastReply { clipboardWrite($0) } }
      Button("Cancel") { workspace.cancelFocusedRun() }
        .disabled(!(workspace.focusedConversation?.isRunning ?? false))
      Button("REPL") { workspace.requestExit() }
    }
    .padding(.horizontal, 1)
    .frame(maxWidth: .infinity, alignment: .leading)
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
      Button("Rename chat") { workspace.requestRenameFocusedConversation() }
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
        if conversation.isRunning { Text("…").foregroundStyle(.warning) }
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
      if let output = conversation.commandOutput {
        CommandOutputView(output: output)
        Divider()
      }
      HStack(spacing: 1) {
        Text(conversation.isRunning ? "…" : ">").foregroundStyle(.tint)
        TextField(
          conversation.isRunning
            ? "Replying; \(visualAlternateKeyName)+K cancels"
            : "Message, or /help (Return sends)",
          text: $conversation.draft
        )
        .focused(focusedInput, equals: pane)
        .defaultFocus(focusedInput, pane)
        .onSubmit { workspace.send(conversation) }
        .onKeyPress(.escape) { _ in
          guard conversation.commandOutput != nil else { return .ignored }
          workspace.dismissCommandOutput(in: conversation)
          return .handled
        }
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

/// What the last slash command printed, shown REPL-style above the input.
struct CommandOutputView: View {
  let output: VisualCommandOutput

  private var text: String { MessageBlock.displayText(output.text) }

  private var rowCount: Int {
    min(12, max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 1) {
        Text(output.command).bold().foregroundStyle(.tint).lineLimit(1).truncationMode(.tail)
        Spacer(minLength: 1)
        Text("Esc closes").foregroundStyle(.separator)
      }
      .padding(.horizontal, 1)
      GeometryReader { geometry in
        ScrollView(.vertical) {
          Text(text)
            .frame(width: max(1, geometry.size.width - 2), alignment: .topLeading)
            .padding(.horizontal, 1)
        }
      }
      .frame(height: rowCount)
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }
}

struct TranscriptView: View {
  /// Older messages stay in the transcript but are not laid out every frame.
  static let renderedMessageLimit = 200

  let conversation: VisualConversation

  var body: some View {
    // The vertical scroll view hands its content whatever width it was
    // proposed, and a flexible frame above it proposes an unbounded width, so
    // pin the content to the measured pane width or long lines never wrap.
    GeometryReader { geometry in
      ScrollViewReader { proxy in
        ScrollView(.vertical) {
          transcriptContent(width: max(1, geometry.size.width - 2))
        }
        .onChange(of: conversation.revision) { _ = proxy.scrollTo(edge: .bottom) }
      }
    }
  }

  private func transcriptContent(width: Int) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      if conversation.visibleMessages.isEmpty && conversation.liveReply.isEmpty {
        Text("No messages yet. Type below and press Return.").foregroundStyle(.muted)
      }
      if conversation.visibleMessages.count > TranscriptView.renderedMessageLimit {
        Text(
          "… \(conversation.visibleMessages.count - TranscriptView.renderedMessageLimit) earlier messages hidden; use /chat log in the REPL."
        )
        .foregroundStyle(.muted)
      }
      ForEach(conversation.visibleMessages.suffix(TranscriptView.renderedMessageLimit), id: \.id) {
        message in
        MessageView(message: message)
      }
      if !conversation.liveReply.isEmpty {
        MessageBlock(label: "Assistant", text: conversation.liveReply, isLive: true)
      }
      ForEach(conversation.activity.indices, id: \.self) { index in
        Text(conversation.activity[index]).foregroundStyle(.muted)
      }
    }
    .frame(width: width, alignment: .topLeading)
    .padding(.horizontal, 1)
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
      Text(text.isEmpty ? "(empty)" : MessageBlock.displayText(text))
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  /// Terminal cells cannot show tabs or other control characters; expand tabs
  /// and drop the rest so message bodies render as plain wrapped prose.
  static func displayText(_ text: String) -> String {
    var result = ""
    result.reserveCapacity(text.utf8.count)
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\t":
        result.append("    ")
      case "\n":
        result.unicodeScalars.append(scalar)
      case "\r":
        continue
      default:
        if scalar.value < 0x20 || scalar.value == 0x7F { continue }
        result.unicodeScalars.append(scalar)
      }
    }
    return result
  }

  private var labelStyle: SemanticShapeStyle {
    switch label {
    case "You": .tint
    case "Tool": .muted
    default: .success
    }
  }
}
