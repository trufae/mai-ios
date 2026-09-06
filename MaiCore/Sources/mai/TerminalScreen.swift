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

/// Keeps the prompt on screen while agents print.
///
/// The terminal is split into a scroll region — every row but the last two —
/// where replies, tool lines, and child-agent blocks land, and two rows below
/// it that never scroll: a status line and the input line. Output is written
/// at the region's saved cursor and the caret goes back to the input row, so
/// a person keeps typing while a run streams and nothing lands in their line.
/// The region starts at the top row, which is what terminals require to keep
/// scrolled-out lines in the scrollback.
///
/// One lock serialises everything that touches the tty: a block from a child
/// agent, a streamed delta, and a keystroke's redraw are each written whole.
final class TerminalScreen: LineEditorSurface, @unchecked Sendable {
  /// Rows kept below the scroll region: the status line and the input line.
  static let reservedRows = 2

  private static let currentLock = NSLock()
  nonisolated(unsafe) private static var installed: TerminalScreen?

  /// The screen the REPL activated, so a command that hands the terminal to
  /// another program — an editor, visual mode — can step aside and come back.
  static var current: TerminalScreen? {
    currentLock.withLock { installed }
  }

  static func install(_ screen: TerminalScreen?) {
    currentLock.withLock { installed = screen }
  }

  private let lock = NSLock()
  private var cooked = termios()
  private var rows = 24
  private var columns = 80
  private var ui = ConfiguredTerminalUI()
  private var statusText = ""
  private var inputStyled = ""
  private var inputWidth = 0
  private var caretBack = 0
  private var outputEndedLine = true
  private var active = false
  private var resizeSource: DispatchSourceSignal?

  private static let saveCursor = "\u{1B}7"
  private static let restoreCursor = "\u{1B}8"
  private static let clearLine = "\u{1B}[2K"
  private static let clearBelow = "\u{1B}[J"
  private static let reset = "\u{1B}[0m"

  /// Nil unless both stdin and stdout are terminals; piped sessions keep the
  /// plain one-line-at-a-time prompt.
  init?() {
    guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else { return nil }
  }

  func configure(ui: ConfiguredTerminalUI) {
    lock.withLock {
      self.ui = ui
      guard active else { return }
      drawStatusRow()
      placeCaret()
    }
  }

  /// Usable columns for one row; the last column stays free so nothing wraps.
  var lineWidth: Int {
    lock.withLock { max(1, columns - 1) }
  }

  // MARK: - Lifecycle

  /// True when the last output ended with a newline, so the next thing
  /// printed starts a fresh row.
  var outputIsAtLineStart: Bool {
    lock.withLock { outputEndedLine }
  }

  /// Enters raw mode, reserves the bottom rows, and draws them. Call before the
  /// input thread starts reading: locating the cursor needs stdin for a moment.
  func activate() {
    lock.withLock { activateLocked() }
  }

  /// Takes the terminal back after `deactivate`, with the same status and
  /// input on screen. Only valid while the input thread is parked.
  func resume() {
    lock.withLock { activateLocked() }
  }

