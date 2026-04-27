import Foundation
import FoundationModels

struct ChatCompletionRequest: Sendable {
  var conversation: Conversation
  var settings: AppSettings
  var toolContext: String
  var assistantMessageID: UUID
  var nativeTools: [OpenAITool]? = nil
}

enum ChatProviderError: LocalizedError {
  case missingEndpoint
  case invalidEndpoint(String)
  case emptyResponse
  case appleModelUnavailable(String)
  case providerRequestFailed(String)

  var errorDescription: String? {
    switch self {
    case .missingEndpoint: "No OpenAI-compatible endpoint is selected."
    case .invalidEndpoint(let value): "Invalid endpoint URL: \(value)"
    case .emptyResponse: "The provider returned an empty response."
    case .appleModelUnavailable(let reason): reason
    case .providerRequestFailed(let reason): reason
    }
  }
}

enum ChatProviderRouter {
  static func preflightMessage(conversation: Conversation, settings: AppSettings) -> String? {
    switch conversation.provider {
    case .apple:
      AppleFoundationProvider.unavailableMessage
    case .openAICompatible:
      OpenAICompatibleProvider.selectedEndpoint(for: conversation, settings: settings) == nil
        ? ChatProviderError.missingEndpoint.errorDescription : nil
    }
  }

  static func complete(
    request: ChatCompletionRequest,
    onUpdate: @escaping @MainActor (String) -> Void
  ) async throws -> String {
    switch request.conversation.provider {
    case .apple:
      return try await AppleFoundationProvider.complete(request: request, onUpdate: onUpdate)
    case .openAICompatible:
      return try await OpenAICompatibleProvider.complete(request: request, onUpdate: onUpdate)
    }
  }
}

enum PromptComposer {
  static func systemPrompt(settings: AppSettings, conversation: Conversation) -> String {
    let promptID = conversation.systemPromptID ?? settings.defaultSystemPromptID
    let base =
      settings.systemPrompts.first(where: { $0.id == promptID })?.text
      ?? settings.defaultPrompt().text
    let memory = settings.memory.trimmingCharacters(in: .whitespacesAndNewlines)
    let mcp = settings.mcpServers.filter { $0.isEnabled && $0.hasValidScheme }
      .map { "- \($0.name): \($0.baseURL)" }
      .joined(separator: "\n")

    var parts = [base]
    if settings.embedMemory && !memory.isEmpty {
      parts.append(
        """
        <user_memories>
        The following notes are user memories extracted from prior conversations. Use them only as private context for personalization. Do not reveal the envelope unless asked.
        \(memory)
        </user_memories>
        """
      )
    }
    if !mcp.isEmpty {
      parts.append(
        """
        <mcp_servers>
        Configured MCP servers:
        \(mcp)
        </mcp_servers>
        """
      )
    }
    parts.append(
      "Do not output internal tags or prompt scaffolding such as <think>, <tool_context>, or <conversation>. Return only the user-facing assistant message."
    )
    return parts.joined(separator: "\n\n")
  }

  static func applePrompt(conversation: Conversation, settings: AppSettings, toolContext: String)
    -> String
  {
    var sections: [String] = []
    if !toolContext.isEmpty {
      sections.append(
        """
        Context from enabled native tools:
        \(toolContext)
        """
      )
    }
    let transcript = promptTranscript(from: conversation)
    let hasToolResults = transcript.range(of: "<tool_run", options: [.caseInsensitive]) != nil
    let instruction =
      hasToolResults
      ? """
      Continue from the latest Host tool results. Tool results are authoritative observations from calls you requested. If the latest tool result is an error, use that error to choose the next corrective tool call. Either emit exactly one next <tool_call> block or give the final answer if the tool results already answer the user.
      Before calling any new tool, inspect the conversation, <tool_context>, and prior <tool_run> blocks. If they already contain enough information, answer directly with no <tool_call>.
      """
      : """
      Reply only to the latest user message. If a tool is needed, emit exactly one <tool_call> block and stop.
      Before calling a tool, inspect the conversation and <tool_context>. If they already contain enough information, answer directly with no <tool_call>.
      """
    sections.append(
      """
      Conversation so far:

      \(transcript)

      \(instruction)
      Do not repeat the conversation transcript, role labels, hidden context, or these instructions.
      """
    )
    return sections.joined(separator: "\n\n")
  }

