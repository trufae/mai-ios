import Foundation

/// A listing entry read from a chat file without materializing its transcript.
public struct AgentChatSummary: Decodable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var title: String
  public var agentID: String
  public var provider: ProviderID
  public var model: String
  public var createdAt: Date
  public var updatedAt: Date
  public var isArchived: Bool
  /// Messages exchanged with the model, excluding configured instructions.
  public var messageCount: Int
  public var hasPendingContent: Bool

  public init(chat: AgentChat) {
    id = chat.id
    title = chat.title
    agentID = chat.primaryAgent.id
    provider = chat.primaryAgent.provider
    model = chat.primaryAgent.model
    createdAt = chat.createdAt
    updatedAt = chat.updatedAt
    isArchived = chat.isArchived
    messageCount = chat.conversationMessages.count
    hasPendingContent = !chat.pendingContent.isEmpty
  }

  private enum CodingKeys: String, CodingKey {
    case id, title, primaryAgent, messages, pendingContent, createdAt, updatedAt, isArchived
  }

  private enum AgentKeys: String, CodingKey {
    case id, provider, model
  }

  private struct RoleOnly: Decodable {
    var role: AgentRole
  }

  private struct Ignored: Decodable {
    init(from decoder: Decoder) throws {}
  }

  /// Decodes the same layout as `AgentChat`, skipping message contents.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    let agent = try container.nestedContainer(keyedBy: AgentKeys.self, forKey: .primaryAgent)
    agentID = try agent.decode(String.self, forKey: .id)
    provider = try agent.decode(ProviderID.self, forKey: .provider)
    model = try agent.decode(String.self, forKey: .model)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    messageCount = try container.decode([RoleOnly].self, forKey: .messages)
      .filter { $0.role != .system }.count
    hasPendingContent =
      !(try container.decodeIfPresent([Ignored].self, forKey: .pendingContent) ?? []).isEmpty
  }

  public var displayTitle: String {
    AgentChat.isPlaceholderTitle(title)
      ? AgentChat.placeholderTitle : title.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var hasConversation: Bool { messageCount > 0 }

  public var isDisposable: Bool {
    AgentChat.isDisposable(
      title: title,
      hasConversation: hasConversation,
      isBusy: false,
      isKept: isArchived)
  }

  /// The sidebar order: active chats newest first, then archived ones.
  public static func precedes(_ lhs: AgentChatSummary, _ rhs: AgentChatSummary) -> Bool {
    if lhs.isArchived != rhs.isArchived { return !lhs.isArchived }
    if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
    return lhs.createdAt > rhs.createdAt
  }
}

/// Persists one project's chats as one JSON file per chat inside a directory,
/// so hosts can list them cheaply and load a transcript only when it is opened.
///
/// Disposable chats never reach disk: a placeholder nobody used has no file,
/// and a chat that becomes disposable again loses its file on the next commit.
/// Whatever way a host exits, an empty chat is therefore neither saved nor
/// listed. Files that fail to decode are skipped, not deleted.
public struct AgentChatStore: Sendable {
  public static let fileExtension = "json"

  public let directoryURL: URL

  public init(directoryURL: URL) {
    self.directoryURL = directoryURL
  }

  public func fileURL(for id: UUID) -> URL {
    directoryURL.appendingPathComponent("\(id.uuidString).\(Self.fileExtension)")
  }

