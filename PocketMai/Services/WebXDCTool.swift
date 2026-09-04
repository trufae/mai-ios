import Foundation

struct WebXDCUpdate: Codable, Sendable {
  var serial: Int
  var payloadJSON: String
  var info: String?
  var document: String?
  var summary: String?
  var sender: String
}

/// In-memory update log per webxdc app, persisted next to the app metadata.
/// The runner webview registers a listener so updates posted by the assistant
/// (via the webxdc_send_update tool) reach a running app immediately.
@MainActor
final class WebXDCUpdateHub {
  private var cache: [UUID: [WebXDCUpdate]] = [:]
  private var listeners: [UUID: [ObjectIdentifier: (WebXDCUpdate) -> Void]] = [:]
  private static let maxUpdates = 500

  func updates(appID: UUID) -> [WebXDCUpdate] {
    if let cached = cache[appID] { return cached }
    let url = WebXDCLibrary.appURL(appID).appendingPathComponent("updates.json")
    let loaded =
      (try? JSONDecoder().decode([WebXDCUpdate].self, from: Data(contentsOf: url))) ?? []
    cache[appID] = loaded
    return loaded
  }

  @discardableResult
  func post(
    appID: UUID,
    payloadJSON: String,
    info: String?,
    document: String?,
    summary: String?,
    sender: String
  ) -> WebXDCUpdate {
    var all = updates(appID: appID)
    let update = WebXDCUpdate(
      serial: (all.last?.serial ?? 0) + 1,
      payloadJSON: payloadJSON,
      info: info,
      document: document,
      summary: summary,
      sender: sender)
    all.append(update)
    if all.count > Self.maxUpdates {
      all.removeFirst(all.count - Self.maxUpdates)
    }
    cache[appID] = all
    let url = WebXDCLibrary.appURL(appID).appendingPathComponent("updates.json")
    if let data = try? JSONEncoder().encode(all) {
      try? data.write(to: url, options: [.atomic])
    }
    for listener in listeners[appID, default: [:]].values {
      listener(update)
    }
    return update
  }

  func addListener(appID: UUID, token: ObjectIdentifier, handler: @escaping (WebXDCUpdate) -> Void)
  {
    listeners[appID, default: [:]][token] = handler
  }

  func removeListener(appID: UUID, token: ObjectIdentifier) {
    listeners[appID]?[token] = nil
  }

  func hasListeners(appID: UUID) -> Bool {
    !(listeners[appID]?.isEmpty ?? true)
  }

  func clear(appID: UUID) {
    cache[appID] = []
    let url = WebXDCLibrary.appURL(appID).appendingPathComponent("updates.json")
    try? FileManager.default.removeItem(at: url)
  }
}

@MainActor
enum WebXDCTool {
  static let listName = "webxdc_list"
  static let createName = "webxdc_create"
  static let filesName = "webxdc_files"
  static let readName = "webxdc_read"
  static let writeName = "webxdc_write"
  static let deleteFileName = "webxdc_delete_file"
  static let rollbackName = "webxdc_rollback"
  static let sendUpdateName = "webxdc_send_update"

  static let toolNames = [
    listName, createName, filesName, readName, writeName, deleteFileName, rollbackName,
    sendUpdateName,
  ]

  private static let appParameter = ToolParameterDef(
    name: "app", type: "string",
    description: "App name or ID prefix from webxdc_list.", required: true)

