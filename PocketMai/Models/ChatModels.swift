import Foundation

enum ChatRole: String, Codable, CaseIterable, Identifiable, Sendable {
  case user
  case assistant
  case system
  case tool
  case error

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .user: "You"
    case .assistant: "Assistant"
    case .system: "System"
    case .tool: "Tool"
    case .error: "Error"
    }
  }
}

enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case apple
  case openAICompatible

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .apple: "Apple"
    case .openAICompatible: "OpenAI-compatible"
    }
  }
}

enum ConversationExportFormat: String, CaseIterable, Identifiable, Sendable {
  case markdown
  case epub
  case audio
  case json

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .markdown: "Markdown"
    case .json: "JSON"
    case .epub: "EPUB"
    case .audio: "Audio"
    }
  }

  var systemImage: String {
    switch self {
    case .markdown: "doc.richtext"
    case .json: "curlybraces"
    case .epub: "book"
    case .audio: "waveform"
    }
  }

  var fileExtension: String {
    switch self {
    case .markdown: "md"
    case .json: "json"
    case .epub: "epub"
    case .audio: "m4a"
    }
  }
}

enum AppearanceFontFamily: Codable, Equatable, Hashable, Identifiable, Sendable {
  case system
  case serif
  case rounded
  case monospaced
  case installed(String)

  var id: String {
    switch self {
    case .system: "system"
    case .serif: "serif"
    case .rounded: "rounded"
    case .monospaced: "monospaced"
    case .installed(let fontName): "installed:\(fontName)"
    }
  }

  var displayName: String {
    switch self {
    case .system: "System"
    case .serif: "Serif"
    case .rounded: "Rounded"
    case .monospaced: "Monospaced"
    case .installed(let fontName): fontName.replacingOccurrences(of: "-", with: " ")
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    switch value {
    case "system": self = .system
    case "serif": self = .serif
    case "rounded": self = .rounded
    case "monospaced": self = .monospaced
    default:
      if value.hasPrefix("installed:") {
        self = .installed(String(value.dropFirst("installed:".count)))
      } else {
        self = .system
      }
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .system:
      try container.encode("system")
    case .serif:
      try container.encode("serif")
    case .rounded:
      try container.encode("rounded")
    case .monospaced:
      try container.encode("monospaced")
    case .installed(let fontName):
      try container.encode("installed:\(fontName)")
    }
  }
}

enum AppearanceTint: String, Codable, CaseIterable, Identifiable, Sendable {
  case system
  case blue
  case purple
  case pink
  case red
  case orange
  case yellow
  case green
  case mint
  case teal
  case cyan
  case indigo

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .system: "System"
    case .blue: "Blue"
    case .purple: "Purple"
    case .pink: "Pink"
    case .red: "Red"
    case .orange: "Orange"
    case .yellow: "Yellow"
    case .green: "Green"
    case .mint: "Mint"
    case .teal: "Teal"
    case .cyan: "Cyan"
    case .indigo: "Indigo"
    }
  }
}

struct AppearanceSettings: Codable, Equatable, Sendable {
  var userFontFamily: AppearanceFontFamily = .rounded
  var assistantFontFamily: AppearanceFontFamily = .serif
  var fontSize: Double = 17
  var tint: AppearanceTint = .system

  static let defaults = AppearanceSettings()

  init() {}

  enum CodingKeys: String, CodingKey {
    case userFontFamily, assistantFontFamily, fontFamily, fontSize, tint
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let legacyFamily = try? c.decode(AppearanceFontFamily.self, forKey: .fontFamily)
    userFontFamily =
      (try? c.decode(AppearanceFontFamily.self, forKey: .userFontFamily)) ?? .rounded
    assistantFontFamily =
      (try? c.decode(AppearanceFontFamily.self, forKey: .assistantFontFamily))
      ?? legacyFamily ?? .serif
    fontSize = (try? c.decode(Double.self, forKey: .fontSize)) ?? 17
    tint = (try? c.decode(AppearanceTint.self, forKey: .tint)) ?? .system
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(userFontFamily, forKey: .userFontFamily)
    try c.encode(assistantFontFamily, forKey: .assistantFontFamily)
    try c.encode(fontSize, forKey: .fontSize)
    try c.encode(tint, forKey: .tint)
  }
}

