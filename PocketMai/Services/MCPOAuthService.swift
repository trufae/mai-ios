import AuthenticationServices
import CryptoKit
import Foundation

struct MCPOAuthResult: Sendable {
  var accessToken: String
  var refreshToken: String?
  var expiresAt: Date?
  var clientID: String
}

enum MCPOAuthError: LocalizedError {
  case discoveryFailed([String])
  case invalidMetadata(String)
  case unsafeDiscoveredURL(String)
  case pkceUnsupported(String)
  case registrationUnsupported
  case registrationFailed(url: String, detail: String)
  case authorizationFailed(String)
  case missingAuthorizationCode
  case stateMismatch
  case tokenRequestFailed(url: String, detail: String)
  case missingAccessToken
  case missingRefreshToken
  case userCancelled
  case presentationAnchorUnavailable

  var errorDescription: String? {
    switch self {
    case .discoveryFailed(let urls):
      "OAuth discovery failed. Tried: \(urls.joined(separator: ", "))"
    case .invalidMetadata(let detail):
      "Invalid MCP OAuth metadata: \(detail)"
    case .unsafeDiscoveredURL(let url):
      "OAuth sign-in stopped before opening the browser. The MCP server advertised an unsafe URL: \(url)"
    case .pkceUnsupported(let url):
      "The OAuth server at \(url) does not advertise PKCE S256 support."
    case .registrationUnsupported:
      "The OAuth server did not provide a client registration URL, so automatic sign-in cannot continue."
    case .registrationFailed(let url, let detail):
      "OAuth client registration failed at \(url): \(detail)"
    case .authorizationFailed(let detail):
      "OAuth authorization failed: \(detail)"
    case .missingAuthorizationCode:
      "The OAuth server did not return an authorization code."
    case .stateMismatch:
      "OAuth state mismatch. The sign-in could not be verified."
    case .tokenRequestFailed(let url, let detail):
      "OAuth token request failed at \(url): \(detail)"
    case .missingAccessToken:
      "The OAuth token response did not contain an access token."
    case .missingRefreshToken:
      "No OAuth refresh token is available. Sign in again."
    case .userCancelled:
      "OAuth sign-in was cancelled."
    case .presentationAnchorUnavailable:
      "No app window is available to present OAuth sign-in."
    }
  }

  var shortDescription: String {
    switch self {
    case .discoveryFailed, .invalidMetadata, .unsafeDiscoveredURL, .pkceUnsupported:
      "OAuth discovery failed."
    case .registrationUnsupported, .registrationFailed:
      "OAuth client registration failed."
    case .authorizationFailed, .missingAuthorizationCode, .stateMismatch,
      .presentationAnchorUnavailable:
      "OAuth authorization failed."
    case .tokenRequestFailed, .missingAccessToken, .missingRefreshToken:
      "OAuth token request failed."
    case .userCancelled:
      "OAuth sign-in was cancelled."
    }
  }
}

@MainActor
enum MCPOAuthService {
  private static let redirectURI = "pocketmai://oauth/mcp"

