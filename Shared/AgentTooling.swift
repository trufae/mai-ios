import CoreFoundation
import Foundation

struct ToolDefinition: Sendable {
  let name: String
  let description: String
  let parameters: [ToolParameterDef]
  let inputSchemaJSON: String

  init(
    name: String,
    description: String,
    parameters: [ToolParameterDef],
    inputSchemaJSON: String = ""
  ) {
    self.name = name
    self.description = description
    self.parameters = parameters
    self.inputSchemaJSON = inputSchemaJSON
  }
}

struct ToolParameterDef: Sendable {
  let name: String
  let type: String
  let description: String
  let required: Bool
}

enum AgentToolArgumentValue: Sendable {
  case string(String)
  case bool(Bool)
  case int(Int)
  case double(Double)
  case object([String: AgentToolArgumentValue])
  case array([AgentToolArgumentValue])
  case null

  init(json: Any) {
    switch json {
    case let bool as Bool:
      self = .bool(bool)
    case let int as Int:
      self = .int(int)
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        self = .bool(number.boolValue)
      } else {
        let double = number.doubleValue
        self = double.rounded() == double ? .int(number.intValue) : .double(double)
      }
    case let double as Double:
      self = double.rounded() == double ? .int(Int(double)) : .double(double)
    case let string as String:
      self = .string(string)
    case let object as [String: Any]:
      self = .object(object.mapValues { AgentToolArgumentValue(json: $0) })
    case let array as [Any]:
      self = .array(array.map { AgentToolArgumentValue(json: $0) })
    default:
      self = .null
    }
  }

  var stringValue: String {
    switch self {
    case .string(let value): return value
    case .bool(let value): return value ? "true" : "false"
    case .int(let value): return String(value)
    case .double(let value): return String(value)
    case .object, .array:
      guard
        let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys]),
        let string = String(data: data, encoding: .utf8)
      else { return "" }
      return string
    case .null: return ""
    }
  }

  var numberValue: Double? {
    switch self {
    case .int(let value): return Double(value)
    case .double(let value): return value
    case .string(let value): return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
    default: return nil
    }
  }

  var boolValue: Bool? {
    switch self {
    case .bool(let value): return value
    case .int(let value) where value == 0 || value == 1: return value == 1
    case .string(let value):
      switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "true", "1", "yes": return true
      case "false", "0", "no": return false
      default: return nil
      }
    default: return nil
    }
  }

  var jsonObject: Any {
    switch self {
    case .string(let value): return value
    case .bool(let value): return value
    case .int(let value): return value
    case .double(let value): return value
    case .object(let value): return value.mapValues(\.jsonObject)
    case .array(let value): return value.map(\.jsonObject)
    case .null: return NSNull()
    }
  }
}

struct ParsedToolCall: Identifiable, Sendable {
  let id = UUID()
  let name: String
  let arguments: [String: String]
  let argumentValues: [String: AgentToolArgumentValue]
  let rawBlock: String
  let argsJSON: String
  let toolCallID: String?
  let apiName: String?

  init(
    name: String,
    arguments: [String: String],
    argumentValues: [String: AgentToolArgumentValue]? = nil,
    rawBlock: String,
    argsJSON: String? = nil,
    toolCallID: String? = nil,
    apiName: String? = nil
  ) {
    self.name = name
    let values = argumentValues ?? arguments.mapValues { AgentToolArgumentValue.string($0) }
    self.argumentValues = values
    self.arguments = values.mapValues(\.stringValue)
    self.rawBlock = rawBlock
    self.argsJSON = argsJSON ?? AgentTooling.compactJSON(values)
    self.toolCallID = toolCallID
    self.apiName = apiName
  }
}

struct AgentNativeToolCall: Sendable {
  let id: String
  let name: String
  let arguments: [String: String]
  let argumentValues: [String: AgentToolArgumentValue]
  let rawArguments: String

  var textBlock: String {
    let payload: [String: Any] = [
      "name": name,
      "arguments": argumentValues.mapValues(\.jsonObject),
    ]
    guard
      let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
      let json = String(data: data, encoding: .utf8)
    else { return "" }
    return "<tool_call>\(json)</tool_call>"
  }
}

