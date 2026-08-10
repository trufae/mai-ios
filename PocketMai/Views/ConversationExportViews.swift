import SwiftUI
import UIKit

struct ExportedFile: Identifiable {
  let id = UUID()
  let url: URL
}

struct PendingEPUBExportImageSizeSelection: Identifiable {
  let id = UUID()
  let conversationID: UUID
}

@MainActor
final class ConversationExportCoordinator: ObservableObject {
  @Published var exportShareFile: ExportedFile?
  @Published var pendingEPUBImageSizeSelection: PendingEPUBExportImageSizeSelection?
  @Published var showingAudioExport = false
  @Published var audioExportError: String?

  let audioExporter = TTSExporter()

  var isExporting: Bool {
    audioExporter.isExporting
  }

  func share(
    format: ConversationExportFormat,
    conversationID: UUID,
    store: AppStore,
    epubImageSize: AttachmentImageSize = .full
  ) async {
    guard
      let url = await exportFileURL(
        for: format,
        conversationID: conversationID,
        store: store,
        epubImageSize: epubImageSize)
    else {
      return
    }
    exportShareFile = ExportedFile(url: url)
  }

  func shareEPUB(conversationID: UUID, store: AppStore) {
    Task { @MainActor in
      guard let conversation = await store.conversationForExport(id: conversationID) else {
        return
      }
      guard Self.containsImageAttachments(conversation) else {
        await share(format: .epub, conversationID: conversationID, store: store, epubImageSize: .full)
        return
      }
      pendingEPUBImageSizeSelection = PendingEPUBExportImageSizeSelection(
        conversationID: conversationID)
    }
  }

  private func exportFileURL(
    for format: ConversationExportFormat,
    conversationID: UUID,
    store: AppStore,
    epubImageSize: AttachmentImageSize
  ) async -> URL? {
    switch format {
    case .audio:
      guard let conversation = await store.conversationForExport(id: conversationID) else {
        return nil
      }
      return await exportAudioFile(conversation: conversation, store: store)
    case .debug:
      return await store.exportConversationDebugJSONFile(id: conversationID)
    case .markdown, .json:
      return await store.exportConversationFile(id: conversationID, format: format)
    case .epub:
      return await store.exportConversationFile(
        id: conversationID,
        format: format,
        epubImageSize: epubImageSize)
    }
  }

  private func exportAudioFile(conversation: Conversation, store: AppStore) async -> URL? {
    showingAudioExport = true
    do {
      let url = try ConversationExportFiles.url(for: conversation, format: .audio)
      try await audioExporter.export(
        messages: conversation.messages,
        voices: store.effectiveToolSettings(for: conversation).voices,
        skipTechnicalContent: store.settings.conversation.skipTechnicalContentInTTS,
        to: url)
      showingAudioExport = false
      try? await Task.sleep(for: .milliseconds(250))
      return url
    } catch is CancellationError {
      showingAudioExport = false
      return nil
    } catch {
      showingAudioExport = false
      audioExportError =
        (error as? LocalizedError)?.errorDescription
        ?? error.localizedDescription
      return nil
    }
  }

  private static func containsImageAttachments(_ conversation: Conversation) -> Bool {
    conversation.messages.contains { message in
      message.attachments.contains { $0.kind == .image }
    }
  }
}

struct ConversationExportMenu: View {
  @EnvironmentObject private var store: AppStore

  let conversationID: UUID?
  @ObservedObject var coordinator: ConversationExportCoordinator

  var body: some View {
    Menu {
      ConversationExportMenuItems(isExporting: coordinator.isExporting) { format in
        guard let conversationID else { return }
        if format == .epub {
          coordinator.shareEPUB(conversationID: conversationID, store: store)
          return
        }
        Task {
          await coordinator.share(format: format, conversationID: conversationID, store: store)
        }
      }
    } label: {
      Label("Export", systemImage: "square.and.arrow.up")
    }
    .disabled(conversationID == nil || coordinator.isExporting)
  }
}

private struct ConversationExportMenuItems: View {
  let isExporting: Bool
  let onSelect: (ConversationExportFormat) -> Void

  var body: some View {
    Section("Share") {
      ForEach(ConversationExportFormat.shareMenuFormats) { format in
        exportButton(format)
      }
    }
    Section("Data") {
      ForEach(ConversationExportFormat.dataMenuFormats) { format in
        exportButton(format)
      }
    }
  }

  private func exportButton(_ format: ConversationExportFormat) -> some View {
    Button {
      onSelect(format)
    } label: {
      Label(format.exportMenuTitle, systemImage: format.systemImage)
    }
    .disabled(isExporting)
  }
}

