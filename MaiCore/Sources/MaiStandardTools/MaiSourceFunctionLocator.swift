import Foundation

/// Locates function declarations and bodies without loading an entire source
/// file into a tool response. It deliberately uses lightweight lexical rules
/// instead of compiler frontends so the Files tools remain portable.
enum MaiSourceFunctionLocator {
  struct Match: Equatable, Sendable {
    let name: String
    let declarationLine: Int
    let startLine: Int
    let endLine: Int
    let byteOffset: Int
    let byteSize: Int
    let bodyStartLine: Int
    let bodyEndLine: Int
    let bodyByteOffset: Int
    let bodyByteSize: Int
  }

  static func matches(
    named name: String,
    in text: String,
    fileExtension: String
  ) -> [Match] {
    let bytes = Array(text.utf8)
    let lineStarts = makeLineStarts(bytes)
    let extension_ = fileExtension.lowercased()
    let indexedLines =
      MaiDocumentIndexer.sourceFunctionIndex(
        text: text,
        fileExtension: extension_)?
      .filter { title($0.title, matches: name) }
      .map(\.line) ?? []
    let candidateLines =
      indexedLines.isEmpty
      ? fallbackCandidateLines(named: name, bytes: bytes, lineStarts: lineStarts)
      : indexedLines

    var seenOffsets: Set<Int> = []
    var results: [Match] = []
    for line in candidateLines {
      guard line > 0, line <= lineStarts.count else { continue }
      let match: Match?
      switch extension_ {
      case "py", "pyi":
        match = indentationMatch(
          named: name, declarationLine: line, bytes: bytes, lineStarts: lineStarts)
      case "rb", "rake", "lua":
        match = endDelimitedMatch(
          named: name, declarationLine: line, bytes: bytes, lineStarts: lineStarts)
      default:
        match = braceMatch(
          named: name, declarationLine: line, bytes: bytes, lineStarts: lineStarts)
      }
      if let match, seenOffsets.insert(match.byteOffset).inserted {
        results.append(match)
      }
    }
    return results.sorted { $0.byteOffset < $1.byteOffset }
  }

  static func revision(of bytes: Data.SubSequence) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in bytes {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    let hexadecimal = String(hash, radix: 16)
    let padded = String(repeating: "0", count: max(0, 16 - hexadecimal.count)) + hexadecimal
    return "fnv1a64:\(padded):\(bytes.count)"
  }

  private static func title(_ title: String, matches name: String) -> Bool {
    guard title != name else { return true }
    return [".", "::", ":"].contains { title.hasSuffix($0 + name) }
  }

  private static func fallbackCandidateLines(
    named name: String,
    bytes: [UInt8],
    lineStarts: [Int]
  ) -> [Int] {
    guard !name.isEmpty else { return [] }
    var result: [Int] = []
    for line in 1...lineStarts.count {
      let range = lineRange(line, bytes: bytes, lineStarts: lineStarts)
      let source = String(decoding: bytes[range], as: UTF8.self)
      let trimmed = source.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty,
        !["//", "/*", "*", "#", "--"].contains(where: { trimmed.hasPrefix($0) }),
        containsIdentifier(name, in: source)
      else { continue }
      let firstWord = trimmed.prefix { $0.isLetter || $0 == "_" }
      guard !["if", "for", "while", "switch", "return", "case", "catch"].contains(firstWord)
      else { continue }
      result.append(line)
    }
    return result
  }

  private static func containsIdentifier(_ name: String, in line: String) -> Bool {
    var searchStart = line.startIndex
    while searchStart < line.endIndex,
      let range = line.range(of: name, range: searchStart..<line.endIndex)
    {
      let before =
        range.lowerBound == line.startIndex ? nil : line[line.index(before: range.lowerBound)]
      let after = range.upperBound == line.endIndex ? nil : line[range.upperBound]
      let isIdentifier: (Character) -> Bool = {
        $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$"
      }
      if before.map(isIdentifier) != true, after.map(isIdentifier) != true {
        let suffix = line[range.upperBound...].drop(while: { $0.isWhitespace })
        if suffix.first == "(" || suffix.first == "<" || suffix.first == ":" { return true }
      }
      searchStart = range.upperBound
    }
    return false
  }

