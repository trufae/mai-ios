import SwiftUI
import Photos
import UIKit

private struct FullChatScreenshotRenderingKey: EnvironmentKey {
  static let defaultValue = false
}

private struct MarkdownRenderImagesKey: EnvironmentKey {
  static let defaultValue = true
}

extension EnvironmentValues {
  var isFullChatScreenshotRendering: Bool {
    get { self[FullChatScreenshotRenderingKey.self] }
    set { self[FullChatScreenshotRenderingKey.self] = newValue }
  }

  var markdownRenderImages: Bool {
    get { self[MarkdownRenderImagesKey.self] }
    set { self[MarkdownRenderImagesKey.self] = newValue }
  }
}

struct MessageBubble: View {
  @EnvironmentObject private var streamingTextStore: StreamingTextStore

  let message: ChatMessage
  let toolSettings: NativeToolSettings
  let openAIEndpoints: [OpenAIEndpoint]
  var skipTechnicalContentInTTS: Bool = true
  let appearance: AppearanceSettings
  var renderMarkdown: Bool = true
  var renderImages: Bool = true
  let onDelete: () -> Void
  var onEdit: ((String) -> Void)? = nil
  var onResubmit: (() -> Void)? = nil
  var onTrimFromHere: (() -> Void)? = nil
  var onRestartFresh: (() -> Void)? = nil
  var onNewChatWithMessage: (() -> Void)? = nil
  var onSpeakFromHere: (() -> Void)? = nil
  var showThinking: Bool = false
  var isWaitingForResponse: Bool = false
  var onStreamingTextChange: ((String) -> Void)? = nil

  var body: some View {
    StreamingMessageBubble(
      message: message,
      streamingText: streamingTextStore.textObject(for: message.id),
      toolSettings: toolSettings,
      openAIEndpoints: openAIEndpoints,
      skipTechnicalContentInTTS: skipTechnicalContentInTTS,
      appearance: appearance,
      renderMarkdown: renderMarkdown,
      renderImages: renderImages,
      onDelete: onDelete,
      onEdit: onEdit,
      onResubmit: onResubmit,
      onTrimFromHere: onTrimFromHere,
      onRestartFresh: onRestartFresh,
      onNewChatWithMessage: onNewChatWithMessage,
      onSpeakFromHere: onSpeakFromHere,
      showThinking: showThinking,
      isWaitingForResponse: isWaitingForResponse,
      onStreamingTextChange: onStreamingTextChange
    )
  }
}

private struct StreamingMessageBubble: View {
  let message: ChatMessage
  @ObservedObject var streamingText: StreamingText
  let toolSettings: NativeToolSettings
  let openAIEndpoints: [OpenAIEndpoint]
  var skipTechnicalContentInTTS: Bool = true
  let appearance: AppearanceSettings
  var renderMarkdown: Bool = true
  var renderImages: Bool = true
  let onDelete: () -> Void
  var onEdit: ((String) -> Void)? = nil
  var onResubmit: (() -> Void)? = nil
  var onTrimFromHere: (() -> Void)? = nil
  var onRestartFresh: (() -> Void)? = nil
  var onNewChatWithMessage: (() -> Void)? = nil
  var onSpeakFromHere: (() -> Void)? = nil
  var showThinking: Bool = false
  var isWaitingForResponse: Bool = false
  var onStreamingTextChange: ((String) -> Void)? = nil

  var body: some View {
    MessageBubbleContent(
      message: message,
      streamingOverride: streamingText.text,
      toolSettings: toolSettings,
      openAIEndpoints: openAIEndpoints,
      skipTechnicalContentInTTS: skipTechnicalContentInTTS,
      appearance: appearance,
      renderMarkdown: renderMarkdown,
      renderImages: renderImages,
      onDelete: onDelete,
      onEdit: onEdit,
      onResubmit: onResubmit,
      onTrimFromHere: onTrimFromHere,
      onRestartFresh: onRestartFresh,
      onNewChatWithMessage: onNewChatWithMessage,
      onSpeakFromHere: onSpeakFromHere,
      showThinking: showThinking,
      isWaitingForResponse: isWaitingForResponse
    )
    .equatable()
    .onChange(of: streamingText.text) { _, newText in
      guard let newText else { return }
      onStreamingTextChange?(newText)
    }
  }
}

private struct MessageBubbleContent: View, Equatable {
  let message: ChatMessage
  var streamingOverride: String? = nil
  let toolSettings: NativeToolSettings
  let openAIEndpoints: [OpenAIEndpoint]
  var skipTechnicalContentInTTS: Bool = true
  let appearance: AppearanceSettings
  var renderMarkdown: Bool = true
  var renderImages: Bool = true
  let onDelete: () -> Void
  var onEdit: ((String) -> Void)? = nil
  var onResubmit: (() -> Void)? = nil
  var onTrimFromHere: (() -> Void)? = nil
  var onRestartFresh: (() -> Void)? = nil
  var onNewChatWithMessage: (() -> Void)? = nil
  var onSpeakFromHere: (() -> Void)? = nil
  var showThinking: Bool = false
  var isWaitingForResponse: Bool = false
  @State private var showingTextSelection = false
  @State private var selectedTextAttachment: ChatAttachment?
  @State private var selectedImageAttachment: ChatAttachment?
  @State private var imageSaveError: String?

  private var isUser: Bool { message.role == .user }
  private var displayText: String { streamingOverride ?? message.text }
  private var isStreaming: Bool { streamingOverride != nil }
  private var isLiveAssistantResponse: Bool {
    message.role == .assistant && (isWaitingForResponse || isStreaming)
  }

  /// Identity for SwiftUI's EquatableView: skip body re-evaluation when neither
  /// the canonical message nor the streaming override has changed. Closure
  /// equality is irrelevant because actions are invoked only from fresh menus.
  nonisolated static func == (lhs: MessageBubbleContent, rhs: MessageBubbleContent) -> Bool {
    lhs.message == rhs.message && lhs.streamingOverride == rhs.streamingOverride
      && lhs.toolSettings == rhs.toolSettings
      && lhs.openAIEndpoints == rhs.openAIEndpoints
      && lhs.skipTechnicalContentInTTS == rhs.skipTechnicalContentInTTS
      && lhs.appearance == rhs.appearance
      && lhs.renderMarkdown == rhs.renderMarkdown
      && lhs.renderImages == rhs.renderImages
      && lhs.showThinking == rhs.showThinking
      && lhs.isWaitingForResponse == rhs.isWaitingForResponse
  }

