import Foundation
import Synchronization

// =====================================================================
// aitest — standalone agentic-loop debugger for OpenAI-compatible
// endpoints with optional MCP servers. Mirrors the same protocol used
// by the MAIChat iOS app:
//   • Text mode: <tool_call>/<tool_run> XML blocks injected into the
//     conversation.
//   • Native mode: OpenAI tools[] in the request, tool_calls parsed
//     from the response and converted into <tool_call> blocks for the
//     same downstream loop.
// =====================================================================

// MARK: - CLI

struct CLIConfig {
  var baseURL: String = ""
  var apiKey: String = ""
  var model: String = ""
  var prompt: String = ""
  var mcpURLs: [String] = []
  var mcpKeys: [String: String] = [:]
  var mode: String = "text"
  var stream: Bool = true
  var maxIterations: Int = 6
  var verbose: Bool = true
  var systemPrompt: String =
    "You are a helpful assistant. Use tools when they help answer the user's question."
}

func printUsage() {
  let msg = """
    aitest — debug the agentic loop without shipping iOS builds.

    Usage:
      aitest [flags] --base-url URL --api-key KEY --model NAME --message TEXT

    Required:
      --base-url URL           OpenAI-compatible base, e.g. https://api.openai.com/v1
      --api-key KEY            Bearer token (or "none" for no auth)
      --model NAME             Model identifier
      --message TEXT  -m TEXT  User message

    Optional:
      --mode text|native|api   Tool-calling protocol (default: text; api is native)
      --no-stream              Disable streaming (default: streaming on)
      --max-iter N             Max agent iterations (default: 6)
      --mcp URL                MCP server URL (repeatable)
      --mcp-key URL=KEY        Bearer for that MCP server (repeatable)
      --system TEXT            Override the system prompt
      --quiet                  Less verbose output

    Example:
      swift run aitest \\
        --base-url https://ollama.com/v1 \\
        --api-key sk-... \\
        --model gpt-oss:120b \\
        --mcp http://192.168.1.10:8080/mcp \\
        --message "list functions in /tmp/binary"
    """
  FileHandle.standardError.write(Data((msg + "\n").utf8))
}

func parseArgs() -> CLIConfig? {
  var cfg = CLIConfig()
  var it = CommandLine.arguments.dropFirst().makeIterator()
  while let arg = it.next() {
    switch arg {
    case "--base-url": cfg.baseURL = it.next() ?? ""
    case "--api-key": cfg.apiKey = it.next() ?? ""
    case "--model": cfg.model = it.next() ?? ""
    case "--message", "-m": cfg.prompt = it.next() ?? ""
    case "--mode": cfg.mode = normalizeMode(it.next() ?? "text")
    case "--no-stream": cfg.stream = false
    case "--max-iter":
      cfg.maxIterations = Int(it.next() ?? "6") ?? 6
    case "--mcp":
      if let v = it.next() { cfg.mcpURLs.append(v) }
    case "--mcp-key":
      if let v = it.next() {
        let parts = v.split(separator: "=", maxSplits: 1).map(String.init)
        if parts.count == 2 { cfg.mcpKeys[parts[0]] = parts[1] }
      }
    case "--system":
      if let v = it.next() { cfg.systemPrompt = v }
    case "--quiet": cfg.verbose = false
    case "--help", "-h":
      printUsage()
      return nil
    default:
      FileHandle.standardError.write(Data("unknown flag: \(arg)\n".utf8))
      return nil
    }
  }
  if cfg.baseURL.isEmpty || cfg.apiKey.isEmpty || cfg.model.isEmpty || cfg.prompt.isEmpty {
    printUsage()
    return nil
  }
  guard cfg.mode == "text" || cfg.mode == "native" else {
    FileHandle.standardError.write(
      Data("invalid --mode: \(cfg.mode) (expected text, native, or api)\n".utf8))
    return nil
  }
  return cfg
}

func normalizeMode(_ mode: String) -> String {
  switch mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
  case "api", "tool", "tools":
    return "native"
  default:
    return mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}

// MARK: - Logging

nonisolated(unsafe) var verbose = true

