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
  case mlx
  case openAICompatible

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .apple: "Apple"
    case .mlx: "MLX"
    case .openAICompatible: "OpenAI-compatible"
    }
  }

  var supportsNativeToolCalling: Bool {
    switch self {
    case .openAICompatible:
      return true
    case .apple, .mlx:
      return false
    }
  }

  var isAirplaneModeEligible: Bool {
    switch self {
    case .apple, .mlx:
      return true
    case .openAICompatible:
      return false
    }
  }
}

enum ConversationExportFormat: String, CaseIterable, Identifiable, Sendable {
  case markdown
  case epub
  case audio
  case json
  case debug

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .markdown: "Markdown"
    case .json: "JSON"
    case .debug: "Debug"
    case .epub: "EPUB"
    case .audio: "Audio"
    }
  }

  var systemImage: String {
    switch self {
    case .markdown: "doc.richtext"
    case .json: "curlybraces"
    case .debug: "ladybug"
    case .epub: "book"
    case .audio: "waveform"
    }
  }

  var fileExtension: String {
    switch self {
    case .markdown: "md"
    case .json, .debug: "json"
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

enum AppearanceTheme: String, Codable, CaseIterable, Identifiable, Sendable {
  case system
  case light
  case dark

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }
}

struct AppearanceSettings: Codable, Equatable, Sendable {
  static let fontSizeRange: ClosedRange<Double> = 6...43
  static let fontSizeStep: Double = 0.05
  static let lineSpacingRange: ClosedRange<Double> = 0...14
  static let lineSpacingStep: Double = 0.25

  var userFontFamily: AppearanceFontFamily = .rounded
  var assistantFontFamily: AppearanceFontFamily = .serif
  var fontSize: Double = 17
  var lineSpacing: Double = 3
  var tint: AppearanceTint = .system
  var theme: AppearanceTheme = .system
  var solidResponseBubbles: Bool = true
  var liveMarkdown: Bool = true
  var justifyText: Bool = false
  var unwrappedTables: Bool = false

  static let defaults = AppearanceSettings()

  init() {}

  static func clampedFontSize(_ size: Double) -> Double {
    min(max(size, fontSizeRange.lowerBound), fontSizeRange.upperBound)
  }

  static func clampedLineSpacing(_ spacing: Double) -> Double {
    min(max(spacing, lineSpacingRange.lowerBound), lineSpacingRange.upperBound)
  }

  enum CodingKeys: String, CodingKey {
    case userFontFamily, assistantFontFamily, fontFamily, fontSize, lineSpacing, tint, theme
    case solidResponseBubbles, colorizeResponseBubbles, liveMarkdown, justifyText, unwrappedTables
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let legacyFamily = try? c.decode(AppearanceFontFamily.self, forKey: .fontFamily)
    userFontFamily =
      (try? c.decode(AppearanceFontFamily.self, forKey: .userFontFamily)) ?? .rounded
    assistantFontFamily =
      (try? c.decode(AppearanceFontFamily.self, forKey: .assistantFontFamily))
      ?? legacyFamily ?? .serif
    fontSize = Self.clampedFontSize((try? c.decode(Double.self, forKey: .fontSize)) ?? 17)
    lineSpacing =
      Self.clampedLineSpacing((try? c.decode(Double.self, forKey: .lineSpacing)) ?? 3)
    tint = (try? c.decode(AppearanceTint.self, forKey: .tint)) ?? .system
    theme = (try? c.decode(AppearanceTheme.self, forKey: .theme)) ?? .system
    solidResponseBubbles =
      (try? c.decode(Bool.self, forKey: .solidResponseBubbles))
      ?? (try? c.decode(Bool.self, forKey: .colorizeResponseBubbles)) ?? true
    liveMarkdown = (try? c.decode(Bool.self, forKey: .liveMarkdown)) ?? true
    justifyText = (try? c.decode(Bool.self, forKey: .justifyText)) ?? false
    unwrappedTables = (try? c.decode(Bool.self, forKey: .unwrappedTables)) ?? false
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(userFontFamily, forKey: .userFontFamily)
    try c.encode(assistantFontFamily, forKey: .assistantFontFamily)
    try c.encode(fontSize, forKey: .fontSize)
    try c.encode(lineSpacing, forKey: .lineSpacing)
    try c.encode(tint, forKey: .tint)
    try c.encode(theme, forKey: .theme)
    try c.encode(solidResponseBubbles, forKey: .solidResponseBubbles)
    try c.encode(liveMarkdown, forKey: .liveMarkdown)
    try c.encode(justifyText, forKey: .justifyText)
    try c.encode(unwrappedTables, forKey: .unwrappedTables)
  }
}

enum LiveSpeechRecognitionBackend: String, Codable, CaseIterable, Identifiable, Sendable {
  case nativeIOSSpeechTranscriber
  case nativeIOS

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .nativeIOSSpeechTranscriber: "Native iOS Live"
    case .nativeIOS: "Native iOS File"
    }
  }

  var systemImage: String {
    switch self {
    case .nativeIOSSpeechTranscriber: "waveform.and.mic"
    case .nativeIOS: "doc.badge.waveform"
    }
  }

}

struct ConversationSettings: Codable, Equatable, Sendable {
  static let silenceTimeoutRange: ClosedRange<Double> = 0.5...8
  static let silenceTimeoutStep: Double = 0.25

  var silenceTimeoutSeconds: Double = 1.25
  var speechRecognitionBackend: LiveSpeechRecognitionBackend = .nativeIOSSpeechTranscriber
  var speechRecognitionLanguageIdentifier: String = Locale.current.identifier
  var streamTTS: Bool = true
  var skipTechnicalContentInTTS: Bool = true
  var backgroundVoiceListeningEnabled: Bool = false

  static let defaults = ConversationSettings()

  init() {}

  var canUseBackgroundVoiceListening: Bool {
    speechRecognitionBackend == .nativeIOSSpeechTranscriber
  }

  var allowsBackgroundVoiceListening: Bool {
    canUseBackgroundVoiceListening && backgroundVoiceListeningEnabled
  }

