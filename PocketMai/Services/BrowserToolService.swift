import Foundation
import UIKit
import Vision

/// The in-app browser exposed to the model as four tools: open a page, read
/// it, act on it, run JavaScript in it. The page lives in a picture-in-picture
/// card the user can enlarge to take over by hand (sign-ins, captchas) and
/// hand back.
@MainActor
enum BrowserTool {
  static let openName = "browser_open"
  static let readName = "browser_read"
  static let actName = "browser_act"
  static let evalName = "browser_eval"
  static let toolNames = [openName, readName, actName, evalName]

  private static let defaultReadLimit = 6000
  private static let openDigestLimit = 3000
  private static let actDigestLimit = 1200
  private static let maxWaitSeconds = 15.0

  static let definitions: [ToolDefinition] = [
    ToolDefinition(
      name: openName,
      description:
        "Open a web page in the in-app browser. The page shows in a small picture-in-picture card; the user can tap it to enlarge and operate the page by hand (for example to sign in) and then tell you to continue. Returns the final URL, the title and the page text.",
      parameters: [
        ToolParameterDef(
          name: "url", type: "string", description: "Address to open. https:// is assumed.",
          required: true)
      ]),
    ToolDefinition(
      name: readName,
      description:
        "Inspect the current page without changing it. what=text returns the readable text (default); links lists visible links; elements lists interactive elements with numeric refs to use as browser_act targets; html returns the markup; screenshot runs on-device text recognition on the visible area and returns each text line with its x,y position, usable as a browser_act target.",
      parameters: [
        ToolParameterDef(
          name: "what", type: "string",
          description: "text, links, elements, html, or screenshot. Default: text.",
          required: false),
        ToolParameterDef(
          name: "selector", type: "string",
          description:
            "CSS selector that limits text, links, elements, or html to one part of the page.",
          required: false),
        ToolParameterDef(
          name: "max_chars", type: "integer",
          description: "Cut the result after this many characters. Default: 6000.",
          required: false),
      ]),
    ToolDefinition(
      name: actName,
      description:
        "Interact with the current page. action=click taps the target; type puts text into the target field (submit=true then presses Enter); scroll moves the page (direction up or down, optional amount in pixels, or a target to scroll to); back returns to the previous page; wait pauses for seconds so a slow page can update. A target is a CSS selector, a ref number from browser_read elements, text=<visible label>, or x,y viewport coordinates from a screenshot. Returns what changed plus the text now visible.",
      parameters: [
        ToolParameterDef(
          name: "action", type: "string",
          description: "click, type, scroll, back, or wait.", required: true),
        ToolParameterDef(
          name: "target", type: "string",
          description: "Element to act on: CSS selector, ref number, text=<label>, or x,y.",
          required: false),
        ToolParameterDef(
          name: "text", type: "string", description: "Text to type.", required: false),
        ToolParameterDef(
          name: "submit", type: "boolean",
          description: "After typing, press Enter / submit the form.", required: false),
        ToolParameterDef(
          name: "direction", type: "string",
          description: "For scroll: up or down. Default: down.", required: false),
        ToolParameterDef(
          name: "amount", type: "integer",
          description: "For scroll: pixels to move. Default: most of one screen.",
          required: false),
        ToolParameterDef(
          name: "seconds", type: "number",
          description: "For wait: seconds to pause, up to 15. Default: 2.", required: false),
      ]),
    ToolDefinition(
      name: evalName,
      description:
        "Run JavaScript in the current page and return the result as text. A single expression returns its value; a multi-statement script must return one. await is supported and DOM nodes come back as HTML.",
      parameters: [
        ToolParameterDef(
          name: "script", type: "string", description: "JavaScript to run.", required: true),
        ToolParameterDef(
          name: "max_chars", type: "integer",
          description: "Cut the result after this many characters. Default: 6000.",
          required: false),
      ]),
  ]

  static func execute(
    name: String,
    arguments: [String: AgentToolArgumentValue],
    store: AppStore
  ) async -> String {
    let session = store.ensureBrowserSession()
    session.noteActivity(activitySummary(name: name, arguments: arguments))
    switch name {
    case openName:
      return await open(arguments, session: session)
    case readName:
      return await read(arguments, session: session)
    case actName:
      return await act(arguments, session: session)
    case evalName:
      return await eval(arguments, session: session)
    default:
      return "Error: unknown browser tool '\(name)'."
    }
  }

  // MARK: - Tools

  private static func open(
    _ arguments: [String: AgentToolArgumentValue],
    session: BrowserSession
  ) async -> String {
    let raw = arguments["url"]?.stringValue ?? ""
    guard let url = BrowserSession.url(from: raw) else {
      return "Error: '\(raw)' is not an http(s) URL."
    }
    await session.load(url)
    return await digest(session: session, limit: openDigestLimit, visibleOnly: false)
  }

