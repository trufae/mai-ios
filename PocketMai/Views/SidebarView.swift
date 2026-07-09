import SwiftUI
import UIKit

extension View {
  @ViewBuilder
  func adaptiveGlassButtonStyle() -> some View {
    if #available(iOS 26.0, *) {
      self.buttonStyle(.glass)
    } else {
      self.buttonStyle(.borderless)
    }
  }
}

struct SidebarView: View {
  @EnvironmentObject private var store: AppStore
  @Binding var showingSettings: Bool
  @State private var isSearchActive = false
  @State private var searchText = ""
  @State private var isSelectionMode = false
  @State private var selectedIDs: Set<UUID> = []
  @State private var pendingDeletion: PendingConversationDeletion?
  @State private var showingFolderManager = false
  @State private var showingMoveDestinationDialog = false
  @State private var keyboardOverlap: CGFloat = 0
  @FocusState private var isSearchFieldFocused: Bool
  let onSelectConversation: (UUID) -> Void
  let onDismiss: () -> Void
  @State private var visibleConversations: [ConversationSummary] = []
  @State private var visibleConversationsRefreshTask: Task<Void, Never>?
  @State private var visibleConversationsRefreshGeneration = 0
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
    .confirmationDialog(
      moveDestinationDialogTitle,
      isPresented: $showingMoveDestinationDialog,
      titleVisibility: .visible
    ) {
      ForEach(store.conversationFolders) { folder in
        Button {
          moveSelected(to: folder.id)
        } label: {
          Label(folder.displayName, systemImage: folder.systemImage)
        }
        .disabled(!selectedConversationsCanMove(to: folder.id))
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(moveDestinationDialogMessage)
    }
    .onAppear { refreshVisibleConversations() }
    .onChange(of: store.conversationSummaries) { _, _ in refreshVisibleConversations() }
    .onChange(of: searchText) { _, _ in refreshVisibleConversations() }
    .onChange(of: isSearchFieldFocused) { _, focused in
      if focused {
        activateSearch()
      } else if searchText.isEmpty {
        deactivateSearchIfEmpty()
      }
    }
    .onChange(of: store.settings.selectedConversationFolderID) { _, _ in
      refreshVisibleConversations()
    }
    .onChange(of: store.settings.conversationFolders) { _, _ in refreshVisibleConversations() }
    .onDisappear {
      visibleConversationsRefreshTask?.cancel()
      visibleConversationsRefreshTask = nil
    }
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
    visibleConversationsRefreshTask?.cancel()
    visibleConversationsRefreshGeneration += 1

    let generation = visibleConversationsRefreshGeneration
    let query = searchQuery
    let folderID = store.selectedConversationFolderID
    let summaries = store.conversationSummaries
    let loadedMessageTextsByID: [UUID: [String]]
    if query.isEmpty {
      loadedMessageTextsByID = [:]
    } else {
      loadedMessageTextsByID = Dictionary(
        uniqueKeysWithValues: store.conversations.map { conversation in
          (conversation.id, conversation.messages.map(\.text))
        })
    }

    visibleConversationsRefreshTask = Task { @MainActor in
      let next = await Self.filteredVisibleConversations(
        summaries: summaries,
        query: query,
        folderID: folderID,
        loadedMessageTextsByID: loadedMessageTextsByID)
      guard !Task.isCancelled,
        visibleConversationsRefreshGeneration == generation
      else {
        return
      }
      if visibleConversations != next {
        visibleConversations = next
      }
    }
  }

  private static func filteredVisibleConversations(
    summaries: [ConversationSummary],
    query: String,
    folderID: String,
    loadedMessageTextsByID: [UUID: [String]]
  ) async -> [ConversationSummary] {
    await Task.detached(priority: .userInitiated) {
      if query.isEmpty {
        return summaries.filter { $0.folderID == folderID }
      }
      return summaries.filter {
        conversation(
          $0,
          matches: query,
          loadedMessageTexts: loadedMessageTextsByID[$0.id] ?? [])
      }
    }.value
  }

