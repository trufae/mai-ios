import SwiftUI

private let sidebarListCoordinateSpace = "SidebarListCoordinateSpace"

struct SidebarView: View {
  @EnvironmentObject private var store: AppStore
  @Binding var showingSettings: Bool
  @State private var showingArchive = false
  @State private var isSearchActive = false
  @State private var searchText = ""
  @State private var isSelectionMode = false
  @State private var selectedIDs: Set<UUID> = []
  @State private var pendingDeletion: PendingConversationDeletion?
  @FocusState private var isSearchFieldFocused: Bool
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
    .alert(
      pendingDeletion?.title ?? "Delete conversations?",
      isPresented: deletionConfirmationBinding,
      presenting: pendingDeletion
    ) { deletion in
      Button("Cancel", role: .cancel) {
        pendingDeletion = nil
      }
      Button(deletion.buttonTitle, role: .destructive) {
        confirmDeletion(deletion)
      }
    } message: { deletion in
      Text(deletion.message)
    }
  }

  private var visibleConversations: [ConversationSummary] {
    if searchQuery.isEmpty {
      return store.conversationSummaries.filter { $0.isArchived == showingArchive }
    }
    return store.conversationSummaries.filter { conversationMatchesSearch($0) }
  }

  private var searchQuery: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var conversationList: some View {
    GeometryReader { proxy in
      List {
        if visibleConversations.isEmpty, let emptyMessage {
          Text(emptyMessage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 12)
            .modifier(SidebarEdgeContentBlur(containerHeight: proxy.size.height))
        }
        ForEach(visibleConversations) { conversation in
          let isSelected = store.selectedConversationID == conversation.id
          let isMultiSelected = selectedIDs.contains(conversation.id)
          ConversationRow(
            conversation: conversation,
            isSelected: isSelected,
            isResponding: store.isResponding(in: conversation.id),
            isSelectionMode: isSelectionMode,
            isMultiSelected: isMultiSelected
          ) {
            if isSelectionMode {
              toggleSelection(of: conversation.id)
            } else {
              Task { await store.selectConversation(id: conversation.id) }
              onSelectConversation()
            }
          }
          .contextMenu {
            if !isSelectionMode {
              conversationContextMenu(for: conversation, isCurrent: isSelected)
            }
          }
          .listRowBackground(
            SidebarRowBackground(
              isSelected: isSelected && !isSelectionMode,
              containerHeight: proxy.size.height
            )
          )
          .modifier(SidebarEdgeContentBlur(containerHeight: proxy.size.height))
        }
      }
      .listStyle(.sidebar)
      .scrollIndicators(.hidden)
      .coordinateSpace(name: sidebarListCoordinateSpace)
    }
  }

  private var emptyMessage: String? {
    if !searchQuery.isEmpty {
      return "No matching conversations."
    }
    if showingArchive {
      return "No archived conversations."
    }
    return nil
  }

  private func conversationMatchesSearch(_ summary: ConversationSummary) -> Bool {
    let query = searchQuery
    guard !query.isEmpty else { return true }
    if text(summary.displayTitle, contains: query) || text(summary.displayPreview, contains: query) {
      return true
    }
    guard let conversation = store.conversation(withID: summary.id) else { return false }
    return conversation.messages.contains { text($0.text, contains: query) }
  }

  private func text(_ text: String, contains query: String) -> Bool {
    text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
  }

  @ViewBuilder
  private func conversationContextMenu(for conversation: ConversationSummary, isCurrent: Bool)
    -> some View
  {
    Button {
      withAnimation {
        isSelectionMode = true
        selectedIDs = [conversation.id]
      }
    } label: {
      Label("Select...", systemImage: "checkmark.circle")
    }

    Button {
      Task { await store.togglePin(id: conversation.id) }
    } label: {
      Label(
        conversation.isPinned ? "Unpin Conversation" : "Pin to Top",
        systemImage: conversation.isPinned ? "pin.slash" : "pin"
      )
    }

    Button {
      Task { await store.toggleArchive(id: conversation.id) }
    } label: {
      Label(
        conversation.isArchived ? "Unarchive" : "Archive Chat",
        systemImage: conversation.isArchived ? "tray.and.arrow.up" : "archivebox"
      )
    }

    Button {
      Task { await store.cloneConversation(id: conversation.id) }
      onSelectConversation()
    } label: {
      Label("Clone Conversation", systemImage: "doc.on.doc")
    }

    Divider()

    Button(role: .destructive) {
      pendingDeletion = .single(conversation)
    } label: {
      Label("Delete...", systemImage: "trash")
    }
  }

  private var floatingActions: some View {
    GeometryReader { proxy in
      HStack(spacing: 10) {
        if isSelectionMode {
          selectionFloatingActions
        } else {
          defaultFloatingActions(searchWidth: searchFieldWidth(containerWidth: proxy.size.width))
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
  }

  @ViewBuilder
  private func defaultFloatingActions(searchWidth: CGFloat) -> some View {
    if isSearchActive {
      FloatingSearchField(
        text: $searchText,
        isFocused: $isSearchFieldFocused,
        width: searchWidth,
        onCancel: cancelSearch
      )
      .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
    } else {
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
        accessibilityLabel: showingArchive
          ? "Show active conversations" : "Show archived conversations",
        isActive: showingArchive
      ) {
        showingArchive.toggle()
      }
      FloatingActionIcon(
        systemImage: "magnifyingglass",
        accessibilityLabel: "Search conversations"
      ) {
        activateSearch()
      }
      FloatingActionIcon(
        systemImage: "gearshape",
        accessibilityLabel: "Settings"
      ) {
        showingSettings = true
      }
      .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
    }
  }

  private func searchFieldWidth(containerWidth: CGFloat) -> CGFloat {
    min(max(containerWidth - 4, 276), 320)
  }

  private func activateSearch() {
    withAnimation(.snappy) {
      isSearchActive = true
    }
    isSearchFieldFocused = true
    Task { await store.loadStoredConversationsForSearch() }
  }

  private func cancelSearch() {
    withAnimation(.snappy) {
      searchText = ""
      isSearchActive = false
      isSearchFieldFocused = false
    }
  }

  @ViewBuilder
  private var selectionFloatingActions: some View {
    let hasSelection = !selectedIDs.isEmpty
    FloatingActionPill(title: "Cancel", prominent: true) {
      withAnimation {
        isSelectionMode = false
        selectedIDs.removeAll()
      }
    }
    FloatingActionIcon(
      systemImage: showingArchive ? "tray.and.arrow.up" : "archivebox",
      accessibilityLabel: showingArchive ? "Unarchive selected" : "Archive selected"
    ) {
      archiveSelected()
    }
    .disabled(!hasSelection)
    .opacity(hasSelection ? 1 : 0.5)
    FloatingActionIcon(
      systemImage: "trash",
      accessibilityLabel: "Delete selected",
      destructive: true
    ) {
      deleteSelected()
    }
    .disabled(!hasSelection)
    .opacity(hasSelection ? 1 : 0.5)
  }

  private func toggleSelection(of id: UUID) {
    if selectedIDs.contains(id) {
      selectedIDs.remove(id)
    } else {
      selectedIDs.insert(id)
    }
  }

  private func archiveSelected() {
    let ids = selectedIDs
    Task {
      for id in ids {
        await store.toggleArchive(id: id)
      }
    }
    withAnimation {
      isSelectionMode = false
      selectedIDs.removeAll()
    }
  }

  private func deleteSelected() {
    guard !selectedIDs.isEmpty else { return }
    pendingDeletion = .selected(selectedIDs)
  }

  private func confirmDeletion(_ deletion: PendingConversationDeletion) {
    guard !deletion.ids.isEmpty else {
      pendingDeletion = nil
      return
    }
    store.deleteConversations(deletion.ids)
    withAnimation {
      isSelectionMode = false
      selectedIDs.removeAll()
    }
    pendingDeletion = nil
  }

  private var deletionConfirmationBinding: Binding<Bool> {
    Binding {
      pendingDeletion != nil
    } set: { isPresented in
      if !isPresented {
        pendingDeletion = nil
      }
    }
  }
}

private struct PendingConversationDeletion: Identifiable {
  let id = UUID()
  let ids: Set<UUID>
  let title: String
  let buttonTitle: String
  let message: String

  static func single(_ conversation: ConversationSummary) -> PendingConversationDeletion {
    PendingConversationDeletion(
      ids: [conversation.id],
      title: "Delete this conversation?",
      buttonTitle: "Delete Conversation",
      message: "This conversation and all of its messages will be deleted. This cannot be undone."
    )
  }

  static func selected(_ ids: Set<UUID>) -> PendingConversationDeletion {
    PendingConversationDeletion(
      ids: ids,
      title: "Delete selected conversations?",
      buttonTitle: "Delete \(ids.count) Conversation\(ids.count == 1 ? "" : "s")",
      message:
        "\(ids.count) selected conversation\(ids.count == 1 ? "" : "s") and their messages will be deleted. This cannot be undone."
    )
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
    let bottom = max(0, min(1, (frame.maxY - containerHeight) / bottomFadeLength))
    let progress = max(top, bottom)
    return progress * progress
  }
}

private struct FloatingChrome<Background: InsettableShape>: ViewModifier {
  let prominent: Bool
  let shape: Background
  var tint: Color? = nil

  func body(content: Content) -> some View {
    content
      .foregroundStyle(tint ?? (prominent ? Color.white : Color.primary))
      .background(
        shape.fill(
          prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial))
      )
      .overlay(shape.strokeBorder(.secondary.opacity(prominent ? 0 : 0.18), lineWidth: 0.5))
      .shadow(
        color: prominent ? Color.accentColor.opacity(0.4) : .black.opacity(0.18),
        radius: prominent ? 12 : 8, x: 0, y: 4)
  }
}

