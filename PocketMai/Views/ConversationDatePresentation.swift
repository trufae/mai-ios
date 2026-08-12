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
}
