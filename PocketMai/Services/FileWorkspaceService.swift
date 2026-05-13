import Foundation

enum PocketMaiDirectories {
  private static let appPrivateDirectoryName = "PocketMai"
  private static let filesWorkspaceDirectoryName = "FilesData"
  private static let appPrivateFilenames = Set([
    "settings.json",
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
    try? fileManager.createDirectory(at: appDataURL, withIntermediateDirectories: true)
    try? fileManager.createDirectory(at: voiceRecordingsURL, withIntermediateDirectories: true)
    try? fileManager.createDirectory(at: filesWorkspaceURL, withIntermediateDirectories: true)
    migrateLegacyDocumentsAppData(fileManager: fileManager)
  }

  @discardableResult
  static func ensureVoiceRecordings() throws -> URL {
    let url = voiceRecordingsURL
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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

enum FileWorkspaceService {
  private static let maxListEntries = 500
  private static let defaultReadLimit = 120_000
  private static let maxReadLimit = 500_000
  private static let maxWriteBytes = 1_000_000
  private static let workspaceFolderName = "FilesData"
  private static let modelsFolderName = "Models"
  private static let listResourceKeys: [URLResourceKey] = [
    .contentModificationDateKey,
    .fileSizeKey,
    .isDirectoryKey,
    .isRegularFileKey,
    .isSymbolicLinkKey,
  ]

  static func list(arguments: [String: AgentToolArgumentValue]) -> String {
    do {
      if let path = optionalPathArgument(arguments) {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isWorkspaceRootPath(trimmedPath) {
          let url = try validatedWorkspaceURL(path: trimmedPath, allowRoot: true)
          return try listWorkspaceDirectory(at: url)
        }
      }

      return try listWorkspaceDirectory(at: try workspaceRootURL())
    } catch {
      return "Error: \(error.localizedDescription)"
    }
  }

  private static func listWorkspaceDirectory(at url: URL) throws -> String {
    let root = try workspaceRootURL()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      throw NSError.fileWorkspace("Folder '\(workspacePath(for: url))' does not exist.")
    }
    guard isDirectory.boolValue else {
      throw NSError.fileWorkspace("'\(workspacePath(for: url))' is not a folder.")
    }

    let entries = try FileManager.default.contentsOfDirectory(
      at: url, includingPropertiesForKeys: listResourceKeys, options: [.skipsHiddenFiles]
    )
    .filter { entry in
      url.standardizedFileURL.path != root.path || entry.lastPathComponent != modelsFolderName
    }
    .sorted {
      $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
    }

    var lines = ["\(workspacePath(for: url)) files:"]
    if entries.isEmpty {
      lines.append("(no files)")
    }
    for entry in entries.prefix(maxListEntries) {
      lines.append(entryLine(for: entry, path: relativePath(for: entry)))
    }
    if entries.count > maxListEntries {
      lines.append("Truncated: showing \(maxListEntries) of \(entries.count) entries.")
    }
    return lines.joined(separator: "\n")
  }

  static func read(arguments: [String: AgentToolArgumentValue]) -> String {
    do {
      let path = pathArgument(arguments, primary: "path", fallback: "file") ?? ""
      guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return "Error: path is required."
      }
      let url = try validatedFileURL(path: path)
      let requestedLimit = arguments["max_bytes"]?.numberValue.map(Int.init) ?? defaultReadLimit
      return try readTextFile(
        at: url,
        displayPath: displayPath(path),
        requestedLimit: requestedLimit)
    } catch {
      return "Error: \(error.localizedDescription)"
    }
  }

  static func write(arguments: [String: AgentToolArgumentValue]) -> String {
    do {
      let path = pathArgument(arguments, primary: "path", fallback: "file") ?? ""
      guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return "Error: path is required."
      }
      let append = arguments["append"]?.boolValue ?? false
      let createDirectoryRequested = shouldCreateDirectory(arguments)
      let url = try validatedFileURL(path: path)
      let root = try workspaceRootURL()

      if createDirectoryRequested {
        return try createDirectory(at: url, path: path, root: root)
      }

      guard let contentValue = arguments["content"] ?? arguments["text"] else {
        return "Error: content is required."
      }
      let content = contentValue.stringValue
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

      try ensureParentDirectory(for: url, root: root, createIfNeeded: true)

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
    } catch {
      return "Error: \(error.localizedDescription)"
    }
  }

