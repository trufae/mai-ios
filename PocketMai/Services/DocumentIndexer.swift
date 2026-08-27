import Foundation

/// Builds a table of contents for a text file: function and type names for
/// source code, heading titles for Markdown. Each entry carries the 1-based
/// line number it starts on, which is what the files_read_index tool shows so
/// the model can jump into large files with files_read_range.
///
/// The source scanners are line-based heuristics, not parsers: they aim for
/// useful navigation, not compiler-grade accuracy.
enum DocumentIndexer {
  struct Entry: Equatable {
    let line: Int
    let title: String
  }

  /// Index a source file by its extension. Returns nil when the extension is
  /// not a recognized programming language (callers then fall back to the
  /// Markdown heading index).
  static func sourceIndex(text: String, fileExtension: String) -> [Entry]? {
    guard let language = Language(fileExtension: fileExtension) else { return nil }
    let patterns = language.patterns
    let cDefinitionRegex = language.usesCFunctionHeuristic ? makeCDefinitionRegex() : nil
    var entries: [Entry] = []
    for (offset, line) in lines(of: text).enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { continue }
      if language.commentPrefixes.contains(where: { trimmed.hasPrefix($0) }) { continue }
      if let title = firstTitle(in: trimmed, patterns: patterns) {
        entries.append(Entry(line: offset + 1, title: title))
      } else if let cDefinitionRegex,
        let name = cFunctionName(in: trimmed, definitionRegex: cDefinitionRegex)
      {
        entries.append(Entry(line: offset + 1, title: name))
      }
    }
    return entries
  }

  /// Index Markdown ATX headings (`# Title` … `###### Title`), skipping fenced
  /// code blocks. The heading markers are kept in the title so the nesting
  /// level stays visible.
  static func markdownIndex(text: String) -> [Entry] {
    var entries: [Entry] = []
    var openFence: String?
    for (offset, line) in lines(of: text).enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if let fence = openFence {
        if trimmed.hasPrefix(fence) { openFence = nil }
        continue
      }
      if trimmed.hasPrefix("```") {
        openFence = "```"
        continue
      }
      if trimmed.hasPrefix("~~~") {
        openFence = "~~~"
        continue
      }
      let hashes = trimmed.prefix(while: { $0 == "#" })
      guard (1...6).contains(hashes.count) else { continue }
      let rest = trimmed.dropFirst(hashes.count)
      guard let first = rest.first, first == " " || first == "\t" else { continue }
      guard !rest.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
      entries.append(Entry(line: offset + 1, title: trimmed))
    }
    return entries
  }

  private static func lines(of text: String) -> [String] {
    text.components(separatedBy: "\n").map { line in
      line.hasSuffix("\r") ? String(line.dropLast()) : line
    }
  }

  // MARK: - Pattern engine

  private struct LinePattern {
    let regex: NSRegularExpression?
    let title: (NSTextCheckingResult, String) -> String?
  }

  private static func firstTitle(in line: String, patterns: [LinePattern]) -> String? {
    let range = NSRange(line.startIndex..<line.endIndex, in: line)
    for pattern in patterns {
      guard let regex = pattern.regex,
        let match = regex.firstMatch(in: line, range: range)
      else { continue }
      if let title = pattern.title(match, line) { return title }
    }
    return nil
  }

  private static func group(_ index: Int, of match: NSTextCheckingResult, in line: String)
    -> String?
  {
    guard index < match.numberOfRanges,
      let range = Range(match.range(at: index), in: line)
    else { return nil }
    let text = String(line[range])
    return text.isEmpty ? nil : text
  }

  private static func regex(_ pattern: String) -> NSRegularExpression? {
    try? NSRegularExpression(pattern: pattern)
  }

  /// Pattern whose first capture group is the entry title.
  private static func name(_ pattern: String) -> LinePattern {
    LinePattern(regex: regex(pattern)) { match, line in
      group(1, of: match, in: line)
    }
  }

  /// Pattern labeled "<group 1> <group 2>", e.g. "class Foo".
  private static func keyworded(_ pattern: String) -> LinePattern {
    LinePattern(regex: regex(pattern)) { match, line in
      guard let keyword = group(1, of: match, in: line),
        let name = group(2, of: match, in: line)
      else { return nil }
      return "\(keyword) \(name)"
    }
  }

  /// Pattern whose title is the whole matched line, minus a trailing brace.
  private static func wholeLine(_ pattern: String) -> LinePattern {
    LinePattern(regex: regex(pattern)) { _, line in
      var title = line
      if title.hasSuffix("{") { title.removeLast() }
      let cleaned = title.trimmingCharacters(in: .whitespaces)
      return cleaned.isEmpty ? nil : cleaned
    }
  }

  /// Pattern producing a fixed title, e.g. "init".
  private static func fixed(_ pattern: String, title: String) -> LinePattern {
    LinePattern(regex: regex(pattern)) { _, _ in title }
  }

  // MARK: - C-style function heuristic

  /// Matches classic `type name(args)` definitions for C, C++, Objective-C,
  /// Java, and C#: at least one type word before the name, an opening
  /// parenthesis after it, and a line that opens a body rather than ending a
  /// statement or declaring a prototype.
  private static func makeCDefinitionRegex() -> NSRegularExpression? {
    regex("^[A-Za-z_][\\w\\s\\*&:<>,\\[\\]]*?[\\s\\*&]([A-Za-z_~][\\w:]*)\\s*\\(")
  }

  private static let cControlKeywords: Set<String> = [
    "if", "else", "for", "while", "switch", "return", "do", "sizeof", "case", "goto",
    "break", "continue", "new", "delete", "throw", "throws", "catch", "using", "typedef",
    "assert", "defined",
  ]

  private static func cFunctionName(
    in line: String,
    definitionRegex: NSRegularExpression
  ) -> String? {
    guard let last = line.last, last == "{" || last == ")" || last == "," || last == "(" else {
      return nil
    }
    guard
      let match = definitionRegex.firstMatch(
        in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
      let nameRange = Range(match.range(at: 1), in: line)
    else { return nil }

    let name = String(line[nameRange])
    let prefix = line[line.startIndex..<nameRange.lowerBound]
    guard !prefix.contains("="), !prefix.contains("\""), !prefix.contains("!") else { return nil }
    let firstWord = String(line.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
    guard !cControlKeywords.contains(firstWord), !cControlKeywords.contains(name) else {
      return nil
    }
    let lastNameComponent = name.split(separator: ":").last.map(String.init) ?? name
    guard !cControlKeywords.contains(lastNameComponent) else { return nil }
    return name
  }

  // MARK: - Languages

  private enum Language {
    case c
    case objectiveC
    case javaLike
    case swift
    case python
    case go
    case rustLike
    case ruby
    case javascript
    case kotlin
    case php
    case shell
    case perl
    case lua

    init?(fileExtension: String) {
      switch fileExtension.lowercased() {
      case "c", "h", "cpp", "cc", "cxx", "hpp", "hh", "hxx", "ino":
        self = .c
      case "m", "mm":
        self = .objectiveC
      case "java", "cs", "scala":
        self = .javaLike
      case "swift":
        self = .swift
      case "py", "pyi":
        self = .python
      case "go":
        self = .go
      case "rs", "zig":
        self = .rustLike
      case "rb", "rake":
        self = .ruby
      case "js", "jsx", "mjs", "cjs", "ts", "tsx":
        self = .javascript
      case "kt", "kts":
        self = .kotlin
      case "php":
        self = .php
      case "sh", "bash", "zsh":
        self = .shell
      case "pl", "pm":
        self = .perl
      case "lua":
        self = .lua
      default:
        return nil
      }
    }

    var commentPrefixes: [String] {
      switch self {
      case .c:
        ["//", "/*", "*", "#"]
      case .objectiveC, .javaLike, .swift, .go, .rustLike, .javascript, .kotlin:
        ["//", "/*", "*"]
      case .php:
        ["//", "/*", "*", "#"]
      case .python, .ruby, .shell, .perl:
        ["#"]
      case .lua:
        ["--"]
      }
    }

    var usesCFunctionHeuristic: Bool {
      switch self {
      case .c, .objectiveC, .javaLike:
        true
      default:
        false
      }
    }

    var patterns: [LinePattern] {
      switch self {
      case .c:
        return [
          DocumentIndexer.keyworded(
            "^(?:template\\s*<[^>]*>\\s*)?(class|struct|namespace|union)\\s+([A-Za-z_]\\w*)")
        ]
      case .objectiveC:
        return [
          DocumentIndexer.name("^[-+]\\s*\\([^)]*\\)\\s*([A-Za-z_]\\w*)"),
          DocumentIndexer.keyworded("^(@interface|@implementation|@protocol)\\s+([A-Za-z_]\\w*)"),
        ]
      case .javaLike:
        return [
          DocumentIndexer.keyworded(
            "^(?:(?:public|private|protected|static|final|abstract|sealed|partial|strictfp)\\s+)*"
              + "(class|interface|enum|record|trait|object)\\s+([A-Za-z_]\\w*)")
        ]
      case .swift:
        let modifiers =
          "^(?:@\\w+(?:\\([^)]*\\))?\\s+)*"
          + "(?:(?:public|private|internal|fileprivate|open|package|static|final|override"
          + "|mutating|nonmutating|nonisolated|dynamic|required|convenience|indirect)\\s+)*"
        return [
          DocumentIndexer.name(modifiers + "func\\s+([A-Za-z_]\\w*)"),
          DocumentIndexer.fixed(modifiers + "init[?!]?\\s*\\(", title: "init"),
          DocumentIndexer.keyworded(
            modifiers + "(class|struct|enum|protocol|actor|extension)\\s+"
              + "(?!func\\b|var\\b|let\\b|subscript\\b)([A-Za-z_][\\w\\.]*)"),
        ]
      case .python:
        return [
          DocumentIndexer.name("^(?:async\\s+)?def\\s+([A-Za-z_]\\w*)"),
          DocumentIndexer.keyworded("^(class)\\s+([A-Za-z_]\\w*)"),
        ]
      case .go:
        return [
          DocumentIndexer.name("^func\\s+(?:\\([^)]*\\)\\s*)?([A-Za-z_]\\w*)\\s*\\("),
          DocumentIndexer.keyworded("^(type)\\s+([A-Za-z_]\\w*)\\s+(?:struct|interface|func)\\b"),
        ]
      case .rustLike:
        return [
          DocumentIndexer.name(
            "^(?:pub(?:\\([^)]*\\))?\\s+)?(?:const\\s+|async\\s+|unsafe\\s+|export\\s+|inline\\s+"
              + "|extern\\s+\"[^\"]*\"\\s+)*fn\\s+([A-Za-z_]\\w*)"),
          DocumentIndexer.keyworded(
            "^(?:pub(?:\\([^)]*\\))?\\s+)?(struct|enum|trait|union|mod)\\s+([A-Za-z_]\\w*)"),
          DocumentIndexer.wholeLine("^impl\\b"),
        ]
      case .ruby:
        return [
          DocumentIndexer.name("^def\\s+((?:self\\.)?[A-Za-z_]\\w*[?!=]?)"),
          DocumentIndexer.keyworded("^(class|module)\\s+([A-Z]\\w*)"),
        ]
      case .javascript:
        return [
          DocumentIndexer.name(
            "^(?:export\\s+)?(?:default\\s+)?(?:async\\s+)?function\\s*\\*?\\s*"
              + "([A-Za-z_$][\\w$]*)"),
          DocumentIndexer.keyworded(
            "^(?:export\\s+)?(?:default\\s+)?(?:abstract\\s+)?(class)\\s+([A-Za-z_$][\\w$]*)"),
          DocumentIndexer.keyworded("^(?:export\\s+)?(interface|enum)\\s+([A-Za-z_$][\\w$]*)"),
          DocumentIndexer.keyworded("^(?:export\\s+)?(type)\\s+([A-Za-z_$][\\w$]*)\\s*="),
          DocumentIndexer.name(
            "^(?:export\\s+)?(?:const|let|var)\\s+([A-Za-z_$][\\w$]*)(?:\\s*:\\s*[^=]+?)?\\s*=\\s*"
              + "(?:async\\s+)?(?:function\\b|(?:\\([^)]*\\)|[A-Za-z_$][\\w$]*)\\s*=>)"),
          LinePattern(
            regex: DocumentIndexer.regex(
              "^(?:(?:public|private|protected|static|readonly|async|override|get|set)\\s+)*"
                + "([A-Za-z_$][\\w$]*)\\s*\\([^)]*\\)\\s*(?::\\s*[^{;]+)?\\{$")
          ) { match, line in
            guard let name = DocumentIndexer.group(1, of: match, in: line) else { return nil }
            let excluded: Set<String> = [
              "if", "for", "while", "switch", "catch", "do", "else", "return", "new",
              "typeof", "await", "yield", "function",
            ]
            return excluded.contains(name) ? nil : name
          },
        ]
      case .kotlin:
        let modifiers =
          "^(?:(?:public|private|protected|internal|open|override|suspend|inline|operator"
          + "|infix|abstract|final|tailrec|external|actual|expect)\\s+)*"
        return [
          DocumentIndexer.name(
            modifiers + "fun\\s+(?:<[^>]+>\\s+)?(?:[\\w\\.]+\\.)?([A-Za-z_]\\w*)"),
          DocumentIndexer.keyworded(
            "^(?:(?:public|private|protected|internal|open|abstract|final|sealed|data"
              + "|annotation|inner|value|enum)\\s+)*(class|interface|object)\\s+([A-Za-z_]\\w*)"),
        ]
      case .php:
        return [
          DocumentIndexer.name(
            "^(?:(?:public|private|protected|static|abstract|final)\\s+)*function\\s+&?\\s*"
              + "([A-Za-z_]\\w*)"),
          DocumentIndexer.keyworded(
            "^(?:(?:abstract|final|readonly)\\s+)*(class|interface|trait|enum)\\s+"
              + "([A-Za-z_]\\w*)"),
        ]
      case .shell:
        return [
          DocumentIndexer.name("^(?:function\\s+)?([A-Za-z_][\\w-]*)\\s*\\(\\s*\\)"),
          DocumentIndexer.name("^function\\s+([A-Za-z_][\\w-]*)\\b"),
        ]
      case .perl:
        return [
          DocumentIndexer.name("^sub\\s+([A-Za-z_]\\w*)")
        ]
      case .lua:
        return [
          DocumentIndexer.name("^(?:local\\s+)?function\\s+([A-Za-z_][\\w\\.:]*)")
        ]
      }
    }
  }
}
