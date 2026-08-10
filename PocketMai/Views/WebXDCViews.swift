import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

// MARK: - Runner

struct WebXDCRunnerSheet: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss

  let app: WebXDCAppInfo

  var body: some View {
    NavigationStack {
      WebXDCWebView(app: app, store: store)
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Close") { dismiss() }
          }
        }
    }
  }
}

private struct WebXDCWebView: UIViewRepresentable {
  let app: WebXDCAppInfo
  let store: AppStore

  static let appScheme = "xdc"

  func makeCoordinator() -> Coordinator {
    Coordinator(app: app, store: store)
  }

  func makeUIView(context: Context) -> WKWebView {
    let coordinator = context.coordinator
    let configuration = WKWebViewConfiguration()
    configuration.setURLSchemeHandler(
      WebXDCSchemeHandler(
        rootURL: WebXDCLibrary.currentRevisionURL(app),
        bridgeScript: coordinator.bridgeScript),
      forURLScheme: Self.appScheme)
    configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: app.id)
    configuration.userContentController.add(coordinator, name: "webxdc")
    let allowInternet = store.settings.toolSettings.webxdcAllowInternet
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = coordinator
    webView.isOpaque = false
    coordinator.webView = webView
    coordinator.registerListener()
    let load = {
      if let url = URL(string: "\(Self.appScheme)://app/index.html") {
        webView.load(URLRequest(url: url))
      }
    }
    if allowInternet {
      load()
    } else {
      // Attach the network-blocking rules before the first load so no remote
      // subresource can slip through while they compile.
      WebXDCWebView.blockNetworkRuleList { ruleList in
        if let ruleList {
          webView.configuration.userContentController.add(ruleList)
        }
        load()
      }
    }
    return webView
  }

  func updateUIView(_ uiView: WKWebView, context: Context) {}

  static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
    coordinator.tearDown()
  }

  /// Content rules blocking http/https/websocket loads. The filter must stay
  /// scheme-scoped: a match-everything rule also blocks the app's own xdc://
  /// resources and renders the app blank.
  private static func blockNetworkRuleList(_ completion: @escaping (WKContentRuleList?) -> Void) {
    let rules = """
      [{"trigger":{"url-filter":"^https?://.*"},"action":{"type":"block"}},
       {"trigger":{"url-filter":"^wss?://.*"},"action":{"type":"block"}}]
      """
    WKContentRuleListStore.default().compileContentRuleList(
      forIdentifier: "webxdc-block-network", encodedContentRuleList: rules
    ) { ruleList, _ in
      completion(ruleList)
    }
  }

  @MainActor
  final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private let app: WebXDCAppInfo
    private weak var store: AppStore?
    weak var webView: WKWebView?
    private var listenerRegistered = false

    init(app: WebXDCAppInfo, store: AppStore) {
      self.app = app
      self.store = store
    }

    var bridgeScript: String {
      WebXDCBridge.script(selfAddr: "you@pocketmai", selfName: "You")
    }

    func registerListener() {
      guard let store, !listenerRegistered else { return }
      listenerRegistered = true
      store.webxdcHub.addListener(appID: app.id, token: ObjectIdentifier(self)) {
        [weak self] update in
        self?.deliver([update])
      }
    }

    func tearDown() {
      store?.webxdcHub.removeListener(appID: app.id, token: ObjectIdentifier(self))
      webView?.configuration.userContentController.removeScriptMessageHandler(forName: "webxdc")
      listenerRegistered = false
    }

    func userContentController(
      _ userContentController: WKUserContentController,
      didReceive message: WKScriptMessage
    ) {
      guard message.name == "webxdc", let body = message.body as? [String: Any],
        let type = body["type"] as? String
      else { return }
      switch type {
      case "ready":
        let since = (body["serial"] as? NSNumber)?.intValue ?? 0
        let updates = (store?.webxdcHub.updates(appID: app.id) ?? [])
          .filter { $0.serial > since }
        deliver(updates)
      case "sendUpdate":
        handleSendUpdate(body)
      case "sendToChat":
        let text = (body["text"] as? String ?? "").trimmingCharacters(
          in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sendToConversation(prompt: text, displayText: text)
      default:
        break
      }
    }

    private func handleSendUpdate(_ body: [String: Any]) {
      guard let store else { return }
      let payloadJSON = (body["payload"] as? String) ?? "null"
      let info = nonEmpty(body["info"] as? String)
      let document = nonEmpty(body["document"] as? String)
      let summary = nonEmpty(body["summary"] as? String)
      let update = store.webxdcHub.post(
        appID: app.id,
        payloadJSON: payloadJSON,
        info: info,
        document: document,
        summary: summary,
        sender: "app")
      guard store.settings.toolSettings.webxdcChatInteractionEnabled else { return }
      var prompt =
        "[webxdc app '\(app.name)' sent update serial \(update.serial)] payload: \(payloadJSON)"
      if let info { prompt += "\ninfo: \(info)" }
      prompt +=
        "\nRespond in chat, and use the webxdc_send_update tool when the app should receive data back."
      let display = info ?? "[\(app.name)] \(payloadJSON)"
      sendToConversation(prompt: prompt, displayText: display)
    }

    private func sendToConversation(prompt: String, displayText: String) {
      guard let store else { return }
      Task { @MainActor in
        _ = await store.send(prompt: prompt, displayText: displayText)
      }
    }

    private func deliver(_ updates: [WebXDCUpdate]) {
      guard !updates.isEmpty, let webView else { return }
      let items: [[String: Any]] = updates.map { update in
        var item: [String: Any] = [
          "serial": update.serial,
          "payloadJSON": update.payloadJSON,
        ]
        if let info = update.info { item["info"] = info }
        if let document = update.document { item["document"] = document }
        if let summary = update.summary { item["summary"] = summary }
        return item
      }
      guard let data = try? JSONSerialization.data(withJSONObject: items),
        var json = String(data: data, encoding: .utf8)
      else { return }
      json = json
        .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
        .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
      webView.evaluateJavaScript("window.__webxdcDeliver(\(json));", completionHandler: nil)
    }

    private func nonEmpty(_ value: String?) -> String? {
      guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
      }
      return value
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      guard let url = navigationAction.request.url else {
        decisionHandler(.cancel)
        return
      }
      let scheme = url.scheme?.lowercased() ?? ""
      if scheme == WebXDCWebView.appScheme || scheme == "about" || scheme == "blob"
        || scheme == "data"
      {
        decisionHandler(.allow)
        return
      }
      if (scheme == "http" || scheme == "https"),
        store?.settings.toolSettings.webxdcAllowInternet == true
      {
        decisionHandler(.allow)
        return
      }
      decisionHandler(.cancel)
    }
  }
}

