@_exported import CMaiPluginABI
import Foundation

public enum PluginJSONValue: Codable, Equatable, Sendable {
  case object([String: PluginJSONValue])
  case array([PluginJSONValue])
  case string(String)
  case integer(Int)
  case number(Double)
  case bool(Bool)
  case null

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([String: PluginJSONValue].self) {
      self = .object(value)
    } else if let value = try? container.decode([PluginJSONValue].self) {
      self = .array(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unsupported JSON value.")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }

  public var objectValue: [String: PluginJSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  public var arrayValue: [PluginJSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  public var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  public var intValue: Int? {
    switch self {
    case .integer(let value): value
    case .number(let value) where value.rounded() == value: Int(value)
    default: nil
    }
  }
}

public struct NativePluginIdentity: Codable, Equatable, Sendable {
  public var id: String
  public var displayName: String
  public var version: String
  public var apiVersion: Int
  public var capabilities: Set<String>

  public init(
    id: String,
    displayName: String,
    version: String,
    apiVersion: Int = 1,
    capabilities: Set<String>
  ) {
    self.id = id
    self.displayName = displayName
    self.version = version
    self.apiVersion = apiVersion
    self.capabilities = capabilities
  }
}

public struct NativePluginExtension: Codable, Equatable, Sendable {
  public var kind: String
  public var metadata: [String: PluginJSONValue]

  public init(kind: String, metadata: [String: PluginJSONValue] = [:]) {
    self.kind = kind
    self.metadata = metadata
  }
}

public struct NativePluginManifest: Codable, Equatable, Sendable {
  public var plugin: NativePluginIdentity
  public var extensions: [String: [NativePluginExtension]]

  public init(
    plugin: NativePluginIdentity,
    extensions: [String: [NativePluginExtension]]
  ) {
    self.plugin = plugin
    self.extensions = extensions
  }

  public func extensions(for capability: String) -> [NativePluginExtension] {
    extensions[capability] ?? []
  }
}

public struct NativePluginRequest: Codable, Equatable, Sendable {
  public var id: String
  public var operation: String
  public var kind: String
  public var configuration: PluginJSONValue?
  public var payload: PluginJSONValue?

  public init(
    id: String = UUID().uuidString,
    operation: String,
    kind: String,
    configuration: PluginJSONValue? = nil,
    payload: PluginJSONValue? = nil
  ) {
    self.id = id
    self.operation = operation
    self.kind = kind
    self.configuration = configuration
    self.payload = payload
  }
}

public struct NativePluginResponse: Codable, Equatable, Sendable {
  public var result: PluginJSONValue?
  public var error: NativePluginFailure?

  public init(result: PluginJSONValue? = nil, error: NativePluginFailure? = nil) {
    self.result = result
    self.error = error
  }
}

public struct NativePluginFailure: Codable, Error, Equatable, LocalizedError, Sendable {
  public var code: String
  public var message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }

  public var errorDescription: String? { "Native plugin error [\(code)]: \(message)" }
}

public enum NativePluginOperation {
  public static let providerModels = "provider.models"
  public static let providerComplete = "provider.complete"
  public static let toolList = "tool.list"
  public static let toolGroups = "tool.groups"
  public static let toolCall = "tool.call"
  public static let ocrRecognize = "ocr.recognize"
  public static let mcpConnect = "mcp.connect"
  public static let mcpCall = "mcp.call"
  public static let mcpClose = "mcp.close"
}

/// Optional response types for `tool.groups`. Older plugins may omit this
/// operation; hosts then infer groups from `tool.list` name prefixes.
public struct NativeToolGroupOptionDefinition: Codable, Equatable, Sendable {
  public var id: String
  public var label: String
  public var help: String?
  public var kind: String
  public var defaultValue: PluginJSONValue?
  public var choices: [String]

  public init(
    id: String,
    label: String,
    help: String? = nil,
    kind: String = "text",
    defaultValue: PluginJSONValue? = nil,
    choices: [String] = []
  ) {
    self.id = id
    self.label = label
    self.help = help
    self.kind = kind
    self.defaultValue = defaultValue
    self.choices = choices
  }
}

public struct NativeToolGroupDefinition: Codable, Equatable, Sendable {
  public var id: String
  public var displayName: String
  public var description: String
  public var toolNames: Set<String>
  public var options: [NativeToolGroupOptionDefinition]

  public init(
    id: String,
    displayName: String? = nil,
    description: String = "",
    toolNames: Set<String>,
    options: [NativeToolGroupOptionDefinition] = []
  ) {
    self.id = id
    self.displayName = displayName ?? id
    self.description = description
    self.toolNames = toolNames
    self.options = options
  }
}

public enum PluginWireCodec {
  public static func value<T: Encodable>(_ value: T) throws -> PluginJSONValue {
    try JSONDecoder().decode(PluginJSONValue.self, from: JSONEncoder().encode(value))
  }

  public static func decode<T: Decodable>(
    _ type: T.Type,
    from value: PluginJSONValue
  ) throws -> T {
    try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
  }
}
