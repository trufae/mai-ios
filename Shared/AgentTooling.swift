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

      ### Tool-call protocol

      To run a tool, emit a single line block (no surrounding text on the same line):
      <tool_call>{"name":"tool_name","arguments":{"required_arg":"value"}}</tool_call>

      ### Mandatory rules - read carefully

      1. After the closing `</tool_call>`, STOP IMMEDIATELY. Do not write your final answer in the same response. The host executes the tool and re-invokes you with the real result visible. Only THEN write the answer.
      2. `<tool_run>` blocks are AUTHORITATIVE ground truth. Read the content character-by-character. Do not guess, paraphrase, or summarize from priors. If the result disagrees with your expectations, the result is right.
      3. The final answer is the response that contains NO `<tool_call>` blocks. The loop stops as soon as you produce one.
      4. Use only listed tool names or their API/native aliases. Never invent arguments.
      5. Include required arguments. Omit optional arguments unless the user explicitly asks for filtering/pagination/limits or a previous tool result requires them.
      6. JSON arguments must preserve schema types: numbers as numbers, booleans as booleans, strings as strings. Never quote numbers or booleans.
      7. Tool errors are observations, not final failures. If a `<tool_run>` says a prerequisite is missing, call the prerequisite tool next with the information already provided by the user, then continue.
      8. Before every tool call, inspect the latest user message, any `<tool_context>`, and all prior `<tool_run>` blocks. If they already contain enough information to answer, give the final answer instead of calling another tool.
      9. Do not re-call a tool whose `<tool_run>` is already in the conversation - read the existing result.
      10. No filler narration between tool calls ("Let me...", "I'll now..."). Emit tool calls or the final answer; nothing else.
      """
  }

  static func parseCalls(in text: String, tools: [ToolDefinition]) -> [ParsedToolCall] {
    let pattern = "<tool_call>([\\s\\S]*?)</tool_call>"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    else { return [] }
    let nsText = text as NSString
    let matches = regex.matches(
      in: text, options: [], range: NSRange(location: 0, length: nsText.length))
    var calls: [ParsedToolCall] = []
    for match in matches {
      guard match.numberOfRanges == 2 else { continue }
      let raw = nsText.substring(with: match.range(at: 0))
      let json = nsText.substring(with: match.range(at: 1))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if let call = parseToolCallJSON(json, rawBlock: raw) {
        calls.append(call)
      }
    }
    if let trailing = trailingUnclosedToolCall(in: text),
      let call = parseToolCallJSON(trailing.json, rawBlock: trailing.rawBlock)
    {
      calls.append(call)
    }
    if !calls.isEmpty { return calls }
    return inferBareToolCall(in: text, tools: tools).map { [$0] } ?? []
  }

  static func parseToolCallJSON(_ json: String, rawBlock: String) -> ParsedToolCall? {
    guard let data = json.data(using: .utf8),
      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let obj = normalizeToolCallObject(parsed),
      let name = (obj["name"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !name.isEmpty
    else { return nil }
    let args = argumentValues(argumentsObject(from: obj["arguments"]))
    return ParsedToolCall(name: name, arguments: [:], argumentValues: args, rawBlock: rawBlock)
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

  static func stringifyArguments(_ args: [String: Any]) -> [String: String] {
    argumentValues(args).mapValues(\.stringValue)
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
      switch value {
      case .int:
        return value
      case .double(let double) where double.rounded() == double:
        return .int(Int(double))
      case .string(let string):
        return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)).map {
          AgentToolArgumentValue.int($0)
        }
      case .bool:
        return parameter.required ? value : nil
      default:
        return parameter.required ? value : nil
      }
    case "number":
      switch value {
      case .int, .double:
        return value
      case .string(let string):
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let int = Int(trimmed) { return .int(int) }
        if let double = Double(trimmed) { return .double(double) }
        return parameter.required ? value : nil
      case .bool:
        return parameter.required ? value : nil
      default:
        return parameter.required ? value : nil
      }
    case "boolean", "bool":
      switch value {
      case .bool:
        return value
      case .string(let string):
        switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1", "yes":
          return .bool(true)
        case "false", "0", "no":
          return .bool(false)
        default:
          return parameter.required ? value : nil
        }
      case .int(let int) where int == 0 || int == 1:
        return .bool(int == 1)
      default:
        return parameter.required ? value : nil
      }
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

  private static func normalizeToolCallObject(_ object: [String: Any]) -> [String: Any]? {
    if let name = object["name"] as? String,
      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      if let nested = object["arguments"] as? [String: Any],
        let nestedName = nested["name"] as? String
      {
        return ["name": nestedName, "arguments": argumentsObject(from: nested["arguments"])]
      }
      return object
    }
    if let name = (object["tool"] as? String) ?? (object["function"] as? String) {
      return [
        "name": name,
        "arguments": argumentsObject(from: object["arguments"] ?? object["args"]),
      ]
    }
    return nil
  }

  private static func trailingUnclosedToolCall(in text: String) -> (rawBlock: String, json: String)?
  {
    guard
      let open = text.range(
        of: "<tool_call>", options: [.caseInsensitive, .backwards]),
      text.range(
        of: "</tool_call>", options: [.caseInsensitive], range: open.upperBound..<text.endIndex)
        == nil
    else { return nil }
    let raw = String(text[open.lowerBound..<text.endIndex])
    let json = String(text[open.upperBound..<text.endIndex])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return json.isEmpty ? nil : (raw, json)
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
