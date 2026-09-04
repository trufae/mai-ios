import Foundation

public final class OpenAICompatibleProvider: ChatProvider, @unchecked Sendable {
  public struct Configuration: Sendable {
    public var id: ProviderID
    public var displayName: String
    public var baseURL: URL
    public var apiKey: String?
    public var additionalHeaders: [String: String]
    public var requestTimeout: TimeInterval

    public init(
      id: ProviderID = .openAI,
      displayName: String = "OpenAI-compatible",
      baseURL: URL,
      apiKey: String? = nil,
      additionalHeaders: [String: String] = [:],
      requestTimeout: TimeInterval = 600
    ) {
      self.id = id
      self.displayName = displayName
      self.baseURL = baseURL
      self.apiKey = apiKey
      self.additionalHeaders = additionalHeaders
      self.requestTimeout = requestTimeout
    }
  }

  public let descriptor: ProviderDescriptor
  private let configuration: Configuration
  private let session: URLSession

  public init(
    configuration: Configuration,
    session: URLSession = .shared
  ) {
    self.configuration = configuration
    self.session = session
    descriptor = ProviderDescriptor(
      id: configuration.id,
      displayName: configuration.displayName,
      capabilities: [
        .streaming, .nativeToolCalling, .imageInput, .audioInput, .reasoning,
        .structuredOutput,
      ])
  }

  public func complete(
    _ request: ProviderRequest,
    emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    let model = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else { throw OpenAICompatibleProviderError.missingModel }

    let resolver = ToolNameResolver(definitions: request.tools)
    let urlRequest = try makeURLRequest(request, model: model, resolver: resolver)
    return request.stream
      ? try await stream(urlRequest, resolver: resolver, emit: emit)
      : try await completeOnce(urlRequest, resolver: resolver, emit: emit)
  }

