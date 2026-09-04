import Foundation

public struct ProviderID: RawRepresentable, Codable, Hashable, Sendable,
  ExpressibleByStringLiteral, CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.init(rawValue: rawValue) }
  public init(stringLiteral value: String) { self.init(value) }
  public var description: String { rawValue }

  public static let hello: ProviderID = "hello"
  public static let openAI: ProviderID = "openai"
}

public struct ProviderCapabilities: OptionSet, Codable, Hashable, Sendable {
  public let rawValue: UInt

  public init(rawValue: UInt) { self.rawValue = rawValue }

  public static let streaming = ProviderCapabilities(rawValue: 1 << 0)
  public static let nativeToolCalling = ProviderCapabilities(rawValue: 1 << 1)
  public static let imageInput = ProviderCapabilities(rawValue: 1 << 2)
  public static let reasoning = ProviderCapabilities(rawValue: 1 << 3)
  public static let structuredOutput = ProviderCapabilities(rawValue: 1 << 4)
  public static let audioInput = ProviderCapabilities(rawValue: 1 << 5)
  public static let fileInput = ProviderCapabilities(rawValue: 1 << 6)
}

public struct ProviderDescriptor: Codable, Equatable, Sendable {
  public var id: ProviderID
  public var displayName: String
  public var capabilities: ProviderCapabilities

  public init(
    id: ProviderID,
    displayName: String,
    capabilities: ProviderCapabilities = []
  ) {
    self.id = id
    self.displayName = displayName
    self.capabilities = capabilities
  }
}

public struct ModelDescriptor: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var displayName: String
  public var ownedBy: String?
  public var capabilities: ProviderCapabilities
  /// Modalities explicitly declared by the model catalog. Nil means unknown.
  public var inputModalities: Set<String>?

  public init(
    id: String,
    displayName: String? = nil,
    ownedBy: String? = nil,
    capabilities: ProviderCapabilities = [],
    inputModalities: Set<String>? = nil
  ) {
    self.id = id
    self.displayName = displayName ?? id
    self.ownedBy = ownedBy
    self.capabilities = capabilities
    self.inputModalities = inputModalities
  }

  private enum CodingKeys: String, CodingKey {
    case id, displayName, ownedBy, capabilities, inputModalities
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decode(String.self, forKey: .id)
    self.init(
      id: id,
      displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
      ownedBy: try container.decodeIfPresent(String.self, forKey: .ownedBy),
      capabilities: try container.decodeIfPresent(
        ProviderCapabilities.self, forKey: .capabilities) ?? [],
      inputModalities: try container.decodeIfPresent(
        Set<String>.self, forKey: .inputModalities))
  }
}

