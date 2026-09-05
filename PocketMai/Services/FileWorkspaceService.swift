import Foundation
import MaiDocuments

enum PocketMaiDirectories {
  private static let appPrivateDirectoryName = "PocketMai"
  private static let filesWorkspaceDirectoryName = "FilesData"
  private static let appPrivateFilenames = Set([
    "settings.json",
    "bookmarks.json",
    "conversations.json",
    "conversations",
    "voice-recordings",
  ])

  private static var documentsURL: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
  }

  static var filesWorkspaceURL: URL {
    documentsURL.appendingPathComponent(filesWorkspaceDirectoryName, isDirectory: true)
  }

  static var appDataURL: URL {
    let applicationSupport =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return applicationSupport.appendingPathComponent(appPrivateDirectoryName, isDirectory: true)
  }

  static var voiceRecordingsURL: URL {
    appDataURL.appendingPathComponent("voice-recordings", isDirectory: true)
  }

  static var localMLXModelCacheURL: URL {
    documentsURL
      .appendingPathComponent("Models", isDirectory: true)
      .appendingPathComponent("huggingface", isDirectory: true)
      .appendingPathComponent("hub", isDirectory: true)
  }

  private static var legacyDocumentsAppDataURL: URL {
    documentsURL.appendingPathComponent(appPrivateDirectoryName, isDirectory: true)
  }

  @discardableResult
  static func ensureFilesWorkspace() throws -> URL {
    let url = filesWorkspaceURL
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @discardableResult
  static func ensureAppData() throws -> URL {
    let url = appDataURL
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  static func prepareStorage(fileManager: FileManager = .default) {
    prepareLaunchStorage(fileManager: fileManager)
    _ = try? ensureLocalMLXModelCache(fileManager: fileManager)
    try? fileManager.createDirectory(at: filesWorkspaceURL, withIntermediateDirectories: true)
  }

  static func prepareLaunchStorage(fileManager: FileManager = .default) {
    try? fileManager.createDirectory(at: appDataURL, withIntermediateDirectories: true)
    try? fileManager.createDirectory(at: voiceRecordingsURL, withIntermediateDirectories: true)
    migrateLegacyDocumentsAppData(fileManager: fileManager)
  }

  @discardableResult
  static func ensureVoiceRecordings() throws -> URL {
    let url = voiceRecordingsURL
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @discardableResult
  static func ensureLocalMLXModelCache(fileManager: FileManager = .default) throws -> URL {
    let url = localMLXModelCacheURL
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)

    var modelsRoot = documentsURL.appendingPathComponent("Models", isDirectory: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? modelsRoot.setResourceValues(values)

    return url
  }

  static func voiceRecordingURL(filename: String) -> URL? {
    let name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty,
      name != ".",
      name != "..",
      !name.contains("/"),
      !name.contains("\\")
    else {
      return nil
    }
    return voiceRecordingsURL.appendingPathComponent(name)
  }

  private static func migrateLegacyDocumentsAppData(fileManager: FileManager) {
    let legacyURL = legacyDocumentsAppDataURL
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: legacyURL.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      return
    }

    for name in appPrivateFilenames {
      migrateAppPrivateItem(named: name, from: legacyURL, fileManager: fileManager)
    }
    migrateRemainingUserFiles(from: legacyURL, fileManager: fileManager)
    removeDirectoryIfEmpty(legacyURL, fileManager: fileManager)
  }

  private static func migrateAppPrivateItem(
    named name: String,
    from legacyURL: URL,
    fileManager: FileManager
  ) {
    let source = legacyURL.appendingPathComponent(name)
    guard fileManager.fileExists(atPath: source.path) else { return }
    let destination = appDataURL.appendingPathComponent(name)
    if fileManager.fileExists(atPath: destination.path) {
      let backupDirectory = appDataURL.appendingPathComponent(
        "LegacyDocumentsBackup",
        isDirectory: true)
      try? fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
      let backupURL = uniqueDestination(
        for: name,
        in: backupDirectory,
        fileManager: fileManager)
      try? fileManager.moveItem(at: source, to: backupURL)
      return
    }
    try? fileManager.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try? fileManager.moveItem(at: source, to: destination)
  }

  private static func migrateRemainingUserFiles(from legacyURL: URL, fileManager: FileManager) {
    guard
      let items = try? fileManager.contentsOfDirectory(
        at: legacyURL,
        includingPropertiesForKeys: nil,
        options: [])
    else {
      return
    }

    try? fileManager.createDirectory(at: filesWorkspaceURL, withIntermediateDirectories: true)
    for item in items where !appPrivateFilenames.contains(item.lastPathComponent) {
      let destination = uniqueDestination(
        for: item.lastPathComponent,
        in: filesWorkspaceURL,
        fileManager: fileManager)
      try? fileManager.moveItem(at: item, to: destination)
    }
  }

  private static func uniqueDestination(
    for filename: String,
    in directory: URL,
    fileManager: FileManager
  ) -> URL {
    let original = directory.appendingPathComponent(filename)
    guard fileManager.fileExists(atPath: original.path) else { return original }

    let nsName = filename as NSString
    let base = nsName.deletingPathExtension.isEmpty ? filename : nsName.deletingPathExtension
    let ext = nsName.pathExtension
    var index = 1
    while true {
      let candidateName =
        ext.isEmpty ? "\(base)-migrated-\(index)" : "\(base)-migrated-\(index).\(ext)"
      let candidate = directory.appendingPathComponent(candidateName)
      if !fileManager.fileExists(atPath: candidate.path) {
        return candidate
      }
      index += 1
    }
  }

  private static func removeDirectoryIfEmpty(_ url: URL, fileManager: FileManager) {
    guard
      let items = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil),
      items.isEmpty
    else {
      return
    }
    try? fileManager.removeItem(at: url)
  }
}