enum NativeToolID: String, Codable, CaseIterable, Identifiable, Sendable {
  case datetime
  case location
  case weather
  case webSearch
  case todo
  case textToSpeech
  case files
  case memory

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .datetime: "Date & Time"
    case .location: "Location"
    case .weather: "Weather"
    case .webSearch: "Web Search"
    case .todo: "Todo"
    case .textToSpeech: "Text to Speech"
    case .files: "Files"
    case .memory: "Memory"
    }
  }

  var systemImage: String {
    switch self {
    case .datetime: "clock"
    case .location: "location"
    case .weather: "cloud.sun"
    case .webSearch: "magnifyingglass"
    case .todo: "checklist"
    case .textToSpeech: "speaker.wave.2"
    case .files: "folder"
    case .memory: "brain"
    }
  }

}

enum ToolCallingMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case text
  case native

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .text: "Text protocol"
    case .native: "Native (OpenAI tools)"
    }
  }

  var summary: String {
    switch self {
    case .text:
      return
        "Works with any model. Tools are described in the system prompt; calls and results travel as <tool_call> / <tool_run> XML blocks."
    case .native:
      return
        "Adds OpenAI's structured tools array to each request so capable models can return tool_calls directly. Falls back to the text protocol on Apple Intelligence."
    }
  }
}

enum ReasoningLevel: String, Codable, CaseIterable, Identifiable, Sendable {
  case automatic
  case disabled
  case minimal
  case low
  case medium
  case high
  case xhigh

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .automatic: "Auto"
    case .disabled: "Off"
    case .minimal: "Minimal"
    case .low: "Low"
    case .medium: "Medium"
    case .high: "High"
    case .xhigh: "Extra High"
    }
  }

  var systemImage: String {
    switch self {
    case .automatic: "brain"
    case .disabled: "xmark.circle"
    case .minimal: "tortoise"
    case .low: "speedometer"
    case .medium: "circle.lefthalf.filled"
    case .high: "flame"
    case .xhigh: "flame.fill"
    }
  }

  var reasoningEffortValue: String? {
    switch self {
    case .automatic: nil
    case .disabled: "none"
    case .minimal: "minimal"
    case .low: "low"
    case .medium: "medium"
    case .high, .xhigh: "high"
    }
  }
}

enum ContextWindowMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case full
  case last10
  case last5
  case lastMessage
  case none

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .full: "Full"
    case .last10: "Last 10 messages"
    case .last5: "Last 5 messages"
    case .lastMessage: "Last Message"
    case .none: "None"
    }
  }

  var messageLimit: Int? {
    switch self {
    case .full: nil
    case .last10: 10
    case .last5: 5
    case .lastMessage: 1
    case .none: 0
    }
  }
}

enum WebSearchProvider: String, Codable, CaseIterable, Identifiable, Sendable {
  case duckDuckGo
  case wikipedia
  case ollama
  case all

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .duckDuckGo: "DuckDuckGo"
    case .wikipedia: "Wikipedia"
    case .ollama: "Ollama Web Search"
    case .all: "All"
    }
  }
}

struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
  var id: UUID = UUID()
  var role: ChatRole
  var text: String
  var createdAt: Date = Date()
}

struct ConversationSummary: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var title: String
  var createdAt: Date
  var updatedAt: Date
  var isPinned: Bool
  var isArchived: Bool
  var preview: String
  var hasMessages: Bool

  init(conversation: Conversation) {
    id = conversation.id
    title = conversation.title
    createdAt = conversation.createdAt
    updatedAt = conversation.updatedAt
    isPinned = conversation.isPinned
    isArchived = conversation.isArchived
    hasMessages = !conversation.messages.isEmpty
    preview =
      conversation.messages.last.map {
        String($0.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
      } ?? ""
  }

  var displayTitle: String {
    title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New chat" : title
  }

  var displayPreview: String {
    preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No messages" : preview
  }
}