  private static func braceMatch(
    named name: String,
    declarationLine: Int,
    bytes: [UInt8],
    lineStarts: [Int]
  ) -> Match? {
    let start = lineStarts[declarationLine - 1]
    guard let opening = findOpeningBrace(bytes, from: start),
      let closing = findClosingBrace(bytes, opening: opening)
    else { return nil }
    return Match(
      name: name,
      declarationLine: declarationLine,
      startLine: declarationLine,
      endLine: lineNumber(at: closing, lineStarts: lineStarts),
      byteOffset: start,
      byteSize: closing + 1 - start,
      bodyStartLine: lineNumber(at: opening + 1, lineStarts: lineStarts),
      bodyEndLine: lineNumber(at: closing, lineStarts: lineStarts),
      bodyByteOffset: opening + 1,
      bodyByteSize: closing - opening - 1)
  }

  private static func indentationMatch(
    named name: String,
    declarationLine: Int,
    bytes: [UInt8],
    lineStarts: [Int]
  ) -> Match? {
    let start = lineStarts[declarationLine - 1]
    guard let colon = findHeaderColon(bytes, from: start) else { return nil }
    let headerLine = lineNumber(at: colon, lineStarts: lineStarts)
    let headerRange = lineRange(headerLine, bytes: bytes, lineStarts: lineStarts)
    let inlineStart = colon + 1
    if inlineStart < headerRange.upperBound,
      bytes[inlineStart..<headerRange.upperBound].contains(where: { !isHorizontalWhitespace($0) })
    {
      return Match(
        name: name,
        declarationLine: declarationLine,
        startLine: declarationLine,
        endLine: headerLine,
        byteOffset: start,
        byteSize: headerRange.upperBound - start,
        bodyStartLine: headerLine,
        bodyEndLine: headerLine,
        bodyByteOffset: inlineStart,
        bodyByteSize: headerRange.upperBound - inlineStart)
    }
    guard headerLine < lineStarts.count else { return nil }
    let declarationIndent = indentation(at: start, bytes: bytes)
    let bodyStart = lineStarts[headerLine]
    var bodyEnd = bytes.count
    for line in (headerLine + 1)...lineStarts.count {
      let range = lineRange(line, bytes: bytes, lineStarts: lineStarts)
      guard bytes[range].contains(where: { !isHorizontalWhitespace($0) }) else { continue }
      if indentation(at: range.lowerBound, bytes: bytes) <= declarationIndent {
        bodyEnd = range.lowerBound
        break
      }
    }
    guard bodyEnd > bodyStart else { return nil }
    return Match(
      name: name,
      declarationLine: declarationLine,
      startLine: declarationLine,
      endLine: lineNumber(at: max(start, bodyEnd - 1), lineStarts: lineStarts),
      byteOffset: start,
      byteSize: bodyEnd - start,
      bodyStartLine: headerLine + 1,
      bodyEndLine: lineNumber(at: max(bodyStart, bodyEnd - 1), lineStarts: lineStarts),
      bodyByteOffset: bodyStart,
      bodyByteSize: bodyEnd - bodyStart)
  }

  private static func endDelimitedMatch(
    named name: String,
    declarationLine: Int,
    bytes: [UInt8],
    lineStarts: [Int]
  ) -> Match? {
    let start = lineStarts[declarationLine - 1]
    let declarationIndent = indentation(at: start, bytes: bytes)
    guard declarationLine < lineStarts.count else { return nil }
    let bodyStart = lineStarts[declarationLine]
    for line in (declarationLine + 1)...lineStarts.count {
      let range = lineRange(line, bytes: bytes, lineStarts: lineStarts)
      guard indentation(at: range.lowerBound, bytes: bytes) == declarationIndent else { continue }
      let trimmed = String(decoding: bytes[range], as: UTF8.self)
        .trimmingCharacters(in: .whitespaces)
      guard
        trimmed == "end" || trimmed.hasPrefix("end;") || trimmed.hasPrefix("end #")
          || trimmed.hasPrefix("end --")
      else { continue }
      return Match(
        name: name,
        declarationLine: declarationLine,
        startLine: declarationLine,
        endLine: line,
        byteOffset: start,
        byteSize: range.upperBound - start,
        bodyStartLine: declarationLine + 1,
        bodyEndLine: max(declarationLine + 1, line - 1),
        bodyByteOffset: bodyStart,
        bodyByteSize: range.lowerBound - bodyStart)
    }
    return nil
  }

  private enum LexicalState {
    case code
    case lineComment
    case blockComment
    case singleQuote
    case doubleQuote
    case backtick
  }