  enum CodingKeys: String, CodingKey {
    case silenceTimeoutSeconds, speechRecognitionBackend, speechRecognitionLanguageIdentifier,
      streamTTS, skipTechnicalContentInTTS, backgroundVoiceListeningEnabled
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = ConversationSettings.defaults
    let timeout =
      (try? c.decode(Double.self, forKey: .silenceTimeoutSeconds))
      ?? defaults.silenceTimeoutSeconds
    silenceTimeoutSeconds = Self.clampedSilenceTimeout(timeout)
    speechRecognitionBackend =
      (try? c.decode(LiveSpeechRecognitionBackend.self, forKey: .speechRecognitionBackend))
      ?? defaults.speechRecognitionBackend
    let languageIdentifier =
      (try? c.decode(String.self, forKey: .speechRecognitionLanguageIdentifier))
      ?? defaults.speechRecognitionLanguageIdentifier
    speechRecognitionLanguageIdentifier =
      languageIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? defaults.speechRecognitionLanguageIdentifier
      : languageIdentifier
    streamTTS =
      (try? c.decode(Bool.self, forKey: .streamTTS)) ?? defaults.streamTTS
    skipTechnicalContentInTTS =
      (try? c.decode(Bool.self, forKey: .skipTechnicalContentInTTS))
      ?? defaults.skipTechnicalContentInTTS
    backgroundVoiceListeningEnabled =
      (try? c.decode(Bool.self, forKey: .backgroundVoiceListeningEnabled))
      ?? defaults.backgroundVoiceListeningEnabled
  }

  static func clampedSilenceTimeout(_ value: Double) -> Double {
    min(max(value, silenceTimeoutRange.lowerBound), silenceTimeoutRange.upperBound)
  }
}

enum BuiltInToolID: String, Codable, CaseIterable, Identifiable, Sendable {
  case datetime
  case language
  case location
  case weather
  case webSearch
  case todo
  case calculator
  case textToSpeech
  case files
  case memory

  var id: String { rawValue }

  var isContextSource: Bool {
    switch self {
    case .datetime, .language, .location, .memory:
      return true
    case .weather, .webSearch, .todo, .calculator, .textToSpeech, .files:
      return false
    }
  }

  var isCallableTool: Bool {
    switch self {
    case .weather, .webSearch, .todo, .calculator, .textToSpeech, .files:
      return true
    case .datetime, .language, .location, .memory:
      return false
    }
  }

  var displayName: String {
    switch self {
    case .datetime: "Date & Time"
    case .language: "Language Preference"
    case .location: "Location"
    case .weather: "Weather"
    case .webSearch: "Web Search"
    case .todo: "Todo"
    case .calculator: "Calculator"
    case .textToSpeech: "Text to Speech"
    case .files: "Files"
    case .memory: "Memory"
    }
  }

  var systemImage: String {
    switch self {
    case .datetime: "clock"
    case .language: "globe"
    case .location: "location"
    case .weather: "cloud.sun"
    case .webSearch: "magnifyingglass"
    case .todo: "checklist"
    case .calculator: "function"
    case .textToSpeech: "speaker.wave.2"
    case .files: "folder"
    case .memory: "brain"
    }
  }

  var isDisabledInAirplaneMode: Bool {
    switch self {
    case .weather, .webSearch:
      return true
    case .datetime, .language, .location, .todo, .calculator, .textToSpeech, .files, .memory:
      return false
    }
  }

}

enum ToolCallingMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case text
  case xml
  case json
  case native

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .text: "Text"
    case .xml: "XML"
    case .json: "JSON"
    case .native: "Native"
    }
  }

  var summary: String {
    switch self {
    case .text:
      return
        "Default. Uses a plain TOOL_CALL block with one argument per line. Most portable for small or local models."
    case .xml:
      return
        "Uses <tool_call> XML blocks with one <arg> element per argument. More structured, but more fragile for small models."
    case .json:
      return
        "Uses one JSON object with name and arguments. Compact and easy to parse when the model emits strict JSON."
    case .native:
      return
        "Uses provider-native structured tools for OpenAI-compatible requests. MLX falls back to JSON; Apple Intelligence falls back to Text."
    }
  }

  var textProtocolFallback: ToolCallingMode {
    self == .native ? .text : self
  }

  func textProtocolFallback(for provider: ProviderKind) -> ToolCallingMode {
    if self == .native, provider == .mlx {
      return .json
    }
    return textProtocolFallback
  }

  func appleInstruction(hasToolResults: Bool) -> String {
    if hasToolResults {
      return
        "Continue from the latest host tool result. Either emit one more \(callReference) if needed, or write the final answer."
    }
    return
      "Reply to the latest user message. If you need a tool, emit one \(callReference) and stop; otherwise answer directly."
  }

  private var callReference: String {
    switch self {
    case .text: "TOOL_CALL block"
    case .xml: "<tool_call> block"
    case .json: "tool-call JSON object"
    case .native: "TOOL_CALL block"
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

enum MLXKVCacheSize: Int, Codable, CaseIterable, Identifiable, Sendable {
  case auto = 0
  case size1024 = 1024
  case size2048 = 2048
  case size4096 = 4096
  case size8192 = 8192
  case size16384 = 16384

  var id: Int { rawValue }

  var effectiveSize: Int {
    guard case .auto = self else { return rawValue }
    let gb = ProcessInfo.processInfo.physicalMemory / (1_024 * 1_024 * 1_024)
    switch gb {
    case ..<6: return 2_048
    case ..<8: return 4_096
    case ..<16: return 8_192
    default: return 16_384
    }
  }

  var displayName: String {
    switch self {
    case .auto:
      let effective = effectiveSize
      let formatted = effective >= 1_000
        ? "\(effective / 1_000),\(String(format: "%03d", effective % 1_000))" : "\(effective)"
      return "Auto (\(formatted) tokens)"
    case .size1024: return "1,024 tokens"
    case .size2048: return "2,048 tokens"
    case .size4096: return "4,096 tokens"
    case .size8192: return "8,192 tokens"
    case .size16384: return "16,384 tokens"
    }
  }
}

enum AttachmentImageSize: String, Codable, CaseIterable, Identifiable, Sendable {
  case tiny
  case small
  case medium
  case full

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .tiny: "Tiny"
    case .small: "Small"
    case .medium: "Medium"
    case .full: "Full"
    }
  }

  var maxDimension: Int? {
    switch self {
    case .tiny: 32
    case .small: 100
    case .medium: 320
    case .full: nil
    }
  }
}