struct Conversation: Identifiable, Codable, Equatable, Sendable {
  var id: UUID = UUID()
  var title: String = "New chat"
  var messages: [ChatMessage] = []
  var createdAt: Date = Date()
  var updatedAt: Date = Date()
  var provider: ProviderKind = .apple
  var modelID: String = AppSettings.appleDefaultModelID
  var endpointID: UUID? = nil
  var systemPromptID: UUID? = nil
  var enabledTools: Set<NativeToolID> = AppSettings.defaultTools
  var usesStreaming: Bool = true
  var isPinned: Bool = false
  var disabledMCPTools: Set<String> = []
  var reasoningLevel: ReasoningLevel = .automatic
  var showThinking: Bool = false
  var lastToolContextSignature: String? = nil
  var isArchived: Bool = false

  init() {}

  enum CodingKeys: String, CodingKey {
    case id
    case title
    case messages
    case createdAt
    case updatedAt
    case provider
    case modelID
    case endpointID
    case systemPromptID
    case enabledTools
    case usesStreaming
    case isPinned
    case disabledMCPTools
    case reasoningLevel
    case showThinking
    case lastToolContextSignature
    case isArchived
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    messages = try container.decode([ChatMessage].self, forKey: .messages)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    provider = try container.decode(ProviderKind.self, forKey: .provider)
    modelID = try container.decode(String.self, forKey: .modelID)
    endpointID = try container.decodeIfPresent(UUID.self, forKey: .endpointID)
    systemPromptID = try container.decodeIfPresent(UUID.self, forKey: .systemPromptID)
    enabledTools = try container.decode(Set<NativeToolID>.self, forKey: .enabledTools)
    usesStreaming = try container.decode(Bool.self, forKey: .usesStreaming)
    isPinned = (try? container.decode(Bool.self, forKey: .isPinned)) ?? false
    disabledMCPTools =
      (try? container.decode(Set<String>.self, forKey: .disabledMCPTools)) ?? []
    reasoningLevel =
      (try? container.decode(ReasoningLevel.self, forKey: .reasoningLevel)) ?? .automatic
    showThinking = (try? container.decode(Bool.self, forKey: .showThinking)) ?? false
    lastToolContextSignature =
      try? container.decodeIfPresent(String.self, forKey: .lastToolContextSignature)
    isArchived = (try? container.decode(Bool.self, forKey: .isArchived)) ?? false
  }

  var displayTitle: String {
    title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New chat" : title
  }

  mutating func refreshTitle(from message: String) {
    guard title == "New chat" || title.isEmpty else { return }
    let compact = message.replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    title = String(compact.prefix(48))
    if title.isEmpty {
      title = "New chat"
    }
  }
}

struct OpenAIEndpoint: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var name: String
  var baseURL: String
  var apiKey: String
  var defaultModel: String
  var defaultReasoningLevel: ReasoningLevel
  var isEnabled: Bool

  init(
    id: UUID = UUID(),
    name: String = "",
    baseURL: String = "https://api.openai.com/v1",
    apiKey: String = "",
    defaultModel: String = "",
    defaultReasoningLevel: ReasoningLevel = .automatic,
    isEnabled: Bool = true
  ) {
    self.id = id
    self.name = name
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.defaultModel = defaultModel
    self.defaultReasoningLevel = defaultReasoningLevel
    self.isEnabled = isEnabled
  }

  enum CodingKeys: String, CodingKey {
    case id, name, baseURL, apiKey, defaultModel, defaultReasoningLevel, isEnabled
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    name = try c.decode(String.self, forKey: .name)
    baseURL = try c.decode(String.self, forKey: .baseURL)
    apiKey = try c.decode(String.self, forKey: .apiKey)
    defaultModel = try c.decode(String.self, forKey: .defaultModel)
    defaultReasoningLevel =
      (try? c.decode(ReasoningLevel.self, forKey: .defaultReasoningLevel)) ?? .automatic
    isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(name, forKey: .name)
    try c.encode(baseURL, forKey: .baseURL)
    try c.encode(apiKey, forKey: .apiKey)
    try c.encode(defaultModel, forKey: .defaultModel)
    try c.encode(defaultReasoningLevel, forKey: .defaultReasoningLevel)
    try c.encode(isEnabled, forKey: .isEnabled)
  }
}

