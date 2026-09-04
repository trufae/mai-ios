import Foundation

public enum ToolApprovalRequirement: String, Codable, Equatable, Sendable {
  case automatic
  case confirm
  case dangerous
}

public struct ToolAnnotations: Codable, Equatable, Sendable {
  public var title: String?
  public var readOnly: Bool
  public var destructive: Bool
  public var idempotent: Bool
  public var openWorld: Bool
  public var approval: ToolApprovalRequirement

  public init(
    title: String? = nil,
    readOnly: Bool = false,
    destructive: Bool = false,
    idempotent: Bool = false,
    openWorld: Bool = true,
    approval: ToolApprovalRequirement = .confirm
  ) {
    self.title = title
    self.readOnly = readOnly
    self.destructive = destructive
    self.idempotent = idempotent
    self.openWorld = openWorld
    self.approval = approval
  }
}

/// A compact, presentation-friendly view of one object-schema property.
///
/// Hosts that already have a full JSON Schema should use `ToolDefinition.inputSchema`.
/// This type exists for tools, configuration files, and UIs that define the common
/// flat object-schema shape.
public struct ToolParameterDef: Codable, Equatable, Sendable {
  public var name: String
  public var type: String
  public var description: String
  public var required: Bool

  public init(name: String, type: String, description: String, required: Bool) {
    self.name = name
    self.type = type
    self.description = description
    self.required = required
  }
}

public struct ToolDefinition: Codable, Equatable, Identifiable, Sendable {
  public var name: String
  public var providerName: String?
  public var description: String
  public var inputSchema: JSONValue
  public var annotations: ToolAnnotations

  public var id: String { name }

  public init(
    name: String,
    providerName: String? = nil,
    description: String,
    inputSchema: JSONValue = .object(["type": .string("object")]),
    annotations: ToolAnnotations = .init()
  ) {
    self.name = name
    self.providerName = providerName
    self.description = description
    self.inputSchema = inputSchema
    self.annotations = annotations
  }

  /// Convenience initializer for hosts that describe tools as a flat parameter list.
  /// A non-empty raw schema takes precedence and preserves nested JSON Schema features.
  public init(
    name: String,
    description: String,
    parameters: [ToolParameterDef],
    inputSchemaJSON: String = "",
    annotations: ToolAnnotations = .init()
  ) {
    let rawSchema = inputSchemaJSON.data(using: .utf8).flatMap {
      try? JSONDecoder().decode(JSONValue.self, from: $0)
    }
    let schema = rawSchema?.objectValue == nil ? Self.schema(for: parameters) : rawSchema
    self.init(
      name: name,
      description: description,
      inputSchema: schema ?? .object([:]),
      annotations: annotations)
  }

  /// The flat properties exposed by this tool's object schema.
  public var parameters: [ToolParameterDef] {
    guard let schema = inputSchema.objectValue,
      let properties = schema["properties"]?.objectValue
    else { return [] }
    let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    return properties.keys.sorted().map { name in
      let property = properties[name]?.objectValue ?? [:]
      return ToolParameterDef(
        name: name,
        type: property["type"]?.stringValue ?? "string",
        description: property["description"]?.stringValue ?? "",
        required: required.contains(name))
    }
  }

  /// A compact JSON representation for APIs that accept raw JSON Schema strings.
  public var inputSchemaJSON: String { inputSchema.compactJSONString }

  private static func schema(for parameters: [ToolParameterDef]) -> JSONValue {
    .object([
      "type": .string("object"),
      "properties": .object(
        Dictionary(
          uniqueKeysWithValues: parameters.map { parameter in
            (
              parameter.name,
              .object([
                "type": .string(parameter.type),
                "description": .string(parameter.description),
              ])
            )
          })),
      "required": .array(parameters.filter(\.required).map { .string($0.name) }),
    ])
  }
}

public struct ToolExecutionContext: Codable, Equatable, Sendable {
  public var run: AgentEventContext
  public var modelTurn: Int

  public init(run: AgentEventContext, modelTurn: Int) {
    self.run = run
    self.modelTurn = modelTurn
  }
}

public protocol AgentTool: Sendable {
  var definition: ToolDefinition { get }

  func call(
    arguments: JSONValue,
    context: ToolExecutionContext
  ) async throws -> ToolOutput
}

public struct ToolOutput: Codable, Equatable, Sendable {
  public var content: [ContentPart]
  public var structuredContent: JSONValue?
  public var isError: Bool

