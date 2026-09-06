import Foundation

/// An edit an agent asked for on its own conversation. The runtime applies it
/// before the agent's next model turn, so a run can drop what no longer
/// matters — a wrong instruction, a long tool result, an aside — and go on
/// with a smaller context instead of dragging it to the end.
public enum AgentTranscriptEdit: Equatable, Sendable {
  case remove(messageIDs: [String])
  case rewrite(messageID: String, text: String)
  /// Replaces the messages with one summary at the place of the first.
  case compact(messageIDs: [String], summary: String)
}

/// What applying edits did, for hosts to show and tools to report.
public struct AgentTranscriptEditReport: Equatable, Sendable {
  public var removed: Int
  public var rewritten: Int
  public var compacted: Int
  public var charactersBefore: Int
  public var charactersAfter: Int

  public init(
    removed: Int = 0,
    rewritten: Int = 0,
    compacted: Int = 0,
    charactersBefore: Int = 0,
    charactersAfter: Int = 0
  ) {
    self.removed = removed
    self.rewritten = rewritten
    self.compacted = compacted
    self.charactersBefore = charactersBefore
    self.charactersAfter = charactersAfter
  }

  public var isEmpty: Bool { removed == 0 && rewritten == 0 && compacted == 0 }

  /// `removed 3 messages, compacted 4 into a summary (12.3k → 2.1k chars)`
  public var summary: String {
    var parts: [String] = []
    if removed > 0 { parts.append("removed \(removed) message\(removed == 1 ? "" : "s")") }
    if rewritten > 0 { parts.append("rewrote \(rewritten) message\(rewritten == 1 ? "" : "s")") }
    if compacted > 0 {
      parts.append("compacted \(compacted) message\(compacted == 1 ? "" : "s") into a summary")
    }
    guard !parts.isEmpty else { return "nothing changed" }
    let before = AgentProcessInfo.compactCount(charactersBefore)
    let after = AgentProcessInfo.compactCount(charactersAfter)
    return parts.joined(separator: ", ") + " (\(before) → \(after) chars)"
  }
}

/// Applies context edits to a transcript. Removing either side of a tool
/// exchange removes the other side too, so what is left can still be sent to
/// a provider.
public enum AgentTranscriptEditor {
  public static func apply(
    _ edits: [AgentTranscriptEdit],
    to messages: [AgentMessage]
  ) -> (messages: [AgentMessage], report: AgentTranscriptEditReport) {
    var transcript = AgentTranscript(messages: messages)
    var report = AgentTranscriptEditReport(charactersBefore: characterCount(of: messages))
    for edit in edits {
      switch edit {
      case .remove(let ids):
        for id in ids {
          if let dropped = try? transcript.removeMessage(id: id) { report.removed += dropped.count }
        }
      case .rewrite(let id, let text):
        if (try? transcript.editMessage(id: id, text: text)) != nil { report.rewritten += 1 }
      case .compact(let ids, let summary):
        guard let first = ids.compactMap({ transcript.index(ofMessageID: $0) }).min() else { continue }
        var dropped = 0
        for id in ids {
          if let removed = try? transcript.removeMessage(id: id) { dropped += removed.count }
        }
        guard dropped > 0 else { continue }
        report.compacted += dropped
        var all = transcript.messages
        all.insert(summaryMessage(summary), at: min(first, all.count))
        transcript.replaceAll(with: all)
      }
    }
    report.charactersAfter = characterCount(of: transcript.messages)
    return (transcript.messages, report)
  }