private struct FloatingActionIcon: View {
  let systemImage: String
  let accessibilityLabel: String
  var isActive: Bool = false
  var destructive: Bool = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.body.weight(.semibold))
        .frame(width: 22, height: 22)
        .padding(12)
        .modifier(
          FloatingChrome(
            prominent: isActive,
            shape: Circle(),
            tint: destructive ? .red : nil
          ))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
  }
}

private struct FloatingSearchField: View {
  @Binding var text: String
  let isFocused: FocusState<Bool>.Binding
  let width: CGFloat
  let onCancel: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.body.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 22, height: 22)

      TextField("Search messages", text: $text)
        .textFieldStyle(.plain)
        .disableAutocorrection(true)
        .textInputAutocapitalization(.never)
        .submitLabel(.search)
        .focused(isFocused)
        .onSubmit {
          isFocused.wrappedValue = false
        }

      Button(action: onCancel) {
        Image(systemName: "xmark.circle.fill")
          .font(.body.weight(.semibold))
          .frame(width: 22, height: 22)
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Cancel search")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .frame(width: width)
    .modifier(FloatingChrome(prominent: false, shape: Capsule()))
    .accessibilityElement(children: .contain)
  }
}

private struct FloatingActionPill: View {
  let title: String
  var systemImage: String? = nil
  let prominent: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        if let systemImage {
          Image(systemName: systemImage).font(.body.weight(.semibold))
        }
        Text(title).font(.body.weight(prominent ? .semibold : .medium))
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .modifier(FloatingChrome(prominent: prominent, shape: Capsule()))
    }
    .buttonStyle(.plain)
  }
}

private struct ConversationRow: View {
  let conversation: ConversationSummary
  let isSelected: Bool
  let isResponding: Bool
  var isSelectionMode: Bool = false
  var isMultiSelected: Bool = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        if isSelectionMode {
          Image(systemName: isMultiSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isMultiSelected ? Color.accentColor : Color.secondary)
            .transition(.opacity.combined(with: .move(edge: .leading)))
        }
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
          }
          Text(conversation.displayPreview)
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
