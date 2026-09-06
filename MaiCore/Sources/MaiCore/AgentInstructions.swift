import Foundation

/// AGENTS.md: the instructions a repository leaves for coding agents. When a
/// host turns them on (`/set use.agentsmd on` in pmai), every such file from
/// the working directory up to the repository root goes into the system
/// prompt of every run, the most general first.
public enum AgentInstructionsFile {
  public static let filename = "AGENTS.md"

  /// The AGENTS.md files that apply in `directory`: its own, and those of its
  /// parents up to and including the directory holding `.git`. Outside a
  /// repository only the directory itself counts, so a stray file higher up
  /// the disk never leaks into unrelated work. Ordered root first.
  public static func locate(from directory: URL, fileManager: FileManager = .default) -> [URL] {
    let start = directory.standardizedFileURL
    var current = start
    var found: [URL] = []
    var insideRepository = false
    while true {
      let candidate = current.appendingPathComponent(filename)
      if fileManager.fileExists(atPath: candidate.path) { found.append(candidate) }
      if fileManager.fileExists(atPath: current.appendingPathComponent(".git").path) {
        insideRepository = true
        break
      }
      let parent = current.deletingLastPathComponent()
      guard parent.pathComponents.count < current.pathComponents.count else { break }
      current = parent
    }
    if !insideRepository {
      found.removeAll { $0.deletingLastPathComponent().standardizedFileURL.path != start.path }
    }
    return found.reversed()
  }

  /// One file's text, trimmed; nil for an empty or unreadable file.
  public static func read(_ url: URL) -> String? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// The block a host adds to the system prompt for the files that apply in
  /// `directory`, or nil when there are none.
  public static func promptSection(from directory: URL, fileManager: FileManager = .default)
    -> String?
  {
    promptSection(files: locate(from: directory, fileManager: fileManager))
  }

  /// The block for the given files, root first. Each is labelled with its
  /// path so the model can tell which part of the tree a rule is about.
  public static func promptSection(files: [URL]) -> String? {
    let parts = files.compactMap { url -> String? in
      guard let text = read(url) else { return nil }
      return "### \(url.path)\n\n\(text)"
    }
    guard !parts.isEmpty else { return nil }
    return """
      <project_instructions>
      ## Project instructions

      The AGENTS.md files below were left in this working tree for coding agents, the most general first. Follow them while working here: they say how this project is built, tested, and written. The person's own messages still take precedence when they conflict.

      \(parts.joined(separator: "\n\n"))
      </project_instructions>
      """
  }
}
