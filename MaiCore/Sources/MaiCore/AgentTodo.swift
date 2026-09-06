import Foundation

/// One task on a project's todo list.
public struct AgentTodoItem: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var title: String
  public var isDone: Bool
  public var createdAt: Date

  public init(id: UUID = UUID(), title: String, isDone: Bool = false, createdAt: Date = Date()) {
    self.id = id
    self.title = title
    self.isDone = isDone
    self.createdAt = createdAt
  }
}

/// The tasks an agent and the person it works with are tracking: what is
/// still to do and what is already done, in the order it was planned.
///
/// pmai keeps one per project in `.pmai/todo.md` and PocketMai keeps one in
/// its settings, but the list, the Markdown it is stored as, and the tools
/// that drive it are all here, so both hosts behave the same.
public struct AgentTodoList: Codable, Equatable, Sendable {
  /// Markdown, not JSON: a GitHub task list people can read and edit by hand.
  public static let filename = "todo.md"

  public var items: [AgentTodoItem]

  public init(items: [AgentTodoItem] = []) {
    self.items = items
  }

  public var isEmpty: Bool { items.isEmpty }
  public var pendingCount: Int { items.filter { !$0.isDone }.count }
  public var doneCount: Int { items.count - pendingCount }

  // MARK: Markdown

  /// Reads a task list: one `- [ ] title` or `- [x] title` per line. Bullets
  /// without a checkbox count as pending; headings and prose are ignored.
  public init(markdown: String, createdAt: Date = Date()) {
    items = markdown.components(separatedBy: .newlines).compactMap {
      Self.parseItem($0, createdAt: createdAt)
    }
  }

  public var markdown: String {
    items.map { "- [\($0.isDone ? "x" : " ")] \($0.title)" }.joined(separator: "\n")
  }

  private static func parseItem(_ line: String, createdAt: Date) -> AgentTodoItem? {
    var rest = Substring(line.trimmingCharacters(in: .whitespaces))
    if let first = rest.first, "-*+".contains(first) {
      rest = rest.dropFirst()
    } else {
      let digits = rest.prefix { $0.isNumber }
      guard !digits.isEmpty, let marker = rest.dropFirst(digits.count).first,
        marker == "." || marker == ")"
      else { return nil }
      rest = rest.dropFirst(digits.count + 1)
    }
    guard rest.first?.isWhitespace == true else { return nil }
    rest = rest.drop { $0.isWhitespace }
    var isDone = false
    if rest.hasPrefix("["), rest.count >= 3 {
      let mark = rest[rest.index(after: rest.startIndex)]
      let close = rest[rest.index(rest.startIndex, offsetBy: 2)]
      if close == "]", mark == " " || mark == "x" || mark == "X" {
        isDone = mark != " "
        rest = rest.dropFirst(3)
      }
    }
    let title = rest.trimmingCharacters(in: .whitespaces)
    guard !title.isEmpty else { return nil }
    return AgentTodoItem(title: title, isDone: isDone, createdAt: createdAt)
  }

  /// Reads the list file, answering an empty list when there is none.
  public static func load(from url: URL) throws -> AgentTodoList {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return AgentTodoList() }
    let modified =
      (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
      ?? nil
    return AgentTodoList(markdown: text, createdAt: modified ?? Date())
  }

  /// Writes the list, removing the file when it is empty so an untouched
  /// project leaves nothing behind.
  public func save(to url: URL) throws {
    guard !isEmpty else {
      try? FileManager.default.removeItem(at: url)
      return
    }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data((markdown + "\n").utf8).write(to: url, options: .atomic)
  }

  // MARK: Reading

  /// The numbered rendering models and people see; numbers are what
  /// `todo_done` takes, so they must match what `todo_list` printed.
  public var listing: String {
    guard !isEmpty else { return "No todos." }
    let lines = items.enumerated().map { index, item in
      "\(index + 1). [\(item.isDone ? "x" : " ")] \(item.title)"
    }
    return "Todo (\(pendingCount) pending, \(doneCount) done):\n" + lines.joined(separator: "\n")
  }