extension OpenAIEndpoint {
  static let defaultDisplayName = "New Endpoint"

  var displayName: String {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedName.isEmpty ? Self.defaultDisplayName : trimmedName
  }
}

struct SystemPrompt: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var name: String
  var text: String

  init(id: UUID = UUID(), name: String, text: String) {
    self.id = id
    self.name = name
    self.text = text
  }
}

struct TodoItem: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var title: String
  var isDone: Bool
  var createdAt: Date

  init(id: UUID = UUID(), title: String, isDone: Bool = false, createdAt: Date = Date()) {
    self.id = id
    self.title = title
    self.isDone = isDone
    self.createdAt = createdAt
  }
}

struct ToolFile: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var name: String
  var excerpt: String
  var importedAt: Date

  init(id: UUID = UUID(), name: String, excerpt: String, importedAt: Date = Date()) {
    self.id = id
    self.name = name
    self.excerpt = excerpt
    self.importedAt = importedAt
  }
}

struct MCPToolDescriptor: Identifiable, Codable, Equatable, Sendable {
  var name: String
  var description: String
  var parametersJSON: String

  var id: String { name }

  init(name: String, description: String = "", parametersJSON: String = "") {
    self.name = name
    self.description = description
    self.parametersJSON = parametersJSON
  }

  enum CodingKeys: String, CodingKey {
    case name, description, parametersJSON
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    description = (try? c.decode(String.self, forKey: .description)) ?? ""
    parametersJSON = (try? c.decode(String.self, forKey: .parametersJSON)) ?? ""
  }
}

struct MCPServer: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var name: String
  var baseURL: String
  var isEnabled: Bool

  init(
    id: UUID = UUID(), name: String = "MCP Server", baseURL: String = "https://",
    isEnabled: Bool = true
  ) {
    self.id = id
    self.name = name
    self.baseURL = baseURL
    self.isEnabled = isEnabled
  }

  var isHTTPS: Bool {
    URL(string: baseURL)?.scheme?.lowercased() == "https"
  }

  var hasValidScheme: Bool {
    let scheme = URL(string: baseURL)?.scheme?.lowercased() ?? ""
    return scheme == "https" || scheme == "http"
  }
}

struct RoleVoiceSettings: Codable, Equatable, Sendable {
  var language: String = ""
  var voiceIdentifier: String = ""
  var rate: Double = 0.5
  var pitch: Double = 1.0

  static let defaults = RoleVoiceSettings()
}

struct VoiceSettings: Codable, Equatable, Sendable {
  var user: RoleVoiceSettings = .defaults
  var assistant: RoleVoiceSettings = .defaults

  static let defaults = VoiceSettings()
}

enum VoiceRole: String, Codable, Sendable {
  case user
  case assistant
}

extension VoiceSettings {
  func settings(for role: VoiceRole) -> RoleVoiceSettings {
    switch role {
    case .user: return user
    case .assistant: return assistant
    }
  }
}

struct NativeToolSettings: Codable, Equatable, Sendable {
  var includeTimeZone: Bool = true
  var includeCurrentTime: Bool = true
  var includeYear: Bool = true
  var useGPSLocation: Bool = false
  var manualLocation: String = ""
  var weatherLocation: String = ""
  var webSearchProvider: WebSearchProvider = .duckDuckGo
  var webSearchFetchingEnabled: Bool = false
  var todos: [TodoItem] = []
  var files: [ToolFile] = []
  var voices: VoiceSettings = .defaults

  static let defaults = NativeToolSettings()

  init() {}

  enum CodingKeys: String, CodingKey {
    case includeTimeZone, includeCurrentTime, includeYear, useGPSLocation
    case manualLocation, weatherLocation, webSearchProvider, webSearchFetchingEnabled, todos, files
    case voices
  }

