import Foundation
import HFAPI

struct CachedMLXModel: Identifiable, Equatable {
  let repoID: String
  let cacheDirectoryName: String
  let directoryURL: URL
  let sizeInBytes: Int64
  let modifiedAt: Date?

  var id: String { directoryURL.path }

  var sizeText: String {
    ByteCountFormatter.string(fromByteCount: sizeInBytes, countStyle: .file)
  }

  var detailText: String {
    guard let modifiedAt else { return sizeText }
    return "\(sizeText) - \(modifiedAt.formatted(date: .abbreviated, time: .shortened))"
  }
}

enum LocalMLXHub {
  static let cache = HubCache(cacheDirectory: PocketMaiDirectories.localMLXModelCacheURL)
  static let client = HubClient(cache: cache)
}

enum LocalMLXModelCache {
  private static let modelDirectoryPrefix = "models--"
  private static let modelWeightFileExtensions: Set<String> = [
    "bin", "gguf", "npz", "safetensors",
  ]

  static var cacheRootURL: URL {
    LocalMLXHub.cache.cacheDirectory
  }

  private static var legacyDefaultCacheRootURL: URL {
    URL.cachesDirectory
      .appendingPathComponent("huggingface", isDirectory: true)
      .appendingPathComponent("hub", isDirectory: true)
  }

  static func listModels() -> [CachedMLXModel] {
    prepareCacheRoot()
    let root = cacheRootURL
    let fileManager = FileManager.default
    guard
      let urls = try? fileManager.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }

