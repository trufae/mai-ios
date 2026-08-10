import AlarmKit
import Foundation
import SwiftUI

@MainActor
enum AlarmTool {
  static let setName = "alarm_set"
  static let listName = "alarm_list"
  static let cancelName = "alarm_cancel"

  static let definitions: [ToolDefinition] = [
    ToolDefinition(
      name: setName,
      description:
        "Schedule an alarm on this device. Use in_minutes for a countdown, or time with an optional date or weekdays for a specific moment.",
      parameters: [
        ToolParameterDef(
          name: "label", type: "string",
          description: "Short alarm label shown when it fires.",
          required: false),
        ToolParameterDef(
          name: "in_minutes", type: "number",
          description: "Fire this many minutes from now. Overrides time and date.",
          required: false),
        ToolParameterDef(
          name: "time", type: "string",
          description: "24-hour clock time as HH:MM, such as 07:30.",
          required: false),
        ToolParameterDef(
          name: "date", type: "string",
          description: "Calendar day as YYYY-MM-DD for a one-shot alarm at the given time.",
          required: false),
        ToolParameterDef(
          name: "weekdays", type: "string",
          description:
            "Comma-separated weekday names, such as monday,friday, for an alarm repeating at the given time.",
          required: false),
      ]),
    ToolDefinition(
      name: listName,
      description: "List alarms scheduled by this app with their short IDs.",
      parameters: []),
    ToolDefinition(
      name: cancelName,
      description: "Cancel a scheduled alarm by short ID.",
      parameters: [
        ToolParameterDef(
          name: "id", type: "string",
          description: "Short ID or ID prefix from alarm_list or alarm_set.",
          required: true)
      ]),
  ]

  private static let unsupportedMessage =
    "Error: alarms require iOS 26.1 or later on this device."

  static func set(arguments: [String: AgentToolArgumentValue]) async -> String {
    guard #available(iOS 26.1, *) else { return unsupportedMessage }
    return await AlarmKitService.set(arguments: arguments)
  }

  static func list() -> String {
    guard #available(iOS 26.1, *) else { return unsupportedMessage }
    return AlarmKitService.list()
  }

  static func cancel(arguments: [String: AgentToolArgumentValue]) -> String {
    guard #available(iOS 26.1, *) else { return unsupportedMessage }
    return AlarmKitService.cancel(arguments: arguments)
  }
}

@available(iOS 26.1, *)
private struct AlarmToolMetadata: AlarmMetadata {}

@available(iOS 26.1, *)
@MainActor
private enum AlarmKitService {
  static func set(arguments: [String: AgentToolArgumentValue]) async -> String {
    if let error = await authorizationError() { return error }
    let label = firstNonEmpty(arguments["label"]?.stringValue, arguments["title"]?.stringValue)
      ?? "PocketMai Alarm"
    let schedule: Alarm.Schedule
    let scheduleSummary: String
    switch buildSchedule(arguments: arguments) {
    case .success(let built):
      (schedule, scheduleSummary) = built
    case .failure(let message):
      return message
    }
    let alert = AlarmPresentation.Alert(title: LocalizedStringResource("\(label)"))
    let attributes = AlarmAttributes<AlarmToolMetadata>(
      presentation: AlarmPresentation(alert: alert),
      tintColor: .accentColor)
    let configuration = AlarmManager.AlarmConfiguration.alarm(
      schedule: schedule, attributes: attributes)
    do {
      let alarm = try await AlarmManager.shared.schedule(id: UUID(), configuration: configuration)
      return "Alarm '\(label)' set \(scheduleSummary) (id=\(shortID(alarm.id)))."
    } catch AlarmManager.AlarmError.maximumLimitReached {
      return "Error: the maximum number of alarms is reached. Cancel one first."
    } catch {
      return "Error: could not schedule the alarm: \(error.localizedDescription)"
    }
  }

  static func list() -> String {
    let alarms = (try? AlarmManager.shared.alarms) ?? []
    guard !alarms.isEmpty else { return "No alarms scheduled by this app." }
    return alarms.map { alarm in
      "- \(shortID(alarm.id)) [\(stateName(alarm.state))] \(describe(alarm.schedule))"
    }.joined(separator: "\n")
  }

