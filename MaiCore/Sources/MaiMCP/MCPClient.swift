import Foundation
import MaiCore

public actor MCPClient {
  private static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]

  public let configuration: MCPServerConfiguration
  private let session: URLSession
  private var sessionID: String?
  private var negotiatedVersion: String?
  private var serverName: String?
  private var nextRequestID = 1
  private var catalog: MCPServerCatalog?

  public init(
    configuration: MCPServerConfiguration,
    session: URLSession = .shared
  ) {
    self.configuration = configuration
    self.session = session
  }

  public func connect() async throws -> MCPServerCatalog {
    if let catalog { return catalog }
    try validateConfiguration()

    var lastError: Error?
    for version in Self.supportedVersions {
      do {
        let result = try await request(
          method: "initialize",
          params: .object([
            "protocolVersion": .string(version),
            "capabilities": .object([:]),
            "clientInfo": .object([
              "name": .string("MaiCore"),
              "version": .string("0.1"),
            ]),
          ]),
          protocolVersion: version,
          useSession: false)
        let negotiated = result.objectValue?["protocolVersion"]?.stringValue ?? version
        negotiatedVersion = negotiated
        serverName = result.objectValue?["serverInfo"]?.objectValue?["name"]?.stringValue
        try await notify(method: "notifications/initialized")
        var firstCatalogError: Error?
        let tools: [ToolDefinition]
        do {
          tools = try await listToolDefinitions()
        } catch {
          if !Self.isMethodNotFound(error) { firstCatalogError = error }
          tools = []
        }
        let resources: [MCPResourceDescriptor]
        do {
          resources = try await fetchResources()
        } catch {
          if !Self.isMethodNotFound(error) { firstCatalogError = firstCatalogError ?? error }
          resources = []
        }
        if tools.isEmpty, resources.isEmpty, let firstCatalogError {
          throw firstCatalogError
        }
        let value = MCPServerCatalog(
          serverID: configuration.id,
          serverName: serverName,
          protocolVersion: negotiated,
          tools: tools,
          resources: resources)
        catalog = value
        return value
      } catch {
        sessionID = nil
        negotiatedVersion = nil
        lastError = error
        if !Self.isUnsupportedVersion(error) { break }
      }
    }
    throw lastError ?? MCPClientError.invalidResponse("MCP initialization failed.")
  }

  public func agentTools() async throws -> [any AgentTool] {
    let catalog = try await connect()
    var tools: [any AgentTool] = catalog.tools.map { definition in
      MCPRemoteTool(
        definition: definition,
        remoteName: remoteName(for: definition.name),
        client: self)
    }
    if !catalog.resources.isEmpty {
      let namespace =
        configuration.toolNamePrefix.flatMap { $0.isEmpty ? nil : $0 }
        ?? configuration.id
      tools.append(
        MCPResourceReadTool(
          definition: ToolDefinition(
            name: "\(namespace)::resources_read",
            description: "Read one resource exposed by \(configuration.displayName).",
            inputSchema: .object([
              "type": .string("object"),
              "properties": .object([
                "uri": .object([
                  "type": .string("string"),
                  "enum": .array(catalog.resources.map { .string($0.uri) }),
                ])
              ]),
              "required": .array([.string("uri")]),
              "additionalProperties": .bool(false),
            ]),
            annotations: ToolAnnotations(
              readOnly: true,
              idempotent: true,
              openWorld: true,
              approval: configuration.defaultApproval)),
          client: self))
    }
    return tools
  }

  public func listResources() async throws -> [MCPResourceDescriptor] {
    let catalog = try await connect()
    return catalog.resources
  }

  private func fetchResources() async throws -> [MCPResourceDescriptor] {
    var resources: [MCPResourceDescriptor] = []
    var cursor: String?
    repeat {
      let params = cursor.map { JSONValue.object(["cursor": .string($0)]) }
      let result = try await request(method: "resources/list", params: params)
      for value in result.objectValue?["resources"]?.arrayValue ?? [] {
        guard let object = value.objectValue,
          let uri = object["uri"]?.stringValue,
          !uri.isEmpty
        else { continue }
        resources.append(
          MCPResourceDescriptor(
            uri: uri,
            name: object["name"]?.stringValue ?? "",
            description: object["description"]?.stringValue ?? "",
            mimeType: object["mimeType"]?.stringValue))
      }
      cursor = result.objectValue?["nextCursor"]?.stringValue
    } while cursor?.isEmpty == false
    return resources
  }

  public func readResource(uri: String) async throws -> [ContentPart] {
    _ = try await ensureInitialized()
    let result = try await request(
      method: "resources/read",
      params: .object(["uri": .string(uri)]))
    return try (result.objectValue?["contents"]?.arrayValue ?? []).map(mcpContent)
  }

  public func close() async {
    guard let sessionID else { return }
    var request = URLRequest(url: configuration.url)
    request.httpMethod = "DELETE"
    request.timeoutInterval = configuration.timeout
    applyHeaders(to: &request, protocolVersion: negotiatedVersion, sessionID: sessionID)
    let delegate = ProviderRedirectDelegate(originalRequest: request)
    _ = try? await session.data(for: request, delegate: delegate)
    self.sessionID = nil
    negotiatedVersion = nil
    catalog = nil
  }

  fileprivate func callTool(name: String, arguments: JSONValue) async throws -> ToolOutput {
    _ = try await ensureInitialized()
    let result = try await request(
      method: "tools/call",
      params: .object([
        "name": .string(name),
        "arguments": arguments,
      ]))
    let parts = try (result.objectValue?["content"]?.arrayValue ?? []).map(mcpContent)
    let isError = result.objectValue?["isError"]?.boolValue ?? false
    return ToolOutput(
      content: parts.isEmpty ? [.text("(no output)")] : parts,
      structuredContent: result.objectValue?["structuredContent"],
      isError: isError)
  }

  private func listToolDefinitions() async throws -> [ToolDefinition] {
    var definitions: [ToolDefinition] = []
    var cursor: String?
    repeat {
      let params = cursor.map { JSONValue.object(["cursor": .string($0)]) }
      let result = try await request(method: "tools/list", params: params)
      for value in result.objectValue?["tools"]?.arrayValue ?? [] {
        guard let object = value.objectValue,
          let remoteName = object["name"]?.stringValue,
          !remoteName.isEmpty
        else { continue }
        let annotations = object["annotations"]?.objectValue ?? [:]
        let destructive = annotations["destructiveHint"]?.boolValue ?? false
        let readOnly = annotations["readOnlyHint"]?.boolValue ?? false
        let canonical = canonicalName(remoteName)
        definitions.append(
          ToolDefinition(
            name: canonical,
            description: object["description"]?.stringValue ?? "MCP tool \(remoteName)",
            inputSchema: object["inputSchema"] ?? .object(["type": .string("object")]),
            annotations: ToolAnnotations(
              title: annotations["title"]?.stringValue,
              readOnly: readOnly,
              destructive: destructive,
              idempotent: annotations["idempotentHint"]?.boolValue ?? false,
              openWorld: annotations["openWorldHint"]?.boolValue ?? true,
              approval: destructive ? .dangerous : configuration.defaultApproval)))
      }
      cursor = result.objectValue?["nextCursor"]?.stringValue
    } while cursor?.isEmpty == false
    return definitions
  }

  private func canonicalName(_ remoteName: String) -> String {
    let prefix = configuration.toolNamePrefix?.trimmingCharacters(in: .whitespacesAndNewlines)
    let namespace = prefix.flatMap { $0.isEmpty ? nil : $0 } ?? configuration.id
    return "\(namespace)::\(remoteName)"
  }

  private func remoteName(for canonicalName: String) -> String {
    guard let separator = canonicalName.range(of: "::") else { return canonicalName }
    return String(canonicalName[separator.upperBound...])
  }

  private func ensureInitialized() async throws -> MCPServerCatalog {
    if let catalog { return catalog }
    return try await connect()
  }

  private func validateConfiguration() throws {
    guard let scheme = configuration.url.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      configuration.url.host?.isEmpty == false
    else {
      throw MCPClientError.invalidURL(configuration.url.absoluteString)
    }
  }

  private func notify(method: String) async throws {
    _ = try await request(method: method, params: nil, notification: true)
  }

  private func request(
    method: String,
    params: JSONValue?,
    notification: Bool = false,
    protocolVersion: String? = nil,
    useSession: Bool = true
  ) async throws -> JSONValue {
    let requestID = nextRequestID
    nextRequestID += 1
    var envelope: [String: JSONValue] = [
      "jsonrpc": .string("2.0"),
      "method": .string(method),
    ]
    if !notification { envelope["id"] = .integer(requestID) }
    if let params { envelope["params"] = params }

    var urlRequest = URLRequest(url: configuration.url)
    urlRequest.httpMethod = "POST"
    urlRequest.timeoutInterval = configuration.timeout
    urlRequest.httpBody = try JSONEncoder().encode(JSONValue.object(envelope))
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    applyHeaders(
      to: &urlRequest,
      protocolVersion: protocolVersion ?? negotiatedVersion,
      sessionID: useSession ? sessionID : nil)

    let delegate = ProviderRedirectDelegate(originalRequest: urlRequest)
    let (data, response) = try await session.data(for: urlRequest, delegate: delegate)
    guard let http = response as? HTTPURLResponse else {
      throw MCPClientError.invalidResponse("MCP returned a non-HTTP response.")
    }
    guard (200..<300).contains(http.statusCode) else {
      let text = String(data: data, encoding: .utf8) ?? "Request failed."
      throw MCPClientError.httpError(statusCode: http.statusCode, message: text)
    }
    if let value = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !value.isEmpty {
      sessionID = value
    }
    if notification || data.isEmpty { return .null }

    let value = try decodedResponse(data: data, contentType: http.mimeType, requestID: requestID)
    guard let object = value.objectValue else {
      throw MCPClientError.invalidResponse("MCP returned an invalid JSON-RPC envelope.")
    }
    if let error = object["error"]?.objectValue {
      throw MCPClientError.rpcError(
        code: error["code"]?.intValue,
        message: error["message"]?.stringValue ?? "Unknown MCP error.")
    }
    return object["result"] ?? .null
  }

  private func applyHeaders(
    to request: inout URLRequest,
    protocolVersion: String?,
    sessionID: String?
  ) {
    for (name, value) in configuration.headers {
      request.setValue(value, forHTTPHeaderField: name)
    }
    if let protocolVersion {
      request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
    }
    if let sessionID {
      request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
    }
  }

  private func decodedResponse(
    data: Data,
    contentType: String?,
    requestID: Int
  ) throws -> JSONValue {
    if contentType?.lowercased().contains("text/event-stream") == true,
      let rawText = String(data: data, encoding: .utf8)
    {
      let text = rawText.replacingOccurrences(of: "\r\n", with: "\n")
      let payloads = text.components(separatedBy: "\n\n").compactMap {
        event -> String? in
        let lines = event.split(separator: "\n", omittingEmptySubsequences: false)
        let dataLines = lines.compactMap { line -> String? in
          guard line.hasPrefix("data:") else { return nil }
          return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        return dataLines.isEmpty ? nil : dataLines.joined(separator: "\n")
      }
      for payload in payloads.reversed() {
        guard let valueData = payload.data(using: .utf8),
          let value = try? JSONDecoder().decode(JSONValue.self, from: valueData),
          value.objectValue?["id"]?.intValue == requestID
        else { continue }
        return value
      }
      throw MCPClientError.invalidResponse("MCP event stream did not contain the response.")
    }
    let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
    if let array = decoded.arrayValue {
      return array.first { $0.objectValue?["id"]?.intValue == requestID } ?? .null
    }
    return decoded
  }

  private func mcpContent(_ value: JSONValue) throws -> ContentPart {
    guard let object = value.objectValue else { return .text(value.compactJSONString) }
    switch object["type"]?.stringValue {
    case "text":
      return .text(object["text"]?.stringValue ?? "")
    case "image":
      guard let raw = object["data"]?.stringValue,
        let data = Data(base64Encoded: raw)
      else { throw MCPClientError.invalidResponse("MCP image content has invalid base64 data.") }
      return .image(
        ImageContent(
          source: .data(data),
          mimeType: object["mimeType"]?.stringValue ?? "application/octet-stream"))
    case "audio":
      guard let raw = object["data"]?.stringValue,
        let data = Data(base64Encoded: raw)
      else { throw MCPClientError.invalidResponse("MCP audio content has invalid base64 data.") }
      return .audio(
        AudioContent(
          source: .data(data),
          mimeType: object["mimeType"]?.stringValue ?? "application/octet-stream"))
    case "resource", "resource_link":
      let resource = object["resource"]?.objectValue ?? object
      let blob = resource["blob"]?.stringValue.flatMap { Data(base64Encoded: $0) }
      return .resource(
        ResourceContent(
          uri: resource["uri"]?.stringValue ?? "",
          name: resource["name"]?.stringValue,
          mimeType: resource["mimeType"]?.stringValue,
          text: resource["text"]?.stringValue,
          blob: blob))
    default:
      return .text(value.compactJSONString)
    }
  }

  private static func isUnsupportedVersion(_ error: Error) -> Bool {
    guard let error = error as? MCPClientError else { return false }
    let message: String
    switch error {
    case .rpcError(_, let value), .httpError(_, let value), .invalidResponse(let value):
      message = value
    case .invalidURL:
      return false
    }
    let lower = message.lowercased()
    return lower.contains("protocol version")
      && (lower.contains("unsupported") || lower.contains("invalid"))
  }

  private static func isMethodNotFound(_ error: Error) -> Bool {
    guard case .rpcError(let code, let message) = error as? MCPClientError else { return false }
    return code == -32601 || message.lowercased().contains("method not found")
  }
}