/// Serves app files for the xdc:// scheme and injects the standard webxdc.js
/// implementation, shadowing any webxdc.js stub bundled with the app.
private final class WebXDCSchemeHandler: NSObject, WKURLSchemeHandler {
  private let rootURL: URL
  private let bridgeScript: String

  init(rootURL: URL, bridgeScript: String) {
    self.rootURL = rootURL
    self.bridgeScript = bridgeScript
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    guard let url = urlSchemeTask.request.url else {
      urlSchemeTask.didFailWithError(URLError(.badURL))
      return
    }
    var path = url.path
    while path.hasPrefix("/") { path.removeFirst() }
    if path.isEmpty { path = "index.html" }

    if path == "webxdc.js" {
      respond(urlSchemeTask, url: url, data: Data(bridgeScript.utf8), mime: "text/javascript")
      return
    }

    let components = path.split(separator: "/").map(String.init)
    guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      urlSchemeTask.didFailWithError(URLError(.badURL))
      return
    }
    let fileURL = components.reduce(rootURL) { $0.appendingPathComponent($1) }
    guard let data = try? Data(contentsOf: fileURL) else {
      urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
      return
    }
    respond(urlSchemeTask, url: url, data: data, mime: Self.mimeType(for: path))
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

  private func respond(_ task: WKURLSchemeTask, url: URL, data: Data, mime: String) {
    let response = URLResponse(
      url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8")
    task.didReceive(response)
    task.didReceive(data)
    task.didFinish()
  }

  private static func mimeType(for path: String) -> String {
    let ext = (path as NSString).pathExtension.lowercased()
    if let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
      return mime
    }
    switch ext {
    case "html", "htm": return "text/html"
    case "js", "mjs": return "text/javascript"
    case "css": return "text/css"
    case "json": return "application/json"
    case "wasm": return "application/wasm"
    default: return "application/octet-stream"
    }
  }
}

