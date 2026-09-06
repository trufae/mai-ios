import Foundation

/// Accent color a project can carry: one of the named presets PocketMai offers
/// for chat folders, or a `#RRGGBB` value. Hosts map it onto their own palette.
public struct AgentProjectTint: RawRepresentable, Codable, Hashable, Sendable,
  CustomStringConvertible
{
  public static let presetNames = [
    "blue", "purple", "pink", "red", "orange", "yellow", "green", "mint", "teal", "cyan",
    "indigo",
  ]
  private static let presetHex: [String: String] = [
    "blue": "#007AFF", "purple": "#AF52DE", "pink": "#FF2D55", "red": "#FF3B30",
    "orange": "#FF9500", "yellow": "#FFCC00", "green": "#34C759", "mint": "#00C7BE",
    "teal": "#30B0C7", "cyan": "#32ADE6", "indigo": "#5856D6",
  ]
  /// Prefix PocketMai stores before custom folder colors; accepted for compatibility.
  public static let customPrefix = "custom:"

  /// A preset name in lowercase, or an uppercase `#RRGGBB` value.
  public let rawValue: String

  public init?(rawValue: String) {
    var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if value.hasPrefix(Self.customPrefix) {
      value = String(value.dropFirst(Self.customPrefix.count))
    }
    if Self.presetNames.contains(value) {
      self.rawValue = value
      return
    }
    guard let hex = Self.normalizedHex(value) else { return nil }
    self.rawValue = hex
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard let tint = AgentProjectTint(rawValue: value) else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Unsupported project tint \"\(value)\".")
    }
    self = tint
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(storageIdentifier)
  }

  public var isPreset: Bool { Self.presetNames.contains(rawValue) }

  /// The form written to disk: the preset name, or `custom:#RRGGBB`, which is
  /// what PocketMai folders have always stored, so files stay readable by
  /// earlier app versions.
  public var storageIdentifier: String {
    isPreset ? rawValue : Self.customPrefix + rawValue
  }

  /// The color as `#RRGGBB`, resolving presets to their reference values.
  public var hex: String { Self.presetHex[rawValue] ?? rawValue }

  public var displayName: String { isPreset ? rawValue.capitalized : rawValue }

  public var description: String { rawValue }

  /// Channel values from 0 to 255.
  public var rgb: (red: Int, green: Int, blue: Int) {
    let packed = Int(hex.dropFirst(), radix: 16) ?? 0
    return ((packed >> 16) & 0xFF, (packed >> 8) & 0xFF, packed & 0xFF)
  }

  /// Accepts `#RGB`, `RGB`, `#RRGGBB`, and `RRGGBB`, always answering `#RRGGBB`.
  public static func normalizedHex(_ raw: String) -> String? {
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if value.hasPrefix("#") { value.removeFirst() }
    if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
    guard value.count == 6, value.allSatisfy(\.isHexDigit) else { return nil }
    return "#\(value)"
  }
}

/// A folder of chats tied to a place people work: the directory pmai was
/// started in, or a named folder with an optional working folder in PocketMai.
/// Chats live in one project; the project carries the name, tint, and working
/// directory they share.
public struct AgentProject: Codable, Equatable, Identifiable, Sendable {
  public static let placeholderName = "Untitled"

  public var id: UUID
  /// A name chosen by people; empty means "name me after the directory".
  public var name: String
  /// Absolute path of the directory the project's tools work in. Empty when
  /// the host resolves it another way, as PocketMai does with bookmarks.
  public var workingDirectory: String
  /// An optional symbol name a host may draw beside the project.
  public var icon: String?
  public var tint: AgentProjectTint?
  public var createdAt: Date
  public var lastOpenedAt: Date

  public init(
    id: UUID = UUID(),
    name: String = "",
    workingDirectory: String = "",
    icon: String? = nil,
    tint: AgentProjectTint? = nil,
    createdAt: Date = Date(),
    lastOpenedAt: Date? = nil
  ) {
    self.id = id
    self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    self.workingDirectory = Self.standardizedPath(workingDirectory)
    self.icon = icon?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    self.tint = tint
    self.createdAt = createdAt
    self.lastOpenedAt = lastOpenedAt ?? createdAt
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, workingDirectory, icon, tint, createdAt, lastOpenedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    self.init(
      id: try container.decode(UUID.self, forKey: .id),
      name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
      workingDirectory: try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        ?? "",
      icon: try container.decodeIfPresent(String.self, forKey: .icon),
      tint: try? container.decodeIfPresent(AgentProjectTint.self, forKey: .tint),
      createdAt: createdAt,
      lastOpenedAt: try container.decodeIfPresent(Date.self, forKey: .lastOpenedAt))
  }

