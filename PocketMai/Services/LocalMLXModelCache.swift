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

enum LocalMLXModelCache {
  private static let modelDirectoryPrefix = "models--"

  static var cacheRootURL: URL {
    HubClient.default.cache.cacheDirectory
  }

  static func listModels() -> [CachedMLXModel] {
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
      return repoID
    }
    .sorted {
      $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }
  }

  static func containsRepository(_ repoID: String) -> Bool {
    guard let url = cacheDirectoryURL(forRepoID: repoID) else { return false }
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
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
    let root = cacheRootURL
    let cacheEntries = [
      root.appendingPathComponent(cacheDirectoryName),
      root.appendingPathComponent(".metadata").appendingPathComponent(cacheDirectoryName),
      root.appendingPathComponent(".locks").appendingPathComponent(cacheDirectoryName),
    ]

    for url in cacheEntries {
      try removeItemIfPresent(url, under: root)
    }
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
