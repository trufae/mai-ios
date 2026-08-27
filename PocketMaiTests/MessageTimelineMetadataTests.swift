import Foundation
import XCTest

@testable import PocketMai

@MainActor
final class MessageTimelineMetadataTests: XCTestCase {
  private let start = Date(timeIntervalSince1970: 1_756_300_000)
  private let utc = TimeZone(identifier: "UTC")!

  private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    return calendar
  }

  private func message(
    _ role: ChatRole,
    _ text: String,
    at offset: TimeInterval,
    location: String? = nil
  ) -> ChatMessage {
    ChatMessage(
      role: role,
      text: text,
      createdAt: start.addingTimeInterval(offset),
      locationText: location)
  }

  private func conversation(
    _ messages: [ChatMessage],
    tools: Set<BuiltInToolID>
  ) -> Conversation {
    var conversation = Conversation()
    conversation.toolsEnabled = true
    conversation.enabledTools = tools
    conversation.messages = messages
    return conversation
  }

  // MARK: - Elapsed formatting

  func testElapsedDescriptionPicksReadableUnits() {
    XCTAssertEqual(ConversationDatePresentation.elapsedDescription(60), "1 minute")
    XCTAssertEqual(ConversationDatePresentation.elapsedDescription(15 * 60), "15 minutes")
    XCTAssertEqual(ConversationDatePresentation.elapsedDescription(3_600), "1 hour")
    XCTAssertEqual(ConversationDatePresentation.elapsedDescription(5_400), "1 hour 30 minutes")
    XCTAssertEqual(ConversationDatePresentation.elapsedDescription(86_400), "1 day")
    XCTAssertEqual(ConversationDatePresentation.elapsedDescription(90_000), "1 day 1 hour")
    XCTAssertEqual(ConversationDatePresentation.elapsedDescription(10 * 86_400), "10 days")
    // Sub-minute pauses never reach the separator, but must not read "0 minutes".
    XCTAssertEqual(ConversationDatePresentation.elapsedDescription(20), "1 minute")
  }

  // MARK: - Chat separators

  func testShortPauseGetsNoSeparator() {
    XCTAssertNil(
      ConversationDatePresentation.messageGapLabel(
        from: start,
        to: start.addingTimeInterval(4 * 60),
        calendar: utcCalendar))
  }

  func testLongPauseSeparatorReportsElapsedTime() {
    let label = ConversationDatePresentation.messageGapLabel(
      from: start,
      to: start.addingTimeInterval(42 * 60),
      calendar: utcCalendar)
    XCTAssertNotNil(label)
    XCTAssertTrue(label?.hasPrefix("42 minutes later · ") == true, label ?? "nil")
  }

  func testSeparatorsOnlyPrecedeUserMessagesThatFollowAPause() {
    let first = message(.user, "hi", at: 0)
    let reply = message(.assistant, "hello", at: 2)
    let resumed = message(.user, "back", at: 3 * 3_600 + 2)
    let quickReply = message(.assistant, "welcome back", at: 3 * 3_600 + 7)
    let labels = ConversationDatePresentation.messageGapLabels(
      for: [first, reply, resumed, quickReply],
      calendar: utcCalendar)

    XCTAssertEqual(labels.count, 1)
    XCTAssertNotNil(labels[resumed.id])
    XCTAssertTrue(
      labels[resumed.id]?.hasPrefix("3 hours later · ") == true, labels[resumed.id] ?? "")
    XCTAssertNil(labels[first.id])
    XCTAssertNil(labels[quickReply.id])
  }

  // MARK: - Prompt metadata

  func testNoMetadataWhenTimeAndLocationToolsAreOff() {
    let chat = conversation(
      [message(.user, "hi", at: 0, location: "Barcelona")],
      tools: [.calculator])
    XCTAssertTrue(MessageMetadataAnnotation.annotations(for: chat, timeZone: utc).isEmpty)
  }

  func testNoMetadataWhenToolsAreDisabledForTheConversation() {
    var chat = conversation([message(.user, "hi", at: 0)], tools: [.datetime])
    chat.toolsEnabled = false
    XCTAssertTrue(MessageMetadataAnnotation.annotations(for: chat, timeZone: utc).isEmpty)
  }

  func testTimeMetadataCarriesTheGapSinceThePreviousMessage() {
    let first = message(.user, "hi", at: 0)
    let reply = message(.assistant, "hello", at: 2)
    let resumed = message(.user, "so about that", at: 10 * 60 + 2)
    let chat = conversation([first, reply, resumed], tools: [.datetime])
    let annotations = MessageMetadataAnnotation.annotations(for: chat, timeZone: utc)

    XCTAssertEqual(annotations.count, 2)
    XCTAssertNil(annotations[reply.id])
    // The opening turn has no previous message to measure against.
    XCTAssertEqual(annotations[first.id]?.contains("after the previous message"), false)
    XCTAssertTrue(
      annotations[resumed.id]?.contains("10 minutes after the previous message") == true,
      annotations[resumed.id] ?? "nil")
  }

  func testConsecutiveMessagesSkipTheElapsedNote() {
    let first = message(.user, "hi", at: 0)
    let second = message(.user, "and one more thing", at: 30)
    let chat = conversation([first, second], tools: [.datetime])
    let annotations = MessageMetadataAnnotation.annotations(for: chat, timeZone: utc)

    XCTAssertEqual(annotations[second.id]?.contains("after the previous message"), false)
  }

  func testLocationMetadataUsesThePlaceCapturedWithTheMessage() {
    let older = message(.user, "at home", at: 0, location: "Latitude 41.3851, longitude 2.1734")
    let newer = message(
      .user, "at the office", at: 2 * 3_600, location: "Latitude 41.4000, longitude 2.2000")
    let chat = conversation([older, newer], tools: [.datetime, .location])
    let annotations = MessageMetadataAnnotation.annotations(for: chat, timeZone: utc)

    XCTAssertTrue(
      annotations[older.id]?.contains("location: Latitude 41.3851, longitude 2.1734") == true,
      annotations[older.id] ?? "nil")
    XCTAssertTrue(
      annotations[newer.id]?.contains("location: Latitude 41.4000, longitude 2.2000") == true,
      annotations[newer.id] ?? "nil")
  }

  func testLocationOnlyConversationsStillAnnotateWithoutTimestamps() {
    let only = message(.user, "here", at: 0, location: "Barcelona")
    let chat = conversation([only], tools: [.location])
    let line = MessageMetadataAnnotation.annotations(for: chat, timeZone: utc)[only.id]

    XCTAssertEqual(line, "[message metadata: location: Barcelona]")
  }

  func testMessagesWithoutACapturedLocationAreNotAnnotated() {
    let only = message(.user, "here", at: 0)
    let chat = conversation([only], tools: [.location])
    XCTAssertTrue(MessageMetadataAnnotation.annotations(for: chat, timeZone: utc).isEmpty)
  }

  func testTimestampIsExplicitAboutTheZone() {
    let stamp = MessageMetadataAnnotation.timestamp(
      Date(timeIntervalSince1970: 1_756_300_800), timeZone: utc)
    XCTAssertEqual(stamp, "Wednesday 2025-08-27 13:20 GMT")
  }

  // MARK: - Prompt wiring

  func testOpenAIPromptPrefixesUserTurnsWithMetadata() {
    let first = message(.user, "plan my trip", at: 0, location: "Barcelona")
    let reply = message(.assistant, "sure", at: 2)
    let resumed = message(.user, "I am back", at: 3 * 3_600 + 2, location: "Girona")
    var chat = conversation([first, reply, resumed], tools: [.datetime, .location])
    chat.provider = .openAICompatible

    let messages = PromptComposer.openAIMessages(
      conversation: chat,
      settings: AppSettings(),
      context: "",
      model: "gpt-test",
      endpoint: OpenAIEndpoint())
    let userMessages = messages.filter { $0.role == "user" }

    XCTAssertEqual(userMessages.count, 2)
    XCTAssertTrue(
      userMessages[0].textContent.hasPrefix("[message metadata: sent "),
      userMessages[0].textContent)
    XCTAssertTrue(
      userMessages[0].textContent.hasSuffix("\nplan my trip"), userMessages[0].textContent)
    XCTAssertTrue(
      userMessages[0].textContent.contains("location: Barcelona"), userMessages[0].textContent)
    XCTAssertTrue(
      userMessages[1].textContent.contains("3 hours after the previous message"),
      userMessages[1].textContent)
    XCTAssertTrue(
      messages.contains { $0.role == "assistant" && $0.textContent == "sure" })
  }

  func testOpenAIPromptLeavesTurnsUntouchedWhenToolsAreOff() {
    let first = message(.user, "plan my trip", at: 0, location: "Barcelona")
    var chat = conversation([first], tools: [])
    chat.provider = .openAICompatible

    let messages = PromptComposer.openAIMessages(
      conversation: chat,
      settings: AppSettings(),
      context: "",
      model: "gpt-test",
      endpoint: OpenAIEndpoint())

    XCTAssertEqual(messages.filter { $0.role == "user" }.first?.textContent, "plan my trip")
  }

  func testContextNoteExplainsTheMetadataLines() {
    let chat = conversation([message(.user, "hi", at: 0)], tools: [.datetime])
    let note = MessageMetadataAnnotation.contextNote(conversation: chat)
    XCTAssertTrue(note?.contains("[message metadata: ...]") == true, note ?? "nil")
    XCTAssertNil(
      MessageMetadataAnnotation.contextNote(
        conversation: conversation([], tools: [.calculator])))
  }
}
