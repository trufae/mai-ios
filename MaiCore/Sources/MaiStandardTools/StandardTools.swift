import Foundation
import MaiCore

public struct MaiStandardToolsPlugin: MaiPlugin {
  public static let factoryKind = "standard-tools"

  public let manifest = PluginManifest(
    id: "org.mai.standard-tools",
    displayName: "Mai standard tools",
    version: "1.0.0",
    capabilities: [.agentTool])

  public init() {}

  public func register(in registry: PluginRegistry) async throws {
    try await registry.register(toolFactory: MaiStandardToolFactory(), from: manifest.id)
  }
}

public struct MaiStandardToolFactory: ConfiguredToolFactory {
  public let kind = MaiStandardToolsPlugin.factoryKind

  public init() {}

  public func makeTools(context: PluginFactoryContext) async throws -> [any AgentTool] {
    let tools: [any AgentTool] = [
      MaiEchoTool(),
      MaiCurrentTimeTool(),
      MaiCalculatorTool(),
      MaiReadTextFileTool(),
    ]
    guard let names = context.options["tools"]?.arrayValue else { return tools }
    let enabled = Set(names.compactMap(\.stringValue))
    return tools.filter { enabled.contains($0.definition.name) }
  }
}

public struct MaiEchoTool: AgentTool {
  public static let name = "echo"
  public static let toolDefinition = ToolDefinition(
    name: name,
    description: "Return the supplied text.",
    inputSchema: objectSchema(
      properties: [
        "text": .object([
          "type": .string("string"),
          "description": .string("Text to return."),
        ])
      ],
      required: ["text"]),
    annotations: ToolAnnotations(
      readOnly: true,
      idempotent: true,
      openWorld: false,
      approval: .automatic))

  public let definition = Self.toolDefinition

  public init() {}

  public func call(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolOutput {
    ToolOutput(text: arguments.objectValue?["text"]?.stringValue ?? "")
  }
}

public struct MaiCurrentTimeTool: AgentTool {
  public static let name = "current_time"
  public static let toolDefinition = ToolDefinition(
    name: name,
    description: "Return the current ISO-8601 date and time.",
    inputSchema: objectSchema(properties: [:], required: []),
    annotations: ToolAnnotations(
      readOnly: true,
      idempotent: false,
      openWorld: false,
      approval: .automatic))

  public let definition = Self.toolDefinition

  public init() {}

  public func call(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolOutput {
    ToolOutput(text: ISO8601DateFormatter().string(from: Date()))
  }
}

public struct MaiReadTextFileTool: AgentTool {
  public static let name = "read_text_file"
  public static let maximumBytes = 1_048_576
  public static let toolDefinition = ToolDefinition(
    name: name,
    description: "Read a UTF-8 text file from the host.",
    inputSchema: objectSchema(
      properties: ["path": .object(["type": .string("string")])],
      required: ["path"]),
    annotations: ToolAnnotations(
      readOnly: true,
      idempotent: true,
      openWorld: false,
      approval: .confirm))

  public let definition = Self.toolDefinition

  public init() {}

  public func call(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolOutput {
    guard let path = arguments.objectValue?["path"]?.stringValue else {
      return ToolOutput(text: "Missing path.", isError: true)
    }
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    guard data.count <= Self.maximumBytes else {
      return ToolOutput(text: "File exceeds the 1 MiB CLI tool limit.", isError: true)
    }
    guard let text = String(data: data, encoding: .utf8) else {
      return ToolOutput(text: "File is not valid UTF-8.", isError: true)
    }
    return ToolOutput(content: [
      .file(FileContent(name: url.lastPathComponent, mimeType: "text/plain", text: text))
    ])
  }
}

public struct MaiCalculatorTool: AgentTool {
  public static let name = "calculator"
  public static let toolDefinition = ToolDefinition(
    name: name,
    description:
      "Evaluate a numeric math expression with parentheses using +, -, *, /, and unary signs.",
    inputSchema: objectSchema(
      properties: [
        "expression": .object([
          "type": .string("string"),
          "description": .string("Math expression to evaluate, such as (2 + 3) * 4 / 5."),
        ])
      ],
      required: ["expression"]),
    annotations: ToolAnnotations(
      readOnly: true,
      idempotent: true,
      openWorld: false,
      approval: .automatic))