    return urls.compactMap { url in
      let directoryName = url.lastPathComponent
      guard let repoID = repoID(fromCacheDirectoryName: directoryName) else { return nil }
      guard isUsableModelCacheDirectory(url) else { return nil }
      guard
        let resourceValues = try? url.resourceValues(forKeys: [
          .isDirectoryKey, .contentModificationDateKey,
        ]),
        resourceValues.isDirectory == true
      else {
        return nil
      }

      return CachedMLXModel(
        repoID: repoID,
        cacheDirectoryName: directoryName,
        directoryURL: url,
        sizeInBytes: directorySize(url),
        modifiedAt: resourceValues.contentModificationDate
      )
    }
    .sorted {
      $0.repoID.localizedCaseInsensitiveCompare($1.repoID) == .orderedAscending
    }
  }

  static func listRepositoryIDs() -> [String] {
    prepareCacheRoot()
    let root = cacheRootURL
    let fileManager = FileManager.default
    guard
      let urls = try? fileManager.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }

    return urls.compactMap { url in
      guard let repoID = repoID(fromCacheDirectoryName: url.lastPathComponent) else {
        return nil
      }
      guard
        let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey]),
        resourceValues.isDirectory == true
      else {
        return nil
      }
      guard isUsableModelCacheDirectory(url) else { return nil }
      return repoID
    }
    .sorted {
      $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }
  }

  static func containsRepository(_ repoID: String) -> Bool {
    prepareCacheRoot()
    guard let url = cacheDirectoryURL(forRepoID: repoID) else { return false }
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
      && isUsableModelCacheDirectory(url)
  }

  static func cacheDirectoryName(for repoID: String) -> String? {
    let trimmed = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard LocalMLXRepoIDValidator.isValid(trimmed) else { return nil }
    let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    return "\(modelDirectoryPrefix)\(parts[0])--\(parts[1])"
  }

  static func repoID(fromCacheDirectoryName name: String) -> String? {
    guard name.hasPrefix(modelDirectoryPrefix) else { return nil }
    let rawRepoID = String(name.dropFirst(modelDirectoryPrefix.count))
    let parts = rawRepoID.components(separatedBy: "--")
    guard parts.count == 2 else { return nil }

    let repoID = "\(parts[0])/\(parts[1])"
    return LocalMLXRepoIDValidator.isValid(repoID) ? repoID : nil
  }

  static func cacheDirectoryURL(named name: String) -> URL? {
    guard repoID(fromCacheDirectoryName: name) != nil else { return nil }
    return cacheRootURL.appendingPathComponent(name, isDirectory: true)
  }

  static func cacheDirectoryURL(forRepoID repoID: String) -> URL? {
    guard let name = cacheDirectoryName(for: repoID) else { return nil }
    return cacheDirectoryURL(named: name)
  }

  static func deleteRepository(_ repoID: String) throws {
    guard let name = cacheDirectoryName(for: repoID) else {
      throw LocalMLXModelCacheError.invalidModelID(repoID)
    }
    try deleteCacheEntries(named: name)
  }

  static func delete(_ model: CachedMLXModel) throws {
    try deleteCacheEntries(named: model.cacheDirectoryName)
  }

  private static func deleteCacheEntries(named cacheDirectoryName: String) throws {
    prepareCacheRoot()
    var firstError: Error?
    for root in cacheRootsForDeletion() {
      for url in cacheEntryURLs(named: cacheDirectoryName, under: root) {
        do {
          try removeItemIfPresent(url, under: root)
        } catch {
          if firstError == nil {
            firstError = error
          }
        }
      }
    }
    if let firstError {
      throw firstError
    }
  }

  private static func cacheRootsForDeletion() -> [URL] {
    let roots = [
      cacheRootURL,
      legacyDefaultCacheRootURL,
    ]
    var seen = Set<String>()
    return roots.compactMap { url in
      let path = url.standardizedFileURL.path
      guard seen.insert(path).inserted else { return nil }
      return url
    }
  }

  private static func cacheEntryURLs(named cacheDirectoryName: String, under root: URL) -> [URL] {
    [
      root.appendingPathComponent(cacheDirectoryName),
      root.appendingPathComponent(".metadata").appendingPathComponent(cacheDirectoryName),
      root.appendingPathComponent(".locks").appendingPathComponent(cacheDirectoryName),
    ]
  }

  private static func prepareCacheRoot() {
    _ = try? PocketMaiDirectories.ensureLocalMLXModelCache()
    migrateLegacyDefaultCacheIfNeeded()
  }

  private static func migrateLegacyDefaultCacheIfNeeded(fileManager: FileManager = .default) {
    let sourceRoot = legacyDefaultCacheRootURL.standardizedFileURL
    let destinationRoot = cacheRootURL.standardizedFileURL
    guard sourceRoot.path != destinationRoot.path else { return }

    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: sourceRoot.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      return
    }

    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: sourceRoot,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return
    }

    try? fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
    for entry in entries {
      let name = entry.lastPathComponent
      guard repoID(fromCacheDirectoryName: name) != nil else { continue }
      migrateCacheEntry(named: name, from: sourceRoot, to: destinationRoot, fileManager: fileManager)
    }
  }

  private static func migrateCacheEntry(
    named cacheDirectoryName: String,
    from sourceRoot: URL,
    to destinationRoot: URL,
    fileManager: FileManager
  ) {
    for sourceURL in cacheEntryURLs(named: cacheDirectoryName, under: sourceRoot) {
      let relativePath = String(sourceURL.path.dropFirst(sourceRoot.path.count + 1))
      let destinationURL = appendingRelativePath(relativePath, to: destinationRoot)
      guard fileManager.fileExists(atPath: sourceURL.path) else { continue }

      if fileManager.fileExists(atPath: destinationURL.path) {
        try? fileManager.removeItem(at: sourceURL)
        continue
      }

      try? fileManager.createDirectory(
        at: destinationURL.deletingLastPathComponent(),
        withIntermediateDirectories: true)

      do {
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
      } catch {
        do {
          try fileManager.copyItem(at: sourceURL, to: destinationURL)
          try? fileManager.removeItem(at: sourceURL)
        } catch {
          try? fileManager.removeItem(at: destinationURL)
        }
      }
    }
  }

  private static func appendingRelativePath(_ relativePath: String, to root: URL) -> URL {
    var url = root
    for component in relativePath.split(separator: "/", omittingEmptySubsequences: true) {
      url.appendPathComponent(String(component))
    }
    return url
  }

  private static func isUsableModelCacheDirectory(_ url: URL) -> Bool {
    let snapshotsURL = url.appendingPathComponent("snapshots", isDirectory: true)
    guard
      let snapshotURLs = try? FileManager.default.contentsOfDirectory(
        at: snapshotsURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return false
    }

    return snapshotURLs.contains { isUsableSnapshotDirectory($0) }
  }

  private static func isUsableSnapshotDirectory(_ url: URL) -> Bool {
    guard isDirectory(url) else { return false }
    guard isReachableFile(url.appendingPathComponent("config.json")) else { return false }
    return containsReachableModelWeights(in: url)
  }

  private static func containsReachableModelWeights(in url: URL) -> Bool {
    guard
      let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return false
    }

    for case let fileURL as URL in enumerator {
      guard modelWeightFileExtensions.contains(fileURL.pathExtension.lowercased()) else {
        continue
      }
      if isReachableFile(fileURL) {
        return true
      }
    }
    return false
  }

  private static func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  private static func isReachableFile(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else {
      return false
    }

    let resolvedURL = url.resolvingSymlinksInPath()
    var resolvedIsDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: resolvedURL.path, isDirectory: &resolvedIsDirectory)
      && !resolvedIsDirectory.boolValue
  }

  private static func directorySize(_ url: URL) -> Int64 {
    let keys: Set<URLResourceKey> = [
      .isRegularFileKey,
      .isSymbolicLinkKey,
      .fileAllocatedSizeKey,
      .totalFileAllocatedSizeKey,
    ]
    guard
      let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
      )
    else {
      return 0
    }

    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
      guard let values = try? fileURL.resourceValues(forKeys: keys) else { continue }
      if values.isRegularFile == true || values.isSymbolicLink == true {
        total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
      }
    }
    return total
  }

  private static func removeItemIfPresent(_ url: URL, under root: URL) throws {
    let rootPath = root.standardizedFileURL.path
    let itemURL = url.standardizedFileURL
    guard itemURL.path.hasPrefix(rootPath + "/") else {
      throw LocalMLXModelCacheError.invalidCachePath
    }
    guard FileManager.default.fileExists(atPath: itemURL.path) else { return }
    try FileManager.default.removeItem(at: itemURL)
  }
}

enum LocalMLXModelCacheError: LocalizedError {
  case invalidCachePath
  case invalidModelID(String)

  var errorDescription: String? {
    switch self {
    case .invalidCachePath:
      return "Refusing to delete a path outside the Hugging Face cache."
    case .invalidModelID(let id):
      return "Invalid MLX model id: \(id)."
    }
  }
}
