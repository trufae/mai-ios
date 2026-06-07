import EventKit
import Foundation

@MainActor
enum CalendarEventService {
  private static let eventStore = EKEventStore()
  private static let maxReadRange: TimeInterval = 32 * 24 * 60 * 60
  private static let maxCreateDuration: TimeInterval = 31 * 24 * 60 * 60
  private static let maxReturnedEvents = 100

  private struct DateParseResult {
    let date: Date
    let isDateOnly: Bool
  }

  private struct EventRange {
    let start: Date
    let end: Date
    let label: String
  }

  private enum CalendarEventError: LocalizedError {
    case calendarAccessRequired(String)
    case writeOnlyAccess
    case missingDateRange
    case invalidRange(String)
    case rangeTooLarge(Int)
    case missingTitle
    case titleTooLong
    case notesTooLong
    case invalidDate(String)
    case missingDefaultCalendar
    case saveFailed(String)

    var errorDescription: String? {
      switch self {
      case .calendarAccessRequired(let status):
        return "Calendar access is not available (\(status)). Enable Calendar access in iOS Settings."
      case .writeOnlyAccess:
        return "Calendar read access is not available. iOS currently allows write-only Calendar access."
      case .missingDateRange:
        return
          "Specify a range such as today, tomorrow, yesterday, week, next week, or this month, or provide start_date and end_date."
      case .invalidRange(let detail):
        return detail
      case .rangeTooLarge(let days):
        return "Calendar range is too large. Request \(days) days or fewer."
      case .missingTitle:
        return "Calendar event title is required."
      case .titleTooLong:
        return "Calendar event title is too long. Keep it under 200 characters."
      case .notesTooLong:
        return "Calendar event notes are too long. Keep them under 2000 characters."
      case .invalidDate(let value):
        return "Invalid calendar date '\(value)'. Use YYYY-MM-DD or ISO 8601 date-time."
      case .missingDefaultCalendar:
        return "No default calendar is available for new events."
      case .saveFailed(let message):
        return "Could not create calendar event: \(message)"
      }
    }
  }