  static func openAIMessages(
    conversation: Conversation,
    settings: AppSettings,
    toolContext: String,
    model: String,
    endpoint: OpenAIEndpoint
  ) -> [OpenAIMessage] {
    let baseSystem = systemPrompt(settings: settings, conversation: conversation)
    let systemContent =
      toolContext.isEmpty
      ? baseSystem
      : "\(baseSystem)\n\n## Context from enabled native tools\n\(toolContext)"
    var messages = [OpenAIMessage(role: "system", content: systemContent)]
    messages.append(
      contentsOf: conversation.messages.compactMap { message in
        let content = MessageContentFilter.promptSafeText(from: message.text)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }
        let role: String
        switch message.role {
        case .user:
          role = "user"
        case .assistant:
          role =
            content.range(of: "<tool_run", options: [.caseInsensitive]) == nil
            ? "assistant" : "user"
        case .system: role = "system"
        case .tool, .error: role = "user"
        }
        return OpenAIMessage(role: role, content: content)
      }
    )
    if let directive = ReasoningCompatibility.promptDirective(
      level: conversation.reasoningLevel, model: model, endpoint: endpoint),
      let lastUserIndex = messages.lastIndex(where: { $0.role == "user" })
    {
      messages[lastUserIndex].content += "\n\n\(directive)"
    }
    return messages
  }

  private static func promptTranscript(from conversation: Conversation) -> String {
    let transcript = conversation.messages.compactMap { message -> String? in
      let content = MessageContentFilter.promptSafeText(from: message.text)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !content.isEmpty else { return nil }
      let displayName =
        content.range(of: "<tool_run", options: [.caseInsensitive]) == nil
        ? message.role.displayName : "Host tool results"
      return "\(displayName):\n\(content)"
    }
    .joined(separator: "\n\n")

    return transcript.isEmpty ? "No prior messages." : transcript
  }
}

enum AppleFoundationProvider {
  static var unavailableMessage: String? {
    switch SystemLanguageModel.default.availability {
    case .available:
      return nil
    case .unavailable(let reason):
      return "Apple Foundation Models are unavailable: \(message(for: reason))"
    }
  }

  static var availabilitySummary: String {
    unavailableMessage ?? "Apple Foundation Models are ready."
  }

  static func complete(
    request: ChatCompletionRequest,
    onUpdate: @escaping @MainActor (String) -> Void
  ) async throws -> String {
    if let unavailableMessage {
      throw ChatProviderError.appleModelUnavailable(unavailableMessage)
    }

    let session = LanguageModelSession(
      instructions: PromptComposer.systemPrompt(
        settings: request.settings, conversation: request.conversation)
    )
    let prompt = PromptComposer.applePrompt(
      conversation: request.conversation,
      settings: request.settings,
      toolContext: request.toolContext
    )
    let options = GenerationOptions(maximumResponseTokens: 1_200)

    if request.conversation.usesStreaming {
      var latest = ""
      var lastEmit = Date(timeIntervalSince1970: 0)
      let throttleInterval: TimeInterval = 0.04
      let stream = session.streamResponse(to: prompt, options: options)
      for try await partial in stream {
        latest = partial.content
        let now = Date()
        if now.timeIntervalSince(lastEmit) >= throttleInterval {
          lastEmit = now
          await MainActor.run { onUpdate(latest) }
        }
      }
      await MainActor.run { onUpdate(latest) }
      return latest
    }

    let response = try await session.respond(to: prompt, options: options)
    let content = response.content
    await MainActor.run { onUpdate(content) }
    return content
  }

  private static func message(
    for reason: SystemLanguageModel.Availability.UnavailableReason
  ) -> String {
    switch reason {
    case .deviceNotEligible:
      return
        "this device or simulator is not eligible. Use an iOS 26 device that supports Apple Intelligence, or switch to an OpenAI-compatible endpoint."
    case .appleIntelligenceNotEnabled:
      return
        "Apple Intelligence is not enabled. Enable it in Settings, or switch to an OpenAI-compatible endpoint."
    case .modelNotReady:
      return
        "the local model is not ready yet. Keep the device online until the model finishes downloading, or switch providers."
    @unknown default:
      return "the local model is not available on this device."
    }
  }
}

struct OpenAIMessage: Codable, Sendable {
  var role: String
  var content: String
}

private struct OpenAIChatRequest: Encodable {
  var model: String
  var messages: [OpenAIMessage]
  var stream: Bool
  var tools: [OpenAITool]?
  var reasoningLevel: ReasoningLevel
  var endpoint: OpenAIEndpoint

