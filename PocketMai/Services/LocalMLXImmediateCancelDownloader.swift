import Foundation
import HFAPI
import MLXLMCommon

// Owns the URLSession tasks used by Settings downloads so cancellation can close them immediately.
struct LocalMLXImmediateCancelDownloader: Downloader {
  private let hub = LocalMLXHub.client

  func download(
    id: String,
    revision: String?,
    matching patterns: [String],
    useLatest: Bool,
    progressHandler: @Sendable @escaping (Progress) -> Void
  ) async throws -> URL {
    guard let repo = Repo.ID(rawValue: id) else {
      throw LocalMLXHubDownloadError.invalidRepositoryID(id)
    }

    let revision = revision ?? "main"
    if !useLatest,
      let cached = hub.resolveCachedSnapshot(
        repo: repo,
        revision: revision,
        matching: patterns)
    {
      let completedBytes = Self.directoryFileSize(cached)
      let progress = Progress(totalUnitCount: max(completedBytes, 1))
      progress.kind = .file
      progress.completedUnitCount = progress.totalUnitCount
      progressHandler(progress)
      return cached
    }

    let allEntries = try await hub.listFiles(in: repo, revision: revision)
    let entries = allEntries
      .filter { $0.type == .file }
      .filter { entry in
        patterns.isEmpty || patterns.contains { Self.wildcard($0, matches: entry.path) }
      }
      .sorted {
        $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
      }

    guard !entries.isEmpty else {
      throw LocalMLXHubDownloadError.noMatchingFiles(id)
    }

    let knownTotalBytes = entries.reduce(Int64(0)) { partial, entry in
      partial + Int64(entry.size ?? 0)
    }
    let hasKnownTotal = entries.allSatisfy { $0.size != nil } && knownTotalBytes > 0
    let totalProgress = Progress(totalUnitCount: hasKnownTotal ? knownTotalBytes : 0)
    totalProgress.kind = .file
    progressHandler(totalProgress)

    let startedAt = Date()
    var completedBytes: Int64 = 0
    var commitHash: String?

    func reportProgress(completedBytes bytes: Int64) {
      totalProgress.completedUnitCount = bytes
      if hasKnownTotal {
        totalProgress.totalUnitCount = knownTotalBytes
      }
      let elapsed = Date().timeIntervalSince(startedAt)
      if elapsed > 0, bytes > 0 {
        totalProgress.setUserInfoObject(Double(bytes) / elapsed, forKey: .throughputKey)
      }
      progressHandler(totalProgress)
    }

    func updateProgress() {
      reportProgress(completedBytes: completedBytes)
    }

    for entry in entries {
      try Task.checkCancellation()
      let metadata = try await fetchMetadata(repo: repo, revision: revision, path: entry.path)
      let fileCommitHash = metadata.commitHash
      let fileSize = metadata.size ?? entry.size.map(Int64.init) ?? 0
      if commitHash == nil {
        commitHash = fileCommitHash
      }

      if isCached(repo: repo, revision: fileCommitHash, path: entry.path, expectedSize: fileSize) {
        completedBytes += fileSize
        updateProgress()
        continue
      }

      if let blob = hub.cache.cachedBlobPath(repo: repo, kind: .model, etag: metadata.etag) {
        if isFileSizeValid(blob, expectedSize: fileSize) {
          try hub.cache.createSnapshotSymlink(
            repo: repo,
            kind: .model,
            revision: fileCommitHash,
            filename: entry.path,
            etag: metadata.etag)
          completedBytes += fileSize
          updateProgress()
          continue
        }
        try? FileManager.default.removeItem(at: blob)
      }

      let request = try await makeRequest(
        method: "GET",
        repo: repo,
        revision: revision,
        path: entry.path)
      let fileBaseBytes = completedBytes
      let tempURL = try await LocalMLXURLSessionDownload.download(request: request) {
        bytesWritten,
        _ in
        reportProgress(completedBytes: fileBaseBytes + bytesWritten)
      }
      defer { try? FileManager.default.removeItem(at: tempURL) }

      try Task.checkCancellation()
      if fileSize > 0, !isFileSizeValid(tempURL, expectedSize: fileSize) {
        let actual = Self.fileSize(tempURL)
        throw LocalMLXHubDownloadError.fileSizeMismatch(
          path: entry.path,
          expected: fileSize,
          actual: actual)
      }

      try await hub.cache.storeFile(
        at: tempURL,
        repo: repo,
        kind: .model,
        revision: fileCommitHash,
        filename: entry.path,
        etag: metadata.etag,
        ref: revision == fileCommitHash ? nil : revision)

      completedBytes += fileSize
      updateProgress()
    }

    guard let commitHash else {
      throw LocalMLXHubDownloadError.missingCommit(id)
    }
    if revision != commitHash {
      try? hub.cache.updateRef(repo: repo, kind: .model, ref: revision, commit: commitHash)
    }

    totalProgress.completedUnitCount = hasKnownTotal ? knownTotalBytes : completedBytes
    if hasKnownTotal {
      totalProgress.totalUnitCount = knownTotalBytes
    }
    progressHandler(totalProgress)

    if let snapshot = hub.cache.snapshotPath(repo: repo, kind: .model, revision: commitHash) {
      return snapshot
    }
    throw LocalMLXHubDownloadError.missingSnapshot(id)
  }