private struct MCPRemoteTool: AgentTool {
  let definition: ToolDefinition
  let remoteName: String
  let client: MCPClient

  func call(
    arguments: JSONValue,
    context: ToolExecutionContext
  ) async throws -> ToolOutput {
    try await client.callTool(name: remoteName, arguments: arguments)
  }
}

private struct MCPResourceReadTool: AgentTool {
  let definition: ToolDefinition
  let client: MCPClient

  func call(
    arguments: JSONValue,
    context: ToolExecutionContext
  ) async throws -> ToolOutput {
    guard let uri = arguments.objectValue?["uri"]?.stringValue else {
      return ToolOutput(text: "Missing resource URI.", isError: true)
    }
    return ToolOutput(content: try await client.readResource(uri: uri))
  }
}

public enum MCPClientError: LocalizedError, Equatable, Sendable {
  case invalidURL(String)
  case invalidResponse(String)
  case httpError(statusCode: Int, message: String)
  case rpcError(code: Int?, message: String)

  public var errorDescription: String? {
    switch self {
    case .invalidURL(let value):
      "Invalid MCP URL: \(value)"
    case .invalidResponse(let message):
      message
    case .httpError(let statusCode, let message):
      "MCP returned HTTP \(statusCode): \(message)"
    case .rpcError(let code, let message):
      "MCP error\(code.map { " \($0)" } ?? ""): \(message)"
    }
  }
}

extension MCPClient: MCPToolSource {}

public struct MaiMCPPlugin: MaiPlugin {
  public let manifest = PluginManifest(
    id: "org.mai.mcp",
    displayName: "Mai MCP",
    version: "1.0.0",
    capabilities: [.mcpToolSource])

  public init() {}

  public func register(in registry: PluginRegistry) async throws {
    try await registry.register(
      mcpFactory: StreamableHTTPMCPFactory(),
      from: manifest.id)
  }
}

public struct StreamableHTTPMCPFactory: ConfiguredMCPToolSourceFactory {
  public let kind = "streamable-http"

  public init() {}

  public func makeMCPToolSource(
    from configuration: ConfiguredMCPServer,
    environment: [String: String]
  ) throws -> any MCPToolSource {
    MCPClient(configuration: try configuration.resolved(environment: environment))
  }
}