  private static func conversation(
    _ summary: ConversationSummary,
    matches query: String,
    loadedMessageTexts: [String]
  ) -> Bool {
    guard !query.isEmpty else { return true }
    if text(summary.displayTitle, contains: query) || text(summary.displayPreview, contains: query)
    {
      return true
    }
    return loadedMessageTexts.contains { text($0, contains: query) }
  }

  private static func text(_ text: String, contains query: String) -> Bool {
    text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
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
            onSelectConversation(conversation.id)
          }
        }
        .modifier(
          ConversationSummaryActionsModifier(
            conversation: conversation,
            isCurrent: isSelected,
            isEnabled: !isSelectionMode,
            exportCoordinator: exportCoordinator,
            onSelectForBatch: {
              withAnimation {
                isSelectionMode = true
                selectedIDs = [conversation.id]
              }
            },
            onAfterClone: onDismiss)
        )
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
        store.selectConversationFolder(ConversationFolder.iCloudID)
      } label: {
        folderPickerLabel(for: ConversationFolder.iCloudFolder)
      }
      .disabled(!store.canUseConversationFolder(ConversationFolder.iCloudID))
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
    if !searchControlsExpanded {
      FloatingActionIcon(
        systemImage: "gearshape",
        accessibilityLabel: "Settings",
        compact: compact
      ) {
        showingSettings = true
      }
      .transition(.opacity.combined(with: .scale(scale: 0.86)))
    }
  }

  @ViewBuilder
  private func folderPickerLabel(for folder: ConversationFolder) -> some View {
    let isUnavailable = !store.canUseConversationFolder(folder.id)
    if store.selectedConversationFolderID == folder.id {
      Label(folder.displayName, systemImage: "checkmark")
        .foregroundStyle(isUnavailable ? Color.secondary : Color.primary)
    } else {
      Label(folder.displayName, systemImage: folder.systemImage)
        .foregroundStyle(isUnavailable ? Color.secondary : Color.primary)
    }
  }

  private var selectedFolderMenuIcon: String {
    let folder = store.selectedConversationFolder
    if folder.id == ConversationFolder.iCloudID {
      return "icloud.fill"
    }
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

  private func deactivateSearchIfEmpty() {
    guard searchText.isEmpty else { return }
    withAnimation(.snappy) {
      isSearchActive = false
    }
  }

  private var searchControlsExpanded: Bool {
    isSearchActive || isSearchFieldFocused || !searchText.isEmpty
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
      systemImage: "folder",
      accessibilityLabel: "Move selected",
      compact: compact
    ) {
      showingMoveDestinationDialog = true
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

  private var moveDestinationDialogTitle: String {
    selectedIDs.count == 1 ? "Move Conversation" : "Move Conversations"
  }

  private var moveDestinationDialogMessage: String {
    "Select a destination folder for \(selectedIDs.count) selected conversation\(selectedIDs.count == 1 ? "" : "s")."
  }

  private func selectedConversationsCanMove(to folderID: String) -> Bool {
    guard store.canUseConversationFolder(folderID) else { return false }
    return store.conversationSummaries.contains { summary in
      selectedIDs.contains(summary.id) && summary.folderID != folderID
    }
  }

  private func moveSelected(to folderID: String) {
    let ids = selectedIDs
    guard !ids.isEmpty, store.canUseConversationFolder(folderID) else { return }
    Task {
      await store.moveConversations(ids, to: folderID)
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
    withAnimation(keyboardAnimation(from: notification)) {
      keyboardOverlap = keyboardOverlap(from: notification)
    }
  }

  private func keyboardAnimation(from notification: Notification) -> Animation {
    let duration =
      notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
    let rawCurve =
      (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?
      .intValue ?? UIView.AnimationCurve.easeInOut.rawValue

    if let curve = UIView.AnimationCurve(rawValue: rawCurve) {
      switch curve {
      case .easeInOut:
        return .easeInOut(duration: duration)
      case .easeIn:
        return .easeIn(duration: duration)
      case .easeOut:
        return .easeOut(duration: duration)
      case .linear:
        return .linear(duration: duration)
      @unknown default:
        return .smooth(duration: duration)
      }
    }
    return .smooth(duration: duration)
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

struct PendingConversationDeletion: Identifiable {
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

struct PendingConversationRename: Identifiable {
  let id: UUID
}

struct ConversationSummaryActionsModifier: ViewModifier {
  @EnvironmentObject private var store: AppStore
  let conversation: ConversationSummary
  let isCurrent: Bool
  let isEnabled: Bool
  @ObservedObject var exportCoordinator: ConversationExportCoordinator
  var onSelectForBatch: (() -> Void)?
  var onAfterClone: () -> Void = {}

  @State private var pendingDeletion: PendingConversationDeletion?
  @State private var pendingRename: PendingConversationRename?
  @State private var renameDraft = ""

  func body(content: Content) -> some View {
    if isEnabled {
      content
        .contextMenu {
          contextMenuItems
        }
        .alert("Change Title", isPresented: renameAlertBinding) {
          TextField("Chat title", text: $renameDraft)
            .onSubmit {
              saveRename()
            }
          Button("Cancel", role: .cancel) {
            clearRename()
          }
          Button("Save") {
            saveRename()
          }
        }
        .alert(
          pendingDeletion?.title ?? "Delete conversation?",
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
    } else {
      content
    }
  }

  @ViewBuilder
  private var contextMenuItems: some View {
    if let onSelectForBatch {
      Button {
        onSelectForBatch()
      } label: {
        Label("Select...", systemImage: "checkmark.circle")
      }
    }

    Button {
      beginRename(conversation)
    } label: {
      Label("Change Title...", systemImage: "pencil")
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
        .disabled(!store.canUseConversationFolder(folder.id) || folder.id == conversation.folderID)
      }
    } label: {
      Label("Move to Folder", systemImage: "folder")
    }

    Button {
      Task { await store.cloneConversation(id: conversation.id) }
      onAfterClone()
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

  private func beginRename(_ conversation: ConversationSummary) {
    renameDraft = conversation.displayTitle
    pendingRename = PendingConversationRename(id: conversation.id)
  }

  private func saveRename() {
    guard let pendingRename else { return }
    let id = pendingRename.id
    let title = renameDraft
    clearRename()
    Task {
      await store.renameConversation(id: id, to: title)
    }
  }

  private func clearRename() {
    pendingRename = nil
    renameDraft = ""
  }

  private var renameAlertBinding: Binding<Bool> {
    Binding {
      pendingRename != nil
    } set: { isPresented in
      if !isPresented {
        clearRename()
      }
    }
  }

  private func confirmDeletion(_ deletion: PendingConversationDeletion) {
    guard !deletion.ids.isEmpty else {
      pendingDeletion = nil
      return
    }
    store.deleteConversations(deletion.ids)
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

private struct ConversationFolderManagementView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @State private var nameEdit: ConversationFolderNameEdit?
  @State private var nameDraft = ""
  @State private var pendingDeletion: ConversationFolder?
  @State private var defaultsFolder: ConversationFolder?
  @State private var iconFolder: ConversationFolder?

  var body: some View {
    NavigationStack {
      Form {
        Section {
          folderInfoRow(ConversationFolder.defaultFolder)
          folderInfoRow(ConversationFolder.iCloudFolder)
          folderInfoRow(ConversationFolder.archivedFolder)
        } header: {
          Text("Built-in")
        } footer: {
          Text("Only conversations in iCloud sync across devices. Default, Archived, and custom folders stay on this device.")
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
    .sheet(item: $defaultsFolder) { folder in
      ConversationFolderDefaultsView(folder: folder)
        .environmentObject(store)
    }
    .sheet(item: $iconFolder) { folder in
      ConversationFolderIconPickerView(folder: folder)
        .environmentObject(store)
    }
  }

  private func folderInfoRow(_ folder: ConversationFolder) -> some View {
    HStack {
      Label(folder.displayName, systemImage: folder.systemImage)
        .foregroundStyle(.secondary)
      Spacer()
      folderActionsMenu(for: folder, allowsRenameDelete: false)
    }
  }

  private func customFolderRow(_ folder: ConversationFolder) -> some View {
    HStack {
      Label(folder.displayName, systemImage: folder.systemImage)
      Spacer()
      folderActionsMenu(for: folder, allowsRenameDelete: true)
    }
  }

  private func folderActionsMenu(
    for folder: ConversationFolder,
    allowsRenameDelete: Bool
  ) -> some View {
    Menu {
      Button {
        defaultsFolder = folder
      } label: {
        Label("Defaults...", systemImage: "slider.horizontal.3")
      }
      if allowsRenameDelete {
        Button {
          beginRename(folder)
        } label: {
          Label("Rename", systemImage: "pencil")
        }
        Button {
          iconFolder = folder
        } label: {
          Label("Change Icon...", systemImage: "square.grid.2x2")
        }
        Button(role: .destructive) {
          pendingDeletion = folder
        } label: {
          Label("Delete", systemImage: "trash")
        }
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .font(.title3)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Folder Actions")
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

private struct ConversationFolderIconPickerView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  let folder: ConversationFolder
  @State private var searchText = ""

  private let columns = [GridItem(.adaptive(minimum: 56), spacing: 12)]

  private var selectedIcon: String {
    store.customConversationFolders.first { $0.id == folder.id }?.icon ?? "folder"
  }

  private var filteredGroups: [ConversationFolderIconCatalog.Group] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else { return ConversationFolderIconCatalog.groups }
    return ConversationFolderIconCatalog.groups.compactMap { group in
      let matches = group.symbols.filter { $0.contains(query) }
      return matches.isEmpty ? nil : .init(title: group.title, symbols: matches)
    }
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 24) {
          ForEach(filteredGroups) { group in
            VStack(alignment: .leading, spacing: 12) {
              Text(group.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
              LazyVGrid(columns: columns, spacing: 12) {
                ForEach(group.symbols, id: \.self) { symbol in
                  iconCell(symbol)
                }
              }
            }
          }
          if filteredGroups.isEmpty {
            Text("No icons match \"\(searchText)\".")
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .center)
              .padding(.top, 40)
          }
        }
        .padding()
      }
      .navigationTitle("Folder Icon")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $searchText, prompt: "Search icons")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  private func iconCell(_ symbol: String) -> some View {
    let isSelected = symbol == selectedIcon
    return Button {
      store.setConversationFolderIcon(id: folder.id, to: symbol)
      dismiss()
    } label: {
      Image(systemName: symbol)
        .font(.title2)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        )
        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(symbol)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }
}

private enum ConversationFolderIconCatalog {
  struct Group: Identifiable {
    var id: String { title }
    let title: String
    let symbols: [String]
  }

  static let groups: [Group] = [
    Group(
      title: "Folders",
      symbols: [
        "folder", "folder.fill", "tray", "tray.full", "archivebox", "shippingbox",
        "internaldrive", "externaldrive", "doc", "doc.text", "doc.on.doc", "books.vertical",
      ]),
    Group(
      title: "Symbols",
      symbols: [
        "star", "star.fill", "heart", "heart.fill", "bookmark", "bookmark.fill",
        "flag", "flag.fill", "tag", "tag.fill", "pin", "pin.fill", "bell", "bolt.fill",
        "sparkles", "crown", "trophy", "gift", "lightbulb", "flame.fill",
      ]),
    Group(
      title: "Work",
      symbols: [
        "briefcase", "briefcase.fill", "case", "building.2", "building.columns",
        "graduationcap", "books.vertical.fill", "pencil", "paperclip", "calendar",
        "clock", "checkmark.seal", "list.bullet.clipboard", "chart.bar", "chart.pie",
      ]),
    Group(
      title: "Tech",
      symbols: [
        "desktopcomputer", "laptopcomputer", "iphone", "ipad", "keyboard", "terminal",
        "cpu", "memorychip", "server.rack", "cloud", "wifi", "antenna.radiowaves.left.and.right",
        "gearshape", "gearshape.2", "hammer", "wrench.and.screwdriver",
      ]),
    Group(
      title: "Communication",
      symbols: [
        "message", "bubble.left", "bubble.left.and.bubble.right", "envelope", "envelope.fill",
        "phone", "video", "mic", "waveform", "person", "person.2", "person.crop.circle",
        "quote.bubble", "text.bubble",
      ]),
    Group(
      title: "Life",
      symbols: [
        "house", "house.fill", "cart", "creditcard", "bag", "fork.knife", "cup.and.saucer",
        "airplane", "car", "bicycle", "map", "location", "globe", "leaf", "pawprint",
        "gamecontroller", "music.note", "paintpalette", "camera", "photo",
      ]),
    Group(
      title: "Nature",
      symbols: [
        "sun.max", "moon", "moon.stars", "cloud.rain", "snowflake", "drop", "flame",
        "tree", "mountain.2", "tortoise", "hare", "ant", "fish", "bird",
      ]),
  ]
}

private struct ConversationFolderDefaultsView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  let folder: ConversationFolder
  @State private var draft = ConversationFolderDefaults()
  @State private var didLoad = false
  @State private var modelFilter = ""

  var body: some View {
    NavigationStack {
      Form {
        Section("System Prompt") {
          Picker("Prompt", selection: systemPromptBinding) {
            Text(appDefaultPromptTitle).tag(UUID?.none)
            ForEach(store.settings.systemPrompts) { prompt in
              Text(prompt.displayName).tag(Optional(prompt.id))
            }
          }
        }

        Section("Provider & Model") {
          providerMenu
          providerModelControls
        }

        Section {
          Button {
            draft = ConversationFolderDefaults()
            modelFilter = ""
          } label: {
            Label("Reset to App Defaults", systemImage: "arrow.counterclockwise")
          }
          .disabled(draft.usesAppDefaults)
        } footer: {
          Text(defaultsFooterText)
        }
      }
      .navigationTitle(folder.displayName)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            saveAndDismiss()
          }
          .disabled(!canSave)
        }
      }
    }
    .onAppear {
      loadDefaultsIfNeeded()
      store.refreshLocalMLXModels()
    }
    .onChange(of: store.localMLXModelIDs) { _, _ in
      ensureDraftMLXModelSelectionIsAvailable()
    }
  }

  private var appDefaultPromptTitle: String {
    let prompt = store.settings.defaultPrompt().displayName
    return "App Default (\(prompt))"
  }

  private var systemPromptBinding: Binding<UUID?> {
    Binding(
      get: { draft.systemPromptID },
      set: { draft.systemPromptID = $0 }
    )
  }

  private var providerMenu: some View {
    Menu {
      Button {
        selectProvider(nil)
      } label: {
        providerMenuLabel(
          "Use App Default",
          systemImage: "gearshape",
          isSelected: draft.provider == nil)
      }
      if store.appleIntelligenceIsAvailable {
        Button {
          selectProvider(.apple)
        } label: {
          providerMenuLabel(
            "Apple Intelligence",
            systemImage: "apple.logo",
            isSelected: draft.provider == .apple)
        }
      }
      Button {
        selectProvider(.mlx)
      } label: {
        providerMenuLabel(
          "MLX Local",
          systemImage: "cpu",
          isSelected: draft.provider == .mlx)
      }
      if !store.settings.airplaneModeEnabled {
        ForEach(store.settings.openAIEndpoints.filter(\.isEnabled)) { endpoint in
          Button {
            selectProvider(.endpoint(endpoint.id))
          } label: {
            providerMenuLabel(
              endpoint.displayName,
              systemImage: "network",
              isSelected: draft.provider == .openAICompatible
                && draft.endpointID == endpoint.id)
          }
        }
      }
    } label: {
      HStack {
        Text("Provider")
        Spacer()
        Label(providerMenuTitle, systemImage: providerMenuIcon)
          .foregroundStyle(Color.accentColor)
      }
    }
  }

  @ViewBuilder
  private func providerMenuLabel(
    _ title: String,
    systemImage: String,
    isSelected: Bool
  ) -> some View {
    if isSelected {
      Label(title, systemImage: "checkmark")
    } else {
      Label(title, systemImage: systemImage)
    }
  }

  private var providerMenuTitle: String {
    switch draft.provider {
    case nil:
      return "Use App Default"
    case .apple:
      return store.appleIntelligenceIsAvailable ? "Apple Intelligence" : "Unavailable"
    case .mlx:
      return "MLX Local"
    case .openAICompatible:
      return selectedEndpoint?.displayName ?? "OpenAI Compatible"
    }
  }

  private var providerMenuIcon: String {
    switch draft.provider {
    case nil:
      return "gearshape"
    case .apple:
      return store.appleIntelligenceIsAvailable ? "apple.logo" : "exclamationmark.triangle"
    case .mlx:
      return "cpu"
    case .openAICompatible:
      return selectedEndpoint == nil ? "exclamationmark.triangle" : "network"
    }
  }

  @ViewBuilder
  private var providerModelControls: some View {
    switch draft.provider {
    case nil:
      LabeledContent("Model", value: appDefaultModelTitle)
    case .apple:
      EmptyView()
    case .mlx:
      mlxModelControls
    case .openAICompatible:
      openAICompatibleModelControls
    }
  }

  private var appDefaultModelTitle: String {
    let defaults = store.effectiveDefaultProviderConfiguration
    switch defaults.provider {
    case .apple:
      return "Apple Intelligence"
    case .mlx:
      return defaults.modelID.isEmpty ? "MLX Local" : defaults.modelID
    case .openAICompatible:
      let endpoint = defaults.endpointID.flatMap { id in
        store.settings.openAIEndpoints.first(where: { $0.id == id })
      }
      let endpointName = endpoint?.displayName ?? "OpenAI Compatible"
      return defaults.modelID.isEmpty ? endpointName : "\(endpointName) / \(defaults.modelID)"
    }
  }

  @ViewBuilder
  private var mlxModelControls: some View {
    let modelIDs = store.localMLXModelIDs
    Group {
      if modelIDs.isEmpty {
        Text("No downloaded MLX models")
          .foregroundStyle(.secondary)
      } else {
        Picker("Model", selection: mlxModelBinding) {
          ForEach(modelIDs, id: \.self) { modelID in
            Text(modelID).tag(modelID)
          }
        }
        .pickerStyle(.menu)
      }

      Button {
        store.refreshLocalMLXModels()
        ensureDraftMLXModelSelectionIsAvailable()
      } label: {
        Label("Refresh Models", systemImage: "arrow.clockwise")
      }
    }
  }

  @ViewBuilder
  private var openAICompatibleModelControls: some View {
    if store.settings.airplaneModeEnabled {
      Text("Airplane Mode is on. Choose Apple Intelligence, MLX Local, or App Default.")
        .foregroundStyle(.secondary)
    } else if let endpoint = selectedEndpoint {
      let models = store.endpointModels[endpoint.id] ?? []
      if models.isEmpty {
        TextField("Model", text: endpointModelBinding(default: endpoint.defaultModel))
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
      } else {
        FilteredModelPicker(
          selection: endpointModelBinding(default: endpoint.defaultModel),
          filter: $modelFilter,
          models: models
        )
      }

      HStack {
        endpointStatusLabel(store.endpointStatuses[endpoint.id] ?? .unknown)
        Spacer()
        Button {
          Task { await store.refreshEndpoint(endpoint) }
        } label: {
          Label("Refresh Models", systemImage: "arrow.clockwise")
        }
        .disabled(isChecking(endpoint))
      }
    } else {
      Text("Choose an enabled endpoint.")
        .foregroundStyle(.secondary)
    }
  }

  private var selectedEndpoint: OpenAIEndpoint? {
    guard let endpointID = draft.endpointID else { return nil }
    return store.settings.openAIEndpoints.first { $0.id == endpointID && $0.isEnabled }
  }

  private var canSave: Bool {
    validationMessage == nil
  }

  private var validationMessage: String? {
    switch draft.provider {
    case nil:
      return nil
    case .apple:
      return store.appleIntelligenceIsAvailable ? nil : "Apple Intelligence is unavailable."
    case .mlx:
      return store.localMLXModelIDs.isEmpty ? "Download an MLX model before saving." : nil
    case .openAICompatible:
      if store.settings.airplaneModeEnabled {
        return "Airplane Mode is on. OpenAI-compatible providers cannot be used."
      }
      return selectedEndpoint == nil ? "Choose an enabled endpoint before saving." : nil
    }
  }

  private var defaultsFooterText: String {
    if let validationMessage {
      return validationMessage
    }
    if draft.usesAppDefaults {
      return "New chats in \(folder.displayName) use the app defaults."
    }
    return "New chats in \(folder.displayName) use these folder defaults."
  }

  private var mlxModelBinding: Binding<String> {
    Binding(
      get: {
        store.availableLocalMLXModelID(preferred: draft.modelID) ?? ""
      },
      set: { modelID in
        guard store.localMLXModelIDs.contains(modelID) else { return }
        draft.modelID = modelID
      }
    )
  }

  private func endpointModelBinding(default defaultModel: String) -> Binding<String> {
    Binding(
      get: {
        let modelID = draft.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return modelID.isEmpty ? defaultModel : modelID
      },
      set: { modelID in
        draft.modelID = modelID
      }
    )
  }

  private func selectProvider(_ selection: DefaultProviderSelection?) {
    guard let selection else {
      draft.provider = nil
      draft.endpointID = nil
      draft.modelID = ""
      return
    }

    switch selection {
    case .apple:
      guard store.appleIntelligenceIsAvailable else { return }
      draft.provider = .apple
      draft.endpointID = nil
      draft.modelID = store.settings.appleModelID
    case .mlx:
      store.refreshLocalMLXModels()
      draft.provider = .mlx
      draft.endpointID = nil
      draft.modelID = store.availableLocalMLXModelID(preferred: draft.modelID) ?? ""
    case .endpoint(let id):
      guard !store.settings.airplaneModeEnabled,
        let endpoint = store.settings.openAIEndpoints.first(where: { $0.id == id && $0.isEnabled })
      else { return }
      draft.provider = .openAICompatible
      draft.endpointID = id
      draft.modelID = endpoint.defaultModel
    }
  }

  private func ensureDraftMLXModelSelectionIsAvailable() {
    guard draft.provider == .mlx else { return }
    draft.modelID = store.availableLocalMLXModelID(preferred: draft.modelID) ?? ""
  }

  private func loadDefaultsIfNeeded() {
    guard !didLoad else { return }
    draft = store.conversationFolderDefaults(for: folder.id)
    if let id = draft.systemPromptID,
      !store.settings.systemPrompts.contains(where: { $0.id == id })
    {
      draft.systemPromptID = nil
    }
    ensureDraftMLXModelSelectionIsAvailable()
    didLoad = true
  }

  private func saveAndDismiss() {
    guard canSave else { return }
    store.setConversationFolderDefaults(draft, for: folder.id)
    dismiss()
  }

  private func endpointStatusLabel(_ status: EndpointConnectionState) -> some View {
    let icon = status == .checking ? "arrow.triangle.2.circlepath" : "circle.fill"
    return Label(status.statusText, systemImage: icon)
      .foregroundStyle(status.statusColor)
  }

  private func isChecking(_ endpoint: OpenAIEndpoint) -> Bool {
    if case .checking = store.endpointStatuses[endpoint.id] {
      return true
    }
    return false
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

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content
        .glassEffect(.clear.tint(tint).interactive(), in: shape)
        .overlay(shape.strokeBorder(borderColor, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 3)
    } else {
      content
        .background(fallbackFill, in: shape)
        .overlay(shape.strokeBorder(borderColor, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 3)
    }
  }

  private var borderColor: Color {
    colorScheme == .dark ? .white.opacity(0.08) : .black.opacity(0.08)
  }

  private var fallbackFill: AnyShapeStyle {
    if let tint {
      return AnyShapeStyle(tint.opacity(colorScheme == .dark ? 0.24 : 0.16))
    }
    return AnyShapeStyle(.regularMaterial)
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