  /// Finds an item by its 1-based number, an id prefix of at least eight
  /// characters, an exact title, or a title fragment — pending items first,
  /// since those are the ones anyone asks about.
  public func index(matching query: String) -> Int? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let number = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
    if let position = Int(number), position >= 1, position <= items.count {
      return position - 1
    }
    let lower = trimmed.lowercased()
    if lower.count >= 8,
      let found = items.firstIndex(where: { $0.id.uuidString.lowercased().hasPrefix(lower) })
    {
      return found
    }
    return items.firstIndex { $0.title.caseInsensitiveCompare(trimmed) == .orderedSame }
      ?? items.firstIndex { !$0.isDone && $0.title.localizedCaseInsensitiveContains(trimmed) }
      ?? items.firstIndex { $0.title.localizedCaseInsensitiveContains(trimmed) }
  }

  // MARK: Editing

  /// Appends one pending item, or nothing when the title is blank or a
  /// pending item already says the same thing.
  @discardableResult
  public mutating func add(_ title: String, at date: Date = Date()) -> AgentTodoItem? {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard
      !items.contains(where: {
        !$0.isDone && $0.title.caseInsensitiveCompare(trimmed) == .orderedSame
      })
    else { return nil }
    let item = AgentTodoItem(title: trimmed, createdAt: date)
    items.append(item)
    return item
  }

  public mutating func markDone(at index: Int) {
    guard items.indices.contains(index) else { return }
    items[index].isDone = true
  }

  /// Drops one item; the ones after it move up a number.
  @discardableResult
  public mutating func remove(at index: Int) -> AgentTodoItem? {
    guard items.indices.contains(index) else { return nil }
    return items.remove(at: index)
  }

  public mutating func removeAll() {
    items.removeAll()
  }
}

/// Tools that let an agent keep a task list: plan the steps of a piece of
/// work, see what is left, and tick items off as it goes.
///
/// The caller owns the list — pmai a file, PocketMai its settings — and
/// passes it in by reference, so nothing here needs to know where it lives.
public enum MaiTodoTools {
  public static let listName = "todo_list"
  public static let addName = "todo_add"
  public static let doneName = "todo_done"

  public static let toolNames = [listName, addName, doneName]

  public static let definitions: [ToolDefinition] = [
    ToolDefinition(
      name: listName,
      description:
        "List the todo items of this project, numbered, with a checkbox showing which are done. Call it to see what is left and to get the numbers todo_done takes.",
      parameters: [],
      annotations: ToolAnnotations(
        readOnly: true, idempotent: true, openWorld: false, approval: .automatic)),
    ToolDefinition(
      name: addName,
      description:
        "Add pending todo items to this project. Use it to plan multi-step work before starting; one title per line adds several items at once. The list persists across chats.",
      parameters: [
        ToolParameterDef(
          name: "title", type: "string",
          description: "Task to add. Separate several tasks with newlines.",
          required: true)
      ],
      annotations: ToolAnnotations(
        readOnly: false, idempotent: false, openWorld: false, approval: .automatic)),
    ToolDefinition(
      name: doneName,
      description: "Mark one todo item done by its number from todo_list or by part of its title.",
      parameters: [
        ToolParameterDef(
          name: "task", type: "string",
          description: "Item number as shown by todo_list, or a fragment of its title.",
          required: true)
      ],
      annotations: ToolAnnotations(
        readOnly: false, idempotent: true, openWorld: false, approval: .automatic)),
  ]

  public static func execute(
    name: String,
    arguments: [String: JSONValue],
    list: inout AgentTodoList
  ) -> String {
    switch name {
    case listName: list.listing
    case addName: add(arguments: arguments, list: &list)
    case doneName: markDone(arguments: arguments, list: &list)
    default: "Error: unknown todo tool '\(name)'."
    }
  }