struct AgentToolNameResolver {
  private let canonicalByAlias: [String: String]
  private let canonicalByShortAlias: [String: String]
  private let apiByCanonical: [String: String]

  init(tools: [ToolDefinition]) {
    var aliases: [String: String] = [:]
    var shortAliases: [String: String] = [:]
    var ambiguousShortAliases = Set<String>()
    var apiNames: [String: String] = [:]
    var usedAPI = Set<String>()

    for tool in tools {
      let api = Self.uniqueAPIName(for: tool.name, used: &usedAPI)
      apiNames[tool.name] = api
      let candidates = [
        tool.name,
        api,
        tool.name.replacingOccurrences(of: "::", with: "."),
        tool.name.replacingOccurrences(of: "::", with: "_"),
        tool.name.replacingOccurrences(of: "::", with: "__"),
      ]
      for candidate in candidates {
        aliases[Self.key(candidate)] = tool.name
        let candidateShortKey = Self.shortKey(candidate)
        if let existing = shortAliases[candidateShortKey], existing != tool.name {
          ambiguousShortAliases.insert(candidateShortKey)
        } else {
          shortAliases[candidateShortKey] = tool.name
        }
      }
      let shortKey = Self.shortKey(tool.name)
      if let existing = shortAliases[shortKey], existing != tool.name {
        ambiguousShortAliases.insert(shortKey)
      } else {
        shortAliases[shortKey] = tool.name
      }
    }
    for key in ambiguousShortAliases {
      shortAliases.removeValue(forKey: key)
    }

    canonicalByAlias = aliases
    canonicalByShortAlias = shortAliases
    apiByCanonical = apiNames
  }

  func canonicalName(for name: String) -> String? {
    canonicalByAlias[Self.key(name)] ?? canonicalByShortAlias[Self.shortKey(name)]
  }

  func apiName(for canonical: String) -> String {
    apiByCanonical[canonical] ?? Self.sanitizeAPIName(canonical)
  }

  private static func key(_ name: String) -> String {
    name
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .filter { $0.isLetter || $0.isNumber }
  }

  private static func shortKey(_ name: String) -> String {
    let normalized = name.replacingOccurrences(of: "::", with: ".")
    guard let last = normalized.split(separator: ".").last else { return key(name) }
    return key(String(last))
  }

  private static func uniqueAPIName(for name: String, used: inout Set<String>) -> String {
    let base = sanitizeAPIName(name)
    var candidate = base
    var n = 2
    while used.contains(candidate) {
      candidate = "\(base)_\(n)"
      n += 1
    }
    used.insert(candidate)
    return candidate
  }

  private static func sanitizeAPIName(_ name: String) -> String {
    var out = ""
    var lastWasUnderscore = false
    for scalar in name.unicodeScalars {
      let isAllowed =
        CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
      if isAllowed {
        out.unicodeScalars.append(scalar)
        lastWasUnderscore = false
      } else if !lastWasUnderscore {
        out.append("_")
        lastWasUnderscore = true
      }
    }
    out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
    if out.isEmpty { out = "tool" }
    if out.first?.isNumber == true { out = "tool_\(out)" }
    if out.count > 64 {
      out = String(out.prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
    }
    return out
  }
}

enum AgentTooling {
  static func firstNonEmpty(_ values: String?...) -> String? {
    for value in values {
      let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !trimmed.isEmpty { return trimmed }
    }
    return nil
  }

  static func promptDescription(
    for definitions: [ToolDefinition],
    mode: ToolCallingMode = .text
  ) -> String {
    guard !definitions.isEmpty else { return "" }
    let resolver = AgentToolNameResolver(tools: definitions)
    let toolDescriptions = definitions.map { def -> String in
      let params: String
      if def.parameters.isEmpty {
        params = "no arguments"
      } else {
        let required = def.parameters.filter(\.required)
        let optional = def.parameters.filter { !$0.required }
        let requiredText =
          required.isEmpty
          ? "no required arguments"
          : required.map { p in
            "\(p.name) (\(p.type)): \(p.description)"
          }.joined(separator: "; ")
        let optionalText =
          optional.isEmpty
          ? ""
          : " Optional arguments, omit unless necessary: "
            + optional.map { p in
              "\(p.name) (\(p.type)): \(p.description)"
            }.joined(separator: "; ")
        params = requiredText + optionalText
      }
      let api = resolver.apiName(for: def.name)
      let name = api == def.name ? def.name : "\(def.name) (API/native alias: \(api))"
      return "- \(name): \(def.description) Arguments: \(params)."
    }.joined(separator: "\n")
    let toolCalling = promptInstructions(for: mode)

    return """
      ## Available Tools

      \(toolDescriptions)

      ## Tool Calling

      \(toolCalling)

      When the host returns a `<tool_run>` result, use that result as ground truth. If more tool work is needed, emit the next single tool call in the same format; otherwise answer normally with no tool call.
      """
  }