  private enum LegacyCodingKeys: String, CodingKey {
    case textToSpeechLanguage, textToSpeechVoiceIdentifier
    case textToSpeechRate, textToSpeechPitch
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = NativeToolSettings.defaults
    includeTimeZone =
      (try? c.decode(Bool.self, forKey: .includeTimeZone)) ?? defaults.includeTimeZone
    includeCurrentTime =
      (try? c.decode(Bool.self, forKey: .includeCurrentTime)) ?? defaults.includeCurrentTime
    includeYear = (try? c.decode(Bool.self, forKey: .includeYear)) ?? defaults.includeYear
    useGPSLocation = (try? c.decode(Bool.self, forKey: .useGPSLocation)) ?? defaults.useGPSLocation
    manualLocation =
      (try? c.decode(String.self, forKey: .manualLocation)) ?? defaults.manualLocation
    weatherLocation =
      (try? c.decode(String.self, forKey: .weatherLocation)) ?? defaults.weatherLocation
    webSearchProvider =
      (try? c.decode(WebSearchProvider.self, forKey: .webSearchProvider))
      ?? defaults.webSearchProvider
    webSearchFetchingEnabled =
      (try? c.decode(Bool.self, forKey: .webSearchFetchingEnabled))
      ?? defaults.webSearchFetchingEnabled
    todos = (try? c.decode([TodoItem].self, forKey: .todos)) ?? defaults.todos
    files = (try? c.decode([ToolFile].self, forKey: .files)) ?? defaults.files

    if let decoded = try? c.decode(VoiceSettings.self, forKey: .voices) {
      voices = decoded
    } else if let legacy = try? decoder.container(keyedBy: LegacyCodingKeys.self) {
      // Migrate from the previous flat textToSpeech* fields. Both roles seed
      // from the same legacy values so the user has a consistent starting
      // point and can diverge them later.
      let legacyVoice = RoleVoiceSettings(
        language: (try? legacy.decode(String.self, forKey: .textToSpeechLanguage)) ?? "",
        voiceIdentifier:
          (try? legacy.decode(String.self, forKey: .textToSpeechVoiceIdentifier)) ?? "",
        rate: (try? legacy.decode(Double.self, forKey: .textToSpeechRate))
          ?? RoleVoiceSettings.defaults.rate,
        pitch: (try? legacy.decode(Double.self, forKey: .textToSpeechPitch))
          ?? RoleVoiceSettings.defaults.pitch)
      voices = VoiceSettings(user: legacyVoice, assistant: legacyVoice)
    } else {
      voices = defaults.voices
    }
  }
}

struct AppSettings: Codable, Equatable, Sendable {
  static let appleDefaultModelID = ""
  static let defaultTools: Set<NativeToolID> = []
  static let defaultSystemPrompt = SystemPrompt(
    name: "Helpful assistant",
    text:
      "You are a helpful, concise assistant for a private text-only chat app. Prefer clear answers and preserve useful formatting."
  )

  var defaultProvider: ProviderKind = .apple
  var appleModelID: String = AppSettings.appleDefaultModelID
  var selectedEndpointID: UUID? = nil
  var streamByDefault: Bool = true
  var showThinkingByDefault: Bool = false
  var openAIEndpoints: [OpenAIEndpoint] = []
  var systemPrompts: [SystemPrompt] = [AppSettings.defaultSystemPrompt]
  var defaultSystemPromptID: UUID = AppSettings.defaultSystemPrompt.id
  var defaultEnabledTools: Set<NativeToolID> = AppSettings.defaultTools
  var toolSettings: NativeToolSettings = .defaults
  var mcpServers: [MCPServer] = []
  var memory: String = ""
  var toolCallingMode: ToolCallingMode = .text
  var useToolProxy: Bool = false
  var contextWindowMode: ContextWindowMode = .full
  var appearance: AppearanceSettings = .defaults

  static let defaults = AppSettings()

  init() {}

  func defaultPrompt() -> SystemPrompt {
    systemPrompts.first(where: { $0.id == defaultSystemPromptID }) ?? systemPrompts.first
      ?? AppSettings.defaultSystemPrompt
  }

  var defaultOpenAIEndpoint: OpenAIEndpoint? {
    if let selectedEndpointID,
      let endpoint = openAIEndpoints.first(where: { $0.id == selectedEndpointID && $0.isEnabled })
    {
      return endpoint
    }
    return openAIEndpoints.first(where: \.isEnabled)
  }