/// Where the Files tools operate: either the built-in FilesData workspace or a
/// user-picked custom working folder reached through a security-scoped bookmark.
struct FileWorkspaceContext: Sendable {
  let rootURL: URL
  let displayName: String
  let hidesModelsFolder: Bool
  let isSecurityScoped: Bool

  init(rootURL: URL, displayName: String, hidesModelsFolder: Bool, isSecurityScoped: Bool) {
    self.rootURL = rootURL.standardizedFileURL
    self.displayName = displayName
    self.hidesModelsFolder = hidesModelsFolder
    self.isSecurityScoped = isSecurityScoped
  }

  static func filesData() throws -> FileWorkspaceContext {
    FileWorkspaceContext(
      rootURL: try PocketMaiDirectories.ensureFilesWorkspace(),
      displayName: FileWorkspaceService.defaultWorkspaceName,
      hidesModelsFolder: true,
      isSecurityScoped: false)
  }

  static func custom(rootURL: URL, displayName: String) -> FileWorkspaceContext {
    FileWorkspaceContext(
      rootURL: rootURL,
      displayName: WorkingFolderReference.normalizedDisplayName(displayName),
      hidesModelsFolder: false,
      isSecurityScoped: true)
  }
}

/// Creates and resolves the security-scoped bookmarks behind custom working
/// folders picked from Files or iCloud Drive.
enum WorkingFolderAccess {
  struct ResolvedFolder {
    let url: URL
    /// Non-nil when the stored bookmark was stale and could be re-created;
    /// callers should persist it so the folder stays reachable.
    let refreshedBookmarkData: Data?
  }

  static func makeReference(from pickedURL: URL) throws -> WorkingFolderReference {
    try withAccess(to: pickedURL) {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: pickedURL.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else {
        throw NSError.fileWorkspace("The selected working folder is not a folder.")
      }
      let bookmarkData = try pickedURL.bookmarkData(
        options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
      return WorkingFolderReference(
        bookmarkData: bookmarkData,
        displayName: pickedURL.lastPathComponent)
    }
  }

  static func resolve(_ reference: WorkingFolderReference) throws -> ResolvedFolder {
    var isStale = false
    let url = try URL(
      resolvingBookmarkData: reference.bookmarkData,
      options: [],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale)
    guard isStale else { return ResolvedFolder(url: url, refreshedBookmarkData: nil) }
    let refreshed = withAccess(to: url) {
      try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    return ResolvedFolder(url: url, refreshedBookmarkData: refreshed)
  }

  static func withAccess<T>(to url: URL, _ body: () throws -> T) rethrows -> T {
    let didStart = url.startAccessingSecurityScopedResource()
    defer {
      if didStart { url.stopAccessingSecurityScopedResource() }
    }
    return try body()
  }
}

enum FileWorkspaceService {
  static let defaultWorkspaceName = "FilesData"
  private static let maxListEntries = 500
  private static let defaultReadLimit = 120_000
  private static let maxReadLimit = 500_000
  private static let maxWriteBytes = 1_000_000
  private static let maxIndexEntries = 400
  private static let defaultRangeLineCount = 200
  private static let maxRangeLineCount = 1_000
  private static let maxEditableFileBytes = 10_000_000
  private static let modelsFolderName = "Models"
  private static let listResourceKeys: [URLResourceKey] = [
    .contentModificationDateKey,
    .fileSizeKey,
    .isDirectoryKey,
    .isRegularFileKey,
    .isSymbolicLinkKey,
  ]

  static func list(
    arguments: [String: AgentToolArgumentValue],
    in context: FileWorkspaceContext
  ) -> String {
    withWorkspaceAccess(context) {
      if let path = optionalPathArgument(arguments) {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isWorkspaceRootPath(trimmedPath, context: context) {
          let url = try validatedWorkspaceURL(path: trimmedPath, allowRoot: true, context: context)
          return try listWorkspaceDirectory(at: url, context: context)
        }
      }

      return try listWorkspaceDirectory(at: try validatedRoot(context), context: context)
    }
  }

  private static func listWorkspaceDirectory(
    at url: URL,
    context: FileWorkspaceContext
  ) throws -> String {
    let root = try validatedRoot(context)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      throw NSError.fileWorkspace(
        "Folder '\(workspacePath(for: url, context: context))' does not exist.")
    }
    guard isDirectory.boolValue else {
      throw NSError.fileWorkspace(
        "'\(workspacePath(for: url, context: context))' is not a folder.")
    }

    let entries = try FileManager.default.contentsOfDirectory(
      at: url, includingPropertiesForKeys: listResourceKeys, options: [.skipsHiddenFiles]
    )
    .filter { entry in
      !context.hidesModelsFolder
        || url.standardizedFileURL.path != root.path
        || entry.lastPathComponent != modelsFolderName
    }
    .sorted {
      $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
    }

    var lines = ["\(workspacePath(for: url, context: context)) files:"]
    if entries.isEmpty {
      lines.append("(no files)")
    }
    for entry in entries.prefix(maxListEntries) {
      lines.append(entryLine(for: entry, path: relativePath(for: entry, context: context)))
    }
    if entries.count > maxListEntries {
      lines.append("Truncated: showing \(maxListEntries) of \(entries.count) entries.")
    }
    return lines.joined(separator: "\n")
  }

  static func read(
    arguments: [String: AgentToolArgumentValue],
    in context: FileWorkspaceContext
  ) -> String {
    withWorkspaceAccess(context) {
      let path = pathArgument(arguments, primary: "path", fallback: "file") ?? ""
      guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return "Error: path is required."
      }
      let url = try validatedFileURL(path: path, context: context)
      let requestedLimit = arguments["max_bytes"]?.numberValue.map(Int.init) ?? defaultReadLimit
      let requestedOffset = arguments["offset"]?.numberValue.map(Int.init) ?? 0
      return try readTextFile(
        at: url,
        displayPath: displayPath(path),
        requestedLimit: requestedLimit,
        requestedOffset: requestedOffset)
    }
  }