  enum CodingKeys: String, CodingKey {
    case model
    case messages
    case stream
    case tools
    case reasoningEffort = "reasoning_effort"
    case reasoning
    case thinking
    case enableThinking = "enable_thinking"
    case thinkingBudget = "thinking_budget"
    case chatTemplateKwargs = "chat_template_kwargs"
    case think
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(model, forKey: .model)
    try container.encode(messages, forKey: .messages)
    try container.encode(stream, forKey: .stream)
    try container.encodeIfPresent(tools, forKey: .tools)

    let payload = ReasoningCompatibility.payload(
      level: reasoningLevel, model: model, endpoint: endpoint)
    try container.encodeIfPresent(payload.reasoningEffort, forKey: .reasoningEffort)
    try container.encodeIfPresent(payload.reasoning, forKey: .reasoning)
    try container.encodeIfPresent(payload.thinking, forKey: .thinking)
    try container.encodeIfPresent(payload.enableThinking, forKey: .enableThinking)
    try container.encodeIfPresent(payload.thinkingBudget, forKey: .thinkingBudget)
    try container.encodeIfPresent(payload.chatTemplateKwargs, forKey: .chatTemplateKwargs)
    try container.encodeIfPresent(payload.think, forKey: .think)
  }
}

private struct OpenAIReasoningConfig: Encodable {
  var effort: String?
  var enabled: Bool?
  var exclude: Bool?
}

private struct OpenAIThinkingConfig: Encodable {
  var type: String
}

private struct OpenAIChatTemplateKwargs: Encodable {
  var enableThinking: Bool

  enum CodingKeys: String, CodingKey {
    case enableThinking = "enable_thinking"
  }
}

private enum OpenAIThinkValue: Encodable {
  case bool(Bool)
  case string(String)

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .bool(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    }
  }
}

private struct ReasoningRequestPayload {
  var reasoningEffort: String? = nil
  var reasoning: OpenAIReasoningConfig? = nil
  var thinking: OpenAIThinkingConfig? = nil
  var enableThinking: Bool? = nil
  var thinkingBudget: Int? = nil
  var chatTemplateKwargs: OpenAIChatTemplateKwargs? = nil
  var think: OpenAIThinkValue? = nil
}

private enum ReasoningCompatibility {
  static func payload(
    level: ReasoningLevel, model: String, endpoint: OpenAIEndpoint
  ) -> ReasoningRequestPayload {
    guard level != .automatic else { return ReasoningRequestPayload() }

    switch profile(model: model, endpoint: endpoint) {
    case .openRouter:
      return openRouterPayload(level)
    case .deepSeek:
      return deepSeekPayload(level)
    case .qwen:
      return qwenPayload(level)
    case .ollama:
      return ollamaPayload(level, model: model)
    case .openAI:
      return openAIPayload(level, model: model)
    case .generic:
      return genericPayload(level)
    }
  }

  static func promptDirective(
    level: ReasoningLevel, model: String, endpoint: OpenAIEndpoint
  ) -> String? {
    guard level == .disabled else { return nil }
    let normalized = normalizedText(model, endpoint)
    guard normalized.contains("qwen") else { return nil }
    return "/no_think"
  }

  private enum Profile {
    case openAI
    case openRouter
    case deepSeek
    case qwen
    case ollama
    case generic
  }

  private static func profile(model: String, endpoint: OpenAIEndpoint) -> Profile {
    let text = normalizedText(model, endpoint)
    if text.contains("openrouter.ai") { return .openRouter }
    if text.contains("ollama") || text.contains(":11434") { return .ollama }
    if text.contains("dashscope") || text.contains("aliyuncs") || text.contains("qwen") {
      return .qwen
    }
    if text.contains("deepseek") { return .deepSeek }
    if text.contains("api.openai.com") || text.contains("openai.azure.com") {
      return .openAI
    }
    return .generic
  }

  private static func normalizedText(_ model: String, _ endpoint: OpenAIEndpoint) -> String {
    "\(model) \(endpoint.name) \(endpoint.baseURL)".lowercased()
  }

  private static func openAIPayload(
    _ level: ReasoningLevel, model: String
  ) -> ReasoningRequestPayload {
    guard isKnownOpenAIReasoningModel(model) else { return ReasoningRequestPayload() }
    if level == .disabled && !supportsOpenAINone(model) {
      return ReasoningRequestPayload(reasoningEffort: "low")
    }
    return ReasoningRequestPayload(reasoningEffort: openAIEffort(for: level))
  }