enum WebSearchProvider: String, Codable, CaseIterable, Identifiable, Sendable {
  case duckDuckGo
  case wikipedia
  case searXNG
  case ollama
  case all

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .duckDuckGo: "DuckDuckGo"
    case .wikipedia: "Wikipedia"
    case .searXNG: "SearXNG"
    case .ollama: "Ollama Web Search"
    case .all: "All"
    }
  }
}

enum ChatAttachmentKind: String, Codable, Sendable {
  case textFile
  case image
}

struct ChatAttachment: Identifiable, Codable, Equatable, Sendable {
  var id: UUID = UUID()
  var kind: ChatAttachmentKind
  var filename: String
  var mimeType: String
  var text: String?
  var dataBase64: String?
  var width: Int?
  var height: Int?

  static func textFile(filename: String, text: String, mimeType: String = "text/plain")
    -> ChatAttachment
  {
    ChatAttachment(kind: .textFile, filename: filename, mimeType: mimeType, text: text)
  }

  static func image(
    filename: String,
    data: Data,
    mimeType: String = "image/jpeg",
    width: Int?,
    height: Int?
  ) -> ChatAttachment {
    ChatAttachment(
      kind: .image,
      filename: filename,
      mimeType: mimeType,
      dataBase64: data.base64EncodedString(),
      width: width,
      height: height)
  }

  var displayName: String {
    filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Attachment" : filename
  }

  var dataURL: String? {
    guard kind == .image, let dataBase64, !dataBase64.isEmpty else { return nil }
    return "data:\(mimeType);base64,\(dataBase64)"
  }
}

struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
  var id: UUID = UUID()
  var role: ChatRole
  var text: String
  var createdAt: Date = Date()
  var voiceRecordingFilename: String? = nil
  var attachments: [ChatAttachment] = []

  enum CodingKeys: String, CodingKey {
    case id, role, text, createdAt, voiceRecordingFilename, attachments
  }

  init(
    id: UUID = UUID(),
    role: ChatRole,
    text: String,
    createdAt: Date = Date(),
    voiceRecordingFilename: String? = nil,
    attachments: [ChatAttachment] = []
  ) {
    self.id = id
    self.role = role
    self.text = text
    self.createdAt = createdAt
    self.voiceRecordingFilename = voiceRecordingFilename
    self.attachments = attachments
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    role = try c.decode(ChatRole.self, forKey: .role)
    text = try c.decode(String.self, forKey: .text)
    createdAt = try c.decode(Date.self, forKey: .createdAt)
    voiceRecordingFilename = try? c.decode(String.self, forKey: .voiceRecordingFilename)
    attachments = (try? c.decode([ChatAttachment].self, forKey: .attachments)) ?? []
  }
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
    preview = Self.previewText(from: conversation.messages)
  }

  var displayTitle: String {
    title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New chat" : title
  }

  var displayPreview: String {
    preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No messages" : preview
  }

  private static func previewText(from messages: [ChatMessage]) -> String {
    messages.reversed().compactMap(previewText(from:)).first ?? ""
  }

  private static func previewText(from message: ChatMessage) -> String? {
    guard message.role == .user || message.role == .assistant else { return nil }
    let text = MessageContentFilter.previewText(from: message.text)
    guard !text.isEmpty else { return nil }
    return text
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
  var toolsEnabled: Bool = true
  var enabledTools: Set<BuiltInToolID> = AppSettings.defaultTools
  var usesStreaming: Bool = true
  var isPinned: Bool = false
  var enabledMCPServers: Set<UUID> = AppSettings.defaultMCPServers
  var enabledMCPTools: Set<String> = AppSettings.defaultMCPTools
  var disabledMCPTools: Set<String> = []
  var reasoningLevel: ReasoningLevel = .automatic
  var showThinking: Bool = false
  var lastContextSignature: String? = nil
  var isArchived: Bool = false
  var languageOverrideIdentifier: String? = nil

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
    case toolsEnabled
    case enabledTools
    case usesStreaming
    case isPinned
    case enabledMCPServers
    case enabledMCPTools
    case disabledMCPTools
    case reasoningLevel
    case showThinking
    case lastContextSignature
    case lastToolContextSignature
    case isArchived
    case languageOverrideIdentifier
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
    toolsEnabled = (try? container.decode(Bool.self, forKey: .toolsEnabled)) ?? true
    enabledTools = try container.decode(Set<BuiltInToolID>.self, forKey: .enabledTools)
    usesStreaming = try container.decode(Bool.self, forKey: .usesStreaming)
    isPinned = (try? container.decode(Bool.self, forKey: .isPinned)) ?? false
    enabledMCPServers =
      (try? container.decode(Set<UUID>.self, forKey: .enabledMCPServers)) ?? []
    enabledMCPTools =
      (try? container.decode(Set<String>.self, forKey: .enabledMCPTools)) ?? []
    disabledMCPTools =
      (try? container.decode(Set<String>.self, forKey: .disabledMCPTools)) ?? []
    reasoningLevel =
      (try? container.decode(ReasoningLevel.self, forKey: .reasoningLevel)) ?? .automatic
    showThinking = (try? container.decode(Bool.self, forKey: .showThinking)) ?? false
    lastContextSignature =
      (try? container.decodeIfPresent(String.self, forKey: .lastContextSignature))
      ?? (try? container.decodeIfPresent(String.self, forKey: .lastToolContextSignature))
    isArchived = (try? container.decode(Bool.self, forKey: .isArchived)) ?? false
    let decodedLanguageOverride =
      (try? container.decodeIfPresent(String.self, forKey: .languageOverrideIdentifier)) ?? nil
    languageOverrideIdentifier = Self.normalizedLanguageOverride(decodedLanguageOverride)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(title, forKey: .title)
    try container.encode(messages, forKey: .messages)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(updatedAt, forKey: .updatedAt)
    try container.encode(provider, forKey: .provider)
    try container.encode(modelID, forKey: .modelID)
    try container.encodeIfPresent(endpointID, forKey: .endpointID)
    try container.encodeIfPresent(systemPromptID, forKey: .systemPromptID)
    try container.encode(toolsEnabled, forKey: .toolsEnabled)
    try container.encode(enabledTools, forKey: .enabledTools)
    try container.encode(usesStreaming, forKey: .usesStreaming)
    try container.encode(isPinned, forKey: .isPinned)
    try container.encode(enabledMCPServers, forKey: .enabledMCPServers)
    try container.encode(enabledMCPTools, forKey: .enabledMCPTools)
    try container.encode(disabledMCPTools, forKey: .disabledMCPTools)
    try container.encode(reasoningLevel, forKey: .reasoningLevel)
    try container.encode(showThinking, forKey: .showThinking)
    try container.encodeIfPresent(lastContextSignature, forKey: .lastContextSignature)
    try container.encode(isArchived, forKey: .isArchived)
    try container.encodeIfPresent(
      Self.normalizedLanguageOverride(languageOverrideIdentifier),
      forKey: .languageOverrideIdentifier)
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

  var effectiveLanguageOverrideIdentifier: String? {
    Self.normalizedLanguageOverride(languageOverrideIdentifier)
  }

  static func normalizedLanguageOverride(_ identifier: String?) -> String? {
    SystemLanguageSupport.normalizedLanguageIdentifier(identifier)
  }
}