  static let definitions: [ToolDefinition] = [
    ToolDefinition(
      name: listName,
      description: "List webxdc apps with IDs, revisions, and descriptions.",
      parameters: []),
    ToolDefinition(
      name: createName,
      description:
        "Create a webxdc app (HTML/CSS/JS mini app run inside the chat). Starts at revision 1 with a template index.html that loads webxdc.js; use webxdc_write to fill in the real code.",
      parameters: [
        ToolParameterDef(
          name: "name", type: "string", description: "App name.", required: true),
        ToolParameterDef(
          name: "description", type: "string",
          description: "One-line description of what the app does.", required: false),
      ]),
    ToolDefinition(
      name: filesName,
      description: "List the files of a webxdc app's current (or given) revision.",
      parameters: [
        appParameter,
        ToolParameterDef(
          name: "revision", type: "number",
          description: "Revision number; omit for the current one.", required: false),
      ]),
    ToolDefinition(
      name: readName,
      description: "Read a text file from a webxdc app.",
      parameters: [
        appParameter,
        ToolParameterDef(
          name: "path", type: "string",
          description: "Relative file path, such as index.html.", required: true),
        ToolParameterDef(
          name: "revision", type: "number",
          description: "Revision number; omit for the current one.", required: false),
      ]),
    ToolDefinition(
      name: writeName,
      description:
        "Write a file into a webxdc app. Every write snapshots the app into a new revision, so changes can be rolled back. Use base64=true to write binary resources such as images.",
      parameters: [
        appParameter,
        ToolParameterDef(
          name: "path", type: "string",
          description: "Relative file path, such as index.html or img/tile.png.",
          required: true),
        ToolParameterDef(
          name: "content", type: "string",
          description: "File content: UTF-8 text, or base64 when base64=true.", required: true),
        ToolParameterDef(
          name: "base64", type: "boolean",
          description: "Set true when content is base64-encoded binary data.", required: false),
      ]),
    ToolDefinition(
      name: deleteFileName,
      description: "Delete a file from a webxdc app, creating a new revision.",
      parameters: [
        appParameter,
        ToolParameterDef(
          name: "path", type: "string", description: "Relative file path.", required: true),
      ]),
    ToolDefinition(
      name: rollbackName,
      description:
        "Roll a webxdc app back: copies the given older revision into a new current revision.",
      parameters: [
        appParameter,
        ToolParameterDef(
          name: "revision", type: "number",
          description: "Revision number to restore.", required: true),
      ]),
    ToolDefinition(
      name: sendUpdateName,
      description:
        "Send a webxdc state update into a running app, e.g. to act as the second player or game master. The payload is delivered to the app's setUpdateListener callback.",
      parameters: [
        appParameter,
        ToolParameterDef(
          name: "payload", type: "string",
          description: "JSON payload for the app (object, array, or scalar).", required: true),
        ToolParameterDef(
          name: "info", type: "string",
          description: "Optional short informational text.", required: false),
      ]),
  ]

  static func execute(
    name: String,
    arguments: [String: AgentToolArgumentValue],
    hub: WebXDCUpdateHub
  ) -> String {
    switch name {
    case listName:
      return list()
    case createName:
      return create(arguments: arguments)
    case filesName:
      return files(arguments: arguments)
    case readName:
      return read(arguments: arguments)
    case writeName:
      return write(arguments: arguments)
    case deleteFileName:
      return deleteFile(arguments: arguments)
    case rollbackName:
      return rollback(arguments: arguments)
    case sendUpdateName:
      return sendUpdate(arguments: arguments, hub: hub)
    default:
      return "Error: unknown webxdc tool."
    }
  }

  private static func list() -> String {
    let apps = WebXDCLibrary.listApps()
    guard !apps.isEmpty else {
      return "No webxdc apps yet. Use webxdc_create to make one."
    }
    return apps.map { app in
      let id = String(app.id.uuidString.prefix(8))
      let revisions = app.revisions.map(\.number).sorted()
      let description = app.appDescription.isEmpty ? "" : " — \(app.appDescription)"
      return
        "- \(id) '\(app.name)' revision \(app.currentRevision) of \(revisions.count)\(description)"
    }.joined(separator: "\n")
  }

  private static func create(arguments: [String: AgentToolArgumentValue]) -> String {
    let name = arguments["name"]?.stringValue ?? ""
    let description = arguments["description"]?.stringValue ?? ""
    do {
      let app = try WebXDCLibrary.createApp(name: name, description: description)
      return
        "Created app '\(app.name)' (id=\(String(app.id.uuidString.prefix(8)))) at revision 1 with a template index.html and manifest.toml. Write the real app with webxdc_write path=index.html. The app can call webxdc.sendUpdate() to talk to you and receives your webxdc_send_update payloads in its update listener."
    } catch {
      return "Error: \(error.localizedDescription)"
    }
  }

  private enum AppResolution {
    case success(WebXDCAppInfo)
    case failure(String)
  }

  private static func resolveApp(_ arguments: [String: AgentToolArgumentValue]) -> AppResolution {
    let query =
      AgentTooling.firstNonEmpty(
        arguments["app"]?.stringValue,
        arguments["id"]?.stringValue,
        arguments["name"]?.stringValue) ?? ""
    guard !query.isEmpty else { return .failure("Error: app is required.") }
    guard let app = WebXDCLibrary.findApp(matching: query) else {
      return .failure("Error: no app matched '\(query)'. Use webxdc_list.")
    }
    return .success(app)
  }

  private static func files(arguments: [String: AgentToolArgumentValue]) -> String {
    switch resolveApp(arguments) {
    case .failure(let error): return error
    case .success(let app):
      let revision = arguments["revision"]?.numberValue.map(Int.init)
      if let revision, !app.revisions.contains(where: { $0.number == revision }) {
        return "Error: revision \(revision) does not exist."
      }
      let paths = WebXDCLibrary.listFiles(app, revision: revision)
      let header =
        "App '\(app.name)' revision \(revision ?? app.currentRevision) "
        + "(revisions: \(app.revisions.map { String($0.number) }.joined(separator: ",")))"
      guard !paths.isEmpty else { return header + "\n(no files)" }
      return header + "\n" + paths.map { "- \($0)" }.joined(separator: "\n")
    }
  }

