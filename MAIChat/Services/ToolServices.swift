import Foundation

enum ToolContextBuilder {
  @MainActor
  static func build(
    input: String,
    conversation: Conversation,
    settings: AppSettings,
    locationService: LocationService
  ) async -> String {
    var sections: [String] = []
    let enabled = conversation.enabledTools

    if enabled.contains(.datetime) {
      sections.append(datetimeContext(settings: settings.toolSettings))
    }
    if enabled.contains(.location) {
      sections.append(
        await locationContext(settings: settings.toolSettings, locationService: locationService))
    }
    if enabled.contains(.weather) {
      if let weather = await WeatherService.weatherContext(
        settings: settings.toolSettings, locationService: locationService)
      {
        sections.append(weather)
      }
    }
    if enabled.contains(.webSearch) {
      if let web = await WebSearchService.searchContext(
        query: input,
        provider: settings.toolSettings.webSearchProvider,
        settings: settings)
      {
        sections.append(web)
      }
    }
    if enabled.contains(.files) {
      let files = filesContext(settings: settings.toolSettings)
      if !files.isEmpty {
        sections.append(files)
      }
    }
    return sections.joined(separator: "\n\n")
  }

  private static func datetimeContext(settings: NativeToolSettings) -> String {
    var values: [String] = []
    let now = Date()
    if settings.includeCurrentTime {
      let formatter = DateFormatter()
      formatter.dateStyle = .full
      formatter.timeStyle = .long
      values.append("Current date/time: \(formatter.string(from: now))")
    }
    if settings.includeTimeZone {
      values.append("Time zone: \(TimeZone.current.identifier)")
    }
    if settings.includeYear {
      values.append("Current year: \(Calendar.current.component(.year, from: now))")
    }
    return "Date & Time tool:\n" + values.joined(separator: "\n")
  }

  @MainActor
  private static func locationContext(
    settings: NativeToolSettings, locationService: LocationService
  ) async -> String {
    if settings.useGPSLocation {
      return "Location tool:\n\(await locationService.currentLocationText())"
    }
    let manual = settings.manualLocation.trimmingCharacters(in: .whitespacesAndNewlines)
    return manual.isEmpty ? "Location tool:\nNo location configured" : "Location tool:\n\(manual)"
  }

  private static func todoContext(settings: NativeToolSettings) -> String {
    let todos = settings.todos
      .filter { !$0.isDone }
      .map { "- \($0.title)" }
      .joined(separator: "\n")
    return todos.isEmpty ? "" : "Todo tool:\n\(todos)"
  }

  private static func filesContext(settings: NativeToolSettings) -> String {
    let files = settings.files.map { file in
      """
      File: \(file.name)
      \(file.excerpt)
      """
    }
    return files.isEmpty ? "" : "Files tool:\n" + files.joined(separator: "\n\n")
  }
}

enum WeatherService {
  @MainActor
  static func weatherContext(settings: NativeToolSettings, locationService: LocationService) async
    -> String?
  {
    var query = settings.weatherLocation.trimmingCharacters(in: .whitespacesAndNewlines)
    if query.isEmpty, settings.useGPSLocation {
      query = await locationService.currentLocationText()
    }
    let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
    let urlString =
      encoded.isEmpty ? "https://wttr.in/?format=3" : "https://wttr.in/\(encoded)?format=3"
    guard let url = URL(string: urlString),
      let (data, _) = try? await URLSession.shared.data(from: url),
      let text = String(data: data, encoding: .utf8)
    else {
      return nil
    }
    return "Weather tool:\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))"
  }
}

enum WebSearchService {
  private static let userAgent =
    "MAIChat/1.0 (iOS; +https://github.com/trufae/mai)"
  private static let requestTimeout: TimeInterval = 8
  private static let maxQueryLength = 240
  private static let maxWebResults = 6
  private static let maxWikipediaSummaries = 3

  static func searchContext(
    query: String, provider: WebSearchProvider, settings: AppSettings
  ) async -> String? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let q = String(trimmed.prefix(maxQueryLength))