extension ConversationSettings {
  func applyingLanguageOverride(from conversation: Conversation?) -> ConversationSettings {
    guard let identifier = conversation?.effectiveLanguageOverrideIdentifier else { return self }
    var copy = self
    copy.speechRecognitionLanguageIdentifier = identifier
    return copy
  }
}

extension RoleVoiceSettings {
  func applyingLanguageOverride(_ identifier: String?) -> RoleVoiceSettings {
    guard provider == .system,
      let identifier = SystemLanguageSupport.normalizedLanguageIdentifier(identifier)
    else {
      return self
    }
    var copy = self
    copy.language = identifier
    copy.voiceIdentifier = ""
    return copy
  }
}

extension VoiceSettings {
  func applyingLanguageOverride(_ identifier: String?) -> VoiceSettings {
    var copy = self
    copy.user = copy.user.applyingLanguageOverride(identifier)
    copy.assistant = copy.assistant.applyingLanguageOverride(identifier)
    return copy
  }
}

extension NativeToolSettings {
  func applyingLanguageOverride(from conversation: Conversation?) -> NativeToolSettings {
    guard let identifier = conversation?.effectiveLanguageOverrideIdentifier else { return self }
    var copy = self
    copy.voices = copy.voices.applyingLanguageOverride(identifier)
    return copy
  }
}

enum EndpointAuthMethod: String, Codable, CaseIterable, Identifiable, Sendable {
  case apiKey
  case oauth

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .apiKey: "API Key"
    case .oauth: "OpenAI Auth (Auth0)"
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
  var authMethod: EndpointAuthMethod
  var oauthIssuer: String
  var oauthClientID: String
  var oauthAudience: String
  var oauthScope: String
  var oauthRedirectURI: String
  var oauthRefreshToken: String
  var oauthAccessTokenExpiresAt: Date?

  init(
    id: UUID = UUID(),
    name: String = "",
    baseURL: String = "https://api.openai.com/v1",
    apiKey: String = "",
    defaultModel: String = "",
    defaultReasoningLevel: ReasoningLevel = .automatic,
    isEnabled: Bool = true,
    authMethod: EndpointAuthMethod = .apiKey,
    oauthIssuer: String = "",
    oauthClientID: String = "",
    oauthAudience: String = "",
    oauthScope: String = "",
    oauthRedirectURI: String = "",
    oauthRefreshToken: String = "",
    oauthAccessTokenExpiresAt: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.defaultModel = defaultModel
    self.defaultReasoningLevel = defaultReasoningLevel
    self.isEnabled = isEnabled
    self.authMethod = authMethod
    self.oauthIssuer = oauthIssuer
    self.oauthClientID = oauthClientID
    self.oauthAudience = oauthAudience
    self.oauthScope = oauthScope
    self.oauthRedirectURI = oauthRedirectURI
    self.oauthRefreshToken = oauthRefreshToken
    self.oauthAccessTokenExpiresAt = oauthAccessTokenExpiresAt
  }

  enum CodingKeys: String, CodingKey {
    case id, name, baseURL, apiKey, defaultModel, defaultReasoningLevel, isEnabled
    case authMethod, oauthIssuer, oauthClientID, oauthAudience, oauthScope, oauthRedirectURI
    case oauthRefreshToken, oauthAccessTokenExpiresAt
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
    authMethod = (try? c.decode(EndpointAuthMethod.self, forKey: .authMethod)) ?? .apiKey
    oauthIssuer = (try? c.decode(String.self, forKey: .oauthIssuer)) ?? ""
    oauthClientID = (try? c.decode(String.self, forKey: .oauthClientID)) ?? ""
    oauthAudience = (try? c.decode(String.self, forKey: .oauthAudience)) ?? ""
    oauthScope = (try? c.decode(String.self, forKey: .oauthScope)) ?? ""
    oauthRedirectURI = (try? c.decode(String.self, forKey: .oauthRedirectURI)) ?? ""
    oauthRefreshToken = (try? c.decode(String.self, forKey: .oauthRefreshToken)) ?? ""
    oauthAccessTokenExpiresAt =
      try? c.decode(Date.self, forKey: .oauthAccessTokenExpiresAt)
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
    try c.encode(authMethod, forKey: .authMethod)
    try c.encode(oauthIssuer, forKey: .oauthIssuer)
    try c.encode(oauthClientID, forKey: .oauthClientID)
    try c.encode(oauthAudience, forKey: .oauthAudience)
    try c.encode(oauthScope, forKey: .oauthScope)
    try c.encode(oauthRedirectURI, forKey: .oauthRedirectURI)
    try c.encode(oauthRefreshToken, forKey: .oauthRefreshToken)
    try c.encodeIfPresent(oauthAccessTokenExpiresAt, forKey: .oauthAccessTokenExpiresAt)
  }

  static let openAIAuthDefaults = OpenAIAuth0Defaults(
    issuer: "https://auth.openai.com",
    clientID: "",
    audience: "https://api.openai.com/v1",
    scope: "openid profile email offline_access",
    redirectURI: "pocketmai://oauth/callback",
    baseURL: "https://api.openai.com/v1"
  )

  var hasOAuthAccessToken: Bool {
    authMethod == .oauth
      && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var oauthAccessTokenExpired: Bool {
    guard authMethod == .oauth, let expiry = oauthAccessTokenExpiresAt else { return false }
    return expiry <= Date()
  }
}

struct OpenAIAuth0Defaults: Sendable {
  let issuer: String
  let clientID: String
  let audience: String
  let scope: String
  let redirectURI: String
  let baseURL: String
}

struct ConversationExportEnvelope: Codable, Equatable, Sendable {
  static let format = "pocketmai.conversation"

