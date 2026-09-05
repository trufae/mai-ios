import Foundation
import MaiCore
import MaiDocuments

/// Configuration for the portable Files tool group. Every path supplied by a
/// model is interpreted relative to `rootURL` and cannot escape it through
/// `..`, absolute paths, or symbolic links.
public struct MaiFileWorkspaceConfiguration: Equatable, Sendable {
  public var rootURL: URL
  public var displayName: String
  public var writeEnabled: Bool
  public var followsProcessWorkingDirectory: Bool
  public var isSecurityScoped: Bool
  public var hiddenRootEntryNames: Set<String>

  public init(
    rootURL: URL,
    displayName: String? = nil,
    writeEnabled: Bool = true,
    followsProcessWorkingDirectory: Bool = false,
    isSecurityScoped: Bool = false,
    hiddenRootEntryNames: Set<String> = []
  ) {
    self.rootURL = rootURL.standardizedFileURL
    self.displayName = displayName ?? rootURL.lastPathComponent
    self.writeEnabled = writeEnabled
    self.followsProcessWorkingDirectory = followsProcessWorkingDirectory
    self.isSecurityScoped = isSecurityScoped
    self.hiddenRootEntryNames = hiddenRootEntryNames
  }
}

/// One operation in the shared, workspace-scoped Files tool group.
public struct MaiFileWorkspaceTool: AgentTool {
  public enum Operation: String, CaseIterable, Sendable {
    case list = "files_list"
    case find = "files_find"
    case grep = "files_grep"
    case read = "files_read"
    case readDocument = "files_read_document"
    case write = "files_write"
    case rename = "files_rename"
    case delete = "files_delete"
    case chdir = "files_chdir"

    var changesFiles: Bool {
      switch self {
      case .list, .find, .grep, .read, .readDocument, .chdir: false
      case .write, .rename, .delete: true
      }
    }
  }

  public static let toolNames = Operation.allCases.map(\.rawValue)

  public let operation: Operation
  public let configuration: MaiFileWorkspaceConfiguration
  public let definition: ToolDefinition

  public init(operation: Operation, configuration: MaiFileWorkspaceConfiguration) {
    self.operation = operation
    self.configuration = configuration
    definition = Self.definition(for: operation, workspaceName: configuration.displayName)
  }

  public static func makeTools(
    configuration: MaiFileWorkspaceConfiguration
  ) -> [MaiFileWorkspaceTool] {
    Operation.allCases.compactMap { operation in
      guard configuration.writeEnabled || !operation.changesFiles else { return nil }
      return MaiFileWorkspaceTool(operation: operation, configuration: configuration)
    }
  }