  private func fetchMetadata(
    repo: Repo.ID,
    revision: String,
    path: String
  ) async throws -> LocalMLXFileMetadata {
    let request = try await makeRequest(method: "HEAD", repo: repo, revision: revision, path: path)
    let session = URLSession(
      configuration: .default,
      delegate: LocalMLXSameHostRedirectDelegate(),
      delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }

    let (_, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw LocalMLXHubDownloadError.invalidResponse(path)
    }
    guard (200..<400).contains(httpResponse.statusCode) else {
      throw LocalMLXHubDownloadError.httpError(path: path, statusCode: httpResponse.statusCode)
    }

    let etag = httpResponse.value(forHTTPHeaderField: "X-Linked-Etag")
      ?? httpResponse.value(forHTTPHeaderField: "ETag")
    let commitHash = httpResponse.value(forHTTPHeaderField: "X-Repo-Commit")
    let linkedSize = httpResponse.value(forHTTPHeaderField: "X-Linked-Size")
    let contentLength =
      (200..<300).contains(httpResponse.statusCode)
      ? httpResponse.value(forHTTPHeaderField: "Content-Length")
      : nil
    guard let etag, let commitHash else {
      throw LocalMLXHubDownloadError.missingMetadata(path)
    }

    return LocalMLXFileMetadata(
      commitHash: commitHash,
      etag: HubCache.normalizeEtag(etag),
      size: (linkedSize ?? contentLength).flatMap(Int64.init))
  }

  private func makeRequest(
    method: String,
    repo: Repo.ID,
    revision: String,
    path: String
  ) async throws -> URLRequest {
    var request = URLRequest(url: fileURL(repo: repo, revision: revision, path: path))
    request.httpMethod = method
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    if let userAgent = hub.userAgent {
      request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    }
    if let token = await hub.bearerToken {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    return request
  }

  private func fileURL(repo: Repo.ID, revision: String, path: String) -> URL {
    hub.host
      .appendingPathComponent(repo.namespace)
      .appendingPathComponent(repo.name)
      .appendingPathComponent("resolve")
      .appendingPathComponent(revision)
      .appendingPathComponent(path)
  }

  private func isCached(
    repo: Repo.ID,
    revision: String,
    path: String,
    expectedSize: Int64
  ) -> Bool {
    guard let cached = hub.cache.cachedFilePath(
      repo: repo,
      kind: .model,
      revision: revision,
      filename: path)
    else {
      return false
    }
    return expectedSize <= 0
      || isFileSizeValid(cached.resolvingSymlinksInPath(), expectedSize: expectedSize)
  }

  private func isFileSizeValid(_ url: URL, expectedSize: Int64) -> Bool {
    expectedSize <= 0 || Self.fileSize(url) == expectedSize
  }

  private static func fileSize(_ url: URL) -> Int64 {
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
      .int64Value
    return size ?? 0
  }

  private static func directoryFileSize(_ url: URL) -> Int64 {
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    guard let enumerator = FileManager.default.enumerator(
      at: url,
      includingPropertiesForKeys: keys,
      options: [.skipsHiddenFiles])
    else {
      return 0
    }

    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
      guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
        values.isRegularFile == true || values.isSymbolicLink == true
      else {
        continue
      }
      let sizeURL = values.isSymbolicLink == true ? fileURL.resolvingSymlinksInPath() : fileURL
      total += fileSize(sizeURL)
    }
    return total
  }

  private static func wildcard(_ pattern: String, matches text: String) -> Bool {
    var regex = "^"
    for scalar in pattern.unicodeScalars {
      switch scalar {
      case "*":
        regex += ".*"
      case "?":
        regex += "."
      default:
        regex += NSRegularExpression.escapedPattern(for: String(scalar))
      }
    }
    regex += "$"
    return text.range(of: regex, options: [.regularExpression]) != nil
  }
}

private struct LocalMLXFileMetadata {
  let commitHash: String
  let etag: String
  let size: Int64?
}

private enum LocalMLXHubDownloadError: LocalizedError {
  case invalidRepositoryID(String)
  case noMatchingFiles(String)
  case missingMetadata(String)
  case missingCommit(String)
  case missingSnapshot(String)
  case invalidResponse(String)
  case httpError(path: String, statusCode: Int)
  case fileSizeMismatch(path: String, expected: Int64, actual: Int64)