  var format: String
  var title: String
  var model: String
  var provider: String
  var exportedAt: Date
  var createdAt: Date
  var pocketMaiVersion: String
  var conversation: Conversation
  var toolCallingDebug: ConversationToolCallingDebug?

  init(
    conversation: Conversation,
    exportedAt: Date = Date(),
    pocketMaiVersion: String = Self.currentPocketMaiVersion,
    toolCallingDebug: ConversationToolCallingDebug? = nil
  ) {
    self.format = Self.format
    self.title = conversation.displayTitle
    self.model = conversation.modelID
    self.provider = conversation.provider.rawValue
    self.exportedAt = exportedAt
    self.createdAt = conversation.createdAt
    self.pocketMaiVersion = pocketMaiVersion
    self.conversation = conversation
    self.toolCallingDebug = toolCallingDebug
  }

  var providerDisplayName: String {
    ProviderKind(rawValue: provider)?.displayName ?? provider
  }

  static var currentPocketMaiVersion: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "Unknown"
    guard let build = info?["CFBundleVersion"] as? String,
      !build.isEmpty,
      build != short
    else {
      return short
    }
    return "\(short) (\(build))"
  }
}

struct ConversationToolCallingDebug: Codable, Equatable, Sendable {
  var selectedMode: String
  var selectedModeDisplayName: String
  var effectiveMode: String
  var effectiveModeDisplayName: String
  var textProtocolFallback: String
  var providerNativeToolCalling: Bool
  var nativeToolCallingUnavailableReason: String?
  var toolCatalogInlinedInPrompt: Bool
  var nativeToolNames: [String]
  var maxToolCallsPerTurn: Int
  var maxRepairTurnsPerTurn: Int
  var yoloModeEnabled: Bool
  var useToolProxy: Bool
  var airplaneModeEnabled: Bool
  var contextWindowMode: String
  var contextWindowMessageLimit: Int?
  var includeAssistantResponsesInContext: Bool?
  var includeReasoningContentInContext: Bool?
  var defaultEnabledTools: [String]
  var defaultEnabledMCPServers: [String]
  var defaultEnabledMCPTools: [String]
  var toolsEnabled: Bool
  var enabledTools: [String]
  var enabledMCPServers: [String]
  var enabledMCPTools: [String]
  var disabledMCPTools: [String]
  var mcpServers: [ConversationDebugMCPServer]
  var nativeToolSettings: ConversationDebugNativeToolSettings
  var fullToolDefinitions: [ConversationDebugToolDefinition]
  var visibleToolDefinitions: [ConversationDebugToolDefinition]
  var toolPrompt: String
  var contextPrompt: String
  var contextSignature: String
  var lastStoredContextSignature: String?
  var systemPrompt: String
  var providerSystemPrompt: String
  var applePrompt: String?
  var promptMessages: [ConversationDebugPromptMessage]
  var iterations: [ConversationDebugToolIteration]
  var notes: [String]
}

struct ConversationDebugNativeToolSettings: Codable, Equatable, Sendable {
  var includeTimeZone: Bool
  var includeMoonPhase: Bool
  var useGPSLocation: Bool
  var manualLocationConfigured: Bool
  var weatherLocationConfigured: Bool
  var webSearchProvider: String
  var webSearchSearXNGURLConfigured: Bool
  var webSearchSearXNGURLHost: String?
  var webSearchSearXNGUsernameConfigured: Bool
  var webSearchSearXNGPasswordConfigured: Bool
  var webSearchFetchingEnabled: Bool
  var filesWorkspaceAccessEnabled: Bool
  var configuredToolFilesCount: Int
  var todoCount: Int
}

struct ConversationDebugMCPServer: Codable, Equatable, Sendable {
  var id: UUID
  var name: String
  var isEnabled: Bool
  var hasValidScheme: Bool
}

struct ConversationDebugToolDefinition: Codable, Equatable, Sendable {
  var name: String
  var description: String
  var parameters: [ConversationDebugToolParameter]
  var inputSchemaJSON: String?
}

struct ConversationDebugToolParameter: Codable, Equatable, Sendable {
  var name: String
  var type: String
  var description: String
  var required: Bool
}

struct ConversationDebugPromptMessage: Codable, Equatable, Sendable {
  var role: String
  var content: String
  var reasoningContent: String? = nil
  var toolCallsJSON: String? = nil
  var toolCallID: String? = nil
}

struct ConversationDebugParsedToolCall: Codable, Equatable, Sendable {
  var name: String
  var argumentsJSON: String
  var rawBlock: String
}

struct ConversationDebugToolIteration: Codable, Equatable, Sendable {
  var assistantMessageID: UUID
  var assistantMessageIndex: Int
  var roundIndex: Int
  var source: String = "storedToolRun"
  var createdAt: Date? = nil
  var provider: String? = nil
  var model: String? = nil
  var selectedMode: String? = nil
  var effectiveMode: String? = nil
  var maxToolCallsPerTurn: Int? = nil
  var maxRepairTurnsPerTurn: Int? = nil
  var yoloModeEnabled: Bool? = nil
  var useToolProxy: Bool? = nil
  var nativeToolCallingUnavailableReason: String? = nil
  var requestContext: String? = nil
  var toolPrompt: String? = nil
  var nativeToolNames: [String] = []
  var visibleToolDefinitions: [ConversationDebugToolDefinition]? = nil
  var promptMessages: [ConversationDebugPromptMessage] = []
  var rawModelResponse: String? = nil
  var parsedToolCalls: [ConversationDebugParsedToolCall] = []
  var outcome: String? = nil
  var toolName: String
  var argumentsJSON: String
  var result: String
  var isError: Bool
  var rawBlock: String
}

struct ConversationImportConflict: Equatable, Sendable {
  var existingID: UUID
  var existingTitle: String
  var contentsMatch: Bool
}

struct ConversationImportPreview: Identifiable, Sendable {
  let id = UUID()
  var envelope: ConversationExportEnvelope
  var conflict: ConversationImportConflict?
  var existingTitles: [String] = []

  var conversation: Conversation {
    envelope.conversation
  }

  var suggestedRenameTitle: String {
    let title = envelope.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = title.isEmpty ? "Imported conversation" : title
    guard conflict != nil else { return base }
    return "\(base) (Imported)"
  }
}