  private static func genericPayload(_ level: ReasoningLevel) -> ReasoningRequestPayload {
    ReasoningRequestPayload(reasoningEffort: openAIEffort(for: level))
  }

  private static func openRouterPayload(_ level: ReasoningLevel) -> ReasoningRequestPayload {
    let disabled = level == .disabled
    return ReasoningRequestPayload(
      reasoning: OpenAIReasoningConfig(
        effort: disabled ? "none" : openAIEffort(for: level),
        enabled: disabled ? false : true,
        exclude: disabled ? true : false
      ))
  }

  private static func deepSeekPayload(_ level: ReasoningLevel) -> ReasoningRequestPayload {
    let disabled = level == .disabled
    return ReasoningRequestPayload(
      reasoningEffort: disabled ? nil : deepSeekEffort(for: level),
      thinking: OpenAIThinkingConfig(type: disabled ? "disabled" : "enabled")
    )
  }

  private static func qwenPayload(_ level: ReasoningLevel) -> ReasoningRequestPayload {
    let enabled = level != .disabled
    return ReasoningRequestPayload(
      enableThinking: enabled,
      thinkingBudget: enabled ? thinkingBudget(for: level) : nil,
      chatTemplateKwargs: OpenAIChatTemplateKwargs(enableThinking: enabled)
    )
  }

  private static func ollamaPayload(
    _ level: ReasoningLevel, model: String
  ) -> ReasoningRequestPayload {
    let text = model.lowercased()
    if text.contains("gpt-oss") {
      let effort = level == .disabled ? "low" : ollamaEffort(for: level)
      return ReasoningRequestPayload(
        reasoningEffort: effort,
        think: .string(effort)
      )
    }
    if level == .disabled {
      return ReasoningRequestPayload(
        reasoningEffort: "none",
        chatTemplateKwargs: OpenAIChatTemplateKwargs(enableThinking: false),
        think: .bool(false)
      )
    }
    return ReasoningRequestPayload(
      reasoningEffort: ollamaEffort(for: level),
      chatTemplateKwargs: OpenAIChatTemplateKwargs(enableThinking: true),
      think: .bool(true)
    )
  }

  private static func openAIEffort(for level: ReasoningLevel) -> String? {
    switch level {
    case .automatic: nil
    case .disabled: "none"
    case .minimal: "minimal"
    case .low: "low"
    case .medium: "medium"
    case .high: "high"
    }
  }

  private static func isKnownOpenAIReasoningModel(_ model: String) -> Bool {
    let text = model.lowercased()
    return text.hasPrefix("o1") || text.hasPrefix("o3") || text.hasPrefix("o4")
      || text.hasPrefix("gpt-5")
  }

  private static func supportsOpenAINone(_ model: String) -> Bool {
    model.lowercased().hasPrefix("gpt-5.1")
  }

  private static func deepSeekEffort(for level: ReasoningLevel) -> String {
    switch level {
    case .automatic, .disabled: "high"
    case .minimal, .low, .medium: "high"
    case .high: "high"
    }
  }

  private static func ollamaEffort(for level: ReasoningLevel) -> String {
    switch level {
    case .automatic, .medium: "medium"
    case .disabled, .minimal, .low: "low"
    case .high: "high"
    }
  }

  private static func thinkingBudget(for level: ReasoningLevel) -> Int? {
    switch level {
    case .automatic, .disabled:
      nil
    case .minimal:
      256
    case .low:
      1024
    case .medium:
      4096
    case .high:
      8192
    }
  }
}

struct OpenAITool: Encodable, Sendable {
  var type: String = "function"
  var function: OpenAIFunctionSpec
}

struct OpenAIFunctionSpec: Encodable, Sendable {
  var name: String
  var description: String
  var parameters: OpenAIFunctionSchema
}

struct OpenAIFunctionSchema: Encodable, Sendable {
  var type: String = "object"
  var properties: [String: OpenAIPropertySpec]
  var required: [String]
}

struct OpenAIPropertySpec: Encodable, Sendable {
  var type: String
  var description: String
}

private struct OpenAIChatResponse: Decodable {
  struct Choice: Decodable {
    var message: OpenAIChoicePayload?
    var text: String?
  }

