import Foundation

/// Converts a JSON file into an indented plain-text document so it can be read
/// like prose instead of raw syntax.
///
/// Objects become `key: value` lines, nested containers indent by two spaces,
/// and array items become `- item` lines, so the result reads like a YAML-ish
/// outline. Key order is preserved, which `JSONSerialization` cannot do, so a
/// minimal parser lives here. Container keys are also reported as sections with
/// the line number they start on in the rendered document, which is what the
/// files_read_index tool shows.
public enum JSONDocumentImporter {
  public enum ImportError: LocalizedError, Equatable, Sendable {
    case tooLarge
    case notUTF8
    case invalidJSON(String)
    case tooDeeplyNested

    public var errorDescription: String? {
      switch self {
      case .tooLarge:
        "JSON documents are limited to 10 MB."
      case .notUTF8:
        "The JSON file is not valid UTF-8 text."
      case .invalidJSON(let detail):
        "The file is not valid JSON: \(detail)."
      case .tooDeeplyNested:
        "The JSON document is nested too deeply."
      }
    }
  }

  public static let maximumFileBytes = 10_000_000
  public static let maximumNestingDepth = 128

  public struct Section: Equatable, Sendable {
    /// 1-based line in the rendered document where the section key appears.
    public let line: Int
    public let depth: Int
    public let title: String

    public init(line: Int, depth: Int, title: String) {
      self.line = line
      self.depth = depth
      self.title = title
    }
  }

  public struct RenderedDocument: Equatable, Sendable {
    public let text: String
    public let sections: [Section]

    public init(text: String, sections: [Section]) {
      self.text = text
      self.sections = sections
    }
  }

  public static func render(data: Data) throws -> RenderedDocument {
    guard data.count <= maximumFileBytes else { throw ImportError.tooLarge }
    guard let text = String(data: data, encoding: .utf8) else { throw ImportError.notUTF8 }
    return try render(text: text)
  }

  public static func render(text: String) throws -> RenderedDocument {
    var source = text
    if source.hasPrefix("\u{FEFF}") { source.removeFirst() }
    var parser = Parser(source)
    let value = try parser.parseDocument()
    var renderer = Renderer()
    renderer.render(value, depth: 0)
    return RenderedDocument(
      text: renderer.lines.joined(separator: "\n"),
      sections: renderer.sections)
  }

  // MARK: - Value model

  private enum JSONValue {
    case object([(key: String, value: JSONValue)])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null
  }

  // MARK: - Parsing

  private struct Parser {
    private let scalars: [Unicode.Scalar]
    private var index = 0

    init(_ text: String) {
      scalars = Array(text.unicodeScalars)
    }

    mutating func parseDocument() throws -> JSONValue {
      let value = try parseValue(depth: 0)
      skipWhitespace()
      guard index == scalars.count else {
        throw ImportError.invalidJSON("unexpected content after the top-level value")
      }
      return value
    }

    private mutating func parseValue(depth: Int) throws -> JSONValue {
      guard depth <= JSONDocumentImporter.maximumNestingDepth else {
        throw ImportError.tooDeeplyNested
      }
      skipWhitespace()
      guard let scalar = current else {
        throw ImportError.invalidJSON("unexpected end of file")
      }
      switch scalar {
      case "{":
        return try parseObject(depth: depth)
      case "[":
        return try parseArray(depth: depth)
      case "\"":
        return .string(try parseString())
      case "t":
        try expect(literal: "true")
        return .bool(true)
      case "f":
        try expect(literal: "false")
        return .bool(false)
      case "n":
        try expect(literal: "null")
        return .null
      default:
        return .number(try parseNumber())
      }
    }

    private mutating func parseObject(depth: Int) throws -> JSONValue {
      advance()
      var pairs: [(key: String, value: JSONValue)] = []
      skipWhitespace()
      if current == "}" {
        advance()
        return .object(pairs)
      }
      while true {
        skipWhitespace()
        guard current == "\"" else {
          throw ImportError.invalidJSON("expected an object key")
        }
        let key = try parseString()
        skipWhitespace()
        guard current == ":" else {
          throw ImportError.invalidJSON("expected ':' after an object key")
        }
        advance()
        let value = try parseValue(depth: depth + 1)
        pairs.append((key: key, value: value))
        skipWhitespace()
        if current == "," {
          advance()
          continue
        }
        guard current == "}" else {
          throw ImportError.invalidJSON("expected ',' or '}' in an object")
        }
        advance()
        return .object(pairs)
      }
    }

