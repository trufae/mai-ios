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
}

struct ToolNameResolver: Sendable {
  private let canonicalToProvider: [String: String]
  private let providerToCanonical: [String: String]

  init(definitions: [ToolDefinition]) {
    var forward: [String: String] = [:]
    var reverse: [String: String] = [:]
    var used = Set<String>()
    for definition in definitions {
      let requested = definition.providerName?.trimmingCharacters(in: .whitespacesAndNewlines)
      let base = Self.sanitize(requested?.isEmpty == false ? requested! : definition.name)
      var candidate = base
      var suffix = 2
      while used.contains(candidate) {
        let suffixText = "_\(suffix)"
        candidate = String(base.prefix(max(1, 64 - suffixText.count))) + suffixText
        suffix += 1
      }
      used.insert(candidate)
      forward[definition.name] = candidate
      reverse[candidate] = definition.name
      reverse[definition.name] = definition.name
    }
    canonicalToProvider = forward
    providerToCanonical = reverse
  }

  func providerName(for canonicalName: String) -> String {
    canonicalToProvider[canonicalName] ?? Self.sanitize(canonicalName)
  }

  func canonicalName(for providerName: String) -> String? {
    providerToCanonical[providerName]
  }

  private static func sanitize(_ name: String) -> String {
    var result = ""
    var previousUnderscore = false
    for scalar in name.unicodeScalars {
      let allowed = CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
      if allowed {
        result.unicodeScalars.append(scalar)
        previousUnderscore = false
      } else if !previousUnderscore {
        result.append("_")
        previousUnderscore = true
      }
    }
    result = result.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
    if result.isEmpty { result = "tool" }
    if result.first?.isNumber == true { result = "tool_\(result)" }
    return String(result.prefix(64))
  }
}

public struct ToolExecutionContext: Equatable, Sendable {
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

public struct ToolOutput: Equatable, Sendable {
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
