import Foundation
import MaiCore

#if canImport(Android)
  import Android
#elseif canImport(Musl)
  import Musl
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

/// Where a line editor draws. The classic surface owns the current row of a
/// scrolling terminal, the way a shell prompt does; `TerminalScreen` owns a
/// row that stays below the output while agents print.
protocol LineEditorSurface: AnyObject {
  /// Draws the whole input row: `styled` after clearing it, `width` columns
  /// wide, with the caret `caretBack` columns left of its end.
  func drawInput(styled: String, width: Int, caretBack: Int)
  /// The line was accepted: it stays on screen as a record and the row is free.
  func acceptInput(styled: String)
  /// Ctrl+C threw the line away.
  func cancelInput()
  /// Text that belongs with the output, such as completion candidates.
  func emit(_ text: String)
  /// The line drawn above a fresh prompt, or nothing.
  func drawSeparator(styled: String?)
  func bell()
  /// Hands the terminal back to the shell for Ctrl+Z and takes it again.
  func suspendProcess()
}

/// The surface of a plain scrolling terminal: everything happens on the row
/// the cursor is on, and the editor owns the tty mode while it reads.
private final class ClassicEditorSurface: LineEditorSurface {
  private var cooked: termios
  private var raw: termios

  init(cooked: termios, raw: termios) {
    self.cooked = cooked
    self.raw = raw
  }

  func drawInput(styled: String, width: Int, caretBack: Int) {
    write("\r\u{1B}[2K" + styled)
    if caretBack > 0 { write("\u{1B}[\(caretBack)D") }
  }

  func acceptInput(styled: String) {
    write("\r\u{1B}[2K" + styled + "\n")
  }

  func cancelInput() {
    write("\r\u{1B}[2K^C\n")
  }

  func emit(_ text: String) {
    write("\n" + text)
  }

  func drawSeparator(styled: String?) {
    guard let styled else { return }
    write("\r\u{1B}[2K" + styled + "\n")
  }

  func bell() {
    write("\u{7}")
  }

  func suspendProcess() {
    // ISIG is disabled while editing so Ctrl+Z arrives as a byte. Restore the
    // shell's terminal mode before stopping, then re-enter raw mode after `fg`.
    write("\r\u{1B}[2K^Z\n")
    _ = tcsetattr(STDIN_FILENO, TCSADRAIN, &cooked)
    _ = kill(getpid(), SIGTSTP)
    _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
  }

  private func write(_ value: String) {
    FileHandle.standardOutput.write(Data(value.utf8))
  }
}

/// Small dependency-free line editor for the REPL. Non-interactive input keeps
/// normal `readLine` behaviour, while terminals gain history and completion.
final class TerminalLineEditor {
  private struct ReverseSearchState {
    var query: [UInt8] = []
    var matchIndex: Int?
    var failed: Bool
  }

  private enum ReverseSearchResult {
    case accepted(line: [UInt8], historyIndex: Int?, cursor: Int)
    case cancelled
    case interrupted
    case submitted([UInt8])
    case endOfFile
  }

  private let historyURL: URL?
  private var history: [String]
  private let maximumHistory = 500
  private var ui = ConfiguredTerminalUI()
  private(set) var wasInterrupted = false
  /// A surface that owns the tty for the whole session. While one is
  /// installed the editor neither changes the terminal mode nor draws a
  /// separator; the surface keeps the row and the status line.
  private var persistentSurface: LineEditorSurface?
  /// Where the current `readLine` draws.
  private var surface: LineEditorSurface?

  init(historyURL: URL? = nil) {
    self.historyURL = historyURL
    history = Self.loadHistory(from: historyURL)
  }

  func configure(ui: ConfiguredTerminalUI) {
    self.ui = ui
  }

  func install(surface: LineEditorSurface?) {
    persistentSurface = surface
  }

