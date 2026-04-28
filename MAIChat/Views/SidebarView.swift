import SwiftUI

private let sidebarListCoordinateSpace = "SidebarListCoordinateSpace"

struct SidebarView: View {
  @EnvironmentObject private var store: AppStore
  @Binding var showingSettings: Bool
  @State private var showingArchive = false
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

  private var visibleConversations: [Conversation] {
    store.conversations.filter { $0.isArchived == showingArchive }
  }

  private var conversationList: some View {
    GeometryReader { proxy in
      List {
        if showingArchive, visibleConversations.isEmpty {
          Text("No archived conversations.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 12)
            .modifier(SidebarEdgeContentBlur(containerHeight: proxy.size.height))
        }
        ForEach(visibleConversations) { conversation in
          let isSelected = store.selectedConversationID == conversation.id
          ConversationRow(
            conversation: conversation,
            isSelected: isSelected,
            isResponding: store.isResponding(in: conversation.id),
            containerHeight: proxy.size.height
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
              store.toggleArchive(conversation)
            } label: {
              Label(
                conversation.isArchived ? "Unarchive Conversation" : "Archive Conversation",
                systemImage: conversation.isArchived ? "tray.and.arrow.up" : "archivebox"
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
          .modifier(SidebarEdgeContentBlur(containerHeight: proxy.size.height))
        }
      }
      .listStyle(.sidebar)
      .coordinateSpace(name: sidebarListCoordinateSpace)
    }
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
      FloatingActionIcon(
        systemImage: showingArchive ? "tray.full.fill" : "archivebox",
        accessibilityLabel: showingArchive ? "Show active conversations" : "Show archived conversations",
        isActive: showingArchive
      ) {
        showingArchive.toggle()
      }
      FloatingActionIcon(
        systemImage: "gearshape",
        accessibilityLabel: "Settings"
      ) {
        showingSettings = true
      }
    }
  }
}

private struct SidebarEdgeContentBlur: ViewModifier {
  let containerHeight: CGFloat
  private let topFadeLength: CGFloat = 110
  private let bottomFadeLength: CGFloat = 210 
  private let maxBlurRadius: CGFloat = 4

  func body(content: Content) -> some View {
    content.visualEffect { content, proxy in
      content.blur(radius: blurRadius(for: proxy))
    }
  }

  private nonisolated func blurRadius(for proxy: GeometryProxy) -> CGFloat {
    let frame = proxy.frame(in: .named(sidebarListCoordinateSpace))
    return maxBlurRadius * edgeProgress(for: frame)
  }

  private nonisolated func edgeProgress(for frame: CGRect) -> CGFloat {
    guard containerHeight > 0 else { return 0 }
    let top = max(0, min(1, 1 - frame.minY / topFadeLength))
    let bottomStart = max(containerHeight, 0)
    let bottom = max(0, min(1, (frame.maxY - bottomStart) / bottomFadeLength))
    let progress = max(top, bottom)
    return progress * progress
  }
}

private struct SidebarRowBackground: View {
  let isSelected: Bool
  let containerHeight: CGFloat

  var body: some View {
    (isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
      .modifier(SidebarEdgeContentBlur(containerHeight: containerHeight))
  }
}

private struct FloatingActionIcon: View {
  let systemImage: String
  let accessibilityLabel: String
  var isActive: Bool = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.body.weight(.semibold))
        .foregroundStyle(isActive ? Color.white : Color.primary)
        .frame(width: 22, height: 22)
        .padding(12)
        .background(
          Circle()
            .fill(
              isActive
                ? AnyShapeStyle(Color.accentColor)
                : AnyShapeStyle(.regularMaterial))
        )
        .overlay(
          Circle()
            .strokeBorder(.secondary.opacity(isActive ? 0 : 0.18), lineWidth: 0.5)
        )
        .shadow(
          color: isActive ? Color.accentColor.opacity(0.4) : .black.opacity(0.18),
          radius: isActive ? 12 : 8,
          x: 0,
          y: 4
        )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
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
  let containerHeight: CGFloat
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
    .listRowBackground(
      SidebarRowBackground(isSelected: isSelected, containerHeight: containerHeight)
    )
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
