import Foundation

enum ConversationDatePresentation {
  static func sidebarGroupTitle(
    for date: Date,
    relativeTo now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent
  ) -> String {
    if calendar.isDate(date, inSameDayAs: now) {
      return "Today"
    }

    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
      calendar.isDate(date, inSameDayAs: yesterday)
    {
      return "Yesterday"
    }

    if let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now),
      currentWeek.contains(date)
    {
      return "This week"
    }

    if let previousWeekReference = calendar.date(byAdding: .weekOfYear, value: -1, to: now),
      let previousWeek = calendar.dateInterval(of: .weekOfYear, for: previousWeekReference),
      previousWeek.contains(date)
    {
      return "Last week"
    }

    if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
      return date.formatted(.dateTime.month(.wide).day())
    }
    return date.formatted(.dateTime.year().month(.wide).day())
  }

  static func timestamp(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
  }

  static func startedText(_ date: Date) -> String {
    "Started \(timestamp(date))"
  }

  /// Silence between two consecutive messages before the chat timeline is worth
  /// annotating. Shared by the chat UI separators and the per-message metadata
  /// handed to the model, so both agree on what counts as a pause.
  static let messageGapThreshold: TimeInterval = 10 * 60

  /// Human readable duration such as "12 minutes" or "3 hours 5 minutes".
  static func elapsedDescription(_ interval: TimeInterval) -> String {
    let seconds = Int(max(0, interval).rounded())
    let minutes = seconds / 60
    if minutes < 60 {
      return unit(max(1, minutes), "minute")
    }
    let hours = minutes / 60
    if hours < 24 {
      let remainingMinutes = minutes % 60
      return remainingMinutes == 0
        ? unit(hours, "hour")
        : "\(unit(hours, "hour")) \(unit(remainingMinutes, "minute"))"
    }
    let days = hours / 24
    if days < 7 {
      let remainingHours = hours % 24
      return remainingHours == 0
        ? unit(days, "day")
        : "\(unit(days, "day")) \(unit(remainingHours, "hour"))"
    }
    if days < 60 {
      return unit(days, "day")
    }
    let months = days / 30
    if months < 24 {
      return unit(months, "month")
    }
    return unit(days / 365, "year")
  }

  /// Label for the gap separator drawn above `current`, or nil when the two
  /// messages are close enough that a marker would be noise.
  static func messageGapLabel(
    from previous: Date,
    to current: Date,
    calendar: Calendar = .autoupdatingCurrent
  ) -> String? {
    let elapsed = current.timeIntervalSince(previous)
    guard elapsed >= messageGapThreshold else { return nil }
    let when =
      calendar.isDate(previous, inSameDayAs: current)
      ? current.formatted(date: .omitted, time: .shortened)
      : timestamp(current)
    return "\(elapsedDescription(elapsed)) later · \(when)"
  }

  private static func unit(_ value: Int, _ name: String) -> String {
    "\(value) \(name)\(value == 1 ? "" : "s")"
  }
}

extension ConversationDatePresentation {
  /// Gap separators keyed by the message they are drawn above. Only user turns
  /// get one: an assistant reply follows its prompt immediately, so the pauses
  /// worth showing are the ones the user took before writing again.
  static func messageGapLabels(
    for messages: [ChatMessage],
    calendar: Calendar = .autoupdatingCurrent
  ) -> [UUID: String] {
    var labels: [UUID: String] = [:]
    var previous: Date?
    for message in messages {
      defer { previous = message.createdAt }
      guard message.role == .user, let previous else { continue }
      if let label = messageGapLabel(
        from: previous, to: message.createdAt, calendar: calendar)
      {
        labels[message.id] = label
      }
    }
    return labels
  }
}