  var choices: [Choice]
  var outputText: String?

  enum CodingKeys: String, CodingKey {
    case choices
    case outputText = "output_text"
  }
}

struct OpenAIToolCall: Decodable, Sendable {
  struct Function: Decodable, Sendable {
    var name: String?
    var arguments: String?
  }
  var id: String?
  var type: String?
  var function: Function?
}

private struct OpenAIStreamChunk: Decodable {
  struct Choice: Decodable {
    struct Delta: Decodable {
      var content: OpenAIContent?
      var reasoningContent: String?
      var toolCalls: [DeltaToolCall]?

      enum CodingKeys: String, CodingKey {
        case content
        case reasoningContent = "reasoning_content"
        case reasoning
        case toolCalls = "tool_calls"
      }

      init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = try? c.decode(OpenAIContent.self, forKey: .content)
        reasoningContent =
          (try? c.decode(String.self, forKey: .reasoningContent))
          ?? (try? c.decode(String.self, forKey: .reasoning))
        toolCalls = try? c.decode([DeltaToolCall].self, forKey: .toolCalls)
      }
    }

    var delta: Delta?
    var message: OpenAIChoicePayload?
    var text: String?
  }

  var choices: [Choice]
}

struct DeltaToolCall: Decodable, Sendable {
  struct Function: Decodable, Sendable {
    var name: String?
    var arguments: String?
  }
  var index: Int?
  var id: String?
  var type: String?
  var function: Function?
}

private struct OpenAIChoicePayload: Decodable {
  var content: OpenAIContent?
  var reasoningContent: String?
  var toolCalls: [OpenAIToolCall]?

  enum CodingKeys: String, CodingKey {
    case content
    case reasoningContent = "reasoning_content"
    case reasoning
    case toolCalls = "tool_calls"
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    content = try? c.decode(OpenAIContent.self, forKey: .content)
    reasoningContent =
      (try? c.decode(String.self, forKey: .reasoningContent))
      ?? (try? c.decode(String.self, forKey: .reasoning))
    toolCalls = try? c.decode([OpenAIToolCall].self, forKey: .toolCalls)
  }
}

private struct OpenAIContent: Decodable {
  struct Part: Decodable {
    var text: String?
    var content: String?
  }

  var text: String

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      text = ""
    } else if let string = try? container.decode(String.self) {
      text = string
    } else if let parts = try? container.decode([Part].self) {
      text = parts.compactMap { $0.text ?? $0.content }.joined(separator: "\n")
    } else {
      text = ""
    }
  }
}

private struct OpenAIErrorResponse: Decodable {
  struct APIError: Decodable {
    var message: String?
    var type: String?
    var code: String?
  }

  var error: APIError
}

private struct OpenAIModelsResponse: Decodable {
  struct Model: Decodable {
    var id: String
  }

  var data: [Model]
}

enum OpenAICompatibleProvider {
  static func fetchModels(endpoint: OpenAIEndpoint) async throws -> [String] {
    let url = try modelsURL(from: endpoint.baseURL)
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "GET"
    let trimmedKey = endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let authorization = trimmedKey.isEmpty ? nil : "Bearer \(trimmedKey)"
    if let authorization {
      urlRequest.setValue(authorization, forHTTPHeaderField: "Authorization")
    }

    let delegate = RedirectPreservingDelegate(
      authorization: authorization, originalRequest: urlRequest)
    let (data, response) = try await URLSession.shared.data(
      for: urlRequest, delegate: delegate)
    if let statusCode = (response as? HTTPURLResponse)?.statusCode,
      !(200..<300).contains(statusCode)
    {
      throw ChatProviderError.providerRequestFailed("Model list returned HTTP \(statusCode).")
    }
    let decoded = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
    let models = decoded.data
      .map(\.id)
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .sorted()
    if models.isEmpty {
      throw ChatProviderError.providerRequestFailed("The endpoint returned no models.")
    }
    return models
  }