  static func signIn(server: MCPServer) async throws -> MCPOAuthResult {
    let configuration = try await discover(server: server)
    let clientID = try await resolveClientID(
      authentication: server.authentication,
      configuration: configuration)
    let verifier = randomURLSafeString(byteCount: 48)
    let state = randomURLSafeString(byteCount: 24)
    let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    let authorizationURL = try makeAuthorizationURL(
      configuration: configuration,
      clientID: clientID,
      challenge: challenge,
      state: state)
    let callback = try await presentAuthorization(url: authorizationURL)
    let parameters = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
    if let error = parameters.first(where: { $0.name == "error" })?.value {
      let description = parameters.first(where: { $0.name == "error_description" })?.value
      throw MCPOAuthError.authorizationFailed(
        description.map { "\(error): \($0)" } ?? error)
    }
    guard parameters.first(where: { $0.name == "state" })?.value == state else {
      throw MCPOAuthError.stateMismatch
    }
    guard let code = parameters.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
      throw MCPOAuthError.missingAuthorizationCode
    }
    return try await requestToken(
      at: configuration.tokenEndpoint,
      parameters: [
        "grant_type": "authorization_code",
        "client_id": clientID,
        "code": code,
        "code_verifier": verifier,
        "redirect_uri": redirectURI,
        "resource": configuration.resource,
      ],
      clientID: clientID,
      existingRefreshToken: nil)
  }

  static func refresh(server: MCPServer) async throws -> MCPOAuthResult {
    let refreshToken = server.authentication.oauthRefreshToken
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !refreshToken.isEmpty else { throw MCPOAuthError.missingRefreshToken }
    let clientID = server.authentication.oauthClientID
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clientID.isEmpty else { throw MCPOAuthError.registrationUnsupported }
    let configuration = try await discover(server: server)
    return try await requestToken(
      at: configuration.tokenEndpoint,
      parameters: [
        "grant_type": "refresh_token",
        "client_id": clientID,
        "refresh_token": refreshToken,
        "resource": configuration.resource,
      ],
      clientID: clientID,
      existingRefreshToken: refreshToken)
  }

  // MARK: - Discovery

  private static func discover(server: MCPServer) async throws -> Configuration {
    guard let endpoint = URL(string: server.baseURL), isSecureOAuthURL(endpoint) else {
      throw MCPOAuthError.invalidMetadata(
        "OAuth requires HTTPS, except for local development endpoints.")
    }
    let challenge = try await authorizationChallenge(endpoint: endpoint)
    let protectedResource = try await protectedResourceMetadata(
      endpoint: endpoint,
      advertisedURL: challenge.resourceMetadataURL)
    let issuerText = protectedResource.authorizationServers?.first
    guard let issuerText, let issuer = URL(string: issuerText) else {
      throw MCPOAuthError.invalidMetadata("authorization_servers is missing.")
    }
    let metadata = try await authorizationServerMetadata(issuer: issuer, endpoint: endpoint)
    guard metadata.codeChallengeMethodsSupported?.contains("S256") == true else {
      throw MCPOAuthError.pkceUnsupported(issuer.absoluteString)
    }
    let authorizationEndpoint = try trustedDiscoveredURL(
      discovered: metadata.authorizationEndpoint,
      field: "authorization_endpoint",
      endpoint: endpoint)
    let tokenEndpoint = try trustedDiscoveredURL(
      discovered: metadata.tokenEndpoint,
      field: "token_endpoint",
      endpoint: endpoint)
    let registrationEndpoint = try optionalTrustedDiscoveredURL(
      discovered: metadata.registrationEndpoint,
      endpoint: endpoint)
    let resource = try resourceIdentifier(
      discovered: protectedResource.resource,
      endpoint: endpoint)
    let scope =
      challenge.scope
      ?? protectedResource.scopesSupported?.joined(separator: " ")
      ?? metadata.scopesSupported?.joined(separator: " ")
      ?? ""
    return Configuration(
      authorizationEndpoint: authorizationEndpoint,
      tokenEndpoint: tokenEndpoint,
      registrationEndpoint: registrationEndpoint,
      resource: resource,
      scope: scope)
  }

  private static func authorizationChallenge(endpoint: URL) async throws -> Challenge {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.httpBody = Data(
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"PocketMai\",\"version\":\"1\"}}}"
        .utf8)
    let (_, response) = try await URLSession.shared.data(for: request)
    let header =
      (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "WWW-Authenticate")
      ?? ""
    return Challenge(
      resourceMetadataURL: quotedParameter("resource_metadata", in: header).flatMap(URL.init),
      scope: quotedParameter("scope", in: header)?.trimmed.nilIfEmpty)
  }

  private static func protectedResourceMetadata(
    endpoint: URL,
    advertisedURL: URL?
  ) async throws -> ProtectedResourceMetadata {
    var candidates: [URL] = []
    if let advertisedURL {
      guard isTrustedOAuthURL(advertisedURL, relativeTo: endpoint) else {
        throw MCPOAuthError.unsafeDiscoveredURL(advertisedURL.absoluteString)
      }
      candidates.append(advertisedURL)
    }
    var pathSpecific = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
    let endpointPath = endpoint.path == "/" ? "" : endpoint.path
    pathSpecific?.path = "/.well-known/oauth-protected-resource" + endpointPath
    pathSpecific?.query = nil
    if let url = pathSpecific?.url { candidates.append(url) }
    var root = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
    root?.path = "/.well-known/oauth-protected-resource"
    root?.query = nil
    if let url = root?.url { candidates.append(url) }
    for candidate in unique(candidates) {
      if let metadata: ProtectedResourceMetadata = try await fetchJSON(candidate) {
        return metadata
      }
    }
    throw MCPOAuthError.discoveryFailed(unique(candidates).map(\.absoluteString))
  }

  private static func authorizationServerMetadata(
    issuer: URL,
    endpoint: URL
  ) async throws -> AuthorizationServerMetadata {
    guard isTrustedOAuthURL(issuer, relativeTo: endpoint) else {
      throw MCPOAuthError.unsafeDiscoveredURL(issuer.absoluteString)
    }
    let candidates = authorizationMetadataURLs(for: issuer)
    for candidate in candidates {
      if let metadata: AuthorizationServerMetadata = try await fetchJSON(candidate) {
        return metadata
      }
    }
    throw MCPOAuthError.discoveryFailed(candidates.map(\.absoluteString))
  }

  private static func authorizationMetadataURLs(for issuer: URL) -> [URL] {
    let path = issuer.path == "/" ? "" : issuer.path
    var urls: [URL] = []
    for wellKnown in ["oauth-authorization-server", "openid-configuration"] {
      var components = URLComponents(url: issuer, resolvingAgainstBaseURL: false)
      components?.path = "/.well-known/\(wellKnown)" + path
      components?.query = nil
      if let url = components?.url { urls.append(url) }
    }
    if !path.isEmpty {
      var appended = URLComponents(url: issuer, resolvingAgainstBaseURL: false)
      appended?.path =
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        .withLeadingSlash + "/.well-known/openid-configuration"
      appended?.query = nil
      if let url = appended?.url { urls.append(url) }
    }
    return unique(urls)
  }

  // MARK: - Registration and tokens

  private static func resolveClientID(
    authentication: MCPAuthentication,
    configuration: Configuration
  ) async throws -> String {
    if let clientID = authentication.oauthClientID.trimmed.nilIfEmpty { return clientID }
    guard let registrationEndpoint = configuration.registrationEndpoint else {
      throw MCPOAuthError.registrationUnsupported
    }
    var request = URLRequest(url: registrationEndpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONEncoder().encode(
      RegistrationRequest(
        clientName: "PocketMai",
        redirectURIs: [redirectURI],
        grantTypes: ["authorization_code", "refresh_token"],
        responseTypes: ["code"],
        tokenEndpointAuthMethod: "none"))
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      throw MCPOAuthError.registrationFailed(
        url: registrationEndpoint.absoluteString,
        detail: error.localizedDescription)
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status),
      let registration = try? JSONDecoder().decode(RegistrationResponse.self, from: data),
      let clientID = registration.clientID?.trimmed.nilIfEmpty
    else {
      throw MCPOAuthError.registrationFailed(
        url: registrationEndpoint.absoluteString,
        detail: responseDetail(data: data, status: status))
    }
    return clientID
  }

  private static func requestToken(
    at endpoint: URL,
    parameters: [String: String],
    clientID: String,
    existingRefreshToken: String?
  ) async throws -> MCPOAuthResult {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = formEncode(parameters).data(using: .utf8)
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      throw MCPOAuthError.tokenRequestFailed(
        url: endpoint.absoluteString,
        detail: error.localizedDescription)
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      throw MCPOAuthError.tokenRequestFailed(
        url: endpoint.absoluteString,
        detail: responseDetail(data: data, status: status))
    }
    guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data),
      let accessToken = token.accessToken?.trimmed.nilIfEmpty
    else {
      throw MCPOAuthError.missingAccessToken
    }
    return MCPOAuthResult(
      accessToken: accessToken,
      refreshToken: token.refreshToken?.trimmed.nilIfEmpty ?? existingRefreshToken,
      expiresAt: token.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
      clientID: clientID)
  }

  // MARK: - Authorization browser

  private static func makeAuthorizationURL(
    configuration: Configuration,
    clientID: String,
    challenge: String,
    state: String
  ) throws -> URL {
    guard
      var components = URLComponents(
        url: configuration.authorizationEndpoint,
        resolvingAgainstBaseURL: false)
    else {
      throw MCPOAuthError.invalidMetadata("Invalid authorization_endpoint.")
    }
    var query = components.queryItems ?? []
    query.append(contentsOf: [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "redirect_uri", value: redirectURI),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "resource", value: configuration.resource),
    ])
    if !configuration.scope.isEmpty {
      query.append(URLQueryItem(name: "scope", value: configuration.scope))
    }
    components.queryItems = query
    guard let url = components.url else {
      throw MCPOAuthError.invalidMetadata("Invalid authorization URL.")
    }
    return url
  }

  private static func presentAuthorization(url: URL) async throws -> URL {
    guard let windowScene = AuthPresenter.preferredWindowScene() else {
      throw MCPOAuthError.presentationAnchorUnavailable
    }
    let presenter = AuthPresenter(windowScene: windowScene)
    return try await withCheckedThrowingContinuation { continuation in
      let session = ASWebAuthenticationSession(
        url: url,
        callbackURLScheme: "pocketmai"
      ) { [presenter] callback, error in
        _ = presenter
        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
          continuation.resume(throwing: MCPOAuthError.userCancelled)
        } else if let error {
          continuation.resume(
            throwing: MCPOAuthError.authorizationFailed(
              "\(error.localizedDescription) URL: \(url.absoluteString)"))
        } else if let callback {
          continuation.resume(returning: callback)
        } else {
          continuation.resume(throwing: MCPOAuthError.missingAuthorizationCode)
        }
      }
      session.presentationContextProvider = presenter
      session.prefersEphemeralWebBrowserSession = false
      if !session.start() {
        continuation.resume(throwing: MCPOAuthError.authorizationFailed("Could not open sign-in."))
      }
    }
  }

  // MARK: - Validation and encoding

  private static func trustedDiscoveredURL(
    discovered: String?,
    field: String,
    endpoint: URL
  ) throws -> URL {
    guard let value = discovered,
      let url = URL(string: value)
    else {
      throw MCPOAuthError.invalidMetadata("\(field) is missing.")
    }
    guard isTrustedOAuthURL(url, relativeTo: endpoint) else {
      throw MCPOAuthError.unsafeDiscoveredURL(url.absoluteString)
    }
    return url
  }

  private static func optionalTrustedDiscoveredURL(
    discovered: String?,
    endpoint: URL
  ) throws -> URL? {
    guard let value = discovered,
      let url = URL(string: value)
    else {
      return nil
    }
    guard isTrustedOAuthURL(url, relativeTo: endpoint) else {
      throw MCPOAuthError.unsafeDiscoveredURL(url.absoluteString)
    }
    return url
  }

  private static func resourceIdentifier(
    discovered: String?,
    endpoint: URL
  ) throws -> String {
    let value = discovered ?? endpoint.absoluteString
    guard let url = URL(string: value), isTrustedOAuthURL(url, relativeTo: endpoint) else {
      throw MCPOAuthError.unsafeDiscoveredURL(value)
    }
    return url.absoluteString
  }

  private static func isTrustedOAuthURL(_ url: URL, relativeTo endpoint: URL) -> Bool {
    guard isSecureOAuthURL(url), url.user == nil, url.password == nil,
      let host = url.host?.lowercased()
    else {
      return false
    }
    let endpointHost = endpoint.host?.lowercased()
    if isLocalHost(host), !isLocalHost(endpointHost ?? "") { return false }
    return true
  }

  private static func isSecureOAuthURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
      return false
    }
    return scheme == "https" || (scheme == "http" && isLocalHost(host))
  }

  private static func isLocalHost(_ host: String) -> Bool {
    if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" { return true }
    let parts = host.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 4 else {
      return host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:")
    }
    return parts[0] == 127 || parts[0] == 10 || (parts[0] == 192 && parts[1] == 168)
      || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 169 && parts[1] == 254)
  }

  private static func fetchJSON<T: Decodable>(_ url: URL) async throws -> T? {
    var request = URLRequest(url: url)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      return nil
    }
    return try? JSONDecoder().decode(T.self, from: data)
  }

  private static func quotedParameter(_ name: String, in header: String) -> String? {
    let lower = header.lowercased()
    guard let nameRange = lower.range(of: name.lowercased()),
      let equals = lower[nameRange.upperBound...].firstIndex(of: "=")
    else {
      return nil
    }
    let start = lower.index(after: equals)
    if start < lower.endIndex, lower[start] == "\"" {
      let valueStart = lower.index(after: start)
      guard let end = lower[valueStart...].firstIndex(of: "\"") else { return nil }
      return String(header[valueStart..<end])
    }
    let end = lower[start...].firstIndex(where: { $0 == "," || $0 == " " }) ?? lower.endIndex
    return String(header[start..<end])
  }

  private static func formEncode(_ parameters: [String: String]) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return parameters.sorted(by: { $0.key < $1.key }).map { key, value in
      let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
      let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
      return "\(encodedKey)=\(encodedValue)"
    }.joined(separator: "&")
  }

  private static func responseDetail(data: Data, status: Int) -> String {
    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      let description =
        object["error_description"] as? String
        ?? object["detail"] as? String
        ?? object["error"] as? String
      if let description, !description.isEmpty { return "HTTP \(status): \(description)" }
    }
    let body = String(data: data.prefix(400), encoding: .utf8)?.trimmed ?? ""
    return body.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(body)"
  }

  private static func randomURLSafeString(byteCount: Int) -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return Data(bytes).base64URLEncodedString()
  }

  private static func unique(_ urls: [URL]) -> [URL] {
    var seen = Set<String>()
    return urls.filter { seen.insert($0.absoluteString).inserted }
  }
}