  public func call(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolOutput {
    let arguments = arguments.objectValue ?? [:]
    #if os(macOS) || os(iOS)
      let didStartAccess =
        configuration.isSecurityScoped
        ? configuration.rootURL.startAccessingSecurityScopedResource() : false
      defer {
        if didStartAccess { configuration.rootURL.stopAccessingSecurityScopedResource() }
      }
    #endif
    do {
      try Task.checkCancellation()
      let workspace = try MaiFileWorkspace(configuration: configuration)
      switch operation {
      case .list:
        return try workspace.list(arguments)
      case .find:
        return try workspace.find(arguments)
      case .grep:
        return try workspace.grep(arguments)
      case .read:
        return try workspace.read(arguments)
      case .readDocument:
        return try workspace.readDocument(arguments)
      case .write:
        return try workspace.write(arguments)
      case .rename:
        return try workspace.rename(arguments)
      case .delete:
        return try workspace.delete(arguments)
      case .chdir:
        return try workspace.chdir(arguments)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return ToolOutput(text: "Error: \(error.localizedDescription)", isError: true)
    }
  }

  private static func definition(
    for operation: Operation,
    workspaceName: String
  ) -> ToolDefinition {
    let path = ToolParameterDef(
      name: "path",
      type: "string",
      description: "Path relative to the configured workspace '\(workspaceName)'.",
      required: true)
    switch operation {
    case .list:
      return ToolDefinition(
        name: operation.rawValue,
        description: "List a folder in the configured workspace '\(workspaceName)'.",
        parameters: [
          ToolParameterDef(
            name: "path",
            type: "string",
            description: "Relative folder path. Omit for the workspace root.",
            required: false)
        ],
        annotations: ToolAnnotations(
          readOnly: true, idempotent: true, openWorld: false, approval: .confirm))
    case .find:
      return ToolDefinition(
        name: operation.rawValue,
        description: "Find files and folders by an approximate name in '\(workspaceName)'.",
        parameters: [
          ToolParameterDef(
            name: "query",
            type: "string",
            description: "Exact, partial, or fuzzy file name or relative path.",
            required: true),
          ToolParameterDef(
            name: "path",
            type: "string",
            description: "Relative folder to search. Omit for the workspace root.",
            required: false),
          ToolParameterDef(
            name: "limit",
            type: "integer",
            description: "Maximum results, 1-500. Default: 100.",
            required: false),
        ],
        annotations: ToolAnnotations(
          readOnly: true, idempotent: true, openWorld: false, approval: .confirm))
    case .grep:
      return ToolDefinition(
        name: operation.rawValue,
        description: "Search UTF-8 files for text or a regular expression in '\(workspaceName)'.",
        parameters: [
          ToolParameterDef(
            name: "query",
            type: "string",
            description: "Text or regular expression to find.",
            required: true),
          ToolParameterDef(
            name: "path",
            type: "string",
            description: "Relative folder to search. Omit for the workspace root.",
            required: false),
          ToolParameterDef(
            name: "regex",
            type: "boolean",
            description: "Interpret query as a regular expression. Default: false.",
            required: false),
          ToolParameterDef(
            name: "case_sensitive",
            type: "boolean",
            description: "Use case-sensitive matching. Default: smart case.",
            required: false),
          ToolParameterDef(
            name: "limit",
            type: "integer",
            description: "Maximum matching lines, 1-500. Default: 100.",
            required: false),
        ],
        annotations: ToolAnnotations(
          readOnly: true, idempotent: true, openWorld: false, approval: .confirm))
    case .read:
      return ToolDefinition(
        name: operation.rawValue,
        description: "Read a UTF-8 text file in the configured workspace '\(workspaceName)'.",
        parameters: [
          path,
          ToolParameterDef(
            name: "max_bytes",
            type: "integer",
            description: "Maximum bytes to return, up to 500000. Default: 120000.",
            required: false),
          ToolParameterDef(
            name: "offset",
            type: "integer",
            description: "Byte offset for continuing a large file. Default: 0.",
            required: false),
        ],
        annotations: ToolAnnotations(
          readOnly: true, idempotent: true, openWorld: false, approval: .confirm))
    case .readDocument:
      return ToolDefinition(
        name: operation.rawValue,
        description:
          "Read a document in '\(workspaceName)': DOCX and PDF become Markdown, JSON becomes an outline, and text remains UTF-8.",
        parameters: [
          path,
          ToolParameterDef(
            name: "max_bytes",
            type: "integer",
            description: "Maximum converted-text bytes to return, up to 500000. Default: 120000.",
            required: false),
          ToolParameterDef(
            name: "offset",
            type: "integer",
            description: "Byte offset for continuing through converted text. Default: 0.",
            required: false),
        ],
        annotations: ToolAnnotations(
          readOnly: true, idempotent: true, openWorld: false, approval: .confirm))
    case .write:
      return ToolDefinition(
        name: operation.rawValue,
        description: "Write or append UTF-8 text, or create a folder, in '\(workspaceName)'.",
        parameters: [
          path,
          ToolParameterDef(
            name: "content",
            type: "string",
            description: "Text to write. Omit only when create_directory is true.",
            required: false),
          ToolParameterDef(
            name: "append",
            type: "boolean",
            description: "Append instead of replacing the file. Default: false.",
            required: false),
          ToolParameterDef(
            name: "create_directory",
            type: "boolean",
            description: "Create a directory instead of writing a file. Default: false.",
            required: false),
        ],
        annotations: ToolAnnotations(
          readOnly: false, idempotent: false, openWorld: false, approval: .confirm))
    case .rename:
      return ToolDefinition(
        name: operation.rawValue,
        description: "Rename or move a file or folder within '\(workspaceName)'.",
        parameters: [
          path,
          ToolParameterDef(
            name: "new_path",
            type: "string",
            description: "New path relative to the same workspace.",
            required: true),
        ],
        annotations: ToolAnnotations(
          readOnly: false, idempotent: false, openWorld: false, approval: .confirm))
    case .delete:
      return ToolDefinition(
        name: operation.rawValue,
        description: "Delete a file or folder within '\(workspaceName)'.",
        parameters: [
          path,
          ToolParameterDef(
            name: "recursive",
            type: "boolean",
            description: "Allow deletion of a non-empty directory. Default: false.",
            required: false),
        ],
        annotations: ToolAnnotations(
          readOnly: false,
          destructive: true,
          idempotent: false,
          openWorld: false,
          approval: .dangerous))
    case .chdir:
      return ToolDefinition(
        name: operation.rawValue,
        description: "Change the current directory used by the Files workspace.",
        parameters: [ToolParameterDef(
          name: "path",
          type: "string",
          description: "Directory path, relative to the current directory or absolute.",
          required: true)],
        annotations: ToolAnnotations(
          readOnly: false, idempotent: false, openWorld: false, approval: .confirm))
    }
  }
}

private struct MaiFileWorkspace: Sendable {
  private static let defaultReadLimit = 120_000
  private static let maximumReadLimit = 500_000
  private static let maximumWriteBytes = 1_000_000
  private static let maximumListEntries = 500

  let configuration: MaiFileWorkspaceConfiguration
  let rootURL: URL

  init(configuration: MaiFileWorkspaceConfiguration) throws {
    let configuredRoot = configuration.followsProcessWorkingDirectory
      ? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      : configuration.rootURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(
      atPath: configuredRoot.path,
      isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw MaiFileWorkspaceError.invalidRoot(configuredRoot.path)
    }
    self.configuration = configuration
    rootURL = configuredRoot.resolvingSymlinksInPath().standardizedFileURL
  }

  func chdir(_ arguments: [String: JSONValue]) throws -> ToolOutput {
    guard configuration.followsProcessWorkingDirectory else {
      throw MaiFileWorkspaceError.invalidPath("files_chdir requires a dynamic workspace")
    }
    guard let rawPath = arguments["path"]?.stringValue,
      !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw MaiFileWorkspaceError.missingArgument("path") }
    let expanded = NSString(string: rawPath).expandingTildeInPath
    let target = URL(fileURLWithPath: expanded, relativeTo: rootURL).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw MaiFileWorkspaceError.notDirectory(target.path) }
    guard FileManager.default.changeCurrentDirectoryPath(target.path) else {
      throw MaiFileWorkspaceError.invalidPath(target.path)
    }
    return ToolOutput(
      content: [.text(FileManager.default.currentDirectoryPath)],
      structuredContent: .object(["cwd": .string(FileManager.default.currentDirectoryPath)]))
  }

