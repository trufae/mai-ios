import Foundation
import Testing

@testable import MaiCore

private let transcript: [AgentMessage] = [
  .system("Be terse."),
  .user("What is 2 + 2?"),
  AgentMessage(
    role: .assistant,
    content: [
      .reasoning("Simple arithmetic."),
      .text("<think>adding</think>\n\nIt is 4."),
    ]),
  .user("Now call a tool."),
  AgentMessage(
    role: .assistant,
    content: [
      .toolCall(ToolCall(id: "call-1", name: "echo", arguments: .object(["text": .string("hi")])))
    ]),
  AgentMessage(
    role: .tool,
    content: [.toolResult(ToolResult(callID: "call-1", text: "hi"))]),
  .assistant("The tool said hi."),
]

@Test("An empty /copy argument selects the last assistant reply")
func copyArgumentParsing() throws {
  #expect(try TranscriptCopy.selection(parsing: "") == .lastAssistantReply)
  #expect(try TranscriptCopy.selection(parsing: "  3 ") == .lastMessages(3))
  #expect(throws: TranscriptCopyError.invalidCount("0")) {
    try TranscriptCopy.selection(parsing: "0")
  }
  #expect(throws: TranscriptCopyError.invalidCount("many")) {
    try TranscriptCopy.selection(parsing: "many")
  }
}

@Test("The last assistant reply is copied as pasteable text without reasoning")
func copyLastAssistantReply() throws {
  let result = try TranscriptCopy.text(for: .lastAssistantReply, in: transcript)
  #expect(result.text == "The tool said hi.")
  #expect(result.messages.count == 1)

  let early = try TranscriptCopy.text(for: .lastAssistantReply, in: Array(transcript.prefix(3)))
  #expect(early.text == "It is 4.")

  #expect(throws: TranscriptCopyError.noAssistantReply) {
    try TranscriptCopy.text(for: .lastAssistantReply, in: Array(transcript.prefix(2)))
  }
}

@Test("Copying several messages labels roles and summarizes tool traffic")
func copyLastMessages() throws {
  let result = try TranscriptCopy.text(for: .lastMessages(4), in: transcript)
  #expect(result.messages.count == 4)
  #expect(
    result.text == """
      User: Now call a tool.

      Assistant: [tool call echo {"text":"hi"}]

      Tool: [tool result] hi

      Assistant: The tool said hi.
      """)
}

@Test("Copying one message omits the role label and never includes instructions")
func copySingleMessageAndBounds() throws {
  let single = try TranscriptCopy.text(for: .lastMessages(1), in: transcript)
  #expect(single.text == "The tool said hi.")

  let everything = try TranscriptCopy.text(for: .lastMessages(100), in: transcript)
  #expect(everything.messages.count == 6)
  #expect(!everything.text.contains("Be terse."))
  #expect(everything.text.hasPrefix("User: What is 2 + 2?"))

  #expect(throws: TranscriptCopyError.noMessages) {
    try TranscriptCopy.text(for: .lastMessages(2), in: [.system("Be terse.")])
  }
}