  /// The tools over a list kept in a file the person may edit between calls,
  /// so every call reads the file afresh and writes it back when it changed.
  /// `url` answers nil while no list is available, such as before a project
  /// is open.
  public static func makeTools(url: @escaping @Sendable () -> URL?) -> [any AgentTool] {
    let file = TodoFile(url: url)
    return definitions.map { definition in
      ClosureTool(definition: definition) { arguments, _ in
        let text = try await file.perform(name: definition.name, arguments: arguments)
        return ToolOutput(text: text, isError: text.hasPrefix("Error:"))
      }
    }
  }

  private static func add(arguments: [String: JSONValue], list: inout AgentTodoList) -> String {
    var titles = arguments["titles"]?.arrayValue?.compactMap(\.stringValue) ?? []
    if titles.isEmpty {
      let text =
        arguments["title"]?.stringValue ?? arguments["task"]?.stringValue
        ?? arguments["text"]?.stringValue ?? ""
      titles = text.components(separatedBy: .newlines)
    }
    titles = titles.map(stripBullet).filter { !$0.isEmpty }
    guard !titles.isEmpty else { return "Error: title is required." }
    var added: [String] = []
    var skipped: [String] = []
    for title in titles {
      if list.add(title) != nil { added.append(title) } else { skipped.append(title) }
    }
    var lines: [String] = []
    if added.count == 1 {
      lines.append("Added: \(added[0]) (#\(list.items.count))")
    } else if !added.isEmpty {
      lines.append("Added \(added.count) items.")
    }
    if !skipped.isEmpty {
      lines.append("Already listed: \(skipped.joined(separator: "; "))")
    }
    lines.append(list.listing)
    return lines.joined(separator: "\n")
  }

  private static func markDone(arguments: [String: JSONValue], list: inout AgentTodoList) -> String
  {
    let query =
      (arguments["task"]?.stringValue ?? arguments["title_or_id"]?.stringValue
      ?? arguments["id"]?.stringValue ?? arguments["title"]?.stringValue
      ?? arguments["number"].flatMap { $0.intValue.map(String.init) ?? $0.stringValue }
      ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return "Error: task is required." }
    guard let index = list.index(matching: query) else {
      return list.isEmpty
        ? "Error: the todo list is empty."
        : "Error: no todo matched '\(query)'.\n\(list.listing)"
    }
    let item = list.items[index]
    if item.isDone { return "Already done: \(item.title)\n\(list.listing)" }
    list.markDone(at: index)
    return "Marked done: \(item.title)\n\(list.listing)"
  }

  /// Models sometimes send the list the way people write it; the bullet is
  /// not part of the task.
  private static func stripBullet(_ title: String) -> String {
    var trimmed = Substring(title.trimmingCharacters(in: .whitespacesAndNewlines))
    if let first = trimmed.first, "-*+".contains(first), trimmed.dropFirst().first == " " {
      trimmed = trimmed.dropFirst(2)
    }
    if trimmed.hasPrefix("[ ] ") || trimmed.hasPrefix("[x] ") || trimmed.hasPrefix("[X] ") {
      trimmed = trimmed.dropFirst(4)
    }
    return trimmed.trimmingCharacters(in: .whitespaces)
  }
}

/// Serializes the read-modify-write of one list file, so two tool calls
/// landing together cannot lose each other's change.
private actor TodoFile {
  private let url: @Sendable () -> URL?

  init(url: @escaping @Sendable () -> URL?) {
    self.url = url
  }

  func perform(name: String, arguments: JSONValue) throws -> String {
    guard let url = url() else {
      return "Error: no project is open, so there is no todo list."
    }
    var list = try AgentTodoList.load(from: url)
    let before = list
    let text = MaiTodoTools.execute(
      name: name, arguments: arguments.objectValue ?? [:], list: &list)
    if list != before { try list.save(to: url) }
    return text
  }
}
