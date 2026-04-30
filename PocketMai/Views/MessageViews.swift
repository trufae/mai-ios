import SwiftUI
import UIKit

struct MessageBubble: View {
  @EnvironmentObject private var streamingTextStore: StreamingTextStore

  let message: ChatMessage
  let toolSettings: NativeToolSettings
  let onDelete: () -> Void
  var onResubmit: (() -> Void)? = nil
  var onTrimFromHere: (() -> Void)? = nil
  var onRestartFresh: (() -> Void)? = nil
  var showThinking: Bool = false
  var onStreamingTextChange: ((String) -> Void)? = nil

  var body: some View {
    let streamingText = streamingTextStore.text(for: message.id)

    MessageBubbleContent(
      message: message,
      streamingOverride: streamingText,
      toolSettings: toolSettings,
      onDelete: onDelete,
      onResubmit: onResubmit,
      onTrimFromHere: onTrimFromHere,
      onRestartFresh: onRestartFresh,
      showThinking: showThinking
    )
    .equatable()
    .onChange(of: streamingText) { _, newText in
      guard let newText else { return }
      onStreamingTextChange?(newText)
    }
  }
}

private struct MessageBubbleContent: View, Equatable {
  let message: ChatMessage
  var streamingOverride: String? = nil
  let toolSettings: NativeToolSettings
  let onDelete: () -> Void
  var onResubmit: (() -> Void)? = nil
  var onTrimFromHere: (() -> Void)? = nil
  var onRestartFresh: (() -> Void)? = nil
  var showThinking: Bool = false

  private var isUser: Bool { message.role == .user }
  private var displayText: String { streamingOverride ?? message.text }
  private var isStreaming: Bool { streamingOverride != nil }

  /// Identity for SwiftUI's EquatableView: skip body re-evaluation when neither
  /// the canonical message nor the streaming override has changed. Closure
  /// equality is irrelevant because actions are invoked only from fresh menus.
  nonisolated static func == (lhs: MessageBubbleContent, rhs: MessageBubbleContent) -> Bool {
    lhs.message == rhs.message && lhs.streamingOverride == rhs.streamingOverride
      && lhs.toolSettings == rhs.toolSettings
      && lhs.showThinking == rhs.showThinking
  }

  var body: some View {
    let prepared = MessageRenderCache.preparedContent(
      messageID: message.id,
      text: displayText
    )
    let markdownBlocks =
      isStreaming || prepared.visibleText.isEmpty
      ? []
      : MessageRenderCache.markdownBlocks(
        messageID: message.id,
        text: prepared.visibleText
      )

    HStack(alignment: .top, spacing: 0) {
      if isUser { Spacer(minLength: 36) }
      VStack(alignment: .leading, spacing: 6) {
        ForEach(prepared.toolEntries) { entry in
          ToolCallRow(entry: entry)
        }
        ForEach(prepared.reasoningSections) { section in
          FoldableMetaSection(
            title: "Reasoning",
            systemImage: "brain",
            content: section.content,
            monospaced: false,
            dimmedContent: true,
            initiallyExpanded: showThinking
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
            markdownBlocks: markdownBlocks
          )
        }
      }
      if !isUser { Spacer(minLength: 36) }
    }
    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
  }

  @ViewBuilder
  private func bubble(visibleText: String, rawText: String, markdownBlocks: [MarkdownBlock])
    -> some View
  {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: iconName)
          .foregroundStyle(iconColor)
        Text(message.role.displayName)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      if visibleText.isEmpty {
        Text("...")
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      } else if isStreaming {
        Text(visibleText)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        MarkdownContentView(blocks: markdownBlocks)
      }
    }
    .padding(14)
    .frame(maxWidth: 720, alignment: .leading)
    .background(backgroundStyle)
    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    .contextMenu {
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
          settings: toolSettings)
      } label: {
        Label("Speak Message", systemImage: "speaker.wave.2")
      }
      if let resend = onTrimFromHere ?? (isUser ? onResubmit : nil) {
        Divider()
        Button {
          resend()
        } label: {
          Label("Resend From Here", systemImage: "arrow.clockwise")
        }
      }
      if let onRestartFresh {
        Divider()
        Button {
          onRestartFresh()
        } label: {
          Label("Restart From Here", systemImage: "arrow.triangle.2.circlepath")
        }
      }
      Button(role: .destructive, action: onDelete) {
        Label("Delete Message", systemImage: "trash")
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

  private var iconColor: Color {
    message.role == .error ? .red : .accentColor
  }

  private var backgroundStyle: some ShapeStyle {
    if message.role == .error {
      return AnyShapeStyle(.red.opacity(0.14))
    }
    if isUser {
      return AnyShapeStyle(Color.accentColor.opacity(0.22))
    }
    return AnyShapeStyle(.regularMaterial)
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
      .filter { $0.tag == "tool_context" || $0.tag == "tool_run" }
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

  @State private var expanded: Bool = false

  init(
    title: String,
    systemImage: String,
    content: String,
    monospaced: Bool,
    dimmedContent: Bool = false,
    initiallyExpanded: Bool = false
  ) {
    self.title = title
    self.systemImage = systemImage
    self.content = content
    self.monospaced = monospaced
    self.dimmedContent = dimmedContent
    self.initiallyExpanded = initiallyExpanded
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
        Text(content)
          .font(monospaced ? .system(.footnote, design: .monospaced) : .callout)
          .foregroundStyle(dimmedContent ? Color.secondary : Color.primary)
          .textSelection(.enabled)
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
        Text(entry.body.isEmpty ? "(no output)" : entry.body)
          .font(.callout)
          .foregroundStyle(.primary)
          .textSelection(.enabled)
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

  init(text: String) {
    self.blocks = MarkdownParser.blocks(from: text)
  }

  init(blocks: [MarkdownBlock]) {
    self.blocks = blocks
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(blocks) { block in
        switch block.kind {
        case .text(let value):
          Text(attributedInlineMarkdown(value))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        case .code(let language, let code):
          CodeBlockView(language: language, code: code)
        case .table(let headers, let rows, let alignments):
          MarkdownTableView(headers: headers, rows: rows, alignments: alignments)
        case .taskList(let items):
          TaskListView(items: items)
        case .bulletList(let items):
          BulletListView(items: items)
        }
      }
    }
  }
}

private func attributedInlineMarkdown(_ value: String) -> AttributedString {
  (try? AttributedString(
    markdown: value,
    options: AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace)))
    ?? AttributedString(value)
}