enum ConversationImportResolution: Sendable {
  case create(title: String)
  case updateExisting
}

enum SettingsBackupScope: String, CaseIterable, Sendable {
  case everything
  case providers
  case prompts
  case tools
  case conversations
}

struct SettingsProvidersBackup: Codable, Sendable {
  var endpoints: [OpenAIEndpoint]
  var selectedEndpointID: UUID?
  var defaultProvider: ProviderKind?
}

struct SettingsPromptsBackup: Codable, Sendable {
  var prompts: [SystemPrompt]
  var defaultSystemPromptID: UUID?
  var compactPrompt: String?
}

struct SettingsToolsBackup: Codable, Sendable {
  var toolSettings: NativeToolSettings
  var mcpServers: [MCPServer]
  var defaultEnabledTools: Set<BuiltInToolID>?
  var defaultEnabledMCPServers: Set<UUID>?
  var defaultEnabledMCPTools: Set<String>?
  var toolCallingMode: ToolCallingMode?
  var maxToolCallsPerTurn: Int?
  var yoloModeEnabled: Bool?
  var useToolProxy: Bool?
}

struct SettingsVoiceRecordingAttachment: Codable, Sendable {
  var filename: String
  var dataBase64: String
}

struct SettingsBackupEnvelope: Codable, Sendable {
  static let format = "pocketmai.backup"
  static let currentVersion = 1

  var format: String
  var version: Int
  var exportedAt: Date
  var pocketMaiVersion: String
  var providers: SettingsProvidersBackup?
  var prompts: SettingsPromptsBackup?
  var tools: SettingsToolsBackup?
  var conversations: [Conversation]?
  var voiceRecordings: [SettingsVoiceRecordingAttachment]?

  init(
    providers: SettingsProvidersBackup? = nil,
    prompts: SettingsPromptsBackup? = nil,
    tools: SettingsToolsBackup? = nil,
    conversations: [Conversation]? = nil,
    voiceRecordings: [SettingsVoiceRecordingAttachment]? = nil,
    exportedAt: Date = Date(),
    pocketMaiVersion: String = ConversationExportEnvelope.currentPocketMaiVersion
  ) {
    self.format = Self.format
    self.version = Self.currentVersion
    self.exportedAt = exportedAt
    self.pocketMaiVersion = pocketMaiVersion
    self.providers = providers
    self.prompts = prompts
    self.tools = tools
    self.conversations = conversations
    self.voiceRecordings = voiceRecordings
  }
}

enum SettingsBackupError: LocalizedError {
  case unreadableFile
  case invalidJSON
  case missingSection(SettingsBackupScope)

  var errorDescription: String? {
    switch self {
    case .unreadableFile: return "The selected file could not be read."
    case .invalidJSON: return "The selected file is not a valid PocketMai backup."
    case .missingSection(let scope):
      return "The backup does not contain \(scope.sectionName)."
    }
  }
}

extension SettingsBackupScope {
  var sectionName: String {
    switch self {
    case .everything: return "any data"
    case .providers: return "provider settings"
    case .prompts: return "system prompts"
    case .tools: return "tool settings"
    case .conversations: return "conversations"
    }
  }
}

extension OpenAIEndpoint {
  static let defaultDisplayName = "New Provider"

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