  private static func promptInstructions(for mode: ToolCallingMode) -> String {
    switch mode.textProtocolFallback {
    case .text:
      return """
        When a tool is needed, reply with exactly one plain text block and no other text:
        TOOL_CALL
        tool: tool_name
        required_arg: value
        END_TOOL_CALL

        Use only listed tool names or aliases. Put one argument per line as `argument_name: value`. Include required arguments, omit unused optional arguments, use true/false for booleans, and stop after the block.
        """
    case .xml:
      return """
        When a tool is needed, reply with exactly one XML block and no other text:
        <tool_call name="tool_name">
        <arg name="required_arg">value</arg>
        </tool_call>

        Use only listed tool names or aliases. Include required arguments, omit unused optional arguments, escape XML special characters, and stop after the block.
        """
    case .json:
      return """
        When a tool is needed, reply with exactly one JSON object and no other text:
        {"name":"tool_name","arguments":{"required_arg":"value"}}

        Use only listed tool names or aliases. Include required arguments, omit unused optional arguments, keep JSON valid, and stop after the JSON object.
        """
    case .native:
      return promptInstructions(for: .text)
    }
  }

  static func parseCalls(
    in text: String,
    tools: [ToolDefinition],
    mode: ToolCallingMode = .text
  ) -> [ParsedToolCall] {
    switch mode {
    case .text:
      let calls = parsePlainTextCalls(in: text, tools: tools)
      return calls.isEmpty ? [] : calls
    case .xml:
      return parseXMLCalls(in: text, tools: tools)
    case .json:
      return parseJSONCall(in: text).map { [$0] } ?? []
    case .native:
      return parseXMLCalls(in: text, tools: tools)
    }
  }

  private static func parseXMLCalls(in text: String, tools: [ToolDefinition]) -> [ParsedToolCall] {
    let pattern = "<tool_call\\b([^>]*)>([\\s\\S]*?)(?:</tool_call\\s*>|$)"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    else { return [] }
    let nsText = text as NSString
    let matches = regex.matches(
      in: text, options: [], range: NSRange(location: 0, length: nsText.length))
    var calls: [ParsedToolCall] = []
    for match in matches {
      guard match.numberOfRanges == 3 else { continue }
      let raw = nsText.substring(with: match.range(at: 0))
      let attributes = nsText.substring(with: match.range(at: 1))
      let payload = nsText.substring(with: match.range(at: 2))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if let call = parseToolCallPayload(payload, attributes: attributes, rawBlock: raw) {
        calls.append(call)
      }
    }
    if !calls.isEmpty { return calls }
    return parseJSONCall(in: text).map { [$0] } ?? []
  }

  private static func parsePlainTextCalls(
    in text: String,
    tools: [ToolDefinition]
  ) -> [ParsedToolCall] {
    let pattern = "(?im)^\\s*TOOL_CALL\\s*$([\\s\\S]*?)(?:^\\s*END_TOOL_CALL\\s*$|\\z)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let nsText = text as NSString
    let matches = regex.matches(
      in: text, options: [], range: NSRange(location: 0, length: nsText.length))

    return matches.compactMap { match in
      guard match.numberOfRanges == 2 else { return nil }
      let raw = nsText.substring(with: match.range(at: 0))
      let body = nsText.substring(with: match.range(at: 1))
      return parsePlainTextToolCallBlock(body, rawBlock: raw, tools: tools)
    }
  }