  func readLine(
    prompt: String,
    completions: [String],
    separator: String? = nil,
    rememberInput: Bool = true
  ) -> String? {
    wasInterrupted = false
    if let persistentSurface {
      surface = persistentSurface
      defer { surface = nil }
      return readInteractive(
        prompt: prompt, completions: completions, separator: nil, rememberInput: rememberInput)
    }
    guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
      FileHandle.standardOutput.write(Data(prompt.utf8))
      guard let line = Swift.readLine(strippingNewline: true) else { return nil }
      if rememberInput { remember(line) }
      return line
    }

    var original = termios()
    guard tcgetattr(STDIN_FILENO, &original) == 0 else {
      FileHandle.standardOutput.write(Data(prompt.utf8))
      guard let line = Swift.readLine(strippingNewline: true) else { return nil }
      if rememberInput { remember(line) }
      return line
    }
    var raw = original
    raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
    raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
    guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return nil }
    defer { _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &original) }
    surface = ClassicEditorSurface(cooked: original, raw: raw)
    defer { surface = nil }
    return readInteractive(
      prompt: prompt, completions: completions, separator: separator, rememberInput: rememberInput)
  }

  private func readInteractive(
    prompt: String,
    completions: [String],
    separator: String?,
    rememberInput: Bool
  ) -> String? {
    var bytes: [UInt8] = []
    var cursor = 0
    var historyIndex: Int?
    var draft: [UInt8] = []
    drawSeparator(separator)
    redraw(prompt: prompt, bytes: bytes, cursor: cursor)

    while let byte = readByte() {
      switch byte {
      case 1:  // Ctrl+A
        cursor = 0
        redraw(prompt: prompt, bytes: bytes, cursor: cursor)
      case 2:  // Ctrl+B, like Left
        cursor = previousCharacterStart(in: bytes, before: cursor)
        redraw(prompt: prompt, bytes: bytes, cursor: cursor)
      case 3:  // Ctrl+C
        wasInterrupted = true
        surface?.cancelInput()
        return ""
      case 4:  // Ctrl+D
        if bytes.isEmpty {
          surface?.acceptInput(styled: "")
          return nil
        }
      case 5:  // Ctrl+E
        cursor = bytes.count
        redraw(prompt: prompt, bytes: bytes, cursor: cursor)
      case 6:  // Ctrl+F, like Right
        cursor = nextCharacterEnd(in: bytes, after: cursor)
        redraw(prompt: prompt, bytes: bytes, cursor: cursor)
      case 9:  // Tab
        complete(
          prompt: prompt,
          bytes: &bytes,
          cursor: &cursor,
          candidates: completions)
      case 14:  // Ctrl+N
        guard
          recallNextHistoryEntry(
            bytes: &bytes,
            cursor: &cursor,
            historyIndex: &historyIndex,
            draft: &draft)
        else { continue }
        redraw(prompt: prompt, bytes: bytes, cursor: cursor)
      case 16:  // Ctrl+P
        guard
          recallPreviousHistoryEntry(
            bytes: &bytes,
            cursor: &cursor,
            historyIndex: &historyIndex,
            draft: &draft)
        else { continue }
        redraw(prompt: prompt, bytes: bytes, cursor: cursor)
      case 18:  // Ctrl+R
        switch reverseSearch(original: bytes, startingAt: historyIndex) {
        case .accepted(let line, let index, let acceptedCursor):
          if historyIndex == nil, index != nil { draft = bytes }
          bytes = line
          cursor = acceptedCursor
          historyIndex = index
          redraw(prompt: prompt, bytes: bytes, cursor: cursor)
        case .cancelled:
          redraw(prompt: prompt, bytes: bytes, cursor: cursor)
        case .interrupted:
          wasInterrupted = true
          surface?.cancelInput()
          return ""
        case .submitted(let line):
          renderSubmittedLine(prompt: prompt, bytes: line)
          let submitted = String(decoding: line, as: UTF8.self)
          if rememberInput { remember(submitted) }
          return submitted
        case .endOfFile:
          surface?.acceptInput(styled: "")
          return nil
        }
      case 23:  // Ctrl+W
        guard cursor > 0 else { continue }
        let start = previousWordStart(in: bytes, before: cursor)
        bytes.removeSubrange(start..<cursor)
        cursor = start
        historyIndex = nil
        redraw(prompt: prompt, bytes: bytes, cursor: cursor)
      case 26:  // Ctrl+Z
        surface?.suspendProcess()
        drawSeparator(separator)
        redraw(prompt: prompt, bytes: bytes, cursor: cursor)
      case 10, 13:
        renderSubmittedLine(prompt: prompt, bytes: bytes)
        let line = String(decoding: bytes, as: UTF8.self)
        if rememberInput { remember(line) }
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
    surface?.acceptInput(styled: "")
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
      guard
        recallPreviousHistoryEntry(
          bytes: &bytes,
          cursor: &cursor,
          historyIndex: &historyIndex,
          draft: &draft)
      else { return }
    case 66:  // Down
      guard
        recallNextHistoryEntry(
          bytes: &bytes,
          cursor: &cursor,
          historyIndex: &historyIndex,
          draft: &draft)
      else { return }
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

  private func recallPreviousHistoryEntry(
    bytes: inout [UInt8],
    cursor: inout Int,
    historyIndex: inout Int?,
    draft: inout [UInt8]
  ) -> Bool {
    guard !history.isEmpty else { return false }
    if historyIndex == nil {
      draft = bytes
      historyIndex = history.count - 1
    } else if historyIndex! > 0 {
      historyIndex! -= 1
    }
    bytes = Array(history[historyIndex!].utf8)
    cursor = bytes.count
    return true
  }

  private func recallNextHistoryEntry(
    bytes: inout [UInt8],
    cursor: inout Int,
    historyIndex: inout Int?,
    draft: inout [UInt8]
  ) -> Bool {
    guard let index = historyIndex else { return false }
    if index + 1 < history.count {
      historyIndex = index + 1
      bytes = Array(history[index + 1].utf8)
    } else {
      historyIndex = nil
      bytes = draft
    }
    cursor = bytes.count
    return true
  }

  private func reverseSearch(original: [UInt8], startingAt historyIndex: Int?)
    -> ReverseSearchResult
  {
    let initialIndex = historyIndex ?? history.indices.last
    var state = ReverseSearchState(
      matchIndex: initialIndex,
      failed: initialIndex == nil)
    var undoStack: [ReverseSearchState] = []
    redrawReverseSearch(state, original: original)

    while let byte = readByte() {
      switch byte {
      case 1:  // Ctrl+A accepts the match and moves to its beginning.
        let selection = reverseSearchSelection(state, original: original)
        return .accepted(line: selection, historyIndex: state.matchIndex, cursor: 0)
      case 2:  // Ctrl+B accepts the match one character from its end, like Left.
        let selection = reverseSearchSelection(state, original: original)
        return .accepted(
          line: selection,
          historyIndex: state.matchIndex,
          cursor: previousCharacterStart(in: selection, before: selection.count))
      case 3:  // Ctrl+C cancels the whole input.
        return .interrupted
      case 5, 6:  // Ctrl+E and Ctrl+F accept the match and move to its end.
        let selection = reverseSearchSelection(state, original: original)
        return .accepted(
          line: selection,
          historyIndex: state.matchIndex,
          cursor: selection.count)
      case 7:  // Ctrl+G restores the line from before the search.
        return .cancelled
      case 9:  // Tab accepts the match for editing.
        let selection = reverseSearchSelection(state, original: original)
        return .accepted(
          line: selection,
          historyIndex: state.matchIndex,
          cursor: selection.count)
      case 10, 13:
        return .submitted(reverseSearchSelection(state, original: original))
      case 18:  // Ctrl+R repeats the search before the current match.
        if let index = state.matchIndex,
          let match = matchingHistoryIndex(for: state.query, atOrBefore: index - 1)
        {
          state.matchIndex = match
          state.failed = false
        } else {
          state.failed = true
          surface?.bell()
        }
      case 27:  // An escape sequence accepts the match for editing.
        let selection = reverseSearchSelection(state, original: original)
        guard readByte() == 91, let code = readByte() else {
          return .accepted(
            line: selection,
            historyIndex: state.matchIndex,
            cursor: selection.count)
        }
        if code == 51 { _ = readByte() }
        let acceptedCursor =
          code == 68
          ? previousCharacterStart(in: selection, before: selection.count)
          : selection.count
        return .accepted(
          line: selection,
          historyIndex: state.matchIndex,
          cursor: acceptedCursor)
      case 127, 8:
        guard let previous = undoStack.popLast() else {
          surface?.bell()
          continue
        }
        state = previous
      default:
        guard byte >= 32 else {
          surface?.bell()
          continue
        }
        let character = readCharacter(startingWith: byte)
        undoStack.append(state)
        state.query.append(contentsOf: character)
        if let match = matchingHistoryIndex(
          for: state.query,
          atOrBefore: state.matchIndex ?? history.count - 1)
        {
          state.matchIndex = match
          state.failed = false
        } else {
          state.failed = true
          surface?.bell()
        }
      }
      redrawReverseSearch(state, original: original)
    }
    return .endOfFile
  }

  private func matchingHistoryIndex(for query: [UInt8], atOrBefore upperBound: Int) -> Int? {
    guard upperBound >= 0, !history.isEmpty else { return nil }
    let needle = String(decoding: query, as: UTF8.self)
    if needle.isEmpty { return min(upperBound, history.count - 1) }
    for index in stride(from: min(upperBound, history.count - 1), through: 0, by: -1) {
      if history[index].contains(needle) { return index }
    }
    return nil
  }

  private func reverseSearchSelection(_ state: ReverseSearchState, original: [UInt8]) -> [UInt8] {
    guard let index = state.matchIndex else { return original }
    return Array(history[index].utf8)
  }

  private func redrawReverseSearch(_ state: ReverseSearchState, original: [UInt8]) {
    let mode = state.failed ? "failed reverse-i-search" : "reverse-i-search"
    let query = String(decoding: state.query, as: UTF8.self)
    let selection = reverseSearchSelection(state, original: original)
    redraw(
      prompt: "(\(mode))`\(query)': ",
      bytes: selection,
      cursor: selection.count)
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
      surface?.bell()
      return
    }
    let replacement: String
    if matches.count == 1 {
      replacement = matches[0] + (matches[0].hasSuffix(" ") ? "" : " ")
    } else {
      replacement = commonPrefix(matches)
      if replacement == line {
        surface?.emit(matches.joined(separator: "  ") + "\n")
      }
    }
    bytes = Array(replacement.utf8)
    cursor = bytes.count
    redraw(prompt: prompt, bytes: bytes, cursor: cursor)
  }

  private func redraw(prompt: String, bytes: [UInt8], cursor: Int) {
    // Leave the terminal's final column unused: printing into it can trigger an
    // automatic wrap, after which clearing one row no longer erases the input.
    let lineWidth = max(1, Self.terminalColumns() - 1)
    let minimumInputWidth = min(12, max(1, lineWidth / 2))
    let visiblePrompt = truncatedPrompt(prompt, maximumWidth: lineWidth - minimumInputWidth)
    let inputWidth = max(1, lineWidth - displayWidth(visiblePrompt))
    let visibleRange = visibleInputRange(in: bytes, cursor: cursor, maximumWidth: inputWidth)
    let visibleInput = String(decoding: bytes[visibleRange], as: UTF8.self)
    let promptStyle = style(foreground: ui.promptForeground, background: ui.promptBackground)
    let inputStyle = style(foreground: ui.foreground, background: ui.background, bold: ui.bold)
    let hasInputBackground = Self.colorCode(ui.background, background: true) != nil
    let paddingWidth = hasInputBackground ? max(0, inputWidth - displayWidth(visibleInput)) : 0
    let padding = String(repeating: " ", count: paddingWidth)
    let styled =
      promptStyle + visiblePrompt + resetStyle + inputStyle + visibleInput + padding + resetStyle
    let width = displayWidth(visiblePrompt) + displayWidth(visibleInput) + paddingWidth
    let suffixWidth = displayWidth(bytes[cursor..<visibleRange.upperBound])
    surface?.drawInput(styled: styled, width: width, caretBack: suffixWidth + paddingWidth)
  }

  /// The prompt and line as they appear once accepted, for the surface to keep.
  func styledLine(prompt: String, text: String) -> String {
    let promptStyle = style(foreground: ui.promptForeground, background: ui.promptBackground)
    let inputStyle = style(foreground: ui.foreground, background: ui.background, bold: ui.bold)
    return promptStyle + prompt + resetStyle + inputStyle + text + resetStyle
  }

  private func renderSubmittedLine(prompt: String, bytes: [UInt8]) {
    surface?.acceptInput(
      styled: styledLine(prompt: prompt, text: String(decoding: bytes, as: UTF8.self)))
  }

  private func drawSeparator(_ text: String?) {
    guard persistentSurface == nil,
      let background = Self.colorCode(ui.backgroundLine, background: true)
    else { return }
    let width = max(1, Self.terminalColumns() - 1)
    let content = truncatedPrompt(text.map { " \($0) " } ?? "", maximumWidth: width)
    let padding = String(repeating: " ", count: max(0, width - displayWidth(content)))
    surface?.drawSeparator(
      styled: "\u{1B}[\(background)m" + content + padding + resetStyle)
  }

  private var resetStyle: String { "\u{1B}[0m" }

  private func style(foreground: String, background: String, bold: Bool = false) -> String {
    var codes: [String] = []
    if bold { codes.append("1") }
    if let foreground = Self.colorCode(foreground, background: false) { codes.append(foreground) }
    if let background = Self.colorCode(background, background: true) { codes.append(background) }
    return codes.isEmpty ? "" : "\u{1B}[" + codes.joined(separator: ";") + "m"
  }

  private static func colorCode(_ rawValue: String, background: Bool) -> String? {
    let value = rawValue.lowercased()
    if value.hasPrefix("#"), value.count == 7 {
      let hex = String(value.dropFirst())
      guard hex.allSatisfy(\.isHexDigit), let packed = Int(hex, radix: 16) else { return nil }
      let red = (packed >> 16) & 0xFF
      let green = (packed >> 8) & 0xFF
      let blue = packed & 0xFF
      return "\(background ? 48 : 38);2;\(red);\(green);\(blue)"
    }
    if value.hasPrefix("rgb:"), value.count == 7 {
      let hex = String(value.dropFirst(4))
      guard hex.allSatisfy(\.isHexDigit), let packed = Int(hex, radix: 16) else { return nil }
      let red = ((packed >> 8) & 0xF) * 17
      let green = ((packed >> 4) & 0xF) * 17
      let blue = (packed & 0xF) * 17
      return "\(background ? 48 : 38);2;\(red);\(green);\(blue)"
    }
    let offset = background ? 10 : 0
    switch value {
    case "black": return "\(30 + offset)"
    case "red": return "\(31 + offset)"
    case "green": return "\(32 + offset)"
    case "yellow", "brown": return "\(33 + offset)"
    case "blue", "dark-blue": return "\(34 + offset)"
    case "magenta", "purple": return "\(35 + offset)"
    case "cyan": return "\(36 + offset)"
    case "white": return "\(37 + offset)"
    case "grey", "bright-black": return "\(90 + offset)"
    case "bright-red": return "\(91 + offset)"
    case "bright-green": return "\(92 + offset)"
    case "bright-yellow", "orange": return "\(93 + offset)"
    case "bright-blue": return "\(94 + offset)"
    case "bright-magenta", "violet", "pink": return "\(95 + offset)"
    case "bright-cyan": return "\(96 + offset)"
    case "bright-white": return "\(97 + offset)"
    default: return nil
    }
  }

  static func normalizedColor(_ rawValue: String) -> String? {
    let value = rawValue.lowercased()
    if ["none", "default", "off", "-"].contains(value) { return "" }
    return colorCode(value, background: false) == nil ? nil : value
  }

  static func foregroundColorCode(_ value: String) -> String? {
    colorCode(value, background: false)
  }

  static func backgroundColorCode(_ value: String) -> String? {
    colorCode(value, background: true)
  }

  static func terminalColumns() -> Int {
    var size = winsize()
    guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0, size.ws_col > 0 else { return 80 }
    return Int(size.ws_col)
  }

  private func truncatedPrompt(_ prompt: String, maximumWidth: Int) -> String {
    guard maximumWidth > 0 else { return "" }
    guard displayWidth(prompt) > maximumWidth else { return prompt }
    guard maximumWidth > 2 else { return String(repeating: " ", count: maximumWidth) }
    let contentWidth = maximumWidth - 2
    var result = ""
    var width = 0
    for character in prompt {
      let characterWidth = displayWidth(String(character))
      guard width + characterWidth <= contentWidth else { break }
      result.append(character)
      width += characterWidth
    }
    return result + "… "
  }

  private func visibleInputRange(
    in bytes: [UInt8],
    cursor: Int,
    maximumWidth: Int
  ) -> Range<Int> {
    var start = cursor
    var width = 0
    while start > 0 {
      let previous = previousCharacterStart(in: bytes, before: start)
      let characterWidth = displayWidth(bytes[previous..<start])
      guard width + characterWidth <= maximumWidth else { break }
      start = previous
      width += characterWidth
    }

    var end = cursor
    while end < bytes.count {
      let next = nextCharacterEnd(in: bytes, after: end)
      let characterWidth = displayWidth(bytes[end..<next])
      guard width + characterWidth <= maximumWidth else { break }
      end = next
      width += characterWidth
    }
    return start..<end
  }

  private func displayWidth(_ bytes: ArraySlice<UInt8>) -> Int {
    displayWidth(String(decoding: bytes, as: UTF8.self))
  }

  private func displayWidth(_ value: String) -> Int {
    Self.displayWidth(of: value)
  }

  /// Terminal columns a string occupies: wide and emoji characters take two,
  /// combining marks none.
  static func displayWidth(of value: String) -> Int {
    value.reduce(into: 0) { width, character in
      let scalars = character.unicodeScalars
      if scalars.allSatisfy({
        switch $0.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: true
        default: false
        }
      }) {
        return
      }
      let emojiPresentation =
        scalars.contains { $0.properties.isEmojiPresentation }
        || (scalars.contains { $0.value == 0xFE0F } && scalars.contains { $0.properties.isEmoji })
      width += emojiPresentation || scalars.contains { isWide($0.value) } ? 2 : 1
    }
  }

  private static func isWide(_ value: UInt32) -> Bool {
    switch value {
    case 0x1100...0x115F, 0x2329...0x232A, 0x2E80...0xA4CF, 0xAC00...0xD7A3,
      0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F, 0xFF00...0xFF60,
      0xFFE0...0xFFE6, 0x1F300...0x1FAFF, 0x20000...0x3FFFD:
      true
    default:
      false
    }
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
    return characterBoundaries(in: bytes).last(where: { $0 < position }) ?? 0
  }

  private func nextCharacterEnd(in bytes: [UInt8], after position: Int) -> Int {
    guard position < bytes.count else { return bytes.count }
    return characterBoundaries(in: bytes).first(where: { $0 > position }) ?? bytes.count
  }

  private func characterBoundaries(in bytes: [UInt8]) -> [Int] {
    var boundaries = [0]
    var offset = 0
    for character in String(decoding: bytes, as: UTF8.self) {
      offset += character.utf8.count
      boundaries.append(min(offset, bytes.count))
    }
    if boundaries.last != bytes.count { boundaries.append(bytes.count) }
    return boundaries
  }

  private func previousWordStart(in bytes: [UInt8], before position: Int) -> Int {
    var index = position
    while index > 0 {
      let previous = previousCharacterStart(in: bytes, before: index)
      guard isWhitespace(bytes[previous..<index]) else { break }
      index = previous
    }
    while index > 0 {
      let previous = previousCharacterStart(in: bytes, before: index)
      guard !isWhitespace(bytes[previous..<index]) else { break }
      index = previous
    }
    return index
  }

  private func isWhitespace(_ bytes: ArraySlice<UInt8>) -> Bool {
    String(decoding: bytes, as: UTF8.self).allSatisfy(\.isWhitespace)
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
}