  /// The chosen name, else the directory's last path component, else a placeholder.
  public var displayName: String {
    if !name.isEmpty { return name }
    return Self.defaultName(forWorkingDirectory: workingDirectory) ?? Self.placeholderName
  }

  public var hasCustomName: Bool { !name.isEmpty }

  public var workingDirectoryURL: URL? {
    workingDirectory.isEmpty ? nil : URL(fileURLWithPath: workingDirectory, isDirectory: true)
  }

  /// True when the working directory can no longer be found, so a listing can
  /// say so instead of pretending the project is still reachable.
  public var workingDirectoryExists: Bool {
    guard !workingDirectory.isEmpty else { return true }
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  public mutating func rename(to name: String) {
    self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public mutating func markOpened(at date: Date = Date()) {
    lastOpenedAt = date
  }

  public static func defaultName(forWorkingDirectory path: String) -> String? {
    let standardized = standardizedPath(path)
    guard !standardized.isEmpty else { return nil }
    let component = URL(fileURLWithPath: standardized).lastPathComponent
    return component.isEmpty || component == "/" ? standardized : component
  }

  /// Resolves `~`, `.`, `..`, symlinks, and trailing slashes so two spellings
  /// of one directory identify the same project.
  public static func standardizedPath(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    let expanded = NSString(string: trimmed).expandingTildeInPath
    let standardized = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
      .resolvingSymlinksInPath().path
    return standardized.count > 1 && standardized.hasSuffix("/")
      ? String(standardized.dropLast()) : standardized
  }
}

/// The list of every project a host has opened, kept outside any of their
/// working directories so it survives projects that move or disappear.
public struct AgentProjectIndex: Codable, Equatable, Sendable {
  public var version: Int
  public private(set) var projects: [AgentProject]

  public init(version: Int = 1, projects: [AgentProject] = []) {
    self.version = version
    self.projects = []
    for project in projects { upsert(project) }
  }

  private enum CodingKeys: String, CodingKey {
    case version, projects
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      version: try container.decodeIfPresent(Int.self, forKey: .version) ?? 1,
      projects: try container.decodeIfPresent([AgentProject].self, forKey: .projects) ?? [])
  }

  /// Projects most recently opened first, so a listing starts with what
  /// people worked on last.
  public var orderedProjects: [AgentProject] {
    projects.sorted(by: Self.precedes)
  }

  public func project(id: UUID) -> AgentProject? {
    projects.first { $0.id == id }
  }

  public func project(atWorkingDirectory path: String) -> AgentProject? {
    let standardized = AgentProject.standardizedPath(path)
    guard !standardized.isEmpty else { return nil }
    return projects.first { $0.workingDirectory == standardized }
  }

  /// Records a project, replacing any earlier entry with its id and any other
  /// entry that claimed the same working directory.
  public mutating func upsert(_ project: AgentProject) {
    projects.removeAll {
      $0.id == project.id
        || (!project.workingDirectory.isEmpty
          && $0.workingDirectory == project.workingDirectory)
    }
    projects.append(project)
  }

  @discardableResult
  public mutating func remove(id: UUID) -> AgentProject? {
    guard let index = projects.firstIndex(where: { $0.id == id }) else { return nil }
    return projects.remove(at: index)
  }

  public static func precedes(_ lhs: AgentProject, _ rhs: AgentProject) -> Bool {
    if lhs.lastOpenedAt != rhs.lastOpenedAt { return lhs.lastOpenedAt > rhs.lastOpenedAt }
    if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
    return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
  }

  public static func load(from url: URL) throws -> AgentProjectIndex {
    try MaiJSONCoding.default.makeDecoder().decode(
      AgentProjectIndex.self, from: Data(contentsOf: url))
  }

  public func save(to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try MaiJSONCoding.default.makeEncoder().encode(self).write(to: url, options: .atomic)
  }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