  /// IDs of every chat file present, whatever their contents.
  public func chatIDs() throws -> [UUID] {
    guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: directoryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
    )
    .filter { $0.pathExtension == Self.fileExtension }
    .compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
    .sorted { $0.uuidString < $1.uuidString }
  }

  public func loadChat(id: UUID) throws -> AgentChat? {
    let url = fileURL(for: id)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try Self.decoder.decode(AgentChat.self, from: Data(contentsOf: url))
  }

  /// Every readable, non-disposable chat. Unreadable files are reported to
  /// `onFailure` and left in place.
  public func loadChats(onFailure: ((URL, any Error) -> Void)? = nil) throws -> [AgentChat] {
    try load(AgentChat.self, onFailure: onFailure).filter { !$0.isDisposable }
  }

  /// Listing entries for every readable, non-disposable chat in sidebar order.
  public func loadSummaries(
    onFailure: ((URL, any Error) -> Void)? = nil
  ) throws -> [AgentChatSummary] {
    try load(AgentChatSummary.self, onFailure: onFailure)
      .filter { !$0.isDisposable }
      .sorted(by: AgentChatSummary.precedes)
  }

  /// Loads every chat into a workspace that is already committed, so a later
  /// `commit` writes only what the host changes.
  public func loadWorkspace(
    selecting selectedChatID: UUID? = nil,
    onFailure: ((URL, any Error) -> Void)? = nil
  ) throws -> AgentChatWorkspace {
    var workspace = AgentChatWorkspace(
      chats: try loadChats(onFailure: onFailure), selectedChatID: selectedChatID)
    workspace.markCommitted()
    return workspace
  }

  /// Writes the chat, or removes its file when it is disposable. Answers
  /// whether a file now exists for it.
  @discardableResult
  public func save(_ chat: AgentChat) throws -> Bool {
    guard !chat.isDisposable else {
      try delete(id: chat.id)
      return false
    }
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    try Self.encoder.encode(chat).write(to: fileURL(for: chat.id), options: .atomic)
    return true
  }

  @discardableResult
  public func delete(id: UUID) throws -> Bool {
    let url = fileURL(for: id)
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    try FileManager.default.removeItem(at: url)
    return true
  }

  /// Writes the chats the workspace changed, deletes the ones it removed, and
  /// clears its change tracking.
  public func commit(_ workspace: inout AgentChatWorkspace) throws {
    for id in workspace.removedChatIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
      try delete(id: id)
    }
    for chat in workspace.chats where workspace.modifiedChatIDs.contains(chat.id) {
      try save(chat)
    }
    workspace.markCommitted()
  }

  private func load<Value: Decodable>(
    _ type: Value.Type,
    onFailure: ((URL, any Error) -> Void)?
  ) throws -> [Value] {
    var values: [Value] = []
    for id in try chatIDs() {
      let url = fileURL(for: id)
      do {
        values.append(try Self.decoder.decode(Value.self, from: Data(contentsOf: url)))
      } catch {
        onFailure?(url, error)
      }
    }
    return values
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  private static var decoder: JSONDecoder { JSONDecoder() }
}

/// The per-user root that outlives any one project: the index of every project
/// a host has opened, plus state shared across them.
///
/// Layout:
///
///     ~/.pmai/projects.json              index of known projects
///     ~/.pmai/history.json               editable input history
///     <workdir>/.pmai/project.json       the project's own id, name, and tint
///     <workdir>/.pmai/chats/<id>.json    one file per chat
///     ~/.pmai/projects/<id>/             the same two, for read-only directories
///
/// The root is `$PMAI_HOME` when set, else `~/.pmai`.
public struct AgentHome: Sendable {
  public static let directoryName = ".pmai"
  public static let environmentVariable = "PMAI_HOME"
  public static let projectIndexFilename = "projects.json"
  public static let projectFilename = "project.json"
  public static let chatsDirectoryName = "chats"
  public static let historyFilename = "history.json"

  public let rootURL: URL

  public init(rootURL: URL) {
    self.rootURL = rootURL
  }

  public static func resolve(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  ) -> AgentHome {
    if let override = environment[environmentVariable]?.trimmingCharacters(
      in: .whitespacesAndNewlines), !override.isEmpty
    {
      let expanded = NSString(string: override).expandingTildeInPath
      return AgentHome(rootURL: URL(fileURLWithPath: expanded, isDirectory: true))
    }
    return AgentHome(
      rootURL: homeDirectory.appendingPathComponent(directoryName, isDirectory: true))
  }