enum WebXDCBridge {
  static func script(selfAddr: String, selfName: String) -> String {
    """
    (function () {
      if (window.webxdc) { return; }
      var listener = null;
      var pending = [];
      var maxSerial = 0;
      function toUpdate(item) {
        var payload = null;
        try { payload = JSON.parse(item.payloadJSON); } catch (e) {}
        var update = { payload: payload, serial: item.serial, max_serial: maxSerial };
        if (item.info) { update.info = item.info; }
        if (item.document) { update.document = item.document; }
        if (item.summary) { update.summary = item.summary; }
        return update;
      }
      window.__webxdcDeliver = function (items) {
        items.forEach(function (item) {
          if (item.serial > maxSerial) { maxSerial = item.serial; }
        });
        items.forEach(function (item) {
          var update = toUpdate(item);
          if (listener) { listener(update); } else { pending.push(update); }
        });
      };
      function post(message) {
        try { window.webkit.messageHandlers.webxdc.postMessage(message); } catch (e) {}
      }
      window.webxdc = {
        selfAddr: \(jsString(selfAddr)),
        selfName: \(jsString(selfName)),
        sendUpdate: function (update, descr) {
          update = update || {};
          var payload = update.payload === undefined ? null : update.payload;
          var payloadJSON = "null";
          try { payloadJSON = JSON.stringify(payload); } catch (e) {}
          if (payloadJSON === undefined) { payloadJSON = "null"; }
          post({
            type: "sendUpdate",
            payload: payloadJSON,
            info: update.info ? String(update.info) : null,
            document: update.document ? String(update.document) : null,
            summary: update.summary ? String(update.summary) : null
          });
        },
        setUpdateListener: function (callback, serial) {
          listener = callback;
          pending.forEach(function (update) { callback(update); });
          pending = [];
          post({ type: "ready", serial: serial || 0 });
          return Promise.resolve();
        },
        sendToChat: function (message) {
          message = message || {};
          var text = message.text ? String(message.text) : "";
          if (message.file && message.file.plainText) {
            text = text ? text + "\\n" + message.file.plainText : message.file.plainText;
          }
          post({ type: "sendToChat", text: text });
          return Promise.resolve();
        },
        importFiles: function (filter) {
          return Promise.resolve([]);
        },
        joinRealtimeChannel: function () {
          throw new Error("realtime channels are not supported in PocketMai");
        }
      };
    })();
    """
  }

  private static func jsString(_ value: String) -> String {
    let data = (try? JSONSerialization.data(
      withJSONObject: value, options: [.fragmentsAllowed]))
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
  }
}

// MARK: - Apps panel