  static func readEvents(arguments: [String: AgentToolArgumentValue]) async -> String {
    do {
      try await ensureReadableAccess()
      let range = try eventRange(from: arguments)
      try validateRange(range.start, range.end, maxDuration: maxReadRange)

      let predicate = eventStore.predicateForEvents(
        withStart: range.start,
        end: range.end,
        calendars: nil)
      let events = eventStore.events(matching: predicate)
        .sorted { lhs, rhs in
          if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
          return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

      let header = "Calendar events (\(range.label), \(TimeZone.current.identifier)):"
      guard !events.isEmpty else { return "\(header)\nNo events." }

      let shown = events.prefix(maxReturnedEvents).map(formatEvent).joined(separator: "\n")
      let hiddenCount = max(0, events.count - maxReturnedEvents)
      let suffix = hiddenCount == 0 ? "" : "\n...and \(hiddenCount) more event(s)."
      return "\(header)\n\(shown)\(suffix)"
    } catch {
      return "Error: \(error.localizedDescription)"
    }
  }

  static func createEvent(
    arguments: [String: AgentToolArgumentValue],
    settings: NativeToolSettings
  ) async -> String {
    guard settings.calendarEventCreationEnabled else {
      return "Error: Calendar event creation is disabled in Settings."
    }

    do {
      try await ensureWritableAccess()
      let title = rawString(arguments, keys: ["title", "name", "summary"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty else { throw CalendarEventError.missingTitle }
      guard title.count <= 200 else { throw CalendarEventError.titleTooLong }

      let allDay = arguments["all_day"]?.boolValue ?? arguments["allDay"]?.boolValue ?? false
      let startRaw = rawString(arguments, keys: ["start_date", "start", "from", "begin"])
      let endRaw = rawString(arguments, keys: ["end_date", "end", "to", "until"])
      guard !startRaw.isEmpty else { throw CalendarEventError.invalidDate("start_date") }
      guard !endRaw.isEmpty else { throw CalendarEventError.invalidDate("end_date") }

      let parsedStart = try parseDate(startRaw)
      let parsedEnd = try parseDate(endRaw)
      let startDate: Date
      let endDate: Date
      if allDay {
        startDate = localCalendar.startOfDay(for: parsedStart.date)
        let endDay = localCalendar.startOfDay(for: parsedEnd.date)
        if parsedEnd.isDateOnly {
          endDate = localCalendar.date(byAdding: .day, value: 1, to: endDay) ?? endDay
        } else {
          endDate = endDay
        }
      } else {
        startDate = normalizedStart(parsedStart)
        endDate = normalizedEnd(parsedEnd)
      }

      try validateRange(startDate, endDate, maxDuration: maxCreateDuration)

      guard let calendar = eventStore.defaultCalendarForNewEvents else {
        throw CalendarEventError.missingDefaultCalendar
      }

      let location = rawString(arguments, keys: ["location", "where"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let notes = rawString(arguments, keys: ["notes", "note", "description"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard notes.count <= 2000 else { throw CalendarEventError.notesTooLong }

      let event = EKEvent(eventStore: eventStore)
      event.calendar = calendar
      event.title = title
      event.startDate = startDate
      event.endDate = endDate
      event.isAllDay = allDay
      if !location.isEmpty { event.location = location }
      if !notes.isEmpty { event.notes = notes }

      do {
        try eventStore.save(event, span: .thisEvent, commit: true)
      } catch {
        throw CalendarEventError.saveFailed(error.localizedDescription)
      }

      return """
        Created calendar event:
        - Title: \(oneLine(title))
        - When: \(formatEventDateRange(start: startDate, end: endDate, isAllDay: allDay))
        - Calendar: \(oneLine(calendar.title))
        """
    } catch {
      return "Error: \(error.localizedDescription)"
    }
  }

  private static func ensureReadableAccess() async throws {
    switch EKEventStore.authorizationStatus(for: .event) {
    case .fullAccess:
      return
    case .authorized:
      return
    case .writeOnly:
      throw CalendarEventError.writeOnlyAccess
    case .notDetermined:
      let granted = await requestFullAccess()
      if !granted {
        throw CalendarEventError.calendarAccessRequired("not granted")
      }
    case .restricted:
      throw CalendarEventError.calendarAccessRequired("restricted")
    case .denied:
      throw CalendarEventError.calendarAccessRequired("denied")
    @unknown default:
      throw CalendarEventError.calendarAccessRequired("unknown")
    }
  }

  private static func ensureWritableAccess() async throws {
    switch EKEventStore.authorizationStatus(for: .event) {
    case .fullAccess, .writeOnly:
      return
    case .authorized:
      return
    case .notDetermined:
      let granted = await requestWriteOnlyAccess()
      if !granted {
        throw CalendarEventError.calendarAccessRequired("not granted")
      }
    case .restricted:
      throw CalendarEventError.calendarAccessRequired("restricted")
    case .denied:
      throw CalendarEventError.calendarAccessRequired("denied")
    @unknown default:
      throw CalendarEventError.calendarAccessRequired("unknown")
    }
  }

  private static func requestFullAccess() async -> Bool {
    await withCheckedContinuation { continuation in
      eventStore.requestFullAccessToEvents { granted, _ in
        continuation.resume(returning: granted)
      }
    }
  }

  private static func requestWriteOnlyAccess() async -> Bool {
    await withCheckedContinuation { continuation in
      eventStore.requestWriteOnlyAccessToEvents { granted, _ in
        continuation.resume(returning: granted)
      }
    }
  }

  private static func eventRange(from arguments: [String: AgentToolArgumentValue]) throws
    -> EventRange
  {
    let rangeRaw = rawString(arguments, keys: ["range", "period", "when"])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let dateRaw = rawString(arguments, keys: ["date", "day"])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let startRaw = rawString(arguments, keys: ["start_date", "start", "from", "begin"])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let endRaw = rawString(arguments, keys: ["end_date", "end", "to", "until"])
      .trimmingCharacters(in: .whitespacesAndNewlines)

    if !startRaw.isEmpty || !endRaw.isEmpty {
      guard !startRaw.isEmpty, !endRaw.isEmpty else {
        throw CalendarEventError.missingDateRange
      }
      let start = try parseDate(startRaw)
      let end = try parseDate(endRaw)
      let startDate = normalizedStart(start)
      let endDate = normalizedEnd(end)
      return EventRange(
        start: startDate,
        end: endDate,
        label: "\(shortDateTime(startDate)) to \(shortDateTime(endDate))")
    }

    if !dateRaw.isEmpty {
      if let range = naturalRange(for: dateRaw) {
        return range
      }
      let date = try parseDate(dateRaw)
      let start = localCalendar.startOfDay(for: date.date)
      let end = localCalendar.date(byAdding: .day, value: 1, to: start) ?? start
      return EventRange(start: start, end: end, label: "day \(shortDate(start))")
    }

    if let natural = naturalRange(for: rangeRaw) {
      return natural
    }
    if let parsed = try? parseDate(rangeRaw) {
      let start = localCalendar.startOfDay(for: parsed.date)
      let end = localCalendar.date(byAdding: .day, value: 1, to: start) ?? start
      return EventRange(start: start, end: end, label: "day \(shortDate(start))")
    }
    throw CalendarEventError.missingDateRange
  }

  private static func naturalRange(for raw: String) -> EventRange? {
    let value = raw.normalizedCalendarPhrase
    switch value {
    case "", "today", "day", "current day":
      return dayRange(offset: 0, labelPrefix: "today")
    case "yesterday", "previous day", "last day":
      return dayRange(offset: -1, labelPrefix: "yesterday")
    case "tomorrow", "next day":
      return dayRange(offset: 1, labelPrefix: "tomorrow")
    case "week", "week ahead", "next 7 days", "coming week", "upcoming week":
      let start = localCalendar.startOfDay(for: Date())
      let end = localCalendar.date(byAdding: .day, value: 7, to: start) ?? start
      return EventRange(start: start, end: end, label: "next 7 days")
    case "this week", "current week":
      return weekRange(offset: 0, label: "this week")
    case "next week", "following week":
      return weekRange(offset: 1, label: "next week")
    case "last week", "previous week":
      return weekRange(offset: -1, label: "last week")
    case "this month", "current month", "month":
      return monthRange(offset: 0, label: "this month")
    case "next month", "following month":
      return monthRange(offset: 1, label: "next month")
    case "last month", "previous month":
      return monthRange(offset: -1, label: "last month")
    default:
      return nil
    }
  }

  private static func dayRange(offset: Int, labelPrefix: String) -> EventRange {
    let today = localCalendar.startOfDay(for: Date())
    let start = localCalendar.date(byAdding: .day, value: offset, to: today) ?? today
    let end = localCalendar.date(byAdding: .day, value: 1, to: start) ?? start
    return EventRange(start: start, end: end, label: "\(labelPrefix) \(shortDate(start))")
  }

  private static func weekRange(offset: Int, label: String) -> EventRange? {
    guard let current = localCalendar.dateInterval(of: .weekOfYear, for: Date()),
      let start = localCalendar.date(byAdding: .weekOfYear, value: offset, to: current.start),
      let end = localCalendar.date(byAdding: .weekOfYear, value: 1, to: start)
    else {
      return nil
    }
    return EventRange(start: start, end: end, label: label)
  }

  private static func monthRange(offset: Int, label: String) -> EventRange? {
    guard let current = localCalendar.dateInterval(of: .month, for: Date()),
      let start = localCalendar.date(byAdding: .month, value: offset, to: current.start),
      let end = localCalendar.date(byAdding: .month, value: 1, to: start)
    else {
      return nil
    }
    return EventRange(start: start, end: end, label: label)
  }

  private static func validateRange(
    _ start: Date,
    _ end: Date,
    maxDuration: TimeInterval
  ) throws {
    guard end > start else {
      throw CalendarEventError.invalidRange("Calendar end date must be after start date.")
    }
    guard end.timeIntervalSince(start) <= maxDuration else {
      throw CalendarEventError.rangeTooLarge(Int(maxDuration / 86_400))
    }
  }

  private static func normalizedStart(_ parsed: DateParseResult) -> Date {
    parsed.isDateOnly ? localCalendar.startOfDay(for: parsed.date) : parsed.date
  }

  private static func normalizedEnd(_ parsed: DateParseResult) -> Date {
    if parsed.isDateOnly {
      let start = localCalendar.startOfDay(for: parsed.date)
      return localCalendar.date(byAdding: .day, value: 1, to: start) ?? start
    }
    return parsed.date
  }

  private static func parseDate(_ raw: String) throws -> DateParseResult {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { throw CalendarEventError.invalidDate(raw) }

    switch value.normalizedCalendarPhrase {
    case "today", "current day":
      return DateParseResult(date: localCalendar.startOfDay(for: Date()), isDateOnly: true)
    case "yesterday", "previous day", "last day":
      return DateParseResult(
        date: dayRange(offset: -1, labelPrefix: "yesterday").start,
        isDateOnly: true)
    case "tomorrow", "next day":
      return DateParseResult(
        date: dayRange(offset: 1, labelPrefix: "tomorrow").start,
        isDateOnly: true)
    default:
      break
    }

    if let date = isoDateTimeFormatter.date(from: value) {
      return DateParseResult(date: date, isDateOnly: false)
    }
    for formatter in localDateTimeFormatters {
      if let date = formatter.date(from: value) {
        return DateParseResult(date: date, isDateOnly: false)
      }
    }
    if let date = localDateFormatter.date(from: value) {
      return DateParseResult(date: date, isDateOnly: true)
    }
    throw CalendarEventError.invalidDate(value)
  }

  private static func rawString(
    _ arguments: [String: AgentToolArgumentValue],
    keys: [String]
  ) -> String {
    for key in keys {
      if let value = arguments[key]?.stringValue {
        return value
      }
    }
    return ""
  }

  private static func formatEvent(_ event: EKEvent) -> String {
    var parts = ["- \(formatEventDateRange(start: event.startDate, end: event.endDate, isAllDay: event.isAllDay)): \(oneLine(event.title))"]
    if event.isAllDay {
      parts.append("all day")
    }
    if let calendarTitle = event.calendar?.title, !calendarTitle.isEmpty {
      parts.append("calendar: \(oneLine(calendarTitle))")
    }
    let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !location.isEmpty {
      parts.append("location: \(oneLine(location))")
    }
    return parts.joined(separator: " | ")
  }

  private static func formatEventDateRange(start: Date, end: Date, isAllDay: Bool) -> String {
    if isAllDay {
      let exclusiveEnd = localCalendar.date(byAdding: .day, value: -1, to: end) ?? end
      if localCalendar.isDate(start, inSameDayAs: exclusiveEnd) {
        return "\(shortDate(start))"
      }
      return "\(shortDate(start)) to \(shortDate(exclusiveEnd))"
    }
    if localCalendar.isDate(start, inSameDayAs: end) {
      return "\(shortDate(start)) \(shortTime(start))-\(shortTime(end))"
    }
    return "\(shortDateTime(start)) to \(shortDateTime(end))"
  }

  private static func oneLine(_ value: String) -> String {
    value
      .split(whereSeparator: \.isNewline)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static var localCalendar: Calendar {
    var calendar = Calendar.autoupdatingCurrent
    calendar.timeZone = .autoupdatingCurrent
    return calendar
  }

  private static let isoDateTimeFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  private static let localDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  private static let localDateTimeFormatters: [DateFormatter] = [
    "yyyy-MM-dd'T'HH:mm:ssXXXXX",
    "yyyy-MM-dd'T'HH:mmXXXXX",
    "yyyy-MM-dd'T'HH:mm:ss",
    "yyyy-MM-dd'T'HH:mm",
    "yyyy-MM-dd HH:mm:ss",
    "yyyy-MM-dd HH:mm",
  ].map { format in
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateFormat = format
    return formatter
  }

  private static let shortDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
  }()

  private static let shortTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
  }()

  private static let shortDateTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()

  private static func shortDate(_ date: Date) -> String {
    shortDateFormatter.string(from: date)
  }

  private static func shortTime(_ date: Date) -> String {
    shortTimeFormatter.string(from: date)
  }

  private static func shortDateTime(_ date: Date) -> String {
    shortDateTimeFormatter.string(from: date)
  }
}

private extension String {
  var normalizedCalendarPhrase: String {
    lowercased()
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