struct MarkdownTableView: View {
  let headers: [String]
  let rows: [[String]]
  let alignments: [TextAlignment]

  var body: some View {
    Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
      GridRow {
        ForEach(Array(headers.enumerated()), id: \.offset) { idx, header in
          cellView(header, columnIndex: idx, isHeader: true)
        }
      }
      .background(Color.secondary.opacity(0.10))
      Divider().opacity(0.5)
      ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
        GridRow {
          ForEach(0..<headers.count, id: \.self) { idx in
            let value = idx < row.count ? row[idx] : ""
            cellView(value, columnIndex: idx, isHeader: false)
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
  private func cellView(_ value: String, columnIndex: Int, isHeader: Bool) -> some View {
    let alignment = columnIndex < alignments.count ? alignments[columnIndex] : .leading
    Text(attributedInlineMarkdown(value))
      .font(isHeader ? .callout.weight(.semibold) : .callout)
      .multilineTextAlignment(alignment)
      .frame(maxWidth: .infinity, alignment: frameAlignment(alignment))
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .textSelection(.enabled)
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
  let language: String
  let code: String

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(language.isEmpty ? "code" : language)
          .font(.caption.monospaced().weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          UIPasteboard.general.string = code
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.glass)
        .help("Copy code")
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      Divider()
      ScrollView(.horizontal, showsIndicators: true) {
        Text(SyntaxHighlighter.highlight(code, language: language))
          .font(.system(.callout, design: .monospaced))
          .textSelection(.enabled)
          .padding(12)
      }
    }
    .background(.thinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(.secondary.opacity(0.18), lineWidth: 1)
    }
  }
}

struct TaskListItem: Identifiable {
  let id = UUID()
  let text: String
  let checked: Bool
}

struct TaskListView: View {
  let items: [TaskListItem]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(items) { item in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(systemName: item.checked ? "checkmark.square.fill" : "square")
            .foregroundStyle(item.checked ? Color.accentColor : Color.secondary)
            .imageScale(.medium)
            .accessibilityLabel(item.checked ? "Checked" : "Unchecked")
          Text(attributedInlineMarkdown(item.text))
            .textSelection(.enabled)
            .strikethrough(item.checked, color: .secondary)
            .foregroundStyle(item.checked ? Color.secondary : Color.primary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}

struct BulletListView: View {
  let items: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(items.enumerated()), id: \.offset) { _, item in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text("•")
            .foregroundStyle(.secondary)
          Text(attributedInlineMarkdown(item))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}

struct MarkdownBlock: Identifiable {
  enum Kind {
    case text(String)
    case code(language: String, code: String)
    case table(headers: [String], rows: [[String]], alignments: [TextAlignment])
    case taskList(items: [TaskListItem])
    case bulletList(items: [String])
  }

  let id = UUID()
  var kind: Kind
}

enum MarkdownParser {
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

      if let firstItem = taskListItem(trimmed) {
        flushText()
        var items: [TaskListItem] = [firstItem]
        var cursor = index + 1
        while cursor < lines.count {
          let nextTrimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
          guard let nextItem = taskListItem(nextTrimmed) else { break }
          items.append(nextItem)
          cursor += 1
        }
        blocks.append(MarkdownBlock(kind: .taskList(items: items)))
        index = cursor
        continue
      }

      if let firstItem = bulletListItem(trimmed) {
        flushText()
        var items: [String] = [firstItem]
        var cursor = index + 1
        while cursor < lines.count {
          let nextTrimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
          guard let nextItem = bulletListItem(nextTrimmed) else { break }
          items.append(nextItem)
          cursor += 1
        }
        blocks.append(MarkdownBlock(kind: .bulletList(items: items)))
        index = cursor
        continue
      }

      if trimmed.contains("|"),
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
            guard rowTrimmed.contains("|"), tableAlignments(rowTrimmed) == nil else { break }
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

  private static func splitTableRow(_ line: String) -> [String] {
    var s = line
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
    guard line.contains("|"), line.contains("-") else { return nil }
    let cells = splitTableRow(line)
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