    private mutating func parseArray(depth: Int) throws -> JSONValue {
      advance()
      var items: [JSONValue] = []
      skipWhitespace()
      if current == "]" {
        advance()
        return .array(items)
      }
      while true {
        items.append(try parseValue(depth: depth + 1))
        skipWhitespace()
        if current == "," {
          advance()
          continue
        }
        guard current == "]" else {
          throw ImportError.invalidJSON("expected ',' or ']' in an array")
        }
        advance()
        return .array(items)
      }
    }

    private mutating func parseString() throws -> String {
      advance()
      var result = String.UnicodeScalarView()
      var pendingHighSurrogate: UInt32?

      func flushPendingSurrogate() {
        if pendingHighSurrogate != nil {
          result.append("\u{FFFD}")
          pendingHighSurrogate = nil
        }
      }

      while let scalar = current {
        advance()
        if scalar == "\"" {
          flushPendingSurrogate()
          return String(result)
        }
        guard scalar == "\\" else {
          flushPendingSurrogate()
          result.append(scalar)
          continue
        }
        guard let escaped = current else { break }
        advance()
        switch escaped {
        case "\"", "\\", "/":
          flushPendingSurrogate()
          result.append(escaped)
        case "b":
          flushPendingSurrogate()
          result.append("\u{08}")
        case "f":
          flushPendingSurrogate()
          result.append("\u{0C}")
        case "n":
          flushPendingSurrogate()
          result.append("\n")
        case "r":
          flushPendingSurrogate()
          result.append("\r")
        case "t":
          flushPendingSurrogate()
          result.append("\t")
        case "u":
          let code = try parseHexCode()
          if let high = pendingHighSurrogate {
            pendingHighSurrogate = nil
            if (0xDC00...0xDFFF).contains(code) {
              let combined = 0x10000 + ((high - 0xD800) << 10) + (code - 0xDC00)
              result.append(Unicode.Scalar(combined) ?? "\u{FFFD}")
            } else {
              result.append("\u{FFFD}")
              if (0xD800...0xDBFF).contains(code) {
                pendingHighSurrogate = code
              } else {
                result.append(Unicode.Scalar(code) ?? "\u{FFFD}")
              }
            }
          } else if (0xD800...0xDBFF).contains(code) {
            pendingHighSurrogate = code
          } else if (0xDC00...0xDFFF).contains(code) {
            result.append("\u{FFFD}")
          } else {
            result.append(Unicode.Scalar(code) ?? "\u{FFFD}")
          }
        default:
          throw ImportError.invalidJSON("invalid escape '\\\(escaped)' in a string")
        }
      }
      throw ImportError.invalidJSON("unterminated string")
    }

    private mutating func parseHexCode() throws -> UInt32 {
      var code: UInt32 = 0
      for _ in 0..<4 {
        guard let scalar = current, let digit = Character(scalar).hexDigitValue else {
          throw ImportError.invalidJSON("invalid \\u escape in a string")
        }
        advance()
        code = code << 4 | UInt32(digit)
      }
      return code
    }

    private func isDigit(_ scalar: Unicode.Scalar) -> Bool {
      // ASCII "0"..."9"
      scalar.value >= 0x30 && scalar.value <= 0x39
    }

    private mutating func parseNumber() throws -> String {
      var lexeme = ""
      if current == "-" {
        lexeme.unicodeScalars.append("-")
        advance()
      }
      var hasDigits = false
      while let scalar = current, isDigit(scalar) {
        lexeme.unicodeScalars.append(scalar)
        advance()
        hasDigits = true
      }
      guard hasDigits else {
        throw ImportError.invalidJSON("unexpected character '\(current.map(String.init) ?? "")'")
      }
      if current == "." {
        lexeme.unicodeScalars.append(".")
        advance()
        var hasFraction = false
        while let scalar = current, isDigit(scalar) {
          lexeme.unicodeScalars.append(scalar)
          advance()
          hasFraction = true
        }
        guard hasFraction else {
          throw ImportError.invalidJSON("number is missing fraction digits")
        }
      }
      if current == "e" || current == "E" {
        lexeme.unicodeScalars.append(current!)
        advance()
        if current == "+" || current == "-" {
          lexeme.unicodeScalars.append(current!)
          advance()
        }
        var hasExponent = false
        while let scalar = current, isDigit(scalar) {
          lexeme.unicodeScalars.append(scalar)
          advance()
          hasExponent = true
        }
        guard hasExponent else {
          throw ImportError.invalidJSON("number is missing exponent digits")
        }
      }
      return lexeme
    }