  var body: some View {
    let prepared = MessageRenderCache.preparedContent(
      messageID: message.id,
      text: displayText
    )
    let canRenderMarkdown = renderMarkdown && (!isStreaming || appearance.liveMarkdown)
    let usesMarkdown =
      canRenderMarkdown
      && (appearance.justifyText || MarkdownParser.mayContainMarkdown(prepared.visibleText))
    let markdownBlocks =
      !usesMarkdown || prepared.visibleText.isEmpty
      ? []
      : MessageRenderCache.markdownBlocks(
        messageID: message.id,
        text: prepared.visibleText
      )

    VStack(alignment: .leading, spacing: 6) {
      ForEach(prepared.toolEntries) { entry in
        ToolCallRow(entry: entry)
      }
      ForEach(prepared.reasoningSections) { section in
        FoldableMetaSection(
          title: "Reasoning",
          systemImage: "brain",
          content: isStreaming ? Self.tailWindow(section.content) : section.content,
          monospaced: false,
          dimmedContent: true,
          initiallyExpanded: showThinking,
          italicContent: true,
          markdownAppearance: canRenderMarkdown ? appearance : nil,
          renderImages: renderImages
        )
      }
      ForEach(prepared.transcriptSections) { section in
        FoldableMetaSection(
          title: "Prompt Transcript",
          systemImage: "text.bubble",
          content: section.content,
          monospaced: true,
          initiallyExpanded: false
        )
      }
      if !prepared.hideBubble {
        bubble(
          visibleText: prepared.visibleText,
          rawText: displayText,
          markdownBlocks: markdownBlocks,
          usesMarkdown: usesMarkdown
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(maxWidth: 720, alignment: .leading)
    .padding(.leading, isUser ? 36 : 0)
    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
  }

  @ViewBuilder
  private func bubble(
    visibleText: String,
    rawText: String,
    markdownBlocks: [MarkdownBlock],
    usesMarkdown: Bool
  )
    -> some View
  {
    let messageFont = appearance.swiftUIFont(for: message.role)
    let messageFontFamily = appearance.fontFamily(for: message.role)
    let bubbleView = VStack(alignment: .leading, spacing: 8) {
      if showsSenderHeader {
        HStack(spacing: 6) {
          Image(systemName: iconName)
            .foregroundStyle(iconColor)
          Text(message.role.displayName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
      }
      if hasVoiceRecording {
        VoiceRecordingPlaybackButton(message: message)
      }
      ForEach(textAttachments) { attachment in
        MessageAttachmentRow(attachment: attachment) {
          if attachment.kind == .textFile {
            selectedTextAttachment = attachment
          }
        }
      }
      if visibleText.isEmpty {
        if isLiveAssistantResponse {
          AssistantTypingIndicator(fontSize: appearance.fontSize)
        } else if !hasDisplayedAttachmentContent {
          Text("...")
            .font(messageFont)
            .foregroundStyle(.secondary)
        }
      } else if usesMarkdown {
        MarkdownContentView(
          blocks: markdownBlocks,
          appearance: appearance,
          fontFamily: messageFontFamily,
          allowsTextSelection: false,
          renderImages: renderImages
        )
        .fixedSize(horizontal: false, vertical: true)
      } else {
        Text(visibleText)
          .font(messageFont)
          .lineSpacing(CGFloat(appearance.lineSpacing))
          .fixedSize(horizontal: false, vertical: true)
      }
      ForEach(imageAttachments) { attachment in
        MessageImageAttachmentView(
          attachment: attachment,
          onOpen: { selectedImageAttachment = attachment },
          onSave: { saveImageAttachment(attachment) }
        )
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(backgroundStyle)
    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

    let bubbleWithSheet =
      bubbleView
      .sheet(isPresented: $showingTextSelection) {
        MessageTextSelectionSheet(
          title: onEdit == nil ? message.role.displayName : "Edit Message",
          text: onEdit == nil ? visibleText : rawText,
          initialFontSize: appearance.fontSize,
          initialLineSpacing: appearance.lineSpacing,
          fontFamily: appearance.fontFamily(for: message.role),
          isEditable: onEdit != nil,
          onSave: onEdit)
      }
      .sheet(item: $selectedTextAttachment) { attachment in
        MessageTextSelectionSheet(
          title: attachment.displayName,
          text: attachment.text ?? "",
          initialFontSize: appearance.fontSize,
          initialLineSpacing: appearance.lineSpacing,
          fontFamily: appearance.fontFamily(for: message.role))
      }
      .fullScreenCover(item: $selectedImageAttachment) { attachment in
        if let image = MessageAttachmentImage.uiImage(from: attachment) {
          MessageImageFullscreenView(attachment: attachment, image: image)
        }
      }
      .alert(
        "Could not save image",
        isPresented: Binding(
          get: { imageSaveError != nil },
          set: { if !$0 { imageSaveError = nil } }),
        presenting: imageSaveError
      ) { _ in
        Button("OK", role: .cancel) { imageSaveError = nil }
      } message: { message in
        Text(message)
      }
    if !isLiveAssistantResponse {
      bubbleWithSheet
        .contextMenu {
          messageContextMenu(visibleText: visibleText, rawText: rawText)
        } preview: {
          Color.clear
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
        }
    } else {
      bubbleWithSheet
    }
  }

  @ViewBuilder
  private func messageContextMenu(visibleText: String, rawText: String) -> some View {
    ForEach(Array(imageAttachments.enumerated()), id: \.element.id) { index, attachment in
      Button {
        saveImageAttachment(attachment)
      } label: {
        Label(imageSaveMenuTitle(at: index), systemImage: "square.and.arrow.down")
      }
    }
    if !imageAttachments.isEmpty {
      Divider()
    }

    Button {
      showingTextSelection = true
    } label: {
      Label(
        onEdit == nil ? "View Text" : "Edit Message",
        systemImage: onEdit == nil ? "text.cursor" : "square.and.pencil")
    }
    Button {
      UIPasteboard.general.string = visibleText
    } label: {
      Label("Copy Message", systemImage: "doc.on.doc")
    }
    Button {
      UIPasteboard.general.string = rawText
    } label: {
      Label("Copy Raw Message", systemImage: "doc.text")
    }
    Button {
      _ = TextToSpeechTool.speak(
        arguments: ["text": .string(visibleText)],
        settings: toolSettings,
        skipTechnicalContent: skipTechnicalContentInTTS,
        openAIEndpoints: openAIEndpoints,
        role: message.role == .user ? .user : .assistant,
        title: message.role.displayName,
        messageID: message.id)
    } label: {
      Label("Speak Message", systemImage: "speaker.wave.2")
    }

    if let onSpeakFromHere {
      Button(action: onSpeakFromHere) {
        Label("Speak From Here", systemImage: "speaker.wave.2.fill")
      }
    }

    if message.role != .assistant {
      if let resend = onTrimFromHere ?? (isUser ? onResubmit : nil) {
        Button(action: resend) {
          Label("Retry From Here", systemImage: "arrow.clockwise")
        }
      }
      if let onRestartFresh {
        Button(action: onRestartFresh) {
          Label("Restart From Here", systemImage: "arrow.triangle.2.circlepath")
        }
      }
      if let onNewChatWithMessage {
        Button(action: onNewChatWithMessage) {
          Label("New Chat With This", systemImage: "bubble.left.and.bubble.right")
        }
      }
    }

    Button(role: .destructive, action: onDelete) {
      Label("Delete Message", systemImage: "trash")
    }
  }

  private var textAttachments: [ChatAttachment] {
    message.attachments.filter { $0.kind == .textFile }
  }

  private var imageAttachments: [ChatAttachment] {
    message.attachments.filter { $0.kind == .image }
  }

  private var hasDisplayedAttachmentContent: Bool {
    hasVoiceRecording || !message.attachments.isEmpty
  }

  private func imageSaveMenuTitle(at index: Int) -> String {
    imageAttachments.count == 1 ? "Save Image" : "Save Image \(index + 1)"
  }

  private func saveImageAttachment(_ attachment: ChatAttachment) {
    Task {
      do {
        try await MessageAttachmentImage.saveToPhotoLibrary(attachment)
      } catch {
        await MainActor.run {
          imageSaveError =
            (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
      }
    }
  }

  private var iconName: String {
    switch message.role {
    case .user: "person.crop.circle"
    case .assistant: "sparkles"
    case .system: "gearshape"
    case .tool: "wrench.and.screwdriver"
    case .error: "exclamationmark.triangle"
    }
  }

  private var showsSenderHeader: Bool {
    switch message.role {
    case .user, .assistant:
      false
    case .system, .tool, .error:
      true
    }
  }

  private var iconColor: Color {
    message.role == .error ? .red : .accentColor
  }

  private var hasVoiceRecording: Bool {
    guard isUser, let filename = message.voiceRecordingFilename,
      let url = PocketMaiDirectories.voiceRecordingURL(filename: filename)
    else {
      return false
    }
    return FileManager.default.fileExists(atPath: url.path)
  }

  private var backgroundStyle: some ShapeStyle {
    if message.role == .error {
      return AnyShapeStyle(.red.opacity(0.14))
    }
    if isUser {
      return AnyShapeStyle(Color.accentColor.opacity(0.22))
    }
    if message.role == .assistant && !appearance.solidResponseBubbles {
      return AnyShapeStyle(Color.clear)
    }
    return AnyShapeStyle(.regularMaterial)
  }

  private static let streamingReasoningTail = 1500

  /// While a message is still streaming, the reasoning section keeps growing
  /// and SwiftUI re-lays out the entire `Text` block on every token tick — at
  /// 5-10 KB that dominates the main thread. Showing only the trailing window
  /// caps layout cost at O(streamingReasoningTail) per update; the full text
  /// is rendered once the stream finalizes.
  private static func tailWindow(_ text: String) -> String {
    guard
      let start = text.index(
        text.endIndex, offsetBy: -streamingReasoningTail, limitedBy: text.startIndex
      )
    else {
      return text
    }
    return "…" + text[start...]
  }
}

private struct MessageAttachmentRow: View {
  let attachment: ChatAttachment
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: 10) {
        preview
        VStack(alignment: .leading, spacing: 2) {
          Text(attachment.displayName)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(Color(uiColor: .secondarySystemBackground).opacity(0.72))
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(attachment.kind != .textFile)
  }

  @ViewBuilder
  private var preview: some View {
    if attachment.kind == .image,
      let dataBase64 = attachment.dataBase64,
      let data = Data(base64Encoded: dataBase64),
      let uiImage = UIImage(data: data)
    {
      Image(uiImage: uiImage)
        .resizable()
        .scaledToFill()
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    } else {
      Image(systemName: attachment.kind == .image ? "photo" : "doc.text")
        .font(.title3)
        .foregroundStyle(Color.accentColor)
        .frame(width: 34, height: 34)
        .background(Color.accentColor.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
  }

  private var subtitle: String {
    switch attachment.kind {
    case .textFile:
      let count = attachment.text?.count ?? 0
      return "\(count) character\(count == 1 ? "" : "s")"
    case .image:
      if let width = attachment.width, let height = attachment.height {
        return "\(width)x\(height)"
      }
      return "Image"
    }
  }
}

private struct MessageImageAttachmentView: View {
  @Environment(\.displayScale) private var displayScale

  let attachment: ChatAttachment
  let onOpen: () -> Void
  let onSave: () -> Void

  var body: some View {
    if let uiImage = MessageAttachmentImage.uiImage(from: attachment) {
      let preview = previewMetrics(for: uiImage)
      Button(action: onOpen) {
        Image(uiImage: uiImage)
          .resizable()
          .interpolation(.high)
          .aspectRatio(uiImage.size, contentMode: .fit)
          .frame(
            maxWidth: preview.size.width,
            maxHeight: preview.size.height,
            alignment: .center
          )
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
          .overlay(alignment: .bottomTrailing) {
            Text(dimensionsLabel(for: uiImage))
              .font(.system(size: 9, weight: .semibold, design: .monospaced))
              .foregroundStyle(.white)
              .lineLimit(1)
              .minimumScaleFactor(0.7)
              .padding(.horizontal, 5)
              .padding(.vertical, 3)
              .background(.black.opacity(0.58), in: Capsule())
              .padding(5)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Attached image")
      .contextMenu {
        Button(action: onSave) {
          Label("Save Image", systemImage: "square.and.arrow.down")
        }
      }
    } else {
      Image(systemName: "photo")
        .font(.title2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel("Image unavailable")
    }
  }

  private func dimensionsLabel(for image: UIImage) -> String {
    let width = attachment.width ?? Int((image.size.width * image.scale).rounded())
    let height = attachment.height ?? Int((image.size.height * image.scale).rounded())
    return "\(width)x\(height)"
  }

  private func nativeDisplaySize(for image: UIImage) -> CGSize {
    let width = CGFloat(attachment.width ?? Int((image.size.width * image.scale).rounded()))
    let height = CGFloat(attachment.height ?? Int((image.size.height * image.scale).rounded()))
    let scale = max(displayScale, 1)
    return CGSize(width: max(1, width / scale), height: max(1, height / scale))
  }

  private func previewMetrics(for image: UIImage) -> (size: CGSize, isUpscaled: Bool) {
    let nativeSize = nativeDisplaySize(for: image)
    let longEdge = max(nativeSize.width, nativeSize.height)
    let shortEdge = min(nativeSize.width, nativeSize.height)
    guard longEdge > 0, shortEdge > 0 else {
      return (CGSize(width: 1, height: 1), false)
    }

    let minimumLongEdge: CGFloat = 180
    let minimumShortEdge: CGFloat = 72
    let maximumLongEdge: CGFloat = 420
    let maximumHeight: CGFloat = 380

    var scale: CGFloat = 1
    if longEdge < minimumLongEdge {
      scale = max(scale, minimumLongEdge / longEdge)
    }
    if shortEdge * scale < minimumShortEdge {
      scale = max(scale, minimumShortEdge / shortEdge)
    }
    scale = min(scale, maximumLongEdge / longEdge)

    var size = CGSize(width: nativeSize.width * scale, height: nativeSize.height * scale)
    if size.height > maximumHeight {
      let heightScale = maximumHeight / size.height
      size = CGSize(width: size.width * heightScale, height: maximumHeight)
    }
    return (
      CGSize(width: max(1, size.width.rounded()), height: max(1, size.height.rounded())),
      scale > 1.01
    )
  }
}

private struct MessageImageFullscreenView: View {
  @Environment(\.dismiss) private var dismiss
  let attachment: ChatAttachment
  let image: UIImage
  @State private var imageSaveError: String?

  var body: some View {
    ZStack(alignment: .top) {
      Color.black
        .ignoresSafeArea()
      ZoomableUIImageView(image: image)
        .ignoresSafeArea()
      HStack {
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.headline)
            .foregroundStyle(.white)
            .frame(width: 42, height: 42)
            .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel("Close")

        Spacer()

        Button {
          saveImage()
        } label: {
          Image(systemName: "square.and.arrow.down")
            .font(.headline)
            .foregroundStyle(.white)
            .frame(width: 42, height: 42)
            .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel("Save Image")
      }
      .padding(.horizontal, 18)
      .padding(.top, 12)
    }
    .statusBarHidden()
    .alert(
      "Could not save image",
      isPresented: Binding(
        get: { imageSaveError != nil },
        set: { if !$0 { imageSaveError = nil } }),
      presenting: imageSaveError
    ) { _ in
      Button("OK", role: .cancel) { imageSaveError = nil }
    } message: { message in
      Text(message)
    }
  }

  private func saveImage() {
    Task {
      do {
        try await MessageAttachmentImage.saveToPhotoLibrary(attachment)
      } catch {
        await MainActor.run {
          imageSaveError =
            (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
      }
    }
  }
}

private struct ZoomableUIImageView: UIViewRepresentable {
  let image: UIImage

  func makeUIView(context: Context) -> UIScrollView {
    let scrollView = UIScrollView()
    scrollView.delegate = context.coordinator
    scrollView.backgroundColor = .black
    scrollView.minimumZoomScale = 1
    scrollView.maximumZoomScale = 8
    scrollView.bouncesZoom = true
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.showsVerticalScrollIndicator = false

    let imageView = UIImageView(image: image)
    imageView.contentMode = .scaleAspectFit
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.isUserInteractionEnabled = true
    scrollView.addSubview(imageView)
    context.coordinator.imageView = imageView

    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
      imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
    ])

    let doubleTap = UITapGestureRecognizer(
      target: context.coordinator,
      action: #selector(Coordinator.handleDoubleTap(_:)))
    doubleTap.numberOfTapsRequired = 2
    scrollView.addGestureRecognizer(doubleTap)

    return scrollView
  }

  func updateUIView(_ scrollView: UIScrollView, context: Context) {
    context.coordinator.imageView?.image = image
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  final class Coordinator: NSObject, UIScrollViewDelegate {
    weak var imageView: UIImageView?

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
      imageView
    }

    @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
      guard let scrollView = recognizer.view as? UIScrollView else { return }
      if scrollView.zoomScale > scrollView.minimumZoomScale {
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
      } else {
        let point = recognizer.location(in: imageView)
        let targetScale = min(3, scrollView.maximumZoomScale)
        let size = CGSize(
          width: scrollView.bounds.width / targetScale,
          height: scrollView.bounds.height / targetScale)
        let rect = CGRect(
          x: point.x - size.width / 2,
          y: point.y - size.height / 2,
          width: size.width,
          height: size.height)
        scrollView.zoom(to: rect, animated: true)
      }
    }
  }
}

private enum MessageAttachmentImage {
  static func data(from attachment: ChatAttachment) -> Data? {
    guard attachment.kind == .image,
      let dataBase64 = attachment.dataBase64,
      !dataBase64.isEmpty
    else {
      return nil
    }
    return Data(base64Encoded: dataBase64)
  }

  static func uiImage(from attachment: ChatAttachment) -> UIImage? {
    guard let data = data(from: attachment) else { return nil }
    return UIImage(data: data)
  }

  static func saveToPhotoLibrary(_ attachment: ChatAttachment) async throws {
    guard let data = data(from: attachment), UIImage(data: data) != nil else {
      throw MessageImageSaveError("This image could not be decoded.")
    }

    let status = await photoLibraryAddAuthorizationStatus()
    guard isAuthorized(status) else {
      throw MessageImageSaveError("Allow photo library access to save this image.")
    }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      PHPhotoLibrary.shared().performChanges {
        let request = PHAssetCreationRequest.forAsset()
        request.addResource(with: .photo, data: data, options: nil)
      } completionHandler: { success, error in
        if let error {
          continuation.resume(throwing: error)
        } else if success {
          continuation.resume()
        } else {
          continuation.resume(throwing: MessageImageSaveError("The image was not saved."))
        }
      }
    }
  }

  private static func photoLibraryAddAuthorizationStatus() async -> PHAuthorizationStatus {
    let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    guard status == .notDetermined else { return status }
    return await withCheckedContinuation { continuation in
      PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
        continuation.resume(returning: status)
      }
    }
  }

  private static func isAuthorized(_ status: PHAuthorizationStatus) -> Bool {
    switch status {
    case .authorized, .limited:
      return true
    case .denied, .notDetermined, .restricted:
      return false
    @unknown default:
      return false
    }
  }
}

private struct MessageImageSaveError: LocalizedError {
  let message: String

  init(_ message: String) {
    self.message = message
  }

  var errorDescription: String? {
    message
  }
}

private struct AssistantTypingIndicator: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let fontSize: Double

  private var dotDiameter: CGFloat {
    min(8, max(5, CGFloat(fontSize) * 0.36))
  }

  private var waveAmplitude: CGFloat {
    dotDiameter * 0.55
  }

  var body: some View {
    Group {
      if reduceMotion {
        dots(progress: 0)
      } else {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
          dots(progress: timeline.date.timeIntervalSinceReferenceDate)
        }
      }
    }
    .frame(height: dotDiameter + waveAmplitude * 2)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Assistant is thinking")
  }

  private func dots(progress: TimeInterval) -> some View {
    HStack(spacing: dotDiameter * 0.75) {
      ForEach(0..<3, id: \.self) { index in
        let phase = progress * 2.0 * Double.pi / 1.15 - Double(index) * 0.48
        let lift = max(0, sin(phase))
        Circle()
          .fill(Color.secondary.opacity(reduceMotion ? 0.55 : 0.38 + lift * 0.24))
          .frame(width: dotDiameter, height: dotDiameter)
          .offset(y: reduceMotion ? 0 : -CGFloat(lift) * waveAmplitude)
      }
    }
    .padding(.vertical, waveAmplitude)
  }
}

private struct MessageTextSelectionSheet: View {
  @Environment(\.dismiss) private var dismiss

  let title: String
  let text: String
  let fontFamily: AppearanceFontFamily
  let lineSpacing: Double
  let isEditable: Bool
  let onSave: ((String) -> Void)?
  @State private var draftText: String
  @State private var fontSize: Double

  init(
    title: String,
    text: String,
    initialFontSize: Double = AppearanceSettings.defaults.fontSize,
    initialLineSpacing: Double = AppearanceSettings.defaults.lineSpacing,
    fontFamily: AppearanceFontFamily = .system,
    isEditable: Bool = false,
    onSave: ((String) -> Void)? = nil
  ) {
    self.title = title
    self.text = text
    self.fontFamily = fontFamily
    self.lineSpacing = AppearanceSettings.clampedLineSpacing(initialLineSpacing)
    self.isEditable = isEditable
    self.onSave = onSave
    _draftText = State(initialValue: text)
    _fontSize = State(initialValue: AppearanceSettings.clampedFontSize(initialFontSize))
  }

  var body: some View {
    NavigationStack {
      SelectableMessageTextView(
        text: $draftText,
        fontSize: $fontSize,
        lineSpacing: lineSpacing,
        fontFamily: fontFamily,
        isEditable: isEditable
      )
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if isEditable {
          ToolbarItem(placement: .topBarLeading) {
            Button("Cancel") {
              dismiss()
            }
          }
          ToolbarItem(placement: .topBarTrailing) {
            Button {
              UIPasteboard.general.string = draftText
            } label: {
              Label("Copy All", systemImage: "doc.on.doc")
            }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Save") {
              saveEdits()
            }
            .disabled(draftText == text)
          }
        } else {
          ToolbarItem(placement: .topBarLeading) {
            Button("Done") {
              dismiss()
            }
          }
          ToolbarItem(placement: .topBarTrailing) {
            Button {
              UIPasteboard.general.string = draftText
            } label: {
              Label("Copy All", systemImage: "doc.on.doc")
            }
          }
        }
      }
    }
  }

  private func saveEdits() {
    guard draftText != text else {
      dismiss()
      return
    }
    onSave?(draftText)
    dismiss()
  }
}

private struct SelectableMessageTextView: UIViewRepresentable {
  @Binding var text: String
  @Binding var fontSize: Double
  let lineSpacing: Double
  let fontFamily: AppearanceFontFamily
  let isEditable: Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(
      text: $text,
      fontSize: $fontSize,
      fontFamily: fontFamily,
      lineSpacing: lineSpacing)
  }

  func makeUIView(context: Context) -> UITextView {
    let textView = UITextView()
    textView.delegate = context.coordinator
    textView.isEditable = isEditable
    textView.isSelectable = true
    applyBareTextInputTraits(to: textView)
    textView.backgroundColor = .clear
    textView.font = fontFamily.uiFont(size: fontSize)
    textView.adjustsFontForContentSizeCategory = true
    textView.textContainerInset = UIEdgeInsets(top: 18, left: 14, bottom: 18, right: 14)
    textView.text = text
    context.coordinator.installPinchGesture(in: textView)
    context.coordinator.applyTextStyle(to: textView, size: fontSize)
    if isEditable {
      DispatchQueue.main.async {
        textView.becomeFirstResponder()
      }
    }
    return textView
  }

  func updateUIView(_ textView: UITextView, context: Context) {
    context.coordinator.text = $text
    context.coordinator.fontSize = $fontSize
    context.coordinator.fontFamily = fontFamily
    context.coordinator.lineSpacing = lineSpacing
    textView.isEditable = isEditable
    applyBareTextInputTraits(to: textView)
    if textView.text != text {
      textView.text = text
    }
    // Skip when the gesture handler already applied the style this run-loop cycle.
    // SwiftUI fires updateUIView after the binding write in updateFontSize, which
    // would cause a second full text-storage re-attribution for every gesture tick.
    if context.coordinator.pendingStyleFromGesture {
      context.coordinator.pendingStyleFromGesture = false
      return
    }
    context.coordinator.applyTextStyle(to: textView, size: fontSize)
  }

  private func applyBareTextInputTraits(to textView: UITextView) {
    textView.smartQuotesType = .no
    textView.smartDashesType = .no
    textView.smartInsertDeleteType = .no
    textView.autocorrectionType = .no
    textView.spellCheckingType = .no
  }

  final class Coordinator: NSObject, UIGestureRecognizerDelegate, UITextViewDelegate {
    var text: Binding<String>
    var fontSize: Binding<Double>
    var fontFamily: AppearanceFontFamily
    var lineSpacing: Double

    private weak var textView: UITextView?
    private var pinchGesture: UIPinchGestureRecognizer?
    private var pinchBaseFontSize: Double?
    private var pinchAnchor: TextViewPinchAnchor?
    private var pinchViewportY: CGFloat?
    // Set when applyTextStyle is called directly from the gesture handler so that
    // the redundant updateUIView→applyTextStyle call in the same SwiftUI pass can be skipped.
    var pendingStyleFromGesture = false
    private var originalShowsVerticalScrollIndicator: Bool?
    private var originalShowsHorizontalScrollIndicator: Bool?

    init(
      text: Binding<String>,
      fontSize: Binding<Double>,
      fontFamily: AppearanceFontFamily,
      lineSpacing: Double
    ) {
      self.text = text
      self.fontSize = fontSize
      self.fontFamily = fontFamily
      self.lineSpacing = lineSpacing
    }

    func installPinchGesture(in textView: UITextView) {
      guard pinchGesture == nil else { return }
      let gesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
      gesture.cancelsTouchesInView = false
      gesture.delaysTouchesBegan = false
      gesture.delaysTouchesEnded = false
      gesture.delegate = self
      textView.addGestureRecognizer(gesture)
      self.textView = textView
      pinchGesture = gesture
    }

    func textViewDidChange(_ textView: UITextView) {
      text.wrappedValue = textView.text
    }

    func applyTextStyle(to textView: UITextView, size: Double) {
      let nextFont = fontFamily.uiFont(size: size)
      let paragraphStyle = NSMutableParagraphStyle()
      paragraphStyle.lineSpacing = CGFloat(lineSpacing)
      textView.font = nextFont
      textView.typingAttributes[.font] = nextFont
      textView.typingAttributes[.paragraphStyle] = paragraphStyle
      if textView.textStorage.length > 0 {
        textView.textStorage.addAttributes(
          [
            .font: nextFont,
            .paragraphStyle: paragraphStyle,
          ],
          range: NSRange(location: 0, length: textView.textStorage.length))
      }
      textView.setNeedsLayout()
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
      guard let textView else { return }

      switch recognizer.state {
      case .began:
        pinchBaseFontSize = fontSize.wrappedValue
        hideScrollIndicators(in: textView)
        updateFontSize(for: recognizer, in: textView)
      case .changed:
        updateFontSize(for: recognizer, in: textView)
      case .ended, .cancelled, .failed:
        pinchBaseFontSize = nil
        pinchAnchor = nil
        pinchViewportY = nil
        restoreScrollIndicators()
      default:
        break
      }
    }

    private func updateFontSize(
      for recognizer: UIPinchGestureRecognizer,
      in textView: UITextView
    ) {
      let baseSize = pinchBaseFontSize ?? fontSize.wrappedValue
      pinchBaseFontSize = baseSize
      let rawSize = baseSize * max(Double(recognizer.scale), 0.1)
      let steppedSize =
        (rawSize / AppearanceSettings.fontSizeStep).rounded() * AppearanceSettings.fontSizeStep
      let clampedSize = AppearanceSettings.clampedFontSize(steppedSize)
      guard fontSize.wrappedValue != clampedSize else { return }

      // Capture anchor and viewport position once per gesture — the layout lookup
      // (layoutIfNeeded + layoutManager queries) only runs on the first tick.
      let contentPoint = recognizer.location(in: textView)
      let viewportY: CGFloat
      let anchor: TextViewPinchAnchor
      if let cachedAnchor = pinchAnchor, let cachedViewportY = pinchViewportY {
        anchor = cachedAnchor
        viewportY = cachedViewportY
      } else {
        viewportY = contentPoint.y - textView.contentOffset.y
        anchor = makePinchAnchor(in: textView, at: contentPoint)
        pinchAnchor = anchor
        pinchViewportY = viewportY
      }

      fontSize.wrappedValue = clampedSize
      // Mark before applyTextStyle so updateUIView can skip the redundant call that
      // SwiftUI will fire in the same run-loop cycle after the binding write above.
      pendingStyleFromGesture = true
      applyTextStyle(to: textView, size: clampedSize)
      preservePinchPosition(in: textView, anchor: anchor, viewportY: viewportY)
    }

    private func preservePinchPosition(
      in textView: UITextView,
      anchor: TextViewPinchAnchor,
      viewportY: CGFloat
    ) {
      textView.layoutIfNeeded()
      let targetContentY = resolvedContentY(for: anchor, in: textView)
      let targetY = targetContentY - viewportY
      textView.setContentOffset(
        CGPoint(x: textView.contentOffset.x, y: clampedScrollOffsetY(targetY, in: textView)),
        animated: false)
    }

    private func makePinchAnchor(
      in textView: UITextView,
      at contentPoint: CGPoint
    ) -> TextViewPinchAnchor {
      textView.layoutIfNeeded()
      let fallbackContentHeight = max(textView.contentSize.height, 1)
      guard textView.textStorage.length > 0 else {
        return TextViewPinchAnchor(
          characterIndex: nil,
          unitY: 0,
          fallbackContentY: contentPoint.y,
          fallbackContentHeight: fallbackContentHeight)
      }

      let textContainerPoint = CGPoint(
        x: contentPoint.x - textView.textContainerInset.left,
        y: contentPoint.y - textView.textContainerInset.top)
      let layoutManager = textView.layoutManager
      layoutManager.ensureLayout(for: textView.textContainer)
      let characterIndex = layoutManager.characterIndex(
        for: textContainerPoint,
        in: textView.textContainer,
        fractionOfDistanceBetweenInsertionPoints: nil)
      let clampedIndex = min(max(characterIndex, 0), textView.textStorage.length - 1)
      let glyphIndex = layoutManager.glyphIndexForCharacter(at: clampedIndex)
      var lineRange = NSRange()
      let lineRect = layoutManager.lineFragmentUsedRect(
        forGlyphAt: glyphIndex,
        effectiveRange: &lineRange)
      let unitY =
        lineRect.height > 1
        ? min(max((textContainerPoint.y - lineRect.minY) / lineRect.height, 0), 1)
        : 0

      return TextViewPinchAnchor(
        characterIndex: clampedIndex,
        unitY: unitY,
        fallbackContentY: contentPoint.y,
        fallbackContentHeight: fallbackContentHeight)
    }

    private func resolvedContentY(
      for anchor: TextViewPinchAnchor,
      in textView: UITextView
    ) -> CGFloat {
      if let characterIndex = anchor.characterIndex, textView.textStorage.length > 0 {
        let layoutManager = textView.layoutManager
        layoutManager.ensureLayout(for: textView.textContainer)
        let clampedIndex = min(max(characterIndex, 0), textView.textStorage.length - 1)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: clampedIndex)
        let lineRect = layoutManager.lineFragmentUsedRect(
          forGlyphAt: glyphIndex, effectiveRange: nil)
        return textView.textContainerInset.top + lineRect.minY + lineRect.height * anchor.unitY
      }

      let newContentHeight = max(textView.contentSize.height, 1)
      return anchor.fallbackContentY * newContentHeight / anchor.fallbackContentHeight
    }

    private func clampedScrollOffsetY(_ y: CGFloat, in textView: UITextView) -> CGFloat {
      let minimumY = -textView.adjustedContentInset.top
      let maximumY = max(
        minimumY,
        textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom)
      return min(max(y, minimumY), maximumY)
    }

    private func hideScrollIndicators(in textView: UITextView) {
      if originalShowsVerticalScrollIndicator == nil {
        originalShowsVerticalScrollIndicator = textView.showsVerticalScrollIndicator
      }
      if originalShowsHorizontalScrollIndicator == nil {
        originalShowsHorizontalScrollIndicator = textView.showsHorizontalScrollIndicator
      }
      textView.showsVerticalScrollIndicator = false
      textView.showsHorizontalScrollIndicator = false
    }

    private func restoreScrollIndicators() {
      guard let textView else { return }
      if let originalShowsVerticalScrollIndicator {
        textView.showsVerticalScrollIndicator = originalShowsVerticalScrollIndicator
      }
      if let originalShowsHorizontalScrollIndicator {
        textView.showsHorizontalScrollIndicator = originalShowsHorizontalScrollIndicator
      }
      originalShowsVerticalScrollIndicator = nil
      originalShowsHorizontalScrollIndicator = nil
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      guard let pinch = gestureRecognizer as? UIPinchGestureRecognizer else { return true }
      return pinch.numberOfTouches >= 2
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      true
    }
  }
}

private struct TextViewPinchAnchor {
  let characterIndex: Int?
  let unitY: CGFloat
  let fallbackContentY: CGFloat
  let fallbackContentHeight: CGFloat
}

extension View {
  @ViewBuilder
  fileprivate func textSelectionIfEnabled(_ enabled: Bool) -> some View {
    if enabled {
      textSelection(.enabled)
    } else {
      self
    }
  }

  @ViewBuilder
  fileprivate func foregroundStyleIfPresent(_ color: Color?) -> some View {
    if let color {
      foregroundStyle(color)
    } else {
      self
    }
  }
}

private struct PreparedMessageContent {
  let visibleText: String
  let toolEntries: [ToolEntry]
  let reasoningSections: [HiddenMessageSection]
  let transcriptSections: [HiddenMessageSection]
  let hideBubble: Bool
}

private enum MessageRenderCache {
  private struct PreparedEntry {
    let text: String
    let content: PreparedMessageContent
  }

  private struct MarkdownEntry {
    let text: String
    let blocks: [MarkdownBlock]
  }

  private static let maxEntries = 160
  @MainActor private static var preparedEntries: [UUID: PreparedEntry] = [:]
  @MainActor private static var markdownEntries: [UUID: MarkdownEntry] = [:]
  @MainActor private static var accessOrder: [UUID] = []

  @MainActor
  static func preparedContent(messageID: UUID, text: String) -> PreparedMessageContent {
    if let entry = preparedEntries[messageID], entry.text == text {
      markAccessed(messageID)
      return entry.content
    }

    let rendered = MessageContentFilter.render(text)
    let toolEntries = rendered.hiddenSections
      .filter { $0.tag == "context" || $0.tag == "tool_context" || $0.tag == "tool_run" }
      .flatMap { ToolCallParser.parse($0.content) }
    let reasoningSections = rendered.hiddenSections.filter { $0.tag == "think" }
    let transcriptSections = rendered.hiddenSections.filter { $0.tag == "conversation" }
    let visibleEmpty = rendered.visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let hasMeta = !toolEntries.isEmpty || !reasoningSections.isEmpty || !transcriptSections.isEmpty
    let content = PreparedMessageContent(
      visibleText: rendered.visibleText,
      toolEntries: toolEntries,
      reasoningSections: reasoningSections,
      transcriptSections: transcriptSections,
      hideBubble: visibleEmpty && hasMeta
    )

    preparedEntries[messageID] = PreparedEntry(text: text, content: content)
    markAccessed(messageID)
    pruneIfNeeded()
    return content
  }

  @MainActor
  static func markdownBlocks(messageID: UUID, text: String) -> [MarkdownBlock] {
    if let entry = markdownEntries[messageID], entry.text == text {
      markAccessed(messageID)
      return entry.blocks
    }

    let blocks = MarkdownParser.blocks(from: text)
    markdownEntries[messageID] = MarkdownEntry(text: text, blocks: blocks)
    markAccessed(messageID)
    pruneIfNeeded()
    return blocks
  }

  @MainActor
  private static func markAccessed(_ id: UUID) {
    accessOrder.removeAll { $0 == id }
    accessOrder.append(id)
  }

  @MainActor
  private static func pruneIfNeeded() {
    while accessOrder.count > maxEntries, let oldest = accessOrder.first {
      accessOrder.removeFirst()
      preparedEntries.removeValue(forKey: oldest)
      markdownEntries.removeValue(forKey: oldest)
    }
  }
}

private struct FoldableMetaSection: View {
  let title: String
  let systemImage: String
  let content: String
  var monospaced: Bool
  var dimmedContent: Bool = false
  var initiallyExpanded: Bool = false
  var italicContent: Bool = false
  var markdownAppearance: AppearanceSettings? = nil
  var renderImages: Bool = true

  @State private var expanded: Bool = false

  init(
    title: String,
    systemImage: String,
    content: String,
    monospaced: Bool,
    dimmedContent: Bool = false,
    initiallyExpanded: Bool = false,
    italicContent: Bool = false,
    markdownAppearance: AppearanceSettings? = nil,
    renderImages: Bool = true
  ) {
    self.title = title
    self.systemImage = systemImage
    self.content = content
    self.monospaced = monospaced
    self.dimmedContent = dimmedContent
    self.initiallyExpanded = initiallyExpanded
    self.italicContent = italicContent
    self.markdownAppearance = markdownAppearance
    self.renderImages = renderImages
    self._expanded = State(initialValue: initiallyExpanded)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: systemImage)
            .imageScale(.small)
            .foregroundStyle(.secondary)
          Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Spacer(minLength: 8)
          Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .imageScale(.small)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if expanded {
        Divider().opacity(0.4)
        Group {
          if let markdownAppearance, MarkdownParser.mayContainMarkdown(content) {
            MarkdownContentView(
              text: content, appearance: markdownAppearance,
              allowsTextSelection: true,
              foregroundStyle: dimmedContent ? Color.secondary : nil,
              renderImages: renderImages,
              italic: italicContent)
          } else {
            let contentFont =
              (monospaced ? Font.system(.footnote, design: .monospaced) : Font.callout)
              .italicizedIf(italicContent)
            Text(content)
              .font(contentFont)
              .foregroundStyle(dimmedContent ? Color.secondary : Color.primary)
              .textSelection(.enabled)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
      }
    }
    .background(.thinMaterial.opacity(0.55))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(.secondary.opacity(0.18), lineWidth: 0.5)
    )
    .onChange(of: initiallyExpanded) { _, expandedByDefault in
      expanded = expandedByDefault
    }
  }
}

private struct VoiceRecordingPlaybackButton: View {
  @EnvironmentObject private var ttsPlayer: TTSPlayer

  let message: ChatMessage

  private var isCurrent: Bool {
    ttsPlayer.currentMessageID == message.id && ttsPlayer.currentRole == .user
  }

  private var isPlaying: Bool {
    isCurrent && ttsPlayer.isSpeaking && !ttsPlayer.isPaused
  }

  private var systemImage: String {
    isPlaying ? "pause.circle.fill" : "play.circle.fill"
  }

  private var title: String {
    if isPlaying { return "Pause recording" }
    if isCurrent && ttsPlayer.isPaused { return "Resume recording" }
    return "Play recording"
  }

  var body: some View {
    Button {
      ttsPlayer.toggleRecordingPlayback(for: message, title: "User Recording")
    } label: {
      HStack(spacing: 8) {
        Image(systemName: systemImage)
          .font(.system(size: 30, weight: .semibold))
          .symbolRenderingMode(.hierarchical)
        Text(title)
          .font(.callout.weight(.semibold))
      }
      .padding(.vertical, 6)
      .padding(.horizontal, 8)
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.borderless)
    .foregroundStyle(Color.accentColor)
    .accessibilityLabel(title)
  }
}

private struct ToolCallRow: View {
  let entry: ToolEntry
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
      } label: {
        HStack(spacing: 8) {
          Image(systemName: entry.systemImage)
            .imageScale(.small)
            .foregroundStyle(Color.accentColor)
          Text(entry.name)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
          if !entry.params.isEmpty {
            Text(entry.params)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          Spacer(minLength: 8)
          Image(systemName: expanded ? "chevron.down" : "chevron.right")
            .imageScale(.small)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if expanded {
        Divider().opacity(0.4)
        VStack(alignment: .leading, spacing: 8) {
          toolSection(label: "Input", value: entry.params, emptyText: "(no input)")
          toolSection(label: "Output", value: entry.body, emptyText: "(no output)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
      }
    }
    .background(.thinMaterial.opacity(0.55))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.accentColor.opacity(0.18), lineWidth: 0.5)
    )
  }

  @ViewBuilder
  private func toolSection(label: String, value: String, emptyText: String) -> some View {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    VStack(alignment: .leading, spacing: 4) {
      Text(label)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(trimmed.isEmpty ? emptyText : value)
        .font(.system(.footnote, design: .monospaced))
        .foregroundStyle(trimmed.isEmpty ? Color.secondary : Color.primary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct ToolEntry: Identifiable {
  let id = UUID()
  let name: String
  let params: String
  let body: String
  let systemImage: String
}

enum ToolCallParser {
  static func parse(_ text: String) -> [ToolEntry] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    var entries: [ToolEntry] = []
    var currentHeader: String? = nil
    var currentBody: [String] = []

    func flush() {
      guard let header = currentHeader else { return }
      let body = currentBody.joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if let entry = makeEntry(header: header, body: body) {
        entries.append(entry)
      }
      currentHeader = nil
      currentBody.removeAll()
    }

    for line in trimmed.components(separatedBy: "\n") {
      if isToolHeader(line) {
        flush()
        currentHeader = line.trimmingCharacters(in: .whitespaces)
      } else if currentHeader != nil {
        currentBody.append(line)
      }
    }
    flush()
    return entries
  }

  private static func isToolHeader(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasSuffix(":") else { return false }
    var stem = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
    if stem.hasSuffix(")"),
      let parenIdx = stem.lastIndex(of: "(")
    {
      stem = String(stem[..<parenIdx]).trimmingCharacters(in: .whitespaces)
    }
    return stem.lowercased().hasSuffix(" tool")
  }

  private static func makeEntry(header: String, body: String) -> ToolEntry? {
    guard let toolRange = header.range(of: " tool", options: [.caseInsensitive]) else {
      return nil
    }
    let name = String(header[..<toolRange.lowerBound])
      .trimmingCharacters(in: .whitespaces)
    let after = String(header[toolRange.upperBound...])
      .trimmingCharacters(in: CharacterSet(charactersIn: " \t:"))
    var params = ""
    if after.hasPrefix("(") && after.hasSuffix(")") {
      params = String(after.dropFirst().dropLast())
    } else if !after.isEmpty {
      params = after
    }
    return ToolEntry(
      name: name.isEmpty ? "Tool" : name,
      params: params,
      body: body,
      systemImage: icon(for: name)
    )
  }

  private static func icon(for name: String) -> String {
    switch name.lowercased() {
    case "date & time": return "clock"
    case "location": return "location"
    case "weather": return "cloud.sun"
    case "web search": return "magnifyingglass"
    case "todo": return "checklist"
    case "files": return "folder"
    case "memory": return "brain"
    default: return "wrench.and.screwdriver"
    }
  }
}

struct MarkdownContentView: View {
  let blocks: [MarkdownBlock]
  let appearance: AppearanceSettings
  let fontFamily: AppearanceFontFamily
  let allowsTextSelection: Bool
  let foregroundStyle: Color?
  let uiForegroundColor: UIColor?
  let renderImages: Bool
  let italic: Bool

  init(
    text: String,
    appearance: AppearanceSettings = .defaults,
    fontFamily: AppearanceFontFamily? = nil,
    allowsTextSelection: Bool = true,
    foregroundStyle: Color? = nil,
    uiForegroundColor: UIColor? = nil,
    renderImages: Bool = true,
    italic: Bool = false
  ) {
    self.blocks = MarkdownParser.blocks(from: text)
    self.appearance = appearance
    self.fontFamily = fontFamily ?? appearance.assistantFontFamily
    self.allowsTextSelection = allowsTextSelection
    self.foregroundStyle = foregroundStyle
    self.uiForegroundColor = uiForegroundColor
    self.renderImages = renderImages
    self.italic = italic
  }

  init(
    blocks: [MarkdownBlock],
    appearance: AppearanceSettings = .defaults,
    fontFamily: AppearanceFontFamily? = nil,
    allowsTextSelection: Bool = true,
    foregroundStyle: Color? = nil,
    uiForegroundColor: UIColor? = nil,
    renderImages: Bool = true,
    italic: Bool = false
  ) {
    self.blocks = blocks
    self.appearance = appearance
    self.fontFamily = fontFamily ?? appearance.assistantFontFamily
    self.allowsTextSelection = allowsTextSelection
    self.foregroundStyle = foregroundStyle
    self.uiForegroundColor = uiForegroundColor
    self.renderImages = renderImages
    self.italic = italic
  }

  var body: some View {
    VStack(alignment: .leading, spacing: appearance.markdownMetric(10)) {
      ForEach(blocks) { block in
        switch block.kind {
        case .heading(let level, let value):
          MarkdownInlineText(
            value: value,
            appearance: appearance,
            font: headingFont(level: level),
            uiFont: headingUIFont(level: level),
            allowsTextSelection: allowsTextSelection,
            foregroundStyle: foregroundStyle,
            uiForegroundColor: uiForegroundColor,
            italic: italic
          )
          .fixedSize(horizontal: false, vertical: true)
        case .text(let value):
          MarkdownInlineText(
            value: value,
            appearance: appearance,
            font: fontFamily.swiftUIFont(size: appearance.fontSize),
            uiFont: fontFamily.uiFont(size: appearance.fontSize),
            allowsTextSelection: allowsTextSelection,
            foregroundStyle: foregroundStyle,
            uiForegroundColor: uiForegroundColor,
            italic: italic
          )
          .fixedSize(horizontal: false, vertical: true)
        case .blockquote(let value):
          BlockquoteView(
            text: value,
            appearance: appearance,
            fontFamily: fontFamily,
            allowsTextSelection: allowsTextSelection,
            italic: italic)
        case .horizontalRule:
          MarkdownHorizontalRuleView(appearance: appearance)
        case .code(let language, let code):
          CodeBlockView(
            language: language,
            code: code,
            appearance: appearance,
            allowsTextSelection: allowsTextSelection)
        case .table(let headers, let rows, let alignments):
          MarkdownTableView(
            headers: headers,
            rows: rows,
            alignments: alignments,
            appearance: appearance,
            fontFamily: fontFamily,
            allowsTextSelection: allowsTextSelection,
            foregroundStyle: foregroundStyle,
            uiForegroundColor: uiForegroundColor,
            italic: italic
          )
        case .taskList(let items):
          TaskListView(
            items: items,
            appearance: appearance,
            fontFamily: fontFamily,
            allowsTextSelection: allowsTextSelection,
            foregroundStyle: foregroundStyle,
            uiForegroundColor: uiForegroundColor,
            italic: italic)
        case .bulletList(let items):
          BulletListView(
            items: items,
            appearance: appearance,
            fontFamily: fontFamily,
            allowsTextSelection: allowsTextSelection,
            foregroundStyle: foregroundStyle,
            uiForegroundColor: uiForegroundColor,
            italic: italic)
        case .orderedList(let items):
          OrderedListView(
            items: items,
            appearance: appearance,
            fontFamily: fontFamily,
            allowsTextSelection: allowsTextSelection,
            foregroundStyle: foregroundStyle,
            uiForegroundColor: uiForegroundColor,
            italic: italic)
        case .footnotes(let items):
          FootnotesView(
            items: items,
            appearance: appearance,
            fontFamily: fontFamily,
            allowsTextSelection: allowsTextSelection,
            foregroundStyle: foregroundStyle,
            uiForegroundColor: uiForegroundColor,
            italic: italic)
        }
      }
    }
    .environment(\.markdownRenderImages, renderImages)
  }

  private func headingFont(level: Int) -> Font {
    let clampedLevel = min(max(level, 1), 6)
    let scale: Double =
      switch clampedLevel {
      case 1: 1.55
      case 2: 1.32
      case 3: 1.16
      case 4: 1.04
      case 5: 0.96
      default: 0.88
      }
    return fontFamily.swiftUIFont(size: appearance.fontSize * scale)
      .weight(clampedLevel == 1 ? .bold : .semibold)
  }

  private func headingUIFont(level: Int) -> UIFont {
    let clampedLevel = min(max(level, 1), 6)
    let scale: Double =
      switch clampedLevel {
      case 1: 1.55
      case 2: 1.32
      case 3: 1.16
      case 4: 1.04
      case 5: 0.96
      default: 0.88
      }
    return fontFamily.uiFont(size: appearance.fontSize * scale)
      .withWeight(clampedLevel == 1 ? .bold : .semibold)
  }
}

private struct MarkdownHorizontalRuleView: View {
  let appearance: AppearanceSettings

  var body: some View {
    Divider()
      .overlay(Color.secondary.opacity(0.35))
      .frame(maxWidth: .infinity)
      .padding(.vertical, appearance.markdownMetric(4))
      .accessibilityHidden(true)
  }
}

private struct MarkdownInlineText: View {
  @Environment(\.markdownRenderImages) private var renderMarkdownImages

  let value: String
  let appearance: AppearanceSettings
  let font: Font
  let uiFont: UIFont
  let allowsTextSelection: Bool
  var textAlignment: TextAlignment = .leading
  var foregroundStyle: Color? = nil
  var uiForegroundColor: UIColor? = nil
  var strikethrough: Bool = false
  var allowsJustification: Bool = true
  var italic: Bool = false

  var body: some View {
    let segments = renderMarkdownImages ? MarkdownInlineImageScanner.segments(in: value) : []
    if renderMarkdownImages && segments.containsImage {
      MarkdownInlineSegmentedText(
        segments: segments,
        appearance: appearance,
        font: font,
        uiFont: uiFont,
        allowsTextSelection: allowsTextSelection,
        textAlignment: textAlignment,
        foregroundStyle: foregroundStyle,
        uiForegroundColor: uiForegroundColor,
        strikethrough: strikethrough,
        allowsJustification: allowsJustification,
        italic: italic)
    } else {
      MarkdownPlainInlineText(
        value: value,
        appearance: appearance,
        font: font,
        uiFont: uiFont,
        allowsTextSelection: allowsTextSelection,
        textAlignment: textAlignment,
        foregroundStyle: foregroundStyle,
        uiForegroundColor: uiForegroundColor,
        strikethrough: strikethrough,
        allowsJustification: allowsJustification,
        italic: italic)
    }
  }
}

private struct MarkdownInlineSegmentedText: View {
  let segments: [MarkdownInlineSegment]
  let appearance: AppearanceSettings
  let font: Font
  let uiFont: UIFont
  let allowsTextSelection: Bool
  let textAlignment: TextAlignment
  let foregroundStyle: Color?
  let uiForegroundColor: UIColor?
  let strikethrough: Bool
  let allowsJustification: Bool
  let italic: Bool

  var body: some View {
    VStack(alignment: frameAlignment, spacing: appearance.markdownMetric(6)) {
      ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
        switch segment {
        case .text(let text):
          if !text.trimmingCharacters(in: .newlines).isEmpty {
            MarkdownPlainInlineText(
              value: text,
              appearance: appearance,
              font: font,
              uiFont: uiFont,
              allowsTextSelection: allowsTextSelection,
              textAlignment: textAlignment,
              foregroundStyle: foregroundStyle,
              uiForegroundColor: uiForegroundColor,
              strikethrough: strikethrough,
              allowsJustification: allowsJustification,
              italic: italic)
            .frame(maxWidth: .infinity, alignment: swiftUIAlignment)
          }
        case .image(let image):
          MarkdownImageView(image: image, appearance: appearance)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }

  private var frameAlignment: HorizontalAlignment {
    switch textAlignment {
    case .center: return .center
    case .trailing: return .trailing
    default: return .leading
    }
  }

  private var swiftUIAlignment: Alignment {
    switch textAlignment {
    case .center: return .center
    case .trailing: return .trailing
    default: return .leading
    }
  }
}

private struct MarkdownPlainInlineText: View {
  let value: String
  let appearance: AppearanceSettings
  let font: Font
  let uiFont: UIFont
  let allowsTextSelection: Bool
  var textAlignment: TextAlignment = .leading
  var foregroundStyle: Color? = nil
  var uiForegroundColor: UIColor? = nil
  var strikethrough: Bool = false
  var allowsJustification: Bool = true
  var italic: Bool = false

  var body: some View {
    if allowsJustification && appearance.justifyText && textAlignment.isLeading {
      JustifiedMarkdownTextView(
        value: value,
        font: uiFont.italicizedIf(italic),
        lineSpacing: appearance.lineSpacing,
        allowsTextSelection: allowsTextSelection,
        foregroundColor: uiForegroundColor ?? .label,
        strikethrough: strikethrough
      )
      .frame(maxWidth: .infinity, alignment: .leading)
      .alignmentGuide(.firstTextBaseline) { dimensions in
        dimensions[.top] + uiFont.ascender
      }
    } else {
      let effectiveFont = font.italicizedIf(italic)
      Text(attributedInlineMarkdown(value, strongFont: effectiveFont.bold()))
        .font(effectiveFont)
        .lineSpacing(CGFloat(appearance.lineSpacing))
        .multilineTextAlignment(textAlignment)
        .foregroundStyleIfPresent(foregroundStyle)
        .strikethrough(strikethrough, color: .secondary)
        .textSelectionIfEnabled(allowsTextSelection)
    }
  }
}

private struct MarkdownImageView: View {
  let image: MarkdownInlineImage
  let appearance: AppearanceSettings

  var body: some View {
    if let url = image.url {
      AsyncImage(url: url) { phase in
        switch phase {
        case .empty:
          placeholderView
        case .success(let loadedImage):
          loadedImage
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: 320, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .failure:
          failureView
        @unknown default:
          failureView
        }
      }
      .accessibilityLabel(accessibilityLabel)
    } else {
      failureView
        .accessibilityLabel(accessibilityLabel)
    }
  }

  private var placeholderView: some View {
    ProgressView()
      .controlSize(.regular)
      .frame(maxWidth: .infinity, minHeight: 96)
      .background(Color.secondary.opacity(0.08))
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(border)
  }

  private var failureView: some View {
    HStack(spacing: appearance.markdownMetric(10)) {
      ZStack(alignment: .bottomTrailing) {
        Image(systemName: "photo")
          .font(.system(size: appearance.fontSize * 1.45, weight: .regular))
          .foregroundStyle(.secondary)
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: max(9, appearance.fontSize * 0.58), weight: .semibold))
          .foregroundStyle(.orange)
          .background(Circle().fill(Color(uiColor: .systemBackground)))
          .offset(x: 4, y: 3)
      }
      .frame(width: appearance.markdownMetric(34), height: appearance.markdownMetric(34))

      VStack(alignment: .leading, spacing: 2) {
        Text(image.altText.isEmpty ? "Image unavailable" : image.altText)
          .font(.system(size: appearance.fontSize * 0.92, weight: .semibold))
          .foregroundStyle(.primary)
          .lineLimit(2)
        Text(image.source)
          .font(.system(size: max(10, appearance.fontSize * 0.76)))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
    .padding(.horizontal, appearance.markdownMetric(10))
    .padding(.vertical, appearance.markdownMetric(9))
    .frame(maxWidth: .infinity, minHeight: appearance.markdownMetric(58), alignment: .leading)
    .background(Color.secondary.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(border)
  }

  private var border: some View {
    RoundedRectangle(cornerRadius: 10, style: .continuous)
      .strokeBorder(.secondary.opacity(0.18), lineWidth: 1)
  }

  private var accessibilityLabel: String {
    image.altText.isEmpty ? "Markdown image" : image.altText
  }
}

private enum MarkdownInlineSegment: Equatable {
  case text(String)
  case image(MarkdownInlineImage)
}

private extension [MarkdownInlineSegment] {
  var containsImage: Bool {
    contains {
      if case .image = $0 { return true }
      return false
    }
  }
}

private struct MarkdownInlineImage: Equatable {
  let altText: String
  let source: String

  var url: URL? {
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed),
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else {
      return nil
    }
    return url
  }
}

private enum MarkdownInlineImageScanner {
  static func segments(in value: String) -> [MarkdownInlineSegment] {
    guard value.contains("![") else { return [.text(value)] }

    let chars = Array(value)
    var segments: [MarkdownInlineSegment] = []
    var textStart = 0
    var index = 0

    while index < chars.count {
      if chars[index] == "`", let end = findUnescapedBacktick(in: chars, start: index + 1) {
        index = end + 1
        continue
      }

      guard let image = imageToken(in: chars, at: index) else {
        index += 1
        continue
      }

      appendText(chars, range: textStart..<index, to: &segments)
      segments.append(.image(image.value))
      index = image.end
      textStart = index
    }

    appendText(chars, range: textStart..<chars.count, to: &segments)
    return segments.isEmpty ? [.text(value)] : segments
  }

  private static func imageToken(in chars: [Character], at index: Int)
    -> (value: MarkdownInlineImage, end: Int)?
  {
    guard index + 1 < chars.count,
      chars[index] == "!",
      chars[index + 1] == "[",
      !isEscaped(chars, at: index),
      let altEnd = findImageAltEnd(in: chars, start: index + 2),
      altEnd + 1 < chars.count,
      chars[altEnd + 1] == "(",
      let destinationEnd = findImageDestinationEnd(in: chars, start: altEnd + 2)
    else {
      return nil
    }

    let alt = String(chars[(index + 2)..<altEnd])
    let destination = String(chars[(altEnd + 2)..<destinationEnd])
    guard let source = imageSource(from: destination) else { return nil }
    return (MarkdownInlineImage(altText: alt, source: source), destinationEnd + 1)
  }

  private static func appendText(
    _ chars: [Character],
    range: Range<Int>,
    to segments: inout [MarkdownInlineSegment]
  ) {
    guard !range.isEmpty else { return }
    segments.append(.text(String(chars[range])))
  }

  private static func imageSource(from destination: String) -> String? {
    let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if trimmed.first == "<", let close = trimmed.firstIndex(of: ">") {
      let start = trimmed.index(after: trimmed.startIndex)
      guard start <= close else { return nil }
      return String(trimmed[start..<close])
    }

    let chars = Array(trimmed)
    var end = 0
    while end < chars.count, !chars[end].isWhitespace {
      end += 1
    }
    guard end > 0 else { return nil }
    return String(chars[0..<end])
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
  }

  private static func findImageAltEnd(in chars: [Character], start: Int) -> Int? {
    var index = start
    while index < chars.count {
      if chars[index] == "\\" {
        index += 2
        continue
      }
      if chars[index] == "]" {
        return index
      }
      if chars[index] == "\n" || chars[index] == "\r" {
        return nil
      }
      index += 1
    }
    return nil
  }

  private static func findImageDestinationEnd(in chars: [Character], start: Int) -> Int? {
    var depth = 0
    var index = start
    while index < chars.count {
      if chars[index] == "\\" {
        index += 2
        continue
      }
      if chars[index] == "\n" || chars[index] == "\r" {
        return nil
      }
      if chars[index] == "(" {
        depth += 1
      } else if chars[index] == ")" {
        if depth == 0 {
          return index
        }
        depth -= 1
      }
      index += 1
    }
    return nil
  }

  private static func findUnescapedBacktick(in chars: [Character], start: Int) -> Int? {
    var index = start
    while index < chars.count {
      if chars[index] == "`", !isEscaped(chars, at: index) {
        return index
      }
      index += 1
    }
    return nil
  }

  private static func isEscaped(_ chars: [Character], at index: Int) -> Bool {
    guard index > 0 else { return false }
    var slashCount = 0
    var cursor = index - 1
    while cursor >= 0, chars[cursor] == "\\" {
      slashCount += 1
      cursor -= 1
    }
    return slashCount % 2 == 1
  }
}

extension TextAlignment {
  fileprivate var isLeading: Bool {
    switch self {
    case .leading: true
    default: false
    }
  }
}

private struct JustifiedMarkdownTextView: UIViewRepresentable {
  let value: String
  let font: UIFont
  let lineSpacing: Double
  let allowsTextSelection: Bool
  let foregroundColor: UIColor
  let strikethrough: Bool

  func makeUIView(context: Context) -> UITextView {
    let textView = UITextView()
    textView.backgroundColor = .clear
    textView.isEditable = false
    textView.isScrollEnabled = false
    textView.textContainerInset = .zero
    textView.textContainer.lineFragmentPadding = 0
    textView.textContainer.lineBreakMode = .byWordWrapping
    textView.adjustsFontForContentSizeCategory = true
    textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
    return textView
  }

  func updateUIView(_ textView: UITextView, context: Context) {
    configure(textView)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView textView: UITextView, context: Context)
    -> CGSize?
  {
    configure(textView)
    guard let width = proposal.width, width.isFinite, width > 0 else {
      return nil
    }
    let height = textView.sizeThatFits(
      CGSize(width: width, height: .greatestFiniteMagnitude)
    ).height
    return CGSize(width: width, height: ceil(height))
  }

  private func configure(_ textView: UITextView) {
    textView.attributedText = nsAttributedInlineMarkdown(
      value,
      font: font,
      lineSpacing: lineSpacing,
      alignment: .justified,
      foregroundColor: foregroundColor,
      strikethrough: strikethrough)
    textView.isSelectable = allowsTextSelection
    textView.isUserInteractionEnabled = allowsTextSelection
  }
}

extension AppearanceSettings {
  fileprivate var markdownMetricScale: CGFloat {
    CGFloat(fontSize / AppearanceSettings.defaults.fontSize)
  }

  fileprivate func markdownMetric(_ value: CGFloat) -> CGFloat {
    value * markdownMetricScale
  }

  fileprivate func markdownListMarkerWidth(markerLength: Int, minimum: CGFloat = 18) -> CGFloat {
    max(markdownMetric(minimum), CGFloat(markerLength) * CGFloat(fontSize) * 0.64)
  }
}

private func attributedInlineMarkdown(_ value: String, strongFont: Font? = nil) -> AttributedString {
  let normalized = MarkdownInlineSymbols.displayString(value)
  let attributed =
    (try? AttributedString(
      markdown: normalized,
      options: AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace)))
    ?? AttributedString(normalized)
  return MarkdownInlineStyleApplier.styled(
    MarkdownInlineTokenColorizer.colorized(attributed),
    strongFont: strongFont
  )
}

private func nsAttributedInlineMarkdown(
  _ value: String,
  font: UIFont,
  lineSpacing: Double,
  alignment: NSTextAlignment,
  foregroundColor: UIColor,
  strikethrough: Bool
) -> NSAttributedString {
  let attributed = attributedInlineMarkdown(value)
  let string = String(attributed.characters)
  let result = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
  let fullRange = NSRange(location: 0, length: result.length)

  let paragraphStyle = NSMutableParagraphStyle()
  paragraphStyle.alignment = alignment
  paragraphStyle.lineBreakMode = .byWordWrapping
  paragraphStyle.lineSpacing = CGFloat(lineSpacing)

  result.addAttributes(
    [
      .font: font,
      .foregroundColor: foregroundColor,
      .paragraphStyle: paragraphStyle,
    ],
    range: fullRange)

  for run in attributed.runs {
    guard let nsRange = nsAttributedRange(for: run.range, in: attributed, string: string),
      nsRange.length > 0
    else {
      continue
    }

    if let intent = run.inlinePresentationIntent {
      var runFont = font
      if intent.contains(.code) {
        runFont = UIFont.monospacedSystemFont(
          ofSize: max(font.pointSize * 0.94, 1),
          weight: .regular)
        result.addAttribute(
          .foregroundColor,
          value: MarkdownInlineStyleApplier.inlineCodeUIColor,
          range: nsRange)
      } else {
        if intent.contains(.stronglyEmphasized) {
          runFont = runFont.withWeight(.bold)
        }
        if intent.contains(.emphasized) {
          runFont = runFont.italicized()
        }
      }
      result.addAttribute(.font, value: runFont, range: nsRange)

      if intent.contains(.strikethrough) {
        result.addAttribute(
          .strikethroughStyle,
          value: NSUnderlineStyle.single.rawValue,
          range: nsRange)
      }
    }

    if let color = run.foregroundColor {
      result.addAttribute(.foregroundColor, value: UIColor(color), range: nsRange)
    }
  }

  if strikethrough {
    result.addAttribute(
      .strikethroughStyle,
      value: NSUnderlineStyle.single.rawValue,
      range: fullRange)
  }

  return result
}

private func nsAttributedRange(
  for range: Range<AttributedString.Index>,
  in attributed: AttributedString,
  string: String
) -> NSRange? {
  let lowerOffset = attributed.characters.distance(
    from: attributed.characters.startIndex,
    to: range.lowerBound)
  let upperOffset = attributed.characters.distance(
    from: attributed.characters.startIndex,
    to: range.upperBound)
  guard
    let lowerBound = string.index(
      string.startIndex,
      offsetBy: lowerOffset,
      limitedBy: string.endIndex),
    let upperBound = string.index(
      string.startIndex,
      offsetBy: upperOffset,
      limitedBy: string.endIndex)
  else {
    return nil
  }
  return NSRange(lowerBound..<upperBound, in: string)
}

extension UIFont {
  fileprivate func withWeight(_ weight: UIFont.Weight) -> UIFont {
    var traits =
      fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any] ?? [:]
    traits[.weight] = weight.rawValue
    let descriptor = fontDescriptor.addingAttributes([.traits: traits])
    return UIFont(descriptor: descriptor, size: pointSize)
  }

  fileprivate func italicized() -> UIFont {
    guard
      let descriptor = fontDescriptor.withSymbolicTraits(
        fontDescriptor.symbolicTraits.union(.traitItalic))
    else {
      return self
    }
    return UIFont(descriptor: descriptor, size: pointSize)
  }

  fileprivate func italicizedIf(_ italic: Bool) -> UIFont {
    italic ? italicized() : self
  }
}

extension Font {
  fileprivate func italicizedIf(_ italic: Bool) -> Font {
    italic ? self.italic() : self
  }
}

private enum MarkdownInlineStyleApplier {
  static func styled(_ attributed: AttributedString, strongFont: Font? = nil) -> AttributedString {
    var result = attributed
    let runs = result.runs.map { ($0.range, $0.inlinePresentationIntent) }

    for (range, intent) in runs {
      guard let intent else { continue }
      if intent.contains(.code) {
        result[range].foregroundColor = inlineCodeColor
      } else if intent.contains(.stronglyEmphasized) {
        result[range].foregroundColor = Color.accentColor
        if let strongFont {
          result[range].font = strongFont
        }
      }
      if intent.contains(.strikethrough) {
        result[range].strikethroughStyle = .single
      }
    }

    return result
  }

  static let inlineCodeUIColor = UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(red: 1.0, green: 0.48, blue: 0.62, alpha: 1)
      : UIColor(red: 0.70, green: 0.08, blue: 0.24, alpha: 1)
  }

  private static let inlineCodeColor = Color(
    uiColor: inlineCodeUIColor)
}

private enum MarkdownInlineTokenColorizer {
  static func colorized(_ attributed: AttributedString) -> AttributedString {
    var result = attributed
    var cursor = result.characters.startIndex

    while cursor != result.characters.endIndex {
      let character = result.characters[cursor]
      guard isMarker(character), isTokenStart(in: result, at: cursor) else {
        cursor = result.characters.index(after: cursor)
        continue
      }

      let next = result.characters.index(after: cursor)
      guard next != result.characters.endIndex, isTokenBody(result.characters[next]) else {
        cursor = next
        continue
      }

      var end = result.characters.index(after: next)
      while end != result.characters.endIndex, isTokenBody(result.characters[end]) {
        end = result.characters.index(after: end)
      }

      result[cursor..<end].foregroundColor = Color.accentColor
      cursor = end
    }

    return result
  }

  private static func isMarker(_ character: Character) -> Bool {
    character == "@" || character == "#"
  }

  private static func isTokenStart(
    in attributed: AttributedString, at index: AttributedString.Index
  )
    -> Bool
  {
    guard index != attributed.characters.startIndex else { return true }
    let previous = attributed.characters.index(before: index)
    return !isTokenBody(attributed.characters[previous])
  }

  private static func isTokenBody(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "_" || character == "-"
  }
}

enum MarkdownInlineSymbols {
  static func displayString(_ raw: String) -> String {
    rewriteDelimitedMath(in: rewriteCitationRefs(in: raw))
  }

  static func toSuperscript(_ key: String) -> String {
    let map: [Character: Character] = [
      "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
      "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
    ]
    return String(key.map { map[$0] ?? $0 })
  }

  private static func rewriteCitationRefs(in raw: String) -> String {
    guard raw.contains("[^") else { return raw }
    var output = ""
    var idx = raw.startIndex
    while idx < raw.endIndex {
      guard raw[idx] == "[" else {
        output.append(raw[idx])
        idx = raw.index(after: idx)
        continue
      }
      let afterBracket = raw.index(after: idx)
      guard afterBracket < raw.endIndex, raw[afterBracket] == "^" else {
        output.append(raw[idx])
        idx = raw.index(after: idx)
        continue
      }
      var searchIdx = raw.index(after: afterBracket)
      var key = ""
      var found = false
      while searchIdx < raw.endIndex {
        let c = raw[searchIdx]
        if c == "]" {
          found = true
          break
        }
        if c == "\n" || c == "[" { break }
        key.append(c)
        searchIdx = raw.index(after: searchIdx)
      }
      if found, !key.isEmpty {
        // Skip definition lines [^key]: ...
        let afterClose = raw.index(after: searchIdx)
        if afterClose < raw.endIndex, raw[afterClose] == ":" {
          output.append(raw[idx])
          idx = raw.index(after: idx)
          continue
        }
        output += toSuperscript(key)
        idx = raw.index(after: searchIdx)
      } else {
        output.append(raw[idx])
        idx = raw.index(after: idx)
      }
    }
    return output
  }

  static func containsMathSyntax(_ raw: String) -> Bool {
    let chars = Array(raw)
    var index = 0

    while index < chars.count {
      if chars[index] == "`", let end = findUnescapedBacktick(in: chars, start: index + 1) {
        index = end + 1
        continue
      }
      if mathReplacement(in: chars, at: index) != nil {
        return true
      }
      index += 1
    }

    return false
  }

  private static func rewriteDelimitedMath(in raw: String) -> String {
    let chars = Array(raw)
    var result = ""
    var index = 0

    while index < chars.count {
      if chars[index] == "`", let end = findUnescapedBacktick(in: chars, start: index + 1) {
        result += String(chars[index...end])
        index = end + 1
        continue
      }

      if let replacement = mathReplacement(in: chars, at: index) {
        result += markdownEscaped(replacement.text)
        index = replacement.end
        continue
      }

      result.append(chars[index])
      index += 1
    }

    return result
  }

  private static func mathReplacement(in chars: [Character], at index: Int)
    -> (text: String, end: Int)?
  {
    if chars[index] == "$", !isEscaped(chars, at: index) {
      if index + 1 < chars.count, chars[index + 1] == "$",
        let end = findUnescapedDoubleDollar(in: chars, start: index + 2),
        let rewritten = rewrittenMathContent(String(chars[(index + 2)..<end]))
      {
        return (rewritten, end + 2)
      }
      if let end = findUnescapedDollar(in: chars, start: index + 1),
        let rewritten = rewrittenMathContent(String(chars[(index + 1)..<end]))
      {
        return (rewritten, end + 1)
      }
    }

    guard chars[index] == "\\", index + 1 < chars.count else { return nil }
    let opener = chars[index + 1]
    guard opener == "(" || opener == "[",
      let end = findEscapedMathClose(in: chars, start: index + 2, opener: opener),
      let rewritten = rewrittenMathContent(String(chars[(index + 2)..<end]))
    else { return nil }
    return (rewritten, end + 2)
  }

  private static func rewrittenMathContent(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard looksLikeLatexMath(trimmed) else { return nil }
    let rewritten = normalizedLatexMath(trimmed)
    return rewritten.isEmpty ? nil : rewritten
  }

  private static func looksLikeLatexMath(_ raw: String) -> Bool {
    guard !raw.isEmpty else { return false }
    if raw.contains("\\") || raw.contains("^") || raw.contains("_")
      || raw.contains("{") || raw.contains("}")
    {
      return true
    }
    if raw.count == 1, raw.first?.isLetter == true {
      return true
    }

    let chars = Array(raw)
    let operators: Set<Character> = ["=", "+", "*", "/", "<", ">", "|", "±", "×", "÷"]
    for (index, char) in chars.enumerated() {
      if operators.contains(char) {
        return true
      }
      if char == "-", hasNonNumericNeighbor(in: chars, at: index) {
        return true
      }
    }

    return false
  }

  private static func hasNonNumericNeighbor(in chars: [Character], at index: Int) -> Bool {
    let previous = nearestNonWhitespace(in: chars, before: index)
    let next = nearestNonWhitespace(in: chars, after: index)
    guard let previous, let next else { return false }
    return !previous.isNumber || !next.isNumber
  }

  private static func nearestNonWhitespace(in chars: [Character], before index: Int) -> Character? {
    guard index > 0 else { return nil }
    var cursor = index - 1
    while cursor >= 0 {
      if !chars[cursor].isWhitespace {
        return chars[cursor]
      }
      cursor -= 1
    }
    return nil
  }

  private static func nearestNonWhitespace(in chars: [Character], after index: Int) -> Character? {
    var cursor = index + 1
    while cursor < chars.count {
      if !chars[cursor].isWhitespace {
        return chars[cursor]
      }
      cursor += 1
    }
    return nil
  }

  private static func normalizedLatexMath(_ raw: String) -> String {
    var output = raw
    output = replacingLatexTextCommands(in: output)
    output = replacingLatexFractions(in: output)
    output = replacingLatexSquareRoots(in: output)
    output = replacingLatexSpacing(in: output)
    output = replacingLatexCommands(in: output)
    output = removingStandaloneLatexCommands(
      in: output,
      commands: textCommandNames.union(["left", "right", "middle"])
    )
    output = replacingLatexScripts(in: output)
    output = unescapingLatexPunctuation(in: output)
    output = output.replacingOccurrences(of: "{", with: "")
      .replacingOccurrences(of: "}", with: "")
    return output.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  private static func replacingLatexCommands(in raw: String) -> String {
    var output = raw
    for symbol in symbolsByLength {
      output = output.replacingOccurrences(of: symbol.marker, with: symbol.value)
    }
    return output
  }

  private static func replacingLatexTextCommands(in raw: String) -> String {
    replacingSingleArgumentCommands(in: raw, commands: textCommandNames) { content in
      normalizedLatexText(content)
    }
  }

  private static func normalizedLatexText(_ raw: String) -> String {
    var output = raw
    output = replacingLatexTextCommands(in: output)
    output = replacingLatexSpacing(in: output)
    output = replacingLatexCommands(in: output)
    output = unescapingLatexPunctuation(in: output)
    return output.replacingOccurrences(of: "{", with: "")
      .replacingOccurrences(of: "}", with: "")
  }

  private static func replacingSingleArgumentCommands(
    in raw: String,
    commands: Set<String>,
    transform: (String) -> String
  ) -> String {
    let chars = Array(raw)
    var output = ""
    var index = 0

    while index < chars.count {
      guard chars[index] == "\\", let command = commandName(in: chars, at: index) else {
        output.append(chars[index])
        index += 1
        continue
      }

      var cursor = index + command.count + 1
      while cursor < chars.count, chars[cursor].isWhitespace {
        cursor += 1
      }

      if commands.contains(command), cursor < chars.count, chars[cursor] == "{",
        let close = findBalancedClose(in: chars, start: cursor, open: "{", close: "}")
      {
        output += transform(String(chars[(cursor + 1)..<close]))
        index = close + 1
        continue
      }

      output.append(chars[index])
      index += 1
    }

    return output
  }

  private static func replacingLatexFractions(in raw: String) -> String {
    let chars = Array(raw)
    var output = ""
    var index = 0
    let fractionCommands: Set<String> = ["frac", "dfrac", "tfrac"]

    while index < chars.count {
      guard chars[index] == "\\", let command = commandName(in: chars, at: index),
        fractionCommands.contains(command)
      else {
        output.append(chars[index])
        index += 1
        continue
      }

      var cursor = index + command.count + 1
      while cursor < chars.count, chars[cursor].isWhitespace {
        cursor += 1
      }
      guard cursor < chars.count, chars[cursor] == "{",
        let numeratorEnd = findBalancedClose(in: chars, start: cursor, open: "{", close: "}")
      else {
        output.append(chars[index])
        index += 1
        continue
      }

      var denominatorStart = numeratorEnd + 1
      while denominatorStart < chars.count, chars[denominatorStart].isWhitespace {
        denominatorStart += 1
      }
      guard denominatorStart < chars.count, chars[denominatorStart] == "{",
        let denominatorEnd = findBalancedClose(
          in: chars,
          start: denominatorStart,
          open: "{",
          close: "}"
        )
      else {
        output.append(chars[index])
        index += 1
        continue
      }

      let numerator = normalizedLatexMath(String(chars[(cursor + 1)..<numeratorEnd]))
      let denominator = normalizedLatexMath(
        String(chars[(denominatorStart + 1)..<denominatorEnd])
      )
      output += "\(parenthesizedIfNeeded(numerator))/\(parenthesizedIfNeeded(denominator))"
      index = denominatorEnd + 1
    }

    return output
  }

  private static func replacingLatexSquareRoots(in raw: String) -> String {
    let chars = Array(raw)
    var output = ""
    var index = 0

    while index < chars.count {
      guard chars[index] == "\\", commandName(in: chars, at: index) == "sqrt" else {
        output.append(chars[index])
        index += 1
        continue
      }

      var cursor = index + 5
      var degree = ""
      if cursor < chars.count, chars[cursor] == "[",
        let close = findBalancedClose(in: chars, start: cursor, open: "[", close: "]")
      {
        degree = normalizedLatexMath(String(chars[(cursor + 1)..<close]))
        cursor = close + 1
      }
      while cursor < chars.count, chars[cursor].isWhitespace {
        cursor += 1
      }
      guard cursor < chars.count, chars[cursor] == "{",
        let close = findBalancedClose(in: chars, start: cursor, open: "{", close: "}")
      else {
        output.append(chars[index])
        index += 1
        continue
      }

      let radicand = normalizedLatexMath(String(chars[(cursor + 1)..<close]))
      output += "\(scripted(degree, superscript: true) ?? degree)√\(radicand)"
      index = close + 1
    }

    return output
  }

  private static func replacingLatexSpacing(in raw: String) -> String {
    let replacements = [
      ("\\qquad", "  "),
      ("\\quad", " "),
      ("\\,", " "),
      ("\\;", " "),
      ("\\:", " "),
      ("\\ ", " "),
      ("\\!", ""),
      ("~", " "),
    ]
    var output = raw
    for (marker, value) in replacements {
      output = output.replacingOccurrences(of: marker, with: value)
    }
    return output
  }

  private static func removingStandaloneLatexCommands(
    in raw: String,
    commands: Set<String>
  ) -> String {
    let chars = Array(raw)
    var output = ""
    var index = 0

    while index < chars.count {
      if chars[index] == "\\", let command = commandName(in: chars, at: index),
        commands.contains(command)
      {
        index += command.count + 1
        continue
      }

      output.append(chars[index])
      index += 1
    }

    return output
  }

  private static func replacingLatexScripts(in raw: String) -> String {
    let chars = Array(raw)
    var output = ""
    var index = 0

    while index < chars.count {
      let char = chars[index]
      if char == "^" || char == "_",
        let body = scriptBody(in: chars, start: index + 1)
      {
        let superscript = char == "^"
        if let scripted = scripted(body.value, superscript: superscript) {
          output += scripted
        } else {
          output.append(char)
          output += body.value
        }
        index = body.end
        continue
      }

      output.append(char)
      index += 1
    }

    return output
  }

  private static func scriptBody(in chars: [Character], start: Int) -> (value: String, end: Int)? {
    guard start < chars.count else { return nil }
    if chars[start] == "{",
      let close = findBalancedClose(in: chars, start: start, open: "{", close: "}")
    {
      return (String(chars[(start + 1)..<close]), close + 1)
    }
    return (String(chars[start]), start + 1)
  }

  private static func scripted(_ raw: String, superscript: Bool) -> String? {
    guard !raw.isEmpty else { return "" }
    let table = superscript ? superscriptCharacters : subscriptCharacters
    var output = ""
    for char in raw {
      guard let mapped = table[char] else { return nil }
      output.append(mapped)
    }
    return output
  }

  private static func unescapingLatexPunctuation(in raw: String) -> String {
    let replacements = [
      ("\\{", "{"),
      ("\\}", "}"),
      ("\\$", "$"),
      ("\\%", "%"),
      ("\\_", "_"),
      ("\\#", "#"),
      ("\\&", "&"),
    ]
    var output = raw
    for (marker, value) in replacements {
      output = output.replacingOccurrences(of: marker, with: value)
    }
    return output
  }

  private static func markdownEscaped(_ raw: String) -> String {
    var output = ""
    for char in raw {
      if "\\`*_{}[]()#+-.!".contains(char) {
        output.append("\\")
      }
      output.append(char)
    }
    return output
  }

  private static func parenthesizedIfNeeded(_ raw: String) -> String {
    let needsParens = raw.contains { char in
      char.isWhitespace || char == "+" || char == "-" || char == "="
    }
    return needsParens ? "(\(raw))" : raw
  }

  private static func commandName(in chars: [Character], at index: Int) -> String? {
    guard index < chars.count, chars[index] == "\\", index + 1 < chars.count,
      chars[index + 1].isLetter
    else {
      return nil
    }

    var cursor = index + 1
    while cursor < chars.count, chars[cursor].isLetter {
      cursor += 1
    }
    return String(chars[(index + 1)..<cursor])
  }

  private static func findBalancedClose(
    in chars: [Character],
    start: Int,
    open: Character,
    close: Character
  ) -> Int? {
    guard start < chars.count, chars[start] == open else { return nil }
    var depth = 0
    var cursor = start
    while cursor < chars.count {
      if chars[cursor] == open, !isEscaped(chars, at: cursor) {
        depth += 1
      } else if chars[cursor] == close, !isEscaped(chars, at: cursor) {
        depth -= 1
        if depth == 0 {
          return cursor
        }
      }
      cursor += 1
    }
    return nil
  }

  private static func findUnescapedDollar(in chars: [Character], start: Int) -> Int? {
    var cursor = start
    while cursor < chars.count {
      if chars[cursor] == "$", !isEscaped(chars, at: cursor) {
        return cursor
      }
      cursor += 1
    }
    return nil
  }

  private static func findUnescapedDoubleDollar(in chars: [Character], start: Int) -> Int? {
    var cursor = start
    while cursor + 1 < chars.count {
      if chars[cursor] == "$", chars[cursor + 1] == "$", !isEscaped(chars, at: cursor) {
        return cursor
      }
      cursor += 1
    }
    return nil
  }

  private static func findUnescapedBacktick(in chars: [Character], start: Int) -> Int? {
    var cursor = start
    while cursor < chars.count {
      if chars[cursor] == "`", !isEscaped(chars, at: cursor) {
        return cursor
      }
      cursor += 1
    }
    return nil
  }

  private static func findEscapedMathClose(
    in chars: [Character], start: Int, opener: Character
  ) -> Int? {
    let closer: Character = opener == "(" ? ")" : "]"
    var cursor = start
    while cursor + 1 < chars.count {
      if chars[cursor] == "\\", chars[cursor + 1] == closer {
        return cursor
      }
      cursor += 1
    }
    return nil
  }

  private static func isEscaped(_ chars: [Character], at index: Int) -> Bool {
    guard index > 0 else { return false }
    var slashCount = 0
    var cursor = index - 1
    while cursor >= 0, chars[cursor] == "\\" {
      slashCount += 1
      cursor -= 1
    }
    return !slashCount.isMultiple(of: 2)
  }

  private static let textCommandNames: Set<String> = [
    "text", "textrm", "textnormal", "textit", "textbf", "texttt", "mathrm", "mathit",
    "mathbf", "mathsf", "mathtt", "operatorname",
  ]

  private static let superscriptCharacters: [Character: Character] = [
    "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷",
    "8": "⁸", "9": "⁹", "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
    "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ", "g": "ᵍ",
    "h": "ʰ", "i": "ⁱ", "j": "ʲ", "k": "ᵏ", "l": "ˡ", "m": "ᵐ", "n": "ⁿ",
    "o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ", "t": "ᵗ", "u": "ᵘ", "v": "ᵛ",
    "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ",
  ]

  private static let subscriptCharacters: [Character: Character] = [
    "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇",
    "8": "₈", "9": "₉", "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
    "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ",
    "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ",
    "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
  ]

  private static let symbolsByLength = symbols.sorted { $0.marker.count > $1.marker.count }

  private static let symbols: [(marker: String, value: String)] = [
    ("\\Longleftrightarrow", "⟺"),
    ("\\Longrightarrow", "⟹"),
    ("\\Longleftarrow", "⟸"),
    ("\\longleftrightarrow", "⟷"),
    ("\\longrightarrow", "⟶"),
    ("\\longleftarrow", "⟵"),
    ("\\Leftrightarrow", "⇔"),
    ("\\leftrightarrow", "↔"),
    ("\\nleftrightarrow", "↮"),
    ("\\hookrightarrow", "↪"),
    ("\\hookleftarrow", "↩"),
    ("\\rightharpoonup", "⇀"),
    ("\\leftharpoonup", "↼"),
    ("\\rightharpoondown", "⇁"),
    ("\\leftharpoondown", "↽"),
    ("\\rightleftharpoons", "⇌"),
    ("\\leftrightharpoons", "⇋"),
    ("\\rightarrow", "→"),
    ("\\leftarrow", "←"),
    ("\\Rightarrow", "⇒"),
    ("\\Leftarrow", "⇐"),
    ("\\nrightarrow", "↛"),
    ("\\nleftarrow", "↚"),
    ("\\uparrow", "↑"),
    ("\\downarrow", "↓"),
    ("\\updownarrow", "↕"),
    ("\\Uparrow", "⇑"),
    ("\\Downarrow", "⇓"),
    ("\\Updownarrow", "⇕"),
    ("\\mapsto", "↦"),
    ("\\nearrow", "↗"),
    ("\\searrow", "↘"),
    ("\\swarrow", "↙"),
    ("\\nwarrow", "↖"),
    ("\\gets", "←"),
    ("\\to", "→"),

    ("\\varepsilon", "ϵ"),
    ("\\vartheta", "ϑ"),
    ("\\varkappa", "ϰ"),
    ("\\varlambda", "λ"),
    ("\\varrho", "ϱ"),
    ("\\varsigma", "ς"),
    ("\\varphi", "ϕ"),
    ("\\varpi", "ϖ"),
    ("\\Gamma", "Γ"),
    ("\\Delta", "Δ"),
    ("\\Theta", "Θ"),
    ("\\Lambda", "Λ"),
    ("\\Xi", "Ξ"),
    ("\\Pi", "Π"),
    ("\\Sigma", "Σ"),
    ("\\Upsilon", "Υ"),
    ("\\Phi", "Φ"),
    ("\\Psi", "Ψ"),
    ("\\Omega", "Ω"),
    ("\\alpha", "α"),
    ("\\beta", "β"),
    ("\\gamma", "γ"),
    ("\\delta", "δ"),
    ("\\epsilon", "ε"),
    ("\\zeta", "ζ"),
    ("\\eta", "η"),
    ("\\theta", "θ"),
    ("\\iota", "ι"),
    ("\\kappa", "κ"),
    ("\\lambda", "λ"),
    ("\\mu", "μ"),
    ("\\nu", "ν"),
    ("\\xi", "ξ"),
    ("\\omicron", "ο"),
    ("\\pi", "π"),
    ("\\rho", "ρ"),
    ("\\sigma", "σ"),
    ("\\tau", "τ"),
    ("\\upsilon", "υ"),
    ("\\phi", "φ"),
    ("\\chi", "χ"),
    ("\\psi", "ψ"),
    ("\\omega", "ω"),

    ("\\nsubseteq", "⊈"),
    ("\\nsupseteq", "⊉"),
    ("\\subseteq", "⊆"),
    ("\\supseteq", "⊇"),
    ("\\subsetneq", "⊊"),
    ("\\supsetneq", "⊋"),
    ("\\subset", "⊂"),
    ("\\supset", "⊃"),
    ("\\notin", "∉"),
    ("\\in", "∈"),
    ("\\ni", "∋"),
    ("\\owns", "∋"),
    ("\\emptyset", "∅"),
    ("\\varnothing", "∅"),
    ("\\cup", "∪"),
    ("\\cap", "∩"),
    ("\\setminus", "∖"),
    ("\\smallsetminus", "∖"),
    ("\\forall", "∀"),
    ("\\exists", "∃"),
    ("\\nexists", "∄"),
    ("\\therefore", "∴"),
    ("\\because", "∵"),
    ("\\land", "∧"),
    ("\\wedge", "∧"),
    ("\\lor", "∨"),
    ("\\vee", "∨"),
    ("\\neg", "¬"),
    ("\\lnot", "¬"),
    ("\\top", "⊤"),
    ("\\bot", "⊥"),
    ("\\models", "⊨"),
    ("\\vdash", "⊢"),
    ("\\dashv", "⊣"),

    ("\\leq", "≤"),
    ("\\le", "≤"),
    ("\\geq", "≥"),
    ("\\ge", "≥"),
    ("\\neq", "≠"),
    ("\\ne", "≠"),
    ("\\equiv", "≡"),
    ("\\not\\equiv", "≢"),
    ("\\approx", "≈"),
    ("\\approxeq", "≊"),
    ("\\simeq", "≃"),
    ("\\sim", "∼"),
    ("\\cong", "≅"),
    ("\\propto", "∝"),
    ("\\ll", "≪"),
    ("\\gg", "≫"),
    ("\\prec", "≺"),
    ("\\succ", "≻"),
    ("\\preceq", "≼"),
    ("\\succeq", "≽"),
    ("\\parallel", "∥"),
    ("\\nparallel", "∦"),
    ("\\perp", "⟂"),
    ("\\asymp", "≍"),

    ("\\times", "×"),
    ("\\div", "÷"),
    ("\\pm", "±"),
    ("\\mp", "∓"),
    ("\\cdot", "·"),
    ("\\circ", "∘"),
    ("\\bullet", "•"),
    ("\\ast", "∗"),
    ("\\star", "★"),
    ("\\oplus", "⊕"),
    ("\\ominus", "⊖"),
    ("\\otimes", "⊗"),
    ("\\oslash", "⊘"),
    ("\\odot", "⊙"),
    ("\\sqrt", "√"),
    ("\\partial", "∂"),
    ("\\nabla", "∇"),
    ("\\int", "∫"),
    ("\\iint", "∬"),
    ("\\iiint", "∭"),
    ("\\oint", "∮"),
    ("\\sum", "∑"),
    ("\\prod", "∏"),
    ("\\coprod", "∐"),
    ("\\infty", "∞"),
    ("\\prime", "′"),
    ("\\doubleprime", "″"),
    ("\\ldots", "…"),
    ("\\dots", "…"),
    ("\\cdots", "⋯"),
    ("\\vdots", "⋮"),
    ("\\ddots", "⋱"),
    ("\\degree", "°"),

    ("\\angle", "∠"),
    ("\\measuredangle", "∡"),
    ("\\triangle", "△"),
    ("\\triangleleft", "◁"),
    ("\\triangleright", "▷"),
    ("\\diamond", "⋄"),
    ("\\Diamond", "◇"),
    ("\\square", "□"),
    ("\\Box", "□"),
    ("\\blacksquare", "■"),
    ("\\langle", "⟨"),
    ("\\rangle", "⟩"),
    ("\\lfloor", "⌊"),
    ("\\rfloor", "⌋"),
    ("\\lceil", "⌈"),
    ("\\rceil", "⌉"),
    ("\\Re", "ℜ"),
    ("\\Im", "ℑ"),
    ("\\aleph", "ℵ"),
    ("\\hbar", "ℏ"),
    ("\\ell", "ℓ"),
    ("\\wp", "℘"),
    ("\\dagger", "†"),
    ("\\ddagger", "‡"),
  ]
}

struct MarkdownTableView: View {
  @Environment(\.isFullChatScreenshotRendering) private var isFullChatScreenshotRendering

  let headers: [String]
  let rows: [[String]]
  let alignments: [TextAlignment]
  let appearance: AppearanceSettings
  var fontFamily: AppearanceFontFamily
  let allowsTextSelection: Bool
  let foregroundStyle: Color?
  let uiForegroundColor: UIColor?
  let italic: Bool

  init(
    headers: [String],
    rows: [[String]],
    alignments: [TextAlignment],
    appearance: AppearanceSettings,
    fontFamily: AppearanceFontFamily? = nil,
    allowsTextSelection: Bool = true,
    foregroundStyle: Color? = nil,
    uiForegroundColor: UIColor? = nil,
    italic: Bool = false
  ) {
    self.headers = headers
    self.rows = rows
    self.alignments = alignments
    self.appearance = appearance
    self.fontFamily = fontFamily ?? appearance.assistantFontFamily
    self.allowsTextSelection = allowsTextSelection
    self.foregroundStyle = foregroundStyle
    self.uiForegroundColor = uiForegroundColor
    self.italic = italic
  }

  var body: some View {
    if appearance.unwrappedTables && !isFullChatScreenshotRendering {
      ScrollView(.horizontal, showsIndicators: true) {
        tableGrid(unwrapped: true)
      }
    } else {
      tableGrid(unwrapped: false)
    }
  }

  private func tableGrid(unwrapped: Bool) -> some View {
    Grid(
      alignment: .topLeading,
      horizontalSpacing: 0,
      verticalSpacing: 0
    ) {
      GridRow {
        ForEach(Array(headers.enumerated()), id: \.offset) { idx, header in
          cellView(header, columnIndex: idx, isHeader: true, unwrapped: unwrapped)
        }
      }
      .background(Color.secondary.opacity(0.10))
      Divider().opacity(0.5)
      ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
        GridRow {
          ForEach(0..<headers.count, id: \.self) { idx in
            let value = idx < row.count ? row[idx] : ""
            cellView(value, columnIndex: idx, isHeader: false, unwrapped: unwrapped)
          }
        }
        .background(rowIdx.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.05))
        if rowIdx < rows.count - 1 {
          Divider().opacity(0.25)
        }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(.secondary.opacity(0.25), lineWidth: 0.5)
    )
  }

  @ViewBuilder
  private func cellView(_ value: String, columnIndex: Int, isHeader: Bool, unwrapped: Bool)
    -> some View
  {
    let alignment = columnIndex < alignments.count ? alignments[columnIndex] : .leading
    let maxWidth: CGFloat? = unwrapped ? nil : .infinity
    MarkdownInlineText(
      value: value,
      appearance: appearance,
      font: isHeader
        ? fontFamily.swiftUIFont(size: appearance.fontSize).weight(.semibold)
        : fontFamily.swiftUIFont(size: appearance.fontSize),
      uiFont: isHeader
        ? fontFamily.uiFont(size: appearance.fontSize).withWeight(.semibold)
        : fontFamily.uiFont(size: appearance.fontSize),
      allowsTextSelection: allowsTextSelection,
      textAlignment: alignment,
      foregroundStyle: foregroundStyle,
      uiForegroundColor: uiForegroundColor,
      allowsJustification: !unwrapped,
      italic: italic
    )
    .fixedSize(horizontal: unwrapped, vertical: false)
    .frame(maxWidth: maxWidth, alignment: frameAlignment(alignment))
    .padding(.horizontal, appearance.markdownMetric(10))
    .padding(.vertical, appearance.markdownMetric(8))
  }

  private func frameAlignment(_ alignment: TextAlignment) -> Alignment {
    switch alignment {
    case .leading: return .leading
    case .center: return .center
    case .trailing: return .trailing
    }
  }
}

struct CodeBlockView: View {
  @Environment(\.isFullChatScreenshotRendering) private var isFullChatScreenshotRendering

  let language: String
  let code: String
  let appearance: AppearanceSettings
  let allowsTextSelection: Bool

  @State private var showingCodePreview = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(language.isEmpty ? "code" : language)
          .font(.caption.monospaced().weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        if !isFullChatScreenshotRendering {
          Button {
            showingCodePreview = true
          } label: {
            Image(systemName: "eye")
          }
          .buttonStyle(.glass)
          .help("View code")
          Button {
            UIPasteboard.general.string = code
          } label: {
            Image(systemName: "doc.on.doc")
          }
          .buttonStyle(.glass)
          .help("Copy code")
        }
      }
      .padding(.horizontal, appearance.markdownMetric(10))
      .padding(.vertical, appearance.markdownMetric(7))
      Divider()
      if isFullChatScreenshotRendering {
        Text(SyntaxHighlighter.highlight(code, language: language))
          .font(appearance.codeFont)
          .lineSpacing(CGFloat(appearance.lineSpacing))
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(appearance.markdownMetric(12))
      } else {
        ScrollView(.horizontal, showsIndicators: true) {
          Text(SyntaxHighlighter.highlight(code, language: language))
            .font(appearance.codeFont)
            .lineSpacing(CGFloat(appearance.lineSpacing))
            .textSelectionIfEnabled(allowsTextSelection)
            .padding(appearance.markdownMetric(12))
            .fixedSize(horizontal: true, vertical: true)
        }
      }
    }
    .sheet(isPresented: $showingCodePreview) {
      MessageTextSelectionSheet(
        title: codePreviewTitle,
        text: code,
        initialFontSize: AppearanceSettings.clampedFontSize(appearance.fontSize - 1),
        initialLineSpacing: appearance.lineSpacing,
        fontFamily: .monospaced)
    }
    .background(.thinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(.secondary.opacity(0.18), lineWidth: 1)
    }
  }

  private var codePreviewTitle: String {
    let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Code" : trimmed
  }
}

struct TaskListItem: Identifiable {
  let id = UUID()
  let text: String
  let checked: Bool
}

struct OrderedListItem: Identifiable {
  let id = UUID()
  let number: Int
  let delimiter: String
  let text: String
}

extension OrderedListItem {
  var marker: String { "\(number)\(delimiter)" }
}

struct TaskListView: View {
  let items: [TaskListItem]
  let appearance: AppearanceSettings
  var fontFamily: AppearanceFontFamily
  let allowsTextSelection: Bool
  let foregroundStyle: Color?
  let uiForegroundColor: UIColor?
  let italic: Bool

  init(
    items: [TaskListItem],
    appearance: AppearanceSettings,
    fontFamily: AppearanceFontFamily? = nil,
    allowsTextSelection: Bool = true,
    foregroundStyle: Color? = nil,
    uiForegroundColor: UIColor? = nil,
    italic: Bool = false
  ) {
    self.items = items
    self.appearance = appearance
    self.fontFamily = fontFamily ?? appearance.assistantFontFamily
    self.allowsTextSelection = allowsTextSelection
    self.foregroundStyle = foregroundStyle
    self.uiForegroundColor = uiForegroundColor
    self.italic = italic
  }

  var body: some View {
    let textFont = fontFamily.swiftUIFont(size: appearance.fontSize)
    let markerWidth = appearance.markdownListMarkerWidth(markerLength: 1, minimum: 20)
    VStack(alignment: .leading, spacing: appearance.markdownMetric(6)) {
      ForEach(items) { item in
        HStack(alignment: .firstTextBaseline, spacing: appearance.markdownMetric(8)) {
          Image(systemName: item.checked ? "checkmark.square.fill" : "square")
            .font(.system(size: appearance.fontSize * 0.95))
            .foregroundStyle(item.checked ? Color.accentColor : Color.secondary)
            .imageScale(.medium)
            .frame(width: markerWidth, alignment: .trailing)
            .accessibilityLabel(item.checked ? "Checked" : "Unchecked")
          MarkdownInlineText(
            value: item.text,
            appearance: appearance,
            font: textFont,
            uiFont: fontFamily.uiFont(size: appearance.fontSize),
            allowsTextSelection: allowsTextSelection,
            foregroundStyle: item.checked ? .secondary : foregroundStyle,
            uiForegroundColor: item.checked ? .secondaryLabel : uiForegroundColor,
            strikethrough: item.checked,
            italic: italic
          )
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

struct BulletListView: View {
  let items: [String]
  let appearance: AppearanceSettings
  var fontFamily: AppearanceFontFamily
  let allowsTextSelection: Bool
  let foregroundStyle: Color?
  let uiForegroundColor: UIColor?
  let italic: Bool

  init(
    items: [String],
    appearance: AppearanceSettings,
    fontFamily: AppearanceFontFamily? = nil,
    allowsTextSelection: Bool = true,
    foregroundStyle: Color? = nil,
    uiForegroundColor: UIColor? = nil,
    italic: Bool = false
  ) {
    self.items = items
    self.appearance = appearance
    self.fontFamily = fontFamily ?? appearance.assistantFontFamily
    self.allowsTextSelection = allowsTextSelection
    self.foregroundStyle = foregroundStyle
    self.uiForegroundColor = uiForegroundColor
    self.italic = italic
  }

  var body: some View {
    let textFont = fontFamily.swiftUIFont(size: appearance.fontSize)
    let markerWidth = appearance.markdownListMarkerWidth(markerLength: 1)
    VStack(alignment: .leading, spacing: appearance.markdownMetric(6)) {
      ForEach(Array(items.enumerated()), id: \.offset) { _, item in
        HStack(alignment: .firstTextBaseline, spacing: appearance.markdownMetric(8)) {
          Text("•")
            .font(textFont.italicizedIf(italic))
            .foregroundStyle(.secondary)
            .frame(width: markerWidth, alignment: .trailing)
          MarkdownInlineText(
            value: item,
            appearance: appearance,
            font: textFont,
            uiFont: fontFamily.uiFont(size: appearance.fontSize),
            allowsTextSelection: allowsTextSelection,
            foregroundStyle: foregroundStyle,
            uiForegroundColor: uiForegroundColor,
            italic: italic
          )
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

struct OrderedListView: View {
  let items: [OrderedListItem]
  let appearance: AppearanceSettings
  var fontFamily: AppearanceFontFamily
  let allowsTextSelection: Bool
  let foregroundStyle: Color?
  let uiForegroundColor: UIColor?
  let italic: Bool

  init(
    items: [OrderedListItem],
    appearance: AppearanceSettings,
    fontFamily: AppearanceFontFamily? = nil,
    allowsTextSelection: Bool = true,
    foregroundStyle: Color? = nil,
    uiForegroundColor: UIColor? = nil,
    italic: Bool = false
  ) {
    self.items = items
    self.appearance = appearance
    self.fontFamily = fontFamily ?? appearance.assistantFontFamily
    self.allowsTextSelection = allowsTextSelection
    self.foregroundStyle = foregroundStyle
    self.uiForegroundColor = uiForegroundColor
    self.italic = italic
  }

  var body: some View {
    let textFont = fontFamily.swiftUIFont(size: appearance.fontSize)
    let markerLength = items.map { $0.marker.count }.max() ?? 2
    let markerWidth = appearance.markdownListMarkerWidth(markerLength: markerLength)
    VStack(alignment: .leading, spacing: appearance.markdownMetric(6)) {
      ForEach(items) { item in
        HStack(alignment: .firstTextBaseline, spacing: appearance.markdownMetric(8)) {
          Text(item.marker)
            .font(textFont.italicizedIf(italic))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(width: markerWidth, alignment: .trailing)
          MarkdownInlineText(
            value: item.text,
            appearance: appearance,
            font: textFont,
            uiFont: fontFamily.uiFont(size: appearance.fontSize),
            allowsTextSelection: allowsTextSelection,
            foregroundStyle: foregroundStyle,
            uiForegroundColor: uiForegroundColor,
            italic: italic
          )
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

struct BlockquoteView: View {
  @Environment(\.markdownRenderImages) private var renderImages

  let text: String
  let appearance: AppearanceSettings
  var fontFamily: AppearanceFontFamily
  let allowsTextSelection: Bool
  let italic: Bool

  init(
    text: String,
    appearance: AppearanceSettings,
    fontFamily: AppearanceFontFamily? = nil,
    allowsTextSelection: Bool = true,
    italic: Bool = false
  ) {
    self.text = text
    self.appearance = appearance
    self.fontFamily = fontFamily ?? appearance.assistantFontFamily
    self.allowsTextSelection = allowsTextSelection
    self.italic = italic
  }

  var body: some View {
    HStack(alignment: .top, spacing: appearance.markdownMetric(10)) {
      RoundedRectangle(cornerRadius: 1.5, style: .continuous)
        .fill(Color.secondary.opacity(0.45))
        .frame(width: appearance.markdownMetric(3))
      MarkdownContentView(
        text: text,
        appearance: appearance,
        fontFamily: fontFamily,
        allowsTextSelection: allowsTextSelection,
        foregroundStyle: .secondary,
        uiForegroundColor: .secondaryLabel,
        renderImages: renderImages,
        italic: italic)
    }
    .padding(.vertical, appearance.markdownMetric(2))
  }
}

private struct FootnotesView: View {
  let items: [(key: String, text: String)]
  let appearance: AppearanceSettings
  let fontFamily: AppearanceFontFamily
  let allowsTextSelection: Bool
  let foregroundStyle: Color?
  let uiForegroundColor: UIColor?
  let italic: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: appearance.markdownMetric(3)) {
      Divider()
        .overlay(Color.secondary.opacity(0.25))
      ForEach(Array(items.enumerated()), id: \.offset) { _, item in
        MarkdownInlineText(
          value: "\(MarkdownInlineSymbols.toSuperscript(item.key)) \(item.text)",
          appearance: appearance,
          font: fontFamily.swiftUIFont(size: appearance.fontSize * 0.82),
          uiFont: fontFamily.uiFont(size: appearance.fontSize * 0.82),
          allowsTextSelection: allowsTextSelection,
          foregroundStyle: foregroundStyle ?? Color.secondary,
          uiForegroundColor: uiForegroundColor ?? .secondaryLabel,
          italic: italic)
      }
    }
  }
}

struct MarkdownBlock: Identifiable {
  enum Kind {
    case heading(level: Int, text: String)
    case text(String)
    case blockquote(String)
    case horizontalRule
    case code(language: String, code: String)
    case table(headers: [String], rows: [[String]], alignments: [TextAlignment])
    case taskList(items: [TaskListItem])
    case bulletList(items: [String])
    case orderedList(items: [OrderedListItem])
    case footnotes(items: [(key: String, text: String)])
  }

  let id = UUID()
  var kind: Kind
}

enum MarkdownParser {
  static func mayContainMarkdown(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    if containsBlockquoteLine(text) || containsHorizontalRuleLine(text)
      || containsOrderedListLine(text)
      || MarkdownInlineSymbols.containsMathSyntax(text)
    {
      return true
    }
    let markers = ["```", "`", "**", "__", "- ", "* ", "+ ", "- [", "* [", "|", "[", "#"]
    return markers.contains { text.contains($0) }
  }

  static func blocks(from text: String) -> [MarkdownBlock] {
    let lines = text.components(separatedBy: .newlines)
    var blocks: [MarkdownBlock] = []
    var textBuffer: [String] = []
    var codeBuffer: [String] = []
    var language = ""
    var inCode = false
    var index = 0

    func flushText() {
      let value = textBuffer.joined(separator: "\n").trimmingCharacters(in: .newlines)
      if !value.isEmpty {
        blocks.append(MarkdownBlock(kind: .text(value)))
      }
      textBuffer.removeAll()
    }

    func flushCode() {
      let code = codeBuffer.joined(separator: "\n")
      if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        blocks.append(MarkdownBlock(kind: .code(language: language, code: code)))
      }
      codeBuffer.removeAll()
      language = ""
    }

    func collectItems<T>(
      first: T,
      after index: Int,
      parse: (String) -> T?
    ) -> (items: [T], nextIndex: Int) {
      var items: [T] = [first]
      var cursor = index + 1
      while cursor < lines.count {
        guard let item = parse(lines[cursor]) else { break }
        items.append(item)
        cursor += 1
      }
      return (items, cursor)
    }

    func parseTrimmed<T>(_ line: String, with parser: (String) -> T?) -> T? {
      parser(line.trimmingCharacters(in: .whitespaces))
    }

    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      if trimmed.hasPrefix("```") {
        if inCode {
          flushCode()
          inCode = false
        } else {
          flushText()
          language = String(trimmed.dropFirst(3))
          inCode = true
        }
        index += 1
        continue
      }

      if inCode {
        codeBuffer.append(line)
        index += 1
        continue
      }

      if let firstLine = blockquoteLine(line) {
        flushText()
        let block = collectItems(first: firstLine, after: index, parse: blockquoteLine)
        blocks.append(
          MarkdownBlock(kind: .blockquote(block.items.joined(separator: "\n")))
        )
        index = block.nextIndex
        continue
      }

      if let heading = heading(trimmed) {
        flushText()
        blocks.append(MarkdownBlock(kind: .heading(level: heading.level, text: heading.text)))
        index += 1
        continue
      }

      if isHorizontalRule(trimmed) {
        flushText()
        blocks.append(MarkdownBlock(kind: .horizontalRule))
        index += 1
        continue
      }

      if let firstItem = taskListItem(trimmed) {
        flushText()
        let block = collectItems(first: firstItem, after: index) {
          parseTrimmed($0, with: taskListItem)
        }
        blocks.append(MarkdownBlock(kind: .taskList(items: block.items)))
        index = block.nextIndex
        continue
      }

      if let firstItem = orderedListItem(trimmed) {
        flushText()
        let block = collectItems(first: firstItem, after: index) {
          parseTrimmed($0, with: orderedListItem)
        }
        blocks.append(MarkdownBlock(kind: .orderedList(items: block.items)))
        index = block.nextIndex
        continue
      }

      if let firstItem = bulletListItem(trimmed) {
        flushText()
        let block = collectItems(first: firstItem, after: index) {
          parseTrimmed($0, with: bulletListItem)
        }
        blocks.append(MarkdownBlock(kind: .bulletList(items: block.items)))
        index = block.nextIndex
        continue
      }

      if let firstItem = footnoteDefinition(trimmed) {
        flushText()
        let block = collectItems(first: firstItem, after: index) {
          parseTrimmed($0, with: footnoteDefinition)
        }
        blocks.append(MarkdownBlock(kind: .footnotes(items: block.items)))
        index = block.nextIndex
        continue
      }

      if Self.containsTablePipe(trimmed),
        index + 1 < lines.count,
        let alignments = tableAlignments(
          lines[index + 1].trimmingCharacters(in: .whitespaces)
        )
      {
        let headers = splitTableRow(trimmed)
        if headers.count == alignments.count, !headers.isEmpty {
          flushText()
          var rows: [[String]] = []
          var cursor = index + 2
          while cursor < lines.count {
            let rowTrimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            guard Self.containsTablePipe(rowTrimmed), tableAlignments(rowTrimmed) == nil else {
              break
            }
            var cells = splitTableRow(rowTrimmed)
            while cells.count < headers.count { cells.append("") }
            if cells.count > headers.count { cells = Array(cells.prefix(headers.count)) }
            rows.append(cells)
            cursor += 1
          }
          blocks.append(
            MarkdownBlock(
              kind: .table(headers: headers, rows: rows, alignments: alignments)
            )
          )
          index = cursor
          continue
        }
      }

      textBuffer.append(line)
      index += 1
    }
    if inCode {
      flushCode()
    }
    flushText()
    return blocks.isEmpty ? [MarkdownBlock(kind: .text(text))] : blocks
  }

  private static func footnoteDefinition(_ trimmed: String) -> (key: String, text: String)? {
    guard trimmed.hasPrefix("[^") else { return nil }
    guard let closeBracket = trimmed.firstIndex(of: "]") else { return nil }
    let afterClose = trimmed.index(after: closeBracket)
    guard afterClose < trimmed.endIndex, trimmed[afterClose] == ":" else { return nil }
    let key = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<closeBracket])
    guard !key.isEmpty else { return nil }
    var textStart = trimmed.index(after: afterClose)
    if textStart < trimmed.endIndex, trimmed[textStart] == " " {
      textStart = trimmed.index(after: textStart)
    }
    return (key: key, text: String(trimmed[textStart...]))
  }

  private static func containsBlockquoteLine(_ text: String) -> Bool {
    text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
      line.drop(while: { $0 == " " || $0 == "\t" }).first == ">"
    }
  }

  private static func containsHorizontalRuleLine(_ text: String) -> Bool {
    text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
      isHorizontalRule(String(line).trimmingCharacters(in: .whitespaces))
    }
  }

  private static func containsOrderedListLine(_ text: String) -> Bool {
    text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
      orderedListItem(String(line).trimmingCharacters(in: .whitespaces)) != nil
    }
  }

  private static func blockquoteLine(_ line: String) -> String? {
    var text = line.drop(while: { $0 == " " || $0 == "\t" })
    guard text.first == ">" else { return nil }
    text = text.dropFirst()
    if text.first == " " {
      text = text.dropFirst()
    }
    return String(text)
  }

  private static func heading(_ trimmed: String) -> (level: Int, text: String)? {
    guard trimmed.hasPrefix("#") else { return nil }
    let level = trimmed.prefix(while: { $0 == "#" }).count
    guard (1...6).contains(level), trimmed.count > level else { return nil }
    let separatorIndex = trimmed.index(trimmed.startIndex, offsetBy: level)
    guard trimmed[separatorIndex] == " " else { return nil }
    let text = trimmed[trimmed.index(after: separatorIndex)...]
      .trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : (level, text)
  }

  private static func isHorizontalRule(_ trimmed: String) -> Bool {
    guard trimmed.count >= 3, let first = trimmed.first,
      first == "-" || first == "_" || first == "*"
    else { return false }
    return trimmed.allSatisfy { $0 == first }
  }

  private static func taskListItem(_ trimmed: String) -> TaskListItem? {
    let bulletMarkers: [Character] = ["-", "*", "+"]
    guard let first = trimmed.first, bulletMarkers.contains(first) else { return nil }
    var rest = trimmed.dropFirst()
    guard rest.first == " " else { return nil }
    rest = rest.drop(while: { $0 == " " })
    guard rest.first == "[", rest.count >= 3 else { return nil }
    let mark = rest[rest.index(after: rest.startIndex)]
    let closeIndex = rest.index(rest.startIndex, offsetBy: 2)
    guard rest[closeIndex] == "]" else { return nil }
    let checked: Bool
    switch mark {
    case " ": checked = false
    case "x", "X": checked = true
    default: return nil
    }
    var text = rest.dropFirst(3)
    if let space = text.first, space != " " && !text.isEmpty { return nil }
    text = text.drop(while: { $0 == " " })
    return TaskListItem(text: String(text), checked: checked)
  }

  private static func bulletListItem(_ trimmed: String) -> String? {
    let bulletMarkers: [Character] = ["-", "*", "+"]
    guard let first = trimmed.first, bulletMarkers.contains(first) else { return nil }
    var rest = trimmed.dropFirst()
    guard rest.first == " " else { return nil }
    rest = rest.drop(while: { $0 == " " })
    guard !rest.isEmpty else { return nil }
    return String(rest)
  }

  private static func orderedListItem(_ trimmed: String) -> OrderedListItem? {
    var cursor = trimmed.startIndex
    var digits = ""
    while cursor < trimmed.endIndex, trimmed[cursor].isNumber, digits.count < 9 {
      digits.append(trimmed[cursor])
      cursor = trimmed.index(after: cursor)
    }
    guard !digits.isEmpty, cursor < trimmed.endIndex else { return nil }
    let delimiter = trimmed[cursor]
    guard delimiter == "." || delimiter == ")" else { return nil }
    cursor = trimmed.index(after: cursor)
    guard cursor < trimmed.endIndex, trimmed[cursor].isWhitespace else { return nil }
    let text = trimmed[cursor...].drop(while: \.isWhitespace)
    guard !text.isEmpty, let number = Int(digits) else { return nil }
    return OrderedListItem(number: number, delimiter: String(delimiter), text: String(text))
  }

  private static func normalizeTablePipes(_ line: String) -> String {
    var result = line
    for ch in ["\u{2502}", "\u{2503}", "\u{FF5C}"] {
      if result.contains(ch) {
        result = result.replacingOccurrences(of: ch, with: "|")
      }
    }
    return result
  }

  static func containsTablePipe(_ line: String) -> Bool {
    line.contains("|") || line.contains("\u{2502}") || line.contains("\u{2503}")
      || line.contains("\u{FF5C}")
  }

  private static func splitTableRow(_ line: String) -> [String] {
    var s = normalizeTablePipes(line)
    if s.hasPrefix("|") { s.removeFirst() }
    if s.hasSuffix("|") { s.removeLast() }
    let placeholder = "\u{1}"
    s = s.replacingOccurrences(of: "\\|", with: placeholder)
    return s.components(separatedBy: "|").map {
      $0.replacingOccurrences(of: placeholder, with: "|")
        .trimmingCharacters(in: .whitespaces)
    }
  }

  private static func tableAlignments(_ line: String) -> [TextAlignment]? {
    let normalized = normalizeTablePipes(line)
    guard normalized.contains("|"), normalized.contains("-") else { return nil }
    let cells = splitTableRow(normalized)
    guard !cells.isEmpty else { return nil }
    var alignments: [TextAlignment] = []
    for cell in cells {
      let trimmed = cell.trimmingCharacters(in: .whitespaces)
      let leading = trimmed.hasPrefix(":")
      let trailing = trimmed.hasSuffix(":")
      let core = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
      guard !core.isEmpty, core.allSatisfy({ $0 == "-" }) else { return nil }
      if leading && trailing {
        alignments.append(.center)
      } else if trailing {
        alignments.append(.trailing)
      } else {
        alignments.append(.leading)
      }
    }
    return alignments
  }
}

enum SyntaxHighlighter {
  static func highlight(_ code: String, language: String) -> AttributedString {
    var output = AttributedString()
    var token = ""

    func appendToken() {
      guard !token.isEmpty else { return }
      var part = AttributedString(token)
      part.foregroundColor = color(for: token, language: language)
      output.append(part)
      token.removeAll()
    }

    for character in code {
      if character.isLetter || character.isNumber || character == "_" {
        token.append(character)
      } else {
        appendToken()
        var part = AttributedString(String(character))
        part.foregroundColor = .primary
        output.append(part)
      }
    }
    appendToken()
    return output
  }

  private static func color(for token: String, language: String) -> Color {
    let keywords: Set<String> = [
      "actor", "as", "async", "await", "case", "catch", "class", "const", "default", "defer", "do",
      "else",
      "enum", "export", "false", "final", "for", "func", "function", "guard", "if", "import", "in",
      "let",
      "nil", "null", "private", "public", "return", "self", "static", "struct", "switch", "throw",
      "throws",
      "true", "try", "var", "while",
    ]
    if keywords.contains(token) {
      return .purple
    }
    if token.allSatisfy(\.isNumber) {
      return .orange
    }
    if token.hasPrefix("//") || token.hasPrefix("#") {
      return .secondary
    }
    return .primary
  }
}