  var displayName: String {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedName.isEmpty ? "Untitled" : trimmedName
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

enum MCPToolSelection {
  static func key(serverID: UUID, toolName: String) -> String {
    "\(serverID.uuidString):\(toolName)"
  }

  static func prefix(serverID: UUID) -> String {
    "\(serverID.uuidString):"
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

enum TTSVoiceProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case system
  case openAICompatible

  var id: String { rawValue }
}

struct RoleVoiceSettings: Codable, Equatable, Sendable {
  var provider: TTSVoiceProviderKind = .system
  var language: String = ""
  var voiceIdentifier: String = ""
  var openAIEndpointID: UUID? = nil
  var openAIVoice: String = ""
  var rate: Double = 0.5
  var pitch: Double = 1.0

  init(
    provider: TTSVoiceProviderKind = .system,
    language: String = "",
    voiceIdentifier: String = "",
    openAIEndpointID: UUID? = nil,
    openAIVoice: String = "",
    rate: Double = 0.5,
    pitch: Double = 1.0
  ) {
    self.provider = provider
    self.language = language
    self.voiceIdentifier = voiceIdentifier
    self.openAIEndpointID = openAIEndpointID
    self.openAIVoice = openAIVoice
    self.rate = rate
    self.pitch = pitch
  }

  enum CodingKeys: String, CodingKey {
    case provider, language, voiceIdentifier, openAIEndpointID, openAIVoice, rate, pitch
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    provider = (try? c.decode(TTSVoiceProviderKind.self, forKey: .provider)) ?? .system
    language = (try? c.decode(String.self, forKey: .language)) ?? ""
    voiceIdentifier = (try? c.decode(String.self, forKey: .voiceIdentifier)) ?? ""
    openAIEndpointID = try? c.decode(UUID.self, forKey: .openAIEndpointID)
    openAIVoice = (try? c.decode(String.self, forKey: .openAIVoice)) ?? ""
    rate = (try? c.decode(Double.self, forKey: .rate)) ?? 0.5
    pitch = (try? c.decode(Double.self, forKey: .pitch)) ?? 1.0
  }

  static let defaults = RoleVoiceSettings()

  func withoutOnlineProvider() -> RoleVoiceSettings {
    guard provider == .openAICompatible else { return self }
    var copy = self
    copy.provider = .system
    return copy
  }
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
  var includeMoonPhase: Bool = true
  var useGPSLocation: Bool = false
  var manualLocation: String = ""
  var weatherLocation: String = ""
  var webSearchProvider: WebSearchProvider = .duckDuckGo
  var webSearchSearXNGURL: String = ""
  var webSearchSearXNGUsername: String = ""
  var webSearchSearXNGPassword: String = ""
  var webSearchFetchingEnabled: Bool = false
  var todos: [TodoItem] = []
  var files: [ToolFile] = []
  var filesWorkspaceAccessEnabled: Bool = false
  var voices: VoiceSettings = .defaults

  static let defaults = NativeToolSettings()

  init() {}

  enum CodingKeys: String, CodingKey {
    case includeTimeZone, includeMoonPhase, includeCurrentTime, includeYear, useGPSLocation
    case manualLocation, weatherLocation, webSearchProvider
    case webSearchSearXNGURL, webSearchSearXNGUsername, webSearchSearXNGPassword
    case webSearchFetchingEnabled, todos, files
    case filesWorkspaceAccessEnabled
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
    includeMoonPhase =
      (try? c.decode(Bool.self, forKey: .includeMoonPhase))
      ?? (try? c.decode(Bool.self, forKey: .includeYear))
      ?? defaults.includeMoonPhase
    useGPSLocation = (try? c.decode(Bool.self, forKey: .useGPSLocation)) ?? defaults.useGPSLocation
    manualLocation =
      (try? c.decode(String.self, forKey: .manualLocation)) ?? defaults.manualLocation
    weatherLocation =
      (try? c.decode(String.self, forKey: .weatherLocation)) ?? defaults.weatherLocation
    webSearchProvider =
      (try? c.decode(WebSearchProvider.self, forKey: .webSearchProvider))
      ?? defaults.webSearchProvider
    webSearchSearXNGURL =
      (try? c.decode(String.self, forKey: .webSearchSearXNGURL))
      ?? defaults.webSearchSearXNGURL
    webSearchSearXNGUsername =
      (try? c.decode(String.self, forKey: .webSearchSearXNGUsername))
      ?? defaults.webSearchSearXNGUsername
    webSearchSearXNGPassword =
      (try? c.decode(String.self, forKey: .webSearchSearXNGPassword))
      ?? defaults.webSearchSearXNGPassword
    webSearchFetchingEnabled =
      (try? c.decode(Bool.self, forKey: .webSearchFetchingEnabled))
      ?? defaults.webSearchFetchingEnabled
    todos = (try? c.decode([TodoItem].self, forKey: .todos)) ?? defaults.todos
    files = (try? c.decode([ToolFile].self, forKey: .files)) ?? defaults.files
    filesWorkspaceAccessEnabled =
      (try? c.decode(Bool.self, forKey: .filesWorkspaceAccessEnabled))
      ?? defaults.filesWorkspaceAccessEnabled

    if let decoded = try? c.decode(VoiceSettings.self, forKey: .voices) {
      voices = decoded
    } else if let legacy = try? decoder.container(keyedBy: LegacyCodingKeys.self) {
      // Migrate from the previous flat textToSpeech* fields. Both roles seed
      // from the same legacy values so the user has a consistent starting
      // point and can diverge them later.
      let legacyVoice = RoleVoiceSettings(
        language: (try? legacy.decode(String.self, forKey: .textToSpeechLanguage)) ?? "",
        voiceIdentifier: (try? legacy.decode(String.self, forKey: .textToSpeechVoiceIdentifier))
          ?? "",
        rate: (try? legacy.decode(Double.self, forKey: .textToSpeechRate))
          ?? RoleVoiceSettings.defaults.rate,
        pitch: (try? legacy.decode(Double.self, forKey: .textToSpeechPitch))
          ?? RoleVoiceSettings.defaults.pitch)
      voices = VoiceSettings(user: legacyVoice, assistant: legacyVoice)
    } else {
      voices = defaults.voices
    }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(includeTimeZone, forKey: .includeTimeZone)
    try c.encode(includeMoonPhase, forKey: .includeMoonPhase)
    try c.encode(useGPSLocation, forKey: .useGPSLocation)
    try c.encode(manualLocation, forKey: .manualLocation)
    try c.encode(weatherLocation, forKey: .weatherLocation)
    try c.encode(webSearchProvider, forKey: .webSearchProvider)
    try c.encode(webSearchSearXNGURL, forKey: .webSearchSearXNGURL)
    try c.encode(webSearchSearXNGUsername, forKey: .webSearchSearXNGUsername)
    try c.encode(webSearchSearXNGPassword, forKey: .webSearchSearXNGPassword)
    try c.encode(webSearchFetchingEnabled, forKey: .webSearchFetchingEnabled)
    try c.encode(todos, forKey: .todos)
    try c.encode(files, forKey: .files)
    try c.encode(filesWorkspaceAccessEnabled, forKey: .filesWorkspaceAccessEnabled)
    try c.encode(voices, forKey: .voices)
  }
}

struct AppSettings: Codable, Equatable, Sendable {
  static let currentSettingsVersion = 1
  static let appleDefaultModelID = ""
  static let localMLXDefaultModelID = "LiquidAI/LFM2.5-1.2B-Instruct-MLX-4bit"
  static let defaultTools: Set<BuiltInToolID> = []
  static let defaultMCPServers: Set<UUID> = []
  static let defaultMCPTools: Set<String> = []
  static let defaultSystemPrompt = SystemPrompt(
    name: "Helpful assistant",
    text:
      "You are a helpful, concise assistant for a private text-only chat app. Prefer clear answers and preserve useful formatting."
  )
  static let defaultCompactPrompt = """
    Compact the transcript below into durable context for continuing the same chat.

    Output only the compacted context. Do not include hidden reasoning, XML tags, prompt scaffolding, or commentary about the task.

    Preserve:
    - User goals, preferences, constraints, and decisions
    - Important names, projects, files, commands, code snippets, errors, and results
    - Current state, unresolved questions, and next steps

    Drop greetings, filler, repeated text, tool protocol blocks, and implementation details that no longer matter. Write concise bullets grouped by topic when useful.

    Transcript:

    {{transcript}}
    """

  var defaultProvider: ProviderKind = .apple
  var appleModelID: String = AppSettings.appleDefaultModelID
  var localMLXModelID: String = AppSettings.localMLXDefaultModelID
  var selectedEndpointID: UUID? = nil
  var streamByDefault: Bool = true
  var showThinkingByDefault: Bool = false
  var openAIEndpoints: [OpenAIEndpoint] = []
  var systemPrompts: [SystemPrompt] = [AppSettings.defaultSystemPrompt]
  var defaultSystemPromptID: UUID = AppSettings.defaultSystemPrompt.id
  var compactPrompt: String = AppSettings.defaultCompactPrompt
  var defaultEnabledTools: Set<BuiltInToolID> = AppSettings.defaultTools
  var settingsVersion: Int = AppSettings.currentSettingsVersion
  var defaultEnabledMCPServers: Set<UUID> = AppSettings.defaultMCPServers
  var defaultEnabledMCPTools: Set<String> = AppSettings.defaultMCPTools
  var toolSettings: NativeToolSettings = .defaults
  var mcpServers: [MCPServer] = []
  var memory: String = ""
  var toolCallingMode: ToolCallingMode = .text
  var maxToolCallsPerTurn: Int = 8
  var yoloModeEnabled: Bool = true
  var useToolProxy: Bool = false
  var contextWindowMode: ContextWindowMode = .full
  var includeAssistantResponsesInContext: Bool = true
  var includeReasoningContentInContext: Bool = true
  var appearance: AppearanceSettings = .defaults
  var conversation: ConversationSettings = .defaults
  var renderMarkdownInChat: Bool = true
  var airplaneModeEnabled: Bool = false
  var attachmentImageSize: AttachmentImageSize = .medium
  var mlxMaxKVSize: MLXKVCacheSize = .auto
  var mlxAutoCompact: Bool = false

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

  var defaultProviderConfiguration: (provider: ProviderKind, endpointID: UUID?, modelID: String) {
    if airplaneModeEnabled && !defaultProvider.isAirplaneModeEligible {
      return (.apple, nil, appleModelID)
    }
    switch defaultProvider {
    case .apple:
      return (.apple, nil, appleModelID)
    case .mlx:
      return (.mlx, nil, localMLXModelID)
    case .openAICompatible:
      guard let endpoint = defaultOpenAIEndpoint else {
        return (.apple, nil, appleModelID)
      }
      return (.openAICompatible, endpoint.id, endpoint.defaultModel)
    }
  }

  enum CodingKeys: String, CodingKey {
    case settingsVersion
    case defaultProvider, appleModelID, localMLXModelID, selectedEndpointID, streamByDefault,
      showThinkingByDefault
    case openAIEndpoints, systemPrompts, defaultSystemPromptID, compactPrompt, defaultEnabledTools
    case defaultEnabledMCPServers, defaultEnabledMCPTools
    case toolSettings, mcpServers, memory, toolCallingMode, maxToolCallsPerTurn
    case yoloModeEnabled, useToolProxy, contextWindowMode
    case includeAssistantResponsesInContext, includeReasoningContentInContext
    case appearance, conversation, renderMarkdownInChat
    case airplaneModeEnabled, attachmentImageSize
    case mlxMaxKVSize, mlxAutoCompact
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let storedSettingsVersion =
      (try? c.decode(Int.self, forKey: .settingsVersion)) ?? 0
    settingsVersion = Self.currentSettingsVersion
    defaultProvider =
      (try? c.decode(ProviderKind.self, forKey: .defaultProvider)) ?? .apple
    appleModelID = (try? c.decode(String.self, forKey: .appleModelID)) ?? ""
    localMLXModelID =
      (try? c.decode(String.self, forKey: .localMLXModelID))
      ?? AppSettings.localMLXDefaultModelID
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
    compactPrompt =
      (try? c.decode(String.self, forKey: .compactPrompt)) ?? AppSettings.defaultCompactPrompt
    let decodedDefaultEnabledTools =
      (try? c.decode(Set<BuiltInToolID>.self, forKey: .defaultEnabledTools))
      ?? AppSettings.defaultTools
    defaultEnabledTools =
      storedSettingsVersion < Self.currentSettingsVersion
      ? AppSettings.defaultTools : decodedDefaultEnabledTools
    let decodedDefaultEnabledMCPServers =
      (try? c.decode(Set<UUID>.self, forKey: .defaultEnabledMCPServers))
      ?? AppSettings.defaultMCPServers
    let decodedDefaultEnabledMCPTools =
      (try? c.decode(Set<String>.self, forKey: .defaultEnabledMCPTools))
      ?? AppSettings.defaultMCPTools
    defaultEnabledMCPServers =
      storedSettingsVersion < Self.currentSettingsVersion
      ? AppSettings.defaultMCPServers : decodedDefaultEnabledMCPServers
    defaultEnabledMCPTools =
      storedSettingsVersion < Self.currentSettingsVersion
      ? AppSettings.defaultMCPTools : decodedDefaultEnabledMCPTools
    toolSettings =
      (try? c.decode(NativeToolSettings.self, forKey: .toolSettings)) ?? .defaults
    if storedSettingsVersion < Self.currentSettingsVersion {
      toolSettings.webSearchFetchingEnabled = false
      toolSettings.filesWorkspaceAccessEnabled = false
    }
    mcpServers = (try? c.decode([MCPServer].self, forKey: .mcpServers)) ?? []
    memory = (try? c.decode(String.self, forKey: .memory)) ?? ""
    let storedMode = (try? c.decode(String.self, forKey: .toolCallingMode)) ?? "text"
    let migratedFromLegacyProxy = (storedMode == "proxy")
    toolCallingMode =
      ToolCallingMode(rawValue: storedMode) ?? .text
    maxToolCallsPerTurn =
      min(20, max(1, (try? c.decode(Int.self, forKey: .maxToolCallsPerTurn)) ?? 8))
    yoloModeEnabled =
      (try? c.decode(Bool.self, forKey: .yoloModeEnabled)) ?? true
    useToolProxy =
      (try? c.decode(Bool.self, forKey: .useToolProxy)) ?? migratedFromLegacyProxy
    contextWindowMode =
      (try? c.decode(ContextWindowMode.self, forKey: .contextWindowMode)) ?? .full
    includeAssistantResponsesInContext =
      (try? c.decode(Bool.self, forKey: .includeAssistantResponsesInContext)) ?? true
    includeReasoningContentInContext =
      (try? c.decode(Bool.self, forKey: .includeReasoningContentInContext)) ?? true
    appearance =
      (try? c.decode(AppearanceSettings.self, forKey: .appearance)) ?? .defaults
    conversation =
      (try? c.decode(ConversationSettings.self, forKey: .conversation)) ?? .defaults
    renderMarkdownInChat =
      (try? c.decode(Bool.self, forKey: .renderMarkdownInChat)) ?? true
    airplaneModeEnabled =
      (try? c.decode(Bool.self, forKey: .airplaneModeEnabled)) ?? false
    attachmentImageSize =
      (try? c.decode(AttachmentImageSize.self, forKey: .attachmentImageSize)) ?? .medium
    mlxMaxKVSize =
      (try? c.decode(MLXKVCacheSize.self, forKey: .mlxMaxKVSize)) ?? .auto
    mlxAutoCompact = (try? c.decode(Bool.self, forKey: .mlxAutoCompact)) ?? false
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
