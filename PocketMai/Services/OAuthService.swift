import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

enum OAuthError: LocalizedError {
  case invalidConfiguration(String)
  case invalidAuthorizationURL
  case invalidRedirectURL(String)
  case userCancelled
  case missingAuthorizationCode
  case stateMismatch
  case authorizationServerError(String)
  case tokenExchangeFailed(String)
  case missingAccessToken
  case noRefreshToken
  case presentationAnchorUnavailable

  var errorDescription: String? {
    switch self {
    case .invalidConfiguration(let reason):
      return "OAuth configuration is incomplete: \(reason)"
    case .invalidAuthorizationURL:
      return "Could not build the OAuth authorization URL."
    case .invalidRedirectURL(let value):
      return "Invalid redirect URI: \(value)"
    case .userCancelled:
      return "Sign-in was cancelled."
    case .missingAuthorizationCode:
      return "The authorization server did not return a code."
    case .stateMismatch:
      return "OAuth state mismatch. The sign-in could not be verified."
    case .authorizationServerError(let message):
      return "Authorization server error: \(message)"
    case .tokenExchangeFailed(let message):
      return "Token exchange failed: \(message)"
    case .missingAccessToken:
      return "The token response did not include an access_token."
    case .noRefreshToken:
      return "No refresh token is available. Please sign in again."
    case .presentationAnchorUnavailable:
      return "No app window is available to present sign-in."
    }
  }
}

struct OAuthTokens: Sendable {
  let accessToken: String
  let refreshToken: String?
  let expiresAt: Date?
}

@MainActor
enum OAuthService {
  /// Run the full PKCE authorization-code flow for the given endpoint configuration.
  /// Returns the freshly issued tokens on success.
  static func signIn(endpoint: OpenAIEndpoint) async throws -> OAuthTokens {
    let config = try validatedConfiguration(for: endpoint)

    let verifier = generateCodeVerifier()
    let challenge = codeChallenge(for: verifier)
    let state = generateState()

    let authorizationURL = try buildAuthorizationURL(
      config: config,
      codeChallenge: challenge,
      state: state)

    let callbackURL = try await presentAuthSession(
      url: authorizationURL,
      callbackScheme: config.callbackScheme)

    let (code, returnedState, errorMessage) = parseCallback(callbackURL)

    if let errorMessage {
      throw OAuthError.authorizationServerError(errorMessage)
    }
    guard let code, !code.isEmpty else {
      throw OAuthError.missingAuthorizationCode
    }
    guard returnedState == state else {
      throw OAuthError.stateMismatch
    }

    return try await exchangeCode(
      code: code,
      verifier: verifier,
      config: config)
  }

  /// Use the stored refresh token to obtain a new access token.
  static func refresh(endpoint: OpenAIEndpoint) async throws -> OAuthTokens {
    let config = try validatedConfiguration(for: endpoint)
    let refreshToken = endpoint.oauthRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !refreshToken.isEmpty else {
      throw OAuthError.noRefreshToken
    }
    return try await performTokenRequest(
      parameters: [
        "grant_type": "refresh_token",
        "client_id": config.clientID,
        "refresh_token": refreshToken,
      ],
      config: config,
      existingRefreshToken: refreshToken)
  }

  // MARK: - Authorization request

  private static func buildAuthorizationURL(
    config: OAuthConfiguration,
    codeChallenge: String,
    state: String
  ) throws -> URL {
    guard var components = URLComponents(url: config.authorizeURL, resolvingAgainstBaseURL: false)
    else {
      throw OAuthError.invalidAuthorizationURL
    }

    var items: [URLQueryItem] = components.queryItems ?? []
    items.append(contentsOf: [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: config.clientID),
      URLQueryItem(name: "redirect_uri", value: config.redirectURI),
      URLQueryItem(name: "scope", value: config.scope),
      URLQueryItem(name: "code_challenge", value: codeChallenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "state", value: state),
    ])
    if !config.audience.isEmpty {
      items.append(URLQueryItem(name: "audience", value: config.audience))
    }
    components.queryItems = items