  static func complete(
    request: ChatCompletionRequest,
    onUpdate: @escaping @MainActor (String) -> Void
  ) async throws -> String {
    guard let endpoint = selectedEndpoint(for: request) else {
      throw ChatProviderError.missingEndpoint
    }
    let url = try chatCompletionsURL(from: endpoint.baseURL)
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let trimmedKey = endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let authorization = trimmedKey.isEmpty ? nil : "Bearer \(trimmedKey)"
    if let authorization {
      urlRequest.setValue(authorization, forHTTPHeaderField: "Authorization")
    }
    let model =
      request.conversation.modelID.isEmpty ? endpoint.defaultModel : request.conversation.modelID
    urlRequest.httpBody = try JSONEncoder().encode(
      OpenAIChatRequest(
        model: model,
        messages: PromptComposer.openAIMessages(
          conversation: request.conversation,
          settings: request.settings,
          toolContext: request.toolContext,
          model: model,
          endpoint: endpoint
        ),
        stream: request.conversation.usesStreaming,
        tools: request.nativeTools,
        reasoningLevel: request.conversation.reasoningLevel,
        endpoint: endpoint
      )
    )

    if request.conversation.usesStreaming {
      return try await stream(
        request: urlRequest, authorization: authorization, onUpdate: onUpdate)
    }
    return try await completeOnce(
      request: urlRequest, authorization: authorization, onUpdate: onUpdate)
  }

  static func selectedEndpoint(for conversation: Conversation, settings: AppSettings)
    -> OpenAIEndpoint?
  {
    let id = conversation.endpointID ?? settings.selectedEndpointID
    if let id,
      let endpoint = settings.openAIEndpoints.first(where: { $0.id == id && $0.isEnabled })
    {
      return endpoint
    }
    return settings.openAIEndpoints.first(where: { $0.isEnabled })
  }

  private static func selectedEndpoint(for request: ChatCompletionRequest) -> OpenAIEndpoint? {
    selectedEndpoint(for: request.conversation, settings: request.settings)
  }

  private static func modelsURL(from baseURL: String) throws -> URL {
    guard var components = URLComponents(string: baseURL),
      ["http", "https"].contains(components.scheme?.lowercased() ?? "")
    else {
      throw ChatProviderError.invalidEndpoint(baseURL)
    }

    var pathComponents = components.path.split(separator: "/").map(String.init)
    if pathComponents.count >= 2,
      pathComponents[pathComponents.count - 2] == "chat",
      pathComponents[pathComponents.count - 1] == "completions"
    {
      pathComponents.removeLast(2)
    }
    if pathComponents.last != "models" {
      pathComponents.append("models")
    }
    components.path = "/" + pathComponents.joined(separator: "/")
    components.query = nil

    guard let url = components.url else {
      throw ChatProviderError.invalidEndpoint(baseURL)
    }
    return url
  }

  private static func chatCompletionsURL(from baseURL: String) throws -> URL {
    guard var components = URLComponents(string: baseURL) else {
      throw ChatProviderError.invalidEndpoint(baseURL)
    }
    let path = components.path
    if !path.hasSuffix("/chat/completions") {
      components.path =
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions"
      if !components.path.hasPrefix("/") {
        components.path = "/" + components.path
      }
    }
    guard let url = components.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    else {
      throw ChatProviderError.invalidEndpoint(baseURL)
    }
    return url
  }