  private static func parsePlainTextToolCallBlock(
    _ body: String,
    rawBlock: String,
    tools: [ToolDefinition]
  ) -> ParsedToolCall? {
    let lines = body.components(separatedBy: .newlines)
    let nameKeys = Set(["tool", "name", "function"])
    let name = lines.compactMap { line -> String? in
      guard let pair = lineKeyValue(line), nameKeys.contains(pair.key.lowercased()) else {
        return nil
      }
      let trimmed = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }.first
    guard let name else { return nil }

    let resolver = AgentToolNameResolver(tools: tools)
    let canonical = resolver.canonicalName(for: name) ?? name
    let tool = tools.first { $0.name == canonical }
    let parameterNames = Set(tool?.parameters.map(\.name) ?? [])
    var arguments: [String: String] = [:]
    var currentKey: String?
    var currentValue: [String] = []

    func flush() {
      guard let currentKey else { return }
      arguments[currentKey] = currentValue.joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    for line in lines {
      guard let pair = lineKeyValue(line) else {
        if currentKey != nil { currentValue.append(line) }
        continue
      }
      let key = pair.key
      if nameKeys.contains(key.lowercased()) {
        continue
      }
      let isKnownArgument = parameterNames.isEmpty || parameterNames.contains(key)
      if isKnownArgument {
        flush()
        currentKey = key
        currentValue = [pair.value]
      } else if currentKey != nil {
        currentValue.append(line)
      }
    }
    flush()

    return ParsedToolCall(
      name: name,
      arguments: [:],
      argumentValues: arguments.mapValues { AgentToolArgumentValue.string($0) },
      rawBlock: rawBlock)
  }

  private static func lineKeyValue(_ line: String) -> (key: String, value: String)? {
    guard let colon = line.firstIndex(of: ":") else { return nil }
    let key = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
    else {
      return nil
    }
    let value = String(line[line.index(after: colon)...])
      .trimmingCharacters(in: .whitespaces)
    return (key, String(value))
  }

  static func containsToolCallMarker(
    in text: String,
    mode: ToolCallingMode? = nil
  ) -> Bool {
    let modes = mode.map { [$0] } ?? [.text, .xml, .native]
    return modes.contains { mode in
      switch mode {
      case .text:
        return text.range(
          of: "(?m)^\\s*TOOL_CALL\\s*$",
          options: [.regularExpression, .caseInsensitive]) != nil
      case .xml, .native:
        return text.range(
          of: "<\\s*/?\\s*tool_call\\b",
          options: [.regularExpression, .caseInsensitive]) != nil
      case .json:
        let visible = stripThinkBlocks(from: stripMarkdownFence(from: text))
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if let object = jsonObject(from: visible), strictToolCallObject(object) != nil {
          return true
        }
        return visible.hasPrefix("{")
          && containsJSONKey(in: visible, keys: ["name", "tool", "function"])
          && containsJSONKey(
            in: visible,
            keys: ["arguments", "args", "parameters", "params", "input"])
      }
    }
  }

  static func malformedToolCallFeedback(
    from text: String,
    mode: ToolCallingMode = .text
  ) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let preview = trimmed.count > 500 ? String(trimmed.prefix(500)) + "..." : trimmed
    let example: String
    switch mode.textProtocolFallback {
    case .text:
      example = """
        TOOL_CALL
        tool: tool_name
        END_TOOL_CALL
        """
    case .xml:
      example = #"<tool_call name="tool_name"></tool_call>"#
    case .json:
      example = #"{"name":"tool_name","arguments":{}}"#
    case .native:
      example = """
        TOOL_CALL
        tool: tool_name
        END_TOOL_CALL
        """
    }
    return """
      <tool_run>
      invalid_tool_call tool ({}):
      Error: the assistant emitted a tool call marker, but the host could not parse an executable tool call.

      Received:
      \(preview)

      Emit exactly one valid tool call in the configured \(mode.displayName) format, or answer normally without any tool call marker:
      \(example)
      </tool_run>
      """
  }

  static func normalizeArguments(
    _ arguments: [String: AgentToolArgumentValue],
    for tool: ToolDefinition?
  ) -> [String: AgentToolArgumentValue] {
    let normalized = normalizeValues(arguments, for: tool)
    guard let tool,
      tool.parameters.filter(\.required).count == 1,
      let requiredName = tool.parameters.first(where: \.required)?.name,
      normalized[requiredName] == nil,
      normalized.count == 1,
      let value = normalized.values.first
    else { return normalized }
    return [requiredName: value]
  }