struct WebXDCAppsPanel: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @State private var apps: [WebXDCAppInfo] = []
  @State private var showingImporter = false
  @State private var pendingDelete: WebXDCAppInfo?
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      List {
        if apps.isEmpty {
          Text(
            "No apps yet. Enable the WebXDC Apps tool in a chat and ask the assistant to create one, or import a .xdc file."
          )
          .foregroundStyle(.secondary)
        }
        ForEach(apps) { app in
          NavigationLink(value: app.id) {
            appRow(app)
          }
          .contextMenu {
            Button(role: .destructive) {
              pendingDelete = app
            } label: {
              Label("Delete App", systemImage: "trash")
            }
          }
        }
      }
      .navigationTitle("Apps")
      .navigationBarTitleDisplayMode(.inline)
      .navigationDestination(for: UUID.self) { id in
        WebXDCAppDetailView(appID: id) { reload() }
      }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            showingImporter = true
          } label: {
            Label("Import", systemImage: "square.and.arrow.down")
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .fileImporter(
        isPresented: $showingImporter,
        allowedContentTypes: importTypes
      ) { result in
        if case .success(let url) = result {
          importApp(from: url)
        }
      }
      .alert(
        "Delete app?", isPresented: deleteConfirmationBinding, presenting: pendingDelete
      ) { app in
        Button("Cancel", role: .cancel) { pendingDelete = nil }
        Button("Delete", role: .destructive) {
          try? WebXDCLibrary.deleteApp(id: app.id)
          pendingDelete = nil
          reload()
        }
      } message: { app in
        Text("'\(app.name)' and all of its revisions will be removed. This cannot be undone.")
      }
      .alert(
        "Import failed", isPresented: errorBinding
      ) {
        Button("OK") { errorMessage = nil }
      } message: {
        Text(errorMessage ?? "")
      }
      .onAppear { reload() }
    }
  }

  private var importTypes: [UTType] {
    var types: [UTType] = [.zip]
    if let xdc = UTType(filenameExtension: "xdc") {
      types.insert(xdc, at: 0)
    }
    return types
  }

  private var deleteConfirmationBinding: Binding<Bool> {
    Binding(
      get: { pendingDelete != nil },
      set: { if !$0 { pendingDelete = nil } })
  }

  private var errorBinding: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } })
  }

  private func appRow(_ app: WebXDCAppInfo) -> some View {
    HStack(spacing: 12) {
      WebXDCAppIcon(app: app)
      VStack(alignment: .leading, spacing: 2) {
        Text(app.name)
          .font(.body.weight(.medium))
        Text(
          app.appDescription.isEmpty
            ? "\(app.revisions.count) revision\(app.revisions.count == 1 ? "" : "s")"
            : app.appDescription
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
      }
    }
  }

  private func reload() {
    apps = WebXDCLibrary.listApps()
  }

  private func importApp(from url: URL) {
    let accessing = url.startAccessingSecurityScopedResource()
    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
    do {
      let fallback = url.deletingPathExtension().lastPathComponent
      _ = try WebXDCLibrary.importXDC(from: url, fallbackName: fallback)
      reload()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

struct WebXDCAppIcon: View {
  let app: WebXDCAppInfo
  var size: CGFloat = 40

  var body: some View {
    Group {
      if let data = WebXDCLibrary.iconData(app), let image = UIImage(data: data) {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Image(systemName: "square.grid.2x2")
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: size, height: size)
    .background(Color.secondary.opacity(0.12))
    .clipShape(RoundedRectangle(cornerRadius: size / 5, style: .continuous))
  }
}

private struct WebXDCEditingFile: Identifiable {
  let path: String
  let text: String

  var id: String { path }
}

struct WebXDCAppDetailView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss

  let appID: UUID
  let onChange: () -> Void

  @State private var app: WebXDCAppInfo?
  @State private var files: [String] = []
  @State private var draftName = ""
  @State private var draftDescription = ""
  @State private var editingFile: WebXDCEditingFile?
  @State private var newFilePath = ""
  @State private var shareURL: URL?
  @State private var runningApp: WebXDCAppInfo?
  @State private var showingIconImporter = false
  @State private var showingDeleteConfirmation = false
  @State private var errorMessage: String?

  init(appID: UUID, onChange: @escaping () -> Void = {}) {
    self.appID = appID
    self.onChange = onChange
  }

  var body: some View {
    Form {
      if let app {
        appSection(app)
        revisionSection(app)
        filesSection(app)
        actionsSection(app)
      } else {
        Text("This app is gone.")
          .foregroundStyle(.secondary)
      }
    }
    .navigationTitle(app?.name ?? "App")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { reload() }
    .sheet(item: $editingFile) { file in
      MessageTextSelectionSheet(
        title: file.path,
        text: file.text,
        initialFontSize: 13,
        initialLineSpacing: 2,
        fontFamily: .monospaced,
        isEditable: true,
        onSave: { newText in
          saveFile(path: file.path, text: newText)
        })
    }
    .sheet(item: $runningApp) { app in
      WebXDCRunnerSheet(app: app)
        .environmentObject(store)
    }
    .sheet(isPresented: shareBinding) {
      if let shareURL {
        ActivityShareSheet(activityItems: [shareURL])
      }
    }
    .fileImporter(
      isPresented: $showingIconImporter,
      allowedContentTypes: [.png, .jpeg, .image]
    ) { result in
      if case .success(let url) = result {
        importIcon(from: url)
      }
    }
    .alert("Delete app?", isPresented: $showingDeleteConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) { deleteApp() }
    } message: {
      Text("All revisions will be removed. This cannot be undone.")
    }
    .alert("Something went wrong", isPresented: errorBinding) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private var shareBinding: Binding<Bool> {
    Binding(
      get: { shareURL != nil },
      set: { if !$0 { shareURL = nil } })
  }

  private var errorBinding: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } })
  }

  @ViewBuilder
  private func appSection(_ app: WebXDCAppInfo) -> some View {
    Section("App") {
      HStack(spacing: 12) {
        Button {
          showingIconImporter = true
        } label: {
          WebXDCAppIcon(app: app, size: 56)
        }
        .buttonStyle(.borderless)
        VStack(alignment: .leading, spacing: 6) {
          TextField("Name", text: $draftName)
            .font(.body.weight(.medium))
            .onSubmit { saveMetadata() }
          TextField("Description", text: $draftDescription, axis: .vertical)
            .font(.caption)
            .onSubmit { saveMetadata() }
        }
      }
      if draftName != app.name || draftDescription != app.appDescription {
        Button("Save Details") { saveMetadata() }
      }
      Text("Tap the icon to set a new one (PNG or JPEG, square, 128-512 px).")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func revisionSection(_ app: WebXDCAppInfo) -> some View {
    Section("Revision") {
      Picker("Revision", selection: revisionBinding(app)) {
        ForEach(app.revisions.sorted { $0.number > $1.number }) { revision in
          Text("\(revision.number) — \(formatted(revision.date)) (\(revision.note))")
            .tag(revision.number)
        }
      }
      if app.revisions.count > 1 {
        Button(role: .destructive) {
          deleteCurrentRevision(app)
        } label: {
          Label("Delete Revision \(app.currentRevision)", systemImage: "clock.arrow.circlepath")
        }
      }
    }
  }

  @ViewBuilder
  private func filesSection(_ app: WebXDCAppInfo) -> some View {
    Section("Files") {
      ForEach(files, id: \.self) { path in
        Button {
          openFile(path)
        } label: {
          HStack {
            Image(systemName: iconName(for: path))
              .foregroundStyle(.secondary)
              .frame(width: 20)
            Text(path)
              .foregroundStyle(.primary)
            Spacer()
            Text(fileSizeText(app, path: path))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .swipeActions {
          Button(role: .destructive) {
            deleteFile(path)
          } label: {
            Label("Delete", systemImage: "trash")
          }
        }
      }
      HStack {
        TextField("New file, e.g. style.css", text: $newFilePath)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .onSubmit { addFile() }
        Button {
          addFile()
        } label: {
          Image(systemName: "plus.circle.fill")
        }
        .buttonStyle(.borderless)
      }
      Text("Editing a file snapshots the app into a new revision first.")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func actionsSection(_ app: WebXDCAppInfo) -> some View {
    Section {
      Button {
        runningApp = app
      } label: {
        Label("Run App", systemImage: "play.circle")
      }
      Button {
        exportApp(app)
      } label: {
        Label("Export .xdc", systemImage: "square.and.arrow.up")
      }
      Button(role: .destructive) {
        showingDeleteConfirmation = true
      } label: {
        Label("Delete App", systemImage: "trash")
      }
    } footer: {
      Text("Exported .xdc files can be shared and used in Delta Chat or another PocketMai.")
    }
  }

  private func revisionBinding(_ app: WebXDCAppInfo) -> Binding<Int> {
    Binding(
      get: { app.currentRevision },
      set: { revision in
        do {
          _ = try WebXDCLibrary.selectRevision(app, revision: revision)
          reload()
        } catch {
          errorMessage = error.localizedDescription
        }
      })
  }

  private func reload() {
    app = WebXDCLibrary.app(id: appID)
    if let app {
      files = WebXDCLibrary.listFiles(app)
      draftName = app.name
      draftDescription = app.appDescription
    } else {
      files = []
    }
    onChange()
  }

  private func saveMetadata() {
    guard var app else { return }
    let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    app.name = name
    app.appDescription = draftDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      try WebXDCLibrary.save(app)
      reload()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func openFile(_ path: String) {
    guard let app else { return }
    do {
      let data = try WebXDCLibrary.readFile(app, path: path)
      if data.prefix(4096).contains(0) {
        errorMessage = "'\(path)' is a binary file and cannot be edited as text."
        return
      }
      guard let text = String(data: data, encoding: .utf8) else {
        errorMessage = "'\(path)' is not valid UTF-8 text."
        return
      }
      editingFile = WebXDCEditingFile(path: path, text: text)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func saveFile(path: String, text: String) {
    guard let app else { return }
    do {
      _ = try WebXDCLibrary.writeFile(app, path: path, data: Data(text.utf8))
      reload()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func addFile() {
    guard let app else { return }
    let path = newFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { return }
    do {
      _ = try WebXDCLibrary.writeFile(app, path: path, data: Data())
      newFilePath = ""
      reload()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func deleteFile(_ path: String) {
    guard let app else { return }
    do {
      _ = try WebXDCLibrary.deleteFile(app, path: path)
      reload()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func deleteCurrentRevision(_ app: WebXDCAppInfo) {
    do {
      _ = try WebXDCLibrary.deleteRevision(app, revision: app.currentRevision)
      reload()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func exportApp(_ app: WebXDCAppInfo) {
    do {
      shareURL = try WebXDCLibrary.exportXDC(app)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func importIcon(from url: URL) {
    guard let app else { return }
    let accessing = url.startAccessingSecurityScopedResource()
    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
    guard let data = try? Data(contentsOf: url), let image = UIImage(data: data),
      let png = image.pngData()
    else {
      errorMessage = "Could not read the image."
      return
    }
    do {
      try WebXDCLibrary.writeFileInPlace(app, path: "icon.png", data: png)
      let jpgURL = WebXDCLibrary.currentRevisionURL(app).appendingPathComponent("icon.jpg")
      try? FileManager.default.removeItem(at: jpgURL)
      reload()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func deleteApp() {
    do {
      try WebXDCLibrary.deleteApp(id: appID)
      onChange()
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func iconName(for path: String) -> String {
    switch (path as NSString).pathExtension.lowercased() {
    case "html", "htm": return "chevron.left.forwardslash.chevron.right"
    case "css": return "paintbrush"
    case "js", "mjs": return "curlybraces"
    case "png", "jpg", "jpeg", "gif", "webp", "svg": return "photo"
    case "toml", "json": return "doc.badge.gearshape"
    default: return "doc"
    }
  }

  private func fileSizeText(_ app: WebXDCAppInfo, path: String) -> String {
    let url = WebXDCLibrary.currentRevisionURL(app).appendingPathComponent(path)
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
    guard let size else { return "" }
    return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
  }

  private func formatted(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
  }
}

// MARK: - Chat launcher

struct WebXDCAppLauncherSheet: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss

  let onLaunch: (WebXDCAppInfo) -> Void

  @State private var apps: [WebXDCAppInfo] = []

  var body: some View {
    NavigationStack {
      List {
        if apps.isEmpty {
          Text(
            "No apps available. Enable the WebXDC Apps tool and ask the assistant to create one, or import a .xdc from Settings > Apps."
          )
          .foregroundStyle(.secondary)
        }
        ForEach(apps) { app in
          Button {
            dismiss()
            onLaunch(app)
          } label: {
            HStack(spacing: 12) {
              WebXDCAppIcon(app: app)
              VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                  .foregroundStyle(.primary)
                if !app.appDescription.isEmpty {
                  Text(app.appDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
              }
            }
          }
        }
      }
      .navigationTitle("Start App")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
      .onAppear { apps = WebXDCLibrary.listApps() }
    }
  }
}