public enum JSONValue: Codable, Equatable, Sendable {
  case object([String: JSONValue])
  case array([JSONValue])
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
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else if let value = try? container.decode([JSONValue].self) {
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

  public static func object(_ pairs: (String, JSONValue)...) -> JSONValue {
    .object(Dictionary(uniqueKeysWithValues: pairs))
  }

  public var objectValue: [String: JSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  public var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  public var arrayValue: [JSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  public var intValue: Int? {
    switch self {
    case .integer(let value): value
    case .number(let value) where value.rounded() == value: Int(value)
    default: nil
    }
  }

  public var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  public var numberValue: Double? {
    switch self {
    case .integer(let value): Double(value)
    case .number(let value): value
    default: nil
    }
  }

  public var compactJSONString: String {
    guard let data = try? JSONEncoder().encode(self),
      let string = String(data: data, encoding: .utf8)
    else { return "null" }
    return string
  }
}

public enum AgentRole: String, Codable, Sendable {
  case system
  case developer
  case user
  case assistant
  case tool
}

public enum ImageDetail: String, Codable, Sendable {
  case automatic = "auto"
  case low
  case high
}

public enum BinarySource: Codable, Equatable, Sendable {
  case data(Data)
  case url(URL)
}

public struct ImageContent: Codable, Equatable, Sendable {
  public var source: BinarySource
  public var mimeType: String
  public var name: String?
  public var width: Int?
  public var height: Int?
  public var detail: ImageDetail

  public init(
    source: BinarySource,
    mimeType: String,
    name: String? = nil,
    width: Int? = nil,
    height: Int? = nil,
    detail: ImageDetail = .automatic
  ) {
    self.source = source
    self.mimeType = mimeType
    self.name = name
    self.width = width
    self.height = height
    self.detail = detail
  }
}

public struct FileContent: Codable, Equatable, Sendable {
  public var source: BinarySource?
  public var text: String?
  public var mimeType: String
  public var name: String

  public init(
    name: String,
    mimeType: String,
    source: BinarySource? = nil,
    text: String? = nil
  ) {
    self.source = source
    self.text = text
    self.mimeType = mimeType
    self.name = name
  }
}

public struct AudioContent: Codable, Equatable, Sendable {
  public var source: BinarySource
  public var mimeType: String
  public var name: String?

  public init(source: BinarySource, mimeType: String, name: String? = nil) {
    self.source = source
    self.mimeType = mimeType
    self.name = name
  }
}

public struct ResourceContent: Codable, Equatable, Sendable {
  public var uri: String
  public var name: String?
  public var mimeType: String?
  public var text: String?
  public var blob: Data?

  public init(
    uri: String,
    name: String? = nil,
    mimeType: String? = nil,
    text: String? = nil,
    blob: Data? = nil
  ) {
    self.uri = uri
    self.name = name
    self.mimeType = mimeType
    self.text = text
    self.blob = blob
  }
}

public struct ToolCall: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var arguments: JSONValue

  public init(id: String, name: String, arguments: JSONValue) {
    self.id = id
    self.name = name
    self.arguments = arguments
  }
}

public struct ToolResult: Codable, Equatable, Sendable {
  public var callID: String
  public var content: [ContentPart]
  public var structuredContent: JSONValue?
  public var isError: Bool

  public init(
    callID: String,
    content: [ContentPart],
    structuredContent: JSONValue? = nil,
    isError: Bool = false
  ) {
    self.callID = callID
    self.content = content
    self.structuredContent = structuredContent
    self.isError = isError
  }

  public init(callID: String, text: String, isError: Bool = false) {
    self.init(callID: callID, content: [.text(text)], isError: isError)
  }

  public var text: String {
    content.compactMap(\.textValue).joined(separator: "\n")
  }
}

public enum ContentPart: Codable, Equatable, Sendable {
  case text(String)
  case image(ImageContent)
  case file(FileContent)
  case audio(AudioContent)
  case resource(ResourceContent)
  case reasoning(String)
  case toolCall(ToolCall)
  case toolResult(ToolResult)

  public var textValue: String? {
    switch self {
    case .text(let value), .reasoning(let value): value
    case .file(let value): value.text
    case .resource(let value): value.text
    case .toolResult(let value): value.text
    case .image, .audio, .toolCall: nil
    }
  }
}

public struct AgentMessage: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var role: AgentRole
  public var content: [ContentPart]

  public init(
    id: String = UUID().uuidString,
    role: AgentRole,
    content: [ContentPart]
  ) {
    self.id = id
    self.role = role
    self.content = content
  }

  public init(id: String = UUID().uuidString, role: AgentRole, content: String) {
    self.init(id: id, role: role, content: [.text(content)])
  }

  public static func system(_ content: String) -> AgentMessage {
    AgentMessage(role: .system, content: content)
  }

  public static func developer(_ content: String) -> AgentMessage {
    AgentMessage(role: .developer, content: content)
  }

  public static func user(_ content: String) -> AgentMessage {
    AgentMessage(role: .user, content: content)
  }

  public static func assistant(_ content: String) -> AgentMessage {
    AgentMessage(role: .assistant, content: content)
  }

  public var text: String {
    content.compactMap { part -> String? in
      switch part {
      case .text(let value): value
      case .file(let value): value.text
      case .resource(let value): value.text
      default: nil
      }
    }.joined(separator: "\n")
  }

  public var reasoning: String {
    content.compactMap { part in
      guard case .reasoning(let value) = part else { return nil }
      return value
    }.joined()
  }

  public var toolCalls: [ToolCall] {
    content.compactMap { part in
      guard case .toolCall(let value) = part else { return nil }
      return value
    }
  }

  public var toolResults: [ToolResult] {
    content.compactMap { part in
      guard case .toolResult(let value) = part else { return nil }
      return value
    }
  }
}

public struct TokenUsage: Codable, Equatable, Sendable {
  public var inputTokens: Int
  public var outputTokens: Int
  public var totalTokens: Int
  public var cachedTokens: Int?
  public var reasoningTokens: Int?

  public init(
    inputTokens: Int,
    outputTokens: Int,
    totalTokens: Int? = nil,
    cachedTokens: Int? = nil,
    reasoningTokens: Int? = nil
  ) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.totalTokens = totalTokens ?? inputTokens + outputTokens
    self.cachedTokens = cachedTokens
    self.reasoningTokens = reasoningTokens
  }
}

