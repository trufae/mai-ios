import Foundation
import XCTest

@testable import PocketMai

final class ConversationFolderTintTests: XCTestCase {
  private let epoch = Date(timeIntervalSinceReferenceDate: 0)

  func testHexNormalizationAcceptsShortAndLongForms() {
    XCTAssertEqual(ConversationFolderTint.normalizedHex("#abc"), "#AABBCC")
    XCTAssertEqual(ConversationFolderTint.normalizedHex("ff7700"), "#FF7700")
    XCTAssertNil(ConversationFolderTint.normalizedHex("#12345"))
    XCTAssertNil(ConversationFolderTint.normalizedHex("nothex"))
  }

  func testFolderTintsSurviveEncoding() throws {
    let folders = [
      ConversationFolder(
        id: "work", name: "Work", icon: "briefcase", tint: .preset(.orange), createdAt: epoch),
      ConversationFolder(
        id: "fun", name: "Fun", icon: "gamecontroller", tint: .custom("#1A2B3C"),
        createdAt: epoch),
      ConversationFolder(id: "plain", name: "Plain", createdAt: epoch),
    ]

    let data = try JSONEncoder().encode(folders)
    let decoded = try JSONDecoder().decode([ConversationFolder].self, from: data)

    XCTAssertEqual(decoded, folders)
    XCTAssertEqual(decoded[0].tint, .preset(.orange))
    XCTAssertEqual(decoded[1].tint?.customHex, "#1A2B3C")
    XCTAssertNil(decoded[2].tint)
  }

  func testFoldersSurviveMissingAndUnusableTints() throws {
    let json = """
      [
        {"id":"a","name":"Legacy folder","createdAt":0},
        {"id":"b","name":"Unknown tint","tint":"chartreuse","createdAt":0},
        {"id":"c","name":"System is not an override","tint":"system","createdAt":0}
      ]
      """

    let decoded = try JSONDecoder().decode([ConversationFolder].self, from: Data(json.utf8))

    XCTAssertEqual(
      decoded.map(\.name),
      ["Legacy folder", "Unknown tint", "System is not an override"])
    XCTAssertTrue(decoded.allSatisfy { $0.tint == nil })
  }

  func testSettingsNormalizationKeepsFolderTint() {
    let normalized = AppSettings.normalizedConversationFolders([
      ConversationFolder(
        id: "work", name: "Work", icon: "briefcase", tint: .preset(.mint), createdAt: epoch)
    ])

    XCTAssertEqual(normalized.count, 1)
    XCTAssertEqual(normalized.first?.tint, .preset(.mint))
  }
}