  static func delete(arguments: [String: AgentToolArgumentValue]) -> String {
    do {
      let path = pathArgument(arguments, primary: "path", fallback: "file") ?? ""
      guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return "Error: path is required."
      }
      let recursive = arguments["recursive"]?.boolValue ?? false
      let url = try validatedFileURL(path: path)
      let root = try workspaceRootURL()

      var isDirectoryFlag: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectoryFlag) else {
        return "Error: path '\(displayPath(path))' does not exist."
      }
      try validateInsideWorkspace(url, root: root)

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
    } catch {
      return "Error: \(error.localizedDescription)"
    }
  }

  static func rename(arguments: [String: AgentToolArgumentValue]) -> String {
    do {
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

      let url = try validatedFileURL(path: path)
      let newURL = try validatedFileURL(path: newPath)
      if url.path == newURL.path {
        return "File is already named \(displayPath(newPath))"
      }

      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
        return "Error: file '\(displayPath(path))' does not exist."
      }
      guard !isDirectory.boolValue else {
        return "Error: '\(displayPath(path))' is a directory."
      }
      guard !FileManager.default.fileExists(atPath: newURL.path) else {
        return "Error: file '\(displayPath(newPath))' already exists."
      }
      try ensureParentDirectory(for: newURL, root: try workspaceRootURL(), createIfNeeded: false)

      try FileManager.default.moveItem(at: url, to: newURL)
      return "Renamed \(displayPath(path)) to \(displayPath(newPath))"
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
    requestedLimit: Int
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
    let limit = min(max(requestedLimit, 1), maxReadLimit)
    let truncated = data.count > limit
    var prefix = Data(data.prefix(limit))
    var text: String?
    while text == nil && !prefix.isEmpty {
      text = String(data: prefix, encoding: .utf8)
      if text == nil {
        prefix.removeLast()
      }
    }
    guard let text else {
      return "Error: '\(displayPath)' is not valid UTF-8 text."
    }

    var lines = [
      "File: \(displayPath)",
      "Bytes: \(data.count)\(truncated ? " (truncated to \(prefix.count))" : "")",
      "",
      text,
    ]
    if truncated {
      lines.append("")
      lines.append("Truncated to \(limit) bytes.")
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

  private static func createDirectory(at url: URL, path: String, root: URL) throws -> String {
    try ensureParentDirectory(for: url, root: root, createIfNeeded: true)

    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else {
        throw NSError.fileWorkspace("File '\(displayPath(path))' already exists.")
      }
      return "Directory already exists \(displayPath(path))"
    }

    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try validateInsideWorkspace(url, root: root)
    return "Created directory \(displayPath(path))"
  }

  private static func validatedFileURL(path rawPath: String) throws -> URL {
    try validatedWorkspaceURL(path: rawPath, allowRoot: false)
  }

  private static func validatedWorkspaceURL(path rawPath: String, allowRoot: Bool) throws -> URL {
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw NSError.fileWorkspace("Path is required.")
    }
    if trimmed.contains("\0") {
      throw NSError.fileWorkspace("Path contains an invalid character.")
    }
    if trimmed.contains("\\") {
      throw NSError.fileWorkspace("Use forward slashes inside FilesData paths.")
    }

    let root = try workspaceRootURL()
    if (trimmed as NSString).isAbsolutePath {
      let url = URL(fileURLWithPath: trimmed, isDirectory: false).standardizedFileURL
      try validateInsideWorkspace(url, root: root, resolvingSymlinks: false)
      if !allowRoot && url.path == root.path {
        throw NSError.fileWorkspace("Path must name a file or folder inside FilesData.")
      }
      try validateWorkspacePathIsNotReserved(url, root: root)
      if FileManager.default.fileExists(atPath: url.path) {
        try validateInsideWorkspace(url, root: root)
      }
      return url
    }

    let components = try workspacePathComponents(trimmed, allowRoot: allowRoot)
    var url = root
    for component in components {
      url.appendPathComponent(component)
    }
    url = url.standardizedFileURL
    try validateInsideWorkspace(url, root: root, resolvingSymlinks: false)
    if FileManager.default.fileExists(atPath: url.path) {
      try validateInsideWorkspace(url, root: root)
    }
    return url
  }

  private static func workspacePathComponents(
    _ rawPath: String,
    allowRoot: Bool
  ) throws -> [String] {
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    if isWorkspaceRootPath(trimmed) {
      if allowRoot { return [] }
      throw NSError.fileWorkspace("Path must name a file or folder inside FilesData.")
    }

    var relativePath = trimmed
    if relativePath.hasPrefix(workspaceFolderName + "/") {
      relativePath.removeFirst(workspaceFolderName.count + 1)
    }
    if isWorkspaceRootPath(relativePath) {
      if allowRoot { return [] }
      throw NSError.fileWorkspace("Path must name a file or folder inside FilesData.")
    }
    if isModelsPath(relativePath) {
      throw NSError.fileWorkspace("Models is not available through FilesData tools.")
    }

    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
      .map(String.init)
    guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      throw NSError.fileWorkspace("FilesData path contains an invalid component.")
    }
    return components
  }

  private static func validateWorkspacePathIsNotReserved(_ url: URL, root: URL) throws {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath + "/") else { return }
    let relativePath = String(path.dropFirst(rootPath.count + 1))
    let firstComponent = relativePath.split(separator: "/", maxSplits: 1).first.map(String.init)
    if firstComponent == modelsFolderName {
      throw NSError.fileWorkspace("Models is not available through FilesData tools.")
    }
  }

  private static func isWorkspaceRootPath(_ path: String) -> Bool {
    path.isEmpty || path == "." || path == workspaceFolderName
  }

  private static func ensureParentDirectory(
    for url: URL,
    root: URL,
    createIfNeeded: Bool
  ) throws {
    let parent = url.deletingLastPathComponent().standardizedFileURL
    try validateInsideWorkspace(parent, root: root, resolvingSymlinks: false)

    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else {
        throw NSError.fileWorkspace("Parent path '\(workspacePath(for: parent))' is not a folder.")
      }
      try validateInsideWorkspace(parent, root: root)
      return
    }

    guard createIfNeeded else {
      throw NSError.fileWorkspace("Folder '\(workspacePath(for: parent))' does not exist.")
    }

    let ancestor = existingAncestor(for: parent, root: root)
    try validateInsideWorkspace(ancestor, root: root)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try validateInsideWorkspace(parent, root: root)
  }

  private static func existingAncestor(for url: URL, root: URL) -> URL {
    let rootPath = root.standardizedFileURL.path
    var current = url.standardizedFileURL
    while current.path != rootPath && !FileManager.default.fileExists(atPath: current.path) {
      current = current.deletingLastPathComponent().standardizedFileURL
    }
    return current.path.hasPrefix(rootPath) ? current : root
  }

  private static func workspaceRootURL() throws -> URL {
    let root = try PocketMaiDirectories.ensureFilesWorkspace().standardizedFileURL
    try validateInsideWorkspace(root, root: root, resolvingSymlinks: false)
    return root
  }

  private static func validateInsideWorkspace(
    _ url: URL,
    root: URL,
    resolvingSymlinks: Bool = true
  ) throws {
    try validateInsideDirectory(
      url,
      root: root,
      message: "Path must be inside FilesData.",
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

  private static func relativePath(for url: URL) -> String {
    let rootPath = PocketMaiDirectories.filesWorkspaceURL.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
    return String(path.dropFirst(rootPath.count + 1))
  }

  private static func workspacePath(for url: URL) -> String {
    let rootPath = PocketMaiDirectories.filesWorkspaceURL.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    if path == rootPath {
      return workspaceFolderName
    }
    guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
    return "\(workspaceFolderName)/\(String(path.dropFirst(rootPath.count + 1)))"
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