  var defaultProviderConfiguration:
    (provider: ProviderKind, endpointID: UUID?, modelID: String)
  {
    switch defaultProvider {
    case .apple:
      return (.apple, nil, appleModelID)
    case .openAICompatible:
      guard let endpoint = defaultOpenAIEndpoint else {
        return (.apple, nil, appleModelID)
      }
      return (.openAICompatible, endpoint.id, endpoint.defaultModel)
    }
  }

  enum CodingKeys: String, CodingKey {
    case defaultProvider, appleModelID, selectedEndpointID, streamByDefault, showThinkingByDefault
    case openAIEndpoints, systemPrompts, defaultSystemPromptID, defaultEnabledTools
    case toolSettings, mcpServers, memory, toolCallingMode
    case useToolProxy, contextWindowMode, appearance
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    defaultProvider =
      (try? c.decode(ProviderKind.self, forKey: .defaultProvider)) ?? .apple
    appleModelID = (try? c.decode(String.self, forKey: .appleModelID)) ?? ""
    selectedEndpointID = try? c.decode(UUID.self, forKey: .selectedEndpointID)
    streamByDefault = (try? c.decode(Bool.self, forKey: .streamByDefault)) ?? true
    showThinkingByDefault = (try? c.decode(Bool.self, forKey: .showThinkingByDefault)) ?? false
    openAIEndpoints =
      (try? c.decode([OpenAIEndpoint].self, forKey: .openAIEndpoints)) ?? []
    systemPrompts =
      (try? c.decode([SystemPrompt].self, forKey: .systemPrompts))
      ?? [AppSettings.defaultSystemPrompt]
    defaultSystemPromptID =
      (try? c.decode(UUID.self, forKey: .defaultSystemPromptID))
      ?? (systemPrompts.first?.id ?? AppSettings.defaultSystemPrompt.id)
    defaultEnabledTools =
      (try? c.decode(Set<NativeToolID>.self, forKey: .defaultEnabledTools))
      ?? AppSettings.defaultTools
    toolSettings =
      (try? c.decode(NativeToolSettings.self, forKey: .toolSettings)) ?? .defaults
    mcpServers = (try? c.decode([MCPServer].self, forKey: .mcpServers)) ?? []
    memory = (try? c.decode(String.self, forKey: .memory)) ?? ""
    let storedMode = (try? c.decode(String.self, forKey: .toolCallingMode)) ?? "text"
    let migratedFromLegacyProxy = (storedMode == "proxy")
    toolCallingMode =
      ToolCallingMode(rawValue: storedMode) ?? .text
    useToolProxy =
      (try? c.decode(Bool.self, forKey: .useToolProxy)) ?? migratedFromLegacyProxy
    contextWindowMode =
      (try? c.decode(ContextWindowMode.self, forKey: .contextWindowMode)) ?? .full
    appearance =
      (try? c.decode(AppearanceSettings.self, forKey: .appearance)) ?? .defaults
  }
}

struct AnyCodable: Codable, Sendable {
  let value: any Sendable

  init(_ value: any Sendable) {
    self.value = value
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      value = ""
    } else if let bool = try? container.decode(Bool.self) {
      value = bool
    } else if let int = try? container.decode(Int.self) {
      value = int
    } else if let double = try? container.decode(Double.self) {
      value = double
    } else if let string = try? container.decode(String.self) {
      value = string
    } else if let array = try? container.decode([AnyCodable].self) {
      value = array
    } else if let dictionary = try? container.decode([String: AnyCodable].self) {
      value = dictionary
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Unsupported JSON value")
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch value {
    case let bool as Bool:
      try container.encode(bool)
    case let int as Int:
      try container.encode(int)
    case let double as Double:
      try container.encode(double)
    case let string as String:
      try container.encode(string)
    case let array as [AnyCodable]:
      try container.encode(array)
    case let dictionary as [String: AnyCodable]:
      try container.encode(dictionary)
    default:
      preconditionFailure("AnyCodable cannot encode value of type \(type(of: value))")
    }
  }
}
