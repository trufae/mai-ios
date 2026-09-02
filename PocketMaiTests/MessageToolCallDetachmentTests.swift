import XCTest

@testable import PocketMai

final class MessageToolCallDetachmentTests: XCTestCase {
  private let message = """
    Here is the forecast.

    <tool_run>
    Weather tool ({"city":"Barcelona"}):
    22C and sunny
    </tool_run>

    It is sunny in Barcelona.
    """

  func testVisibleTextLeavesToolResultsOut() {
    XCTAssertEqual(
      MessageContentFilter.render(message).visibleText,
      "Here is the forecast.\n\nIt is sunny in Barcelona.")
  }

  func testEditingVisibleTextKeepsToolRunBlock() {
    let edited = MessageContentFilter.replacingVisibleText(
      in: message,
      with: "It is sunny in Barcelona, 22 degrees.")

    XCTAssertTrue(edited.contains("<tool_run>"))
    XCTAssertTrue(edited.contains("22C and sunny"))
    XCTAssertEqual(
      MessageContentFilter.render(edited).visibleText,
      "It is sunny in Barcelona, 22 degrees.")
  }

  func testEditingVisibleTextKeepsReasoningBlock() {
    let text = "<think>\nthinking out loud\n</think>\n\nShort answer."
    let edited = MessageContentFilter.replacingVisibleText(in: text, with: "Longer answer.")

    XCTAssertTrue(edited.contains("thinking out loud"))
    XCTAssertEqual(MessageContentFilter.render(edited).visibleText, "Longer answer.")
  }

  func testEditingMessageWithoutHiddenSectionsReplacesEverything() {
    XCTAssertEqual(
      MessageContentFilter.replacingVisibleText(in: "plain answer", with: "edited answer"),
      "edited answer")
  }

  func testToolEntryCarriesItsRawBlock() {
    let section = """

      Weather tool ({"city":"Barcelona"}):
      22C and sunny

      """
    guard let entry = ToolCallParser.parse(section).first else {
      return XCTFail("expected one parsed tool entry")
    }

    XCTAssertEqual(entry.name, "Weather")
    XCTAssertEqual(entry.params, #"{"city":"Barcelona"}"#)
    XCTAssertEqual(entry.body, "22C and sunny")
    // The raw block is a verbatim slice of the message, so an edited block can be
    // written back in place.
    XCTAssertEqual(entry.rawBlock, "Weather tool ({\"city\":\"Barcelona\"}):\n22C and sunny")
    XCTAssertTrue(message.contains(entry.rawBlock))
  }

  func testToolEntryCopyTextWithoutInput() {
    guard let entry = ToolCallParser.parse("Clipboard tool:\ncopied\n").first else {
      return XCTFail("expected one parsed tool entry")
    }

    XCTAssertEqual(entry.params, "")
    XCTAssertEqual(entry.copyText, "Clipboard tool:\ncopied")
  }
}