  private static func read(
    _ arguments: [String: AgentToolArgumentValue],
    session: BrowserSession
  ) async -> String {
    let what = string(arguments["what"]).lowercased()
    let selector = string(arguments["selector"])
    let limit = charLimit(arguments["max_chars"], default: defaultReadLimit)
    let scriptArguments: [String: Any] = ["selector": selector, "max": limit]
    let body: String
    switch what {
    case "", "text":
      body = "return __pm.text(selector || null, max);"
    case "links":
      body = "return __pm.links(selector || null, max);"
    case "elements":
      body = "return __pm.elements(selector || null, max);"
    case "html":
      body = "return __pm.html(selector || null, max);"
    case "screenshot":
      return await screenshotText(session: session, limit: limit)
    default:
      return "Error: what must be text, links, elements, html, or screenshot."
    }
    let result = await session.call(body, arguments: scriptArguments)
    return withNotices(session: session, header(session: session) + "\n\n" + result)
  }

  private static func act(
    _ arguments: [String: AgentToolArgumentValue],
    session: BrowserSession
  ) async -> String {
    let action = string(arguments["action"]).lowercased()
    let target = string(arguments["target"])
    let outcome: String
    switch action {
    case "click":
      guard !target.isEmpty else { return "Error: click needs a target." }
      outcome = await session.call(
        "return __pm.click(target);", arguments: ["target": target])
      await session.waitForLoad()
    case "type":
      let text = arguments["text"]?.stringValue ?? ""
      let submit = bool(arguments["submit"])
      outcome = await session.call(
        "return __pm.type(target, text, submit);",
        arguments: ["target": target, "text": text, "submit": submit])
      if submit {
        await session.waitForLoad()
      }
    case "scroll":
      let direction = string(arguments["direction"]).lowercased() == "up" ? "up" : "down"
      let amount = int(arguments["amount"]) ?? 0
      outcome = await session.call(
        "return __pm.scroll(direction, amount, target || null);",
        arguments: ["direction": direction, "amount": amount, "target": target])
      try? await Task.sleep(for: .milliseconds(300))
    case "back":
      await session.goBack()
      outcome = "Went back."
    case "wait":
      let seconds = min(maxWaitSeconds, max(0.1, double(arguments["seconds"]) ?? 2))
      try? await Task.sleep(for: .seconds(seconds))
      await session.waitForLoad(timeout: 1)
      outcome = "Waited \(Self.format(seconds))s."
    default:
      return "Error: action must be click, type, scroll, back, or wait."
    }
    if outcome.hasPrefix("Error:") {
      return withNotices(session: session, outcome)
    }
    let digest = await digest(session: session, limit: actDigestLimit, visibleOnly: true)
    return "\(outcome)\n\n\(digest)"
  }