  private func activateLocked() {
    guard !active else { return }
    measure()
    var raw = termios()
    guard tcgetattr(STDIN_FILENO, &cooked) == 0 else { return }
    raw = cooked
    raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
    raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
    guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return }
    active = true
    // Two newlines scroll exactly as much as it takes for the current row to
    // end up inside the region, whatever row it was on.
    let row = currentCursorRow() ?? rows
    let bottom = regionBottom
    var out = "\n\n"
    out += "\u{1B}[1;\(bottom)r"
    out += move(row: min(row, bottom), column: 1)
    out += Self.saveCursor
    write(out)
    outputEndedLine = true
    drawStatusRow()
    drawInputRow()
    placeCaret()
    watchResizes()
  }

  /// Gives the whole terminal back: the region is released, the reserved rows
  /// are cleared, and the tty returns to the mode the shell left it in.
  func deactivate() {
    lock.withLock { deactivateLocked() }
  }

  /// Steps aside for another program that needs the tty, then comes back with
  /// the same status and input on screen.
  func suspendTerminal(_ action: () -> Void) {
    lock.withLock {
      let wasActive = active
      if wasActive { deactivateLocked() }
      action()
      if wasActive { activateLocked() }
    }
  }

  private func deactivateLocked() {
    guard active else { return }
    resizeSource?.cancel()
    resizeSource = nil
    write(Self.restoreCursor + (outputEndedLine ? "" : "\n"))
    // Resetting the region homes the cursor, so the last output row is looked
    // up first (the input thread is parked, so stdin is free to answer) and
    // the shell continues right under it, with the reserved rows wiped.
    let row = currentCursorRow() ?? regionBottom
    write("\u{1B}[r" + move(row: max(1, row), column: 1) + "\n" + Self.clearBelow)
    _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &cooked)
    active = false
  }

  // MARK: - Output

  /// Writes into the scroll region, leaving the caret on the input row.
  func write(_ text: String, to handle: FileHandle) {
    guard !text.isEmpty else { return }
    lock.withLock {
      guard active else {
        handle.write(Data(text.utf8))
        return
      }
      if handle === FileHandle.standardOutput {
        write(Self.restoreCursor + text + Self.saveCursor)
      } else {
        write(Self.restoreCursor)
        handle.write(Data(text.utf8))
        write(Self.saveCursor)
      }
      outputEndedLine = text.hasSuffix("\n")
      placeCaret()
    }
  }

  /// Replaces the status line above the input; an unchanged line is not redrawn.
  func setStatus(_ text: String) {
    lock.withLock {
      guard text != statusText else { return }
      statusText = text
      guard active else { return }
      drawStatusRow()
      placeCaret()
    }
  }

  // MARK: - LineEditorSurface

  func drawInput(styled: String, width: Int, caretBack: Int) {
    lock.withLock {
      inputStyled = styled
      inputWidth = width
      self.caretBack = caretBack
      guard active else { return }
      drawInputRow()
      placeCaret()
    }
  }

  func acceptInput(styled: String) {
    lock.withLock {
      inputStyled = ""
      inputWidth = 0
      caretBack = 0
      guard active else { return }
      var out = Self.restoreCursor
      if !outputEndedLine { out += "\n" }
      out += styled + "\n" + Self.saveCursor
      write(out)
      outputEndedLine = true
      drawInputRow()
      placeCaret()
    }
  }

  func cancelInput() {
    acceptInput(styled: "^C")
  }

  func emit(_ text: String) {
    write(text, to: .standardOutput)
  }

  func drawSeparator(styled: String?) {
    // The status row is the separator here, and the REPL keeps it current.
  }

  func bell() {
    lock.withLock { write("\u{7}") }
  }

  func suspendProcess() {
    suspendTerminal {
      _ = kill(getpid(), SIGTSTP)
    }
  }

  // MARK: - Drawing

  private var regionBottom: Int { max(1, rows - Self.reservedRows) }

  private func drawStatusRow() {
    let width = max(1, columns - 1)
    let content = Self.truncated(" \(statusText) ", width: width)
    let padding = String(repeating: " ", count: max(0, width - Self.displayWidth(content)))
    var out = move(row: rows - 1, column: 1) + Self.clearLine
    if let background = TerminalLineEditor.backgroundColorCode(ui.backgroundLine) {
      out += "\u{1B}[\(background)m" + content + padding + Self.reset
    } else {
      out += "\u{1B}[2m" + content + Self.reset
    }
    write(out)
  }

  private func drawInputRow() {
    write(move(row: rows, column: 1) + Self.clearLine + inputStyled)
  }

  private func placeCaret() {
    write(move(row: rows, column: max(1, 1 + inputWidth - caretBack)))
  }

  private func move(row: Int, column: Int) -> String {
    "\u{1B}[\(row);\(column)H"
  }

  private func write(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
  }

  private func measure() {
    var size = winsize()
    guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0 else { return }
    if size.ws_row > Int32(Self.reservedRows) { rows = Int(size.ws_row) }
    if size.ws_col > 0 { columns = Int(size.ws_col) }
  }

  private func watchResizes() {
    signal(SIGWINCH, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
    source.setEventHandler { [weak self] in self?.resized() }
    source.resume()
    resizeSource = source
  }

  /// After a resize the saved cursor is anywhere; output continues from the
  /// bottom of the new region and the reserved rows are drawn again.
  private func resized() {
    lock.withLock {
      guard active else { return }
      measure()
      let bottom = regionBottom
      var out = "\u{1B}[1;\(bottom)r"
      out += move(row: bottom, column: 1) + Self.saveCursor
      write(out)
      outputEndedLine = true
      drawStatusRow()
      drawInputRow()
      placeCaret()
    }
  }

  /// Asks the terminal where the cursor is. Only valid before the input
  /// thread owns stdin; answers nil when the terminal stays quiet.
  private func currentCursorRow() -> Int? {
    write("\u{1B}[6n")
    var buffer: [UInt8] = []
    let deadline = Date().addingTimeInterval(0.25)
    while Date() < deadline {
      var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
      let remaining = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
      guard poll(&descriptor, 1, remaining) > 0 else { return nil }
      var byte: UInt8 = 0
      guard read(STDIN_FILENO, &byte, 1) == 1 else { return nil }
      buffer.append(byte)
      if byte == UInt8(ascii: "R") { break }
    }
    guard let start = buffer.lastIndex(of: 0x1B), buffer.last == UInt8(ascii: "R") else {
      return nil
    }
    let body = String(decoding: buffer[(start + 1)...].dropLast(), as: UTF8.self)
    guard body.hasPrefix("["), let row = Int(body.dropFirst().split(separator: ";").first ?? "")
    else { return nil }
    return row
  }

  private static func truncated(_ text: String, width: Int) -> String {
    guard displayWidth(text) > width else { return text }
    guard width > 2 else { return String(repeating: " ", count: max(0, width)) }
    var result = ""
    var used = 0
    for character in text {
      let characterWidth = displayWidth(String(character))
      guard used + characterWidth <= width - 2 else { break }
      result.append(character)
      used += characterWidth
    }
    return result + "… "
  }

  static func displayWidth(_ value: String) -> Int {
    TerminalLineEditor.displayWidth(of: value)
  }
}