  public func availableModels() async throws -> [ModelDescriptor] {
    var request = URLRequest(url: try endpointURL("models"))
    request.httpMethod = "GET"
    request.timeoutInterval = max(1, configuration.requestTimeout)
    applyHeaders(to: &request)

    let delegate = ProviderRedirectDelegate(originalRequest: request)
    let (data, response) = try await session.data(for: request, delegate: delegate)
    try validate(response: response, data: data)
    let root = try decodeRoot(data)
    if let message = providerError(in: root) {
      throw OpenAICompatibleProviderError.providerFailure(message)
    }
    guard let values = (root["data"] ?? root["models"])?.arrayValue else {
      throw OpenAICompatibleProviderError.invalidResponse(
        "Expected a model catalog in the provider response.")
    }
    return values.compactMap { value in
      guard let object = value.objectValue,
        let id = object["id"]?.stringValue,
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return nil }
      return ModelDescriptor(
        id: id,
        displayName: object["display_name"]?.stringValue ?? object["name"]?.stringValue,
        ownedBy: object["owned_by"]?.stringValue ?? object["ownedBy"]?.stringValue)
    }.sorted {
      $0.id.localizedStandardCompare($1.id) == .orderedAscending
    }
  }

  func makeURLRequest(_ request: ProviderRequest, model: String) throws -> URLRequest {
    try makeURLRequest(
      request,
      model: model,
      resolver: ToolNameResolver(definitions: request.tools))
  }

  private func makeURLRequest(
    _ request: ProviderRequest,
    model: String,
    resolver: ToolNameResolver
  ) throws -> URLRequest {
    var body = request.options.additional
    body["model"] = .string(model)
    body["messages"] = .array(
      try request.messages.flatMap { try openAIMessages($0, resolver: resolver) })
    body["stream"] = .bool(request.stream)
    if request.stream {
      body["stream_options"] = .object(["include_usage": .bool(true)])
    }
    if !request.tools.isEmpty {
      body["tools"] = .array(request.tools.map { openAITool($0, resolver: resolver) })
      body["tool_choice"] = openAIToolChoice(request.toolChoice, resolver: resolver)
    }
    if let temperature = request.options.temperature {
      body["temperature"] = .number(temperature)
    }
    if let maxOutputTokens = request.options.maxOutputTokens {
      body["max_tokens"] = .integer(maxOutputTokens)
    }
    if let reasoningEffort = request.options.reasoningEffort,
      !reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      body["reasoning_effort"] = .string(reasoningEffort)
    }
    if let responseFormat = openAIResponseFormat(request.responseFormat) {
      body["response_format"] = responseFormat
    }

    var urlRequest = URLRequest(url: try endpointURL("chat/completions"))
    urlRequest.httpMethod = "POST"
    urlRequest.timeoutInterval = max(1, configuration.requestTimeout)
    urlRequest.httpBody = try JSONEncoder().encode(JSONValue.object(body))
    applyHeaders(to: &urlRequest)
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return urlRequest
  }

  private func applyHeaders(to request: inout URLRequest) {
    for (name, value) in configuration.additionalHeaders {
      request.setValue(value, forHTTPHeaderField: name)
    }
    let key = configuration.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !key.isEmpty {
      request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }
  }

  private func endpointURL(_ endpoint: String) throws -> URL {
    guard
      var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      components.host?.isEmpty == false
    else {
      throw OpenAICompatibleProviderError.invalidBaseURL(configuration.baseURL.absoluteString)
    }

    var path = components.path
    while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
    for suffix in ["/chat/completions", "/models"] where path.hasSuffix(suffix) {
      path.removeLast(suffix.count)
      break
    }
    if path == "/" { path = "" }
    path += "/\(endpoint)"
    components.path = path.hasPrefix("/") ? path : "/\(path)"
    components.query = nil
    components.fragment = nil
    guard let url = components.url else {
      throw OpenAICompatibleProviderError.invalidBaseURL(configuration.baseURL.absoluteString)
    }
    return url
  }

  private func completeOnce(
    _ request: URLRequest,
    resolver: ToolNameResolver,
    emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    let delegate = ProviderRedirectDelegate(originalRequest: request)
    let (data, response) = try await session.data(for: request, delegate: delegate)
    try validate(response: response, data: data)
    let root = try decodeRoot(data)
    if let message = providerError(in: root) {
      throw OpenAICompatibleProviderError.providerFailure(message)
    }
    guard let choice = root["choices"]?.arrayValue?.first?.objectValue else {
      throw OpenAICompatibleProviderError.emptyResponse
    }
    let payload = choice["message"]?.objectValue ?? choice
    let message = try agentMessage(from: payload, resolver: resolver)
    guard
      !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !message.toolCalls.isEmpty
    else {
      throw OpenAICompatibleProviderError.emptyResponse
    }

    if !message.reasoning.isEmpty { await emit(.reasoningDelta(message.reasoning)) }
    if !message.text.isEmpty { await emit(.textDelta(message.text)) }
    for (index, call) in message.toolCalls.enumerated() {
      await emit(
        .toolCallDelta(
          ToolCallDelta(
            index: index,
            id: call.id,
            name: call.name,
            argumentsFragment: call.arguments.compactJSONString)))
    }
    let usage = tokenUsage(root["usage"])
    if let usage { await emit(.usage(usage)) }
    return ProviderResponse(
      message: message,
      usage: usage,
      stopReason: ProviderStopReason(choice["finish_reason"]?.stringValue))
  }

  private func stream(
    _ request: URLRequest,
    resolver: ToolNameResolver,
    emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    let delegate = ProviderRedirectDelegate(originalRequest: request)
    let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
    guard let http = response as? HTTPURLResponse else {
      throw OpenAICompatibleProviderError.invalidResponse(
        "The provider returned a non-HTTP response.")
    }
    guard (200..<300).contains(http.statusCode) else {
      var body = Data()
      for try await byte in bytes {
        guard body.count < 64 * 1_024 else { break }
        body.append(byte)
      }
      throw httpError(statusCode: http.statusCode, data: body)
    }

    var text = ""
    var reasoning = ""
    var usage: TokenUsage?
    var stopReason = ProviderStopReason.unknown
    var toolCalls: [Int: ToolCallAccumulator] = [:]

    for try await line in bytes.lines {
      try Task.checkCancellation()
      guard line.hasPrefix("data:") else { continue }
      let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
      if payload == "[DONE]" { break }
      guard let data = payload.data(using: .utf8) else { continue }
      let root = try decodeRoot(data)
      if let message = providerError(in: root) {
        throw OpenAICompatibleProviderError.providerFailure(message)
      }
      if let value = tokenUsage(root["usage"]) {
        usage = value
        await emit(.usage(value))
      }
      guard let choice = root["choices"]?.arrayValue?.first?.objectValue else { continue }
      let delta = choice["delta"]?.objectValue ?? choice["message"]?.objectValue ?? [:]
      let textDelta = decodedText(delta["content"])
      if !textDelta.isEmpty {
        text += textDelta
        await emit(.textDelta(textDelta))
      }
      let reasoningDelta =
        delta["reasoning_content"]?.stringValue
        ?? delta["reasoning"]?.stringValue ?? ""
      if !reasoningDelta.isEmpty {
        reasoning += reasoningDelta
        await emit(.reasoningDelta(reasoningDelta))
      }
      for rawCall in delta["tool_calls"]?.arrayValue ?? [] {
        guard let object = rawCall.objectValue else { continue }
        let index = object["index"]?.intValue ?? toolCalls.count
        var accumulator = toolCalls[index] ?? ToolCallAccumulator()
        let function = object["function"]?.objectValue ?? [:]
        let id = object["id"]?.stringValue
        let name = function["name"]?.stringValue
        let arguments = function["arguments"]?.stringValue ?? ""
        if let id, !id.isEmpty { accumulator.id = id }
        if let name, !name.isEmpty { accumulator.name += name }
        accumulator.arguments += arguments
        toolCalls[index] = accumulator
        await emit(
          .toolCallDelta(
            ToolCallDelta(
              index: index,
              id: id,
              name: name.flatMap(resolver.canonicalName) ?? name,
              argumentsFragment: arguments)))
      }
      if let value = choice["finish_reason"]?.stringValue {
        stopReason = ProviderStopReason(value)
      }
    }

    let completedCalls = try toolCalls.keys.sorted().compactMap { index -> ToolCall? in
      guard let accumulator = toolCalls[index] else { return nil }
      return try accumulator.toolCall(index: index, resolver: resolver)
    }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !completedCalls.isEmpty
    else {
      throw OpenAICompatibleProviderError.emptyResponse
    }
    var parts: [ContentPart] = []
    if !reasoning.isEmpty { parts.append(.reasoning(reasoning)) }
    if !text.isEmpty { parts.append(.text(text)) }
    parts.append(contentsOf: completedCalls.map(ContentPart.toolCall))
    return ProviderResponse(
      message: AgentMessage(role: .assistant, content: parts),
      usage: usage,
      stopReason: completedCalls.isEmpty ? stopReason : .toolCall)
  }

  private func openAIMessages(
    _ message: AgentMessage,
    resolver: ToolNameResolver
  ) throws -> [JSONValue] {
    if message.role == .tool || !message.toolResults.isEmpty {
      return try message.toolResults.map { result in
        var content = result.content
        if let structured = result.structuredContent {
          content.append(
            .text("<structured_content>\n\(structured.compactJSONString)\n</structured_content>"))
        }
        return .object([
          "role": .string("tool"),
          "tool_call_id": .string(result.callID),
          "content": try openAIContent(content),
        ])
      }
    }

    var object: [String: JSONValue] = ["role": .string(message.role.rawValue)]
    let visibleParts = message.content.filter { part in
      switch part {
      case .reasoning, .toolCall, .toolResult: false
      default: true
      }
    }
    object["content"] = visibleParts.isEmpty ? .null : try openAIContent(visibleParts)
    if !message.reasoning.isEmpty { object["reasoning_content"] = .string(message.reasoning) }
    if !message.toolCalls.isEmpty {
      object["tool_calls"] = .array(
        message.toolCalls.map { call in
          .object([
            "id": .string(call.id),
            "type": .string("function"),
            "function": .object([
              "name": .string(resolver.providerName(for: call.name)),
              "arguments": .string(call.arguments.compactJSONString),
            ]),
          ])
        })
    }
    return [.object(object)]
  }

  private func openAIContent(_ parts: [ContentPart]) throws -> JSONValue {
    if parts.count == 1, case .text(let text) = parts[0] { return .string(text) }
    var values: [JSONValue] = []
    for part in parts {
      switch part {
      case .text(let text):
        values.append(.object(["type": .string("text"), "text": .string(text)]))
      case .reasoning, .toolCall, .toolResult:
        continue
      case .image(let image):
        values.append(
          .object([
            "type": .string("image_url"),
            "image_url": .object([
              "url": .string(try encodedURL(image.source, mimeType: image.mimeType)),
              "detail": .string(image.detail.rawValue),
            ]),
          ]))
      case .audio(let audio):
        guard case .data(let data) = audio.source else {
          throw OpenAICompatibleProviderError.unsupportedContent(
            "OpenAI-compatible audio input requires inline data.")
        }
        let format = audio.mimeType.split(separator: "/").last.map(String.init) ?? "wav"
        values.append(
          .object([
            "type": .string("input_audio"),
            "input_audio": .object([
              "data": .string(data.base64EncodedString()),
              "format": .string(format),
            ]),
          ]))
      case .file(let file):
        if let text = file.text {
          values.append(
            .object([
              "type": .string("text"),
              "text": .string("<file name=\"\(file.name)\">\n\(text)\n</file>"),
            ]))
        } else {
          throw OpenAICompatibleProviderError.unsupportedContent(
            "Binary file '\(file.name)' is not supported by Chat Completions.")
        }
      case .resource(let resource):
        if let text = resource.text {
          values.append(
            .object([
              "type": .string("text"),
              "text": .string("<resource uri=\"\(resource.uri)\">\n\(text)\n</resource>"),
            ]))
        } else {
          throw OpenAICompatibleProviderError.unsupportedContent(
            "Binary resource '\(resource.uri)' is not supported by Chat Completions.")
        }
      }
    }
    return .array(values)
  }

  private func encodedURL(_ source: BinarySource, mimeType: String) throws -> String {
    switch source {
    case .url(let url): return url.absoluteString
    case .data(let data): return "data:\(mimeType);base64,\(data.base64EncodedString())"
    }
  }

  private func openAITool(_ definition: ToolDefinition, resolver: ToolNameResolver) -> JSONValue {
    .object([
      "type": .string("function"),
      "function": .object([
        "name": .string(resolver.providerName(for: definition.name)),
        "description": .string(definition.description),
        "parameters": definition.inputSchema,
      ]),
    ])
  }

  private func openAIToolChoice(_ choice: ToolChoice, resolver: ToolNameResolver) -> JSONValue {
    switch choice {
    case .automatic: .string("auto")
    case .none: .string("none")
    case .required: .string("required")
    case .tool(let name):
      .object([
        "type": .string("function"),
        "function": .object(["name": .string(resolver.providerName(for: name))]),
      ])
    }
  }

  private func openAIResponseFormat(_ format: ResponseFormat) -> JSONValue? {
    switch format {
    case .text: nil
    case .jsonObject: .object(["type": .string("json_object")])
    case .jsonSchema(let name, let schema, let strict):
      .object([
        "type": .string("json_schema"),
        "json_schema": .object([
          "name": .string(name),
          "schema": schema,
          "strict": .bool(strict),
        ]),
      ])
    }
  }

  private func agentMessage(
    from payload: [String: JSONValue],
    resolver: ToolNameResolver
  ) throws -> AgentMessage {
    let text = decodedText(payload["content"] ?? payload["text"])
    let reasoning =
      payload["reasoning_content"]?.stringValue ?? payload["reasoning"]?.stringValue ?? ""
    var parts: [ContentPart] = []
    if !reasoning.isEmpty { parts.append(.reasoning(reasoning)) }
    if !text.isEmpty { parts.append(.text(text)) }
    for (index, raw) in (payload["tool_calls"]?.arrayValue ?? []).enumerated() {
      guard let object = raw.objectValue else { continue }
      let function = object["function"]?.objectValue ?? [:]
      let providerName = function["name"]?.stringValue ?? ""
      let rawArguments = function["arguments"]?.stringValue ?? "{}"
      let arguments = try decodeToolArguments(rawArguments, tool: providerName)
      let call = ToolCall(
        id: object["id"]?.stringValue ?? "call_\(index)",
        name: resolver.canonicalName(for: providerName) ?? providerName,
        arguments: arguments)
      parts.append(.toolCall(call))
    }
    return AgentMessage(role: .assistant, content: parts)
  }

  private func decodedText(_ value: JSONValue?) -> String {
    if let string = value?.stringValue { return string }
    return (value?.arrayValue ?? []).compactMap { part -> String? in
      guard let object = part.objectValue else { return nil }
      return object["text"]?.stringValue
        ?? object["content"]?.stringValue
        ?? object["value"]?.stringValue
    }.joined()
  }

  private func decodeRoot(_ data: Data) throws -> [String: JSONValue] {
    do {
      let root = try JSONDecoder().decode(JSONValue.self, from: data)
      guard let object = root.objectValue else {
        throw OpenAICompatibleProviderError.invalidResponse("Expected a JSON object.")
      }
      return object
    } catch let error as OpenAICompatibleProviderError {
      throw error
    } catch {
      throw OpenAICompatibleProviderError.invalidResponse(
        "The response was not a supported chat-completions payload.")
    }
  }

  private func decodeToolArguments(_ raw: String, tool: String) throws -> JSONValue {
    guard let data = raw.data(using: .utf8),
      let value = try? JSONDecoder().decode(JSONValue.self, from: data),
      value.objectValue != nil
    else {
      throw OpenAICompatibleProviderError.invalidToolArguments(tool: tool, arguments: raw)
    }
    return value
  }

  private func providerError(in root: [String: JSONValue]) -> String? {
    root["error"]?.objectValue?["message"]?.stringValue
  }

  private func tokenUsage(_ value: JSONValue?) -> TokenUsage? {
    guard let usage = value?.objectValue else { return nil }
    let input = usage["prompt_tokens"]?.intValue ?? usage["input_tokens"]?.intValue ?? 0
    let output = usage["completion_tokens"]?.intValue ?? usage["output_tokens"]?.intValue ?? 0
    let promptDetails = usage["prompt_tokens_details"]?.objectValue
    let completionDetails = usage["completion_tokens_details"]?.objectValue
    return TokenUsage(
      inputTokens: input,
      outputTokens: output,
      totalTokens: usage["total_tokens"]?.intValue,
      cachedTokens: promptDetails?["cached_tokens"]?.intValue,
      reasoningTokens: completionDetails?["reasoning_tokens"]?.intValue)
  }

  private func validate(response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else {
      throw OpenAICompatibleProviderError.invalidResponse(
        "The provider returned a non-HTTP response.")
    }
    guard (200..<300).contains(http.statusCode) else {
      throw httpError(statusCode: http.statusCode, data: data)
    }
  }

  private func httpError(statusCode: Int, data: Data) -> OpenAICompatibleProviderError {
    if let root = try? JSONDecoder().decode(JSONValue.self, from: data).objectValue,
      let message = providerError(in: root)
    {
      return .httpError(statusCode: statusCode, message: message)
    }
    let body =
      String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return .httpError(
      statusCode: statusCode,
      message: body.isEmpty ? "Request failed." : String(body.prefix(1_000)))
  }
}

