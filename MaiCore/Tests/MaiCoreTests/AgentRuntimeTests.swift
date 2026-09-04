import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import MaiCore
@testable import MaiMCP
@testable import MaiOpenAI

@Test("Image attachment modes resize images and preserve their metadata")
func imageAttachmentResize() async throws {
  let original = try pngData(width: 200, height: 100)
  let part = try await ImageAttachmentImporter.content(
    data: original,
    mimeType: "image/png",
    filename: "fixture.png",
    mode: .tiny)

  guard case .image(let image) = part else {
    Issue.record("Expected resized image content")
    return
  }
  #expect(image.mimeType == "image/jpeg")
  #expect(image.name == "fixture.jpg")
  #expect(image.width == 100)
  #expect(image.height == 50)
  guard case .data(let resized) = image.source else {
    Issue.record("Expected inline resized image data")
    return
  }
  #expect(resized != original)
}

@Test("OCR image mode delegates to a separate provider and returns a Markdown file")
func imageAttachmentOCR() async throws {
  let part = try await ImageAttachmentImporter.content(
    data: Data([0x01, 0x02]),
    mimeType: "image/jpeg",
    filename: "receipt.jpg",
    mode: .ocr,
    ocrProvider: FixtureOCRProvider())

  guard case .file(let file) = part else {
    Issue.record("Expected OCR Markdown file content")
    return
  }
  #expect(file.name == "receipt.md")
  #expect(file.mimeType == "text/markdown")
  #expect(file.text == "# Recognized\n\nHello from OCR")

  await #expect(throws: ImageAttachmentImportError.ocrProviderRequired) {
    try await ImageAttachmentImporter.content(
      data: Data([0x01]),
      mimeType: "image/jpeg",
      filename: "missing.jpg",
      mode: .ocr)
  }
}

@Test("Structured messages preserve multimodal and tool content")
func structuredMessageRoundTrip() throws {
  let message = AgentMessage(
    id: "message-1",
    role: .user,
    content: [
      .text("inspect"),
      .image(
        ImageContent(
          source: .data(Data([0x01, 0x02])),
          mimeType: "image/png",
          name: "sample.png")),
      .file(FileContent(name: "notes.txt", mimeType: "text/plain", text: "notes")),
      .toolResult(ToolResult(callID: "call-1", text: "done")),
    ])

  let data = try JSONEncoder().encode(message)
  #expect(try JSONDecoder().decode(AgentMessage.self, from: data) == message)
}

@Test("Transcripts edit rich messages and preserve valid tool transactions")
func transcriptEditing() throws {
  let messages = [
    AgentMessage(id: "system", role: .system, content: "Rules"),
    AgentMessage(
      id: "user",
      role: .user,
      content: [
        .text("original"),
        .image(ImageContent(source: .data(Data([0x01])), mimeType: "image/png")),
      ]),
    AgentMessage(
      id: "calls",
      role: .assistant,
      content: [
        .toolCall(ToolCall(id: "call-a", name: "a", arguments: .object([:]))),
        .toolCall(ToolCall(id: "call-b", name: "b", arguments: .object([:]))),
      ]),
    AgentMessage(
      id: "result-a",
      role: .tool,
      content: [.toolResult(ToolResult(callID: "call-a", text: "A"))]),
    AgentMessage(
      id: "result-b",
      role: .tool,
      content: [.toolResult(ToolResult(callID: "call-b", text: "B"))]),
    AgentMessage(id: "answer", role: .assistant, content: "Done"),
  ]
  var transcript = AgentTranscript(messages: messages)

  let previous = try transcript.editMessage(id: "user", text: "revised")
  #expect(previous.text == "original")
  #expect(transcript[1].text == "revised")
  #expect(transcript[1].content.contains { if case .image = $0 { true } else { false } })

  try transcript.editMessage(id: "result-a", text: "Edited tool result")
  #expect(transcript[3].toolResults.first?.text == "Edited tool result")

  let removed = try transcript.removeMessage(id: "result-a")
  #expect(Set(removed.map(\.id)) == ["calls", "result-a", "result-b"])
  #expect(transcript.messages.map(\.id) == ["system", "user", "answer"])

  let trimmed = try transcript.trim(throughMessageID: "user")
  #expect(trimmed.map(\.id) == ["answer"])
  #expect(transcript.messages.map(\.id) == ["system", "user"])
}