    private mutating func expect(literal: String) throws {
      for expected in literal.unicodeScalars {
        guard current == expected else {
          throw ImportError.invalidJSON("unexpected character '\(current.map(String.init) ?? "")'")
        }
        advance()
      }
    }

    private var current: Unicode.Scalar? {
      index < scalars.count ? scalars[index] : nil
    }

    private mutating func advance() {
      index += 1
    }

    private mutating func skipWhitespace() {
      while let scalar = current,
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
      {
        advance()
      }
    }
  }

  // MARK: - Rendering

  private struct Renderer {
    var lines: [String] = []
    var sections: [Section] = []

    mutating func render(_ value: JSONValue, depth: Int) {
      switch value {
      case .object(let pairs):
        guard !pairs.isEmpty else {
          append("{}", depth: depth)
          return
        }
        renderObject(pairs, depth: depth)
      case .array(let items):
        guard !items.isEmpty else {
          append("[]", depth: depth)
          return
        }
        renderArray(items, depth: depth)
      default:
        renderScalarLines(value, depth: depth)
      }
    }

    private mutating func renderObject(
      _ pairs: [(key: String, value: JSONValue)],
      depth: Int
    ) {
      for (key, value) in pairs {
        let title = displayKey(key)
        switch value {
        case .object(let children):
          guard !children.isEmpty else {
            append("\(title): {}", depth: depth)
            continue
          }
          sections.append(Section(line: lines.count + 1, depth: depth, title: title))
          append("\(title):", depth: depth)
          renderObject(children, depth: depth + 1)
        case .array(let items):
          guard !items.isEmpty else {
            append("\(title): []", depth: depth)
            continue
          }
          sections.append(Section(line: lines.count + 1, depth: depth, title: title))
          append("\(title):", depth: depth)
          renderArray(items, depth: depth + 1)
        case .string(let string) where isMultiline(string):
          append("\(title):", depth: depth)
          for line in blockLines(string) {
            append(line, depth: depth + 1)
          }
        default:
          append("\(title): \(scalarText(value))", depth: depth)
        }
      }
    }

    private mutating func renderArray(_ items: [JSONValue], depth: Int) {
      for item in items {
        switch item {
        case .object(let children):
          guard !children.isEmpty else {
            append("- {}", depth: depth)
            continue
          }
          append("-", depth: depth)
          renderObject(children, depth: depth + 1)
        case .array(let children):
          guard !children.isEmpty else {
            append("- []", depth: depth)
            continue
          }
          append("-", depth: depth)
          renderArray(children, depth: depth + 1)
        case .string(let string) where isMultiline(string):
          append("-", depth: depth)
          for line in blockLines(string) {
            append(line, depth: depth + 1)
          }
        default:
          append("- \(scalarText(item))", depth: depth)
        }
      }
    }

    private mutating func renderScalarLines(_ value: JSONValue, depth: Int) {
      if case .string(let string) = value, isMultiline(string) {
        for line in blockLines(string) {
          append(line, depth: depth)
        }
        return
      }
      append(scalarText(value), depth: depth)
    }

    private mutating func append(_ text: String, depth: Int) {
      lines.append(String(repeating: "  ", count: depth) + text)
    }

    private func scalarText(_ value: JSONValue) -> String {
      switch value {
      case .string(let string):
        string.isEmpty ? "\"\"" : string
      case .number(let lexeme):
        lexeme
      case .bool(let flag):
        flag ? "true" : "false"
      case .null:
        "null"
      case .object, .array:
        ""
      }
    }

    private func displayKey(_ key: String) -> String {
      let cleaned =
        key
        .replacingOccurrences(of: "\r\n", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
      return cleaned.isEmpty ? "\"\"" : cleaned
    }

    private func isMultiline(_ string: String) -> Bool {
      string.contains("\n") || string.contains("\r")
    }

    private func blockLines(_ string: String) -> [String] {
      string
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .components(separatedBy: "\n")
    }
  }
}