  static func normalizeArguments(_ arguments: [String: String], for tool: ToolDefinition?)
    -> [String: String]
  {
    normalizeArguments(arguments.mapValues { .string($0) }, for: tool).mapValues(\.stringValue)
  }

  static func parameters(fromSchemaJSON schemaJSON: String) -> [ToolParameterDef] {
    guard !schemaJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let data = schemaJSON.data(using: .utf8),
      let schema = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let properties = schema["properties"] as? [String: Any]
    else { return [] }
    let required = Set(schema["required"] as? [String] ?? [])
    return properties.keys.sorted().map { name in
      let property = properties[name] as? [String: Any] ?? [:]
      return ToolParameterDef(
        name: name,
        type: (property["type"] as? String) ?? "string",
        description: (property["description"] as? String) ?? "",
        required: required.contains(name))
    }
  }

  static func makeRunBlock(toolName: String, argumentsJSON: String, result: String) -> String {
    let body = result.trimmingCharacters(in: .whitespacesAndNewlines)
    return "<tool_run>\n\(toolName) tool (\(argumentsJSON)):\n\(body)\n</tool_run>"
  }

  static func editableToolCallText(for call: ParsedToolCall, mode: ToolCallingMode) -> String {
    let raw = call.rawBlock.trimmingCharacters(in: .whitespacesAndNewlines)
    if !raw.isEmpty { return raw }

    switch mode {
    case .text:
      var lines = ["TOOL_CALL", "tool: \(call.name)"]
      for key in call.argumentValues.keys.sorted() {
        guard let value = call.argumentValues[key] else { continue }
        lines.append("\(key): \(value.stringValue)")
      }
      lines.append("END_TOOL_CALL")
      return lines.joined(separator: "\n")
    case .xml, .native:
      return "<tool_call>\(toolCallObjectJSON(for: call))</tool_call>"
    case .json:
      return toolCallObjectJSON(for: call)
    }
  }

  static func compactJSON(_ args: [String: String]) -> String {
    compactJSON(args.mapValues { .string($0) })
  }

  static func compactJSON(_ args: [String: AgentToolArgumentValue]) -> String {
    guard !args.isEmpty,
      let data = try? JSONSerialization.data(
        withJSONObject: args.mapValues(\.jsonObject), options: [.sortedKeys]),
      let s = String(data: data, encoding: .utf8)
    else { return "{}" }
    return s
  }