  public let definition = Self.toolDefinition

  public init() {}

  public func call(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolOutput {
    Self.evaluate(arguments.objectValue ?? [:])
  }

  public static func evaluate(_ arguments: [String: JSONValue]) -> ToolOutput {
    let expression =
      arguments["expression"]?.stringValue ?? arguments["expr"]?.stringValue
      ?? arguments["input"]?.stringValue ?? ""
    let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return ToolOutput(text: "Error: expression is required.", isError: true)
    }

    do {
      var parser = CalculatorParser(trimmed)
      return ToolOutput(text: format(try parser.parse()))
    } catch {
      return ToolOutput(
        text: "Error: invalid expression: \(error.localizedDescription)",
        isError: true)
    }
  }

  private static func format(_ value: Double) -> String {
    guard value.isFinite else { return "Error: calculation result is not finite." }
    if value.rounded() == value && value <= Double(Int64.max) && value >= Double(Int64.min) {
      return String(Int64(value))
    }
    return String(format: "%.15g", value)
  }
}

private struct CalculatorParser {
  private let text: String
  private var index: String.Index

  init(_ text: String) {
    self.text = text
    self.index = text.startIndex
  }

  mutating func parse() throws -> Double {
    let value = try parseExpression()
    skipWhitespace()
    guard index == text.endIndex else {
      throw CalculatorParserError("unexpected '\(text[index])'")
    }
    guard value.isFinite else { throw CalculatorParserError("result is not finite") }
    return value
  }

  private mutating func parseExpression() throws -> Double {
    var value = try parseTerm()
    while true {
      if consume("+") {
        value += try parseTerm()
      } else if consume("-") {
        value -= try parseTerm()
      } else {
        return value
      }
    }
  }

  private mutating func parseTerm() throws -> Double {
    var value = try parseFactor()
    while true {
      if consume("*") {
        value *= try parseFactor()
      } else if consume("/") {
        let divisor = try parseFactor()
        guard divisor != 0 else { throw CalculatorParserError("division by zero") }
        value /= divisor
      } else {
        return value
      }
    }
  }

  private mutating func parseFactor() throws -> Double {
    skipWhitespace()
    if consume("+") { return try parseFactor() }
    if consume("-") { return -(try parseFactor()) }
    if consume("(") {
      let value = try parseExpression()
      guard consume(")") else { throw CalculatorParserError("expected ')'") }
      return value
    }
    return try parseNumber()
  }

  private mutating func parseNumber() throws -> Double {
    skipWhitespace()
    let start = index
    var hasDigit = false
    while let char = current, char.isNumber {
      hasDigit = true
      advance()
    }
    if consumeRaw(".") {
      while let char = current, char.isNumber {
        hasDigit = true
        advance()
      }
    }
    guard hasDigit else { throw CalculatorParserError("expected number") }

    if let char = current, char == "e" || char == "E" {
      advance()
      _ = consumeRaw("+") || consumeRaw("-")
      var hasExponentDigit = false
      while let char = current, char.isNumber {
        hasExponentDigit = true
        advance()
      }
      guard hasExponentDigit else { throw CalculatorParserError("expected exponent digits") }
    }

    let raw = String(text[start..<index])
    guard let value = Double(raw), value.isFinite else {
      throw CalculatorParserError("invalid number '\(raw)'")
    }
    return value
  }

  private var current: Character? { index < text.endIndex ? text[index] : nil }

  private mutating func skipWhitespace() {
    while current?.isWhitespace == true { advance() }
  }

  private mutating func consume(_ char: Character) -> Bool {
    skipWhitespace()
    return consumeRaw(char)
  }

  private mutating func consumeRaw(_ char: Character) -> Bool {
    guard current == char else { return false }
    advance()
    return true
  }

  private mutating func advance() {
    index = text.index(after: index)
  }
}

private struct CalculatorParserError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

private func objectSchema(
  properties: [String: JSONValue],
  required: [String]
) -> JSONValue {
  .object([
    "type": .string("object"),
    "properties": .object(properties),
    "required": .array(required.map(JSONValue.string)),
    "additionalProperties": .bool(false),
  ])
}