  /// A transcript cut off inside a tool exchange — by Ctrl+C, a crash, a
  /// dropped connection — ends with calls nobody answered, which providers
  /// reject. This answers each with an error that says so, so the transcript
  /// can be run again and the model knows those steps did not happen.
  public static func answeringUnansweredToolCalls(
    in messages: [AgentMessage],
    reason: String
  ) -> [AgentMessage] {
    let answered = Set(messages.flatMap(\.toolResults).map(\.callID))
    var repaired = messages
    for (index, message) in messages.enumerated().reversed() where message.role == .assistant {
      let pending = message.toolCalls.filter { !answered.contains($0.id) }
      guard !pending.isEmpty else { continue }
      let results = pending.map {
        ContentPart.toolResult(
          ToolResult(callID: $0.id, text: "Error: not executed; \(reason).", isError: true))
      }
      repaired.insert(AgentMessage(role: .tool, content: results), at: index + 1)
      break
    }
    return repaired
  }

  /// A summary reads as something the conversation already covered, in the
  /// user's voice so every provider accepts it wherever it lands.
  static func summaryMessage(_ summary: String) -> AgentMessage {
    .user(
      "Summary of earlier parts of this conversation, written by the assistant to save context:\n\n"
        + summary.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  public static func characterCount(of messages: [AgentMessage]) -> Int {
    messages.reduce(0) { $0 + characterCount(of: $1) }
  }

  public static func characterCount(of message: AgentMessage) -> Int {
    message.content.reduce(0) { total, part in
      switch part {
      case .text(let text), .reasoning(let text): total + text.count
      case .toolCall(let call): total + call.name.count + call.arguments.compactJSONString.count
      case .toolResult(let result): total + result.text.count
      case .file(let file): total + (file.text?.count ?? 0)
      case .resource(let resource): total + (resource.text?.count ?? 0)
      case .image, .audio: total + 64
      }
    }
  }
}

/// Tools an agent uses on its own context: see what is in it, drop messages,
/// rewrite one, or fold a stretch into a summary. Each call reads the running
/// process's transcript from the supervisor and queues an edit the runtime
/// applies before the next model turn.
///
/// The system prompt and the turn in progress are kept out of reach; a task
/// that should start with no history at all belongs in a child agent.
public enum MaiContextTools {
  public static let listName = "context_list"
  public static let removeName = "context_remove"
  public static let rewriteName = "context_rewrite"
  public static let compactName = "context_compact"

  public static let toolNames = [listName, removeName, rewriteName, compactName]

  private static let previewLength = 90

  private static let messagesParameter = ToolParameterDef(
    name: "messages", type: "string",
    description:
      "Message numbers from context_list: one (\"4\"), a list (\"3, 5\"), a range (\"3-7\"), or \"all\" for everything before the latest user message.",
    required: true)

  public static let definitions: [ToolDefinition] = [
    ToolDefinition(
      name: listName,
      description:
        "List the messages in this conversation with their numbers, roles, sizes, and a preview, so you can decide what to remove, rewrite, or compact. Call it before the other context tools.",
      parameters: [],
      annotations: ToolAnnotations(readOnly: true, idempotent: true, openWorld: false)),
    ToolDefinition(
      name: removeName,
      description:
        "Remove messages from this conversation before your next turn: off-topic detours, superseded instructions, or tool output you no longer need. A tool call and its result always go together. The system prompt and the turn in progress cannot be removed.",
      parameters: [messagesParameter],
      annotations: ToolAnnotations(
        readOnly: false, destructive: true, idempotent: false, openWorld: false,
        approval: .confirm)),
    ToolDefinition(
      name: rewriteName,
      description:
        "Replace the text of one message before your next turn, for example to correct a wrong instruction or shorten a long tool result to what matters. Tool calls in the message are kept.",
      parameters: [
        ToolParameterDef(
          name: "message", type: "integer", description: "Message number from context_list.",
          required: true),
        ToolParameterDef(
          name: "text", type: "string", description: "The new text of the message.",
          required: true),
      ],
      annotations: ToolAnnotations(
        readOnly: false, destructive: true, idempotent: false, openWorld: false,
        approval: .confirm)),
    ToolDefinition(
      name: compactName,
      description:
        "Replace a stretch of messages with one summary you write, keeping the facts, decisions, and paths still needed and dropping the rest. Use it when the context has grown with details that no longer help. To work without any of this history, start a child agent instead.",
      parameters: [
        messagesParameter,
        ToolParameterDef(
          name: "summary", type: "string",
          description: "What the removed messages established, in a few lines.",
          required: true),
      ],
      annotations: ToolAnnotations(
        readOnly: false, destructive: true, idempotent: false, openWorld: false,
        approval: .confirm)),
  ]

  /// The tools bound to a supervisor, ready to register with a runtime.
  public static func makeTools(supervisor: AgentSupervisor) -> [any AgentTool] {
    definitions.map { definition in
      ClosureTool(definition: definition) { arguments, context in
        guard let pid = context.run.pid else {
          return ToolOutput(
            text: "Error: this run has no process table, so its context cannot be edited.",
            isError: true)
        }
        return await execute(
          name: definition.name,
          arguments: arguments.objectValue ?? [:],
          pid: pid,
          supervisor: supervisor)
      }
    }
  }

  public static func execute(
    name: String,
    arguments: [String: JSONValue],
    pid: AgentPID,
    supervisor: AgentSupervisor
  ) async -> ToolOutput {
    let view = ContextView(messages: await supervisor.transcript(pid))
    switch name {
    case listName:
      return ToolOutput(text: view.listing)
    case removeName:
      guard let selector = arguments["messages"]?.coercedStringValue else {
        return error("messages is required.")
      }
      let selection: [Int]
      do {
        selection = try view.select(selector)
      } catch {
        return self.error(error.localizedDescription)
      }
      let edit = AgentTranscriptEdit.remove(messageIDs: view.ids(selection))
      let preview = AgentTranscriptEditor.apply([edit], to: view.messages).report
      await supervisor.post(edit: edit, to: pid)
      return ToolOutput(
        text:
          "Before your next turn: \(preview.summary). Tool calls and their results go together, so linked messages are included."
      )
    case rewriteName:
      guard let number = arguments["message"]?.coercedNumberValue.map({ Int($0) }) else {
        return error("message is required.")
      }
      guard let text = arguments["text"]?.stringValue, !text.isEmpty else {
        return error("text is required.")
      }
      let selection: [Int]
      do {
        selection = try view.select(String(number))
      } catch {
        return self.error(error.localizedDescription)
      }
      guard let index = selection.first else { return error("No such message.") }
      await supervisor.post(edit: .rewrite(messageID: view.messages[index].id, text: text), to: pid)
      return ToolOutput(text: "Before your next turn: message #\(number) is rewritten (\(text.count) chars).")
    case compactName:
      guard let selector = arguments["messages"]?.coercedStringValue else {
        return error("messages is required.")
      }
      guard let summary = arguments["summary"]?.stringValue,
        !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        return error("summary is required.")
      }
      let selection: [Int]
      do {
        selection = try view.select(selector)
      } catch {
        return self.error(error.localizedDescription)
      }
      let edit = AgentTranscriptEdit.compact(messageIDs: view.ids(selection), summary: summary)
      let preview = AgentTranscriptEditor.apply([edit], to: view.messages).report
      await supervisor.post(edit: edit, to: pid)
      return ToolOutput(text: "Before your next turn: \(preview.summary).")
    default:
      return error("unknown context tool '\(name)'.")
    }
  }

  private static func error(_ message: String) -> ToolOutput {
    ToolOutput(text: "Error: \(message)", isError: true)
  }

  /// The transcript as the tools number it (from 1), with what may not be
  /// touched: the system prompt at the top and the turn being produced.
  struct ContextView {
    let messages: [AgentMessage]
    let protected: Set<Int>
    let currentTurnStart: Int?
    let latestUser: Int?

    init(messages: [AgentMessage]) {
      self.messages = messages
      var protected: Set<Int> = []
      if messages.first?.role == .system { protected.insert(0) }
      let currentTurn = messages.lastIndex { $0.role == .assistant }
      if let currentTurn {
        for index in currentTurn..<messages.count { protected.insert(index) }
      }
      self.protected = protected
      currentTurnStart = currentTurn
      latestUser = messages.lastIndex { $0.role == .user }
    }

    func ids(_ indexes: [Int]) -> [String] {
      indexes.map { messages[$0].id }
    }

    /// Zero-based indexes for a selector, refusing protected messages.
    func select(_ selector: String) throws -> [Int] {
      let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      var indexes: [Int] = []
      if trimmed == "all" {
        for index in messages.indices where !protected.contains(index) && index != latestUser {
          indexes.append(index)
        }
        guard !indexes.isEmpty else { throw ContextSelectionError.nothingToRemove }
        return indexes
      }
      for piece in trimmed.split(separator: ",") {
        let part = piece.trimmingCharacters(in: .whitespaces)
        let bounds = part.split(separator: "-", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let lower = Int(bounds.first ?? ""), let upper = Int(bounds.last ?? "") , lower >= 1, upper >= lower
        else { throw ContextSelectionError.invalidSelector(part) }
        for number in lower...upper {
          let index = number - 1
          guard messages.indices.contains(index) else {
            throw ContextSelectionError.outOfRange(number, messages.count)
          }
          if protected.contains(index) {
            throw ContextSelectionError.protected(number, index == 0 ? "it is the system prompt" : "it belongs to the turn in progress")
          }
          if !indexes.contains(index) { indexes.append(index) }
        }
      }
      guard !indexes.isEmpty else { throw ContextSelectionError.invalidSelector(trimmed) }
      return indexes.sorted()
    }

    var listing: String {
      let total = AgentTranscriptEditor.characterCount(of: messages)
      var lines = [
        "Context: \(messages.count) message\(messages.count == 1 ? "" : "s"), ~\(AgentProcessInfo.compactCount(total)) chars (~\(AgentProcessInfo.compactCount(total / 4)) tokens)"
      ]
      for (index, message) in messages.enumerated() {
        let size = AgentProcessInfo.compactCount(AgentTranscriptEditor.characterCount(of: message))
        var note = ""
        if index == 0, protected.contains(0) { note = "  [system prompt, kept]" }
        if let start = currentTurnStart, index >= start { note = "  [turn in progress, kept]" }
        lines.append("#\(index + 1) \(message.role.rawValue) \(size) chars: \(Self.preview(message))\(note)")
      }
      lines.append(
        "Numbers are what context_remove, context_rewrite, and context_compact take; edits apply before your next turn."
      )
      return lines.joined(separator: "\n")
    }

    private static func preview(_ message: AgentMessage) -> String {
      var pieces: [String] = []
      for part in message.content {
        switch part {
        case .text(let text): pieces.append(text)
        case .reasoning: pieces.append("(reasoning)")
        case .toolCall(let call): pieces.append("→ \(call.name) \(call.arguments.compactJSONString)")
        case .toolResult(let result): pieces.append("← \(result.isError ? "error" : "result"): \(result.text)")
        case .image(let image): pieces.append("(image \(image.name ?? image.mimeType))")
        case .file(let file): pieces.append("(file \(file.name))")
        case .audio: pieces.append("(audio)")
        case .resource(let resource): pieces.append("(resource \(resource.uri))")
        }
      }
      return AgentProcessInfo.oneLine(pieces.joined(separator: " "), limit: previewLength)
    }
  }

  enum ContextSelectionError: LocalizedError {
    case invalidSelector(String)
    case outOfRange(Int, Int)
    case protected(Int, String)
    case nothingToRemove

    var errorDescription: String? {
      switch self {
      case .invalidSelector(let text):
        "'\(text)' is not a message number, list, or range; context_list shows the numbers."
      case .outOfRange(let number, let count):
        "there is no message #\(number); the conversation has \(count)."
      case .protected(let number, let reason):
        "message #\(number) cannot be changed: \(reason)."
      case .nothingToRemove:
        "nothing before the latest user message can be removed."
      }
    }
  }
}