  private static func completeOnce(
    request: URLRequest,
    authorization: String?,
    onUpdate: @escaping @MainActor (String) -> Void
  ) async throws -> String {
    let delegate = RedirectPreservingDelegate(
      authorization: authorization, originalRequest: request)
    let (data, response) = try await URLSession.shared.data(for: request, delegate: delegate)
    try validateHTTPResponse(response, data: data)
    let content = (try? decodeChatResponseText(from: data)) ?? ""
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw emptyResponseError(rawData: data)
    }
    await MainActor.run { onUpdate(content) }
    return content
  }

  private static func stream(
    request: URLRequest,
    authorization: String?,
    onUpdate: @escaping @MainActor (String) -> Void
  ) async throws -> String {
    let delegate = RedirectPreservingDelegate(
      authorization: authorization, originalRequest: request)
    let (bytes, response) = try await URLSession.shared.bytes(for: request, delegate: delegate)
    let statusCode = (response as? HTTPURLResponse)?.statusCode
    var accumulated = ""
    var reasoning = ""
    var rawLines: [String] = []
    var streamTrace: [String] = []
    let traceCap = 80
    var lastEmit = Date(timeIntervalSince1970: 0)
    let throttleInterval: TimeInterval = 0.04
    var dirty = false
    var toolCallAcc: [Int: (id: String?, name: String?, args: String)] = [:]
    var fullMessageToolCalls: [OpenAIToolCall] = []
    for try await line in bytes.lines {
      if streamTrace.count < traceCap {
        streamTrace.append(line)
      }
      if let statusCode, !(200..<300).contains(statusCode) {
        appendRawLine(line, to: &rawLines)
        continue
      }
      guard line.hasPrefix("data:") else {
        appendRawLine(line, to: &rawLines)
        continue
      }
      let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
      if payload == "[DONE]" { break }
      guard let data = payload.data(using: .utf8) else { continue }

      if let errorPayload = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data),
        let message = errorPayload.error.message?
          .trimmingCharacters(in: .whitespacesAndNewlines),
        !message.isEmpty
      {
        let type = errorPayload.error.type.map { " (\($0))" } ?? ""
        throw ChatProviderError.providerRequestFailed("\(message)\(type)")
      }

      guard let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data) else {
        appendRawLine(line, to: &rawLines)
        continue
      }
      if let delta = streamDeltaText(from: chunk), !delta.isEmpty {
        accumulated += delta
        dirty = true
      }
      if let reasoningDelta = streamReasoningText(from: chunk), !reasoningDelta.isEmpty {
        reasoning += reasoningDelta
        dirty = true
      }
      if let deltas = chunk.choices.first?.delta?.toolCalls {
        for tc in deltas {
          let idx = tc.index ?? 0
          var entry = toolCallAcc[idx] ?? (nil, nil, "")
          if let id = tc.id { entry.id = id }
          if let name = tc.function?.name { entry.name = name }
          if let a = tc.function?.arguments { entry.args += a }
          toolCallAcc[idx] = entry
        }
      }
      if let messageCalls = chunk.choices.first?.message?.toolCalls {
        fullMessageToolCalls = messageCalls
      }
      if dirty {
        let now = Date()
        if now.timeIntervalSince(lastEmit) >= throttleInterval {
          lastEmit = now
          dirty = false
          let snapshot = responseText(content: accumulated, reasoning: reasoning)
          await MainActor.run { onUpdate(snapshot) }
        }
      }
    }
    let toolCallText =
      fullMessageToolCalls.isEmpty
      ? joinedToolCallBlocks(AgentTooling.nativeToolCalls(from: toolCallAcc).map(\.textBlock))
      : synthesizeToolCallBlocks(from: fullMessageToolCalls)
    if !toolCallText.isEmpty {
      accumulated =
        accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? toolCallText
        : "\(accumulated)\n\n\(toolCallText)"
      dirty = true
    }

    if dirty {
      let snapshot = responseText(content: accumulated, reasoning: reasoning)
      await MainActor.run { onUpdate(snapshot) }
    }

    let rawBody = rawLines.joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let statusCode, !(200..<300).contains(statusCode) {
      throw providerHTTPError(statusCode: statusCode, data: rawBody.data(using: .utf8) ?? Data())
    }
    if accumulated.isEmpty, !rawBody.isEmpty,
      let data = rawBody.data(using: .utf8),
      let fallback = try? decodeChatResponseText(from: data),
      !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      await MainActor.run { onUpdate(fallback) }
      return fallback
    }
    let content = responseText(content: accumulated, reasoning: reasoning)
    if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let trace = streamTrace.suffix(40).joined(separator: "\n")
      throw emptyResponseError(streamTrace: trace, rawBody: rawBody)
    }
    return content
  }

  private static func emptyResponseError(rawData: Data) -> ChatProviderError {
    let body =
      String(data: rawData, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if body.isEmpty {
      return .emptyResponse
    }
    let snippet = body.count > 800 ? String(body.prefix(800)) + "…" : body
    return .providerRequestFailed(
      "Provider returned no readable text. Raw response:\n\(snippet)")
  }

  private static func emptyResponseError(streamTrace: String, rawBody: String)
    -> ChatProviderError
  {
    let stoppedEmpty =
      streamTrace.contains("\"finish_reason\":\"stop\"")
      && streamTrace.contains("\"content\":\"\"")
      && !streamTrace.contains("\"tool_calls\"")
    var pieces: [String] = []
    if stoppedEmpty {
      pieces.append(
        "The model stopped without producing any text or tool calls. If you're using Native tool calling, the server may not fully support it for this model — switch Settings → MCP Servers → Tool Calling to Text protocol and try again."
      )
    }
    if !streamTrace.isEmpty {
      let trimmed =
        streamTrace.count > 1200 ? String(streamTrace.prefix(1200)) + "…" : streamTrace
      pieces.append("Last stream lines:\n\(trimmed)")
    }
    if !rawBody.isEmpty {
      let trimmed = rawBody.count > 600 ? String(rawBody.prefix(600)) + "…" : rawBody
      pieces.append("Non-data lines:\n\(trimmed)")
    }
    if pieces.isEmpty {
      return .emptyResponse
    }
    return .providerRequestFailed(pieces.joined(separator: "\n\n"))
  }

  private static func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
    guard let statusCode = (response as? HTTPURLResponse)?.statusCode,
      !(200..<300).contains(statusCode)
    else {
      return
    }
    throw providerHTTPError(statusCode: statusCode, data: data)
  }

  private static func providerHTTPError(statusCode: Int, data: Data) -> ChatProviderError {
    if let error = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
      let message = error.error.message ?? "Request failed"
      let type = error.error.type.map { " (\($0))" } ?? ""
      return .providerRequestFailed("Provider returned HTTP \(statusCode): \(message)\(type)")
    }
    let body =
      String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if body.isEmpty {
      return .providerRequestFailed("Provider returned HTTP \(statusCode).")
    }
    return .providerRequestFailed(
      "Provider returned HTTP \(statusCode): \(String(body.prefix(500)))")
  }

  private static func decodeChatResponseText(from data: Data) throws -> String {
    let response = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
    let choice = response.choices.first
    let baseContent =
      choice?.message?.content?.text
      ?? choice?.text
      ?? response.outputText
      ?? ""
    let reasoning = choice?.message?.reasoningContent ?? ""
    let toolCallText = synthesizeToolCallBlocks(from: choice?.message?.toolCalls)
    let combined: String
    if toolCallText.isEmpty {
      combined = baseContent
    } else if baseContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      combined = toolCallText
    } else {
      combined = "\(baseContent)\n\n\(toolCallText)"
    }
    return responseText(content: combined, reasoning: reasoning)
  }

  static func synthesizeToolCallBlocks(from calls: [OpenAIToolCall]?) -> String {
    guard let calls, !calls.isEmpty else { return "" }
    return joinedToolCallBlocks(
      calls.compactMap { call -> String? in
        guard let name = call.function?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
          !name.isEmpty
        else { return nil }
        return AgentTooling.makeNativeToolCall(
          id: call.id, name: name, rawArguments: call.function?.arguments ?? ""
        ).textBlock
      })
  }

  private static func joinedToolCallBlocks(_ blocks: [String]) -> String {
    blocks.filter { !$0.isEmpty }.joined(separator: "\n")
  }

  private static func streamDeltaText(from chunk: OpenAIStreamChunk) -> String? {
    let choice = chunk.choices.first
    return choice?.delta?.content?.text
      ?? choice?.message?.content?.text
      ?? choice?.text
  }

  private static func streamReasoningText(from chunk: OpenAIStreamChunk) -> String? {
    let choice = chunk.choices.first
    return choice?.delta?.reasoningContent ?? choice?.message?.reasoningContent
  }

  private static func responseText(content: String, reasoning: String) -> String {
    let visible = content.trimmingCharacters(in: .whitespacesAndNewlines)
    let hidden = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
    if hidden.isEmpty {
      return visible
    }
    if visible.isEmpty {
      return "<think>\n\(hidden)\n</think>"
    }
    return "<think>\n\(hidden)\n</think>\n\n\(visible)"
  }

  private static func appendRawLine(_ line: String, to rawLines: inout [String]) {
    guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    if rawLines.joined(separator: "\n").count < 32_000 {
      rawLines.append(line)
    }
  }
}

final class RedirectPreservingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  private let authorization: String?
  private let method: String
  private let body: Data?
  private let contentType: String?

  init(authorization: String?, originalRequest: URLRequest) {
    self.authorization = authorization
    self.method = originalRequest.httpMethod ?? "GET"
    self.body = originalRequest.httpBody
    self.contentType = originalRequest.value(forHTTPHeaderField: "Content-Type")
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    var modified = request
    modified.httpMethod = method
    if let body, modified.httpBody == nil {
      modified.httpBody = body
    }
    if let contentType, modified.value(forHTTPHeaderField: "Content-Type") == nil {
      modified.setValue(contentType, forHTTPHeaderField: "Content-Type")
    }
    if let authorization, modified.value(forHTTPHeaderField: "Authorization") == nil {
      modified.setValue(authorization, forHTTPHeaderField: "Authorization")
    }
    return modified
  }
}
