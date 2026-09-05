import Foundation

#if os(Linux)
  import Glibc
#else
  import Darwin
#endif

/// Small dependency-free line editor for the REPL. Non-interactive input keeps
/// normal `readLine` behaviour, while terminals gain history and completion.
final class TerminalLineEditor {
  private let historyURL: URL?
  private var history: [String]
  private let maximumHistory = 500

  init(historyURL: URL? = nil) {
    self.historyURL = historyURL
    history = Self.loadHistory(from: historyURL)
  }

  func readLine(prompt: String, completions: [String]) -> String? {
    guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
      FileHandle.standardOutput.write(Data(prompt.utf8))
      guard let line = Swift.readLine(strippingNewline: true) else { return nil }
      remember(line)
      return line
    }

    var original = termios()
    guard tcgetattr(STDIN_FILENO, &original) == 0 else {
      FileHandle.standardOutput.write(Data(prompt.utf8))
      guard let line = Swift.readLine(strippingNewline: true) else { return nil }
      remember(line)
      return line
    }
    var raw = original
    raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
    raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
    guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return nil }
    defer { _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &original) }

    var bytes: [UInt8] = []
    var cursor = 0
    var historyIndex: Int?
    var draft: [UInt8] = []
    write(prompt)

    while let byte = readByte() {
      switch byte {
      case 3:  // Ctrl+C
        write("^C\n")
        return ""
      case 4:  // Ctrl+D
        if bytes.isEmpty {
          write("\n")
          return nil
        }
      case 9:  // Tab
        complete(
          prompt: prompt,
          bytes: &bytes,
          cursor: &cursor,
          candidates: completions)
      case 10, 13:
        write("\n")
        let line = String(decoding: bytes, as: UTF8.self)
        remember(line)
        return line
      case 27:
        handleEscape(
          prompt: prompt,
          bytes: &bytes,
          cursor: &cursor,
          historyIndex: &historyIndex,
          draft: &draft)
      case 127, 8:
        guard cursor > 0 else { continue }
        let previous = previousCharacterStart(in: bytes, before: cursor)
        bytes.removeSubrange(previous..<cursor)
        cursor = previous
        redraw(prompt: prompt, bytes: bytes, cursor: cursor)
      default:
        guard byte >= 32 else { continue }
        let character = readCharacter(startingWith: byte)
        bytes.insert(contentsOf: character, at: cursor)
        cursor += character.count
        historyIndex = nil
        redraw(prompt: prompt, bytes: bytes, cursor: cursor)
      }
    }
    write("\n")
    return nil
  }

  private func handleEscape(
    prompt: String,
    bytes: inout [UInt8],
    cursor: inout Int,
    historyIndex: inout Int?,
    draft: inout [UInt8]
  ) {
    guard readByte() == 91, let code = readByte() else { return }
    switch code {
    case 65:  // Up
      guard !history.isEmpty else { return }
      if historyIndex == nil {
        draft = bytes
        historyIndex = history.count - 1
      } else if historyIndex! > 0 {
        historyIndex! -= 1
      }
      bytes = Array(history[historyIndex!].utf8)
      cursor = bytes.count
    case 66:  // Down
      guard let index = historyIndex else { return }
      if index + 1 < history.count {
        historyIndex = index + 1
        bytes = Array(history[index + 1].utf8)
      } else {
        historyIndex = nil
        bytes = draft
      }
      cursor = bytes.count
    case 67:  // Right
      cursor = nextCharacterEnd(in: bytes, after: cursor)
    case 68:  // Left
      cursor = previousCharacterStart(in: bytes, before: cursor)
    case 72:  // Home
      cursor = 0
    case 70:  // End
      cursor = bytes.count
    case 51:  // Delete: ESC [ 3 ~
      guard readByte() == 126, cursor < bytes.count else { return }
      let end = nextCharacterEnd(in: bytes, after: cursor)
      bytes.removeSubrange(cursor..<end)
    default:
      return
    }
    redraw(prompt: prompt, bytes: bytes, cursor: cursor)
  }

  private func complete(
    prompt: String,
    bytes: inout [UInt8],
    cursor: inout Int,
    candidates: [String]
  ) {
    guard cursor == bytes.count else { return }
    let line = String(decoding: bytes, as: UTF8.self)
    let matches = candidates.filter { $0.hasPrefix(line) }.sorted()
    guard !matches.isEmpty else {
      write("\u{7}")
      return
    }
    let replacement: String
    if matches.count == 1 {
      replacement = matches[0] + (matches[0].hasSuffix(" ") ? "" : " ")
    } else {
      replacement = commonPrefix(matches)
      if replacement == line {
        write("\n" + matches.joined(separator: "  ") + "\n")
      }
    }
    bytes = Array(replacement.utf8)
    cursor = bytes.count
    redraw(prompt: prompt, bytes: bytes, cursor: cursor)
  }

  private func redraw(prompt: String, bytes: [UInt8], cursor: Int) {
    let line = String(decoding: bytes, as: UTF8.self)
    write("\r\u{1B}[2K" + prompt + line)
    let suffix = String(decoding: bytes[cursor...], as: UTF8.self)
    if !suffix.isEmpty { write("\u{1B}[\(suffix.count)D") }
  }

  private func readCharacter(startingWith first: UInt8) -> [UInt8] {
    let count: Int
    switch first {
    case 0xC0...0xDF: count = 2
    case 0xE0...0xEF: count = 3
    case 0xF0...0xF7: count = 4
    default: return [first]
    }
    var result = [first]
    while result.count < count, let byte = readByte() { result.append(byte) }
    return result
  }

  private func readByte() -> UInt8? {
    var byte: UInt8 = 0
    return read(STDIN_FILENO, &byte, 1) == 1 ? byte : nil
  }

  private func previousCharacterStart(in bytes: [UInt8], before position: Int) -> Int {
    guard position > 0 else { return 0 }
    var index = position - 1
    while index > 0, bytes[index] & 0xC0 == 0x80 { index -= 1 }
    return index
  }

  private func nextCharacterEnd(in bytes: [UInt8], after position: Int) -> Int {
    guard position < bytes.count else { return bytes.count }
    var index = position + 1
    while index < bytes.count, bytes[index] & 0xC0 == 0x80 { index += 1 }
    return index
  }

  private func commonPrefix(_ values: [String]) -> String {
    guard var prefix = values.first else { return "" }
    for value in values.dropFirst() {
      while !value.hasPrefix(prefix), !prefix.isEmpty { prefix.removeLast() }
    }
    return prefix
  }

  private func remember(_ line: String) {
    guard !line.isEmpty else { return }
    if history.last != line { history.append(line) }
    if history.count > maximumHistory {
      history.removeFirst(history.count - maximumHistory)
    }
    guard let historyURL else { return }
    do {
      try FileManager.default.createDirectory(
        at: historyURL.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      try JSONEncoder().encode(history).write(to: historyURL, options: .atomic)
    } catch {
      // Input must remain usable even if history persistence is unavailable.
    }
  }

  private static func loadHistory(from url: URL?) -> [String] {
    guard let url, let data = try? Data(contentsOf: url) else { return [] }
    return (try? JSONDecoder().decode([String].self, from: data)) ?? []
  }

  private func write(_ value: String) {
    FileHandle.standardOutput.write(Data(value.utf8))
  }
}