    guard let url = components.url else {
      throw OAuthError.invalidAuthorizationURL
    }
    return url
  }

  private static func presentAuthSession(
    url: URL,
    callbackScheme: String
  ) async throws -> URL {
    guard let windowScene = AuthPresenter.preferredWindowScene() else {
      throw OAuthError.presentationAnchorUnavailable
    }
    let presenter = AuthPresenter(windowScene: windowScene)
    return try await withCheckedThrowingContinuation { continuation in
      let session = ASWebAuthenticationSession(
        url: url,
        callbackURLScheme: callbackScheme
      ) { [presenter] callback, error in
        // Retain presenter for the lifetime of the session.
        _ = presenter
        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
          continuation.resume(throwing: OAuthError.userCancelled)
          return
        }
        if let error {
          continuation.resume(throwing: error)
          return
        }
        guard let callback else {
          continuation.resume(throwing: OAuthError.missingAuthorizationCode)
          return
        }
        continuation.resume(returning: callback)
      }
      session.prefersEphemeralWebBrowserSession = false
      session.presentationContextProvider = presenter
      if !session.start() {
        continuation.resume(throwing: OAuthError.invalidAuthorizationURL)
      }
    }
  }

  // MARK: - Callback parsing

  private static func parseCallback(_ url: URL)
    -> (code: String?, state: String?, errorMessage: String?)
  {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let code = items.first(where: { $0.name == "code" })?.value
    let state = items.first(where: { $0.name == "state" })?.value
    let error = items.first(where: { $0.name == "error" })?.value
    let errorDescription = items.first(where: { $0.name == "error_description" })?.value
    let combinedError: String? = {
      switch (error, errorDescription) {
      case (.some(let e), .some(let d)) where !d.isEmpty: return "\(e): \(d)"
      case (.some(let e), _): return e
      case (.none, .some(let d)) where !d.isEmpty: return d
      default: return nil
      }
    }()
    return (code, state, combinedError)
  }

  // MARK: - Token exchange

  private static func exchangeCode(
    code: String,
    verifier: String,
    config: OAuthConfiguration
  ) async throws -> OAuthTokens {
    try await performTokenRequest(
      parameters: [
        "grant_type": "authorization_code",
        "client_id": config.clientID,
        "code": code,
        "code_verifier": verifier,
        "redirect_uri": config.redirectURI,
      ],
      config: config,
      existingRefreshToken: nil)
  }

  private static func performTokenRequest(
    parameters: [String: String],
    config: OAuthConfiguration,
    existingRefreshToken: String?
  ) async throws -> OAuthTokens {
    var request = URLRequest(url: config.tokenURL)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = formEncode(parameters).data(using: .utf8)

    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if !(200..<300).contains(status) {
      let message = parseTokenError(data: data)
        ?? "HTTP \(status) from \(config.tokenURL.absoluteString)"
      throw OAuthError.tokenExchangeFailed(message)
    }

    let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
    let access = decoded.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !access.isEmpty else {
      throw OAuthError.missingAccessToken
    }
    let refresh =
      decoded.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      ?? existingRefreshToken
    let expiresAt: Date? = decoded.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
    return OAuthTokens(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: expiresAt)
  }

  // MARK: - Helpers

  private static func validatedConfiguration(for endpoint: OpenAIEndpoint) throws
    -> OAuthConfiguration
  {
    let issuer = endpoint.oauthIssuer.trimmingCharacters(in: .whitespacesAndNewlines)
    let clientID = endpoint.oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines)
    let scope = endpoint.oauthScope.trimmingCharacters(in: .whitespacesAndNewlines)
    let redirectURI = endpoint.oauthRedirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
    let audience = endpoint.oauthAudience.trimmingCharacters(in: .whitespacesAndNewlines)
    let authorizeOverride = endpoint.oauthAuthorizeURL
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let tokenOverride = endpoint.oauthTokenURL.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !clientID.isEmpty else {
      throw OAuthError.invalidConfiguration("Client ID is required.")
    }
    guard !redirectURI.isEmpty,
      let redirectURL = URL(string: redirectURI),
      let scheme = redirectURL.scheme?.lowercased(),
      !scheme.isEmpty
    else {
      throw OAuthError.invalidRedirectURL(redirectURI)
    }

    let authorizeURL = try resolveEndpointURL(
      override: authorizeOverride,
      issuer: issuer,
      path: "/authorize",
      fieldDescription: "authorize URL")
    let tokenURL = try resolveEndpointURL(
      override: tokenOverride,
      issuer: issuer,
      path: "/oauth/token",
      fieldDescription: "token URL")

    return OAuthConfiguration(
      authorizeURL: authorizeURL,
      tokenURL: tokenURL,
      clientID: clientID,
      audience: audience,
      scope: scope.isEmpty ? "openid profile email offline_access" : scope,
      redirectURI: redirectURI,
      callbackScheme: scheme)
  }

  /// Returns the explicit override URL when set, otherwise composes `<issuer><path>`.
  /// Throws `invalidConfiguration` when neither source produces a valid https URL.
  private static func resolveEndpointURL(
    override: String,
    issuer: String,
    path: String,
    fieldDescription: String
  ) throws -> URL {
    if !override.isEmpty {
      guard let url = URL(string: override),
        url.scheme?.lowercased() == "https"
      else {
        throw OAuthError.invalidConfiguration("\(fieldDescription) must be an https:// URL.")
      }
      return url
    }

    guard !issuer.isEmpty,
      var components = URLComponents(string: issuer),
      components.scheme?.lowercased() == "https"
    else {
      throw OAuthError.invalidConfiguration(
        "Issuer must be an https:// URL when no \(fieldDescription) is provided.")
    }
    let trimmedPath = components.path.hasSuffix("/")
      ? String(components.path.dropLast())
      : components.path
    components.path = trimmedPath + path
    components.queryItems = nil
    guard let url = components.url else {
      throw OAuthError.invalidConfiguration("Could not build \(fieldDescription) from issuer.")
    }
    return url
  }

  private static func generateCodeVerifier(length: Int = 64) -> String {
    var bytes = [UInt8](repeating: 0, count: length)
    _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
    return Data(bytes).base64URLEncodedString()
  }

  private static func codeChallenge(for verifier: String) -> String {
    let digest = SHA256.hash(data: Data(verifier.utf8))
    return Data(digest).base64URLEncodedString()
  }

  private static func generateState() -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return Data(bytes).base64URLEncodedString()
  }

  private static func formEncode(_ parameters: [String: String]) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return
      parameters
      .map { key, value in
        let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "\(k)=\(v)"
      }
      .joined(separator: "&")
  }

  private static func parseTokenError(data: Data) -> String? {
    if let payload = try? JSONDecoder().decode(TokenErrorResponse.self, from: data) {
      switch (payload.error, payload.errorDescription) {
      case (.some(let code), .some(let description)) where !description.isEmpty:
        return "\(code): \(description)"
      case (.some(let code), _):
        return code
      case (.none, .some(let description)):
        return description
      default:
        break
      }
    }
    if let raw = String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !raw.isEmpty
    {
      return raw
    }
    return nil
  }
}