struct ConversationExportPresentations: ViewModifier {
  @EnvironmentObject private var store: AppStore
  @ObservedObject var coordinator: ConversationExportCoordinator

  func body(content: Content) -> some View {
    content
      .sheet(item: exportShareFileBinding) { file in
        ActivityShareSheet(activityItems: [file.url])
      }
      .sheet(isPresented: showingAudioExportBinding) {
        AudioExportProgressView(exporter: coordinator.audioExporter) {
          coordinator.audioExporter.cancel()
        }
      }
      .alert(
        "Audio export failed",
        isPresented: audioExportErrorPresentedBinding,
        presenting: coordinator.audioExportError
      ) { _ in
        Button("OK", role: .cancel) { coordinator.audioExportError = nil }
      } message: { message in
        Text(message)
      }
      .imageSizeConfirmationDialog(
        isPresented: epubImageSizeSelectionPresentedBinding,
        presenting: coordinator.pendingEPUBImageSizeSelection,
        message: { _ in
          "Choose the maximum image size for this EPUB."
        },
        onSelect: { pending, size in
          coordinator.pendingEPUBImageSizeSelection = nil
          Task {
            await coordinator.share(
              format: .epub,
              conversationID: pending.conversationID,
              store: store,
              epubImageSize: size)
          }
        },
        onCancel: {
          coordinator.pendingEPUBImageSizeSelection = nil
        })
  }

  private var exportShareFileBinding: Binding<ExportedFile?> {
    Binding {
      coordinator.exportShareFile
    } set: { file in
      coordinator.exportShareFile = file
    }
  }

  private var showingAudioExportBinding: Binding<Bool> {
    Binding {
      coordinator.showingAudioExport
    } set: { isPresented in
      coordinator.showingAudioExport = isPresented
    }
  }

  private var audioExportErrorPresentedBinding: Binding<Bool> {
    Binding {
      coordinator.audioExportError != nil
    } set: { isPresented in
      if !isPresented {
        coordinator.audioExportError = nil
      }
    }
  }

  private var epubImageSizeSelectionPresentedBinding: Binding<Bool> {
    Binding {
      coordinator.pendingEPUBImageSizeSelection != nil
    } set: { isPresented in
      if !isPresented {
        coordinator.pendingEPUBImageSizeSelection = nil
      }
    }
  }
}

extension View {
  func imageSizeConfirmationDialog<Selection>(
    isPresented: Binding<Bool>,
    presenting selection: Selection?,
    message: @escaping (Selection) -> String,
    onSelect: @escaping (Selection, AttachmentImageSize) -> Void,
    onCancel: @escaping () -> Void
  ) -> some View {
    confirmationDialog(
      "Image Size",
      isPresented: isPresented,
      titleVisibility: .visible,
      presenting: selection
    ) { selection in
      ForEach(AttachmentImageSize.concreteCases) { size in
        Button(size.imageSizeDialogTitle) {
          onSelect(selection, size)
        }
      }
      Button("Cancel", role: .cancel, action: onCancel)
    } message: { selection in
      Text(message(selection))
    }
  }
}

extension AttachmentImageSize {
  var imageSizeDialogTitle: String {
    guard let maxDimension else {
      return displayName
    }
    return "\(displayName) (\(maxDimension) px)"
  }
}

private struct AudioExportProgressView: View {
  @ObservedObject var exporter: TTSExporter
  let onCancel: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "waveform")
        .font(.system(size: 32))
        .foregroundStyle(.secondary)
      ProgressView(value: exporter.progress)
        .progressViewStyle(.linear)
      Text(exporter.phase)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Button("Cancel", role: .cancel, action: onCancel)
    }
    .padding(24)
    .frame(maxWidth: .infinity)
    .presentationDetents([.height(220)])
    .interactiveDismissDisabled()
  }
}

struct ActivityShareSheet: UIViewControllerRepresentable {
  let activityItems: [Any]

  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
  }

  func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private extension ConversationExportFormat {
  static var shareMenuFormats: [ConversationExportFormat] {
    [.markdown, .epub, .audio]
  }

  static var dataMenuFormats: [ConversationExportFormat] {
    [.json, .debug]
  }

  var exportMenuTitle: String {
    switch self {
    case .markdown: "Markdown (.md)"
    case .epub: "EPUB (.epub)"
    case .audio: "Audio (.m4a)"
    case .json: "JSON Archive"
    case .debug: "Debug JSON"
    }
  }
}