  private static func toolCallObjectJSON(for call: ParsedToolCall) -> String {
    let payload: [String: Any] = [
      "arguments": call.argumentValues.mapValues(\.jsonObject),
      "name": call.name,
    ]
    guard
      let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
      let json = String(data: data, encoding: .utf8)
    else { return #"{"arguments":{},"name":"\#(call.name)"}"# }
    return json
  }

  static func argumentValues(_ args: [String: Any]) -> [String: AgentToolArgumentValue] {
    args.mapValues { AgentToolArgumentValue(json: $0) }
  }

  private static func normalizeValues(
    _ arguments: [String: AgentToolArgumentValue],
    for tool: ToolDefinition?
  ) -> [String: AgentToolArgumentValue] {
    guard let tool else {
      return arguments.filter { _, value in
        if case .null = value { return false }
        return true
      }
    }
    let parameterByName = Dictionary(uniqueKeysWithValues: tool.parameters.map { ($0.name, $0) })
    var result: [String: AgentToolArgumentValue] = [:]
    for (name, value) in arguments {
      guard let parameter = parameterByName[name] else {
        result[name] = value
        continue
      }
      guard let normalized = normalizeValue(value, for: parameter) else {
        continue
      }
      if !parameter.required, isDefaultOptionalValue(normalized, for: parameter) {
        continue
      }
      result[name] = normalized
    }
    return result
  }

  private static func normalizeValue(
    _ value: AgentToolArgumentValue,
    for parameter: ToolParameterDef
  ) -> AgentToolArgumentValue? {
    if case .null = value { return nil }
    switch parameter.type.lowercased() {
    case "integer", "int":
      if case .int = value { return value }
      if let number = value.numberValue, number.rounded() == number {
        return .int(Int(number))
      }
      return parameter.required ? value : nil
    case "number":
      if case .int = value { return value }
      if let number = value.numberValue {
        return number.rounded() == number ? .int(Int(number)) : .double(number)
      }
      return parameter.required ? value : nil
    case "boolean", "bool":
      return value.boolValue.map(AgentToolArgumentValue.bool) ?? (parameter.required ? value : nil)
    case "string":
      if case .string = value { return value }
      return parameter.required ? .string(value.stringValue) : nil
    default:
      return value
    }
  }

  private static func isDefaultOptionalValue(
    _ value: AgentToolArgumentValue,
    for parameter: ToolParameterDef
  ) -> Bool {
    switch value {
    case .string(let string):
      return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .bool(let bool):
      return !bool
    case .int(let int):
      let description = parameter.description.lowercased()
      return description.contains("default: \(int)") || description.contains("default \(int)")
    case .double(let double):
      let description = parameter.description.lowercased()
      return description.contains("default: \(double)") || description.contains("default \(double)")
    default:
      return false
    }
  }

  static func nativeToolCalls(from acc: [Int: (id: String?, name: String?, args: String)])
    -> [AgentNativeToolCall]
  {
    acc.sorted(by: { $0.key < $1.key }).compactMap { _, e -> AgentNativeToolCall? in
      guard let name = e.name else { return nil }
      return makeNativeToolCall(id: e.id, name: name, rawArguments: e.args)
    }
  }

  static func makeNativeToolCall(id: String?, name: String, rawArguments: String)
    -> AgentNativeToolCall
  {
    var args: [String: AgentToolArgumentValue] = [:]
    if !rawArguments.isEmpty,
      let data = rawArguments.data(using: .utf8),
      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      args = argumentValues(parsed)
    }
    return AgentNativeToolCall(
      id: id ?? "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
      name: name,
      arguments: args.mapValues(\.stringValue),
      argumentValues: args,
      rawArguments: rawArguments.isEmpty ? "{}" : rawArguments)
  }

  private static func parseToolCallPayload(
    _ payload: String,
    attributes: String,
    rawBlock: String
  ) -> ParsedToolCall? {
    let attrs = toolCallAttributes(from: attributes)
    let attrName = firstNonEmpty(attrs["name"], attrs["tool"], attrs["function"])
    let attrArgs = firstNonEmpty(attrs["arguments"], attrs["args"], attrs["params"], attrs["input"])
    let normalizedPayload = stripMarkdownFence(from: payload)
    var candidates = [normalizedPayload]
    if let object = firstJSONObject(in: normalizedPayload), object != normalizedPayload {
      candidates.append(object)
    }
    if let attrArgs, !attrArgs.isEmpty {
      candidates.append(stripMarkdownFence(from: attrArgs))
    }

    for candidate in candidates {
      guard let object = jsonObject(from: candidate) else { continue }
      if let normalized = normalizeToolCallObject(object),
        let name = (normalized["name"] as? String)?
          .trimmingCharacters(in: .whitespacesAndNewlines),
        !name.isEmpty
      {
        let args = argumentValues(argumentsObject(from: normalized["arguments"]))
        return ParsedToolCall(name: name, arguments: [:], argumentValues: args, rawBlock: rawBlock)
      }
      if let attrName {
        return ParsedToolCall(
          name: attrName,
          arguments: [:],
          argumentValues: argumentValues(object),
          rawBlock: rawBlock)
      }
    }

    if let xmlCall = xmlToolCallPayload(normalizedPayload, attrName: attrName, rawBlock: rawBlock) {
      return xmlCall
    }

    if let attrName {
      return ParsedToolCall(name: attrName, arguments: [:], argumentValues: [:], rawBlock: rawBlock)
    }
    return nil
  }