  static func cancel(arguments: [String: AgentToolArgumentValue]) -> String {
    let query = (arguments["id"]?.stringValue ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else { return "Error: id is required." }
    let alarms = (try? AlarmManager.shared.alarms) ?? []
    guard let alarm = alarms.first(where: { $0.id.uuidString.lowercased().hasPrefix(query) })
    else {
      return "Error: no alarm matched '\(query)'. Use alarm_list to see the IDs."
    }
    do {
      try AlarmManager.shared.cancel(id: alarm.id)
      return "Cancelled alarm \(shortID(alarm.id)) (\(describe(alarm.schedule)))."
    } catch {
      return "Error: could not cancel the alarm: \(error.localizedDescription)"
    }
  }

  private static func authorizationError() async -> String? {
    let manager = AlarmManager.shared
    switch manager.authorizationState {
    case .authorized:
      return nil
    case .denied:
      return "Error: alarm access is denied. Enable it for PocketMai in iOS Settings."
    case .notDetermined:
      let state = (try? await manager.requestAuthorization()) ?? .denied
      return state == .authorized
        ? nil : "Error: the alarm permission was not granted."
    @unknown default:
      return "Error: unknown alarm authorization state."
    }
  }

  private static func buildSchedule(
    arguments: [String: AgentToolArgumentValue]
  ) -> BuildResult {
    if let minutes = arguments["in_minutes"]?.numberValue ?? arguments["minutes"]?.numberValue {
      guard minutes > 0 else { return .failure("Error: in_minutes must be greater than zero.") }
      let fireDate = Date().addingTimeInterval(minutes * 60)
      return .success((.fixed(fireDate), "for \(formatted(fireDate))"))
    }
    let timeText = arguments["time"]?.stringValue ?? ""
    guard let time = parseTime(timeText) else {
      return .failure(
        timeText.isEmpty
          ? "Error: provide in_minutes or a time (HH:MM)."
          : "Error: time must be HH:MM in 24-hour format, got '\(timeText)'.")
    }
    let weekdaysText = arguments["weekdays"]?.stringValue ?? ""
    if !weekdaysText.isEmpty {
      guard let days = parseWeekdays(weekdaysText) else {
        return .failure("Error: weekdays must be names like monday,friday, got '\(weekdaysText)'.")
      }
      let relative = Alarm.Schedule.Relative(
        time: .init(hour: time.hour, minute: time.minute),
        repeats: .weekly(days))
      return .success(
        (.relative(relative),
         "for \(clockText(time)) repeating on \(weekdaysText.lowercased())"))
    }
    let dateText = arguments["date"]?.stringValue ?? ""
    if !dateText.isEmpty {
      guard let fireDate = parseDate(dateText, time: time) else {
        return .failure("Error: date must be YYYY-MM-DD, got '\(dateText)'.")
      }
      guard fireDate > Date() else {
        return .failure("Error: \(dateText) \(clockText(time)) is in the past.")
      }
      return .success((.fixed(fireDate), "for \(formatted(fireDate))"))
    }
    let relative = Alarm.Schedule.Relative(
      time: .init(hour: time.hour, minute: time.minute), repeats: .never)
    return .success((.relative(relative), "for the next \(clockText(time))"))
  }

  private enum BuildResult {
    case success((Alarm.Schedule, String))
    case failure(String)
  }

  private static func parseTime(_ text: String) -> (hour: Int, minute: Int)? {
    let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
    guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
      (0...23).contains(hour), (0...59).contains(minute)
    else { return nil }
    return (hour, minute)
  }

  private static func parseDate(_ text: String, time: (hour: Int, minute: Int)) -> Date? {
    let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "-")
    guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]),
      let day = Int(parts[2]), (1...12).contains(month), (1...31).contains(day)
    else { return nil }
    let components = DateComponents(
      year: year, month: month, day: day, hour: time.hour, minute: time.minute)
    return Calendar.current.date(from: components)
  }

  private static func parseWeekdays(_ text: String) -> [Locale.Weekday]? {
    var days: [Locale.Weekday] = []
    for part in text.split(separator: ",") {
      let name = part.trimmingCharacters(in: .whitespaces).lowercased()
      guard let day = weekday(named: name) else { return nil }
      if !days.contains(day) { days.append(day) }
    }
    return days.isEmpty ? nil : days
  }

  private static func weekday(named name: String) -> Locale.Weekday? {
    switch name.prefix(3) {
    case "sun": return .sunday
    case "mon": return .monday
    case "tue": return .tuesday
    case "wed": return .wednesday
    case "thu": return .thursday
    case "fri": return .friday
    case "sat": return .saturday
    default: return nil
    }
  }

  private static func describe(_ schedule: Alarm.Schedule?) -> String {
    switch schedule {
    case .fixed(let date):
      return formatted(date)
    case .relative(let relative):
      let time = clockText((relative.time.hour, relative.time.minute))
      switch relative.repeats {
      case .weekly(let days):
        let names = days.map { weekdayName($0) }.joined(separator: ",")
        return "\(time) repeating on \(names)"
      case .never:
        return "next \(time)"
      @unknown default:
        return time
      }
    case nil:
      return "no schedule"
    @unknown default:
      return "unknown schedule"
    }
  }

  private static func weekdayName(_ day: Locale.Weekday) -> String {
    switch day {
    case .sunday: return "sunday"
    case .monday: return "monday"
    case .tuesday: return "tuesday"
    case .wednesday: return "wednesday"
    case .thursday: return "thursday"
    case .friday: return "friday"
    case .saturday: return "saturday"
    @unknown default: return "unknown"
    }
  }

  private static func stateName(_ state: Alarm.State) -> String {
    switch state {
    case .scheduled: return "scheduled"
    case .countdown: return "countdown"
    case .paused: return "paused"
    case .alerting: return "alerting"
    @unknown default: return "unknown"
    }
  }

  private static func clockText(_ time: (hour: Int, minute: Int)) -> String {
    String(format: "%02d:%02d", time.hour, time.minute)
  }

  private static func formatted(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
  }

  private static func shortID(_ id: UUID) -> String {
    String(id.uuidString.prefix(8))
  }

  private static func firstNonEmpty(_ values: String?...) -> String? {
    for value in values {
      if let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
        return trimmed
      }
    }
    return nil
  }
}
