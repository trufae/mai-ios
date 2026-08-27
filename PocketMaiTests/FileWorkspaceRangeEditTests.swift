import XCTest

@testable import PocketMai

final class FileWorkspaceRangeEditTests: XCTestCase {
  func testReplaceMiddleLines() throws {
    let edit = try FileWorkspaceService.replacingLineRange(
      in: "one\ntwo\nthree\nfour\n",
      startLine: 2,
      endLine: 3,
      replacement: "TWO\n2.5")
    XCTAssertEqual(edit.text, "one\nTWO\n2.5\nfour\n")
    XCTAssertEqual(edit.removedLineCount, 2)
    XCTAssertEqual(edit.insertedLineCount, 2)
    XCTAssertEqual(edit.totalLineCount, 4)
  }

  func testTrailingNewlineInReplacementDoesNotAddEmptyLine() throws {
    let edit = try FileWorkspaceService.replacingLineRange(
      in: "one\ntwo\n",
      startLine: 1,
      endLine: 1,
      replacement: "ONE\n")
    XCTAssertEqual(edit.text, "ONE\ntwo\n")
    XCTAssertEqual(edit.insertedLineCount, 1)
  }

  func testInsertWithoutRemoving() throws {
    let edit = try FileWorkspaceService.replacingLineRange(
      in: "one\ntwo\n",
      startLine: 2,
      endLine: 1,
      replacement: "between")
    XCTAssertEqual(edit.text, "one\nbetween\ntwo\n")
    XCTAssertEqual(edit.removedLineCount, 0)
    XCTAssertEqual(edit.insertedLineCount, 1)
    XCTAssertEqual(edit.totalLineCount, 3)
  }

  func testAppendAtEnd() throws {
    let edit = try FileWorkspaceService.replacingLineRange(
      in: "one\ntwo\n",
      startLine: 3,
      endLine: 2,
      replacement: "three")
    XCTAssertEqual(edit.text, "one\ntwo\nthree\n")
  }

  func testDeleteRange() throws {
    let edit = try FileWorkspaceService.replacingLineRange(
      in: "one\ntwo\nthree",
      startLine: 1,
      endLine: 2,
      replacement: "")
    XCTAssertEqual(edit.text, "three")
    XCTAssertEqual(edit.removedLineCount, 2)
    XCTAssertEqual(edit.insertedLineCount, 0)
    XCTAssertEqual(edit.totalLineCount, 1)
  }

  func testPreservesMissingTrailingNewline() throws {
    let edit = try FileWorkspaceService.replacingLineRange(
      in: "one\ntwo",
      startLine: 2,
      endLine: 2,
      replacement: "TWO")
    XCTAssertEqual(edit.text, "one\nTWO")
  }

  func testDeleteAllLines() throws {
    let edit = try FileWorkspaceService.replacingLineRange(
      in: "one\n",
      startLine: 1,
      endLine: 1,
      replacement: "")
    XCTAssertEqual(edit.text, "")
    XCTAssertEqual(edit.totalLineCount, 0)
  }

  func testInsertIntoEmptyFile() throws {
    let edit = try FileWorkspaceService.replacingLineRange(
      in: "",
      startLine: 1,
      endLine: 0,
      replacement: "hello\n")
    XCTAssertEqual(edit.text, "hello")
    XCTAssertEqual(edit.totalLineCount, 1)
  }

  func testOutOfRangeThrows() {
    XCTAssertThrowsError(
      try FileWorkspaceService.replacingLineRange(
        in: "one\n", startLine: 3, endLine: 3, replacement: "x"))
    XCTAssertThrowsError(
      try FileWorkspaceService.replacingLineRange(
        in: "one\n", startLine: 0, endLine: 1, replacement: "x"))
    XCTAssertThrowsError(
      try FileWorkspaceService.replacingLineRange(
        in: "one\ntwo\n", startLine: 1, endLine: 3, replacement: "x"))
    XCTAssertThrowsError(
      try FileWorkspaceService.replacingLineRange(
        in: "one\ntwo\n", startLine: 2, endLine: 0, replacement: "x"))
  }
}
