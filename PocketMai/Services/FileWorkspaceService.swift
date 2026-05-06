import Foundation

enum PocketMaiDirectories {
  private static let appPrivateDirectoryName = "PocketMai"
  private static let filesWorkspaceDirectoryName = "FilesData"
  private static let appPrivateFilenames = Set([
    "settings.json",
    "conversations.json",
    "conversations",
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
    try? fileManager.createDirectory(at: filesWorkspaceURL, withIntermediateDirectories: true)
    migrateLegacyDocumentsAppData(fileManager: fileManager)
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
    guard let items = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil),
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

  static func list(arguments: [String: AgentToolArgumentValue]) -> String {
    do {
      let url = try PocketMaiDirectories.ensureFilesWorkspace()
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
        return "Error: FilesData folder does not exist."
      }
      guard isDirectory.boolValue else {
        return "Error: FilesData is not a folder."
      }

      let keys: [URLResourceKey] = [
        .contentModificationDateKey,
        .fileSizeKey,
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
      ]
      let entries = try FileManager.default.contentsOfDirectory(
        at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
      )
      .sorted {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
      }

      if entries.isEmpty {
        return "FilesData files:\n(no files)"
      }

      var lines = ["FilesData files:"]
      for entry in entries.prefix(maxListEntries) {
        let values = try? entry.resourceValues(forKeys: Set(keys))
        let type =
          values?.isDirectory == true ? "directory"
          : values?.isSymbolicLink == true ? "symlink"
          : values?.isRegularFile == true ? "file" : "other"
        let size = values?.fileSize.map { " \($0) bytes" } ?? ""
        let modified = values?.contentModificationDate.map {
          " modified \(ISO8601DateFormatter().string(from: $0))"
        } ?? ""
        lines.append("- \(relativePath(for: entry)) \(type)\(size)\(modified)")
      }
      if entries.count > maxListEntries {
        lines.append("Truncated: showing \(maxListEntries) of \(entries.count) entries.")
      }
      return lines.joined(separator: "\n")
    } catch {
      return "Error: \(error.localizedDescription)"
    }
  }

  static func read(arguments: [String: AgentToolArgumentValue]) -> String {
    do {
      let path = pathArgument(arguments, primary: "path", fallback: "file") ?? ""
      guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return "Error: path is required."
      }
      let url = try validatedFileURL(path: path)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
        return "Error: file '\(displayPath(path))' does not exist."
      }
      guard !isDirectory.boolValue else {
        return "Error: '\(displayPath(path))' is a directory."
      }

      let data = try Data(contentsOf: url, options: [.mappedIfSafe])
      if looksBinary(data) {
        return "Error: '\(displayPath(path))' appears to be binary; text files only."
      }
      let requestedLimit = arguments["max_bytes"]?.numberValue.map(Int.init) ?? defaultReadLimit
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
        return "Error: '\(displayPath(path))' is not valid UTF-8 text."
      }

      var lines = [
        "File: \(displayPath(path))",
        "Bytes: \(data.count)\(truncated ? " (truncated to \(prefix.count))" : "")",
        "",
        text,
      ]
      if truncated {
        lines.append("")
        lines.append("Truncated to \(limit) bytes.")
      }
      return lines.joined(separator: "\n")
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
      if arguments["create_directory"]?.boolValue == true
        || arguments["directory"]?.boolValue == true
        || arguments["create_dirs"]?.boolValue == true
        || arguments["create_directories"]?.boolValue == true
      {
        return "Error: FilesData tools work with files only. Create folders in the Files app."
      }

      let url = try validatedFileURL(path: path)
      let content = arguments["content"]?.stringValue ?? ""
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

  private static func pathArgument(
    _ arguments: [String: AgentToolArgumentValue],
    primary: String,
    fallback: String
  ) -> String? {
    AgentTooling.firstNonEmpty(arguments[primary]?.stringValue, arguments[fallback]?.stringValue)
  }

  private static func validatedFileURL(path rawPath: String) throws -> URL {
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw NSError.fileWorkspace("Path is required.")
    }
    if trimmed == "." || trimmed == ".." {
      throw NSError.fileWorkspace("Path must be a file name.")
    }
    if trimmed.contains("/") || trimmed.contains("\\") {
      throw NSError.fileWorkspace("Folders are not supported by FilesData tools.")
    }
    if (path as NSString).isAbsolutePath {
      throw NSError.fileWorkspace("Absolute paths are not allowed.")
    }
    if trimmed.contains("\0") {
      throw NSError.fileWorkspace("Path contains an invalid character.")
    }

    let root = try PocketMaiDirectories.ensureFilesWorkspace().standardizedFileURL
    let url = root.appendingPathComponent(trimmed, isDirectory: false).standardizedFileURL
    try validateInsideWorkspace(url.deletingLastPathComponent(), root: root)
    if FileManager.default.fileExists(atPath: url.path) {
      try validateInsideWorkspace(url, root: root)
    }
    return url
  }

  private static func validateInsideWorkspace(_ url: URL, root: URL) throws {
    let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
    let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
    guard resolvedPath == rootPath || resolvedPath.hasPrefix(rootPath + "/") else {
      throw NSError.fileWorkspace("Path escapes the FilesData folder.")
    }
  }

  private static func relativePath(for url: URL) -> String {
    let rootPath = PocketMaiDirectories.filesWorkspaceURL.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
    return String(path.dropFirst(rootPath.count + 1))
  }

  private static func displayPath(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "." : trimmed
  }

  private static func looksBinary(_ data: Data) -> Bool {
    data.prefix(4096).contains(0)
  }
}

private extension NSError {
  static func fileWorkspace(_ message: String) -> NSError {
    NSError(domain: "PocketMai.FileWorkspace", code: 1, userInfo: [
      NSLocalizedDescriptionKey: message
    ])
  }
}