private struct OAuthConfiguration: Sendable {
  let authorizeURL: URL
  let tokenURL: URL
  let clientID: String
  let audience: String
  let scope: String
  let redirectURI: String
  let callbackScheme: String
}

private struct TokenResponse: Decodable {
  let accessToken: String?
  let refreshToken: String?
  let tokenType: String?
  let expiresIn: Int?
  let scope: String?

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
    case tokenType = "token_type"
    case expiresIn = "expires_in"
    case scope
  }
}

private struct TokenErrorResponse: Decodable {
  let error: String?
  let errorDescription: String?

  enum CodingKeys: String, CodingKey {
    case error
    case errorDescription = "error_description"
  }
}

@MainActor
private final class AuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
  private let windowScene: UIWindowScene

  init(windowScene: UIWindowScene) {
    self.windowScene = windowScene
    super.init()
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    if let window = windowScene.windows.first(where: \.isKeyWindow) {
      return window
    }
    return ASPresentationAnchor(windowScene: windowScene)
  }

  static func preferredWindowScene() -> UIWindowScene? {
    let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    if let window = windowScenes.flatMap(\.windows).first(where: \.isKeyWindow) {
      return window.windowScene
    }
    if let windowScene = windowScenes.first(where: { $0.activationState == .foregroundActive })
      ?? windowScenes.first
    {
      return windowScene
    }
    return nil
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
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