  private static func xmlToolCallPayload(
    _ payload: String,
    attrName: String?,
    rawBlock: String
  ) -> ParsedToolCall? {
    let name =
      attrName
      ?? firstXMLValue(named: "name", in: payload)
      ?? firstXMLValue(named: "tool", in: payload)
      ?? firstXMLValue(named: "function", in: payload)
    guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
      return nil
    }
    return ParsedToolCall(
      name: name,
      arguments: [:],
      argumentValues: argumentValues(xmlArguments(from: payload)),
      rawBlock: rawBlock)
  }

  private static func xmlArguments(from payload: String) -> [String: Any] {
    var arguments: [String: Any] = [:]
    let nsPayload = payload as NSString

    if let argRegex = try? NSRegularExpression(
      pattern: #"<\s*arg\s+name\s*=\s*("[^"]*"|'[^']*'|[^\s"'>/]+)\s*>([\s\S]*?)<\s*/\s*arg\s*>"#,
      options: [.caseInsensitive])
    {
      let matches = argRegex.matches(
        in: payload, options: [], range: NSRange(location: 0, length: nsPayload.length))
      for match in matches where match.numberOfRanges == 3 {
        var name = nsPayload.substring(with: match.range(at: 1))
        if name.count >= 2,
          (name.hasPrefix("\"") && name.hasSuffix("\""))
            || (name.hasPrefix("'") && name.hasSuffix("'"))
        {
          name.removeFirst()
          name.removeLast()
        }
        arguments[name] = xmlUnescaped(nsPayload.substring(with: match.range(at: 2)))
      }
    }

    if let tagRegex = try? NSRegularExpression(
      pattern: #"<\s*([A-Za-z_][A-Za-z0-9_-]*)\s*>([\s\S]*?)<\s*/\s*\1\s*>"#,
      options: [.caseInsensitive])
    {
      let matches = tagRegex.matches(
        in: payload, options: [], range: NSRange(location: 0, length: nsPayload.length))
      let reserved = Set(["name", "tool", "function", "arguments", "args", "params", "input"])
      for match in matches where match.numberOfRanges == 3 {
        let name = nsPayload.substring(with: match.range(at: 1))
        guard !reserved.contains(name.lowercased()), arguments[name] == nil else { continue }
        arguments[name] = xmlUnescaped(nsPayload.substring(with: match.range(at: 2)))
      }
    }

    return arguments
  }

  private static func firstXMLValue(named name: String, in payload: String) -> String? {
    guard let regex = try? NSRegularExpression(
      pattern: #"<\s*\#(name)\s*>([\s\S]*?)<\s*/\s*\#(name)\s*>"#,
      options: [.caseInsensitive])
    else {
      return nil
    }
    let nsPayload = payload as NSString
    guard let match = regex.firstMatch(
      in: payload, options: [], range: NSRange(location: 0, length: nsPayload.length)),
      match.numberOfRanges == 2
    else {
      return nil
    }
    return xmlUnescaped(nsPayload.substring(with: match.range(at: 1)))
  }