private struct Configuration: Sendable {
  var authorizationEndpoint: URL
  var tokenEndpoint: URL
  var registrationEndpoint: URL?
  var resource: String
  var scope: String
}

private struct Challenge: Sendable {
  var resourceMetadataURL: URL?
  var scope: String?
}

private struct ProtectedResourceMetadata: Decodable {
  var authorizationServers: [String]?
  var resource: String?
  var scopesSupported: [String]?

  enum CodingKeys: String, CodingKey {
    case authorizationServers = "authorization_servers"
    case resource
    case scopesSupported = "scopes_supported"
  }
}

private struct AuthorizationServerMetadata: Decodable {
  var authorizationEndpoint: String?
  var tokenEndpoint: String?
  var registrationEndpoint: String?
  var scopesSupported: [String]?
  var codeChallengeMethodsSupported: [String]?

  enum CodingKeys: String, CodingKey {
    case authorizationEndpoint = "authorization_endpoint"
    case tokenEndpoint = "token_endpoint"
    case registrationEndpoint = "registration_endpoint"
    case scopesSupported = "scopes_supported"
    case codeChallengeMethodsSupported = "code_challenge_methods_supported"
  }
}

private struct RegistrationRequest: Encodable {
  var clientName: String
  var redirectURIs: [String]
  var grantTypes: [String]
  var responseTypes: [String]
  var tokenEndpointAuthMethod: String

  enum CodingKeys: String, CodingKey {
    case clientName = "client_name"
    case redirectURIs = "redirect_uris"
    case grantTypes = "grant_types"
    case responseTypes = "response_types"
    case tokenEndpointAuthMethod = "token_endpoint_auth_method"
  }
}

private struct RegistrationResponse: Decodable {
  var clientID: String?

  enum CodingKeys: String, CodingKey {
    case clientID = "client_id"
  }
}

private struct TokenResponse: Decodable {
  var accessToken: String?
  var refreshToken: String?
  var expiresIn: Int?

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
    case expiresIn = "expires_in"
  }
}

extension Data {
  fileprivate func base64URLEncodedString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

extension String {
  fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
  fileprivate var withLeadingSlash: String { hasPrefix("/") ? self : "/" + self }
}
