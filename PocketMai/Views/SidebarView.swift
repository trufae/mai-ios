import SwiftUI
import UIKit

struct SidebarView: View {
  @EnvironmentObject private var store: AppStore
  @Binding var showingSettings: Bool
  @State private var isSearchActive = false
  @State private var searchText = ""
  @State private var isSelectionMode = false
  @State private var selectedIDs: Set<UUID> = []
  @State private var pendingDeletion: PendingConversationDeletion?
  @State private var showingFolderManager = false
  @State private var keyboardOverlap: CGFloat = 0
  @FocusState private var isSearchFieldFocused: Bool
  let onSelectConversation: () -> Void
  @State private var visibleConversations: [ConversationSummary] = []
  @StateObject private var exportCoordinator = ConversationExportCoordinator()
  private let floatingActionHorizontalInset: CGFloat = 18
  private let floatingActionBottomInset: CGFloat = 22

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      conversationList
        .safeAreaInset(edge: .bottom) {
          Color.clear.frame(height: 80 + keyboardOverlap)
        }
      sidebarEdgeFades
      floatingActions
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
    .onAppear { refreshVisibleConversations() }
    .onChange(of: store.conversationSummaries) { _, _ in refreshVisibleConversations() }
    .onChange(of: searchText) { _, _ in refreshVisibleConversations() }
    .onChange(of: store.settings.selectedConversationFolderID) { _, _ in
      refreshVisibleConversations()
    }
    .onChange(of: store.settings.conversationFolders) { _, _ in refreshVisibleConversations() }
    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) {
      updateKeyboardOverlap(from: $0)
    }
    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) {
      updateKeyboardOverlap(from: $0)
    }
    .modifier(ConversationExportPresentations(coordinator: exportCoordinator))
    .sheet(isPresented: $showingFolderManager) {
      ConversationFolderManagementView()
        .environmentObject(store)
    }
  }

  private func refreshVisibleConversations() {
    let next: [ConversationSummary]
    if searchQuery.isEmpty {
      let folderID = store.selectedConversationFolderID
      next = store.conversationSummaries.filter { $0.folderID == folderID }
    } else {
      next = store.conversationSummaries.filter { conversationMatchesSearch($0) }
    }
    if visibleConversations != next {
      visibleConversations = next
    }
  }

  private var searchQuery: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var conversationList: some View {
    List {
      if visibleConversations.isEmpty, let emptyMessage {
        Text(emptyMessage)
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(.vertical, 12)
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
        .listRowBackground(SidebarRowBackground(isSelected: isSelected && !isSelectionMode))
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .top) {
      Color.clear.frame(height: 32)
    }
    .scrollIndicators(.hidden)
  }

  private var sidebarEdgeFades: some View {
    VStack(spacing: 0) {
      SidebarEdgeFade(edge: .top)
      Spacer(minLength: 0)
      SidebarEdgeFade(edge: .bottom)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .ignoresSafeArea(edges: .vertical)
    .allowsHitTesting(false)
  }

  private var emptyMessage: String? {
    if !searchQuery.isEmpty {
      return "No matching conversations."
    }
    if store.selectedConversationFolderID == ConversationFolder.archivedID {
      return "No archived conversations."
    }
    return "No conversations in \(store.selectedConversationFolder.displayName)."
  }

  private func conversationMatchesSearch(_ summary: ConversationSummary) -> Bool {
    let query = searchQuery
    guard !query.isEmpty else { return true }
    if text(summary.displayTitle, contains: query) || text(summary.displayPreview, contains: query)
    {
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

    Menu {
      ForEach(store.conversationFolders) { folder in
        Button {
          Task { await store.moveConversation(id: conversation.id, to: folder.id) }
        } label: {
          if folder.id == conversation.folderID {
            Label(folder.displayName, systemImage: "checkmark")
          } else {
            Label(folder.displayName, systemImage: folder.systemImage)
          }
        }
      }
    } label: {
      Label("Move to Folder", systemImage: "folder")
    }

    Button {
      Task { await store.cloneConversation(id: conversation.id) }
      onSelectConversation()
    } label: {
      Label("Clone Conversation", systemImage: "doc.on.doc")
    }

    Divider()

    ConversationExportMenu(conversationID: conversation.id, coordinator: exportCoordinator)

    Divider()

    Button(role: .destructive) {
      pendingDeletion = .single(conversation)
    } label: {
      Label("Delete...", systemImage: "trash")
    }
  }

  private var floatingActions: some View {
    GeometryReader { proxy in
      let availableWidth = max(proxy.size.width - floatingActionHorizontalInset * 2, 0)
      let isCompact = availableWidth < 300

      HStack(spacing: isCompact ? 6 : 10) {
        if isSelectionMode {
          selectionFloatingActions(compact: isCompact)
        } else {
          defaultFloatingActions(compact: isCompact)
        }
      }
      .frame(width: availableWidth)
      .frame(maxHeight: .infinity, alignment: .bottom)
      .padding(.horizontal, floatingActionHorizontalInset)
      .padding(.bottom, floatingActionBottomInset + keyboardOverlap)
      .animation(.snappy, value: isSearchActive)
    }
  }

  @ViewBuilder
  private func defaultFloatingActions(compact: Bool) -> some View {
    Menu {
      Button {
        store.selectConversationFolder(ConversationFolder.defaultID)
      } label: {
        folderPickerLabel(for: ConversationFolder.defaultFolder)
      }
      Button {
        store.selectConversationFolder(ConversationFolder.archivedID)
      } label: {
        folderPickerLabel(for: ConversationFolder.archivedFolder)
      }
      ForEach(store.customConversationFolders) { folder in
        Button {
          store.selectConversationFolder(folder.id)
        } label: {
          folderPickerLabel(for: folder)
        }
      }
      Divider()
      Button {
        showingFolderManager = true
      } label: {
        Label("Manage...", systemImage: "folder.badge.gearshape")
      }
    } label: {
      FloatingActionMenuIcon(
        systemImage: selectedFolderMenuIcon,
        isActive: store.selectedConversationFolderID != ConversationFolder.defaultID,
        compact: compact)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Conversation folder")
    FloatingSearchField(
      text: $searchText,
      isFocused: $isSearchFieldFocused,
      onActivate: activateSearch,
      onCancel: cancelSearch
    )
    FloatingActionIcon(
      systemImage: "gearshape",
      accessibilityLabel: "Settings",
      compact: compact
    ) {
      showingSettings = true
    }
  }

  @ViewBuilder
  private func folderPickerLabel(for folder: ConversationFolder) -> some View {
    if store.selectedConversationFolderID == folder.id {
      Label(folder.displayName, systemImage: "checkmark")
    } else {
      Label(folder.displayName, systemImage: folder.systemImage)
    }
  }

  private var selectedFolderMenuIcon: String {
    let folder = store.selectedConversationFolder
    if folder.id == ConversationFolder.archivedID {
      return "archivebox.fill"
    }
    if folder.id == ConversationFolder.defaultID {
      return "tray"
    }
    return "folder.fill"
  }

  private func activateSearch() {
    if !isSearchActive {
      withAnimation(.snappy) {
        isSearchActive = true
      }
      Task { await store.loadStoredConversationsForSearch() }
    }
    isSearchFieldFocused = true
  }

  private func cancelSearch() {
    withAnimation(.snappy) {
      searchText = ""
      isSearchActive = false
      isSearchFieldFocused = false
    }
  }

  @ViewBuilder
  private func selectionFloatingActions(compact: Bool) -> some View {
    let hasSelection = !selectedIDs.isEmpty
    FloatingActionPill(title: "Cancel", prominent: true, compact: compact) {
      withAnimation {
        isSelectionMode = false
        selectedIDs.removeAll()
      }
    }
    Spacer(minLength: compact ? 0 : 4)
    FloatingActionIcon(
      systemImage: selectedFolderIsArchived ? "tray.and.arrow.up" : "archivebox",
      accessibilityLabel: selectedFolderIsArchived ? "Move selected to Default" : "Archive selected",
      compact: compact
    ) {
      moveSelectedToArchiveOrDefault()
    }
    .disabled(!hasSelection)
    .opacity(hasSelection ? 1 : 0.5)
    FloatingActionIcon(
      systemImage: "trash",
      accessibilityLabel: "Delete selected",
      destructive: true,
      compact: compact
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

  private var selectedFolderIsArchived: Bool {
    store.selectedConversationFolderID == ConversationFolder.archivedID
  }

  private func moveSelectedToArchiveOrDefault() {
    let ids = selectedIDs
    let destination =
      selectedFolderIsArchived ? ConversationFolder.defaultID : ConversationFolder.archivedID
    Task {
      await store.moveConversations(ids, to: destination)
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

  private func updateKeyboardOverlap(from notification: Notification) {
    let duration =
      notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
    withAnimation(.easeOut(duration: duration)) {
      keyboardOverlap = keyboardOverlap(from: notification)
    }
  }

  private func keyboardOverlap(from notification: Notification) -> CGFloat {
    if notification.name == UIResponder.keyboardWillHideNotification {
      return 0
    }
    guard
      let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
    else {
      return 0
    }
    let screenMaxY = UIApplication.shared.openSessions
      .compactMap { ($0.scene as? UIWindowScene)?.screen }
      .first { $0.bounds.intersects(frame) }?.bounds.maxY
      ?? frame.maxY
    return max(0, screenMaxY - frame.minY)
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

private struct ConversationFolderManagementView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @State private var nameEdit: ConversationFolderNameEdit?
  @State private var nameDraft = ""
  @State private var pendingDeletion: ConversationFolder?

  var body: some View {
    NavigationStack {
      Form {
        Section("Built-in") {
          folderInfoRow(ConversationFolder.defaultFolder)
          folderInfoRow(ConversationFolder.archivedFolder)
        }

        Section {
          if store.customConversationFolders.isEmpty {
            Text("No custom folders.")
              .foregroundStyle(.secondary)
          }
          ForEach(store.customConversationFolders) { folder in
            customFolderRow(folder)
          }
        } header: {
          Text("Folders")
        } footer: {
          Text("Deleting a folder moves its conversations to Default.")
        }
      }
      .navigationTitle("Folders")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            beginCreate()
          } label: {
            Image(systemName: "plus")
          }
          .accessibilityLabel("New Folder")
        }
      }
    }
    .alert(nameEdit?.title ?? "Folder", isPresented: nameEditBinding) {
      TextField("Folder name", text: $nameDraft)
      Button("Cancel", role: .cancel) {
        clearNameEdit()
      }
      Button("Save") {
        saveNameEdit()
      }
    } message: {
      Text(nameEdit?.message ?? "")
    }
    .alert(
      "Delete Folder?",
      isPresented: deletionBinding,
      presenting: pendingDeletion
    ) { folder in
      Button("Cancel", role: .cancel) {
        pendingDeletion = nil
      }
      Button("Delete Folder", role: .destructive) {
        Task { await store.deleteConversationFolder(id: folder.id) }
        pendingDeletion = nil
      }
    } message: { folder in
      Text("Conversations in \(folder.displayName) will move to Default.")
    }
  }

  private func folderInfoRow(_ folder: ConversationFolder) -> some View {
    Label(folder.displayName, systemImage: folder.systemImage)
      .foregroundStyle(.secondary)
  }

  private func customFolderRow(_ folder: ConversationFolder) -> some View {
    HStack {
      Label(folder.displayName, systemImage: folder.systemImage)
      Spacer()
      Menu {
        Button {
          beginRename(folder)
        } label: {
          Label("Rename", systemImage: "pencil")
        }
        Button(role: .destructive) {
          pendingDeletion = folder
        } label: {
          Label("Delete", systemImage: "trash")
        }
      } label: {
        Image(systemName: "ellipsis.circle")
          .font(.title3)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Folder Actions")
    }
  }

  private var nameEditBinding: Binding<Bool> {
    Binding {
      nameEdit != nil
    } set: { isPresented in
      if !isPresented {
        clearNameEdit()
      }
    }
  }

  private var deletionBinding: Binding<Bool> {
    Binding {
      pendingDeletion != nil
    } set: { isPresented in
      if !isPresented {
        pendingDeletion = nil
      }
    }
  }

  private func beginCreate() {
    nameDraft = ""
    nameEdit = ConversationFolderNameEdit(folder: nil)
  }

  private func beginRename(_ folder: ConversationFolder) {
    nameDraft = folder.displayName
    nameEdit = ConversationFolderNameEdit(folder: folder)
  }

  private func saveNameEdit() {
    guard let edit = nameEdit else { return }
    if let folder = edit.folder {
      store.renameConversationFolder(id: folder.id, to: nameDraft)
    } else {
      store.createConversationFolder(named: nameDraft)
    }
    clearNameEdit()
  }

  private func clearNameEdit() {
    nameEdit = nil
    nameDraft = ""
  }
}

private struct ConversationFolderNameEdit: Identifiable {
  let id = UUID()
  let folder: ConversationFolder?

  var title: String {
    folder == nil ? "New Folder" : "Rename Folder"
  }

  var message: String {
    folder == nil ? "Create a folder for conversations." : "Rename this folder."
  }
}

private struct SidebarRowBackground: View {
  let isSelected: Bool

  var body: some View {
    (isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
  }
}

// Suppresses parent-driven re-invalidation; @State / @EnvironmentObject / @Binding still re-trigger body.
extension SidebarView: Equatable {
  nonisolated static func == (lhs: Self, rhs: Self) -> Bool { true }
}

struct SidebarPlaneEffect: ViewModifier {
  let progress: CGFloat

  func body(content: Content) -> some View {
    content
      .scaleEffect(scale, anchor: .leading)
  }

  private var clampedProgress: CGFloat {
    min(max(progress, 0), 1)
  }

  private var easedProgress: CGFloat {
    let progress = clampedProgress
    return progress * progress * (3 - 2 * progress)
  }

  private var scale: CGFloat {
    0.88 + easedProgress * 0.12
  }

}

struct SidebarDistanceTone: View {
  @Environment(\.colorScheme) private var colorScheme

  let progress: CGFloat

  var body: some View {
    toneColor
      .opacity(toneOpacity)
      .ignoresSafeArea(edges: .vertical)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }

  private var toneColor: Color {
    colorScheme == .dark ? .black : .white
  }

  private var toneOpacity: Double {
    let progress = min(max(progress, 0), 1)
    let eased = progress * progress * (3 - 2 * progress)
    return Double(1 - eased)
  }
}

private struct SidebarEdgeFade: View {
  @Environment(\.colorScheme) private var colorScheme

  let edge: VerticalEdge
  private let topFadeLength: CGFloat = 110
  private let bottomFadeLength: CGFloat = 210

  var body: some View {
    LinearGradient(
      colors: gradientColors,
      startPoint: .top,
      endPoint: .bottom
    )
    .frame(height: edge == .top ? topFadeLength : bottomFadeLength)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private var gradientColors: [Color] {
    switch edge {
    case .top:
      [edgeColor, edgeColor.opacity(0)]
    case .bottom:
      [edgeColor.opacity(0), edgeColor]
    }
  }

  private var edgeColor: Color {
    colorScheme == .dark ? .black : .white
  }
}

private struct FloatingGlassSurface<Background: InsettableShape>: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  let shape: Background
  var tint: Color? = nil

  func body(content: Content) -> some View {
    content
      .glassEffect(.clear.tint(tint).interactive(), in: shape)
      .overlay(shape.strokeBorder(borderColor, lineWidth: 0.5))
      .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 3)
  }

  private var borderColor: Color {
    colorScheme == .dark ? .white.opacity(0.08) : .black.opacity(0.08)
  }
}

struct FloatingActionIcon: View {
  let systemImage: String
  let accessibilityLabel: String
  var isActive: Bool = false
  var destructive: Bool = false
  var compact: Bool = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font((compact ? Font.title3 : Font.title2).weight(.semibold))
        .foregroundStyle(destructive ? Color.red : (isActive ? Color.accentColor : Color.primary))
        .frame(width: compact ? 24 : 28, height: compact ? 24 : 28)
        .padding(compact ? 12 : 14)
        .modifier(FloatingGlassSurface(shape: Circle(), tint: glassTint))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
  }

  private var glassTint: Color? {
    if destructive {
      return Color.red.opacity(0.16)
    }
    if isActive {
      return Color.accentColor.opacity(0.18)
    }
    return nil
  }
}

private struct FloatingActionMenuIcon: View {
  let systemImage: String
  var isActive: Bool = false
  var compact: Bool = false

  var body: some View {
    Image(systemName: systemImage)
      .font((compact ? Font.title3 : Font.title2).weight(.semibold))
      .foregroundStyle(isActive ? Color.accentColor : Color.primary)
      .frame(width: compact ? 24 : 28, height: compact ? 24 : 28)
      .padding(compact ? 12 : 14)
      .modifier(
        FloatingGlassSurface(
          shape: Circle(),
          tint: isActive ? Color.accentColor.opacity(0.18) : nil))
      .contentShape(Circle())
  }
}

private struct FloatingSearchField: View {
  @Binding var text: String
  let isFocused: FocusState<Bool>.Binding
  let onActivate: () -> Void
  let onCancel: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.body.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 22, height: 22)

      TextField("Search", text: $text)
        .textFieldStyle(.plain)
        .disableAutocorrection(true)
        .textInputAutocapitalization(.never)
        .submitLabel(.search)
        .focused(isFocused)
        .onSubmit {
          isFocused.wrappedValue = false
        }

      if showsCancelButton {
        Button(action: onCancel) {
          Image(systemName: "xmark.circle.fill")
            .font(.body.weight(.semibold))
            .frame(width: 22, height: 22)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cancel search")
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity)
    .modifier(
      FloatingGlassSurface(
        shape: Capsule(),
        tint: nil))
    .contentShape(Capsule())
    .onTapGesture {
      onActivate()
    }
    .onChange(of: isFocused.wrappedValue) { _, focused in
      if focused {
        onActivate()
      }
    }
    .accessibilityElement(children: .contain)
    .animation(.snappy, value: showsCancelButton)
  }

  private var showsCancelButton: Bool {
    isFocused.wrappedValue || !text.isEmpty
  }
}

struct FloatingActionPill: View {
  let title: String
  var systemImage: String? = nil
  let prominent: Bool
  var compact: Bool = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: compact ? 6 : 8) {
        if let systemImage {
          Image(systemName: systemImage)
            .font(.body.weight(.semibold))
            .frame(width: compact ? 20 : nil, height: compact ? 20 : nil)
        }
        Text(title)
          .font(.body.weight(prominent ? .semibold : .medium))
          .lineLimit(1)
          .minimumScaleFactor(0.9)
      }
      .padding(.horizontal, compact ? 12 : 16)
      .padding(.vertical, compact ? 11 : 12)
      .foregroundStyle(prominent ? Color.accentColor : Color.primary)
      .modifier(
        FloatingGlassSurface(
          shape: Capsule(),
          tint: prominent ? Color.accentColor.opacity(0.16) : nil))
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
