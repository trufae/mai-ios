import Foundation

#if canImport(AppKit)
  import AppKit
#endif

/// Writes text to the system clipboard. macOS uses the native pasteboard; other
/// platforms shell out to the first available clipboard tool.
enum SystemClipboard {
  static func write(_ text: String) throws {
    #if canImport(AppKit)
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      guard pasteboard.setString(text, forType: .string) else {
        throw ClipboardError.writeFailed("NSPasteboard rejected the text.")
      }
    #else
      try writeUsingExternalTool(text)
    #endif
  }

  /// Command lines tried in order on platforms without a native pasteboard API.
  static let externalTools: [[String]] = [
    ["wl-copy"],
    ["xclip", "-selection", "clipboard"],
    ["xsel", "--clipboard", "--input"],
    ["pbcopy"],
    ["clip.exe"],
  ]

  static func writeUsingExternalTool(
    _ text: String,
    searchPath: [String] = ProcessInfo.processInfo.environment["PATH"]?
      .split(separator: ":").map(String.init) ?? []
  ) throws {
    guard let command = externalTools.compactMap({ resolve($0, searchPath: searchPath) }).first
    else {
      let names = externalTools.map { $0[0] }.joined(separator: ", ")
      throw ClipboardError.unavailable("No clipboard tool found in PATH (tried \(names)).")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command[0])
    process.arguments = Array(command.dropFirst())
    let input = Pipe()
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    input.fileHandleForWriting.write(Data(text.utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw ClipboardError.writeFailed(
        "\(command[0]) exited with status \(process.terminationStatus).")
    }
  }

  private static func resolve(_ command: [String], searchPath: [String]) -> [String]? {
    guard let name = command.first else { return nil }
    for directory in searchPath {
      let candidate = (directory as NSString).appendingPathComponent(name)
      if FileManager.default.isExecutableFile(atPath: candidate) {
        return [candidate] + command.dropFirst()
      }
    }
    return nil
  }
}

enum ClipboardError: LocalizedError {
  case unavailable(String)
  case writeFailed(String)

  var errorDescription: String? {
    switch self {
    case .unavailable(let reason): "Clipboard unavailable: \(reason)"
    case .writeFailed(let reason): "Clipboard write failed: \(reason)"
    }
  }
}
