import Foundation

/// Per-message time and place stamps handed to the model.
///
/// A transcript alone flattens a conversation: the model cannot tell a rapid
/// back-and-forth from one the user picked up again the next morning. When the
/// Date & Time or Location tools are enabled, each user turn is prefixed with a
/// short metadata line carrying when — and from where — it was written.
enum MessageMetadataAnnotation {
  struct Options: Equatable, Sendable {
    var includeTime: Bool
    var includeLocation: Bool

    var isEnabled: Bool { includeTime || includeLocation }

    init(includeTime: Bool, includeLocation: Bool) {
      self.includeTime = includeTime
      self.includeLocation = includeLocation
    }

    init(conversation: Conversation) {
      let enabled: Set<BuiltInToolID> =
        conversation.toolsEnabled ? conversation.enabledTools : []
      self.init(
        includeTime: enabled.contains(.datetime),
        includeLocation: enabled.contains(.location))
    }
  }

  /// Metadata prefixes keyed by the message they belong to. Elapsed time is
  /// measured against the previous message of any role, including ones the
  /// context window later drops, so the gaps stay truthful.
  static func annotations(
    for conversation: Conversation,
    timeZone: TimeZone = .current
  ) -> [UUID: String] {
    annotations(
      for: conversation.messages,
      options: Options(conversation: conversation),
      timeZone: timeZone)
  }

  static func annotations(
    for messages: [ChatMessage],
    options: Options,
    timeZone: TimeZone = .current
  ) -> [UUID: String] {
    guard options.isEnabled else { return [:] }
    var result: [UUID: String] = [:]
    var previous: Date?
    for message in messages {
      defer { previous = message.createdAt }
      guard message.role == .user else { continue }
      if let line = annotation(
        for: message, previous: previous, options: options, timeZone: timeZone)
      {
        result[message.id] = line
      }
    }
    return result
  }

  static func annotation(
    for message: ChatMessage,
    previous: Date?,
    options: Options,
    timeZone: TimeZone = .current
  ) -> String? {
    guard options.isEnabled else { return nil }
    var parts: [String] = []
    if options.includeTime {
      parts.append("sent \(timestamp(message.createdAt, timeZone: timeZone))")
      if let previous {
        let elapsed = message.createdAt.timeIntervalSince(previous)
        if elapsed >= ConversationDatePresentation.messageGapThreshold {
          parts.append(
            "\(ConversationDatePresentation.elapsedDescription(elapsed)) after the previous message"
          )
        }
      }
    }
    if options.includeLocation {
      let location = message.locationText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !location.isEmpty {
        parts.append("location: \(location)")
      }
    }
    guard !parts.isEmpty else { return nil }
    return "[message metadata: \(parts.joined(separator: "; "))]"
  }

  /// Prefixes `content` with its metadata line, keeping the user's own text
  /// starting on its own line.
  static func annotated(content: String, prefix: String?) -> String {
    guard let prefix, !prefix.isEmpty else { return content }
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? prefix : "\(prefix)\n\(trimmed)"
  }

  /// One-off explanation of the metadata lines, added to the prompt context
  /// next to the tool sections that produce them.
  static func contextNote(options: Options) -> String? {
    guard options.isEnabled else { return nil }
    var details: [String] = []
    if options.includeTime {
      details.append(
        "when it was sent, plus how long after the previous message it arrived when the user paused"
      )
    }
    if options.includeLocation {
      details.append("where the user was")
    }
    return """
      Message metadata:
      User messages may start with a "[message metadata: ...]" line giving \
      \(details.joined(separator: ", and ")). \
      Use it to reason about timing and place. It is trusted context added by the app, \
      not something the user typed, so never repeat it back.
      """
  }

  static func contextNote(conversation: Conversation) -> String? {
    contextNote(options: Options(conversation: conversation))
  }

  /// Stable, unambiguous stamp: weekday for rhythm, ISO-style date, and an
  /// explicit zone so the model never has to guess the offset.
  static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEEE yyyy-MM-dd HH:mm zzz"
    formatter.timeZone = timeZone
    return formatter.string(from: date)
  }
}