public struct ToolCallDelta: Codable, Equatable, Sendable {
  public var index: Int
  public var id: String?
  public var name: String?
  public var argumentsFragment: String

  public init(index: Int, id: String? = nil, name: String? = nil, argumentsFragment: String = "") {
    self.index = index
    self.id = id
    self.name = name
    self.argumentsFragment = argumentsFragment
  }
}

public enum ProviderEvent: Codable, Equatable, Sendable {
  case textDelta(String)
  case reasoningDelta(String)
  case toolCallDelta(ToolCallDelta)
  case usage(TokenUsage)
}

public enum ProviderStopReason: String, Codable, Sendable {
  case stop
  case length
  case toolCall
  case contentFilter
  case cancelled
  case unknown
}

public enum ToolChoice: Codable, Equatable, Sendable {
  case automatic
  case none
  case required
  case tool(String)

  public init(from decoder: Decoder) throws {
    let value = try JSONValue(from: decoder)
    if let string = value.stringValue {
      switch string {
      case "auto", "automatic": self = .automatic
      case "none": self = .none
      case "required": self = .required
      default:
        throw DecodingError.dataCorrupted(
          .init(
            codingPath: decoder.codingPath, debugDescription: "Unknown tool choice '\(string)'."))
      }
      return
    }
    if let name = value.objectValue?["tool"]?.stringValue {
      self = .tool(name)
      return
    }
    throw DecodingError.dataCorrupted(
      .init(codingPath: decoder.codingPath, debugDescription: "Invalid tool choice."))
  }

  public func encode(to encoder: Encoder) throws {
    switch self {
    case .automatic: try JSONValue.string("auto").encode(to: encoder)
    case .none: try JSONValue.string("none").encode(to: encoder)
    case .required: try JSONValue.string("required").encode(to: encoder)
    case .tool(let name): try JSONValue.object(["tool": .string(name)]).encode(to: encoder)
    }
  }
}

public enum ToolCallingStrategy: String, Codable, Equatable, Sendable {
  case automatic
  case native
  case text
  case xml
  case json
}

public enum ResponseFormat: Codable, Equatable, Sendable {
  case text
  case jsonObject
  case jsonSchema(name: String, schema: JSONValue, strict: Bool)

  public init(from decoder: Decoder) throws {
    let value = try JSONValue(from: decoder)
    if let string = value.stringValue {
      switch string {
      case "text": self = .text
      case "json", "jsonObject": self = .jsonObject
      default:
        throw DecodingError.dataCorrupted(
          .init(codingPath: decoder.codingPath, debugDescription: "Unknown response format."))
      }
      return
    }
    guard let object = value.objectValue,
      object["type"]?.stringValue == "jsonSchema",
      let name = object["name"]?.stringValue,
      let schema = object["schema"]
    else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Invalid response format."))
    }
    self = .jsonSchema(name: name, schema: schema, strict: object["strict"]?.boolValue ?? true)
  }

  public func encode(to encoder: Encoder) throws {
    switch self {
    case .text:
      try JSONValue.string("text").encode(to: encoder)
    case .jsonObject:
      try JSONValue.string("jsonObject").encode(to: encoder)
    case .jsonSchema(let name, let schema, let strict):
      try JSONValue.object([
        "type": .string("jsonSchema"),
        "name": .string(name),
        "schema": schema,
        "strict": .bool(strict),
      ]).encode(to: encoder)
    }
  }
}

public struct GenerationOptions: Codable, Equatable, Sendable {
  public var temperature: Double?
  public var maxOutputTokens: Int?
  public var reasoningEffort: String?
  public var includeStreamUsage: Bool
  public var additional: [String: JSONValue]

  public init(
    temperature: Double? = nil,
    maxOutputTokens: Int? = nil,
    reasoningEffort: String? = nil,
    includeStreamUsage: Bool = true,
    additional: [String: JSONValue] = [:]
  ) {
    self.temperature = temperature
    self.maxOutputTokens = maxOutputTokens
    self.reasoningEffort = reasoningEffort
    self.includeStreamUsage = includeStreamUsage
    self.additional = additional
  }

  private enum CodingKeys: String, CodingKey {
    case temperature, maxOutputTokens, reasoningEffort, includeStreamUsage, additional
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      temperature: try container.decodeIfPresent(Double.self, forKey: .temperature),
      maxOutputTokens: try container.decodeIfPresent(Int.self, forKey: .maxOutputTokens),
      reasoningEffort: try container.decodeIfPresent(String.self, forKey: .reasoningEffort),
      includeStreamUsage: try container.decodeIfPresent(Bool.self, forKey: .includeStreamUsage)
        ?? true,
      additional: try container.decodeIfPresent(
        [String: JSONValue].self,
        forKey: .additional) ?? [:])
  }
}