public enum OpenAICompatibleProviderError: LocalizedError, Equatable, Sendable {
  case invalidBaseURL(String)
  case missingModel
  case emptyResponse
  case invalidResponse(String)
  case providerFailure(String)
  case invalidToolArguments(tool: String, arguments: String)
  case unsupportedContent(String)
  case httpError(statusCode: Int, message: String)

  public var errorDescription: String? {
    switch self {
    case .invalidBaseURL(let value):
      "Invalid OpenAI-compatible base URL: \(value)"
    case .missingModel:
      "An OpenAI-compatible model must be selected. Use /model NAME or --model NAME."
    case .emptyResponse:
      "The provider returned an empty response."
    case .invalidResponse(let message), .providerFailure(let message),
      .unsupportedContent(let message):
      message
    case .invalidToolArguments(let tool, let arguments):
      "Provider returned invalid JSON arguments for '\(tool)': \(arguments)"
    case .httpError(let statusCode, let message):
      "Provider returned HTTP \(statusCode): \(message)"
    }
  }
}

private struct ToolCallAccumulator {
  var id = ""
  var name = ""
  var arguments = ""

  func toolCall(index: Int, resolver: ToolNameResolver) throws -> ToolCall {
    let raw = arguments.isEmpty ? "{}" : arguments
    guard let data = raw.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
      decoded.objectValue != nil
    else {
      throw OpenAICompatibleProviderError.invalidToolArguments(tool: name, arguments: raw)
    }
    return ToolCall(
      id: id.isEmpty ? "call_\(index)" : id,
      name: resolver.canonicalName(for: name) ?? name,
      arguments: decoded)
  }
}

extension ProviderStopReason {
  fileprivate init(_ rawValue: String?) {
    switch rawValue {
    case "stop": self = .stop
    case "length", "max_tokens": self = .length
    case "tool_calls", "function_call": self = .toolCall
    case "content_filter": self = .contentFilter
    case "cancelled": self = .cancelled
    default: self = .unknown
    }
  }
}