  var errorDescription: String? {
    switch self {
    case .invalidRepositoryID(let id):
      return "Invalid Hugging Face repository ID: \(id)."
    case .noMatchingFiles(let repo):
      return "No MLX model files were found in \(repo)."
    case .missingMetadata(let path):
      return "Could not read download metadata for \(path)."
    case .missingCommit(let repo):
      return "Could not resolve a commit for \(repo)."
    case .missingSnapshot(let repo):
      return "Downloaded files for \(repo), but the local snapshot was not created."
    case .invalidResponse(let path):
      return "Invalid response while checking \(path)."
    case .httpError(let path, let statusCode):
      return "Download request for \(path) failed with HTTP \(statusCode)."
    case .fileSizeMismatch(let path, let expected, let actual):
      let expectedText = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
      let actualText = ByteCountFormatter.string(fromByteCount: actual, countStyle: .file)
      return "Downloaded \(path) is incomplete: \(actualText) of \(expectedText)."
    }
  }
}

private final class LocalMLXSameHostRedirectDelegate: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let originalHost = task.originalRequest?.url?.host,
      let newHost = request.url?.host
    else {
      completionHandler(nil)
      return
    }

    if originalHost == newHost {
      var redirectRequest = request
      if let originalHeaders = task.originalRequest?.allHTTPHeaderFields {
        for (key, value) in originalHeaders where redirectRequest.value(forHTTPHeaderField: key) == nil {
          redirectRequest.setValue(value, forHTTPHeaderField: key)
        }
      }
      completionHandler(redirectRequest)
    } else {
      completionHandler(nil)
    }
  }
}

private final class LocalMLXDownloadCancellationBox: @unchecked Sendable {
  private let lock = NSLock()
  private var session: URLSession?
  private var task: URLSessionTask?
  private var isCancelled = false

  func set(session: URLSession, task: URLSessionTask) {
    lock.lock()
    if isCancelled {
      lock.unlock()
      task.cancel()
      session.invalidateAndCancel()
      return
    }
    self.session = session
    self.task = task
    lock.unlock()
  }

  func cancel() {
    lock.lock()
    isCancelled = true
    let session = session
    let task = task
    lock.unlock()
    task?.cancel()
    session?.invalidateAndCancel()
  }

  func finish() {
    lock.lock()
    let session = session
    self.session = nil
    self.task = nil
    lock.unlock()
    session?.finishTasksAndInvalidate()
  }
}

private final class LocalMLXURLSessionDownload: NSObject, URLSessionDownloadDelegate,
  @unchecked Sendable
{
  private let progress: (Int64, Int64?) -> Void
  private let continuation: CheckedContinuation<URL, Error>
  private let lock = NSLock()
  private var didResume = false

  init(
    progress: @escaping (Int64, Int64?) -> Void,
    continuation: CheckedContinuation<URL, Error>
  ) {
    self.progress = progress
    self.continuation = continuation
  }

  static func download(
    request: URLRequest,
    progress: @escaping (Int64, Int64?) -> Void
  ) async throws -> URL {
    let cancellationBox = LocalMLXDownloadCancellationBox()
    return try await withTaskCancellationHandler {
      defer { cancellationBox.finish() }
      return try await withCheckedThrowingContinuation { continuation in
        let delegate = LocalMLXURLSessionDownload(
          progress: progress,
          continuation: continuation)
        let session = URLSession(
          configuration: .default,
          delegate: delegate,
          delegateQueue: nil)
        let task = session.downloadTask(with: request)
        cancellationBox.set(session: session, task: task)
        task.resume()
      }
    } onCancel: {
      cancellationBox.cancel()
    }
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    let expected = totalBytesExpectedToWrite >= 0 ? totalBytesExpectedToWrite : nil
    progress(totalBytesWritten, expected)
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    guard let response = downloadTask.response as? HTTPURLResponse else {
      finish(.failure(URLError(.badServerResponse)))
      return
    }
    guard (200..<300).contains(response.statusCode) else {
      finish(.failure(LocalMLXHubDownloadError.httpError(
        path: downloadTask.originalRequest?.url?.lastPathComponent ?? "file",
        statusCode: response.statusCode)))
      return
    }

    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    do {
      try FileManager.default.copyItem(at: location, to: tempURL)
      finish(.success(tempURL))
    } catch {
      finish(.failure(error))
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    finish(.failure(error ?? URLError(.cannotWriteToFile)))
  }

  private func finish(_ result: Result<URL, Error>) {
    lock.lock()
    guard !didResume else {
      lock.unlock()
      return
    }
    didResume = true
    lock.unlock()

    switch result {
    case .success(let url):
      continuation.resume(returning: url)
    case .failure(let error):
      continuation.resume(throwing: error)
    }
  }
}