public struct ProviderRequest: Codable, Sendable {
  public var model: String
  public var messages: [AgentMessage]
  public var tools: [ToolDefinition]
  public var toolChoice: ToolChoice
  public var responseFormat: ResponseFormat
  public var options: GenerationOptions
  public var stream: Bool

  public init(
    model: String,
    messages: [AgentMessage],
    tools: [ToolDefinition] = [],
    toolChoice: ToolChoice = .automatic,
    responseFormat: ResponseFormat = .text,
    options: GenerationOptions = .init(),
    stream: Bool = true
  ) {
    self.model = model
    self.messages = messages
    self.tools = tools
    self.toolChoice = toolChoice
    self.responseFormat = responseFormat
    self.options = options
    self.stream = stream
  }
}

public struct ProviderResponse: Codable, Equatable, Sendable {
  public var message: AgentMessage
  public var usage: TokenUsage?
  public var stopReason: ProviderStopReason

  public init(
    message: AgentMessage,
    usage: TokenUsage? = nil,
    stopReason: ProviderStopReason = .unknown
  ) {
    self.message = message
    self.usage = usage
    self.stopReason = stopReason
  }

  public var reasoning: String { message.reasoning }
}

public struct AgentRunLimits: Codable, Equatable, Sendable {
  public var maxModelTurns: Int
  public var maxToolCalls: Int
  public var maxSubagents: Int
  public var maxSubagentDepth: Int
  public var maxTotalTokens: Int?

  public init(
    maxModelTurns: Int = 12,
    maxToolCalls: Int = 20,
    maxSubagents: Int = 4,
    maxSubagentDepth: Int = 2,
    maxTotalTokens: Int? = nil
  ) {
    self.maxModelTurns = max(1, maxModelTurns)
    self.maxToolCalls = max(0, maxToolCalls)
    self.maxSubagents = max(0, maxSubagents)
    self.maxSubagentDepth = max(0, maxSubagentDepth)
    self.maxTotalTokens = maxTotalTokens.map { max(1, $0) }
  }

  private enum CodingKeys: String, CodingKey {
    case maxModelTurns, maxToolCalls, maxSubagents, maxSubagentDepth, maxTotalTokens
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      maxModelTurns: try container.decodeIfPresent(Int.self, forKey: .maxModelTurns) ?? 12,
      maxToolCalls: try container.decodeIfPresent(Int.self, forKey: .maxToolCalls) ?? 20,
      maxSubagents: try container.decodeIfPresent(Int.self, forKey: .maxSubagents) ?? 4,
      maxSubagentDepth: try container.decodeIfPresent(Int.self, forKey: .maxSubagentDepth) ?? 2,
      maxTotalTokens: try container.decodeIfPresent(Int.self, forKey: .maxTotalTokens))
  }
}

public struct AgentDefinition: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var displayName: String
  public var instructions: String
  public var provider: ProviderID
  public var model: String
  public var toolNames: Set<String>
  public var subagentNames: Set<String>
  public var stream: Bool
  public var limits: AgentRunLimits
  public var toolChoice: ToolChoice
  public var responseFormat: ResponseFormat
  public var options: GenerationOptions
  public var toolCallingStrategy: ToolCallingStrategy

  public init(
    id: String,
    displayName: String? = nil,
    instructions: String,
    provider: ProviderID,
    model: String,
    toolNames: Set<String> = [],
    subagentNames: Set<String> = [],
    stream: Bool = true,
    limits: AgentRunLimits = .init(),
    toolChoice: ToolChoice = .automatic,
    responseFormat: ResponseFormat = .text,
    options: GenerationOptions = .init(),
    toolCallingStrategy: ToolCallingStrategy = .automatic
  ) {
    self.id = id
    self.displayName = displayName ?? id
    self.instructions = instructions
    self.provider = provider
    self.model = model
    self.toolNames = toolNames
    self.subagentNames = subagentNames
    self.stream = stream
    self.limits = limits
    self.toolChoice = toolChoice
    self.responseFormat = responseFormat
    self.options = options
    self.toolCallingStrategy = toolCallingStrategy
  }

  private enum CodingKeys: String, CodingKey {
    case id, displayName, instructions, provider, model, toolNames, subagentNames, stream, limits
    case toolChoice, responseFormat, options, toolCallingStrategy
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decode(String.self, forKey: .id)
    self.init(
      id: id,
      displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
      instructions: try container.decodeIfPresent(String.self, forKey: .instructions) ?? "",
      provider: try container.decode(ProviderID.self, forKey: .provider),
      model: try container.decodeIfPresent(String.self, forKey: .model) ?? "",
      toolNames: try container.decodeIfPresent(Set<String>.self, forKey: .toolNames) ?? [],
      subagentNames: try container.decodeIfPresent(Set<String>.self, forKey: .subagentNames) ?? [],
      stream: try container.decodeIfPresent(Bool.self, forKey: .stream) ?? true,
      limits: try container.decodeIfPresent(AgentRunLimits.self, forKey: .limits) ?? .init(),
      toolChoice: try container.decodeIfPresent(ToolChoice.self, forKey: .toolChoice) ?? .automatic,
      responseFormat: try container.decodeIfPresent(ResponseFormat.self, forKey: .responseFormat)
        ?? .text,
      options: try container.decodeIfPresent(GenerationOptions.self, forKey: .options) ?? .init(),
      toolCallingStrategy: try container.decodeIfPresent(
        ToolCallingStrategy.self,
        forKey: .toolCallingStrategy) ?? .automatic)
  }
}

