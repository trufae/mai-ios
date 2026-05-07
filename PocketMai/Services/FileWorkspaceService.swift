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
        if !trimmedPath.isEmpty, trimmedPath != ".", trimmedPath != "FilesData" {
          guard isModelsPath(trimmedPath) else {
            return "Error: only FilesData and the read-only Models folder can be listed."
          }
          return try listModelsPath(trimmedPath)
        }
      }

      let url = try workspaceRootURL()
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
        return "Error: FilesData folder does not exist."
      }
      guard isDirectory.boolValue else {
        return "Error: FilesData is not a folder."
      }

      let entries = try FileManager.default.contentsOfDirectory(
        at: url, includingPropertiesForKeys: listResourceKeys, options: [.skipsHiddenFiles]
      )
      .filter { $0.lastPathComponent != modelsFolderName }
      .sorted {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
      }

      var lines = ["FilesData files:", "- \(modelsFolderName) directory read-only"]
      for entry in entries.prefix(maxListEntries) {
        lines.append(entryLine(for: entry, path: relativePath(for: entry)))
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
      let url =
        isModelsPath(path)
        ? try validatedModelsFileURL(path: path)
        : try validatedFileURL(path: path)
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
      if arguments["create_directory"]?.boolValue == true
        || arguments["directory"]?.boolValue == true
        || arguments["create_dirs"]?.boolValue == true
        || arguments["create_directories"]?.boolValue == true
      {
        return "Error: FilesData tools work with files only. Create folders in the Files app."
      }

      let url = try validatedFileURL(path: path)
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

      if content.isEmpty && !append {
        guard FileManager.default.fileExists(atPath: url.path) else {
          return "Error: file '\(displayPath(path))' does not exist."
        }
        try FileManager.default.removeItem(at: url)
        return "Deleted \(displayPath(path))"
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

  private static func optionalPathArgument(_ arguments: [String: AgentToolArgumentValue]) -> String? {
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

  private static func listModelsPath(_ rawPath: String) throws -> String {
    let components = try modelsPathComponents(rawPath)
    if components.count == 1 {
      let models = LocalMLXModelCache.listModels()
      var lines = ["FilesData/\(modelsFolderName) files:"]
      if models.isEmpty {
        lines.append("(no downloaded models)")
        return lines.joined(separator: "\n")
      }

      for model in models.prefix(maxListEntries) {
        let modified = model.modifiedAt.map {
          " modified \(ISO8601DateFormatter().string(from: $0))"
        } ?? ""
        lines.append(
          "- \(modelsFolderName)/\(model.cacheDirectoryName) directory \(model.sizeText)\(modified)"
        )
      }
      if models.count > maxListEntries {
        lines.append("Truncated: showing \(maxListEntries) of \(models.count) entries.")
      }
      return lines.joined(separator: "\n")
    }

    let url = try validatedModelsURL(components: components)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      throw NSError.fileWorkspace("Folder '\(components.joined(separator: "/"))' does not exist.")
    }
    guard isDirectory.boolValue else {
      throw NSError.fileWorkspace("'\(components.joined(separator: "/"))' is not a folder.")
    }

    let entries = try FileManager.default.contentsOfDirectory(
      at: url,
      includingPropertiesForKeys: listResourceKeys,
      options: [.skipsHiddenFiles]
    )
    .sorted {
      $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
    }

    var lines = ["FilesData/\(components.joined(separator: "/")) files:"]
    if entries.isEmpty {
      lines.append("(no files)")
      return lines.joined(separator: "\n")
    }
    for entry in entries.prefix(maxListEntries) {
      lines.append(entryLine(for: entry, path: modelsRelativePath(for: entry)))
    }
    if entries.count > maxListEntries {
      lines.append("Truncated: showing \(maxListEntries) of \(entries.count) entries.")
    }
    return lines.joined(separator: "\n")
  }

  private static func validatedModelsFileURL(path rawPath: String) throws -> URL {
    let components = try modelsPathComponents(rawPath)
    guard components.count >= 2 else {
      throw NSError.fileWorkspace("Path must name a file under Models.")
    }
    return try validatedModelsURL(components: components)
  }

  private static func validatedModelsURL(components: [String]) throws -> URL {
    guard components.count >= 2 else {
      throw NSError.fileWorkspace("Path must name a downloaded model under Models.")
    }
    let cacheDirectoryName = components[1]
    guard let modelRoot = LocalMLXModelCache.cacheDirectoryURL(named: cacheDirectoryName) else {
      throw NSError.fileWorkspace("Unknown downloaded model '\(cacheDirectoryName)'.")
    }

    var url = modelRoot
    for component in components.dropFirst(2) {
      url.appendPathComponent(component)
    }
    try validateInsideDirectory(
      url,
      root: modelRoot,
      message: "Path must stay inside Models/\(cacheDirectoryName).",
      resolvingSymlinks: false)
    if FileManager.default.fileExists(atPath: url.path) {
      try validateInsideDirectory(
        url,
        root: modelRoot,
        message: "Path must stay inside Models/\(cacheDirectoryName).")
    }
    return url
  }

  private static func modelsPathComponents(_ rawPath: String) throws -> [String] {
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw NSError.fileWorkspace("Path is required.")
    }
    guard isModelsPath(trimmed) else {
      throw NSError.fileWorkspace("Path must start with Models.")
    }
    if (trimmed as NSString).isAbsolutePath {
      throw NSError.fileWorkspace("Models paths must be relative.")
    }
    if trimmed.contains("\0") {
      throw NSError.fileWorkspace("Path contains an invalid character.")
    }
    if trimmed.contains("\\") {
      throw NSError.fileWorkspace("Use forward slashes inside Models paths.")
    }

    let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
      .map(String.init)
    guard components.first == modelsFolderName else {
      throw NSError.fileWorkspace("Path must start with Models.")
    }
    guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      throw NSError.fileWorkspace("Models path contains an invalid component.")
    }
    return components
  }

  private static func validatedFileURL(path rawPath: String) throws -> URL {
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw NSError.fileWorkspace("Path is required.")
    }
    if trimmed.contains("\0") {
      throw NSError.fileWorkspace("Path contains an invalid character.")
    }
    if trimmed.contains("\\") {
      throw NSError.fileWorkspace("Folders are not supported by FilesData tools.")
    }
    if isModelsPath(trimmed) {
      throw NSError.fileWorkspace("Models is read-only. Use files_list or files_read for Models.")
    }

    let root = try workspaceRootURL()
    let url: URL
    if (trimmed as NSString).isAbsolutePath {
      url = URL(fileURLWithPath: trimmed, isDirectory: false).standardizedFileURL
      try validateInsideWorkspace(url, root: root, resolvingSymlinks: false)
      try validateTopLevelFileURL(url, root: root)
    } else {
      if trimmed == "." || trimmed == ".." {
        throw NSError.fileWorkspace("Path must be a file name.")
      }
      if trimmed.contains("/") {
        throw NSError.fileWorkspace("Folders are not supported by FilesData tools.")
      }
      url = root.appendingPathComponent(trimmed, isDirectory: false).standardizedFileURL
      try validateInsideWorkspace(url, root: root, resolvingSymlinks: false)
      try validateTopLevelFileURL(url, root: root)
    }

    if FileManager.default.fileExists(atPath: url.path) {
      try validateInsideWorkspace(url, root: root)
    }
    return url
  }

  private static func workspaceRootURL() throws -> URL {
    let root = try PocketMaiDirectories.ensureFilesWorkspace().standardizedFileURL
    try validateInsideWorkspace(root, root: root, resolvingSymlinks: false)
    return root
  }

  private static func validateTopLevelFileURL(_ url: URL, root: URL) throws {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path != rootPath else {
      throw NSError.fileWorkspace("Path must be a file name.")
    }
    guard url.deletingLastPathComponent().standardizedFileURL.path == rootPath else {
      throw NSError.fileWorkspace("Folders are not supported by FilesData tools.")
    }
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
      values?.isDirectory == true ? "directory"
      : values?.isSymbolicLink == true ? "symlink"
      : values?.isRegularFile == true ? "file" : "other"
    let size = values?.fileSize.map { " \($0) bytes" } ?? ""
    let modified = values?.contentModificationDate.map {
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

  private static func modelsRelativePath(for url: URL) -> String {
    let rootPath = LocalMLXModelCache.cacheRootURL.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath + "/") else {
      return "\(modelsFolderName)/\(url.lastPathComponent)"
    }
    return "\(modelsFolderName)/\(String(path.dropFirst(rootPath.count + 1)))"
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