  public var projectIndexURL: URL {
    rootURL.appendingPathComponent(Self.projectIndexFilename)
  }

  public var historyURL: URL {
    rootURL.appendingPathComponent(Self.historyFilename)
  }

  /// Storage for projects whose working directory cannot hold a `.pmai` folder.
  public var projectsDirectoryURL: URL {
    rootURL.appendingPathComponent("projects", isDirectory: true)
  }

  public func loadProjectIndex() throws -> AgentProjectIndex {
    guard FileManager.default.fileExists(atPath: projectIndexURL.path) else {
      return AgentProjectIndex()
    }
    return try AgentProjectIndex.load(from: projectIndexURL)
  }

  public func saveProjectIndex(_ index: AgentProjectIndex) throws {
    try index.save(to: projectIndexURL)
  }

  /// Where a project keeps its files: `.pmai` inside its working directory
  /// when that directory is writable or already holds one, else a directory
  /// named after the project id under the home.
  public func storageDirectory(for project: AgentProject) -> URL {
    if let workingDirectory = project.workingDirectoryURL {
      let local = workingDirectory.appendingPathComponent(Self.directoryName, isDirectory: true)
      if FileManager.default.fileExists(atPath: local.path)
        || FileManager.default.isWritableFile(atPath: workingDirectory.path)
      {
        return local
      }
    }
    return projectsDirectoryURL.appendingPathComponent(project.id.uuidString, isDirectory: true)
  }

  public func projectFileURL(for project: AgentProject) -> URL {
    storageDirectory(for: project).appendingPathComponent(Self.projectFilename)
  }

  public func chatStore(for project: AgentProject) -> AgentChatStore {
    AgentChatStore(
      directoryURL: storageDirectory(for: project).appendingPathComponent(
        Self.chatsDirectoryName, isDirectory: true))
  }

  /// The project rooted at a directory, from its own `project.json` or from
  /// the index; nil when the directory was never opened.
  public func loadProject(atWorkingDirectory directory: URL) throws -> AgentProject? {
    let path = AgentProject.standardizedPath(directory.path)
    let localFile = directory.appendingPathComponent(Self.directoryName, isDirectory: true)
      .appendingPathComponent(Self.projectFilename)
    if FileManager.default.fileExists(atPath: localFile.path) {
      var project = try Self.decodeProject(at: localFile)
      project.workingDirectory = path
      return project
    }
    guard let indexed = try loadProjectIndex().project(atWorkingDirectory: path) else {
      return nil
    }
    let fallbackFile = projectFileURL(for: indexed)
    guard FileManager.default.fileExists(atPath: fallbackFile.path) else { return indexed }
    var project = try Self.decodeProject(at: fallbackFile)
    project.workingDirectory = path
    return project
  }

  /// Opens the project rooted at a directory, creating and registering it on
  /// first use, and records the visit in the index.
  @discardableResult
  public func openProject(atWorkingDirectory directory: URL, at date: Date = Date()) throws
    -> AgentProject
  {
    var project =
      try loadProject(atWorkingDirectory: directory)
      ?? AgentProject(workingDirectory: directory.path, createdAt: date)
    project.markOpened(at: date)
    try saveProject(project)
    return project
  }

  /// Writes the project's own file and refreshes its entry in the index.
  public func saveProject(_ project: AgentProject) throws {
    let url = projectFileURL(for: project)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(project).write(to: url, options: .atomic)
    var index = try loadProjectIndex()
    index.upsert(project)
    try saveProjectIndex(index)
  }

  /// Drops a project from the index. Its files stay where they are.
  @discardableResult
  public func forgetProject(id: UUID) throws -> AgentProject? {
    var index = try loadProjectIndex()
    guard let removed = index.remove(id: id) else { return nil }
    try saveProjectIndex(index)
    return removed
  }

  private static func decodeProject(at url: URL) throws -> AgentProject {
    try JSONDecoder().decode(AgentProject.self, from: Data(contentsOf: url))
  }
}