  public init(
    content: [ContentPart],
    structuredContent: JSONValue? = nil,
    isError: Bool = false
  ) {
    self.content = content
    self.structuredContent = structuredContent
    self.isError = isError
  }

  public init(text: String, isError: Bool = false) {
    self.init(content: [.text(text)], isError: isError)
  }

  public var text: String {
    content.compactMap(\.textValue).joined(separator: "\n")
  }
}

public struct ClosureTool: AgentTool {
  public let definition: ToolDefinition
  private let operation: @Sendable (JSONValue, ToolExecutionContext) async throws -> ToolOutput

  public init(
    definition: ToolDefinition,
    operation: @escaping @Sendable (JSONValue, ToolExecutionContext) async throws -> ToolOutput
  ) {
    self.definition = definition
    self.operation = operation
  }

  public func call(
    arguments: JSONValue,
    context: ToolExecutionContext
  ) async throws -> ToolOutput {
    try await operation(arguments, context)
  }
}

public struct ApprovalRequest: Equatable, Sendable {
  public var run: AgentEventContext
  public var tool: ToolDefinition
  public var call: ToolCall

  public init(run: AgentEventContext, tool: ToolDefinition, call: ToolCall) {
    self.run = run
    self.tool = tool
    self.call = call
  }
}

public enum ApprovalDecision: Equatable, Sendable {
  case approve(arguments: JSONValue)
  case deny(reason: String)
  case cancelRun
}

public protocol ApprovalHandler: Sendable {
  func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision
}

public struct DenyInteractiveApprovals: ApprovalHandler {
  public init() {}

  public func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
    .deny(reason: "No approval handler is configured for '\(request.tool.name)'.")
  }
}

public struct AllowAllApprovals: ApprovalHandler {
  public init() {}

  public func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
    .approve(arguments: request.call.arguments)
  }
}

public enum AgentToolError: LocalizedError, Equatable, Sendable {
  case invalidName
  case duplicateName(String)
  case unavailable(String)
  case invalidArguments(tool: String, reason: String)
  case executionFailed(tool: String, reason: String)

  public var errorDescription: String? {
    switch self {
    case .invalidName:
      "Tool names cannot be empty."
    case .duplicateName(let name):
      "Tool '\(name)' is already registered."
    case .unavailable(let name):
      "Tool '\(name)' is not registered."
    case .invalidArguments(let tool, let reason):
      "Invalid arguments for '\(tool)': \(reason)"
    case .executionFailed(let tool, let reason):
      "Tool '\(tool)' failed: \(reason)"
    }
  }
}

enum ToolSchemaValidator {
  static func validate(arguments: JSONValue, definition: ToolDefinition) -> String? {
    guard arguments.objectValue != nil else { return "arguments must be a JSON object" }
    return validate(arguments, schema: definition.inputSchema, path: "arguments")
  }

  private static func validate(_ value: JSONValue, schema: JSONValue, path: String) -> String? {
    guard let schema = schema.objectValue else { return nil }
    if let allowed = schema["enum"]?.arrayValue, !allowed.contains(value) {
      return "\(path) must be one of the schema's allowed values"
    }
    if let expected = schema["type"]?.stringValue, !matches(value, type: expected) {
      return "\(path) must be \(expected)"
    }
    if let object = value.objectValue {
      let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
      let missing = required.filter { object[$0] == nil }
      if !missing.isEmpty {
        return
          "missing required field\(missing.count == 1 ? "" : "s"): \(missing.joined(separator: ", "))"
      }
      let properties = schema["properties"]?.objectValue ?? [:]
      if schema["additionalProperties"]?.boolValue == false {
        let unknown = object.keys.filter { properties[$0] == nil }.sorted()
        if !unknown.isEmpty {
          return "unknown field\(unknown.count == 1 ? "" : "s"): \(unknown.joined(separator: ", "))"
        }
      }
      for (name, propertySchema) in properties {
        if let property = object[name],
          let error = validate(property, schema: propertySchema, path: "\(path).\(name)")
        {
          return error
        }
      }
    }
    if let array = value.arrayValue, let itemSchema = schema["items"] {
      for (index, item) in array.enumerated() {
        if let error = validate(item, schema: itemSchema, path: "\(path)[\(index)]") {
          return error
        }
      }
    }
    return nil
  }

  private static func matches(_ value: JSONValue, type: String) -> Bool {
    switch (type, value) {
    case ("object", .object), ("array", .array), ("string", .string),
      ("integer", .integer), ("number", .integer), ("number", .number),
      ("boolean", .bool), ("null", .null):
      true
    default:
      false
    }
  }
}