func ANSI(_ code: String, _ s: String) -> String {
  isatty(fileno(stderr)) != 0 ? "\u{001B}[\(code)m\(s)\u{001B}[0m" : s
}
func info(_ msg: String) {
  FileHandle.standardError.write(Data("\(ANSI("36", "[i]")) \(msg)\n".utf8))
}
func warn(_ msg: String) {
  FileHandle.standardError.write(Data("\(ANSI("33", "[!]")) \(msg)\n".utf8))
}
func err(_ msg: String) {
  FileHandle.standardError.write(Data("\(ANSI("31", "[x]")) \(msg)\n".utf8))
}
func ok(_ msg: String) {
  FileHandle.standardError.write(Data("\(ANSI("32", "[+]")) \(msg)\n".utf8))
}
func vlog(_ msg: String) {
  if verbose { FileHandle.standardError.write(Data("    \(msg)\n".utf8)) }
}

// MARK: - Models

struct MCPTool {
  let name: String
  let description: String
  let inputSchema: [String: Any]?
  let parametersJSON: String
}

struct ParsedToolCall {
  let name: String
  let arguments: [String: Any]
  let rawBlock: String
  let toolCallID: String?
  let apiName: String?
  var argsJSON: String {
    (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]))
      .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
  }
}

struct NativeToolCall {
  let id: String
  let name: String
  let arguments: [String: Any]
  let rawArguments: String

  var textBlock: String {
    let payload: [String: Any] = ["name": name, "arguments": arguments]
    guard
      let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
      let json = String(data: data, encoding: .utf8)
    else { return "" }
    return "<tool_call>\(json)</tool_call>"
  }
}

struct ChatCompletionResult {
  let text: String
  let nativeToolCalls: [NativeToolCall]
}

struct ToolNameResolver {
  private let canonicalByAlias: [String: String]
  private let canonicalByShortAlias: [String: String]
  private let apiByCanonical: [String: String]

  init(tools: [MCPTool]) {
    var aliases: [String: String] = [:]
    var shortAliases: [String: String] = [:]
    var ambiguousShortAliases = Set<String>()
    var apiNames: [String: String] = [:]
    var usedAPI = Set<String>()

    for tool in tools {
      let api = ToolNameResolver.uniqueAPIName(for: tool.name, used: &usedAPI)
      apiNames[tool.name] = api
      let candidates = [
        tool.name,
        api,
        tool.name.replacingOccurrences(of: "::", with: "."),
        tool.name.replacingOccurrences(of: "::", with: "_"),
        tool.name.replacingOccurrences(of: "::", with: "__"),
      ]
      for candidate in candidates {
        aliases[ToolNameResolver.key(candidate)] = tool.name
      }
      let shortKey = ToolNameResolver.shortKey(tool.name)
      if let existing = shortAliases[shortKey], existing != tool.name {
        ambiguousShortAliases.insert(shortKey)
      } else {
        shortAliases[shortKey] = tool.name
      }
    }
    for key in ambiguousShortAliases {
      shortAliases.removeValue(forKey: key)
    }

    canonicalByAlias = aliases
    canonicalByShortAlias = shortAliases
    apiByCanonical = apiNames
  }

  func canonicalName(for name: String) -> String? {
    canonicalByAlias[ToolNameResolver.key(name)]
      ?? canonicalByShortAlias[ToolNameResolver.shortKey(name)]
  }

  func apiName(for canonical: String) -> String {
    apiByCanonical[canonical] ?? ToolNameResolver.sanitizeAPIName(canonical)
  }

  private static func key(_ name: String) -> String {
    name
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .filter { $0.isLetter || $0.isNumber }
  }

  private static func shortKey(_ name: String) -> String {
    let parts = name.split { !$0.isLetter && !$0.isNumber }
    return key(String(parts.last ?? Substring(name)))
  }

  private static func uniqueAPIName(for name: String, used: inout Set<String>) -> String {
    let base = sanitizeAPIName(name)
    var candidate = base
    var n = 2
    while used.contains(candidate) {
      candidate = "\(base)_\(n)"
      n += 1
    }
    used.insert(candidate)
    return candidate
  }