    let ollamaEndpoint = Self.ollamaEndpoint(in: settings)
    let useOllama = (provider == .ollama || provider == .all) && ollamaEndpoint != nil
    let useDDG = provider == .duckDuckGo || provider == .all
    let useWiki = provider == .wikipedia || provider == .all

    async let ollama: String? =
      useOllama ? ollamaWebSearch(query: q, endpoint: ollamaEndpoint!) : nil
    async let ddg: String? = useDDG ? duckDuckGo(query: q) : nil
    async let wiki: String? = useWiki ? wikipedia(query: q) : nil
    var sections: [String] = []
    if let s = await ollama { sections.append(s) }
    if let s = await ddg { sections.append(s) }
    if let s = await wiki { sections.append(s) }

    if sections.isEmpty {
      async let ddgFallback: String? = useDDG ? nil : duckDuckGo(query: q)
      async let wikiFallback: String? = useWiki ? nil : wikipedia(query: q)
      if let s = await ddgFallback { sections.append(s) }
      if let s = await wikiFallback { sections.append(s) }
    }

    guard !sections.isEmpty else { return nil }
    let header = "Web Search tool (query: \"\(q)\"):"
    return ([header] + sections).joined(separator: "\n\n")
  }

  static func ollamaEndpoint(in settings: AppSettings) -> OpenAIEndpoint? {
    settings.openAIEndpoints.first { endpoint in
      guard endpoint.isEnabled else { return false }
      let host = URL(string: endpoint.baseURL)?.host?.lowercased() ?? ""
      let trimmedKey = endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
      return host.hasSuffix("ollama.com") && !trimmedKey.isEmpty
    }
  }

  // MARK: - Ollama Web Search

  private static func ollamaWebSearch(query: String, endpoint: OpenAIEndpoint) async -> String? {
    let trimmedKey = endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedKey.isEmpty,
      let url = URL(string: "https://ollama.com/api/web_search")
    else {
      return nil
    }
    let authorization = "Bearer \(trimmedKey)"
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue(authorization, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.timeoutInterval = requestTimeout
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])

    let delegate = RedirectPreservingDelegate(
      authorization: authorization, originalRequest: request)
    guard
      let (data, response) = try? await URLSession.shared.data(for: request, delegate: delegate),
      let http = response as? HTTPURLResponse,
      (200..<300).contains(http.statusCode),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }

    let rawResults =
      (object["results"] as? [[String: Any]])
      ?? (object["data"] as? [[String: Any]]) ?? []
    let lines = rawResults.prefix(maxWebResults).compactMap { item -> String? in
      let title = ((item["title"] as? String) ?? (item["name"] as? String) ?? "").cleaned
      let urlString =
        ((item["url"] as? String) ?? (item["link"] as? String) ?? "").cleaned
      let snippet =
        ((item["content"] as? String) ?? (item["snippet"] as? String)
          ?? (item["text"] as? String) ?? "")
        .cleaned
      guard !title.isEmpty || !snippet.isEmpty else { return nil }
      var entry = "- \(title.isEmpty ? urlString : title)"
      if !snippet.isEmpty {
        entry += "\n  \(snippet)"
      }
      if !urlString.isEmpty, urlString != title {
        entry += "\n  \(urlString)"
      }
      return entry
    }
    guard !lines.isEmpty else { return nil }
    return "Ollama Web Search:\n" + lines.joined(separator: "\n")
  }

  // MARK: - DuckDuckGo

  private static func duckDuckGo(query: String) async -> String? {
    async let instant: String? = duckDuckGoInstant(query: query)
    async let web: String? = duckDuckGoWeb(query: query)
    var blocks: [String] = []
    if let s = await instant { blocks.append(s) }
    if let s = await web { blocks.append(s) }
    return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
  }

  private static func duckDuckGoInstant(query: String) async -> String? {
    var components = URLComponents(string: "https://api.duckduckgo.com/")
    components?.queryItems = [
      URLQueryItem(name: "q", value: query),
      URLQueryItem(name: "format", value: "json"),
      URLQueryItem(name: "no_redirect", value: "1"),
      URLQueryItem(name: "no_html", value: "1"),
      URLQueryItem(name: "skip_disambig", value: "1"),
    ]
    guard let url = components?.url,
      let object = await getJSON(url: url) as? [String: Any]
    else {
      return nil
    }
    var lines: [String] = []
    if let abstract = (object["AbstractText"] as? String)?.cleaned, !abstract.isEmpty {
      let source = (object["AbstractSource"] as? String) ?? "DuckDuckGo"
      lines.append("\(source): \(abstract)")
      if let urlString = (object["AbstractURL"] as? String)?.cleaned, !urlString.isEmpty {
        lines.append("  Source: \(urlString)")
      }
    }
    if let answer = (object["Answer"] as? String)?.cleaned, !answer.isEmpty {
      let type = (object["AnswerType"] as? String) ?? "answer"
      lines.append("Answer (\(type)): \(answer)")
    }
    if let definition = (object["Definition"] as? String)?.cleaned, !definition.isEmpty {
      let source = (object["DefinitionSource"] as? String) ?? "Definition"
      lines.append("\(source): \(definition)")
    }
    if let topics = object["RelatedTopics"] as? [[String: Any]] {
      let topicLines = topics.prefix(5).compactMap { item -> String? in
        guard let text = (item["Text"] as? String)?.cleaned, !text.isEmpty else { return nil }
        if let urlString = (item["FirstURL"] as? String)?.cleaned, !urlString.isEmpty {
          return "- \(text) (\(urlString))"
        }
        return "- \(text)"
      }
      if !topicLines.isEmpty {
        lines.append("Related topics:")
        lines.append(contentsOf: topicLines)
      }
    }
    guard !lines.isEmpty else { return nil }
    return "DuckDuckGo Instant:\n" + lines.joined(separator: "\n")
  }

  private static func duckDuckGoWeb(query: String) async -> String? {
    var components = URLComponents(string: "https://html.duckduckgo.com/html/")
    components?.queryItems = [URLQueryItem(name: "q", value: query)]
    guard let url = components?.url,
      let html = await getString(url: url, accept: "text/html")
    else {
      return nil
    }
    let results = parseDuckDuckGoHTML(html, limit: maxWebResults)
    guard !results.isEmpty else { return nil }
    let body = results.map { result in
      var entry = "- \(result.title)"
      if !result.snippet.isEmpty {
        entry += "\n  \(result.snippet)"
      }
      if !result.url.isEmpty {
        entry += "\n  \(result.url)"
      }
      return entry
    }.joined(separator: "\n")
    return "DuckDuckGo results:\n" + body
  }

  private struct WebResult {
    let title: String
    let url: String
    let snippet: String
  }

  private static func parseDuckDuckGoHTML(_ html: String, limit: Int) -> [WebResult] {
    let pattern =
      #"class=\"result__a\"[^>]*href=\"([^\"]+)\"[^>]*>([\s\S]*?)</a>[\s\S]{0,2000}?class=\"result__snippet\"[^>]*>([\s\S]*?)</a>"#
    guard
      let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    else {
      return []
    }
    let nsHTML = html as NSString
    let matches = regex.matches(
      in: html, options: [], range: NSRange(location: 0, length: nsHTML.length))
    var results: [WebResult] = []
    var seenURLs = Set<String>()
    for match in matches {
      if results.count >= limit { break }
      guard match.numberOfRanges == 4 else { continue }
      let rawURL = nsHTML.substring(with: match.range(at: 1))
      let rawTitle = nsHTML.substring(with: match.range(at: 2))
      let rawSnippet = nsHTML.substring(with: match.range(at: 3))
      let title = stripHTML(rawTitle)
      let snippet = stripHTML(rawSnippet)
      let url = decodeDDGRedirect(rawURL)
      guard !title.isEmpty || !snippet.isEmpty else { continue }
      let key = url.isEmpty ? title : url
      if seenURLs.contains(key) { continue }
      seenURLs.insert(key)
      results.append(WebResult(title: title, url: url, snippet: snippet))
    }
    return results
  }

  private static func decodeDDGRedirect(_ raw: String) -> String {
    var s = raw.cleaned
    if s.hasPrefix("//") { s = "https:" + s }
    guard let comps = URLComponents(string: s) else { return s }
    if let uddg = comps.queryItems?.first(where: { $0.name == "uddg" })?.value,
      !uddg.isEmpty
    {
      return uddg.removingPercentEncoding ?? uddg
    }
    return s
  }

  // MARK: - Wikipedia

  private static func wikipedia(query: String) async -> String? {
    guard let titles = await wikipediaSearch(query: query, limit: maxWikipediaSummaries),
      !titles.isEmpty
    else {
      return nil
    }
    let summaries = await withTaskGroup(of: (Int, String?).self, returning: [String?].self) {
      group in
      for (index, title) in titles.enumerated() {
        group.addTask {
          (index, await wikipediaSummary(title: title))
        }
      }
      var collected: [String?] = Array(repeating: nil, count: titles.count)
      for await (index, summary) in group {
        if collected.indices.contains(index) {
          collected[index] = summary
        }
      }
      return collected
    }
    let entries = summaries.compactMap { $0 }
    guard !entries.isEmpty else { return nil }
    return "Wikipedia:\n" + entries.joined(separator: "\n\n")
  }

  private static func wikipediaSearch(query: String, limit: Int) async -> [String]? {
    var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")
    components?.queryItems = [
      URLQueryItem(name: "action", value: "query"),
      URLQueryItem(name: "list", value: "search"),
      URLQueryItem(name: "srsearch", value: query),
      URLQueryItem(name: "format", value: "json"),
      URLQueryItem(name: "srlimit", value: String(limit)),
      URLQueryItem(name: "origin", value: "*"),
    ]
    guard let url = components?.url,
      let object = await getJSON(url: url) as? [String: Any],
      let queryObject = object["query"] as? [String: Any],
      let results = queryObject["search"] as? [[String: Any]]
    else {
      return nil
    }
    return results.compactMap { $0["title"] as? String }
  }

  private static func wikipediaSummary(title: String) async -> String? {
    let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
    let encoded = title.addingPercentEncoding(withAllowedCharacters: allowed) ?? title
    guard
      let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)"),
      let object = await getJSON(url: url) as? [String: Any]
    else {
      return nil
    }
    guard let extract = (object["extract"] as? String)?.cleaned, !extract.isEmpty else {
      return nil
    }
    let outTitle = (object["title"] as? String) ?? title
    var entry = "- \(outTitle): \(extract)"
    if let urls = object["content_urls"] as? [String: Any],
      let desktop = urls["desktop"] as? [String: Any],
      let page = (desktop["page"] as? String)?.cleaned,
      !page.isEmpty
    {
      entry += "\n  \(page)"
    }
    return entry
  }

  // MARK: - HTTP helpers

  private static func getJSON(url: URL) async -> Any? {
    guard let data = await getData(url: url, accept: "application/json") else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
  }

  private static func getString(url: URL, accept: String) async -> String? {
    guard let data = await getData(url: url, accept: accept) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func getData(url: URL, accept: String) async -> Data? {
    var request = URLRequest(url: url)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue(accept, forHTTPHeaderField: "Accept")
    request.timeoutInterval = requestTimeout
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
        return nil
      }
      return data
    } catch {
      return nil
    }
  }

  // MARK: - HTML cleanup

  private static func stripHTML(_ s: String) -> String {
    var t = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    let entities: [(String, String)] = [
      ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
      ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"),
      ("&nbsp;", " "), ("&hellip;", "…"), ("&mdash;", "—"), ("&ndash;", "–"),
    ]
    for (entity, replacement) in entities {
      t = t.replacingOccurrences(of: entity, with: replacement)
    }
    return t.cleaned
  }
}