  private static func xmlUnescaped(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&apos;", with: "'")
      .replacingOccurrences(of: "&amp;", with: "&")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func jsonObject(from text: String) -> [String: Any]? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = trimmed.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  private static func stripMarkdownFence(from text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("```") else { return trimmed }
    var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") == true {
      lines.removeFirst()
    }
    if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") == true {
      lines.removeLast()
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func firstJSONObject(in text: String) -> String? {
    var start: String.Index?
    var depth = 0
    var inString = false
    var escaped = false

    for index in text.indices {
      let char = text[index]
      if start == nil {
        guard char == "{" else { continue }
        start = index
        depth = 1
        continue
      }

      if inString {
        if escaped {
          escaped = false
        } else if char == "\\" {
          escaped = true
        } else if char == "\"" {
          inString = false
        }
        continue
      }

      if char == "\"" {
        inString = true
      } else if char == "{" {
        depth += 1
      } else if char == "}" {
        depth -= 1
        if depth == 0, let start {
          return String(text[start...index]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
      }
    }
    return nil
  }

  private static func toolCallAttributes(from text: String) -> [String: String] {
    let pattern = #"([A-Za-z_][A-Za-z0-9_:-]*)\s*=\s*("[^"]*"|'[^']*'|[^\s"'>/]+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
    let nsText = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
    var attrs: [String: String] = [:]
    for match in matches where match.numberOfRanges == 3 {
      let key = nsText.substring(with: match.range(at: 1)).lowercased()
      var value = nsText.substring(with: match.range(at: 2))
      if value.count >= 2,
        (value.hasPrefix("\"") && value.hasSuffix("\""))
          || (value.hasPrefix("'") && value.hasSuffix("'"))
      {
        value.removeFirst()
        value.removeLast()
      }
      attrs[key] = value
    }
    return attrs
  }

  private static func normalizeToolCallObject(_ object: [String: Any]) -> [String: Any]? {
    if let name = object["name"] as? String,
      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      if let nested = object["arguments"] as? [String: Any],
        let nestedName = nested["name"] as? String
      {
        return ["name": nestedName, "arguments": toolArguments(from: nested)]
      }
      return ["name": name, "arguments": toolArguments(from: object)]
    }
    if let name = (object["tool"] as? String) ?? (object["function"] as? String) {
      return [
        "name": name,
        "arguments": toolArguments(from: object),
      ]
    }
    if let function = object["function"] as? [String: Any],
      let name = function["name"] as? String,
      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return ["name": name, "arguments": toolArguments(from: function)]
    }
    return nil
  }

  private static func toolArguments(from object: [String: Any]) -> [String: Any] {
    for key in ["arguments", "args", "parameters", "params", "input"] {
      let args = argumentsObject(from: object[key])
      if !args.isEmpty { return args }
    }
    var args: [String: Any] = [:]
    var reserved = Set([
      "name", "tool", "function", "arguments", "args", "parameters", "params", "input",
    ])
    if (object["type"] as? String)?.lowercased() == "function" {
      reserved.formUnion(["id", "type"])
    }
    for (key, value) in object where !reserved.contains(key) {
      args[key] = value
    }
    return args
  }

  private static func parseJSONCall(in text: String) -> ParsedToolCall? {
    let rawBlock = stripThinkBlocks(from: text).trimmingCharacters(in: .whitespacesAndNewlines)
    let visible = stripMarkdownFence(from: rawBlock)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard visible.hasPrefix("{"), visible.hasSuffix("}"),
      let data = visible.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let normalized = strictToolCallObject(object)
    else { return nil }
    return ParsedToolCall(
      name: normalized.name,
      arguments: [:],
      argumentValues: argumentValues(normalized.arguments),
      rawBlock: rawBlock)
  }

  private static func strictToolCallObject(_ object: [String: Any])
    -> (name: String, arguments: [String: Any])?
  {
    if let function = object["function"] as? [String: Any],
      let name = nonEmptyString(function["name"]),
      let arguments = explicitArgumentsObject(from: function)
        ?? explicitArgumentsObject(from: object)
    {
      return (name, arguments)
    }
    if let name = nonEmptyString(object["name"])
      ?? nonEmptyString(object["tool"])
      ?? nonEmptyString(object["function"]),
      let arguments = explicitArgumentsObject(from: object)
    {
      return (name, arguments)
    }
    return nil
  }

  private static func nonEmptyString(_ value: Any?) -> String? {
    guard let string = value as? String else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func explicitArgumentsObject(from object: [String: Any]) -> [String: Any]? {
    for key in ["arguments", "args", "parameters", "params", "input"]
    where object.keys.contains(key) {
      if let argumentObject = object[key] as? [String: Any] {
        return argumentObject
      }
      if let string = object[key] as? String,
        let data = string.data(using: .utf8),
        let argumentObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      {
        return argumentObject
      }
    }
    return nil
  }

  private static func containsJSONKey(in text: String, keys: [String]) -> Bool {
    keys.contains { key in
      text.range(
        of: #""\#(NSRegularExpression.escapedPattern(for: key))"\s*:"#,
        options: [.regularExpression]) != nil
    }
  }

  private static func stripThinkBlocks(from text: String) -> String {
    let pattern = "<think>[\\s\\S]*?</think>"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    else { return text }
    let range = NSRange(location: 0, length: (text as NSString).length)
    return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
  }

  private static func argumentsObject(from value: Any?) -> [String: Any] {
    if let object = value as? [String: Any] {
      return object
    }
    if let string = value as? String,
      let data = string.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      return object
    }
    return [:]
  }
}
