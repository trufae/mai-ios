import Foundation

/// Groups and formats chat timestamps the way the PocketMai sidebar does, so
/// every host lists chats under the same Today / Yesterday / This week headers.
public enum ChatDatePresentation {
  /// The sidebar section a chat updated at `date` belongs to.
  public static func groupTitle(
    for date: Date,
    relativeTo now: Date = Date(),
    calendar: Calendar = .current
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
    let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
    return formatter(sameYear ? "MMMM d" : "MMMM d, yyyy", calendar: calendar).string(from: date)
  }

  /// A full, sortable timestamp such as `2026-09-05 14:32`.
  public static func timestamp(_ date: Date, calendar: Calendar = .current) -> String {
    formatter("yyyy-MM-dd HH:mm", calendar: calendar).string(from: date)
  }

  /// Only the time when `date` falls on the same day as `now`; the full
  /// timestamp otherwise. Meant for rows already grouped under a day header.
  public static func compactTimestamp(
    _ date: Date,
    relativeTo now: Date = Date(),
    calendar: Calendar = .current
  ) -> String {
    guard calendar.isDate(date, inSameDayAs: now) else {
      return timestamp(date, calendar: calendar)
    }
    return formatter("HH:mm", calendar: calendar).string(from: date)
  }

  private static func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = format
    return formatter
  }
}