extension String {
  fileprivate var cleaned: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

enum MCPHTTPClient {
  static func send(server: MCPServer, method: String, params: [String: AnyCodable]? = nil)
    async throws -> Data
  {
    guard server.hasValidScheme, let url = URL(string: server.baseURL) else {
      throw ChatProviderError.invalidEndpoint(server.baseURL)
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.timeoutInterval = 8
    let body = JSONRPCRequest(id: Int.random(in: 1...Int.max), method: method, params: params)
    request.httpBody = try JSONEncoder().encode(body)
    let (data, response) = try await URLSession.shared.data(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      let snippet = String(data: data.prefix(400), encoding: .utf8) ?? ""
      throw ChatProviderError.providerRequestFailed(
        "MCP HTTP \(http.statusCode): \(snippet)")
    }
    return data
  }

  static func fetchTools(server: MCPServer) async throws -> [MCPToolDescriptor] {
    let data = try await send(server: server, method: "tools/list")
    guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ChatProviderError.providerRequestFailed("MCP returned non-JSON response.")
    }
    if let err = raw["error"] as? [String: Any] {
      let message = (err["message"] as? String) ?? "unknown"
      let codeSuffix = (err["code"] as? Int).map { " (code \($0))" } ?? ""
      throw ChatProviderError.providerRequestFailed("MCP error\(codeSuffix): \(message)")
    }
    let result = raw["result"] as? [String: Any] ?? [:]
    let toolList = result["tools"] as? [[String: Any]] ?? []
    return toolList.compactMap { toolDict -> MCPToolDescriptor? in
      guard let name = toolDict["name"] as? String else { return nil }
      let description = (toolDict["description"] as? String) ?? ""
      var parametersJSON = ""
      if let schema = toolDict["inputSchema"],
        let pdata = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]),
        let pjson = String(data: pdata, encoding: .utf8)
      {
        parametersJSON = pjson
      }
      return MCPToolDescriptor(
        name: name, description: description, parametersJSON: parametersJSON)
    }
  }

  static func callTool(
    server: MCPServer, name: String, arguments: [String: AgentToolArgumentValue]
  ) async throws -> String {
    let argsCodable = arguments.compactMapValues(anyCodable)
    let params: [String: AnyCodable] = [
      "name": AnyCodable(name),
      "arguments": AnyCodable(argsCodable),
    ]
    let data = try await send(server: server, method: "tools/call", params: params)
    let decoded = try JSONDecoder().decode(MCPToolCallResponse.self, from: data)
    if let err = decoded.error {
      let message = err.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let codeSuffix = err.code.map { " (code \($0))" } ?? ""
      throw ChatProviderError.providerRequestFailed(
        "MCP error\(codeSuffix): \(message.isEmpty ? "unknown" : message)")
    }
    let parts = decoded.result?.content?.compactMap { $0.text } ?? []
    let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    if decoded.result?.isError == true {
      return "Error: \(text.isEmpty ? "tool reported failure" : text)"
    }
    return text.isEmpty ? "(no output)" : text
  }

  private static func anyCodable(_ value: AgentToolArgumentValue) -> AnyCodable? {
    switch value {
    case .string(let value):
      return AnyCodable(value)
    case .bool(let value):
      return AnyCodable(value)
    case .int(let value):
      return AnyCodable(value)
    case .double(let value):
      return AnyCodable(value)
    case .object(let value):
      return AnyCodable(value.compactMapValues(anyCodable))
    case .array(let value):
      return AnyCodable(value.compactMap(anyCodable))
    case .null:
      return nil
    }
  }
}

private struct JSONRPCRequest: Encodable {
  var jsonrpc = "2.0"
  var id: Int
  var method: String
  var params: [String: AnyCodable]?
}

private struct MCPToolsListResponse: Decodable {
  struct Result: Decodable {
    var tools: [RawTool]?
  }
  struct RawTool: Decodable {
    var name: String
    var description: String?
  }
  struct Err: Decodable {
    var code: Int?
    var message: String?
  }
  var result: Result?
  var error: Err?
}

private struct MCPToolCallResponse: Decodable {
  struct Result: Decodable {
    var content: [ContentPart]?
    var isError: Bool?
  }
  struct ContentPart: Decodable {
    var type: String?
    var text: String?
  }
  struct Err: Decodable {
    var code: Int?
    var message: String?
  }
  var result: Result?
  var error: Err?
}
