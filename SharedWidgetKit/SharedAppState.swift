import Foundation

/// Bridges a small amount of state between the PocketMai app and its widget /
/// App-Intent extensions through a shared App Group container.
///
/// - The app *writes* the current provider/model labels so widgets can mirror
///   the active selection.
/// - App Intents (Action Button / Siri) *enqueue* a pending launch command that
///   the app *drains* when it next becomes active.
enum SharedAppState {
  static let appGroupID = "group.io.github.trufae.mai"

  private static var defaults: UserDefaults? {
    UserDefaults(suiteName: appGroupID)
  }

  private enum Key {
    static let providerLabel = "widget.providerLabel"
    static let modelLabel = "widget.modelLabel"
    static let pendingCommand = "widget.pendingCommand"
  }

  // MARK: - Current selection (app writes, widgets read)

  static var providerLabel: String {
    get { defaults?.string(forKey: Key.providerLabel) ?? "" }
    set { defaults?.set(newValue, forKey: Key.providerLabel) }
  }

  static var modelLabel: String {
    get { defaults?.string(forKey: Key.modelLabel) ?? "" }
    set { defaults?.set(newValue, forKey: Key.modelLabel) }
  }

  // MARK: - Pending launch command (intents write, app drains)

  static func enqueueLaunchCommand(_ command: LaunchCommand) {
    guard let data = try? JSONEncoder().encode(command) else { return }
    defaults?.set(data, forKey: Key.pendingCommand)
  }

  static func takePendingLaunchCommand() -> LaunchCommand? {
    guard let data = defaults?.data(forKey: Key.pendingCommand) else { return nil }
    defaults?.removeObject(forKey: Key.pendingCommand)
    return try? JSONDecoder().decode(LaunchCommand.self, from: data)
  }
}