@Test("Trimming through an incomplete tool call removes the entire transaction")
func transcriptTrimToolBoundary() throws {
  var transcript = AgentTranscript(messages: [
    .user("question"),
    AgentMessage(
      id: "calls",
      role: .assistant,
      content: [.toolCall(ToolCall(id: "call", name: "lookup", arguments: .object([:])))]),
    AgentMessage(
      role: .tool,
      content: [.toolResult(ToolResult(callID: "call", text: "result"))]),
    .assistant("answer"),
  ])

  let removed = try transcript.trim(through: 1)
  #expect(removed.map(\.id).contains("calls"))
  #expect(transcript.messages.map(\.role) == [.user])
}

@Test("A registered provider runs through MaiCore and emits lifecycle events")
func registeredProviderRun() async throws {
  let runtime = AgentRuntime()
  try await runtime.register(HelloProvider())
  let recorder = EventRecorder()

  let result = try await runtime.run(
    AgentRequest(provider: .hello, messages: [.user("world")])
  ) { event in
    await recorder.append(event)
  }

  #expect(result.response.text == "Hello from MaiCore: world")
  #expect(result.stopReason == .stop)
  #expect(result.transcript.count == 2)
  let events = await recorder.events
  #expect(events.count == 4)
  guard case .started(let context, let descriptor) = events[0] else {
    Issue.record("Expected started event")
    return
  }
  #expect(descriptor == HelloProvider().descriptor)
  #expect(events[1] == .modelStarted(context, turn: 1))
  #expect(events[2] == .provider(context, .textDelta("Hello from MaiCore: world")))
  #expect(events[3] == .finished(context, result))
}

@Test("Provider registration rejects duplicates and permits explicit replacement")
func providerRegistration() async throws {
  let runtime = AgentRuntime()
  try await runtime.register(HelloProvider())
  await #expect(throws: AgentRuntimeError.providerAlreadyRegistered(.hello)) {
    try await runtime.register(HelloProvider(prefix: "Replacement"))
  }
  try await runtime.register(
    HelloProvider(prefix: "Replacement"),
    replacingExisting: true)
  let result = try await runtime.run(
    AgentRequest(provider: .hello, messages: [.user("works")]))
  #expect(result.response.text == "Replacement: works")
}

