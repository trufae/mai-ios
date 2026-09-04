import Foundation
import MaiCore
import MaiMCP

typealias MCPServerSentEvent = MaiMCP.MCPServerSentEvent
typealias MCPServerSentEventParser = MaiMCP.MCPServerSentEventParser

/// Compatibility adapter between PocketMai's persisted UI models and MaiMCP.
enum MCPHTTPClient {
  struct Catalog: Sendable {
    var tools: [MCPToolDescriptor]
    var resources: [MCPResourceDescriptor]
    var transport: MCPTransport?
    var serverName: String?
    var protocolVersion: String?
  }

  static func fetchCatalog(server: MCPServer, timeout: TimeInterval) async throws -> Catalog {
    let catalog = try await MCPStreamableHTTPTransport.fetchCatalog(
      server: try configuration(for: server, timeout: timeout))
    return Catalog(
      tools: catalog.tools.map {
        MCPToolDescriptor(
          name: $0.name,
          description: $0.description,
          parametersJSON: $0.inputSchema.compactJSONString)
      },
      resources: catalog.resources.map {
        MCPResourceDescriptor(
          uri: $0.uri,
          name: $0.name,
          description: $0.description,
          mimeType: $0.mimeType ?? "")
      },
      transport: .streamableHTTP,
      serverName: catalog.serverName,
      protocolVersion: catalog.protocolVersion)
  }

  static func callTool(
    server: MCPServer,
    name: String,
    arguments: [String: AgentToolArgumentValue],
    timeout: TimeInterval
  ) async throws -> String {
    let output = try await MCPStreamableHTTPTransport.callTool(
      server: try configuration(for: server, timeout: timeout),
      name: name,
      arguments: .object(arguments.mapValues(jsonValue)))
    let text = render(output.content, empty: "(no output)")
    return output.isError ? "Error: \(text)" : text
  }

  static func readResource(
    server: MCPServer,
    uri: String,
    timeout: TimeInterval
  ) async throws -> String {
    let content = try await MCPStreamableHTTPTransport.readResource(
      server: try configuration(for: server, timeout: timeout),
      uri: uri)
    return render(content, empty: "(empty resource)")
  }

  static func resetSession(for serverID: UUID) async {
    await MCPStreamableHTTPTransport.resetSession(for: serverID.uuidString)
  }

  static func resetAllSessions() async {
    await MCPStreamableHTTPTransport.resetAllSessions()
  }

  static func isAvailabilityFailure(_ error: Error) -> Bool {
    MCPStreamableHTTPTransport.isAvailabilityFailure(error)
  }

  private static func configuration(
    for server: MCPServer,
    timeout: TimeInterval
  ) throws -> MCPServerConfiguration {
    let trimmed = server.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard server.hasValidEndpointURL, let url = URL(string: trimmed) else {
      throw MCPClientError.invalidURL(server.baseURL)
    }
    var headers: [String: String] = [:]
    if let token = server.authentication.accessToken {
      headers["Authorization"] = "Bearer \(token)"
    }
    return MCPServerConfiguration(
      id: server.id.uuidString,
      displayName: server.name,
      url: url,
      headers: headers,
      timeout: timeout)
  }

  private static func jsonValue(_ value: AgentToolArgumentValue) -> MaiCore.JSONValue {
    switch value {
    case .string(let value): .string(value)
    case .bool(let value): .bool(value)
    case .int(let value): .integer(value)
    case .double(let value): .number(value)
    case .object(let value): .object(value.mapValues(jsonValue))
    case .array(let value): .array(value.map(jsonValue))
    case .null: .null
    }
  }

  private static func render(_ content: [MaiCore.ContentPart], empty: String) -> String {
    let parts = content.compactMap { part -> String? in
      switch part {
      case .text(let text), .reasoning(let text):
        return text
      case .image(let image):
        return "[image \(image.mimeType)]"
      case .audio(let audio):
        return "[audio \(audio.mimeType)]"
      case .file(let file):
        return file.text ?? "[file \(file.name)]"
      case .resource(let resource):
        if let text = resource.text, !text.isEmpty { return text }
        if let blob = resource.blob { return "[resource \(resource.uri), \(blob.count) bytes]" }
        return "[resource \(resource.uri)]"
      case .toolResult(let result):
        return result.text
      case .toolCall:
        return nil
      }
    }
    let rendered = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return rendered.isEmpty ? empty : rendered
  }
}
