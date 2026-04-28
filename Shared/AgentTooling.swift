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
        CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
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
  static func promptDescription(for definitions: [ToolDefinition]) -> String {
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

    return """
      ## Available Tools

      \(toolDescriptions)

      ## Tool Calling

      When a tool is needed, reply with exactly one block and no other text:
      <tool_call>{"name":"tool_name","arguments":{"required_arg":"value"}}</tool_call>

      Use only listed tool names or aliases. Include required arguments, omit unused optional arguments, and keep JSON values typed correctly. After a tool call, stop.

      When the host returns a `<tool_run>` result, use that result as ground truth. If more tool work is needed, emit the next single `<tool_call>` block; otherwise answer normally with no `<tool_call>`.
      """
  }

  static func parseCalls(in text: String, tools: [ToolDefinition]) -> [ParsedToolCall] {
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
    return inferBareToolCall(in: text, tools: tools).map { [$0] } ?? []
  }

  static func parseToolCallJSON(_ json: String, rawBlock: String) -> ParsedToolCall? {
    parseToolCallPayload(json, attributes: "", rawBlock: rawBlock)
  }

  static func containsToolCallMarker(in text: String) -> Bool {
    text.range(
      of: "<\\s*/?\\s*tool_call\\b",
      options: [.regularExpression, .caseInsensitive]) != nil
  }

  static func malformedToolCallFeedback(from text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let preview = trimmed.count > 500 ? String(trimmed.prefix(500)) + "..." : trimmed
    return """
      <tool_run>
      invalid_tool_call tool ({}):
      Error: the assistant emitted a `<tool_call>` marker, but the host could not parse an executable tool call.

      Received:
      \(preview)

      Emit exactly one valid block with real JSON, or answer normally without any `<tool_call>` marker:
      <tool_call>{"name":"tool_name","arguments":{}}</tool_call>
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
    let guidance =
      isErrorResult(body)
      ? "\n\nHost note: this tool result is an error. Use it to choose the next corrective tool call. If it reports a missing prerequisite, call that prerequisite next and retry only after the prerequisite succeeds."
      : ""
    return "<tool_run>\n\(toolName) tool (\(argumentsJSON)):\n\(body)\(guidance)\n</tool_run>"
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

  static func argumentValues(_ args: [String: Any]) -> [String: AgentToolArgumentValue] {
    args.mapValues { AgentToolArgumentValue(json: $0) }
  }

  static func isErrorResult(_ result: String) -> Bool {
    let text = result.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return text.hasPrefix("error:")
      || text.hasPrefix("error ")
      || text.contains("you have to ")
      || text.contains("must ")
      || text.contains("missing prerequisite")
      || text.contains("not opened")
      || text.contains("open file first")
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

    if let attrName {
      return ParsedToolCall(name: attrName, arguments: [:], argumentValues: [:], rawBlock: rawBlock)
    }
    return nil
  }

  private static func firstNonEmpty(_ values: String?...) -> String? {
    for value in values {
      let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !trimmed.isEmpty { return trimmed }
    }
    return nil
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

  private static func inferBareToolCall(in text: String, tools: [ToolDefinition]) -> ParsedToolCall?
  {
    let visible = stripThinkBlocks(from: text).trimmingCharacters(in: .whitespacesAndNewlines)
    guard visible.hasPrefix("{"), visible.hasSuffix("}"),
      let data = visible.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }

    if let normalized = normalizeToolCallObject(object),
      let name = normalized["name"] as? String
    {
      return ParsedToolCall(
        name: name,
        arguments: [:],
        argumentValues: argumentValues(argumentsObject(from: normalized["arguments"])),
        rawBlock: visible)
    }

    let objectKeys = Set(object.keys)
    guard !objectKeys.isEmpty else { return nil }
    let candidates = tools.compactMap { tool -> (tool: ToolDefinition, score: Int)? in
      let paramNames = Set(tool.parameters.map(\.name))
      let required = Set(tool.parameters.filter(\.required).map(\.name))
      guard !paramNames.isEmpty, objectKeys.isSubset(of: paramNames) else { return nil }
      guard required.isEmpty || required.isSubset(of: objectKeys) else { return nil }
      return (tool, objectKeys.intersection(paramNames).count + required.count)
    }
    let sorted = candidates.sorted { $0.score > $1.score }
    guard let first = sorted.first else { return nil }
    if sorted.count > 1, sorted[1].score == first.score { return nil }
    return ParsedToolCall(
      name: first.tool.name,
      arguments: [:],
      argumentValues: argumentValues(object),
      rawBlock: visible)
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