  func list(_ arguments: [String: JSONValue]) throws -> ToolOutput {
    let rawPath = arguments["path"]?.stringValue ?? ""
    let directory = try resolve(rawPath, allowRoot: true, mustExist: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw MaiFileWorkspaceError.notDirectory(displayPath(rawPath))
    }
    let entries = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles])
      .filter {
        directory.path != rootURL.path
          || !configuration.hiddenRootEntryNames.contains($0.lastPathComponent)
      }
      .sorted {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
      }
    let visible = Array(entries.prefix(Self.maximumListEntries))
    let rows: [JSONValue] = visible.map { entry in
      let values = try? entry.resourceValues(
        forKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey])
      return .object([
        "path": .string(relativePath(entry)),
        "kind": .string(
          values?.isSymbolicLink == true ? "symlink" : values?.isDirectory == true ? "directory" : "file"),
        "bytes": .integer(values?.fileSize ?? 0),
      ])
    }
    var lines = visible.map { entry in
      let values = try? entry.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
      let suffix = values?.isDirectory == true ? "/" : " (\(values?.fileSize ?? 0) bytes)"
      return relativePath(entry) + suffix
    }
    if lines.isEmpty { lines = ["(no files)"] }
    if entries.count > visible.count {
      lines.append("Truncated: showing \(visible.count) of \(entries.count) entries.")
    }
    return ToolOutput(
      content: [.text(lines.joined(separator: "\n"))],
      structuredContent: .object([
        "workspace": .string(configuration.displayName),
        "path": .string(displayPath(rawPath)),
        "entries": .array(rows),
        "truncated": .bool(entries.count > visible.count),
      ]))
  }

  func find(_ arguments: [String: JSONValue]) throws -> ToolOutput {
    let query = try requiredText(arguments, key: "query")
    let rawPath = arguments["path"]?.stringValue ?? ""
    let directory = try resolve(rawPath, allowRoot: true, mustExist: true)
    try requireDirectory(directory, displayPath: displayPath(rawPath))
    let limit = boundedLimit(arguments["limit"]?.intValue, default: 100)
    var matches: [(url: URL, score: Int, kind: String)] = []
    var scanned = 0
    try enumerateFiles(at: directory) { url, values, enumerator in
      scanned += 1
      guard scanned <= 10_000 else {
        enumerator.skipDescendants()
        return false
      }
      let relative = relativePath(url)
      guard let score = fuzzyScore(relative, query: query) else { return true }
      let kind = values.isDirectory == true ? "directory" : "file"
      matches.append((url, score, kind))
      return true
    }
    matches.sort {
      $0.score == $1.score
        ? relativePath($0.url).localizedStandardCompare(relativePath($1.url)) == .orderedAscending
        : $0.score < $1.score
    }
    let selected = Array(matches.prefix(limit))
    let rows = selected.map { match in
      JSONValue.object([
        "path": .string(relativePath(match.url)),
        "kind": .string(match.kind),
        "score": .integer(match.score),
      ])
    }
    let text = selected.isEmpty
      ? "No files matched '\(query)'."
      : selected.map { relativePath($0.url) + ($0.kind == "directory" ? "/" : "") }
        .joined(separator: "\n")
    return ToolOutput(
      content: [.text(text)],
      structuredContent: .object([
        "query": .string(query),
        "matches": .array(rows),
        "scanned": .integer(min(scanned, 10_000)),
        "truncated": .bool(matches.count > selected.count || scanned > 10_000),
      ]))
  }

  func grep(_ arguments: [String: JSONValue]) throws -> ToolOutput {
    let query = try requiredText(arguments, key: "query")
    let rawPath = arguments["path"]?.stringValue ?? ""
    let directory = try resolve(rawPath, allowRoot: true, mustExist: true)
    try requireDirectory(directory, displayPath: displayPath(rawPath))
    let limit = boundedLimit(arguments["limit"]?.intValue, default: 100)
    let caseSensitive =
      arguments["case_sensitive"]?.coercedBoolValue ?? query.contains(where: \.isUppercase)
    let useRegex = arguments["regex"]?.coercedBoolValue == true
    let expression: NSRegularExpression?
    if useRegex {
      do {
        expression = try NSRegularExpression(
          pattern: query,
          options: caseSensitive ? [] : [.caseInsensitive])
      } catch {
        throw MaiFileWorkspaceError.invalidPattern(error.localizedDescription)
      }
    } else {
      expression = nil
    }
    var rows: [JSONValue] = []
    var rendered: [String] = []
    var scannedFiles = 0
    var hitLimit = false
    try enumerateFiles(at: directory) { url, values, enumerator in
      guard rows.count < limit, scannedFiles < 10_000 else {
        hitLimit = true
        enumerator.skipDescendants()
        return false
      }
      guard values.isRegularFile == true, values.isSymbolicLink != true else { return true }
      scannedFiles += 1
      guard (values.fileSize ?? 0) <= 5_000_000,
        let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
        !looksBinary(data),
        let text = String(data: data, encoding: .utf8)
      else { return true }
      for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
      where rows.count < limit {
        if index.isMultiple(of: 64) { try Task.checkCancellation() }
        let line = String(line)
        let matched: Bool
        if let expression {
          matched =
            expression.firstMatch(
              in: line,
              range: NSRange(line.startIndex..<line.endIndex, in: line)) != nil
        } else if caseSensitive {
          matched = line.contains(query)
        } else {
          matched = line.localizedCaseInsensitiveContains(query)
        }
        guard matched else { continue }
        let clipped = line.count > 500 ? String(line.prefix(500)) + "…" : line
        let path = relativePath(url)
        rendered.append("\(path):\(index + 1): \(clipped)")
        rows.append(
          .object([
            "path": .string(path),
            "line": .integer(index + 1),
            "text": .string(clipped),
          ]))
      }
      if rows.count == limit { hitLimit = true }
      return rows.count < limit
    }
    return ToolOutput(
      content: [.text(rendered.isEmpty ? "No matching lines." : rendered.joined(separator: "\n"))],
      structuredContent: .object([
        "query": .string(query),
        "matches": .array(rows),
        "scannedFiles": .integer(scannedFiles),
        "truncated": .bool(hitLimit),
      ]))
  }

  func read(_ arguments: [String: JSONValue]) throws -> ToolOutput {
    let rawPath = try requiredPath(arguments, key: "path")
    let file = try resolve(rawPath, allowRoot: false, mustExist: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else {
      throw MaiFileWorkspaceError.notFile(displayPath(rawPath))
    }
    let data = try Data(contentsOf: file, options: [.mappedIfSafe])
    guard !looksBinary(data) else { throw MaiFileWorkspaceError.binary(displayPath(rawPath)) }
    let window = try textWindow(data, arguments: arguments, path: rawPath)
    return ToolOutput(
      content: [
        .file(
          FileContent(
            name: file.lastPathComponent,
            mimeType: "text/plain",
            text: window.text))
      ],
      structuredContent: .object([
        "path": .string(displayPath(rawPath)),
        "totalBytes": .integer(data.count),
        "offset": .integer(window.offset),
        "nextOffset": .integer(window.nextOffset),
        "truncated": .bool(window.nextOffset < data.count),
      ]))
  }

  func readDocument(_ arguments: [String: JSONValue]) throws -> ToolOutput {
    let rawPath = try requiredPath(arguments, key: "path")
    let file = try resolve(rawPath, allowRoot: false, mustExist: true)
    let attachment = try DocumentAttachmentImporter.attachment(at: file)
    guard case .file(let content) = attachment.content, let text = content.text else {
      throw MaiFileWorkspaceError.invalidUTF8(displayPath(rawPath))
    }
    let data = Data(text.utf8)
    let window = try textWindow(data, arguments: arguments, path: rawPath)
    return ToolOutput(
      content: [
        .file(
          FileContent(
            name: content.name,
            mimeType: content.mimeType,
            text: window.text))
      ],
      structuredContent: .object([
        "path": .string(displayPath(rawPath)),
        "name": .string(attachment.name),
        "characters": .integer(attachment.characterCount),
        "totalBytes": .integer(data.count),
        "offset": .integer(window.offset),
        "nextOffset": .integer(window.nextOffset),
        "truncated": .bool(window.nextOffset < data.count),
        "conversion": attachment.note.map(JSONValue.string) ?? .null,
      ]))
  }

  func write(_ arguments: [String: JSONValue]) throws -> ToolOutput {
    try requireWriteAccess()
    let rawPath = try requiredPath(arguments, key: "path")
    let destination = try resolve(rawPath, allowRoot: false, mustExist: false)
    if arguments["create_directory"]?.coercedBoolValue == true {
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      return mutationOutput("Created directory \(displayPath(rawPath))", path: rawPath)
    }
    guard let content = arguments["content"]?.stringValue else {
      throw MaiFileWorkspaceError.missingArgument("content")
    }
    let data = Data(content.utf8)
    guard data.count <= Self.maximumWriteBytes else {
      throw MaiFileWorkspaceError.writeTooLarge(Self.maximumWriteBytes)
    }
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    {
      throw MaiFileWorkspaceError.notFile(displayPath(rawPath))
    }
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let append = arguments["append"]?.coercedBoolValue == true
    if append, FileManager.default.fileExists(atPath: destination.path) {
      let handle = try FileHandle(forWritingTo: destination)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
    } else {
      try data.write(to: destination, options: append ? [] : [.atomic])
    }
    return mutationOutput(
      "\(append ? "Appended" : "Wrote") \(data.count) bytes to \(displayPath(rawPath))",
      path: rawPath,
      extra: ["bytes": .integer(data.count), "appended": .bool(append)])
  }

  func rename(_ arguments: [String: JSONValue]) throws -> ToolOutput {
    try requireWriteAccess()
    let rawPath = try requiredPath(arguments, key: "path")
    let newPath = try requiredPath(arguments, key: "new_path")
    let source = try resolve(rawPath, allowRoot: false, mustExist: true)
    let destination = try resolve(newPath, allowRoot: false, mustExist: false)
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw MaiFileWorkspaceError.alreadyExists(displayPath(newPath))
    }
    var parentIsDirectory: ObjCBool = false
    guard FileManager.default.fileExists(
      atPath: destination.deletingLastPathComponent().path,
      isDirectory: &parentIsDirectory),
      parentIsDirectory.boolValue
    else {
      throw MaiFileWorkspaceError.notDirectory(relativePath(destination.deletingLastPathComponent()))
    }
    try FileManager.default.moveItem(at: source, to: destination)
    return mutationOutput(
      "Renamed \(displayPath(rawPath)) to \(displayPath(newPath))",
      path: newPath,
      extra: ["previousPath": .string(displayPath(rawPath))])
  }

  func delete(_ arguments: [String: JSONValue]) throws -> ToolOutput {
    try requireWriteAccess()
    let rawPath = try requiredPath(arguments, key: "path")
    let target = try resolve(rawPath, allowRoot: false, mustExist: true)
    var isDirectory: ObjCBool = false
    _ = FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory)
    if isDirectory.boolValue, arguments["recursive"]?.coercedBoolValue != true {
      let entries = try FileManager.default.contentsOfDirectory(atPath: target.path)
      guard entries.isEmpty else {
        throw MaiFileWorkspaceError.recursiveRequired(displayPath(rawPath))
      }
    }
    try FileManager.default.removeItem(at: target)
    return mutationOutput("Deleted \(displayPath(rawPath))", path: rawPath)
  }

  private func resolve(
    _ rawPath: String,
    allowRoot: Bool,
    mustExist: Bool
  ) throws -> URL {
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
      throw MaiFileWorkspaceError.outsideWorkspace(rawPath)
    }
    let candidate = rootURL.appendingPathComponent(trimmed.isEmpty ? "." : trimmed)
      .standardizedFileURL
    guard isInside(candidate) else { throw MaiFileWorkspaceError.outsideWorkspace(rawPath) }
    guard allowRoot || candidate.path != rootURL.path else {
      throw MaiFileWorkspaceError.rootNotAllowed
    }
    if FileManager.default.fileExists(atPath: candidate.path) {
      let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
      guard isInside(resolved) else { throw MaiFileWorkspaceError.outsideWorkspace(rawPath) }
      return resolved
    }
    guard !mustExist else { throw MaiFileWorkspaceError.notFound(displayPath(rawPath)) }

    var ancestor = candidate.deletingLastPathComponent()
    while ancestor.path != rootURL.path, !FileManager.default.fileExists(atPath: ancestor.path) {
      ancestor.deleteLastPathComponent()
    }
    let resolvedAncestor = ancestor.resolvingSymlinksInPath().standardizedFileURL
    guard isInside(resolvedAncestor) else {
      throw MaiFileWorkspaceError.outsideWorkspace(rawPath)
    }
    return candidate
  }

  private func enumerateFiles(
    at directory: URL,
    _ visit: (URL, URLResourceValues, FileManager.DirectoryEnumerator) throws -> Bool
  ) throws {
    let keys: Set<URLResourceKey> = [
      .fileSizeKey, .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
    ]
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles, .skipsPackageDescendants])
    else {
      throw MaiFileWorkspaceError.notDirectory(relativePath(directory))
    }
    while let url = enumerator.nextObject() as? URL {
      try Task.checkCancellation()
      let values = try url.resourceValues(forKeys: keys)
      if values.isSymbolicLink == true {
        if values.isDirectory == true { enumerator.skipDescendants() }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard isInside(resolved) else { continue }
      }
      if directory.path == rootURL.path,
        configuration.hiddenRootEntryNames.contains(url.lastPathComponent),
        url.deletingLastPathComponent().standardizedFileURL.path == rootURL.path
      {
        if values.isDirectory == true { enumerator.skipDescendants() }
        continue
      }
      guard try visit(url, values, enumerator) else { break }
    }
  }

  private func requireDirectory(_ url: URL, displayPath: String) throws {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw MaiFileWorkspaceError.notDirectory(displayPath)
    }
  }

  private func boundedLimit(_ requested: Int?, default defaultValue: Int) -> Int {
    min(max(requested ?? defaultValue, 1), 500)
  }

  private func textWindow(
    _ data: Data,
    arguments: [String: JSONValue],
    path: String
  ) throws -> (text: String, offset: Int, nextOffset: Int) {
    let requestedOffset = min(max(arguments["offset"]?.intValue ?? 0, 0), data.count)
    let limit = min(
      max(arguments["max_bytes"]?.intValue ?? Self.defaultReadLimit, 1),
      Self.maximumReadLimit)
    var chunk = Data(data.dropFirst(requestedOffset).prefix(limit))
    var offset = requestedOffset
    while let first = chunk.first, first & 0b1100_0000 == 0b1000_0000 {
      chunk.removeFirst()
      offset += 1
    }
    var text = String(data: chunk, encoding: .utf8)
    while text == nil, !chunk.isEmpty {
      chunk.removeLast()
      text = String(data: chunk, encoding: .utf8)
    }
    guard let text else { throw MaiFileWorkspaceError.invalidUTF8(displayPath(path)) }
    return (text, offset, offset + chunk.count)
  }

  private func fuzzyScore(_ candidate: String, query: String) -> Int? {
    let candidate = candidate.lowercased()
    let query = query.lowercased()
    let name = (candidate as NSString).lastPathComponent
    if name == query { return 0 }
    if candidate == query { return 1 }
    if let range = name.range(of: query) {
      return 10 + name.distance(from: name.startIndex, to: range.lowerBound) + name.count - query.count
    }
    if let range = candidate.range(of: query) {
      return 30 + candidate.distance(from: candidate.startIndex, to: range.lowerBound)
    }
    var queryIndex = query.startIndex
    var gaps = 0
    var lastMatch: String.Index?
    for index in candidate.indices where queryIndex < query.endIndex {
      guard candidate[index] == query[queryIndex] else { continue }
      if let lastMatch { gaps += candidate.distance(from: lastMatch, to: index) - 1 }
      lastMatch = index
      query.formIndex(after: &queryIndex)
    }
    return queryIndex == query.endIndex ? 100 + gaps + candidate.count - query.count : nil
  }

  private func isInside(_ url: URL) -> Bool {
    url.path == rootURL.path || url.path.hasPrefix(rootURL.path + "/")
  }

  private func relativePath(_ url: URL) -> String {
    let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
    if resolvedPath == rootURL.path { return "." }
    if resolvedPath.hasPrefix(rootURL.path + "/") {
      return String(resolvedPath.dropFirst(rootURL.path.count + 1))
    }
    let lexicalRoot = configuration.rootURL.standardizedFileURL.path
    let lexicalPath = url.standardizedFileURL.path
    if lexicalPath == lexicalRoot { return "." }
    if lexicalPath.hasPrefix(lexicalRoot + "/") {
      return String(lexicalPath.dropFirst(lexicalRoot.count + 1))
    }
    return url.lastPathComponent
  }

  private func displayPath(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty || trimmed == "." ? configuration.displayName : trimmed
  }

  private func requiredPath(
    _ arguments: [String: JSONValue],
    key: String
  ) throws -> String {
    guard let value = arguments[key]?.stringValue,
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw MaiFileWorkspaceError.missingArgument(key)
    }
    return value
  }

  private func requiredText(
    _ arguments: [String: JSONValue],
    key: String
  ) throws -> String {
    guard let value = arguments[key]?.stringValue,
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw MaiFileWorkspaceError.missingArgument(key)
    }
    return value
  }

  private func requireWriteAccess() throws {
    guard configuration.writeEnabled else { throw MaiFileWorkspaceError.writeDisabled }
  }

  private func looksBinary(_ data: Data) -> Bool {
    data.prefix(8_192).contains(0)
  }

  private func mutationOutput(
    _ text: String,
    path: String,
    extra: [String: JSONValue] = [:]
  ) -> ToolOutput {
    var values: [String: JSONValue] = ["path": .string(displayPath(path))]
    values.merge(extra) { _, new in new }
    return ToolOutput(content: [.text(text)], structuredContent: .object(values))
  }
}