public struct AgentRequest: Sendable {
  public var agentID: String
  public var provider: ProviderID
  public var model: String
  public var messages: [AgentMessage]
  public var toolNames: Set<String>
  public var subagentNames: Set<String>
  public var toolChoice: ToolChoice
  public var responseFormat: ResponseFormat
  public var options: GenerationOptions
  public var limits: AgentRunLimits
  public var stream: Bool
  public var toolCallingStrategy: ToolCallingStrategy

  public init(
    agentID: String = "main",
    provider: ProviderID,
    model: String = "",
    messages: [AgentMessage],
    toolNames: Set<String> = [],
    subagentNames: Set<String> = [],
    toolChoice: ToolChoice = .automatic,
    responseFormat: ResponseFormat = .text,
    options: GenerationOptions = .init(),
    limits: AgentRunLimits = .init(),
    stream: Bool = true,
    toolCallingStrategy: ToolCallingStrategy = .automatic
  ) {
    self.agentID = agentID
    self.provider = provider
    self.model = model
    self.messages = messages
    self.toolNames = toolNames
    self.subagentNames = subagentNames
    self.toolChoice = toolChoice
    self.responseFormat = responseFormat
    self.options = options
    self.limits = limits
    self.stream = stream
    self.toolCallingStrategy = toolCallingStrategy
  }
}

public struct AgentResult: Equatable, Sendable {
  public var runID: UUID
  public var agentID: String
  public var provider: ProviderID
  public var response: AgentMessage
  public var transcript: [AgentMessage]
  public var usage: TokenUsage?
  public var stopReason: ProviderStopReason
  public var modelTurns: Int
  public var toolCalls: Int

  public init(
    runID: UUID,
    agentID: String,
    provider: ProviderID,
    response: AgentMessage,
    transcript: [AgentMessage],
    usage: TokenUsage?,
    stopReason: ProviderStopReason,
    modelTurns: Int,
    toolCalls: Int
  ) {
    self.runID = runID
    self.agentID = agentID
    self.provider = provider
    self.response = response
    self.transcript = transcript
    self.usage = usage
    self.stopReason = stopReason
    self.modelTurns = modelTurns
    self.toolCalls = toolCalls
  }

  public var reasoning: String { response.reasoning }
}

public struct AgentEventContext: Codable, Equatable, Sendable {
  public var runID: UUID
  public var parentRunID: UUID?
  public var agentID: String
  public var depth: Int

  public init(runID: UUID, parentRunID: UUID?, agentID: String, depth: Int) {
    self.runID = runID
    self.parentRunID = parentRunID
    self.agentID = agentID
    self.depth = depth
  }
}

public enum AgentEvent: Equatable, Sendable {
  case started(AgentEventContext, ProviderDescriptor)
  case modelStarted(AgentEventContext, turn: Int)
  case provider(AgentEventContext, ProviderEvent)
  case approvalRequested(AgentEventContext, ApprovalRequest)
  case approvalDecided(AgentEventContext, ApprovalDecision)
  case toolStarted(AgentEventContext, ToolCall)
  case toolFinished(AgentEventContext, ToolResult)
  case childStarted(AgentEventContext, child: AgentEventContext)
  case childFinished(AgentEventContext, child: AgentResult)
  case finished(AgentEventContext, AgentResult)
}

public typealias ProviderEventHandler = @Sendable (ProviderEvent) async -> Void
public typealias AgentEventHandler = @Sendable (AgentEvent) async -> Void