  private static func findOpeningBrace(_ bytes: [UInt8], from start: Int) -> Int? {
    var state = LexicalState.code
    var escaped = false
    var parentheses = 0
    var brackets = 0
    let limit = min(bytes.count, start + 131_072)
    var index = start
    while index < limit {
      let byte = bytes[index]
      if advanceLexicalState(bytes, index: &index, state: &state, escaped: &escaped) {
        continue
      }
      switch byte {
      case 40: parentheses += 1
      case 41: parentheses = max(0, parentheses - 1)
      case 91: brackets += 1
      case 93: brackets = max(0, brackets - 1)
      case 59 where parentheses == 0 && brackets == 0: return nil
      case 123 where parentheses == 0 && brackets == 0: return index
      default: break
      }
      index += 1
    }
    return nil
  }

  private static func findClosingBrace(_ bytes: [UInt8], opening: Int) -> Int? {
    var state = LexicalState.code
    var escaped = false
    var depth = 1
    var index = opening + 1
    while index < bytes.count {
      let byte = bytes[index]
      if advanceLexicalState(bytes, index: &index, state: &state, escaped: &escaped) {
        continue
      }
      if byte == 123 { depth += 1 }
      if byte == 125 {
        depth -= 1
        if depth == 0 { return index }
      }
      index += 1
    }
    return nil
  }

  private static func findHeaderColon(_ bytes: [UInt8], from start: Int) -> Int? {
    var state = LexicalState.code
    var escaped = false
    var depth = 0
    let limit = min(bytes.count, start + 131_072)
    var index = start
    while index < limit {
      let byte = bytes[index]
      if advanceLexicalState(bytes, index: &index, state: &state, escaped: &escaped) {
        continue
      }
      switch byte {
      case 40, 91, 123: depth += 1
      case 41, 93, 125: depth = max(0, depth - 1)
      case 58 where depth == 0: return index
      case 10 where depth == 0: return nil
      default: break
      }
      index += 1
    }
    return nil
  }

  /// Returns true when the caller should continue without interpreting the
  /// current byte as source structure. The index always advances in that case.
  private static func advanceLexicalState(
    _ bytes: [UInt8],
    index: inout Int,
    state: inout LexicalState,
    escaped: inout Bool
  ) -> Bool {
    let byte = bytes[index]
    let next = index + 1 < bytes.count ? bytes[index + 1] : 0
    switch state {
    case .code:
      if byte == 47, next == 47 {
        state = .lineComment
        index += 2
        return true
      }
      if byte == 47, next == 42 {
        state = .blockComment
        index += 2
        return true
      }
      if byte == 34 {
        state = .doubleQuote
        escaped = false
        index += 1
        return true
      }
      if byte == 39 {
        state = .singleQuote
        escaped = false
        index += 1
        return true
      }
      if byte == 96 {
        state = .backtick
        escaped = false
        index += 1
        return true
      }
      return false
    case .lineComment:
      if byte == 10 { state = .code }
      index += 1
      return true
    case .blockComment:
      if byte == 42, next == 47 {
        state = .code
        index += 2
      } else {
        index += 1
      }
      return true
    case .singleQuote, .doubleQuote, .backtick:
      let delimiter: UInt8 = state == .singleQuote ? 39 : state == .doubleQuote ? 34 : 96
      if escaped {
        escaped = false
      } else if byte == 92 {
        escaped = true
      } else if byte == delimiter {
        state = .code
      }
      index += 1
      return true
    }
  }

  private static func makeLineStarts(_ bytes: [UInt8]) -> [Int] {
    var result = [0]
    for (index, byte) in bytes.enumerated() where byte == 10 && index + 1 < bytes.count {
      result.append(index + 1)
    }
    return result
  }

  private static func lineRange(
    _ line: Int,
    bytes: [UInt8],
    lineStarts: [Int]
  ) -> Range<Int> {
    let start = lineStarts[line - 1]
    var end = line < lineStarts.count ? lineStarts[line] - 1 : bytes.count
    if end > start, bytes[end - 1] == 13 { end -= 1 }
    return start..<end
  }

  private static func lineNumber(at offset: Int, lineStarts: [Int]) -> Int {
    var lower = 0
    var upper = lineStarts.count
    while lower < upper {
      let middle = (lower + upper) / 2
      if lineStarts[middle] <= offset { lower = middle + 1 } else { upper = middle }
    }
    return max(1, lower)
  }

  private static func indentation(at offset: Int, bytes: [UInt8]) -> Int {
    var count = 0
    var index = offset
    while index < bytes.count {
      if bytes[index] == 32 { count += 1 } else if bytes[index] == 9 { count += 8 } else { break }
      index += 1
    }
    return count
  }

  private static func isHorizontalWhitespace(_ byte: UInt8) -> Bool {
    byte == 32 || byte == 9 || byte == 13
  }
}