private enum MaiFileWorkspaceError: LocalizedError {
  case invalidRoot(String)
  case missingArgument(String)
  case outsideWorkspace(String)
  case rootNotAllowed
  case notFound(String)
  case notFile(String)
  case notDirectory(String)
  case binary(String)
  case invalidUTF8(String)
  case alreadyExists(String)
  case recursiveRequired(String)
  case writeTooLarge(Int)
  case writeDisabled
  case invalidPattern(String)
  case invalidPath(String)

  var errorDescription: String? {
    switch self {
    case .invalidRoot(let path): "Files workspace '\(path)' is not an accessible directory."
    case .missingArgument(let name): "\(name) is required."
    case .outsideWorkspace(let path): "Path '\(path)' is outside the configured workspace."
    case .rootNotAllowed: "This operation cannot target the workspace root."
    case .notFound(let path): "'\(path)' does not exist."
    case .notFile(let path): "'\(path)' is not a file."
    case .notDirectory(let path): "'\(path)' is not a directory."
    case .binary(let path): "'\(path)' appears to be binary; text files only."
    case .invalidUTF8(let path): "'\(path)' is not valid UTF-8 text."
    case .alreadyExists(let path): "'\(path)' already exists."
    case .recursiveRequired(let path):
      "Directory '\(path)' is not empty; set recursive=true to delete it."
    case .writeTooLarge(let limit): "A single write is limited to \(limit) bytes."
    case .writeDisabled: "File changes are disabled for this tool source."
    case .invalidPattern(let detail): "Invalid regular expression: \(detail)"
    case .invalidPath(let path): "Could not change the current directory to '\(path)'."
    }
  }
}