  /// Reads a document file as text: Word and PDF files are converted to
  /// Markdown, JSON files to an indented outline, and anything else is read as
  /// plain UTF-8 text.
  static func readDocument(
    arguments: [String: AgentToolArgumentValue],
    in context: FileWorkspaceContext
  ) -> String {
    withWorkspaceAccess(context) {
      let path = pathArgument(arguments, primary: "path", fallback: "file") ?? ""
      guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return "Error: path is required."
      }
      let url = try validatedFileURL(path: path, context: context)
      let document = try loadDocument(at: url, displayPath: displayPath(path))
      let requestedLimit = arguments["max_bytes"]?.numberValue.map(Int.init) ?? defaultReadLimit
      let requestedOffset = arguments["offset"]?.numberValue.map(Int.init) ?? 0
      let data = Data(document.text.utf8)
      guard
        let window = utf8Window(
          in: data, requestedLimit: requestedLimit, requestedOffset: requestedOffset)
      else {
        return "Error: '\(displayPath(path))' is not valid UTF-8 text."
      }
      let suffix = document.conversionNote.map { " (\($0))" } ?? ""
      return windowedFileReport(
        header: "Document: \(displayPath(path))\(suffix)",
        window: window,
        totalBytes: data.count,
        continuationTool: "files_read_document")
    }
  }

  /// Lists an index of a file with 1-based line numbers: function and type
  /// names for source code, headings for Markdown (including converted Word
  /// and PDF documents), and container keys for JSON.
  static func readIndex(
    arguments: [String: AgentToolArgumentValue],
    in context: FileWorkspaceContext
  ) -> String {
    withWorkspaceAccess(context) {
      let path = pathArgument(arguments, primary: "path", fallback: "file") ?? ""
      guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return "Error: path is required."
      }
      let url = try validatedFileURL(path: path, context: context)
      let display = displayPath(path)
      let document = try loadDocument(at: url, displayPath: display)

      let entries: [DocumentIndexer.Entry]
      if let sections = document.jsonSections {
        entries = sections.map { section in
          DocumentIndexer.Entry(
            line: section.line,
            title: String(repeating: "  ", count: section.depth) + section.title)
        }
      } else if document.conversionNote == nil,
        let sourceEntries = DocumentIndexer.sourceIndex(
          text: document.text, fileExtension: url.pathExtension)
      {
        entries = sourceEntries
      } else {
        entries = DocumentIndexer.markdownIndex(text: document.text)
      }

      let suffix = document.conversionNote.map { " (\($0))" } ?? ""
      guard !entries.isEmpty else {
        return
          "No index entries found in \(display)\(suffix). The index lists function and type names in source files, headings in Markdown and converted documents, and keys in JSON files."
      }
      let noun = entries.count == 1 ? "entry" : "entries"
      var lines = ["Index of \(display)\(suffix): \(entries.count) \(noun)"]
      if document.conversionNote != nil {
        lines.append(
          "Line numbers refer to the converted text returned by files_read_document and files_read_range.")
      }
      for entry in entries.prefix(maxIndexEntries) {
        lines.append("\(entry.line): \(entry.title)")
      }
      if entries.count > maxIndexEntries {
        lines.append("Truncated: showing \(maxIndexEntries) of \(entries.count) entries.")
      }
      return lines.joined(separator: "\n")
    }
  }

  /// Returns a numbered range of lines. Word, PDF, and JSON files are read
  /// through the same conversion as files_read_document, so line numbers match
  /// the files_read_index output.
  static func readRange(
    arguments: [String: AgentToolArgumentValue],
    in context: FileWorkspaceContext
  ) -> String {
    withWorkspaceAccess(context) {
      let path = pathArgument(arguments, primary: "path", fallback: "file") ?? ""
      guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return "Error: path is required."
      }
      let url = try validatedFileURL(path: path, context: context)
      let display = displayPath(path)
      let document = try loadDocument(at: url, displayPath: display)
      let lines = documentLines(document.text)

      let start = arguments["start_line"]?.numberValue.map(Int.init) ?? 1
      let requestedEnd =
        arguments["end_line"]?.numberValue.map(Int.init)
        ?? arguments["line_count"]?.numberValue.map { start + Int($0) - 1 }
        ?? start + defaultRangeLineCount - 1
      guard start >= 1 else { return "Error: start_line must be at least 1." }
      guard !lines.isEmpty else { return "\(display) is empty." }
      guard start <= lines.count else {
        return "Error: start_line \(start) is past the end of \(display) (\(lines.count) lines)."
      }
      guard requestedEnd >= start else {
        return "Error: end_line must be at least start_line."
      }

      var end = min(requestedEnd, lines.count)
      var cappedByLineLimit = false
      if end - start + 1 > maxRangeLineCount {
        end = start + maxRangeLineCount - 1
        cappedByLineLimit = true
      }

      let suffix = document.conversionNote.map { " (\($0))" } ?? ""
      var output = ["File: \(display)\(suffix), lines \(start)-\(end) of \(lines.count)"]
      var usedBytes = 0
      var lastIncluded = start - 1
      for lineNumber in start...end {
        let rendered = "\(lineNumber): \(lines[lineNumber - 1])"
        let renderedBytes = rendered.utf8.count + 1
        if usedBytes + renderedBytes > maxReadLimit {
          if lastIncluded < start {
            // Even the first line exceeds the byte budget; return a clipped view.
            output.append(String(rendered.prefix(maxReadLimit)))
            output.append(
              "Line \(lineNumber) is longer than \(maxReadLimit) bytes and was clipped; use files_read with offsets for the full line.")
            lastIncluded = lineNumber
          }
          break
        }
        usedBytes += renderedBytes
        output.append(rendered)
        lastIncluded = lineNumber
      }
      if lastIncluded < end {
        output.append("Truncated. Continue with start_line=\(lastIncluded + 1).")
      } else if cappedByLineLimit {
        output.append(
          "Showing \(maxRangeLineCount) lines. Continue with start_line=\(lastIncluded + 1).")
      }
      return output.joined(separator: "\n")
    }
  }

  /// Replaces an inclusive 1-based line range of a plain UTF-8 text file.
  /// Passing end_line = start_line - 1 inserts before start_line without
  /// removing anything; empty content deletes the range.
  static func replaceRange(
    arguments: [String: AgentToolArgumentValue],
    in context: FileWorkspaceContext
  ) -> String {
    withWorkspaceAccess(context) {
      let path = pathArgument(arguments, primary: "path", fallback: "file") ?? ""
      guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return "Error: path is required."
      }
      guard let start = arguments["start_line"]?.numberValue.map(Int.init) else {
        return "Error: start_line is required."
      }
      let url = try validatedFileURL(path: path, context: context)
      let display = displayPath(path)
      guard case .plainText = WorkspaceDocumentKind(url: url) else {
        return
          "Error: files_replace_range edits plain UTF-8 text files only; '\(display)' is read through a converted view. Use files_read and files_write for raw edits."
      }
      let document = try loadDocument(at: url, displayPath: display)
      let end = arguments["end_line"]?.numberValue.map(Int.init) ?? start
      let replacement =
        arguments["content"]?.stringValue ?? arguments["text"]?.stringValue ?? ""
      guard replacement.utf8.count <= maxWriteBytes else {
        return "Error: replacement content is limited to \(maxWriteBytes) bytes."
      }

      let edit = try replacingLineRange(
        in: document.text, startLine: start, endLine: end, replacement: replacement)
      let data = Data(edit.text.utf8)
      guard data.count <= maxEditableFileBytes else {
        return "Error: the edited file would exceed \(maxEditableFileBytes) bytes."
      }
      try data.write(to: url, options: [.atomic])

      let inserted = "\(edit.insertedLineCount) line\(edit.insertedLineCount == 1 ? "" : "s")"
      let rangeText = start == end ? "line \(start)" : "lines \(start)-\(end)"
      if edit.removedLineCount == 0 {
        return
          "Inserted \(inserted) before line \(start) in \(display); now \(edit.totalLineCount) lines."
      }
      if edit.insertedLineCount == 0 {
        return "Deleted \(rangeText) from \(display); now \(edit.totalLineCount) lines."
      }
      return
        "Replaced \(rangeText) with \(inserted) in \(display); now \(edit.totalLineCount) lines."
    }
  }

  struct LineRangeEdit: Equatable {
    let text: String
    let removedLineCount: Int
    let insertedLineCount: Int
    let totalLineCount: Int
  }

  /// Pure line-range replacement over `text`, 1-based and inclusive. Exposed
  /// for testing; files_replace_range validates paths and sizes around it.
  static func replacingLineRange(
    in text: String,
    startLine: Int,
    endLine: Int,
    replacement: String
  ) throws -> LineRangeEdit {
    guard startLine >= 1 else {
      throw NSError.fileWorkspace("start_line must be at least 1.")
    }
    guard endLine >= startLine - 1 else {
      throw NSError.fileWorkspace(
        "end_line must be at least start_line - 1 (start_line - 1 inserts without removing).")
    }
    let lines = documentLines(text)
    guard startLine <= lines.count + 1 else {
      throw NSError.fileWorkspace(
        "start_line \(startLine) is past the end of the file (\(lines.count) lines).")
    }
    guard endLine <= lines.count else {
      throw NSError.fileWorkspace(
        "end_line \(endLine) is past the end of the file (\(lines.count) lines).")
    }

    var replacementLines = replacement.components(separatedBy: "\n")
    if replacementLines.last == "" { replacementLines.removeLast() }

    var result = Array(lines[0..<(startLine - 1)])
    result.append(contentsOf: replacementLines)
    result.append(contentsOf: lines[endLine...])

    var newText = result.joined(separator: "\n")
    if text.hasSuffix("\n"), !newText.isEmpty { newText += "\n" }
    return LineRangeEdit(
      text: newText,
      removedLineCount: endLine - startLine + 1,
      insertedLineCount: replacementLines.count,
      totalLineCount: result.count)
  }

  /// Content lines of a document: a trailing newline does not add an empty
  /// final line.
  private static func documentLines(_ text: String) -> [String] {
    guard !text.isEmpty else { return [] }
    var lines = text.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    return lines
  }

  private struct WorkspaceDocument {
    let text: String
    /// Human-readable conversion note, nil when the file was read verbatim.
    let conversionNote: String?
    /// Key outline when the file is JSON, aligned with the rendered text.
    let jsonSections: [JSONDocumentImporter.Section]?
  }

  private enum WorkspaceDocumentKind {
    case wordDocument
    case pdfDocument
    case jsonDocument
    case plainText

    init(url: URL) {
      switch url.pathExtension.lowercased() {
      case "docx": self = .wordDocument
      case "pdf": self = .pdfDocument
      case "json": self = .jsonDocument
      default: self = .plainText
      }
    }
  }

  private static func loadDocument(
    at url: URL,
    displayPath: String
  ) throws -> WorkspaceDocument {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      throw NSError.fileWorkspace("File '\(displayPath)' does not exist.")
    }
    guard !isDirectory.boolValue else {
      throw NSError.fileWorkspace("'\(displayPath)' is a directory.")
    }

    switch WorkspaceDocumentKind(url: url) {
    case .wordDocument:
      return WorkspaceDocument(
        text: try DOCXImporter.markdown(from: url),
        conversionNote: "converted from Word to Markdown",
        jsonSections: nil)
    case .pdfDocument:
      return WorkspaceDocument(
        text: try PDFImporter.markdown(from: url),
        conversionNote: "converted from PDF to Markdown",
        jsonSections: nil)
    case .jsonDocument:
      let rendered = try JSONDocumentImporter.render(
        data: try Data(contentsOf: url, options: [.mappedIfSafe]))
      return WorkspaceDocument(
        text: rendered.text,
        conversionNote: "converted from JSON to an indented outline",
        jsonSections: rendered.sections)
    case .plainText:
      let data = try Data(contentsOf: url, options: [.mappedIfSafe])
      guard data.count <= maxEditableFileBytes else {
        throw NSError.fileWorkspace(
          "'\(displayPath)' is larger than \(maxEditableFileBytes) bytes; use files_read with offsets instead.")
      }
      if looksBinary(data) {
        throw NSError.fileWorkspace("'\(displayPath)' appears to be binary; text files only.")
      }
      guard let text = String(data: data, encoding: .utf8) else {
        throw NSError.fileWorkspace("'\(displayPath)' is not valid UTF-8 text.")
      }
      return WorkspaceDocument(text: text, conversionNote: nil, jsonSections: nil)
    }
  }

  static func write(
    arguments: [String: AgentToolArgumentValue],
    in context: FileWorkspaceContext
  ) -> String {
    withWorkspaceAccess(context) {
      let path = pathArgument(arguments, primary: "path", fallback: "file") ?? ""
      guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return "Error: path is required."
      }
      let append = arguments["append"]?.boolValue ?? false
      let createDirectoryRequested = shouldCreateDirectory(arguments)
      let url = try validatedFileURL(path: path, context: context)
      let root = try validatedRoot(context)

      if createDirectoryRequested {
        return try createDirectory(at: url, path: path, root: root, context: context)
      }

      guard let contentValue = arguments["content"] ?? arguments["text"] else {
        return "Error: content is required."
      }
      let content = contentValue.coercedStringValue
      guard let data = content.data(using: .utf8) else {
        return "Error: content must be UTF-8 text."
      }
      guard data.count <= maxWriteBytes else {
        return "Error: write is limited to \(maxWriteBytes) bytes."
      }

      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      {
        return "Error: '\(displayPath(path))' is a directory."
      }

      try ensureParentDirectory(for: url, root: root, createIfNeeded: true, context: context)

      if append, FileManager.default.fileExists(atPath: url.path) {
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
      } else if append {
        try data.write(to: url)
      } else {
        try data.write(to: url, options: [.atomic])
      }

      let action = append ? "Appended" : "Wrote"
      return "\(action) \(data.count) byte\(data.count == 1 ? "" : "s") to \(displayPath(path))"
    }
  }

  static func delete(
    arguments: [String: AgentToolArgumentValue],
    in context: FileWorkspaceContext
  ) -> String {
    withWorkspaceAccess(context) {
      let path = pathArgument(arguments, primary: "path", fallback: "file") ?? ""
      guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return "Error: path is required."
      }
      let recursive = arguments["recursive"]?.boolValue ?? false
      let url = try validatedFileURL(path: path, context: context)
      let root = try validatedRoot(context)

      var isDirectoryFlag: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectoryFlag) else {
        return "Error: path '\(displayPath(path))' does not exist."
      }
      try validateInsideWorkspace(url, root: root, context: context)

      let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      let isDirectory = values?.isDirectory == true && values?.isSymbolicLink != true
      if isDirectory {
        if !recursive {
          let entries = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [])
          guard entries.isEmpty else {
            return
              "Error: directory '\(displayPath(path))' is not empty. Set recursive=true to delete it."
          }
        }
        try FileManager.default.removeItem(at: url)
        return "Deleted directory \(displayPath(path))"
      }

      try FileManager.default.removeItem(at: url)
      return "Deleted file \(displayPath(path))"
    }
  }

  static func rename(
    arguments: [String: AgentToolArgumentValue],
    in context: FileWorkspaceContext
  ) -> String {
    withWorkspaceAccess(context) {
      let path =
        AgentTooling.firstNonEmpty(
          arguments["path"]?.stringValue,
          arguments["file"]?.stringValue,
          arguments["old_path"]?.stringValue,
          arguments["from_path"]?.stringValue,
          arguments["source"]?.stringValue) ?? ""
      let newPath =
        AgentTooling.firstNonEmpty(
          arguments["new_path"]?.stringValue,
          arguments["new_file"]?.stringValue,
          arguments["new_name"]?.stringValue,
          arguments["to_path"]?.stringValue,
          arguments["destination"]?.stringValue) ?? ""
      guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return "Error: path is required."
      }
      guard !newPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return "Error: new_path is required."
      }

      let url = try validatedFileURL(path: path, context: context)
      let newURL = try validatedFileURL(path: newPath, context: context)
      if url.path == newURL.path {
        return "'\(displayPath(path))' is already named \(displayPath(newPath))"
      }

      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
        return "Error: '\(displayPath(path))' does not exist."
      }
      if isDirectory.boolValue {
        let sourcePath = url.standardizedFileURL.path
        let destinationPath = newURL.standardizedFileURL.path
        guard !destinationPath.hasPrefix(sourcePath + "/") else {
          return "Error: cannot move folder '\(displayPath(path))' inside itself."
        }
      }
      guard !FileManager.default.fileExists(atPath: newURL.path) else {
        return "Error: '\(displayPath(newPath))' already exists."
      }
      try ensureParentDirectory(
        for: newURL, root: try validatedRoot(context), createIfNeeded: false, context: context)

      try FileManager.default.moveItem(at: url, to: newURL)
      return "Renamed \(displayPath(path)) to \(displayPath(newPath))"
    }
  }

  private static func withWorkspaceAccess(
    _ context: FileWorkspaceContext,
    _ body: () throws -> String
  ) -> String {
    do {
      guard context.isSecurityScoped else { return try body() }
      return try WorkingFolderAccess.withAccess(to: context.rootURL, body)
    } catch {
      return "Error: \(error.localizedDescription)"
    }
  }

  private static func pathArgument(
    _ arguments: [String: AgentToolArgumentValue],
    primary: String,
    fallback: String
  ) -> String? {
    AgentTooling.firstNonEmpty(arguments[primary]?.stringValue, arguments[fallback]?.stringValue)
  }

  private static func optionalPathArgument(_ arguments: [String: AgentToolArgumentValue]) -> String?
  {
    AgentTooling.firstNonEmpty(
      arguments["path"]?.stringValue,
      arguments["directory"]?.stringValue,
      arguments["folder"]?.stringValue)
  }

  private static func readTextFile(
    at url: URL,
    displayPath: String,
    requestedLimit: Int,
    requestedOffset: Int
  ) throws -> String {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      return "Error: file '\(displayPath)' does not exist."
    }
    guard !isDirectory.boolValue else {
      return "Error: '\(displayPath)' is a directory."
    }

    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    if looksBinary(data) {
      return "Error: '\(displayPath)' appears to be binary; text files only."
    }
    guard
      let window = utf8Window(
        in: data, requestedLimit: requestedLimit, requestedOffset: requestedOffset)
    else {
      return "Error: '\(displayPath)' is not valid UTF-8 text."
    }
    return windowedFileReport(
      header: "File: \(displayPath)",
      window: window,
      totalBytes: data.count,
      continuationTool: "files_read")
  }

  private struct UTF8Window {
    let text: String
    let start: Int
    let consumedEnd: Int
  }

  private static func utf8Window(
    in data: Data,
    requestedLimit: Int,
    requestedOffset: Int
  ) -> UTF8Window? {
    let offset = min(max(requestedOffset, 0), data.count)
    let limit = min(max(requestedLimit, 1), maxReadLimit)
    var chunk = Data(data.dropFirst(offset).prefix(limit))
    var start = offset
    if offset > 0 {
      // A byte offset can land mid-character; skip UTF-8 continuation bytes.
      while let first = chunk.first, first & 0b1100_0000 == 0b1000_0000 {
        chunk.removeFirst()
        start += 1
      }
    }
    var decoded = String(data: chunk, encoding: .utf8)
    while decoded == nil, !chunk.isEmpty {
      chunk.removeLast()
      decoded = String(data: chunk, encoding: .utf8)
    }
    guard let text = decoded else { return nil }
    return UTF8Window(text: text, start: start, consumedEnd: start + chunk.count)
  }

  private static func windowedFileReport(
    header: String,
    window: UTF8Window,
    totalBytes: Int,
    continuationTool: String
  ) -> String {
    let truncated = window.consumedEnd < totalBytes
    let shownBytes = window.consumedEnd - window.start
    let rangeNote =
      truncated || window.start > 0
      ? " (showing \(shownBytes) at offset \(window.start))" : ""
    var lines = [
      header,
      "Bytes: \(totalBytes)\(rangeNote)",
      "",
      window.text,
    ]
    if truncated {
      lines.append("")
      lines.append(
        "Truncated. Pass offset=\(window.consumedEnd) to \(continuationTool) to continue.")
    }
    return lines.joined(separator: "\n")
  }

  private static func isModelsPath(_ path: String) -> Bool {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed == modelsFolderName || trimmed.hasPrefix(modelsFolderName + "/")
  }

  private static func shouldCreateDirectory(_ arguments: [String: AgentToolArgumentValue]) -> Bool {
    arguments["create_directory"]?.boolValue == true
      || arguments["directory"]?.boolValue == true
      || arguments["create_dirs"]?.boolValue == true
      || arguments["create_directories"]?.boolValue == true
  }

  private static func createDirectory(
    at url: URL,
    path: String,
    root: URL,
    context: FileWorkspaceContext
  ) throws -> String {
    try ensureParentDirectory(for: url, root: root, createIfNeeded: true, context: context)

    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else {
        throw NSError.fileWorkspace("File '\(displayPath(path))' already exists.")
      }
      return "Directory already exists \(displayPath(path))"
    }

    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try validateInsideWorkspace(url, root: root, context: context)
    return "Created directory \(displayPath(path))"
  }

  private static func validatedFileURL(
    path rawPath: String,
    context: FileWorkspaceContext
  ) throws -> URL {
    try validatedWorkspaceURL(path: rawPath, allowRoot: false, context: context)
  }

  private static func validatedWorkspaceURL(
    path rawPath: String,
    allowRoot: Bool,
    context: FileWorkspaceContext
  ) throws -> URL {
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw NSError.fileWorkspace("Path is required.")
    }
    if trimmed.contains("\0") {
      throw NSError.fileWorkspace("Path contains an invalid character.")
    }
    if trimmed.contains("\\") {
      throw NSError.fileWorkspace("Use forward slashes inside \(context.displayName) paths.")
    }

    let root = try validatedRoot(context)
    if (trimmed as NSString).isAbsolutePath {
      let url = URL(fileURLWithPath: trimmed, isDirectory: false).standardizedFileURL
      try validateInsideWorkspace(url, root: root, context: context, resolvingSymlinks: false)
      if !allowRoot && url.path == root.path {
        throw NSError.fileWorkspace(
          "Path must name a file or folder inside \(context.displayName).")
      }
      try validateWorkspacePathIsNotReserved(url, root: root, context: context)
      if FileManager.default.fileExists(atPath: url.path) {
        try validateInsideWorkspace(url, root: root, context: context)
      }
      return url
    }

    let components = try workspacePathComponents(trimmed, allowRoot: allowRoot, context: context)
    var url = root
    for component in components {
      url.appendPathComponent(component)
    }
    url = url.standardizedFileURL
    try validateInsideWorkspace(url, root: root, context: context, resolvingSymlinks: false)
    if FileManager.default.fileExists(atPath: url.path) {
      try validateInsideWorkspace(url, root: root, context: context)
    }
    return url
  }

  private static func workspacePathComponents(
    _ rawPath: String,
    allowRoot: Bool,
    context: FileWorkspaceContext
  ) throws -> [String] {
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    if isWorkspaceRootPath(trimmed, context: context) {
      if allowRoot { return [] }
      throw NSError.fileWorkspace(
        "Path must name a file or folder inside \(context.displayName).")
    }

    var relativePath = trimmed
    if relativePath.hasPrefix(context.displayName + "/") {
      relativePath.removeFirst(context.displayName.count + 1)
    }
    if isWorkspaceRootPath(relativePath, context: context) {
      if allowRoot { return [] }
      throw NSError.fileWorkspace(
        "Path must name a file or folder inside \(context.displayName).")
    }
    if context.hidesModelsFolder && isModelsPath(relativePath) {
      throw NSError.fileWorkspace("Models is not available through \(context.displayName) tools.")
    }

    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
      .map(String.init)
    guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      throw NSError.fileWorkspace("\(context.displayName) path contains an invalid component.")
    }
    return components
  }

  private static func validateWorkspacePathIsNotReserved(
    _ url: URL,
    root: URL,
    context: FileWorkspaceContext
  ) throws {
    guard context.hidesModelsFolder else { return }
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath + "/") else { return }
    let relativePath = String(path.dropFirst(rootPath.count + 1))
    let firstComponent = relativePath.split(separator: "/", maxSplits: 1).first.map(String.init)
    if firstComponent == modelsFolderName {
      throw NSError.fileWorkspace("Models is not available through \(context.displayName) tools.")
    }
  }

  private static func isWorkspaceRootPath(_ path: String, context: FileWorkspaceContext) -> Bool {
    path.isEmpty || path == "." || path == context.displayName
  }

  private static func ensureParentDirectory(
    for url: URL,
    root: URL,
    createIfNeeded: Bool,
    context: FileWorkspaceContext
  ) throws {
    let parent = url.deletingLastPathComponent().standardizedFileURL
    try validateInsideWorkspace(parent, root: root, context: context, resolvingSymlinks: false)

    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else {
        throw NSError.fileWorkspace(
          "Parent path '\(workspacePath(for: parent, context: context))' is not a folder.")
      }
      try validateInsideWorkspace(parent, root: root, context: context)
      return
    }

    guard createIfNeeded else {
      throw NSError.fileWorkspace(
        "Folder '\(workspacePath(for: parent, context: context))' does not exist.")
    }

    let ancestor = existingAncestor(for: parent, root: root)
    try validateInsideWorkspace(ancestor, root: root, context: context)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try validateInsideWorkspace(parent, root: root, context: context)
  }

  private static func existingAncestor(for url: URL, root: URL) -> URL {
    let rootPath = root.standardizedFileURL.path
    var current = url.standardizedFileURL
    while current.path != rootPath && !FileManager.default.fileExists(atPath: current.path) {
      current = current.deletingLastPathComponent().standardizedFileURL
    }
    return current.path.hasPrefix(rootPath) ? current : root
  }

  private static func validatedRoot(_ context: FileWorkspaceContext) throws -> URL {
    let root = context.rootURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw NSError.fileWorkspace(
        "Working folder '\(context.displayName)' is not available. Select it again from the chat's + menu.")
    }
    return root
  }

  private static func validateInsideWorkspace(
    _ url: URL,
    root: URL,
    context: FileWorkspaceContext,
    resolvingSymlinks: Bool = true
  ) throws {
    try validateInsideDirectory(
      url,
      root: root,
      message: "Path must be inside \(context.displayName).",
      resolvingSymlinks: resolvingSymlinks)
  }

  private static func validateInsideDirectory(
    _ url: URL,
    root: URL,
    message: String,
    resolvingSymlinks: Bool = true
  ) throws {
    let rootURL =
      resolvingSymlinks
      ? root.resolvingSymlinksInPath().standardizedFileURL
      : root.standardizedFileURL
    let candidateURL =
      resolvingSymlinks
      ? url.resolvingSymlinksInPath().standardizedFileURL
      : url.standardizedFileURL
    let rootPath = rootURL.path
    let path = candidateURL.path
    guard path == rootPath || path.hasPrefix(rootPath + "/") else {
      throw NSError.fileWorkspace(message)
    }
  }

  private static func entryLine(for entry: URL, path: String) -> String {
    let values = try? entry.resourceValues(forKeys: Set(listResourceKeys))
    let type =
      values?.isDirectory == true
      ? "directory"
      : values?.isSymbolicLink == true
        ? "symlink"
        : values?.isRegularFile == true ? "file" : "other"
    let size = values?.fileSize.map { " \($0) bytes" } ?? ""
    let modified =
      values?.contentModificationDate.map {
        " modified \(ISO8601DateFormatter().string(from: $0))"
      } ?? ""
    return "- \(path) \(type)\(size)\(modified)"
  }

  private static func relativePath(for url: URL, context: FileWorkspaceContext) -> String {
    let rootPath = context.rootURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
    return String(path.dropFirst(rootPath.count + 1))
  }

  private static func workspacePath(for url: URL, context: FileWorkspaceContext) -> String {
    let rootPath = context.rootURL.path
    let path = url.standardizedFileURL.path
    if path == rootPath {
      return context.displayName
    }
    guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
    return "\(context.displayName)/\(String(path.dropFirst(rootPath.count + 1)))"
  }

  private static func displayPath(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "." : trimmed
  }

  private static func looksBinary(_ data: Data) -> Bool {
    data.prefix(4096).contains(0)
  }
}

extension NSError {
  fileprivate static func fileWorkspace(_ message: String) -> NSError {
    NSError(
      domain: "PocketMai.FileWorkspace", code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: message
      ])
  }
}
