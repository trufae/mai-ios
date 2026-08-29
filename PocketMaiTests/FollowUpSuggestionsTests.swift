import Foundation
import XCTest

@testable import PocketMai

final class FollowUpSuggestionsTests: XCTestCase {
  func testDefaultsAreDisabledAndExposeFollowUpSlashPrompt() {
    let settings = AppSettings.defaults

    XCTAssertFalse(settings.followUps.isEnabled)
    XCTAssertEqual(settings.followUps.suggestionCount, 3)
    XCTAssertEqual(settings.followUps.contextMessageCount, 3)
    XCTAssertTrue(
      settings.userPrompts.contains {
        PromptSlashCommand.normalized($0.slashCommandName) == "followup"
      })
  }

  func testPromptUsesConfiguredRecentMessageCountAndJSONContract() throws {
    var settings = AppSettings.defaults
    settings.followUps.isEnabled = true
    settings.followUps.suggestionCount = 3
    settings.followUps.contextMessageCount = 2
    let customInstruction = "Offer focused next steps."
    let followUpIndex = try XCTUnwrap(
      settings.userPrompts.firstIndex(where: { $0.id == AppSettings.followUpUserPrompt.id }))
    settings.userPrompts[followUpIndex].text = customInstruction

    var conversation = Conversation()
    conversation.messages = [
      ChatMessage(role: .user, text: "Old message that should be excluded."),
      ChatMessage(role: .assistant, text: "Older answer that should be excluded."),
      ChatMessage(role: .user, text: "Which approach is safest?"),
      ChatMessage(role: .assistant, text: "Use the incremental migration."),
    ]

    let request = try XCTUnwrap(
      FollowUpPromptBuilder.request(conversation: conversation, settings: settings))

    XCTAssertTrue(request.prompt.contains(customInstruction))
    XCTAssertTrue(request.prompt.contains("Which approach is safest?"))
    XCTAssertTrue(request.prompt.contains("Use the incremental migration."))
    XCTAssertFalse(request.prompt.contains("Old message that should be excluded."))
    XCTAssertTrue(request.prompt.contains("Generate exactly 3 options"))
    XCTAssertTrue(request.prompt.contains(#"{"options":["First option","Second option"]}"#))
  }

  func testParserAcceptsFencedObjectDeduplicatesAndHonorsLimit() {
    let response = """
      ```json
      {"options":["Show me an example.","What are the tradeoffs?","show me an example.","How do I start?"]}
      ```
      """

    XCTAssertEqual(
      FollowUpSuggestionParser.parse(response, limit: 3),
      ["Show me an example.", "What are the tradeoffs?", "How do I start?"])
  }

  func testParserRejectsSuggestionsLongerThanTwelveWords() {
    let response = #"{"options":["Keep this one short.","This suggestion contains far too many words to qualify as a short follow-up sentence for display.","Show another example."]}"#

    XCTAssertEqual(
      FollowUpSuggestionParser.parse(response, limit: 3),
      ["Keep this one short.", "Show another example."])
  }

  func testParserIgnoresReasoningBeforeJSONPayload() {
    let response = """
      <think>
      We should output {"options":["Placeholder one","Placeholder two","Placeholder three"]}.
      </think>
      {"options":["Can you show an example?","What should I try first?","Are there any tradeoffs?"]}
      """

    XCTAssertEqual(
      FollowUpSuggestionParser.parse(response, limit: 3),
      ["Can you show an example?", "What should I try first?", "Are there any tradeoffs?"])
  }

  func testLegacySettingsDecodeWithFollowUpsDisabled() throws {
    let encoder = JSONEncoder()
    let encoded = try encoder.encode(AppSettings.defaults)
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["followUps"] = nil
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)

    XCTAssertEqual(decoded.followUps, .defaults)
  }
}