  private static func sanitizeAPIName(_ name: String) -> String {
    var out = ""
    var lastWasUnderscore = false
    for scalar in name.unicodeScalars {
      let isAllowed =
        CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
      if isAllowed {
        out.unicodeScalars.append(scalar)
        lastWasUnderscore = false
      } else if !lastWasUnderscore {
        out.append("_")
        lastWasUnderscore = true
      }
    }
    out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
    if out.isEmpty { out = "tool" }
    if out.first?.isNumber == true { out = "tool_\(out)" }
    if out.count > 64 {
      out = String(out.prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
    }
    return out
  }
}

// MARK: - HTTP

func postJSON(url: URL, body: Data, headers: [String: String]) async throws -> (
  Data, HTTPURLResponse
) {
  var req = URLRequest(url: url)
  req.httpMethod = "POST"
  req.setValue("application/json", forHTTPHeaderField: "Content-Type")
  for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
  req.httpBody = body
  req.timeoutInterval = 60
  let (data, response) = try await URLSession.shared.data(for: req)
  guard let http = response as? HTTPURLResponse else {
    throw NSError(
      domain: "aitest", code: -1, userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response"])
  }
  return (data, http)
}

// MARK: - MCP

struct MCPClient {
  let url: URL
  let bearer: String?

  func headers() -> [String: String] {
    var h = ["Accept": "application/json, text/event-stream"]
    if let bearer, !bearer.isEmpty { h["Authorization"] = "Bearer \(bearer)" }
    return h
  }

  private func jsonrpc(method: String, params: [String: Any]?) async throws -> [String: Any] {
    var payload: [String: Any] = [
      "jsonrpc": "2.0", "id": Int.random(in: 1...Int.max), "method": method,
    ]
    if let params { payload["params"] = params }
    let data = try JSONSerialization.data(withJSONObject: payload)
    let (resp, http) = try await postJSON(url: url, body: data, headers: headers())
    guard (200..<300).contains(http.statusCode) else {
      let snippet = String(data: resp.prefix(400), encoding: .utf8) ?? ""
      throw NSError(
        domain: "aitest", code: http.statusCode,
        userInfo: [NSLocalizedDescriptionKey: "MCP HTTP \(http.statusCode): \(snippet)"])
    }
    guard let raw = try? JSONSerialization.jsonObject(with: resp) as? [String: Any] else {
      throw NSError(
        domain: "aitest", code: -1,
        userInfo: [NSLocalizedDescriptionKey: "MCP returned non-JSON"])
    }
    if let error = raw["error"] as? [String: Any] {
      let msg = (error["message"] as? String) ?? "unknown"
      let code = (error["code"] as? Int).map { " (code \($0))" } ?? ""
      throw NSError(
        domain: "aitest", code: -1,
        userInfo: [NSLocalizedDescriptionKey: "MCP error\(code): \(msg)"])
    }
    return raw
  }

  func listTools() async throws -> [MCPTool] {
    let raw = try await jsonrpc(method: "tools/list", params: nil)
    let result = raw["result"] as? [String: Any] ?? [:]
    let toolList = result["tools"] as? [[String: Any]] ?? []
    return toolList.compactMap { d in
      guard let name = d["name"] as? String else { return nil }
      let desc = (d["description"] as? String) ?? ""
      var schema: [String: Any]? = nil
      var schemaJSON = ""
      if let inputSchema = d["inputSchema"] as? [String: Any] {
        schema = inputSchema
        if let pdata = try? JSONSerialization.data(
          withJSONObject: inputSchema, options: [.sortedKeys]),
          let s = String(data: pdata, encoding: .utf8)
        {
          schemaJSON = s
        }
      }
      return MCPTool(
        name: name, description: desc, inputSchema: schema, parametersJSON: schemaJSON)
    }
  }

  func callTool(name: String, arguments: [String: Any]) async throws -> String {
    let raw = try await jsonrpc(
      method: "tools/call", params: ["name": name, "arguments": arguments])
    let result = raw["result"] as? [String: Any] ?? [:]
    let parts = (result["content"] as? [[String: Any]] ?? [])
      .compactMap { $0["text"] as? String }
    let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    if (result["isError"] as? Bool) == true {
      return "Error: \(text.isEmpty ? "tool reported failure" : text)"
    }
    return text.isEmpty ? "(no output)" : text
  }
}

// MARK: - Tool-call parser (text protocol)

func parseToolCalls(in text: String) -> [ParsedToolCall] {
  let pattern = "<tool_call>([\\s\\S]*?)</tool_call>"
  guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
  else { return [] }
  let nsText = text as NSString
  let matches = regex.matches(
    in: text, options: [], range: NSRange(location: 0, length: nsText.length))
  var calls: [ParsedToolCall] = []
  for m in matches {
    guard m.numberOfRanges == 2 else { continue }
    let raw = nsText.substring(with: m.range(at: 0))
    let json = nsText.substring(with: m.range(at: 1))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let call = parseToolCallJSON(json, rawBlock: raw) {
      calls.append(call)
    }
  }
  if let trailing = trailingUnclosedToolCall(in: text),
    let call = parseToolCallJSON(trailing.json, rawBlock: trailing.rawBlock)
  {
    calls.append(call)
  }
  return calls
}

func parseToolCallJSON(_ json: String, rawBlock: String) -> ParsedToolCall? {
  guard let data = json.data(using: .utf8),
    let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let obj = normalizeToolCallObject(parsed),
    let name = (obj["name"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
    !name.isEmpty
  else { return nil }
  let args = (obj["arguments"] as? [String: Any]) ?? [:]
  return ParsedToolCall(
    name: name, arguments: args, rawBlock: rawBlock, toolCallID: nil, apiName: nil)
}

func trailingUnclosedToolCall(in text: String) -> (rawBlock: String, json: String)? {
  guard
    let open = text.range(
      of: "<tool_call>", options: [.caseInsensitive, .backwards]),
    text.range(
      of: "</tool_call>", options: [.caseInsensitive], range: open.upperBound..<text.endIndex)
      == nil
  else { return nil }
  let raw = String(text[open.lowerBound..<text.endIndex])
  let json = String(text[open.upperBound..<text.endIndex])
    .trimmingCharacters(in: .whitespacesAndNewlines)
  return json.isEmpty ? nil : (raw, json)
}

func normalizeToolCallObject(_ object: [String: Any]) -> [String: Any]? {
  if let name = object["name"] as? String,
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  {
    if let nested = object["arguments"] as? [String: Any],
      let nestedName = nested["name"] as? String
    {
      return [
        "name": nestedName,
        "arguments": (nested["arguments"] as? [String: Any]) ?? [:],
      ]
    }
    return object
  }
  if let name = (object["tool"] as? String) ?? (object["function"] as? String) {
    return [
      "name": name,
      "arguments": (object["arguments"] as? [String: Any]) ?? object["args"] ?? [:],
    ]
  }
  return nil
}

func inferBareToolCall(in text: String, tools: [MCPTool]) -> ParsedToolCall? {
  let visible = stripThinkBlocks(from: text).trimmingCharacters(in: .whitespacesAndNewlines)
  guard visible.hasPrefix("{"), visible.hasSuffix("}"),
    let data = visible.data(using: .utf8),
    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  else { return nil }

  if let normalized = normalizeToolCallObject(object),
    let name = normalized["name"] as? String
  {
    return ParsedToolCall(
      name: name,
      arguments: (normalized["arguments"] as? [String: Any]) ?? [:],
      rawBlock: visible,
      toolCallID: nil,
      apiName: nil)
  }

  let objectKeys = Set(object.keys)
  guard !objectKeys.isEmpty else { return nil }
  let candidates = tools.compactMap { tool -> (tool: MCPTool, score: Int)? in
    let properties = Set((tool.inputSchema?["properties"] as? [String: Any] ?? [:]).keys)
    let required = Set(tool.inputSchema?["required"] as? [String] ?? [])
    guard !properties.isEmpty, objectKeys.isSubset(of: properties) else { return nil }
    guard required.isEmpty || required.isSubset(of: objectKeys) else { return nil }
    return (tool, objectKeys.intersection(properties).count + required.count)
  }
  let sorted = candidates.sorted { $0.score > $1.score }
  guard let first = sorted.first else { return nil }
  if sorted.count > 1, sorted[1].score == first.score { return nil }
  return ParsedToolCall(
    name: first.tool.name,
    arguments: object,
    rawBlock: visible,
    toolCallID: nil,
    apiName: nil)
}

func stripThinkBlocks(from text: String) -> String {
  let pattern = "<think>[\\s\\S]*?</think>"
  guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
  else { return text }
  let range = NSRange(location: 0, length: (text as NSString).length)
  return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
}

// MARK: - Agent prompt

func buildAgentPrompt(tools: [MCPTool], resolver: ToolNameResolver) -> String {
  if tools.isEmpty { return "" }
  let listing = tools.map { tool -> String in
    let base =
      tool.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "MCP tool"
      : tool.description
    let api = resolver.apiName(for: tool.name)
    let name = api == tool.name ? tool.name : "\(tool.name) (API/native alias: \(api))"
    if !tool.parametersJSON.isEmpty {
      return "- \(name): \(base) Input schema: \(tool.parametersJSON)"
    }
    return "- \(name): \(base)"
  }.joined(separator: "\n")

  return """
    ## Available Tools

    \(listing)

    ### Tool-call protocol

    Emit a single block per tool you want to run:
    <tool_call>{"name":"tool_name","arguments":{"arg":"value"}}</tool_call>

    Rules:
    1. After </tool_call>, STOP. Do NOT write the final answer in the same response.
    2. <tool_run> blocks contain authoritative tool results — read carefully.
    3. The final answer is a response WITHOUT any <tool_call> blocks.
    4. Use only listed tool names or their API/native aliases; arguments must be valid JSON on a single line.
    5. Do not re-run a tool whose <tool_run> already exists in the conversation.
    """
}

// MARK: - OpenAI client

struct OpenAIRequest {
  let messages: [[String: Any]]
  let nativeTools: [[String: Any]]?
}

struct OpenAIClient {
  let baseURL: String
  let apiKey: String
  let model: String
  let stream: Bool

  private var endpoint: URL {
    let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return URL(string: "\(base)/chat/completions")!
  }

  private func headers() -> [String: String] {
    var h: [String: String] = [:]
    if !apiKey.isEmpty && apiKey != "none" {
      h["Authorization"] = "Bearer \(apiKey)"
    }
    return h
  }

  func chatCompletion(_ req: OpenAIRequest) async throws -> ChatCompletionResult {
    var body: [String: Any] = [
      "model": model,
      "messages": req.messages,
      "stream": stream,
    ]
    if let tools = req.nativeTools, !tools.isEmpty {
      body["tools"] = tools
    }
    let bodyData = try JSONSerialization.data(withJSONObject: body)

    if verbose {
      vlog("→ POST \(endpoint.absoluteString)")
      let preview = String(data: bodyData, encoding: .utf8) ?? "<binary>"
      vlog("→ body: \(preview.count > 1500 ? String(preview.prefix(1500)) + "…" : preview)")
    }

    if stream {
      return try await streamRequest(body: bodyData)
    }
    return try await singleRequest(body: bodyData)
  }

  private func singleRequest(body: Data) async throws -> ChatCompletionResult {
    let (data, http) = try await postJSON(url: endpoint, body: body, headers: headers())
    let bodyStr = String(data: data, encoding: .utf8) ?? ""
    if !(200..<300).contains(http.statusCode) {
      throw NSError(
        domain: "aitest", code: http.statusCode,
        userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(bodyStr)"])
    }
    if verbose {
      vlog("← \(bodyStr.count) chars")
    }
    guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw NSError(
        domain: "aitest", code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Non-JSON response: \(bodyStr.prefix(400))"])
    }
    return assemble(fromChoiceRoot: raw)
  }

  private func streamRequest(body: Data) async throws -> ChatCompletionResult {
    var req = URLRequest(url: endpoint)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for (k, v) in headers() { req.setValue(v, forHTTPHeaderField: k) }
    req.httpBody = body
    req.timeoutInterval = 120

    let (bytes, response) = try await URLSession.shared.bytes(for: req)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0

    var content = ""
    var reasoning = ""
    var tcAcc: [Int: (id: String?, name: String?, args: String)] = [:]
    var rawLines: [String] = []
    var trace: [String] = []

    for try await line in bytes.lines {
      if trace.count < 80 { trace.append(line) }
      if !(200..<300).contains(status) {
        rawLines.append(line)
        continue
      }
      guard line.hasPrefix("data:") else {
        if !line.isEmpty { rawLines.append(line) }
        continue
      }
      let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
      if payload == "[DONE]" { break }
      guard let data = payload.data(using: .utf8) else { continue }
      guard let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else {
        if verbose { vlog("undecodable chunk: \(payload.prefix(200))") }
        continue
      }
      if let error = chunk["error"] as? [String: Any] {
        let msg = (error["message"] as? String) ?? "unknown"
        throw NSError(
          domain: "aitest", code: -1,
          userInfo: [NSLocalizedDescriptionKey: "Stream error: \(msg)"])
      }
      let choices = chunk["choices"] as? [[String: Any]] ?? []
      guard let choice = choices.first else { continue }
      let delta = choice["delta"] as? [String: Any] ?? [:]
      if let s = delta["content"] as? String {
        content += s
        if verbose && !s.isEmpty { print(s, terminator: "") }
      }
      if let r =
        (delta["reasoning_content"] as? String)
        ?? (delta["reasoning"] as? String)
      {
        reasoning += r
      }
      if let tcs = delta["tool_calls"] as? [[String: Any]] {
        for tc in tcs {
          let idx = (tc["index"] as? Int) ?? 0
          var entry = tcAcc[idx] ?? (nil, nil, "")
          if let id = tc["id"] as? String { entry.id = id }
          let function = tc["function"] as? [String: Any] ?? [:]
          if let name = function["name"] as? String { entry.name = name }
          if let args = function["arguments"] as? String { entry.args += args }
          tcAcc[idx] = entry
        }
      }
    }
    if verbose && !content.isEmpty { print() }

    if !(200..<300).contains(status) {
      let snippet = rawLines.joined(separator: "\n")
      throw NSError(
        domain: "aitest", code: status,
        userInfo: [NSLocalizedDescriptionKey: "HTTP \(status): \(snippet.prefix(800))"])
    }

    vlog(
      "← stream summary: content=\(content.count) reasoning=\(reasoning.count) tool_calls=\(tcAcc.count)"
    )

    var result = content
    if !reasoning.isEmpty {
      result =
        result.isEmpty
        ? "<think>\n\(reasoning)\n</think>"
        : "<think>\n\(reasoning)\n</think>\n\n\(result)"
    }
    let nativeCalls = nativeToolCalls(from: tcAcc)
    let toolCallText = nativeCalls.map(\.textBlock).filter { !$0.isEmpty }.joined(separator: "\n")
    if !toolCallText.isEmpty {
      result =
        result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? toolCallText
        : "\(result)\n\n\(toolCallText)"
    }
    if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let last = trace.suffix(20).joined(separator: "\n")
      throw NSError(
        domain: "aitest", code: -1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Stream produced no content. Last lines:\n\(last)"
        ])
    }
    return ChatCompletionResult(text: result, nativeToolCalls: nativeCalls)
  }

  private func assemble(fromChoiceRoot raw: [String: Any]) -> ChatCompletionResult {
    let choices = raw["choices"] as? [[String: Any]] ?? []
    guard let first = choices.first else {
      return ChatCompletionResult(text: "", nativeToolCalls: [])
    }
    let message = first["message"] as? [String: Any] ?? [:]
    var text = (message["content"] as? String) ?? ""
    if let r =
      (message["reasoning_content"] as? String)
      ?? (message["reasoning"] as? String)
    {
      text =
        text.isEmpty
        ? "<think>\n\(r)\n</think>"
        : "<think>\n\(r)\n</think>\n\n\(text)"
    }
    let nativeCalls = nativeToolCalls(from: message["tool_calls"] as? [[String: Any]] ?? [])
    let blocks = nativeCalls.map(\.textBlock).filter { !$0.isEmpty }
    if !blocks.isEmpty {
      text =
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? blocks.joined(separator: "\n")
        : "\(text)\n\n\(blocks.joined(separator: "\n"))"
    }
    return ChatCompletionResult(text: text, nativeToolCalls: nativeCalls)
  }

  private func nativeToolCalls(
    from acc: [Int: (id: String?, name: String?, args: String)]
  ) -> [NativeToolCall] {
    acc.sorted(by: { $0.key < $1.key }).compactMap {
      _, e -> NativeToolCall? in
      guard let name = e.name else { return nil }
      return makeNativeToolCall(id: e.id, name: name, rawArguments: e.args)
    }
  }

  private func nativeToolCalls(from calls: [[String: Any]]) -> [NativeToolCall] {
    calls.compactMap { tc -> NativeToolCall? in
      let function = tc["function"] as? [String: Any] ?? [:]
      guard let name = function["name"] as? String else { return nil }
      return makeNativeToolCall(
        id: tc["id"] as? String,
        name: name,
        rawArguments: (function["arguments"] as? String) ?? "")
    }
  }

  private func makeNativeToolCall(id: String?, name: String, rawArguments: String) -> NativeToolCall
  {
    var argsObj: Any = [:] as [String: Any]
    if !rawArguments.isEmpty,
      let d = rawArguments.data(using: .utf8),
      let parsed = try? JSONSerialization.jsonObject(with: d)
    {
      argsObj = parsed
    }
    return NativeToolCall(
      id: id ?? "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
      name: name,
      arguments: (argsObj as? [String: Any]) ?? [:],
      rawArguments: rawArguments.isEmpty ? "{}" : rawArguments)
  }
}

// MARK: - Native tools schema

func openAITools(from tools: [MCPTool], resolver: ToolNameResolver) -> [[String: Any]] {
  tools.map { tool -> [String: Any] in
    var schema: [String: Any] = [
      "type": "object",
      "properties": [String: Any](),
      "required": [String](),
    ]
    if let s = tool.inputSchema, !s.isEmpty {
      schema = s
    }
    return [
      "type": "function",
      "function": [
        "name": resolver.apiName(for: tool.name),
        "description":
          (tool.description.isEmpty ? "MCP tool" : tool.description)
          + (resolver.apiName(for: tool.name) == tool.name
            ? "" : " Original MCP name: \(tool.name)."),
        "parameters": schema,
      ] as [String: Any],
    ]
  }
}

func parsedCalls(from completion: ChatCompletionResult, tools: [MCPTool]) -> [ParsedToolCall] {
  if !completion.nativeToolCalls.isEmpty {
    return completion.nativeToolCalls.map { call in
      ParsedToolCall(
        name: call.name,
        arguments: call.arguments,
        rawBlock: call.textBlock,
        toolCallID: call.id,
        apiName: call.name)
    }
  }
  let explicit = parseToolCalls(in: completion.text)
  if !explicit.isEmpty { return explicit }
  return inferBareToolCall(in: completion.text, tools: tools).map { [$0] } ?? []
}

func appendNextTurnMessages(
  mode: String,
  response: String,
  calls: [ParsedToolCall],
  toolResults: [(call: ParsedToolCall, canonical: String, result: String)],
  resolver: ToolNameResolver,
  messages: inout [[String: Any]]
) {
  let nativeCalls = calls.filter { $0.toolCallID != nil }
  guard mode == "native", nativeCalls.count == calls.count else {
    var assistantContent = response
    var hostContent = "Tool results:\n"
    for item in toolResults {
      let runBlock =
        "<tool_run>\n\(item.canonical) tool (\(item.call.argsJSON)):\n\(item.result.trimmingCharacters(in: .whitespacesAndNewlines))\n</tool_run>"
      hostContent += "\n\(runBlock)\n"
      if let range = assistantContent.range(of: item.call.rawBlock) {
        assistantContent.removeSubrange(range)
      } else {
        assistantContent = assistantContent.replacingOccurrences(of: item.call.rawBlock, with: "")
      }
    }
    assistantContent = assistantContent.trimmingCharacters(in: .whitespacesAndNewlines)
    if !assistantContent.isEmpty {
      messages.append(["role": "assistant", "content": assistantContent])
    }
    messages.append([
      "role": "user",
      "content":
        "\(hostContent.trimmingCharacters(in: .whitespacesAndNewlines))\n\nContinue from these tool results. Either call the next needed tool or give the final answer.",
    ])
    return
  }

  var assistantContent = response
  for call in calls {
    assistantContent = assistantContent.replacingOccurrences(of: call.rawBlock, with: "")
  }
  assistantContent = assistantContent.trimmingCharacters(in: .whitespacesAndNewlines)

  let toolCalls: [[String: Any]] = calls.map { call in
    let canonical = resolver.canonicalName(for: call.name) ?? call.name
    let apiName = call.apiName ?? resolver.apiName(for: canonical)
    return [
      "id": call.toolCallID ?? "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
      "type": "function",
      "function": [
        "name": apiName,
        "arguments": call.argsJSON,
      ],
    ]
  }

  messages.append([
    "role": "assistant",
    "content": assistantContent,
    "tool_calls": toolCalls,
  ])
  for item in toolResults {
    guard let id = item.call.toolCallID else { continue }
    messages.append([
      "role": "tool",
      "tool_call_id": id,
      "content": item.result,
    ])
  }
}

func normalizedArguments(_ arguments: [String: Any], for tool: MCPTool?) -> [String: Any] {
  guard let tool,
    let required = tool.inputSchema?["required"] as? [String],
    required.count == 1,
    let requiredName = required.first,
    arguments[requiredName] == nil,
    arguments.count == 1,
    let value = arguments.values.first
  else { return arguments }
  return [requiredName: value]
}

// MARK: - Run

func runMain() async {
  guard let cfg = parseArgs() else { exit(2) }
  verbose = cfg.verbose

  info("base URL : \(cfg.baseURL)")
  info("model    : \(cfg.model)")
  info("mode     : \(cfg.mode)\(cfg.stream ? " (streaming)" : " (non-streaming)")")
  info("max iter : \(cfg.maxIterations)")
  info("MCPs     : \(cfg.mcpURLs.isEmpty ? "(none)" : cfg.mcpURLs.joined(separator: ", "))")
  print()

  var allTools: [MCPTool] = []
  var toolsByName: [String: MCPTool] = [:]
  var routing: [String: MCPClient] = [:]
  for urlStr in cfg.mcpURLs {
    guard let url = URL(string: urlStr) else {
      warn("invalid MCP URL: \(urlStr)")
      continue
    }
    let bearer = cfg.mcpKeys[urlStr]
    let client = MCPClient(url: url, bearer: bearer)
    info("MCP \(urlStr): listing tools…")
    do {
      let tools = try await client.listTools()
      ok("→ \(tools.count) tools: \(tools.map(\.name).joined(separator: ", "))")
      for t in tools { routing[t.name] = client }
      for t in tools { toolsByName[t.name] = t }
      allTools.append(contentsOf: tools)
    } catch {
      err("tools/list failed: \(error.localizedDescription)")
    }
  }
  print()

  let resolver = ToolNameResolver(tools: allTools)
  let agentPrompt = buildAgentPrompt(tools: allTools, resolver: resolver)
  let systemContent =
    agentPrompt.isEmpty
    ? cfg.systemPrompt
    : "\(cfg.systemPrompt)\n\n\(agentPrompt)"

  var messages: [[String: Any]] = [
    ["role": "system", "content": systemContent],
    ["role": "user", "content": cfg.prompt],
  ]

  let openai = OpenAIClient(
    baseURL: cfg.baseURL, apiKey: cfg.apiKey, model: cfg.model, stream: cfg.stream)
  let nativeTools: [[String: Any]]? =
    cfg.mode == "native" && !allTools.isEmpty
    ? openAITools(from: allTools, resolver: resolver) : nil

  var fullAssistant = ""

  for iteration in 1...cfg.maxIterations {
    info(ANSI("1;35", "=== iteration \(iteration) ==="))
    let completion: ChatCompletionResult
    do {
      completion = try await openai.chatCompletion(
        OpenAIRequest(messages: messages, nativeTools: nativeTools))
    } catch {
      if isEmptyProviderTurn(error), !fullAssistant.isEmpty {
        warn("provider returned an empty turn; terminating with the transcript collected so far")
        break
      }
      err("provider call failed: \(error.localizedDescription)")
      exit(1)
    }
    let response = completion.text
    print(ANSI("90", "── raw assistant ──"))
    print(response)
    print(ANSI("90", "───────────────────"))

    let calls = parsedCalls(from: completion, tools: allTools)
    info("parsed \(calls.count) tool call(s)")

    if calls.isEmpty || iteration == cfg.maxIterations {
      fullAssistant +=
        (fullAssistant.isEmpty ? "" : "\n\n") + response
      ok("loop terminated (no more tool_calls or max iter reached)")
      break
    }

    var transformed = response
    var toolResults: [(call: ParsedToolCall, canonical: String, result: String)] = []
    for call in calls {
      let canonical = resolver.canonicalName(for: call.name) ?? call.name
      let arguments = normalizedArguments(call.arguments, for: toolsByName[canonical])
      let normalizedCall = ParsedToolCall(
        name: call.name,
        arguments: arguments,
        rawBlock: call.rawBlock,
        toolCallID: call.toolCallID,
        apiName: call.apiName)
      let displayName = canonical == call.name ? call.name : "\(call.name) → \(canonical)"
      info("dispatching \(ANSI("36", displayName))(\(normalizedCall.argsJSON))")
      let result: String
      if let server = routing[canonical] {
        do {
          result = try await server.callTool(
            name: canonical, arguments: arguments)
        } catch {
          result = "Error: \(error.localizedDescription)"
        }
      } else {
        result = "Error: unknown tool '\(call.name)' (not provided by any registered MCP)"
      }
      toolResults.append((normalizedCall, canonical, result))
      let preview =
        result.count > 400 ? String(result.prefix(400)) + "…" : result
      print(ANSI("90", "── result ──"))
      print(preview)
      print(ANSI("90", "────────────"))

      let runBlock =
        "<tool_run>\n\(canonical) tool (\(normalizedCall.argsJSON)):\n\(result.trimmingCharacters(in: .whitespacesAndNewlines))\n</tool_run>"
      if let range = transformed.range(of: call.rawBlock) {
        transformed.replaceSubrange(range, with: runBlock)
      } else {
        transformed += "\n\n" + runBlock
      }
    }

    fullAssistant += (fullAssistant.isEmpty ? "" : "\n\n") + transformed
    appendNextTurnMessages(
      mode: cfg.mode,
      response: response,
      calls: calls,
      toolResults: toolResults,
      resolver: resolver,
      messages: &messages)
  }

  print()
  print(ANSI("1;32", "═══ final assistant turn ═══"))
  print(fullAssistant)
}

func isEmptyProviderTurn(_ error: Error) -> Bool {
  (error as NSError).localizedDescription.contains("Stream produced no content")
}

await runMain()
