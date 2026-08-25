import AppIntents
import Foundation

/// Starts a new PocketMai chat. When run from the Action Button / Siri /
/// Shortcuts without a prompt, iOS asks the user for the text via the
/// `requestValueDialog`. The captured prompt is handed to the app through the
/// shared App Group and applied when the app comes to the foreground.
struct NewPromptIntent: AppIntent {
  static let title: LocalizedStringResource = "New PocketMai Prompt"
  static let description = IntentDescription("Start a new PocketMai chat with a prompt.")
  static let openAppWhenRun = true

  @Parameter(title: "Prompt", requestValueDialog: "What do you want to ask?")
  var prompt: String

  func perform() async throws -> some IntentResult {
    SharedAppState.enqueueLaunchCommand(.newPrompt(text: prompt))
    return .result()
  }
}

/// Opens PocketMai directly into voice-conversation mode.
struct StartVoiceIntent: AppIntent {
  static let title: LocalizedStringResource = "Start PocketMai Voice"
  static let description = IntentDescription("Open PocketMai in voice conversation mode.")
  static let openAppWhenRun = true

  func perform() async throws -> some IntentResult {
    SharedAppState.enqueueLaunchCommand(.voice)
    return .result()
  }
}

/// Surfaces the intents to Shortcuts, Siri, and the Action Button so users can
/// assign them without any extra setup.
struct PocketMaiShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: NewPromptIntent(),
      phrases: [
        "New \(.applicationName) prompt",
        "Ask \(.applicationName)",
      ],
      shortTitle: "New Prompt",
      systemImageName: "square.and.pencil")
    AppShortcut(
      intent: StartVoiceIntent(),
      phrases: [
        "Start \(.applicationName) voice",
        "Talk to \(.applicationName)",
      ],
      shortTitle: "Voice Mode",
      systemImageName: "waveform")
  }
}