  private static func read(arguments: [String: AgentToolArgumentValue]) -> String {
    switch resolveApp(arguments) {
    case .failure(let error): return error
    case .success(let app):
      let path = arguments["path"]?.stringValue ?? ""
      let revision = arguments["revision"]?.numberValue.map(Int.init)
      do {
        let data = try WebXDCLibrary.readFile(app, path: path, revision: revision)
        if data.prefix(4096).contains(0) {
          return "Error: '\(path)' is binary (\(data.count) bytes)."
        }
        guard let text = String(data: data, encoding: .utf8) else {
          return "Error: '\(path)' is not valid UTF-8 text."
        }
        return text
      } catch {
        return "Error: \(error.localizedDescription)"
      }
    }
  }

  private static func write(arguments: [String: AgentToolArgumentValue]) -> String {
    switch resolveApp(arguments) {
    case .failure(let error): return error
    case .success(let app):
      let path = arguments["path"]?.stringValue ?? ""
      guard let content = arguments["content"] ?? arguments["text"] else {
        return "Error: content is required."
      }
      let data: Data
      if arguments["base64"]?.boolValue == true {
        guard
          let decoded = Data(
            base64Encoded: content.coercedStringValue, options: [.ignoreUnknownCharacters])
        else {
          return "Error: content is not valid base64."
        }
        data = decoded
      } else {
        data = Data(content.coercedStringValue.utf8)
      }
      do {
        let updated = try WebXDCLibrary.writeFile(app, path: path, data: data)
        return
          "Wrote \(data.count) bytes to \(path) in app '\(updated.name)', now at revision \(updated.currentRevision)."
      } catch {
        return "Error: \(error.localizedDescription)"
      }
    }
  }

  private static func deleteFile(arguments: [String: AgentToolArgumentValue]) -> String {
    switch resolveApp(arguments) {
    case .failure(let error): return error
    case .success(let app):
      let path = arguments["path"]?.stringValue ?? ""
      do {
        let updated = try WebXDCLibrary.deleteFile(app, path: path)
        return
          "Deleted \(path) from app '\(updated.name)', now at revision \(updated.currentRevision)."
      } catch {
        return "Error: \(error.localizedDescription)"
      }
    }
  }

  private static func rollback(arguments: [String: AgentToolArgumentValue]) -> String {
    switch resolveApp(arguments) {
    case .failure(let error): return error
    case .success(let app):
      guard let revision = arguments["revision"]?.numberValue.map(Int.init) else {
        return "Error: revision is required."
      }
      do {
        let updated = try WebXDCLibrary.rollback(app, to: revision)
        return
          "Restored revision \(revision) of '\(updated.name)' as new revision \(updated.currentRevision)."
      } catch {
        return "Error: \(error.localizedDescription)"
      }
    }
  }

  private static func sendUpdate(
    arguments: [String: AgentToolArgumentValue],
    hub: WebXDCUpdateHub
  ) -> String {
    switch resolveApp(arguments) {
    case .failure(let error): return error
    case .success(let app):
      guard let payload = arguments["payload"] else {
        return "Error: payload is required."
      }
      let payloadJSON = normalizedPayloadJSON(payload)
      let info = AgentTooling.firstNonEmpty(arguments["info"]?.stringValue)
      let update = hub.post(
        appID: app.id,
        payloadJSON: payloadJSON,
        info: info,
        document: nil,
        summary: nil,
        sender: "assistant")
      let running = hub.hasListeners(appID: app.id)
      return
        "Sent update serial \(update.serial) to '\(app.name)'"
        + (running ? " (app is running and received it)." : " (queued; the app is not open).")
    }
  }

  /// The payload may arrive as a JSON string or as a structured value; either
  /// way the stored form is a JSON-encoded string.
  private static func normalizedPayloadJSON(_ value: AgentToolArgumentValue) -> String {
    if case .string(let text) = value {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if let data = trimmed.data(using: .utf8),
        (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
      {
        return trimmed
      }
      let quoted = (try? JSONSerialization.data(
        withJSONObject: text, options: [.fragmentsAllowed]))
        .flatMap { String(data: $0, encoding: .utf8) }
      return quoted ?? "null"
    }
    let object = value.jsonObject
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys]),
      let text = String(data: data, encoding: .utf8)
    else { return "null" }
    return text
  }
}
