import XCTest

@testable import PocketMai

final class MCPAuthenticationTests: XCTestCase {
  func testLegacyServerDefaultsToNoAuthentication() throws {
    let data = Data(
      #"{"id":"C478FC6D-F6A9-48AD-8EED-5F7B45371BC2","name":"Legacy","baseURL":"https://example.com/mcp","isEnabled":true}"#
        .utf8)

    let server = try JSONDecoder().decode(MCPServer.self, from: data)

    XCTAssertEqual(server.authentication.method, .none)
    XCTAssertNil(server.authentication.accessToken)
  }

  func testBearerTokenIsTrimmed() {
    var authentication = MCPAuthentication()
    authentication.method = .bearer
    authentication.bearerToken = "  secret-token\n"

    XCTAssertEqual(authentication.accessToken, "secret-token")
  }

  func testOAuthAuthenticationRoundTrips() throws {
    var authentication = MCPAuthentication()
    authentication.method = .oauth
    authentication.oauthAccessToken = "access"
    authentication.oauthRefreshToken = "refresh"
    authentication.oauthClientID = "client"
    let server = MCPServer(
      name: "OAuth",
      baseURL: "https://example.com/mcp",
      authentication: authentication)

    let decoded = try JSONDecoder().decode(
      MCPServer.self,
      from: JSONEncoder().encode(server))

    XCTAssertEqual(decoded, server)
    XCTAssertEqual(decoded.authentication.accessToken, "access")
  }

  func testOAuthRegistrationErrorKeepsURLOutOfShortSummary() {
    let url = "https://auth.example.com/register"
    let error = MCPOAuthError.registrationFailed(
      url: url,
      detail: "HTTP 502: a very long proxy response")

    XCTAssertEqual(error.shortDescription, "OAuth client registration failed.")
    XCTAssertTrue(error.localizedDescription.contains(url))
    XCTAssertTrue(error.localizedDescription.contains("HTTP 502"))
  }
}
