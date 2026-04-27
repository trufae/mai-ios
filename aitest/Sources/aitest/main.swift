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

struct ChatCompletionResult {
  let text: String
  let nativeToolCalls: [AgentNativeToolCall]
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

  func listTools() async throws -> [ToolDefinition] {
    let raw = try await jsonrpc(method: "tools/list", params: nil)
    let result = raw["result"] as? [String: Any] ?? [:]
    let toolList = result["tools"] as? [[String: Any]] ?? []
    return toolList.compactMap { d in
      guard let name = d["name"] as? String else { return nil }
      let desc = (d["description"] as? String) ?? ""
      var schemaJSON = ""
      if let inputSchema = d["inputSchema"] as? [String: Any] {
        if let pdata = try? JSONSerialization.data(
          withJSONObject: inputSchema, options: [.sortedKeys]),
          let s = String(data: pdata, encoding: .utf8)
        {
          schemaJSON = s
        }
      }
      return ToolDefinition(
        name: name,
        description: desc,
        parameters: AgentTooling.parameters(fromSchemaJSON: schemaJSON),
        inputSchemaJSON: schemaJSON)
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
  ) -> [AgentNativeToolCall] {
    AgentTooling.nativeToolCalls(from: acc)
  }

  private func nativeToolCalls(from calls: [[String: Any]]) -> [AgentNativeToolCall] {
    calls.compactMap { tc -> AgentNativeToolCall? in
      let function = tc["function"] as? [String: Any] ?? [:]
      guard let name = function["name"] as? String else { return nil }
      return AgentTooling.makeNativeToolCall(
        id: tc["id"] as? String,
        name: name,
        rawArguments: (function["arguments"] as? String) ?? "")
    }
  }
}

// MARK: - Native tools schema

func openAITools(from tools: [ToolDefinition], resolver: AgentToolNameResolver) -> [[String: Any]] {
  tools.map { tool -> [String: Any] in
    var schema: [String: Any] = [
      "type": "object",
      "properties": [String: Any](),
      "required": [String](),
    ]
    if !tool.inputSchemaJSON.isEmpty,
      let data = tool.inputSchemaJSON.data(using: .utf8),
      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      !parsed.isEmpty
    {
      schema = parsed
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

func parsedCalls(from completion: ChatCompletionResult, tools: [ToolDefinition]) -> [ParsedToolCall]
{
  guard !tools.isEmpty else { return [] }
  if !completion.nativeToolCalls.isEmpty {
    return completion.nativeToolCalls.map { call in
      let normalized = AgentTooling.parseCalls(in: call.textBlock, tools: tools).first
      return ParsedToolCall(
        name: normalized?.name ?? call.name,
        arguments: [:],
        argumentValues: normalized?.argumentValues ?? call.argumentValues,
        rawBlock: call.textBlock,
        toolCallID: call.id,
        apiName: call.name)
    }
  }
  return AgentTooling.parseCalls(in: completion.text, tools: tools)
}

func appendNextTurnMessages(
  mode: String,
  response: String,
  calls: [ParsedToolCall],
  toolResults: [(call: ParsedToolCall, canonical: String, result: String)],
  resolver: AgentToolNameResolver,
  messages: inout [[String: Any]]
) {
  let nativeCalls = calls.filter { $0.toolCallID != nil }
  guard mode == "native", nativeCalls.count == calls.count else {
    var assistantContent = response
    var hostContent = "Tool results:\n"
    for item in toolResults {
      let runBlock = AgentTooling.makeRunBlock(
        toolName: item.canonical, argumentsJSON: item.call.argsJSON, result: item.result)
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
        "\(hostContent.trimmingCharacters(in: .whitespacesAndNewlines))\n\nContinue from these tool results. Inspect the conversation and previous tool results before calling any new tool. If they already contain enough information, give the final answer.",
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

func jsonArguments(_ arguments: [String: AgentToolArgumentValue]) -> [String: Any] {
  arguments.compactMapValues { value in
    if case .null = value { return nil }
    return value.jsonObject
  }
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

  var allTools: [ToolDefinition] = []
  var toolsByName: [String: ToolDefinition] = [:]
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

  let resolver = AgentToolNameResolver(tools: allTools)
  let agentPrompt = AgentTooling.promptDescription(for: allTools)
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
  var didFinish = false
  let maxIterations = allTools.isEmpty ? 1 : cfg.maxIterations

  for iteration in 1...maxIterations {
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

    let calls = allTools.isEmpty ? [] : parsedCalls(from: completion, tools: allTools)
    info("parsed \(calls.count) tool call(s)")

    if calls.isEmpty {
      if !allTools.isEmpty && AgentTooling.containsToolCallMarker(in: response) {
        let feedback = AgentTooling.malformedToolCallFeedback(from: response)
        let turnText = [response, feedback]
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
          .joined(separator: "\n\n")
        fullAssistant += (fullAssistant.isEmpty ? "" : "\n\n") + turnText
        warn("tool_call marker was present but no executable call parsed; asking model to repair it")
        if !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          messages.append(["role": "assistant", "content": response])
        }
        messages.append(["role": "user", "content": feedback])
        continue
      }
      fullAssistant +=
        (fullAssistant.isEmpty ? "" : "\n\n") + response
      ok("loop terminated (no more tool_calls)")
      didFinish = true
      break
    }

    var transformed = response
    var runBlocks: [String] = []
    var toolResults: [(call: ParsedToolCall, canonical: String, result: String)] = []
    for call in calls {
      let canonical = resolver.canonicalName(for: call.name) ?? call.name
      let arguments = AgentTooling.normalizeArguments(
        call.argumentValues, for: toolsByName[canonical])
      let normalizedCall = ParsedToolCall(
        name: canonical,
        arguments: [:],
        argumentValues: arguments,
        rawBlock: call.rawBlock,
        toolCallID: call.toolCallID,
        apiName: call.apiName)
      let displayName = canonical == call.name ? call.name : "\(call.name) → \(canonical)"
      info("dispatching \(ANSI("36", displayName))(\(normalizedCall.argsJSON))")
      let result: String
      if let server = routing[canonical] {
        do {
          result = try await server.callTool(
            name: canonical, arguments: jsonArguments(arguments))
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

      let runBlock = AgentTooling.makeRunBlock(
        toolName: canonical, argumentsJSON: normalizedCall.argsJSON, result: result)
      if let range = transformed.range(of: call.rawBlock) {
        transformed.removeSubrange(range)
      } else {
        transformed = transformed.replacingOccurrences(of: call.rawBlock, with: "")
      }
      runBlocks.append(runBlock)
    }

    let turnText = ([transformed.trimmingCharacters(in: .whitespacesAndNewlines)] + runBlocks)
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .joined(separator: "\n\n")
    fullAssistant += (fullAssistant.isEmpty ? "" : "\n\n") + turnText
    appendNextTurnMessages(
      mode: cfg.mode,
      response: response,
      calls: calls,
      toolResults: toolResults,
      resolver: resolver,
      messages: &messages)
  }

  if !didFinish {
    warn("loop reached max iterations after executing pending tool calls")
  }

  print()
  print(ANSI("1;32", "═══ final assistant turn ═══"))
  print(fullAssistant)
}

func isEmptyProviderTurn(_ error: Error) -> Bool {
  (error as NSError).localizedDescription.contains("Stream produced no content")
}

await runMain()
