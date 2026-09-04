import Foundation
import XCTest

@testable import PocketMai

@MainActor
final class BrowserToolTests: XCTestCase {
  func testURLNormalizationAssumesHTTPSAndRejectsOtherSchemes() {
    XCTAssertEqual(
      BrowserSession.url(from: "example.com/path")?.absoluteString, "https://example.com/path")
    XCTAssertEqual(
      BrowserSession.url(from: "  http://example.com ")?.absoluteString, "http://example.com")
    XCTAssertNil(BrowserSession.url(from: ""))
    XCTAssertNil(BrowserSession.url(from: "javascript:alert(1)"))
    XCTAssertNil(BrowserSession.url(from: "file:///etc/passwd"))
    XCTAssertNil(BrowserSession.url(from: "pocketmai://prompt"))
  }

  func testBrowserToolsAreRegisteredWithUniqueNames() {
    let names = BrowserTool.definitions.map(\.name)
    XCTAssertEqual(names, BrowserTool.toolNames)
    XCTAssertEqual(Set(names).count, names.count)
    XCTAssertTrue(names.allSatisfy(BuiltInToolCatalog.isBuiltInToolName))
    XCTAssertEqual(BuiltInToolCatalog.approvalKind(forToolName: BrowserTool.actName), .confirm)
  }

  func testOpenConversationDeepLinkRoundTrips() {
    let id = UUID()
    let url = PocketMaiDeepLink.url(for: .openConversation(id: id))
    XCTAssertEqual(url.host, PocketMaiDeepLink.conversationHost)
    XCTAssertEqual(PocketMaiDeepLink.command(from: url), .openConversation(id: id))
    XCTAssertNil(
      PocketMaiDeepLink.command(from: URL(string: "pocketmai://conversation/not-a-uuid")!))
  }
}
