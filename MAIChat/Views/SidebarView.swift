import SwiftUI

struct SidebarView: View {
  @EnvironmentObject private var store: AppStore
  @Binding var showingSettings: Bool
  let onSelectConversation: () -> Void

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      conversationList
        .safeAreaInset(edge: .bottom) {
          Color.clear.frame(height: 80)
        }
      floatingActions
        .padding(.trailing, 18)
        .padding(.bottom, 22)
    }
  }

  private var conversationList: some View {
    List {
      ForEach(store.conversations) { conversation in
        let isSelected = store.selectedConversationID == conversation.id
        ConversationRow(
          conversation: conversation,
          isSelected: isSelected,
          isResponding: store.isResponding(in: conversation.id)
        ) {
          store.select(conversation)
          onSelectConversation()
        }
        .contextMenu {
          Button {
            store.togglePin(conversation)
          } label: {
            Label(
              conversation.isPinned ? "Unpin Conversation" : "Pin Conversation",
              systemImage: conversation.isPinned ? "pin.slash" : "pin"
            )
          }

          Button {
            store.cloneConversation(conversation)
            onSelectConversation()
          } label: {
            Label("Clone Conversation", systemImage: "doc.on.doc")
          }

          Button(role: .destructive) {
            store.deleteConversation(conversation)
          } label: {
            Label("Delete Conversation", systemImage: "trash")
          }

          if isSelected {
            Button(role: .destructive) {
              let others = Set(store.conversations.map(\.id)).subtracting([conversation.id])
              store.deleteConversations(others)
            } label: {
              Label("Delete all except this one", systemImage: "trash.slash")
            }
          }
        }
      }
    }
    .listStyle(.sidebar)
    .edgeFadeBlur()
  }

  private var floatingActions: some View {
    HStack(spacing: 10) {
      FloatingActionPill(
        title: "New Chat",
        systemImage: "square.and.pencil",
        prominent: true
      ) {
        store.newConversation()
        onSelectConversation()
      }
      FloatingActionPill(
        title: "Settings",
        systemImage: "gearshape",
        prominent: false
      ) {
        showingSettings = true
      }
    }
  }
}

private struct FloatingActionPill: View {
  let title: String
  let systemImage: String
  let prominent: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: systemImage)
          .font(.body.weight(.semibold))
        Text(title)
          .font(.body.weight(prominent ? .semibold : .medium))
      }
      .foregroundStyle(prominent ? Color.white : Color.primary)
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .background(
        Capsule()
          .fill(
            prominent
              ? AnyShapeStyle(Color.accentColor)
              : AnyShapeStyle(.regularMaterial))
      )
      .overlay(
        Capsule()
          .strokeBorder(.secondary.opacity(prominent ? 0 : 0.18), lineWidth: 0.5)
      )
      .shadow(
        color: prominent ? Color.accentColor.opacity(0.4) : .black.opacity(0.18),
        radius: prominent ? 12 : 8,
        x: 0,
        y: 4
      )
    }
    .buttonStyle(.plain)
  }
}

private struct ConversationRow: View {
  let conversation: Conversation
  let isSelected: Bool
  let isResponding: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(conversation.displayTitle)
              .font(.body.weight(.medium))
              .lineLimit(1)
            if conversation.isPinned {
              Image(systemName: "pin.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if conversation.isIncognito {
              Image(systemName: "eye.slash")
                .foregroundStyle(.secondary)
            }
          }
          Text(conversation.messages.last?.text ?? "No messages")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        Spacer()
        responseIndicator
      }
      .padding(.vertical, 5)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .listRowBackground(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
  }

  @ViewBuilder
  private var responseIndicator: some View {
    if isResponding {
      ProgressView()
        .controlSize(.small)
        .accessibilityLabel("Waiting for response")
    }
  }
}