@Test("OpenAI-compatible provider encodes multimodal native-tool requests")
func openAIChatCompletion() async throws {
  let recorder = URLRequestRecorder()
  StubURLProtocol.install(forHost: "completion.example.test") { request in
    recorder.record(request, body: try requestBodyData(request))
    return try httpResponse(
      request,
      contentType: "application/json",
      body: """
        {
          "choices": [{
            "message": {
              "content": null,
              "reasoning_content": "need weather",
              "tool_calls": [{
                "id": "call-1",
                "type": "function",
                "function": {"name": "weather_get", "arguments": "{\\"city\\":\\"Barcelona\\"}"}
              }]
            },
            "finish_reason": "tool_calls"
          }],
          "usage": {
            "prompt_tokens": 4,
            "completion_tokens": 3,
            "total_tokens": 7,
            "prompt_tokens_details": {"cached_tokens": 1},
            "completion_tokens_details": {"reasoning_tokens": 2}
          }
        }
        """)
  }
  defer { StubURLProtocol.reset(host: "completion.example.test") }

  let provider = OpenAICompatibleProvider(
    configuration: .init(
      baseURL: try #require(URL(string: "https://completion.example.test/v1/")),
      apiKey: "secret"),
    session: stubSession())
  #expect(provider.descriptor.capabilities.contains(.nativeToolCalling))
  #expect(provider.descriptor.capabilities.contains(.imageInput))
  let events = ProviderEventRecorder()
  let weather = ToolDefinition(
    name: "weather::get",
    providerName: "weather_get",
    description: "Get weather",
    inputSchema: objectSchema(required: ["city"]))

  let response = try await provider.complete(
    ProviderRequest(
      model: "test-model",
      messages: [
        AgentMessage(
          role: .user,
          content: [
            .text("weather?"),
            .image(
              ImageContent(
                source: .data(Data([0x89, 0x50])),
                mimeType: "image/png")),
          ])
      ],
      tools: [weather],
      responseFormat: .jsonSchema(
        name: "answer",
        schema: objectSchema(required: ["answer"]),
        strict: true),
      stream: false)
  ) { event in
    await events.append(event)
  }

  #expect(response.message.reasoning == "need weather")
  #expect(response.message.toolCalls.first?.name == "weather::get")
  #expect(response.message.toolCalls.first?.arguments == .object(["city": .string("Barcelona")]))
  #expect(response.stopReason == .toolCall)
  #expect(response.usage?.cachedTokens == 1)
  #expect(response.usage?.reasoningTokens == 2)

  let request = try #require(recorder.request)
  #expect(request.url?.absoluteString == "https://completion.example.test/v1/chat/completions")
  #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
  let body = try jsonObject(try #require(recorder.body))
  let messages = try #require(body["messages"] as? [[String: Any]])
  let parts = try #require(messages.first?["content"] as? [[String: Any]])
  #expect(parts.contains { $0["type"] as? String == "image_url" })
  let tools = try #require(body["tools"] as? [[String: Any]])
  let function = try #require(tools.first?["function"] as? [String: Any])
  #expect(function["name"] as? String == "weather_get")
  #expect((body["response_format"] as? [String: Any])?["type"] as? String == "json_schema")
}

@Test("OpenAI-compatible provider lists its model catalog")
func openAIModelCatalog() async throws {
  let recorder = URLRequestRecorder()
  StubURLProtocol.install(forHost: "models.example.test") { request in
    recorder.record(request, body: Data())
    return try httpResponse(
      request,
      contentType: "application/json",
      body: """
        {
          "object": "list",
          "data": [
            {"id":"model-z","owned_by":"vendor"},
            {
              "id":"model-a",
              "name":"Model A",
              "architecture":{"input_modalities":["text","image","audio"]}
            }
          ]
        }
        """)
  }
  defer { StubURLProtocol.reset(host: "models.example.test") }

  let provider = OpenAICompatibleProvider(
    configuration: .init(
      baseURL: try #require(URL(string: "https://models.example.test/v1/chat/completions")),
      apiKey: "secret",
      additionalHeaders: ["X-Workspace": "test"]),
    session: stubSession())
  let models = try await provider.availableModels()

  #expect(models.map(\.id) == ["model-a", "model-z"])
  #expect(models.first?.displayName == "Model A")
  #expect(models.first?.inputModalities == ["text", "image", "audio"])
  #expect(models.first?.capabilities.contains(.imageInput) == true)
  #expect(models.first?.capabilities.contains(.audioInput) == true)
  #expect(models.last?.ownedBy == "vendor")
  let request = try #require(recorder.request)
  #expect(request.httpMethod == "GET")
  #expect(request.url?.absoluteString == "https://models.example.test/v1/models")
  #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
  #expect(request.value(forHTTPHeaderField: "X-Workspace") == "test")
}

@Test("Streaming requests accept providers that return one-shot JSON")
func openAIStreamingJSONFallback() async throws {
  StubURLProtocol.install(forHost: "buffered.example.test") { request in
    try httpResponse(
      request,
      contentType: "application/json",
      body: """
        {
          "choices": [{
            "message": {"content": "buffered response"},
            "finish_reason": "stop"
          }],
          "usage": {"prompt_tokens": 2, "completion_tokens": 3}
        }
        """)
  }
  defer { StubURLProtocol.reset(host: "buffered.example.test") }

  let provider = OpenAICompatibleProvider(
    configuration: .init(
      baseURL: try #require(URL(string: "https://buffered.example.test/v1"))),
    session: stubSession())
  let response = try await provider.complete(
    ProviderRequest(
      model: "test-model",
      messages: [.user("hello")],
      stream: true))

  #expect(response.message.text == "buffered response")
  #expect(response.usage == TokenUsage(inputTokens: 2, outputTokens: 3))
  #expect(response.stopReason == .stop)
}

@Test("OpenAI-compatible provider accumulates streamed tool-call fragments")
func openAIStreamingToolCall() async throws {
  StubURLProtocol.install(forHost: "stream.example.test") { request in
    try httpResponse(
      request,
      contentType: "text/event-stream",
      body: """
        data: {"choices":[{"delta":{"reasoning_content":"checking "}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-2","function":{"name":"echo","arguments":"{\\"text\\":"}}]}}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"hello\\"}"}}]},"finish_reason":"tool_calls"}]}

        data: {"choices":[],"usage":{"prompt_tokens":2,"completion_tokens":2,"total_tokens":4}}

        data: [DONE]

        """)
  }
  defer { StubURLProtocol.reset(host: "stream.example.test") }

  let provider = OpenAICompatibleProvider(
    configuration: .init(
      baseURL: try #require(URL(string: "https://stream.example.test/v1"))),
    session: stubSession())
  let response = try await provider.complete(
    ProviderRequest(
      model: "test-model",
      messages: [.user("echo hello")],
      tools: [ToolDefinition(name: "echo", description: "Echo")],
      stream: true))

  #expect(response.message.reasoning == "checking ")
  #expect(
    response.message.toolCalls == [
      ToolCall(id: "call-2", name: "echo", arguments: .object(["text": .string("hello")]))
    ])
  #expect(response.usage == TokenUsage(inputTokens: 2, outputTokens: 2, totalTokens: 4))
  #expect(response.stopReason == .toolCall)
}

@Test("Agent runtime validates, approves, executes, and continues after a tool call")
func toolLoop() async throws {
  let provider = ScriptedProvider(responses: [
    ProviderResponse(
      message: AgentMessage(
        role: .assistant,
        content: [
          .toolCall(
            ToolCall(
              id: "call-1",
              name: "uppercase",
              arguments: .object(["text": .string("hello")])))
        ]),
      stopReason: .toolCall),
    ProviderResponse(message: .assistant("The result is HELLO."), stopReason: .stop),
  ])
  let approval = QueueApprovalHandler(decisions: [
    .approve(arguments: .object(["text": .string("changed")]))
  ])
  let observedArguments = JSONValueRecorder()
  let runtime = AgentRuntime(approvalHandler: approval)
  try await runtime.register(provider)
  try await runtime.register(
    tool: ClosureTool(
      definition: ToolDefinition(
        name: "uppercase",
        description: "Uppercase text",
        inputSchema: objectSchema(required: ["text"]),
        annotations: ToolAnnotations(approval: .confirm))
    ) { arguments, _ in
      await observedArguments.record(arguments)
      return ToolOutput(text: arguments.objectValue?["text"]?.stringValue?.uppercased() ?? "")
    })

  let result = try await runtime.run(
    AgentRequest(
      provider: "scripted",
      model: "fixture",
      messages: [.user("uppercase hello")],
      toolNames: ["uppercase"]))

  #expect(result.response.text == "The result is HELLO.")
  #expect(result.modelTurns == 2)
  #expect(result.toolCalls == 1)
  #expect(await observedArguments.value == .object(["text": .string("changed")]))
  #expect(result.transcript.flatMap(\.toolResults).first?.text == "CHANGED")
}

@Test("Denied approvals become tool results without executing the tool")
func deniedApproval() async throws {
  let provider = ScriptedProvider(responses: [
    ProviderResponse(
      message: AgentMessage(
        role: .assistant,
        content: [.toolCall(ToolCall(id: "c", name: "sensitive", arguments: .object([:])))]),
      stopReason: .toolCall),
    ProviderResponse(message: .assistant("Denied."), stopReason: .stop),
  ])
  let runtime = AgentRuntime(
    approvalHandler: QueueApprovalHandler(decisions: [.deny(reason: "test policy")]))
  try await runtime.register(provider)
  try await runtime.register(
    tool: ClosureTool(
      definition: ToolDefinition(
        name: "sensitive",
        description: "Sensitive",
        annotations: ToolAnnotations(approval: .dangerous))
    ) { _, _ in
      Issue.record("Denied tool must not execute")
      return ToolOutput(text: "unexpected")
    })

  let result = try await runtime.run(
    AgentRequest(
      provider: "scripted",
      model: "fixture",
      messages: [.user("do it")],
      toolNames: ["sensitive"]))
  let toolResult = try #require(result.transcript.flatMap(\.toolResults).first)
  #expect(toolResult.isError)
  #expect(toolResult.text.contains("test policy"))
}

@Test("Providers without native tools use the JSON fallback without leaking protocol text")
func textToolFallback() async throws {
  let provider = ScriptedProvider(
    responses: [
      ProviderResponse(
        message: .assistant("{\"tool\":\"echo\",\"arguments\":{\"text\":\"fallback\"}}"),
        stopReason: .stop),
      ProviderResponse(message: .assistant("Fallback complete."), stopReason: .stop),
    ],
    capabilities: [.streaming])
  let events = EventRecorder()
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  try await runtime.register(
    tool: ClosureTool(
      definition: ToolDefinition(
        name: "echo",
        description: "Echo",
        inputSchema: objectSchema(required: ["text"]),
        annotations: ToolAnnotations(approval: .automatic))
    ) { arguments, _ in
      ToolOutput(text: arguments.objectValue?["text"]?.stringValue ?? "")
    })

  let result = try await runtime.run(
    AgentRequest(
      provider: "scripted",
      model: "fixture",
      messages: [.user("use echo")],
      toolNames: ["echo"],
      toolCallingStrategy: .automatic)
  ) { event in
    await events.append(event)
  }

  #expect(result.response.text == "Fallback complete.")
  #expect(result.transcript.flatMap(\.toolResults).first?.text == "fallback")
  let requests = await provider.requests
  #expect(requests.first?.tools.isEmpty == true)
  #expect(requests.first?.stream == false)
  #expect(requests.first?.messages.contains { $0.text.contains("JSON fallback protocol") } == true)
  let leakedProtocol = await events.events.contains { event in
    if case .provider(_, .textDelta(let text)) = event { return text.contains("\"tool\"") }
    return false
  }
  #expect(!leakedProtocol)
}

@Test("Token budgets are shared and enforced")
func tokenBudget() async throws {
  let provider = ScriptedProvider(responses: [
    ProviderResponse(
      message: .assistant("too expensive"),
      usage: TokenUsage(inputTokens: 4, outputTokens: 2),
      stopReason: .stop)
  ])
  let runtime = AgentRuntime()
  try await runtime.register(provider)
  await #expect(throws: AgentRuntimeError.limitExceeded("token budget")) {
    try await runtime.run(
      AgentRequest(
        provider: "scripted",
        model: "fixture",
        messages: [.user("hello")],
        limits: AgentRunLimits(maxTotalTokens: 5)))
  }
}

@Test("Subagents run with isolated transcripts and shared bounded lifecycle")
func subagentRun() async throws {
  let provider = ScriptedProvider(responses: [
    ProviderResponse(
      message: AgentMessage(
        role: .assistant,
        content: [
          .toolCall(
            ToolCall(
              id: "spawn-1",
              name: AgentRuntime.subagentToolName,
              arguments: .object([
                "agent": .string("researcher"),
                "task": .string("Find the answer"),
              ])))
        ]),
      stopReason: .toolCall),
    ProviderResponse(message: .assistant("Child result"), stopReason: .stop),
    ProviderResponse(message: .assistant("Parent used Child result"), stopReason: .stop),
  ])
  let recorder = EventRecorder()
  let runtime = AgentRuntime(approvalHandler: AllowAllApprovals())
  try await runtime.register(provider)
  try await runtime.register(
    agent: AgentDefinition(
      id: "researcher",
      instructions: "Research carefully.",
      provider: "scripted",
      model: "fixture"))

  let result = try await runtime.run(
    AgentRequest(
      provider: "scripted",
      model: "fixture",
      messages: [.user("delegate")],
      subagentNames: ["researcher"],
      limits: AgentRunLimits(
        maxModelTurns: 4,
        maxToolCalls: 2,
        maxSubagents: 1,
        maxSubagentDepth: 1))
  ) { event in
    await recorder.append(event)
  }

  #expect(result.response.text == "Parent used Child result")
  #expect(result.transcript.flatMap(\.toolResults).first?.text == "Child result")
  let events = await recorder.events
  #expect(events.contains { if case .childStarted = $0 { true } else { false } })
  #expect(events.contains { if case .childFinished = $0 { true } else { false } })
  let requests = await provider.requests
  #expect(requests.count == 3)
  #expect(requests[1].messages.first?.text == "Research carefully.")
  #expect(requests[1].messages.last?.text == "Find the answer")
}

@Test("Configuration loads providers, agents, secrets, and defaults")
func configurationLoading() async throws {
  let data = Data(
    """
    {
      "version": 1,
      "defaultAgent": "main",
      "providers": [{
        "id": "local",
        "kind": "openAICompatible",
        "baseURL": "http://127.0.0.1:8080/v1",
        "apiKeyEnvironment": "TEST_API_KEY"
      }],
      "agents": [{
        "id": "main",
        "provider": "local",
        "model": "model",
        "toolCallingStrategy": "json",
        "options": {"temperature": 0.2, "maxOutputTokens": 100},
        "subagentNames": ["helper"]
      }, {
        "id": "helper",
        "provider": "local",
        "model": "model"
      }],
      "approvals": {"confirm": "allow", "dangerous": "deny"}
    }
    """.utf8)
  let configuration = try JSONDecoder().decode(MaiConfiguration.self, from: data)
  try configuration.validate()
  #expect(configuration.defaultAgent == "main")
  #expect(configuration.approvals.confirm == .allow)
  #expect(configuration.agents[0].limits == AgentRunLimits())
  #expect(configuration.agents[0].toolCallingStrategy == .json)
  #expect(configuration.agents[0].options.maxOutputTokens == 100)
  let plugins = PluginRegistry()
  try await plugins.install(MaiOpenAIPlugin())
  let provider = try await plugins.makeProvider(
    from: configuration.providers[0],
    environment: ["TEST_API_KEY": "secret"])
  #expect(provider.descriptor.id == "local")
}

@Test("Configuration accepts host-defined provider kinds and factories")
func customProviderFactory() async throws {
  let data = Data(
    """
    {
      "id": "fixture-provider",
      "kind": "fixture",
      "options": {"prefix": "Configured extension"}
    }
    """.utf8)
  let configured = try JSONDecoder().decode(ConfiguredProvider.self, from: data)
  #expect(configured.kind == ConfiguredProviderKind("fixture"))
  #expect(configured.options["prefix"] == .string("Configured extension"))

  let plugins = PluginRegistry()
  try await plugins.install(FixtureProviderPlugin())
  let provider = try await plugins.makeProvider(from: configured, environment: [:])
  let response = try await provider.complete(
    ProviderRequest(model: "fixture", messages: [.user("works")], stream: false))

  #expect(provider.descriptor.id == "fixture-provider")
  #expect(response.message.text == "Configured extension: works")
}

@Test("MCP client negotiates, catalogs, and preserves structured tool content")
func mcpClient() async throws {
  let recorder = MethodRecorder()
  StubURLProtocol.install(forHost: "mcp.example.test") { request in
    let body = try jsonObject(try requestBodyData(request))
    let method = try #require(body["method"] as? String)
    recorder.record(method)
    let id = body["id"] as? Int
    let payload: String
    switch method {
    case "initialize":
      payload = rpc(
        id: id,
        result: """
          {"protocolVersion":"2025-11-25","serverInfo":{"name":"Fixture"}}
          """)
    case "notifications/initialized":
      payload = ""
    case "tools/list":
      payload = rpc(
        id: id,
        result: """
          {"tools":[{"name":"lookup","description":"Lookup","inputSchema":{"type":"object","properties":{"q":{"type":"string"}},"required":["q"]},"annotations":{"readOnlyHint":true}}]}
          """)
    case "resources/list":
      payload = rpc(
        id: id,
        result: """
          {"resources":[{"uri":"fixture://readme","name":"Readme","mimeType":"text/plain"}]}
          """)
    case "tools/call":
      payload = rpc(
        id: id,
        result: """
          {"content":[{"type":"text","text":"found"},{"type":"image","data":"AQI=","mimeType":"image/png"}],"structuredContent":{"count":1},"isError":false}
          """)
    default:
      payload = rpc(id: id, result: "{}")
    }
    return try httpResponse(
      request,
      contentType: "application/json",
      body: payload,
      headers: method == "initialize" ? ["Mcp-Session-Id": "session-1"] : [:])
  }
  defer { StubURLProtocol.reset(host: "mcp.example.test") }

  let client = MCPClient(
    configuration: MCPServerConfiguration(
      id: "fixture",
      url: try #require(URL(string: "https://mcp.example.test/mcp"))),
    session: stubSession())
  let catalog = try await client.connect()
  #expect(catalog.serverName == "Fixture")
  #expect(catalog.tools.first?.name == "fixture::lookup")
  #expect(catalog.resources.first?.uri == "fixture://readme")
  let agentTools = try await client.agentTools()
  #expect(agentTools.contains { $0.definition.name == "fixture::resources_read" })
  let tool = try #require(agentTools.first)
  let output = try await tool.call(
    arguments: .object(["q": .string("test")]),
    context: ToolExecutionContext(
      run: AgentEventContext(runID: UUID(), parentRunID: nil, agentID: "test", depth: 0),
      modelTurn: 1))
  #expect(output.content.first == .text("found"))
  #expect(output.content.contains { if case .image = $0 { true } else { false } })
  #expect(output.structuredContent == .object(["count": .integer(1)]))
  #expect(recorder.methods.contains("notifications/initialized"))
  #expect(recorder.methods.contains("tools/call"))
}

private func objectSchema(required: [String]) -> JSONValue {
  .object([
    "type": .string("object"),
    "properties": .object(
      Dictionary(uniqueKeysWithValues: required.map { ($0, .object(["type": .string("string")])) })),
    "required": .array(required.map(JSONValue.string)),
  ])
}

private struct FixtureOCRProvider: OCRProvider {
  let descriptor = OCRProviderDescriptor(id: "fixture", displayName: "Fixture OCR")

  func recognize(_ request: OCRRequest) async throws -> OCRResult {
    #expect(request.filename == "receipt.jpg")
    #expect(request.mimeType == "image/jpeg")
    return OCRResult(markdown: "# Recognized\n\nHello from OCR")
  }
}

private struct FixtureConfiguredProviderFactory: ConfiguredProviderFactory {
  let kind = ConfiguredProviderKind("fixture")

  func makeProvider(
    from configuration: ConfiguredProvider,
    environment: [String: String]
  ) throws -> any ChatProvider {
    HelloProvider(
      id: ProviderID(configuration.id),
      displayName: configuration.displayName ?? "Fixture",
      prefix: configuration.options["prefix"]?.stringValue ?? "Fixture")
  }
}

private struct FixtureProviderPlugin: MaiPlugin {
  let manifest = PluginManifest(
    id: "fixture-provider-plugin",
    displayName: "Fixture provider",
    version: "1.0.0",
    capabilities: [.chatProvider])

  func register(in registry: PluginRegistry) async throws {
    try await registry.register(
      providerFactory: FixtureConfiguredProviderFactory(),
      from: manifest.id)
  }
}

private func pngData(width: Int, height: Int) throws -> Data {
  let colorSpace = CGColorSpaceCreateDeviceRGB()
  let context = try #require(
    CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
  context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  let image = try #require(context.makeImage())
  let data = NSMutableData()
  let destination = try #require(
    CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
  CGImageDestinationAddImage(destination, image, nil)
  try #require(CGImageDestinationFinalize(destination))
  return data as Data
}

private func stubSession() -> URLSession {
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [StubURLProtocol.self]
  return URLSession(configuration: configuration)
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
  try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func requestBodyData(_ request: URLRequest) throws -> Data {
  if let body = request.httpBody { return body }
  guard let stream = request.httpBodyStream else { return Data() }
  stream.open()
  defer { stream.close() }
  var result = Data()
  var buffer = [UInt8](repeating: 0, count: 4_096)
  while stream.hasBytesAvailable {
    let count = stream.read(&buffer, maxLength: buffer.count)
    if count < 0 { throw stream.streamError ?? TestError.missingResponse }
    if count == 0 { break }
    result.append(contentsOf: buffer.prefix(count))
  }
  return result
}

private func httpResponse(
  _ request: URLRequest,
  status: Int = 200,
  contentType: String,
  body: String,
  headers: [String: String] = [:]
) throws -> (HTTPURLResponse, Data) {
  var allHeaders = headers
  allHeaders["Content-Type"] = contentType
  let url = try #require(request.url)
  let response = try #require(
    HTTPURLResponse(
      url: url,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: allHeaders))
  return (response, Data(body.utf8))
}

private func rpc(id: Int?, result: String) -> String {
  "{\"jsonrpc\":\"2.0\",\"id\":\(id ?? 0),\"result\":\(result)}"
}

private actor EventRecorder {
  private(set) var events: [AgentEvent] = []
  func append(_ event: AgentEvent) { events.append(event) }
}

private actor ProviderEventRecorder {
  private(set) var events: [ProviderEvent] = []
  func append(_ event: ProviderEvent) { events.append(event) }
}

private actor ScriptedProvider: ChatProvider {
  nonisolated let descriptor: ProviderDescriptor
  private var responses: [ProviderResponse]
  private(set) var requests: [ProviderRequest] = []

  init(
    responses: [ProviderResponse],
    capabilities: ProviderCapabilities = [.streaming, .nativeToolCalling, .imageInput]
  ) {
    descriptor = ProviderDescriptor(
      id: "scripted",
      displayName: "Scripted",
      capabilities: capabilities)
    self.responses = responses
  }

  func complete(
    _ request: ProviderRequest,
    emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    requests.append(request)
    guard !responses.isEmpty else { throw TestError.missingResponse }
    let response = responses.removeFirst()
    if !response.message.reasoning.isEmpty {
      await emit(.reasoningDelta(response.message.reasoning))
    }
    if !response.message.text.isEmpty { await emit(.textDelta(response.message.text)) }
    return response
  }
}

private actor QueueApprovalHandler: ApprovalHandler {
  private var decisions: [ApprovalDecision]
  init(decisions: [ApprovalDecision]) { self.decisions = decisions }

  func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
    guard !decisions.isEmpty else { return .deny(reason: "No test decision") }
    return decisions.removeFirst()
  }
}

private actor JSONValueRecorder {
  private(set) var value: JSONValue?
  func record(_ value: JSONValue) { self.value = value }
}

private final class URLRequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedRequest: URLRequest?
  private var storedBody: Data?
  var request: URLRequest? { lock.withLock { storedRequest } }
  var body: Data? { lock.withLock { storedBody } }
  func record(_ request: URLRequest, body: Data) {
    lock.withLock {
      storedRequest = request
      storedBody = body
    }
  }
}

private final class MethodRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedMethods: [String] = []
  var methods: [String] { lock.withLock { storedMethods } }
  func record(_ method: String) { lock.withLock { storedMethods.append(method) } }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
  private static let lock = NSLock()
  nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

  static func install(forHost host: String, _ handler: @escaping Handler) {
    lock.withLock { handlers[host] = handler }
  }

  static func reset(host: String) { lock.withLock { handlers[host] = nil } }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    do {
      let host = try #require(request.url?.host)
      let handler = try Self.lock.withLock { try #require(Self.handlers[host]) }
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

private enum TestError: Error { case missingResponse }
