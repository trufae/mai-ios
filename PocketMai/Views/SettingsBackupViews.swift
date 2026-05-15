import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct BackupSharedFile: Identifiable {
  let id = UUID()
  let url: URL
}

private struct BackupActivityShareSheet: UIViewControllerRepresentable {
  let activityItems: [Any]

  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
  }

  func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Import Panel

struct SettingsImportView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss

  @State private var pendingScope: SettingsBackupScope?
  @State private var showingFileImporter = false
  @State private var restoreAudio = false

  @State private var showingConversationImporter = false
  @State private var pendingConversationImport: ConversationImportPreview?

  @State private var toast: String?
  @State private var errorMessage: String?

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $restoreAudio) {
          VStack(alignment: .leading, spacing: 2) {
            Label("Restore voice audio", systemImage: "waveform")
            Text("Write base64-encoded m4a files back to the voice-recordings folder.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      } header: {
        Text("Options")
      }

      Section {
        importRow(
          title: "Everything",
          systemImage: "tray.full",
          description: "Restore providers, prompts, tool settings, and conversations.",
          scope: .everything)
        importRow(
          title: "Provider Settings",
          systemImage: "network",
          description: "Endpoints, API keys, and the default provider.",
          scope: .providers)
        importRow(
          title: "System Prompts",
          systemImage: "text.bubble",
          description: "Replace the prompt library and compact prompt with the backup.",
          scope: .prompts)
        importRow(
          title: "Tool Settings",
          systemImage: "wrench.and.screwdriver",
          description: "Built-in tools, MCP servers, voices, and tool-calling preferences.",
          scope: .tools)
        importRow(
          title: "All Conversations",
          systemImage: "bubble.left.and.bubble.right",
          description: "Add every conversation from a full backup.",
          scope: .conversations)
      } header: {
        Text("From PocketMai Backup")
      } footer: {
        Text(
          "Importing a section replaces it with the contents of the backup file. Conversations are added alongside existing chats."
        )
      }

      Section {
        Button {
          showingConversationImporter = true
        } label: {
          Label("Single Conversation", systemImage: "square.and.arrow.down.on.square")
        }
      } header: {
        Text("Single Conversation")
      } footer: {
        Text("Pick a PocketMai conversation JSON to add or update a single chat.")
      }

      if let errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
        }
      }
    }
    .navigationTitle("Import")
    .navigationBarTitleDisplayMode(.inline)
    .fileImporter(
      isPresented: $showingFileImporter,
      allowedContentTypes: [.json]
    ) { result in
      handleBackupPick(result)
    }
    .fileImporter(
      isPresented: $showingConversationImporter,
      allowedContentTypes: [.json]
    ) { result in
      switch result {
      case .success(let url):
        Task { await prepareConversationImport(from: url) }
      case .failure(let error):
        errorMessage = error.localizedDescription
      }
    }
    .sheet(item: $pendingConversationImport) { preview in
      ConversationImportConfirmationView(
        preview: preview,
        onCancel: {
          pendingConversationImport = nil
        },
        onImportAsNew: { title in
          finishConversationImport(preview, resolution: .create(title: title))
        },
        onUpdateExisting: {
          finishConversationImport(preview, resolution: .updateExisting)
        }
      )
    }
    .settingsToast($toast)
  }

  @ViewBuilder
  private func importRow(
    title: String,
    systemImage: String,
    description: String,
    scope: SettingsBackupScope
  ) -> some View {
    Button {
      errorMessage = nil
      pendingScope = scope
      showingFileImporter = true
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        Label(title, systemImage: systemImage)
          .foregroundStyle(.primary)
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func handleBackupPick(_ result: Result<URL, Error>) {
    guard let scope = pendingScope else { return }
    pendingScope = nil
    switch result {
    case .success(let url):
      do {
        let summary = try store.importSettingsBackup(
          from: url, scope: scope, restoreAudio: restoreAudio)
        showToast(summary)
      } catch {
        errorMessage = error.localizedDescription
      }
    case .failure(let error):
      errorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func prepareConversationImport(from url: URL) async {
    do {
      pendingConversationImport = try await store.previewConversationImport(from: url)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func finishConversationImport(
    _ preview: ConversationImportPreview,
    resolution: ConversationImportResolution
  ) -> String? {
    do {
      try store.importConversation(preview, resolution: resolution)
      pendingConversationImport = nil
      showToast("Imported conversation.")
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  private func showToast(_ message: String) {
    withAnimation(.snappy) {
      toast = message
    }
  }
}

// MARK: - Export Panel

struct SettingsExportView: View {
  @EnvironmentObject private var store: AppStore

  @State private var shareFile: BackupSharedFile?
  @State private var errorMessage: String?
  @State private var includeAudio = false

  var body: some View {
    Form {
      Section {
        Toggle(isOn: $includeAudio) {
          VStack(alignment: .leading, spacing: 2) {
            Label("Include voice audio", systemImage: "waveform")
            Text(
              "Embed m4a recordings as base64. Disabled by default because audio inflates the file."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
      } header: {
        Text("Options")
      }

      Section {
        exportRow(
          title: "Everything",
          systemImage: "tray.full",
          description: "Providers, prompts, tool settings, and conversations.",
          scope: .everything)
        exportRow(
          title: "Provider Settings",
          systemImage: "network",
          description: "Endpoints, API keys, and the default provider.",
          scope: .providers)
        exportRow(
          title: "System Prompts",
          systemImage: "text.bubble",
          description: "The prompt library, default prompt, and compact prompt.",
          scope: .prompts)
        exportRow(
          title: "Tool Settings",
          systemImage: "wrench.and.screwdriver",
          description: "Built-in tools, MCP servers, voices, and tool-calling preferences.",
          scope: .tools)
        exportRow(
          title: "All Conversations",
          systemImage: "bubble.left.and.bubble.right",
          description: "Every chat on this device.",
          scope: .conversations)
      } header: {
        Text("Save to File")
      } footer: {
        Text(
          "Exports a PocketMai JSON backup you can save or send to another device. Provider exports include API keys; treat the file like a secret."
        )
      }

      if let errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
        }
      }
    }
    .navigationTitle("Export")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(item: $shareFile) { file in
      BackupActivityShareSheet(activityItems: [file.url])
    }
  }

  @ViewBuilder
  private func exportRow(
    title: String,
    systemImage: String,
    description: String,
    scope: SettingsBackupScope
  ) -> some View {
    Button {
      errorMessage = nil
      if let url = store.exportSettingsBackupFile(scope: scope, includeAudio: includeAudio) {
        shareFile = BackupSharedFile(url: url)
      } else {
        errorMessage = store.errorMessage ?? "Could not export."
      }
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        Label(title, systemImage: systemImage)
          .foregroundStyle(.primary)
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

// MARK: - Destroy Panel

private enum DestroyAction: Identifiable {
  case conversations
  case memory
  case downloadedModels
  case filesWorkspace
  case providers
  case prompts
  case toolSettings
  case mcpServers
  case factoryReset

  var id: String {
    switch self {
    case .conversations: "conversations"
    case .memory: "memory"
    case .downloadedModels: "downloadedModels"
    case .filesWorkspace: "filesWorkspace"
    case .providers: "providers"
    case .prompts: "prompts"
    case .toolSettings: "toolSettings"
    case .mcpServers: "mcpServers"
    case .factoryReset: "factoryReset"
    }
  }

  var title: String {
    switch self {
    case .conversations: "Clear all conversations?"
    case .memory: "Clear memory?"
    case .downloadedModels: "Clear downloaded models?"
    case .filesWorkspace: "Clear files workspace?"
    case .providers: "Clear provider settings?"
    case .prompts: "Reset system prompts?"
    case .toolSettings: "Reset tool settings?"
    case .mcpServers: "Remove all MCP servers?"
    case .factoryReset: "Factory reset PocketMai?"
    }
  }

  var confirmButtonTitle: String {
    switch self {
    case .conversations: "Clear Conversations"
    case .memory: "Clear Memory"
    case .downloadedModels: "Delete Models"
    case .filesWorkspace: "Clear Files"
    case .providers: "Clear Providers"
    case .prompts: "Reset Prompts"
    case .toolSettings: "Reset Tools"
    case .mcpServers: "Remove Servers"
    case .factoryReset: "Factory Reset"
    }
  }

  var message: String {
    switch self {
    case .conversations:
      return "Every chat and its messages will be deleted. This cannot be undone."
    case .memory:
      return "Saved memory will be removed from this device. This cannot be undone."
    case .downloadedModels:
      return
        "All locally downloaded MLX models will be deleted. They can be re-downloaded later."
    case .filesWorkspace:
      return "Every file in the workspace (FilesData) will be deleted. This cannot be undone."
    case .providers:
      return
        "All OpenAI-compatible endpoints and their stored API keys will be removed from this device."
    case .prompts:
      return "Custom system prompts will be removed and the compact prompt restored to default."
    case .toolSettings:
      return
        "Tool settings, voices, todos, imported tool files, and tool-calling preferences will be reset to defaults."
    case .mcpServers:
      return "All configured MCP servers and their tool selections will be removed."
    case .factoryReset:
      return
        "All conversations, settings, providers, API keys, memory, tools, and local app data will be removed from this device. This cannot be undone."
    }
  }
}

struct SettingsDestroyView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss

  let dismissSettings: () -> Void

  @State private var pendingAction: DestroyAction?
  @State private var toast: String?

  var body: some View {
    Form {
      Section {
        destroyRow(
          title: "Conversations",
          systemImage: "bubble.left.and.bubble.right",
          description: "Delete every chat on this device (archived chats are kept).",
          action: .conversations)
        destroyRow(
          title: "Memory",
          systemImage: "brain",
          description: "Remove the saved long-term memory.",
          action: .memory)
        destroyRow(
          title: "Downloaded Models",
          systemImage: "arrow.down.circle",
          description: "Delete locally downloaded MLX models from the cache.",
          action: .downloadedModels)
        destroyRow(
          title: "Files Workspace",
          systemImage: "folder",
          description: "Erase everything in the FilesData workspace.",
          action: .filesWorkspace)
      } header: {
        Text("Clear Data")
      }

      Section {
        destroyRow(
          title: "Provider Settings",
          systemImage: "network",
          description: "Remove all endpoints and their stored API keys.",
          action: .providers)
        destroyRow(
          title: "System Prompts",
          systemImage: "text.bubble",
          description: "Restore the default prompt and drop the rest.",
          action: .prompts)
        destroyRow(
          title: "Tool Settings",
          systemImage: "wrench.and.screwdriver",
          description: "Reset built-in tools, voices, todos, and tool-calling preferences.",
          action: .toolSettings)
        destroyRow(
          title: "MCP Servers",
          systemImage: "server.rack",
          description: "Remove every configured MCP server.",
          action: .mcpServers)
      } header: {
        Text("Reset Settings")
      }

      Section {
        destroyRow(
          title: "Factory Reset",
          systemImage: "arrow.counterclockwise.circle",
          description: "Wipe every local file: conversations, settings, models, and workspace.",
          action: .factoryReset,
          tint: .red)
      } header: {
        Text("Nuclear Option")
      } footer: {
        Text("Each destructive action shows a confirmation prompt before it runs.")
      }
    }
    .navigationTitle("Destroy")
    .navigationBarTitleDisplayMode(.inline)
    .alert(
      pendingAction?.title ?? "Are you sure?",
      isPresented: pendingActionBinding,
      presenting: pendingAction
    ) { action in
      Button("Cancel", role: .cancel) {
        pendingAction = nil
      }
      Button(action.confirmButtonTitle, role: .destructive) {
        perform(action)
      }
    } message: { action in
      Text(action.message)
    }
    .settingsToast($toast)
  }

  private var pendingActionBinding: Binding<Bool> {
    Binding(
      get: { pendingAction != nil },
      set: { isPresented in
        if !isPresented { pendingAction = nil }
      })
  }

  @ViewBuilder
  private func destroyRow(
    title: String,
    systemImage: String,
    description: String,
    action: DestroyAction,
    tint: Color = .primary
  ) -> some View {
    Button {
      pendingAction = action
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        Label(title, systemImage: systemImage)
          .foregroundStyle(tint)
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func perform(_ action: DestroyAction) {
    pendingAction = nil
    switch action {
    case .conversations:
      store.clearAllConversations()
      showToast("Conversations cleared.")
    case .memory:
      store.clearMemory()
      showToast("Memory cleared.")
    case .downloadedModels:
      let summary = store.clearDownloadedMLXModels()
      showToast(summary)
    case .filesWorkspace:
      let summary = store.clearFilesWorkspace()
      showToast(summary)
    case .providers:
      store.clearProviderSettings()
      showToast("Providers cleared.")
    case .prompts:
      store.clearSystemPrompts()
      showToast("System prompts reset.")
    case .toolSettings:
      store.clearToolSettings()
      showToast("Tool settings reset.")
    case .mcpServers:
      store.clearMCPServers()
      showToast("MCP servers cleared.")
    case .factoryReset:
      store.factoryReset()
      dismissSettings()
    }
  }

  private func showToast(_ message: String) {
    withAnimation(.snappy) {
      toast = message
    }
  }
}