  private static func eval(
    _ arguments: [String: AgentToolArgumentValue],
    session: BrowserSession
  ) async -> String {
    let script = arguments["script"]?.stringValue ?? ""
    guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return "Error: script is required."
    }
    let limit = charLimit(arguments["max_chars"], default: defaultReadLimit)
    let result = await session.call(
      "return await __pm.eval(script, max);", arguments: ["script": script, "max": limit])
    return withNotices(session: session, result)
  }

  // MARK: - Screenshot recognition

  private struct RecognizedLine: Sendable {
    let text: String
    let center: CGPoint
    let height: CGFloat
  }

  /// Vision runs on a JPEG of the snapshot so nothing non-Sendable crosses
  /// into the detached task.
  private static func screenshotText(session: BrowserSession, limit: Int) async -> String {
    let image: UIImage
    do {
      image = try await session.snapshot()
    } catch {
      return "Error: could not capture the page: \(error.localizedDescription)"
    }
    let size = image.size
    guard size.width > 0, size.height > 0, let data = image.jpegData(compressionQuality: 0.85)
    else {
      return "Error: the snapshot is empty; is the page still loading?"
    }
    let lines = await Task.detached(priority: .userInitiated) {
      recognizeText(in: data, pointSize: size)
    }.value
    let viewport = "Viewport \(Int(size.width))x\(Int(size.height)) points."
    guard !lines.isEmpty else {
      return withNotices(
        session: session,
        "\(header(session: session))\n\(viewport)\nNo text was recognized in the visible area.")
    }
    let body = lines.map { line in
      "(\(Int(line.center.x.rounded())),\(Int(line.center.y.rounded()))) \(line.text)"
    }
    .joined(separator: "\n")
    let text = """
      \(header(session: session))
      \(viewport) Lines are listed top to bottom as (x,y) = center; pass "x,y" as a browser_act target to click there.

      \(body)
      """
    return withNotices(session: session, truncated(text, limit: limit))
  }

  private nonisolated static func recognizeText(in data: Data, pointSize: CGSize)
    -> [RecognizedLine]
  {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    guard (try? VNImageRequestHandler(data: data, options: [:]).perform([request])) != nil else {
      return []
    }
    var lines: [RecognizedLine] = []
    for observation in request.results ?? [] {
      guard let candidate = observation.topCandidates(1).first else { continue }
      let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { continue }
      let box = observation.boundingBox
      lines.append(
        RecognizedLine(
          text: text,
          center: CGPoint(x: box.midX * pointSize.width, y: (1 - box.midY) * pointSize.height),
          height: box.height * pointSize.height))
    }
    lines.sort { lhs, rhs in
      let tolerance = min(lhs.height, rhs.height) * 0.5
      if abs(lhs.center.y - rhs.center.y) > tolerance {
        return lhs.center.y < rhs.center.y
      }
      return lhs.center.x < rhs.center.x
    }
    return Array(lines.prefix(250))
  }

  // MARK: - Result shaping

  private static func activitySummary(name: String, arguments: [String: AgentToolArgumentValue])
    -> String
  {
    switch name {
    case openName:
      let host =
        BrowserSession.url(from: string(arguments["url"]))?.host ?? string(arguments["url"])
      return "open \(host)"
    case readName:
      let what = string(arguments["what"]).lowercased()
      return "read \(what.isEmpty ? "text" : what)"
    case actName:
      let action = string(arguments["action"]).lowercased()
      let target = string(arguments["target"])
      switch action {
      case "type":
        return target.isEmpty ? "type" : "type into \(target)"
      case "scroll":
        return "scroll \(string(arguments["direction"]).lowercased() == "up" ? "up" : "down")"
      default:
        return target.isEmpty ? action : "\(action) \(target)"
      }
    case evalName:
      return "eval \(string(arguments["script"]))"
    default:
      return name
    }
  }

  private static func header(session: BrowserSession) -> String {
    let url = session.currentURL?.absoluteString ?? "about:blank"
    let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return "URL: \(url)\nTitle: \(title.isEmpty ? "(untitled)" : title)"
      + (session.isLoading ? "\n(still loading)" : "")
  }

  private static func digest(session: BrowserSession, limit: Int, visibleOnly: Bool) async
    -> String
  {
    let body =
      visibleOnly
      ? "return __pm.visibleText(max);"
      : "return __pm.text(null, max);"
    let text = await session.call(body, arguments: ["max": limit])
    let label = visibleOnly ? "Visible text" : "Page text"
    return withNotices(session: session, "\(header(session: session))\n\n\(label):\n\(text)")
  }

  private static func withNotices(session: BrowserSession, _ text: String) -> String {
    let notices = session.takePendingNotices()
    guard !notices.isEmpty else { return text }
    return notices.joined(separator: "\n") + "\n\n" + text
  }

  private static func truncated(_ text: String, limit: Int) -> String {
    guard text.count > limit else { return text }
    return String(text.prefix(limit)) + "\n…[truncated, \(text.count - limit) more characters]"
  }

  // MARK: - Argument helpers

  private static func string(_ value: AgentToolArgumentValue?) -> String {
    value?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  private static func bool(_ value: AgentToolArgumentValue?) -> Bool {
    switch value {
    case .bool(let flag): return flag
    case .int(let number): return number != 0
    case .string(let text):
      return ["true", "yes", "1", "on"].contains(
        text.trimmingCharacters(in: .whitespaces).lowercased())
    default: return false
    }
  }

  private static func int(_ value: AgentToolArgumentValue?) -> Int? {
    switch value {
    case .int(let number): return number
    case .double(let number): return Int(number)
    case .string(let text): return Int(text.trimmingCharacters(in: .whitespaces))
    default: return nil
    }
  }

  private static func double(_ value: AgentToolArgumentValue?) -> Double? {
    switch value {
    case .int(let number): return Double(number)
    case .double(let number): return number
    case .string(let text): return Double(text.trimmingCharacters(in: .whitespaces))
    default: return nil
    }
  }

  private static func charLimit(_ value: AgentToolArgumentValue?, default fallback: Int) -> Int {
    guard let requested = int(value), requested > 0 else { return fallback }
    return min(requested, 60_000)
  }

  private static func format(_ seconds: Double) -> String {
    seconds.rounded() == seconds ? String(Int(seconds)) : String(format: "%.1f", seconds)
  }
}
