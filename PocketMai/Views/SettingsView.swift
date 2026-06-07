import AVFoundation
import Speech
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum DefaultProviderSelection: Hashable {
  case apple
  case mlx
  case endpoint(UUID)
}

struct EndpointProviderPreset {
  let name: String
  let url: String
  let authMethods: [EndpointAuthMethod]
  let oauthDefaults: OAuthPresetDefaults?
  let preferredAuthMethod: EndpointAuthMethod?

  init(
    name: String,
    url: String,
    authMethods: [EndpointAuthMethod] = [.apiKey],
    oauthDefaults: OAuthPresetDefaults? = nil,
    preferredAuthMethod: EndpointAuthMethod? = nil
  ) {
    self.name = name
    self.url = url
    self.authMethods = authMethods
    self.oauthDefaults = oauthDefaults
    self.preferredAuthMethod = preferredAuthMethod
  }

  var tag: String {
    url
  }
}

private struct PendingSettingsDeletion: Identifiable {
  let id = UUID()
  let kind: SettingsDeletionKind
  let offsets: IndexSet
}

private enum SettingsRoute: Hashable {
  case endpoint(UUID)
  case mcpServer(UUID)
}

private enum SettingsDeletionKind {
  case endpoint
  case systemPrompt
  case userPrompt
  case file
  case mcpServer

  var title: String {
    switch self {
    case .endpoint: "Delete provider?"
    case .systemPrompt: "Delete system prompt?"
    case .userPrompt: "Delete user prompt?"
    case .file: "Delete file?"
    case .mcpServer: "Delete MCP server?"
    }
  }

  func buttonTitle(count: Int) -> String {
    switch self {
    case .endpoint: "Delete \(itemName("Provider", count: count))"
    case .systemPrompt: "Delete \(itemName("Prompt", count: count))"
    case .userPrompt: "Delete \(itemName("Prompt", count: count))"
    case .file: "Delete \(itemName("File", count: count))"
    case .mcpServer: "Delete \(itemName("Server", count: count))"
    }
  }

  func message(count: Int) -> String {
    switch self {
    case .endpoint:
      "\(count) provider\(count == 1 ? "" : "s") will be removed. This cannot be undone."
    case .systemPrompt:
      "\(count) system prompt\(count == 1 ? "" : "s") will be removed. This cannot be undone."
    case .userPrompt:
      "\(count) user prompt\(count == 1 ? "" : "s") will be removed. This cannot be undone."
    case .file:
      "\(count) imported file\(count == 1 ? "" : "s") will be removed. This cannot be undone."
    case .mcpServer:
      "\(count) MCP server\(count == 1 ? "" : "s") will be removed. This cannot be undone."
    }
  }

  private func itemName(_ singular: String, count: Int) -> String {
    count == 1 ? singular : "\(count) \(singular)s"
  }
}

let endpointProviderPresets: [EndpointProviderPreset] = [
  EndpointProviderPreset(
    name: "OpenAI",
    url: "https://api.openai.com/v1",
    authMethods: [.apiKey, .oauth],
    oauthDefaults: OpenAIEndpoint.openAIAuthDefaults
  ),
  EndpointProviderPreset(name: "Ollama", url: "http://localhost:11434/v1"),
  EndpointProviderPreset(name: "Ollama Cloud", url: "https://ollama.com/v1"),
  EndpointProviderPreset(name: "OpenRouter", url: "https://openrouter.ai/api/v1"),
  EndpointProviderPreset(name: "OpenCode Zen", url: "https://opencode.ai/zen/v1"),
  EndpointProviderPreset(name: "Hugging Face", url: "https://router.huggingface.co/v1"),
  EndpointProviderPreset(
    name: "Anthropic",
    url: OpenAIEndpoint.anthropicOAuthDefaults.baseURL,
    oauthDefaults: OpenAIEndpoint.anthropicOAuthDefaults
  ),
  EndpointProviderPreset(
    name: "Google Gemini",
    url: "https://generativelanguage.googleapis.com/v1beta/openai"
  ),
  EndpointProviderPreset(
    name: "Google Vertex AI",
    url: OpenAIEndpoint.googleOAuthDefaults.baseURL,
    authMethods: [.oauth],
    oauthDefaults: OpenAIEndpoint.googleOAuthDefaults,
    preferredAuthMethod: .oauth
  ),
  EndpointProviderPreset(name: "Mistral", url: "https://api.mistral.ai/v1"),
  EndpointProviderPreset(name: "MiniMax", url: "https://api.minimax.io/v1"),
  EndpointProviderPreset(name: "xAI", url: "https://api.x.ai/v1"),
  EndpointProviderPreset(name: "DeepSeek", url: "https://api.deepseek.com/v1"),
  EndpointProviderPreset(name: "Groq", url: "https://api.groq.com/openai/v1"),
  EndpointProviderPreset(name: "Cerebras", url: "https://api.cerebras.ai/v1"),
  EndpointProviderPreset(name: "NVIDIA", url: "https://integrate.api.nvidia.com/v1"),
]

private let customProviderTag = "__custom__"

private enum TTSVoiceCache {
  static let voices: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices().sorted {
    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
  }

  static let languages: [String] = SystemLanguageSupport.textToSpeechLanguageIdentifiers

  static let primaryLanguages: [String] = {
    let primaries = Set(languages.compactMap(SystemLanguageSupport.primaryLanguageCode))
    return Array(primaries).sorted {
      primaryLanguageDisplayName($0)
        .localizedCaseInsensitiveCompare(primaryLanguageDisplayName($1)) == .orderedAscending
    }
  }()

  static func voiceOptions(for language: String) -> [AVSpeechSynthesisVoice] {
    let normalized = SystemLanguageSupport.canonicalLanguageIdentifier(language)
    let filtered =
      normalized.isEmpty
      ? voices
      : voices.filter {
        SystemLanguageSupport.canonicalLanguageIdentifier($0.language) == normalized
      }
    return filtered.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  static func variants(forPrimary primary: String) -> [String] {
    languages
      .filter { SystemLanguageSupport.primaryLanguageCode($0) == primary }
      .sorted {
        variantDisplayName($0)
          .localizedCaseInsensitiveCompare(variantDisplayName($1)) == .orderedAscending
      }
  }

  static func primaryLanguageCode(_ identifier: String) -> String? {
    SystemLanguageSupport.primaryLanguageCode(identifier)
  }

  static func primaryLanguageDisplayName(_ code: String) -> String {
    SystemLanguageSupport.primaryLanguageDisplayName(code)
  }

  static func variantDisplayName(_ identifier: String) -> String {
    SystemLanguageSupport.variantDisplayName(identifier)
  }

  static func languageDisplayName(_ language: String) -> String {
    SystemLanguageSupport.languageDisplayName(language)
  }
}

private enum VoiceTestPhrases {
  // Keyed by primary BCP-47 subtag (e.g. "es" for "es-ES").
  static let phrases: [String: String] = [
    "en": "Hello, this is a voice test.",
    "es": "Hola, esta es una prueba de voz.",
    "ca": "Hola, això és una prova de veu.",
    "fr": "Bonjour, ceci est un test vocal.",
    "de": "Hallo, das ist ein Stimmtest.",
    "it": "Ciao, questa è una prova vocale.",
    "pt": "Olá, este é um teste de voz.",
    "nl": "Hallo, dit is een stemtest.",
    "sv": "Hej, det här är ett rösttest.",
    "no": "Hei, dette er en stemmetest.",
    "da": "Hej, dette er en stemmetest.",
    "fi": "Hei, tämä on äänitesti.",
    "pl": "Cześć, to jest test głosu.",
    "tr": "Merhaba, bu bir ses testidir.",
    "ru": "Привет, это проверка голоса.",
    "uk": "Привіт, це перевірка голосу.",
    "ja": "こんにちは、これは音声テストです。",
    "zh": "你好，这是一次语音测试。",
    "ko": "안녕하세요, 이것은 음성 테스트입니다.",
    "ar": "مرحبًا، هذا اختبار للصوت.",
    "he": "שלום, זוהי בדיקת קול.",
    "hi": "नमस्ते, यह आवाज़ का परीक्षण है।",
    "th": "สวัสดี นี่คือการทดสอบเสียง",
    "vi": "Xin chào, đây là một bài kiểm tra giọng nói.",
    "id": "Halo, ini adalah tes suara.",
    "el": "Γειά σας, αυτή είναι μια δοκιμή φωνής.",
    "cs": "Ahoj, toto je hlasový test.",
    "ro": "Salut, acesta este un test de voce.",
    "hu": "Helló, ez egy hangteszt.",
  ]

  static func phrase(forLanguageTag tag: String) -> String {
    let primary = tag.split(separator: "-").first.map(String.init)?.lowercased() ?? ""
    if let exact = phrases[primary] { return exact }
    return phrases["en"] ?? "Hello, this is a voice test."
  }
}

private enum VoiceTest {
  static func tag(for role: VoiceRole) -> String {
    "settings-test:\(role.rawValue)"
  }

  static func effectiveLanguage(for voice: RoleVoiceSettings) -> String {
    if voice.provider == .openAICompatible { return Locale.current.identifier }
    if !voice.language.isEmpty { return voice.language }
    if !voice.voiceIdentifier.isEmpty,
      let v = AVSpeechSynthesisVoice(identifier: voice.voiceIdentifier)
    {
      return v.language
    }
    return Locale.current.identifier
  }

  @MainActor
  static func toggle(
    role: VoiceRole,
    voice: RoleVoiceSettings,
    openAIEndpoints: [OpenAIEndpoint],
    player: TTSPlayer
  ) {
    let tag = tag(for: role)
    if player.isPlaying(tag: tag) {
      player.stop()
      return
    }
    let phrase = VoiceTestPhrases.phrase(forLanguageTag: effectiveLanguage(for: voice))
    player.speak(
      text: phrase,
      voice: voice,
      role: role,
      title: "Voice Test",
      tag: tag,
      openAIEndpoints: openAIEndpoints)
  }
}

private enum VoiceProviderSelection: Hashable {
  case system
  case openAI(UUID)
}

struct SettingsView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @State private var showingToolFileImporter = false
  @State private var newTodoTitle = ""
  @State private var showingClearMemoryConfirmation = false
  @State private var showingBackgroundVoiceConfirmation = false
  @State private var pendingDeletion: PendingSettingsDeletion?
  @State private var navigationPath: [SettingsRoute] = []
  @State private var draftEndpoint: OpenAIEndpoint?
  @State private var draftMCPServer: MCPServer?
  @State private var toastMessage: String?

  var body: some View {
    NavigationStack(path: $navigationPath) {
      Form {
        providerSection
        appearanceSection
        toolsSection
        dangerSection
        aboutSection
      }
      .navigationDestination(for: SettingsRoute.self) { route in
        switch route {
        case .endpoint(let id):
          if let index = store.settings.openAIEndpoints.firstIndex(where: { $0.id == id }) {
            EndpointDetailView(endpoint: $store.settings.openAIEndpoints[index])
          } else if draftEndpoint?.id == id {
            EndpointDetailView(endpoint: draftEndpointBinding(for: id)) { endpoint in
              if let index = store.settings.openAIEndpoints.firstIndex(where: {
                $0.id == endpoint.id
              }) {
                store.settings.openAIEndpoints[index] = endpoint
              } else {
                store.settings.openAIEndpoints.append(endpoint)
              }
              store.settings.selectedEndpointID = endpoint.id
            }
          }
        case .mcpServer(let id):
          if let index = store.settings.mcpServers.firstIndex(where: { $0.id == id }) {
            MCPServerDetailView(server: $store.settings.mcpServers[index])
          } else if draftMCPServer?.id == id {
            MCPServerDetailView(server: draftMCPServerBinding(for: id), isNew: true) { server in
              if let index = store.settings.mcpServers.firstIndex(where: { $0.id == server.id }) {
                store.settings.mcpServers[index] = server
              } else {
                store.settings.mcpServers.append(server)
              }
              draftMCPServer = nil
            }
          }
        }
      }
      .alert(
        pendingDeletion?.kind.title ?? "Delete item?",
        isPresented: settingsDeletionConfirmationBinding,
        presenting: pendingDeletion
      ) { deletion in
        Button("Cancel", role: .cancel) {
          pendingDeletion = nil
        }
        Button(deletion.kind.buttonTitle(count: deletion.offsets.count), role: .destructive) {
          performSettingsDeletion(deletion)
        }
      } message: { deletion in
        Text(deletion.kind.message(count: deletion.offsets.count))
      }
      .alert(
        "Clear memory?",
        isPresented: $showingClearMemoryConfirmation
      ) {
        Button("Cancel", role: .cancel) {}
        Button("Clear Memory", role: .destructive) {
          store.settings.memory = ""
          store.saveSettings()
        }
      } message: {
        Text("Saved memory will be removed from this device. This cannot be undone.")
      }
      .alert(
        "Continue voice chat when locked?",
        isPresented: $showingBackgroundVoiceConfirmation
      ) {
        Button("Cancel", role: .cancel) {}
        Button("Enable") {
          enableBackgroundVoiceListening()
        }
      } message: {
        Text(
          "Voice capture can continue after the screen locks while an active voice conversation is running. Native iOS Live transcribes on device; raw microphone audio is not uploaded by PocketMai."
        )
      }
      .navigationTitle("Settings")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            toggleAirplaneMode()
          } label: {
            Label(
              store.settings.airplaneModeEnabled ? "Offline" : "Online",
              systemImage: store.settings.airplaneModeEnabled
                ? "airplane.circle.fill" : "airplane.circle"
            )
          }
          .accessibilityLabel(
            store.settings.airplaneModeEnabled
              ? "Offline mode enabled. Tap to go online."
              : "Online mode enabled. Tap to go offline."
          )
          .help(store.settings.airplaneModeEnabled ? "Go online" : "Go offline")
        }

        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { saveAndDismiss() }
        }
      }
      .settingsToast($toastMessage)
      .fileImporter(
        isPresented: $showingToolFileImporter,
        allowedContentTypes: [.text, .plainText, .json, .sourceCode]
      ) { result in
        if case .success(let url) = result {
          store.importToolFile(from: url)
        }
      }
      .onAppear {
        store.refreshLocalMLXModels()
      }
      .onChange(of: navigationPath) { _, path in
        discardDraftEndpointIfNeeded(path: path)
        discardDraftMCPServerIfNeeded(path: path)
      }
    }
    .preferredColorScheme(store.settings.appearance.theme.colorScheme)
    .tint(store.settings.appearance.tintColor)
    .accentColor(store.settings.appearance.tintColor)
  }

  @ViewBuilder
  private var advancedOptionsContent: some View {
    Toggle("Show thinking", isOn: settingsBinding(\.showThinkingByDefault))
    Toggle("Stream responses", isOn: settingsBinding(\.streamByDefault))
    Picker("Conversation Context", selection: settingsBinding(\.contextWindowMode)) {
      ForEach(ContextWindowMode.allCases) { mode in
        Text(mode.displayName).tag(mode)
      }
    }
    .pickerStyle(.menu)
    Toggle(
      "Include assistant responses",
      isOn: settingsBinding(\.includeAssistantResponsesInContext))
    Toggle(
      "Include reasoning content",
      isOn: settingsBinding(\.includeReasoningContentInContext))
    Picker("MLX KV Cache", selection: settingsBinding(\.mlxMaxKVSize)) {
      ForEach(MLXKVCacheSize.allCases) { size in
        Text(size.displayName).tag(size)
      }
    }
    .pickerStyle(.menu)
    Text(
      "Caps the token sliding window for MLX Local. Larger values retain more conversation history but use more GPU memory. Reducing this is the first fix for out-of-memory crashes."
    )
    .font(.caption)
    .foregroundStyle(.secondary)
    Toggle("Auto-Compact MLX Context", isOn: settingsBinding(\.mlxAutoCompact))
    if store.settings.mlxAutoCompact {
      Text(
        "Before each MLX response, older messages are summarized automatically when the conversation grows long, keeping the most recent exchange intact. Uses the same Compact Prompt template."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    Picker("Image Attachments", selection: settingsBinding(\.attachmentImageSize)) {
      ForEach(AttachmentImageSize.allCases) { size in
        Text(size.displayName).tag(size)
      }
    }
    .pickerStyle(.menu)
    toolCallingContent
    yoloModeContent
  }

  @ViewBuilder
  private var toolCallingContent: some View {
    Picker("Tool Calling", selection: settingsBinding(\.toolCallingMode)) {
      ForEach(ToolCallingMode.allCases) { mode in
        Text(mode.displayName).tag(mode)
      }
    }
    .pickerStyle(.menu)
    Text(store.settings.toolCallingMode.summary)
      .font(.caption)
      .foregroundStyle(.secondary)
    Stepper(value: settingsBinding(\.maxToolCallsPerTurn), in: 1...20) {
      Text("Max Tool Calls: \(store.settings.maxToolCallsPerTurn)")
    }
    Text(
      "Stops one assistant turn after this many executed tool calls, including repeated calls and multiple calls emitted in one response."
    )
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private var yoloModeContent: some View {
    Toggle("YOLO mode", isOn: settingsBinding(\.yoloModeEnabled))
    Text(
      "On: tool calls run immediately. Off: review, edit, confirm, or cancel each tool call before it runs."
    )
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private var providerSection: some View {
    Section {
      Menu {
        if store.appleIntelligenceIsAvailable {
          Button {
            defaultProviderBinding.wrappedValue = .apple
          } label: {
            Label("Apple Intelligence", systemImage: "apple.logo")
          }
        }
        Button {
          defaultProviderBinding.wrappedValue = .mlx
        } label: {
          Label("MLX Local", systemImage: "cpu")
        }
        if !store.settings.airplaneModeEnabled {
          ForEach(store.settings.openAIEndpoints.filter(\.isEnabled)) { endpoint in
            Button {
              defaultProviderBinding.wrappedValue = .endpoint(endpoint.id)
            } label: {
              Label(endpoint.displayName, systemImage: "network")
            }
          }
        }
      } label: {
        HStack {
          Text("Default")
          Spacer()
          Label(defaultProviderMenuTitle, systemImage: defaultProviderMenuIcon)
            .foregroundStyle(store.settings.airplaneModeEnabled ? .secondary : Color.accentColor)
        }
      }

      DisclosureGroup {
        endpointContent
      } label: {
        Label("Providers", systemImage: "network")
      }

      DisclosureGroup {
        promptContent
      } label: {
        Label("System Prompts", systemImage: "text.bubble")
      }

      DisclosureGroup {
        userPromptContent
      } label: {
        Label("User Prompts", systemImage: "text.quote")
      }

      DisclosureGroup {
        advancedOptionsContent
      } label: {
        Label("Advanced Options", systemImage: "slider.horizontal.3")
      }

      DisclosureGroup {
        openAPIServerContent
      } label: {
        Label("OpenAPI Server", systemImage: "server.rack")
      }
    } header: {
      Text("Inference")
    }
  }

  @ViewBuilder
  private var openAPIServerContent: some View {
    LabeledContent("Port") {
      TextField(
        "\(OpenAPIServerSettings.defaultPort)",
        value: openAPIServerPortBinding,
        format: .number
      )
      .keyboardType(.numberPad)
      .multilineTextAlignment(.trailing)
    }
    Text("Ollama and OpenAI-compatible clients can connect to this port while serving is enabled.")
      .font(.caption)
      .foregroundStyle(.secondary)

    Picker("Source", selection: settingsBinding(\.openAPIServer.conversationScope)) {
      ForEach(OpenAPIServerConversationScope.allCases) { scope in
        Text(scope.displayName).tag(scope)
      }
    }
    .pickerStyle(.menu)
    Text(store.settings.openAPIServer.conversationScope.summary)
      .font(.caption)
      .foregroundStyle(.secondary)

    Toggle(
      "Allow caller overrides",
      isOn: settingsBinding(\.openAPIServer.allowClientOverrides))
    Text(
      "Off keeps clients bound to the selected app model. On lets callers pass a model name for the selected provider."
    )
    .font(.caption)
    .foregroundStyle(.secondary)

    Toggle(
      "Run PocketMai tools",
      isOn: settingsBinding(\.openAPIServer.allowToolExecution))
    Text(
      "Off serves only the provider and model. On lets served requests use the selected tool configuration and returns tool run details when tools are called."
    )
    .font(.caption)
    .foregroundStyle(.secondary)

    if let port = store.openAPIServerState.port {
      let configuredPort = store.settings.openAPIServer.port
      let statusText =
        store.isOpenAPIServerRunning && port != configuredPort
        ? "Serving on port \(port). Stop and start serving to use port \(configuredPort)."
        : (store.isOpenAPIServerRunning ? "Serving on port \(port)." : "Starting on port \(port)…")
      Text(statusText)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var toolProxySummary: String {
    "Off: every enabled tool is described in each request. On: only `list-tools` and `call-tool` wrappers go to the model — it lists matching tools by keyword, then calls the chosen one. Saves prompt context with many tools, adds one extra round-trip per call. Combines with all tool calling modes."
  }

  private var appearanceSection: some View {
    Section {
      DisclosureGroup {
        appearanceOptionsContent
      } label: {
        Label("Appearance", systemImage: "paintpalette")
      }

      DisclosureGroup {
        fontOptionsContent
      } label: {
        Label("Fonts", systemImage: "textformat")
      }

      DisclosureGroup {
        voicesContent
      } label: {
        Label("Voices", systemImage: "speaker.wave.2")
      }

      DisclosureGroup {
        hapticsContent
      } label: {
        Label("Haptics", systemImage: "waveform.path")
      }

      DisclosureGroup {
        conversationOptionsContent
      } label: {
        Label("Conversation", systemImage: "mic.badge.plus")
      }
    } header: {
      Text("Look and Feel")
    }
  }

  @ViewBuilder
  private var appearanceOptionsContent: some View {
    Picker("Accent", selection: settingsBinding(\.appearance.tint)) {
      ForEach(AppearanceTint.allCases) { tint in
        HStack {
          Circle()
            .fill(tint.swatchColor)
            .frame(width: 12, height: 12)
          Text(tint.displayName)
        }
        .tag(tint)
      }
    }
    .pickerStyle(.menu)

    Picker("App Theme", selection: settingsBinding(\.appearance.theme)) {
      ForEach(AppearanceTheme.allCases) { theme in
        Text(theme.displayName).tag(theme)
      }
    }
    .pickerStyle(.menu)

    Picker("On Launch", selection: settingsBinding(\.startupBehavior)) {
      ForEach(AppStartupBehavior.allCases) { behavior in
        Text(behavior.displayName).tag(behavior)
      }
    }
    .pickerStyle(.menu)

    Toggle(
      "Solid response bubbles",
      isOn: settingsBinding(\.appearance.solidResponseBubbles))
    Toggle("Render Markdown", isOn: settingsBinding(\.renderMarkdownInChat))
    Toggle("Live Markdown", isOn: settingsBinding(\.appearance.liveMarkdown))
    Toggle("Render images", isOn: settingsBinding(\.renderMarkdownImagesInChat))
    Toggle("Justify Text", isOn: settingsBinding(\.appearance.justifyText))
    Toggle("Unwrapped Tables", isOn: settingsBinding(\.appearance.unwrappedTables))
  }

  @ViewBuilder
  private var fontOptionsContent: some View {
    fontPickerContent("User", selection: \.appearance.userFontFamily)
    fontPickerContent("Assistant", selection: \.appearance.assistantFontFamily)

    Stepper(
      value: settingsBinding(\.appearance.fontSize),
      in: AppearanceSettings.fontSizeRange,
      step: AppearanceSettings.fontSizeStep
    ) {
      Text(
        "Size \(store.settings.appearance.fontSize.formatted(.number.precision(.fractionLength(0...1)))) pt"
      )
    }

    Stepper(
      value: settingsBinding(\.appearance.lineSpacing),
      in: AppearanceSettings.lineSpacingRange,
      step: AppearanceSettings.lineSpacingStep
    ) {
      Text(
        "Line spacing \(store.settings.appearance.lineSpacing.formatted(.number.precision(.fractionLength(0...1)))) pt"
      )
    }

    VStack(alignment: .leading, spacing: 4) {
      Text("User: the quick brown fox jumps over the lazy dog.")
        .font(store.settings.appearance.userSwiftUIFont)
        .lineSpacing(CGFloat(store.settings.appearance.lineSpacing))
        .foregroundStyle(.secondary)
      Text("Assistant: the quick brown fox jumps over the lazy dog.")
        .font(store.settings.appearance.assistantSwiftUIFont)
        .lineSpacing(CGFloat(store.settings.appearance.lineSpacing))
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 2)
  }

  @ViewBuilder
  private func fontPickerContent(
    _ title: String,
    selection keyPath: WritableKeyPath<AppSettings, AppearanceFontFamily>
  ) -> some View {
    Picker(title, selection: fontPickerGroupBinding(keyPath)) {
      ForEach(AppearanceFontFamily.fontPickerGroups) { group in
        Text(group.displayName).tag(group.id)
      }
    }
    .pickerStyle(.menu)

    if let group = AppearanceFontFamily.installedPickerGroup(
      for: store.settings[keyPath: keyPath].pickerGroupID)
    {
      Picker("\(title) Style", selection: fontPickerFaceBinding(keyPath, group: group)) {
        ForEach(group.faces) { face in
          Text(face.displayName).tag(face.fontName)
        }
      }
      .pickerStyle(.menu)
    }
  }

  @ViewBuilder
  private var voicesContent: some View {
    NavigationLink {
      RoleVoiceSettingsView(role: .user, voice: settingsBinding(\.toolSettings.voices.user))
    } label: {
      Text("User")
    }
    NavigationLink {
      RoleVoiceSettingsView(
        role: .assistant, voice: settingsBinding(\.toolSettings.voices.assistant))
    } label: {
      Text("Assistant")
    }
    Text("Voices are used by Speak Message and the assistant's text-to-speech tool.")
      .font(.caption)
      .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private var hapticsContent: some View {
    Toggle("Enable Haptics", isOn: settingsBinding(\.appearance.hapticsEnabled))
    Toggle(
      "Vibrate on Stream Packets",
      isOn: settingsBinding(\.appearance.vibrateOnEveryStreamPacket)
    )
    .disabled(!store.settings.appearance.hapticsEnabled)
    Text(
      store.settings.appearance.vibrateOnEveryStreamPacket
        ? "Irregular typing-like taps play while the assistant streams; a completion pulse plays when it ends."
        : "A completion pulse plays when the assistant response completes."
    )
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private var conversationOptionsContent: some View {
    Stepper(
      value: settingsBinding(\.conversation.silenceTimeoutSeconds),
      in: ConversationSettings.silenceTimeoutRange,
      step: ConversationSettings.silenceTimeoutStep
    ) {
      Text(
        "Silence \(store.settings.conversation.silenceTimeoutSeconds.formatted(.number.precision(.fractionLength(0...2)))) sec"
      )
    }

    Picker("Speech to Text", selection: settingsBinding(\.conversation.speechRecognitionBackend)) {
      ForEach(LiveSpeechRecognitionBackend.allCases) { backend in
        Label(
          backend.displayName,
          systemImage: backend.systemImage
        )
        .tag(backend)
      }
    }
    .pickerStyle(.menu)
    .onChange(of: store.settings.conversation.speechRecognitionBackend) { _, backend in
      guard backend != .nativeIOSSpeechTranscriber,
        store.settings.conversation.backgroundVoiceListeningEnabled
      else {
        return
      }
      store.settings.conversation.backgroundVoiceListeningEnabled = false
      store.saveSettings()
    }

    Picker("Language", selection: speechRecognitionPrimaryLanguageBinding) {
      ForEach(speechRecognitionPrimaryLanguages, id: \.self) { primary in
        Text(TTSVoiceCache.primaryLanguageDisplayName(primary)).tag(primary)
      }
    }
    .pickerStyle(.menu)

    let variants = speechRecognitionVariants(
      forPrimary: speechRecognitionPrimaryLanguageBinding.wrappedValue)
    if variants.count > 1 {
      Picker(
        "Region",
        selection: settingsBinding(\.conversation.speechRecognitionLanguageIdentifier)
      ) {
        ForEach(variants, id: \.self) { id in
          Text(TTSVoiceCache.variantDisplayName(id)).tag(id)
        }
      }
      .pickerStyle(.menu)
    }

    Toggle("Continue Voice Chat When Locked", isOn: backgroundVoiceListeningBinding)
      .disabled(!store.settings.conversation.canUseBackgroundVoiceListening)

    Toggle("StreamTTS", isOn: settingsBinding(\.conversation.streamTTS))

    Toggle(
      "Skip Code and Links in TTS",
      isOn: settingsBinding(\.conversation.skipTechnicalContentInTTS))

  }

  private var speechRecognitionLocaleIdentifiers: [String] {
    let selected = store.settings.conversation.speechRecognitionLanguageIdentifier
      .trimmingCharacters(in: .whitespacesAndNewlines)
    var ids = SystemLanguageSupport.speechRecognitionLocaleIdentifiers
    if !selected.isEmpty, !ids.contains(selected) {
      ids.append(selected)
    }
    return SystemLanguageSupport.sortedLanguageIdentifiers(ids)
  }

  private var speechRecognitionPrimaryLanguages: [String] {
    let primaries = Set(
      speechRecognitionLocaleIdentifiers.compactMap {
        TTSVoiceCache.primaryLanguageCode($0)
      })
    return Array(primaries).sorted {
      TTSVoiceCache.primaryLanguageDisplayName($0)
        .localizedCaseInsensitiveCompare(TTSVoiceCache.primaryLanguageDisplayName($1))
        == .orderedAscending
    }
  }

  private func speechRecognitionVariants(forPrimary primary: String) -> [String] {
    speechRecognitionLocaleIdentifiers
      .filter { TTSVoiceCache.primaryLanguageCode($0) == primary }
      .sorted {
        TTSVoiceCache.variantDisplayName($0)
          .localizedCaseInsensitiveCompare(TTSVoiceCache.variantDisplayName($1))
          == .orderedAscending
      }
  }

  private var speechRecognitionPrimaryLanguageBinding: Binding<String> {
    Binding(
      get: {
        let id = store.settings.conversation.speechRecognitionLanguageIdentifier
        return TTSVoiceCache.primaryLanguageCode(id) ?? id
      },
      set: { newPrimary in
        let variants = speechRecognitionVariants(forPrimary: newPrimary)
        let current = store.settings.conversation.speechRecognitionLanguageIdentifier
        if variants.contains(current) { return }
        store.settings.conversation.speechRecognitionLanguageIdentifier =
          variants.first ?? newPrimary
        store.saveSettings()
      }
    )
  }

  private var backgroundVoiceListeningBinding: Binding<Bool> {
    Binding(
      get: { store.settings.conversation.allowsBackgroundVoiceListening },
      set: { enabled in
        guard store.settings.conversation.canUseBackgroundVoiceListening else {
          store.settings.conversation.backgroundVoiceListeningEnabled = false
          store.saveSettings()
          return
        }
        guard enabled else {
          store.settings.conversation.backgroundVoiceListeningEnabled = false
          store.saveSettings()
          return
        }
        guard !store.settings.conversation.backgroundVoiceListeningEnabled else { return }
        showingBackgroundVoiceConfirmation = true
      }
    )
  }

  private func enableBackgroundVoiceListening() {
    guard store.settings.conversation.canUseBackgroundVoiceListening else {
      store.settings.conversation.backgroundVoiceListeningEnabled = false
      store.saveSettings()
      return
    }
    store.settings.conversation.backgroundVoiceListeningEnabled = true
    store.saveSettings()
  }

  @ViewBuilder
  private var endpointContent: some View {
    if store.appleIntelligenceIsAvailable {
      appleIntelligenceProviderRow
    }

    NavigationLink {
      LocalLLMView()
    } label: {
      mlxProviderRow
    }

    ForEach(store.settings.openAIEndpoints) { endpoint in
      NavigationLink(value: SettingsRoute.endpoint(endpoint.id)) {
        endpointRow(endpoint)
      }
      .disabled(store.settings.airplaneModeEnabled)
      .opacity(store.settings.airplaneModeEnabled ? 0.5 : 1)
    }
    .onDelete { offsets in
      pendingDeletion = PendingSettingsDeletion(kind: .endpoint, offsets: offsets)
    }
    Button {
      let endpoint = OpenAIEndpoint(baseURL: "", authMethod: .apiKey)
      draftEndpoint = endpoint
      navigationPath.append(.endpoint(endpoint.id))
    } label: {
      Label("Add Provider", systemImage: "plus")
    }
    .disabled(store.settings.airplaneModeEnabled)
    Text(
      store.settings.airplaneModeEnabled
        ? (store.appleIntelligenceIsAvailable
          ? "Airplane Mode is on. Apple Intelligence and MLX remain available; OpenAI-compatible providers are offline."
          : "Airplane Mode is on. MLX remains available; OpenAI-compatible providers are offline.")
        : (store.appleIntelligenceIsAvailable
          ? "Apple Intelligence and MLX are built in. OpenAI-compatible providers can be added, edited, or removed."
          : "MLX is built in. OpenAI-compatible providers can be added, edited, or removed.")
    )
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private var appleIntelligenceProviderRow: some View {
    let report = store.appleAvailabilityReport
    let deviceOnlyReady = store.settings.airplaneModeEnabled && report.kind == .available
    return providerStatusRow(
      title: "Apple Intelligence",
      subtitle: deviceOnlyReady ? "Ready: device-only on this device" : report.providerListSubtitle,
      systemImage: appleIntelligenceStatusIcon(report.kind),
      color: appleIntelligenceStatusColor(report.kind),
      badge: deviceOnlyReady ? "Device" : report.statusLabel
    )
  }

  private var mlxProviderRow: some View {
    let modelID = store.settings.localMLXModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    let downloadedCount = store.localMLXModelIDs.count
    let subtitle: String = {
      if downloadedCount == 0 {
        return "No downloaded models"
      }
      let countText = "\(downloadedCount) downloaded"
      guard !modelID.isEmpty else {
        return countText
      }
      guard store.localMLXModelIDs.contains(modelID) else {
        return "\(countText). Select a downloaded model"
      }
      return "\(countText). \(modelID)"
    }()
    return providerStatusRow(
      title: "Local MLX LLM",
      subtitle: subtitle,
      systemImage: "cpu",
      color: .green,
      badge: "Built-in"
    )
  }

  private func providerStatusRow(
    title: String,
    subtitle: String,
    systemImage: String,
    color: Color,
    badge: String
  ) -> some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage)
        .imageScale(.medium)
        .foregroundStyle(color)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.body)
          .foregroundStyle(.primary)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      Text(badge)
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
    }
    .padding(.vertical, 2)
  }

  private func appleIntelligenceStatusIcon(_ kind: AppleFoundationAvailabilityKind) -> String {
    switch kind {
    case .checking:
      return "arrow.triangle.2.circlepath"
    case .available:
      return "checkmark.circle.fill"
    case .deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady, .unavailable:
      return "exclamationmark.circle.fill"
    }
  }

  private func appleIntelligenceStatusColor(_ kind: AppleFoundationAvailabilityKind) -> Color {
    switch kind {
    case .checking:
      return .orange
    case .available:
      return .green
    case .modelNotReady:
      return .orange
    case .deviceNotEligible, .appleIntelligenceNotEnabled, .unavailable:
      return .red
    }
  }

  private func endpointRow(_ endpoint: OpenAIEndpoint) -> some View {
    let status = store.endpointStatuses[endpoint.id] ?? .unknown
    let subtitle: String = {
      let trimmedModel = endpoint.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmedModel.isEmpty {
        return trimmedModel
      }
      let host = URL(string: endpoint.baseURL)?.host ?? endpoint.baseURL
      return host.isEmpty ? "No model selected" : host
    }()
    return HStack(spacing: 12) {
      Image(systemName: endpointStatusIcon(status))
        .imageScale(.medium)
        .foregroundStyle(status.statusColor)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(endpoint.displayName)
          .font(.body)
          .foregroundStyle(.primary)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      if store.settings.airplaneModeEnabled {
        Text("Offline")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
      } else if !endpoint.isEnabled {
        Text("Off")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, 2)
  }

  private func endpointStatusIcon(_ status: EndpointConnectionState) -> String {
    switch status {
    case .unknown: "circle"
    case .checking: "arrow.triangle.2.circlepath"
    case .available: "checkmark.circle.fill"
    case .failed: "exclamationmark.circle.fill"
    }
  }

  @ViewBuilder
  private var promptContent: some View {
    NavigationLink {
      CompactPromptDetailView()
    } label: {
      compactPromptRow
    }
    ForEach(store.settings.systemPrompts) { prompt in
      NavigationLink {
        SystemPromptDetailView(
          prompt: prompt,
          isDefault: prompt.id == store.settings.defaultSystemPromptID)
      } label: {
        promptRow(prompt)
      }
    }
    .onDelete { offsets in
      pendingDeletion = PendingSettingsDeletion(kind: .systemPrompt, offsets: offsets)
    }
    NavigationLink {
      SystemPromptDetailView()
    } label: {
      Label("Add Prompt", systemImage: "plus")
    }
    Text(
      "Compact Prompt is used when summarizing a chat. System prompts are sent to the model at the start of each chat."
    )
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private var userPromptContent: some View {
    ForEach(store.settings.userPrompts) { prompt in
      NavigationLink {
        UserPromptDetailView(prompt: prompt)
      } label: {
        userPromptRow(prompt)
      }
    }
    .onDelete { offsets in
      pendingDeletion = PendingSettingsDeletion(kind: .userPrompt, offsets: offsets)
    }
    NavigationLink {
      UserPromptDetailView()
    } label: {
      Label("Add User Prompt", systemImage: "plus")
    }
    Text("User prompts are prepended to user messages submitted with /name text.")
      .font(.caption)
      .foregroundStyle(.secondary)
  }

  private var compactPromptRow: some View {
    let trimmed = store.settings.compactPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let preview = trimmed.split(separator: "\n").first.map(String.init) ?? ""
    return HStack(spacing: 12) {
      Image(systemName: "rectangle.compress.vertical")
        .imageScale(.medium)
        .foregroundStyle(Color.accentColor)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text("Compact Prompt")
          .font(.body)
        Text(preview.isEmpty ? "Empty" : preview)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
    }
    .padding(.vertical, 2)
  }

  private func promptRow(_ prompt: SystemPrompt) -> some View {
    let isDefault = prompt.id == store.settings.defaultSystemPromptID
    let trimmed = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let preview = trimmed.split(separator: "\n").first.map(String.init) ?? ""
    return HStack(spacing: 12) {
      Image(systemName: isDefault ? "star.fill" : "text.bubble")
        .imageScale(.medium)
        .foregroundStyle(isDefault ? Color.accentColor : .secondary)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(prompt.displayName)
          .font(.body)
        Text(preview.isEmpty ? "Empty" : preview)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
    }
    .padding(.vertical, 2)
  }

  private func userPromptRow(_ prompt: UserPrompt) -> some View {
    let trimmed = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let preview = trimmed.split(separator: "\n").first.map(String.init) ?? ""
    return HStack(spacing: 12) {
      Image(systemName: "text.quote")
        .imageScale(.medium)
        .foregroundStyle(.secondary)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(prompt.displayName)
          .font(.body)
        Text(preview.isEmpty ? "Empty" : preview)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
    }
    .padding(.vertical, 2)
  }

  private var toolsSection: some View {
    Section {
      DisclosureGroup {
        contextToolsContent
      } label: {
        Label("Contextual", systemImage: "text.append")
      }

      DisclosureGroup {
        builtInToolsContent
      } label: {
        Label("Native", systemImage: "wrench.and.screwdriver")
      }

      DisclosureGroup {
        externalToolsContent
      } label: {
        Label("MCPs", systemImage: "server.rack")
      }

      DisclosureGroup {
        Text("Coming soon")
          .foregroundStyle(.secondary)
      } label: {
        Label("Skills", systemImage: "sparkles")
      }
    } header: {
      Text("Tools")
    }
  }

  @ViewBuilder
  private var builtInToolsContent: some View {
    ForEach(BuiltInToolID.allCases.filter(\.isCallableTool)) { tool in
      toolRow(tool)
    }
    Text("Tap the checkbox to enable. Tap the row to expand options where available.")
      .font(.caption)
      .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private var contextToolsContent: some View {
    ForEach(BuiltInToolID.allCases.filter(\.isContextSource)) { tool in
      toolRow(tool)
    }
    Text(
      "Context tools are rendered into the system prompt instead of being called on-demand. Toggle each tool to include its content in every chat."
    )
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private func toolRow(_ tool: BuiltInToolID) -> some View {
    DisclosureGroup {
      toolOptions(tool)
    } label: {
      toolLabel(tool)
    }
    .disabled(store.settings.airplaneModeEnabled && tool.isDisabledInAirplaneMode)
    .opacity(store.settings.airplaneModeEnabled && tool.isDisabledInAirplaneMode ? 0.5 : 1)
  }

  private func toolLabel(_ tool: BuiltInToolID) -> some View {
    HStack(spacing: 12) {
      Button {
        toggleTool(tool)
      } label: {
        Image(
          systemName: store.settings.defaultEnabledTools.contains(tool)
            ? "checkmark.square.fill" : "square"
        )
        .imageScale(.large)
        .foregroundStyle(
          store.settings.defaultEnabledTools.contains(tool) ? Color.accentColor : .secondary
        )
      }
      .buttonStyle(.borderless)
      Image(systemName: tool.systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 20)
      Text(tool.displayName)
        .foregroundStyle(.primary)
    }
  }

  @ViewBuilder
  private func toolOptions(_ tool: BuiltInToolID) -> some View {
    switch tool {
    case .datetime:
      Toggle("Include time zone", isOn: settingsBinding(\.toolSettings.includeTimeZone))
      Toggle("Include moon phase", isOn: settingsBinding(\.toolSettings.includeMoonPhase))
    case .language:
      Text(
        "Adds the chat language preference to the prompt. Chats set to Defaults use the language from Conversation settings, then voice settings."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    case .location:
      Toggle("Use GPS location", isOn: settingsBinding(\.toolSettings.useGPSLocation))
      TextField("Manual location", text: settingsBinding(\.toolSettings.manualLocation))
    case .weather:
      TextField("Weather location", text: settingsBinding(\.toolSettings.weatherLocation))
    case .webSearch:
      Picker("Provider", selection: settingsBinding(\.toolSettings.webSearchProvider)) {
        ForEach(availableWebSearchProviders) { provider in
          Text(provider.displayName).tag(provider)
        }
      }
      if showsSearXNGSettings {
        TextField("SearXNG URL", text: settingsBinding(\.toolSettings.webSearchSearXNGURL))
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        TextField(
          "SearXNG username", text: settingsBinding(\.toolSettings.webSearchSearXNGUsername)
        )
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        SecureField(
          "SearXNG password", text: settingsBinding(\.toolSettings.webSearchSearXNGPassword))
      }
      Toggle(
        "Fetching data",
        isOn: settingsBinding(\.toolSettings.webSearchFetchingEnabled))
    case .todo:
      HStack {
        TextField("New todo", text: $newTodoTitle)
          .submitLabel(.done)
          .onSubmit {
            addTodo()
          }
        Button {
          addTodo()
        } label: {
          Image(systemName: "plus.circle.fill")
        }
        .buttonStyle(.borderless)
      }
      ForEach($store.settings.toolSettings.todos) { $todo in
        HStack(spacing: 10) {
          Button {
            todo.isDone.toggle()
            store.saveSettings()
          } label: {
            Image(systemName: todo.isDone ? "checkmark.circle.fill" : "circle")
              .imageScale(.large)
              .foregroundStyle(todo.isDone ? Color.accentColor : .secondary)
          }
          .buttonStyle(.borderless)
          TextField("Todo", text: $todo.title)
            .foregroundStyle(todo.isDone ? .secondary : .primary)
        }
      }
      .onDelete { offsets in
        deleteTodos(at: offsets)
      }
    case .calculator:
      Text("Evaluates local arithmetic with parentheses, +, -, *, and /.")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .textToSpeech:
      Text("Configure user and assistant voices in Look and Feel.")
        .font(.footnote)
        .foregroundStyle(.secondary)
    case .calendar:
      Toggle(
        "Allow creating events",
        isOn: settingsBinding(\.toolSettings.calendarEventCreationEnabled))
      Text(
        "Off exposes only calendar_read_events. On also exposes calendar_create_event. Reads request full Calendar access only when called; event creation requests write-only Calendar access when possible."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    case .files:
      Toggle(
        "Enable FilesData tools",
        isOn: settingsBinding(\.toolSettings.filesWorkspaceAccessEnabled))
      Text(
        "The callable Files tools can list folders, read, write, append, rename, and delete UTF-8 text files in FilesData. Writes can create folders. Downloaded MLX models are visible in the iOS Files app under Models, but unavailable to FilesData tools."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Button {
        showingToolFileImporter = true
      } label: {
        Label("Import Text File", systemImage: "doc.badge.plus")
      }
      .buttonStyle(.borderless)
      ForEach(store.settings.toolSettings.files) { file in
        VStack(alignment: .leading) {
          Text(file.name)
            .font(.body.weight(.medium))
          Text(file.excerpt)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
        }
      }
      .onDelete { offsets in
        pendingDeletion = PendingSettingsDeletion(kind: .file, offsets: offsets)
      }
    case .memory:
      TextEditor(text: settingsBinding(\.memory))
        .frame(minHeight: 140)
        .font(.callout)
      Button {
        Task { await store.updateMemoryFromConversations() }
      } label: {
        if store.isUpdatingMemory {
          ProgressView()
        } else {
          Label("Update From Conversations", systemImage: "wand.and.sparkles")
        }
      }
      .disabled(store.isUpdatingMemory || !hasConversationContent)
      Button {
        showingClearMemoryConfirmation = true
      } label: {
        let memoryEmpty =
          store.settings.memory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let active = hasConversationContent && !memoryEmpty
        Label("Clear Memory", systemImage: "trash")
          .foregroundStyle(active ? Color.red : Color.secondary)
      }
      .disabled(
        !hasConversationContent
          || store.settings.memory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      Text(
        "Memory is added to the system prompt as durable context when the Memory context tool is enabled."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var externalToolsContent: some View {
    Toggle("Use tool proxy (list / call)", isOn: settingsBinding(\.useToolProxy))
    Text(toolProxySummary)
      .font(.caption)
      .foregroundStyle(.secondary)
    ForEach(store.settings.mcpServers) { server in
      NavigationLink(value: SettingsRoute.mcpServer(server.id)) {
        mcpRow(server)
      }
    }
    .onDelete { offsets in
      pendingDeletion = PendingSettingsDeletion(kind: .mcpServer, offsets: offsets)
    }
    Button {
      let server = MCPServer(name: "", baseURL: "")
      draftMCPServer = server
      navigationPath.append(.mcpServer(server.id))
    } label: {
      Label("Add MCP Server", systemImage: "plus")
    }
    Text("HTTP and HTTPS MCP endpoints are accepted; transport is detected automatically.")
      .font(.caption)
      .foregroundStyle(.secondary)
  }

  private func mcpRow(_ server: MCPServer) -> some View {
    let transport = server.transport?.displayName
    let subtitle: String = {
      if let tools = store.mcpTools[server.id], !tools.isEmpty {
        let resources = store.mcpResources[server.id] ?? []
        let resourceText =
          resources.isEmpty ? "" : ", \(resources.count) resource\(resources.count == 1 ? "" : "s")"
        let catalogText = "\(tools.count) tool\(tools.count == 1 ? "" : "s")\(resourceText)"
        return [transport, catalogText].compactMap { $0 }.joined(separator: " • ")
      }
      if let resources = store.mcpResources[server.id], !resources.isEmpty {
        let resourceText = "\(resources.count) resource\(resources.count == 1 ? "" : "s")"
        return [transport, resourceText].compactMap { $0 }.joined(separator: " • ")
      }
      let url = server.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
      if url.isEmpty || url == "https://" {
        return transport ?? "No URL set"
      }
      let endpointText = URL(string: url)?.host ?? url
      return [transport, endpointText].compactMap { $0 }.joined(separator: " • ")
    }()
    let icon: String = {
      if server.isHTTPS && server.hasValidEndpointURL { return "lock.fill" }
      if server.hasValidEndpointURL { return "globe" }
      return "lock.trianglebadge.exclamationmark"
    }()
    let iconColor: Color = {
      if server.isHTTPS && server.hasValidEndpointURL { return .green }
      if server.hasValidEndpointURL { return .orange }
      return .red
    }()
    return HStack(spacing: 12) {
      Image(systemName: icon)
        .imageScale(.medium)
        .foregroundStyle(iconColor)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(server.name.isEmpty ? "Untitled Server" : server.name)
          .font(.body)
          .foregroundStyle(.primary)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      if !server.isEnabled {
        Text("Off")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, 2)
  }

  private var aboutSection: some View {
    Section {
      HStack {
        Text("Author")
        Spacer()
        Text("pancake").foregroundStyle(.secondary)
      }
      HStack {
        Text("Version")
        Spacer()
        Text(appVersionString).foregroundStyle(.secondary)
      }
      Link(destination: URL(string: "https://github.com/trufae/mai")!) {
        HStack {
          Label("GitHub", systemImage: "link")
          Spacer()
          Image(systemName: "arrow.up.right")
            .imageScale(.small)
            .foregroundStyle(.tertiary)
        }
      }
      NavigationLink {
        LicensesView()
      } label: {
        Label("Licenses", systemImage: "doc.text")
      }
    } header: {
      Text("About")
    }
  }

  private var appVersionString: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "—"
    if let build = info?["CFBundleVersion"] as? String, build != short {
      return "\(short) (\(build))"
    }
    return short
  }

  private var dangerSection: some View {
    Section {
      NavigationLink {
        SettingsImportView()
          .environmentObject(store)
      } label: {
        Label("Import...", systemImage: "square.and.arrow.down")
      }

      NavigationLink {
        SettingsExportView()
          .environmentObject(store)
      } label: {
        Label("Export...", systemImage: "square.and.arrow.up")
      }

      NavigationLink {
        SettingsDestroyView { dismiss() }
          .environmentObject(store)
      } label: {
        Label("Destroy...", systemImage: "exclamationmark.triangle")
          .foregroundStyle(Color.red)
      }
    } header: {
      Text("Danger Zone")
    } footer: {
      Text(
        "Move data between devices with Import and Export, or clear local data from Destroy. Destructive actions still require confirmation."
      )
    }
  }

  private var hasConversationContent: Bool {
    store.conversationSummaries.contains(where: \.hasMessages)
  }

  private var settingsDeletionConfirmationBinding: Binding<Bool> {
    Binding {
      pendingDeletion != nil
    } set: { isPresented in
      if !isPresented {
        pendingDeletion = nil
      }
    }
  }

  private func performSettingsDeletion(_ deletion: PendingSettingsDeletion) {
    defer { pendingDeletion = nil }

    switch deletion.kind {
    case .endpoint:
      guard deletion.offsets.allSatisfy({ store.settings.openAIEndpoints.indices.contains($0) })
      else { return }
      let removedIDs = deletion.offsets.map { store.settings.openAIEndpoints[$0].id }
      store.settings.openAIEndpoints.remove(atOffsets: deletion.offsets)
      for id in removedIDs {
        store.resetEndpointStatus(id)
      }
      if let selected = store.settings.selectedEndpointID, removedIDs.contains(selected) {
        store.settings.selectedEndpointID = store.settings.openAIEndpoints.first?.id
        if store.settings.selectedEndpointID == nil {
          store.settings.defaultProvider = .mlx
        }
      }
      navigationPath.removeAll { route in
        if case .endpoint(let id) = route {
          return removedIDs.contains(id)
        }
        return false
      }
      store.saveSettings()
    case .systemPrompt:
      guard deletion.offsets.allSatisfy({ store.settings.systemPrompts.indices.contains($0) })
      else { return }
      store.settings.systemPrompts.remove(atOffsets: deletion.offsets)
      if !store.settings.systemPrompts.contains(where: {
        $0.id == store.settings.defaultSystemPromptID
      }) {
        store.settings.defaultSystemPromptID =
          store.settings.systemPrompts.first?.id ?? AppSettings.defaultSystemPrompt.id
      }
      if store.settings.systemPrompts.isEmpty {
        store.settings.systemPrompts = [AppSettings.defaultSystemPrompt]
        store.settings.defaultSystemPromptID = AppSettings.defaultSystemPrompt.id
      }
      store.saveSettings()
    case .userPrompt:
      guard deletion.offsets.allSatisfy({ store.settings.userPrompts.indices.contains($0) })
      else { return }
      store.settings.userPrompts.remove(atOffsets: deletion.offsets)
      store.saveSettings()
    case .file:
      guard deletion.offsets.allSatisfy({ store.settings.toolSettings.files.indices.contains($0) })
      else { return }
      store.settings.toolSettings.files.remove(atOffsets: deletion.offsets)
      store.saveSettings()
    case .mcpServer:
      guard deletion.offsets.allSatisfy({ store.settings.mcpServers.indices.contains($0) })
      else { return }
      let removedIDs = deletion.offsets.map { store.settings.mcpServers[$0].id }
      store.settings.mcpServers.remove(atOffsets: deletion.offsets)
      for id in removedIDs {
        let prefix = MCPToolSelection.prefix(serverID: id)
        store.settings.defaultEnabledMCPServers.remove(id)
        store.settings.defaultEnabledMCPTools = Set(
          store.settings.defaultEnabledMCPTools.filter { !$0.hasPrefix(prefix) })
        store.mcpStatuses[id] = nil
        store.mcpTools[id] = nil
        store.mcpResources[id] = nil
        Task { await MCPHTTPClient.resetSession(for: id) }
      }
      navigationPath.removeAll { route in
        if case .mcpServer(let id) = route {
          return removedIDs.contains(id)
        }
        return false
      }
      store.saveSettings()
    }
  }

  private func deleteTodos(at offsets: IndexSet) {
    guard offsets.allSatisfy({ store.settings.toolSettings.todos.indices.contains($0) }) else {
      return
    }
    store.settings.toolSettings.todos.remove(atOffsets: offsets)
    store.saveSettings()
  }

  private func addTodo() {
    let trimmed = newTodoTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    store.settings.toolSettings.todos.append(TodoItem(title: trimmed))
    newTodoTitle = ""
    store.saveSettings()
  }

  private func saveAndDismiss() {
    guard finalizeEmptyEndpointNames() else { return }
    store.saveSettings()
    dismiss()
  }

  private func finalizeEmptyEndpointNames() -> Bool {
    for index in store.settings.openAIEndpoints.indices {
      let endpoint = store.settings.openAIEndpoints[index]
      let trimmedName = endpoint.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmedName.isEmpty else { continue }

      if let message = EndpointNameResolution.nameValidationMessage(
        for: endpoint,
        in: store.settings.openAIEndpoints)
      {
        showToast(message)
        return false
      }

      if let name = EndpointNameResolution.savedName(for: endpoint) {
        store.settings.openAIEndpoints[index].name = name
      }
    }
    return true
  }

  private func draftEndpointBinding(for id: UUID) -> Binding<OpenAIEndpoint> {
    Binding(
      get: {
        draftEndpoint ?? OpenAIEndpoint(id: id, baseURL: "", authMethod: .apiKey)
      },
      set: { endpoint in
        draftEndpoint = endpoint
      }
    )
  }

  private func discardDraftEndpointIfNeeded(path: [SettingsRoute]) {
    guard let draftEndpoint, !path.contains(.endpoint(draftEndpoint.id)) else { return }
    self.draftEndpoint = nil
  }

  private func draftMCPServerBinding(for id: UUID) -> Binding<MCPServer> {
    Binding(
      get: {
        draftMCPServer ?? MCPServer(id: id, name: "", baseURL: "")
      },
      set: { server in
        draftMCPServer = server
      }
    )
  }

  private func discardDraftMCPServerIfNeeded(path: [SettingsRoute]) {
    guard let draftMCPServer, !path.contains(.mcpServer(draftMCPServer.id)) else { return }
    store.mcpStatuses[draftMCPServer.id] = nil
    store.mcpTools[draftMCPServer.id] = nil
    store.mcpResources[draftMCPServer.id] = nil
    Task { await MCPHTTPClient.resetSession(for: draftMCPServer.id) }
    self.draftMCPServer = nil
  }

  private func showToast(_ message: String) {
    withAnimation(.snappy) {
      toastMessage = message
    }
  }

  private var defaultProviderBinding: Binding<DefaultProviderSelection> {
    Binding(
      get: {
        if store.settings.airplaneModeEnabled
          && !store.settings.defaultProvider.isAirplaneModeEligible
        {
          return .mlx
        }
        switch store.settings.defaultProvider {
        case .apple:
          return store.appleIntelligenceIsAvailable ? .apple : .mlx
        case .mlx:
          return .mlx
        case .openAICompatible:
          if let id = store.settings.selectedEndpointID,
            store.settings.openAIEndpoints.contains(where: { $0.id == id && $0.isEnabled })
          {
            return .endpoint(id)
          }
          if let first = store.settings.defaultOpenAIEndpoint {
            return .endpoint(first.id)
          }
          return .mlx
        }
      },
      set: { newValue in
        switch newValue {
        case .apple:
          guard store.appleIntelligenceIsAvailable else {
            store.refreshLocalMLXModels()
            store.settings.defaultProvider = .mlx
            store.settings.localMLXModelID =
              store.availableLocalMLXModelID(preferred: store.settings.localMLXModelID) ?? ""
            store.saveSettings()
            return
          }
          store.settings.defaultProvider = .apple
        case .mlx:
          store.refreshLocalMLXModels()
          store.settings.defaultProvider = .mlx
          store.settings.localMLXModelID =
            store.availableLocalMLXModelID(preferred: store.settings.localMLXModelID) ?? ""
        case .endpoint(let id):
          guard !store.settings.airplaneModeEnabled else {
            showToast(
              store.appleIntelligenceIsAvailable
                ? "Airplane Mode is enabled. Choose Apple Intelligence or MLX Local."
                : "Airplane Mode is enabled. Choose MLX Local.")
            return
          }
          store.settings.defaultProvider = .openAICompatible
          store.settings.selectedEndpointID = id
        }
        store.saveSettings()
      }
    )
  }

  private var defaultProviderMenuTitle: String {
    switch defaultProviderBinding.wrappedValue {
    case .apple:
      return store.appleIntelligenceIsAvailable ? "Apple Intelligence" : "MLX Local"
    case .mlx:
      return "MLX Local"
    case .endpoint(let id):
      return store.settings.openAIEndpoints.first(where: { $0.id == id })?.displayName
        ?? "OpenAI Compatible"
    }
  }

  private var defaultProviderMenuIcon: String {
    switch defaultProviderBinding.wrappedValue {
    case .apple:
      return store.appleIntelligenceIsAvailable ? "apple.logo" : "cpu"
    case .mlx:
      return "cpu"
    case .endpoint:
      return "network"
    }
  }

  private func toggleAirplaneMode() {
    store.settings.airplaneModeEnabled.toggle()
    if store.settings.airplaneModeEnabled {
      store.endpointStatuses.removeAll()
      store.endpointModels.removeAll()
      store.endpointVoices.removeAll()
    } else {
      store.refreshConfiguredEndpointsInBackground()
    }
    store.refreshAppleIntelligenceAvailabilityInBackground()
    store.saveSettings()
  }

  private func settingsBinding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<
    Value
  > {
    Binding(
      get: { store.settings[keyPath: keyPath] },
      set: { value in
        store.settings[keyPath: keyPath] = value
        store.saveSettings()
      }
    )
  }

  private var openAPIServerPortBinding: Binding<Int> {
    Binding(
      get: { store.settings.openAPIServer.port },
      set: { value in
        store.settings.openAPIServer.port = OpenAPIServerSettings.clampedPort(value)
        store.saveSettings()
      }
    )
  }

  private func fontPickerGroupBinding(
    _ keyPath: WritableKeyPath<AppSettings, AppearanceFontFamily>
  ) -> Binding<String> {
    Binding(
      get: { store.settings[keyPath: keyPath].pickerGroupID },
      set: { groupID in
        store.settings[keyPath: keyPath] = AppearanceFontFamily.font(
          forPickerGroupID: groupID,
          current: store.settings[keyPath: keyPath])
        store.saveSettings()
      }
    )
  }

  private func fontPickerFaceBinding(
    _ keyPath: WritableKeyPath<AppSettings, AppearanceFontFamily>,
    group: AppearanceFontPickerGroup
  ) -> Binding<String> {
    Binding(
      get: {
        let current = store.settings[keyPath: keyPath].installedFontName
        return group.preferredFace(currentFontName: current)?.fontName ?? ""
      },
      set: { fontName in
        guard group.faces.contains(where: { $0.fontName == fontName }) else { return }
        store.settings[keyPath: keyPath] = .installed(fontName)
        store.saveSettings()
      }
    )
  }

  private var availableWebSearchProviders: [WebSearchProvider] {
    let hasOllama = WebSearchService.ollamaEndpoint(in: store.settings) != nil
    return WebSearchProvider.allCases.filter { provider in
      provider != .ollama || hasOllama
    }
  }

  private var showsSearXNGSettings: Bool {
    let provider = store.settings.toolSettings.webSearchProvider
    return provider == .searXNG || provider == .all
  }

  private func toggleTool(_ tool: BuiltInToolID) {
    guard !(store.settings.airplaneModeEnabled && tool.isDisabledInAirplaneMode) else {
      showToast("\(tool.displayName) is disabled while Airplane Mode is enabled.")
      return
    }
    if store.settings.defaultEnabledTools.contains(tool) {
      store.settings.defaultEnabledTools.remove(tool)
    } else {
      store.settings.defaultEnabledTools.insert(tool)
    }
    store.saveSettings()
  }
}

private struct RoleVoiceSettingsView: View {
  @EnvironmentObject private var store: AppStore
  @EnvironmentObject private var ttsPlayer: TTSPlayer
  let role: VoiceRole
  @Binding var voice: RoleVoiceSettings

  var body: some View {
    Form {
      Section {
        Picker("Provider", selection: providerBinding) {
          Text("System").tag(VoiceProviderSelection.system)
          ForEach(openAIVoiceEndpoints) { endpoint in
            Text(endpoint.displayName)
              .tag(VoiceProviderSelection.openAI(endpoint.id))
              .disabled(store.settings.airplaneModeEnabled)
          }
        }
      } footer: {
        Text(
          store.settings.airplaneModeEnabled
            ? "Airplane Mode is on. Provider voices are unavailable."
            : "Only OpenAI-compatible providers with discovered /v1/voices are listed.")
      }

      if showsOpenAIVoiceSettings {
        Section {
          openAIVoicePicker
          Button {
            refreshSelectedVoiceEndpoint()
          } label: {
            if isRefreshingSelectedVoiceEndpoint {
              HStack {
                ProgressView()
                Text("Refreshing Voices...")
              }
            } else {
              Label("Refresh Voices", systemImage: "arrow.clockwise")
            }
          }
          .disabled(selectedOpenAIEndpoint == nil || isRefreshingSelectedVoiceEndpoint)
        } footer: {
          if selectedEndpointVoices.isEmpty {
            Text("Refresh this provider to load voices from /v1/voices.")
          } else {
            Text("Provider voices are requested as WAV audio from /v1/audio/speech.")
          }
        }
      } else {
        Section {
          Picker("Language", selection: voicePrimaryLanguageBinding) {
            Text("System Default").tag("")
            ForEach(TTSVoiceCache.primaryLanguages, id: \.self) { primary in
              Text(TTSVoiceCache.primaryLanguageDisplayName(primary)).tag(primary)
            }
          }

          let variants = TTSVoiceCache.variants(
            forPrimary: voicePrimaryLanguageBinding.wrappedValue)
          if variants.count > 1 {
            Picker("Region", selection: voiceBinding(\.language)) {
              ForEach(variants, id: \.self) { id in
                Text(TTSVoiceCache.variantDisplayName(id)).tag(id)
              }
            }
          }

          Picker("Voice", selection: voiceBinding(\.voiceIdentifier)) {
            Text("Default Voice").tag("")
            ForEach(TTSVoiceCache.voiceOptions(for: voice.language), id: \.identifier) { option in
              Text(option.name).tag(option.identifier)
            }
          }
        }

        Section {
          LabeledContent("Rate") {
            Slider(value: voiceBinding(\.rate), in: 0...1, step: 0.05)
          }

          LabeledContent("Pitch") {
            Slider(value: voiceBinding(\.pitch), in: 0.5...2, step: 0.05)
          }
        }
      }

      Section {
        Button {
          VoiceTest.toggle(
            role: role,
            voice: effectiveVoice,
            openAIEndpoints: store.settings.airplaneModeEnabled
              ? [] : store.settings.openAIEndpoints,
            player: ttsPlayer)
        } label: {
          let isPlaying = ttsPlayer.isPlaying(tag: VoiceTest.tag(for: role))
          Label(
            isPlaying ? "Stop Test" : "Test Voice",
            systemImage: isPlaying ? "stop.circle" : "play.circle")
        }
      }
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .onChange(of: voice.language) { _, newLanguage in
      guard effectiveVoice.provider == .system else { return }
      guard !newLanguage.isEmpty,
        let selectedVoice = TTSVoiceCache.voices.first(where: {
          $0.identifier == voice.voiceIdentifier
        }),
        selectedVoice.language != newLanguage
      else { return }
      voice.voiceIdentifier = ""
    }
    .onAppear {
      normalizeProviderVoiceSelection()
    }
    .onChange(of: selectedEndpointVoices) { _, _ in
      normalizeProviderVoiceSelection()
    }
  }

  private var title: String {
    switch role {
    case .user: "User"
    case .assistant: "Assistant"
    }
  }

  private var effectiveVoice: RoleVoiceSettings {
    store.settings.airplaneModeEnabled ? voice.withoutOnlineProvider() : voice
  }

  private var showsOpenAIVoiceSettings: Bool {
    effectiveVoice.provider == .openAICompatible
  }

  private func voiceBinding<Value>(_ keyPath: WritableKeyPath<RoleVoiceSettings, Value>)
    -> Binding<Value>
  {
    Binding(
      get: { voice[keyPath: keyPath] },
      set: { newValue in
        var copy = voice
        copy[keyPath: keyPath] = newValue
        voice = copy
      })
  }

  private var voicePrimaryLanguageBinding: Binding<String> {
    Binding(
      get: {
        let lang = voice.language
        if lang.isEmpty { return "" }
        return TTSVoiceCache.primaryLanguageCode(lang) ?? ""
      },
      set: { newPrimary in
        var copy = voice
        if newPrimary.isEmpty {
          copy.language = ""
        } else {
          let variants = TTSVoiceCache.variants(forPrimary: newPrimary)
          if !variants.contains(copy.language) {
            copy.language = variants.first ?? ""
          }
        }
        voice = copy
      })
  }

  private var providerBinding: Binding<VoiceProviderSelection> {
    Binding(
      get: {
        guard !store.settings.airplaneModeEnabled else { return .system }
        if voice.provider == .openAICompatible, let id = voice.openAIEndpointID {
          return .openAI(id)
        }
        return .system
      },
      set: { selection in
        var copy = voice
        switch selection {
        case .system:
          copy.provider = .system
        case .openAI(let id):
          guard !store.settings.airplaneModeEnabled else { return }
          copy.provider = .openAICompatible
          copy.openAIEndpointID = id
          let voices = store.endpointVoices[id] ?? []
          if !voices.contains(copy.openAIVoice) {
            copy.openAIVoice = voices.first ?? copy.openAIVoice
          }
        }
        voice = copy
      })
  }

  @ViewBuilder
  private var openAIVoicePicker: some View {
    Picker("Voice", selection: voiceBinding(\.openAIVoice)) {
      if openAIVoiceOptions.isEmpty {
        Text("No voices loaded").tag("")
      } else {
        ForEach(openAIVoiceOptions, id: \.self) { option in
          Text(option).tag(option)
        }
      }
    }
  }

  private var openAIVoiceOptions: [String] {
    var options = selectedEndpointVoices
    let current = voice.openAIVoice.trimmingCharacters(in: .whitespacesAndNewlines)
    if !current.isEmpty && !options.contains(current) {
      options.insert(current, at: 0)
    }
    return options
  }

  private var selectedEndpointVoices: [String] {
    guard !store.settings.airplaneModeEnabled else { return [] }
    guard voice.provider == .openAICompatible,
      let id = voice.openAIEndpointID
    else { return [] }
    return store.endpointVoices[id] ?? []
  }

  private var openAIVoiceEndpoints: [OpenAIEndpoint] {
    guard !store.settings.airplaneModeEnabled else { return [] }
    return store.settings.openAIEndpoints.filter { endpoint in
      endpoint.isEnabled && !(store.endpointVoices[endpoint.id] ?? []).isEmpty
    }
  }

  private var selectedOpenAIEndpoint: OpenAIEndpoint? {
    guard let id = voice.openAIEndpointID else { return nil }
    return openAIVoiceEndpoints.first(where: { $0.id == id })
  }

  private var isRefreshingSelectedVoiceEndpoint: Bool {
    guard let id = voice.openAIEndpointID,
      case .checking = store.endpointStatuses[id]
    else { return false }
    return true
  }

  private func normalizeProviderVoiceSelection() {
    guard voice.provider == .openAICompatible else { return }
    guard !store.settings.airplaneModeEnabled else { return }
    guard !openAIVoiceEndpoints.isEmpty else {
      voice.provider = .system
      voice.openAIEndpointID = nil
      return
    }
    if voice.openAIEndpointID == nil
      || !openAIVoiceEndpoints.contains(where: { $0.id == voice.openAIEndpointID })
    {
      voice.openAIEndpointID = openAIVoiceEndpoints.first?.id
    }
    guard let id = voice.openAIEndpointID else { return }
    let voices = store.endpointVoices[id] ?? []
    if !voices.isEmpty && !voices.contains(voice.openAIVoice) {
      voice.openAIVoice = voices[0]
    }
  }

  private func refreshSelectedVoiceEndpoint() {
    guard !store.settings.airplaneModeEnabled else { return }
    guard let endpoint = selectedOpenAIEndpoint else { return }
    Task { await store.refreshEndpoint(endpoint) }
  }
}

private enum EndpointNameResolution {
  static func savedName(for endpoint: OpenAIEndpoint) -> String? {
    let trimmedName = endpoint.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedName.isEmpty {
      return trimmedName
    }
    return providerName(for: endpoint)
  }

  static func validationMessage(for endpoint: OpenAIEndpoint, in endpoints: [OpenAIEndpoint])
    -> String?
  {
    if let message = baseURLValidationMessage(for: endpoint) {
      return message
    }
    if let message = nameValidationMessage(for: endpoint, in: endpoints) {
      return message
    }
    if let message = apiKeyValidationMessage(for: endpoint) {
      return message
    }
    return nil
  }

  static func nameValidationMessage(for endpoint: OpenAIEndpoint, in endpoints: [OpenAIEndpoint])
    -> String?
  {
    let trimmedName = endpoint.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedName: String
    if trimmedName.isEmpty {
      guard let fallbackName = providerName(for: endpoint) else {
        return "Specify a name for this provider."
      }
      resolvedName = fallbackName
    } else {
      resolvedName = trimmedName
    }
    if hasDuplicateName(resolvedName, excluding: endpoint.id, in: endpoints) {
      return "Another provider is already named \"\(resolvedName)\". Specify a name."
    }
    return nil
  }

  static func connectionValidationMessage(for endpoint: OpenAIEndpoint) -> String? {
    if let message = baseURLValidationMessage(for: endpoint) {
      return message
    }
    return apiKeyValidationMessage(for: endpoint)
  }

  private static func baseURLValidationMessage(for endpoint: OpenAIEndpoint) -> String? {
    let baseURL = endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !baseURL.isEmpty else {
      return "Specify a base URL for this provider."
    }
    guard let components = URLComponents(string: baseURL),
      let scheme = components.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      let host = components.host,
      !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return "Specify a valid http or https base URL."
    }
    return nil
  }

  private static func apiKeyValidationMessage(for endpoint: OpenAIEndpoint) -> String? {
    guard requiresAPIKey(for: endpoint) else { return nil }
    let apiKey = endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard apiKey.isEmpty else { return nil }
    let name = savedName(for: endpoint) ?? "this provider"
    return "Specify an API key for \(name)."
  }

  private static func providerName(for endpoint: OpenAIEndpoint) -> String? {
    let baseURL = endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if let preset = providerPreset(forBaseURL: baseURL) {
      return preset.name
    }
    return nil
  }

  private static func requiresAPIKey(for endpoint: OpenAIEndpoint) -> Bool {
    guard endpoint.authMethod == .apiKey else { return false }
    guard let preset = providerPreset(forBaseURL: endpoint.baseURL) else { return false }
    return preset.name != "Ollama"
      && !OllamaNetworkScanner.isLikelyLocalOllamaBaseURL(endpoint.baseURL)
  }

  static func providerPreset(forBaseURL baseURL: String) -> EndpointProviderPreset? {
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    return endpointProviderPresets.first(where: { $0.url == trimmed })
  }

  static func matchingOAuthPreset(for endpoint: OpenAIEndpoint) -> EndpointProviderPreset? {
    let authorize = endpoint.oauthAuthorizeURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let issuer = endpoint.oauthIssuer.trimmingCharacters(in: .whitespacesAndNewlines)
    return endpointProviderPresets.first { preset in
      guard preset.authMethods.contains(.oauth) else { return false }
      guard let defaults = preset.oauthDefaults else { return false }
      if !authorize.isEmpty, !defaults.authorizeURL.isEmpty {
        return defaults.authorizeURL == authorize
      }
      return !issuer.isEmpty && defaults.issuer == issuer
    }
  }

  private static func hasDuplicateName(
    _ name: String,
    excluding endpointID: UUID,
    in endpoints: [OpenAIEndpoint]
  ) -> Bool {
    let normalized = normalizedName(name)
    return endpoints.contains { endpoint in
      guard endpoint.id != endpointID,
        let endpointName = savedName(for: endpoint)
      else { return false }
      return normalizedName(endpointName) == normalized
    }
  }

  private static func normalizedName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}

struct ConversationImportConfirmationView: View {
  let preview: ConversationImportPreview
  let onCancel: () -> Void
  let onImportAsNew: (String) -> String?
  let onUpdateExisting: () -> String?

  @State private var title: String
  @State private var errorMessage: String?

  init(
    preview: ConversationImportPreview,
    onCancel: @escaping () -> Void,
    onImportAsNew: @escaping (String) -> String?,
    onUpdateExisting: @escaping () -> String?
  ) {
    self.preview = preview
    self.onCancel = onCancel
    self.onImportAsNew = onImportAsNew
    self.onUpdateExisting = onUpdateExisting
    _title = State(initialValue: preview.suggestedRenameTitle)
  }

  var body: some View {
    NavigationStack {
      Form {
        importDetailsSection
        conflictSection
        errorSection
        importActionSection
      }
      .navigationTitle("Import Conversation")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            onCancel()
          }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }

  @ViewBuilder
  private var errorSection: some View {
    if let errorMessage {
      Section {
        Label(errorMessage, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red)
      }
    }
  }

  private var importDetailsSection: some View {
    Section {
      infoRow("Title", preview.envelope.title)
      infoRow("Provider", preview.envelope.providerDisplayName)
      infoRow("Model", preview.envelope.model)
      infoRow("Exported", formattedDate(preview.envelope.exportedAt))
      infoRow("Created", formattedDate(preview.envelope.createdAt))
      infoRow("PocketMai", preview.envelope.pocketMaiVersion)
      infoRow("Messages", "\(preview.conversation.messages.count)")
    } header: {
      Text("Contents")
    }
  }

  @ViewBuilder
  private var conflictSection: some View {
    if let conflict = preview.conflict {
      Section {
        Label(
          conflictTitle(conflict),
          systemImage: conflict.contentsMatch ? "doc.on.doc" : "exclamationmark.triangle"
        )
        .foregroundStyle(conflict.contentsMatch ? Color.secondary : Color.orange)
        Text(conflictMessage(conflict))
          .font(.caption)
          .foregroundStyle(.secondary)
      } header: {
        Text("Name Conflict")
      }
    }
  }

  private var importActionSection: some View {
    Section {
      if preview.conflict != nil {
        TextField("New title", text: $title)
          .textInputAutocapitalization(.sentences)
        Button {
          errorMessage = onImportAsNew(titleForImport)
        } label: {
          Label("Import Renamed Copy", systemImage: "plus.bubble")
        }
        .disabled(!canImportAsNew)
      } else {
        Button {
          errorMessage = onImportAsNew(titleForImport)
        } label: {
          Label("Import Conversation", systemImage: "square.and.arrow.down")
        }
      }

      if let conflict = preview.conflict, !conflict.contentsMatch {
        Button(role: .destructive) {
          errorMessage = onUpdateExisting()
        } label: {
          Label("Update Existing", systemImage: "arrow.triangle.2.circlepath")
        }
      }
    }
  }

  private var titleForImport: String {
    title.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canImportAsNew: Bool {
    guard !titleForImport.isEmpty else { return false }
    let normalized = normalizedTitle(titleForImport)
    return !preview.existingTitles.contains {
      normalizedTitle($0) == normalized
    }
  }

  private func conflictTitle(_ conflict: ConversationImportConflict) -> String {
    conflict.contentsMatch ? "Already imported" : "Title already exists"
  }

  private func conflictMessage(_ conflict: ConversationImportConflict) -> String {
    if conflict.contentsMatch {
      return "\"\(conflict.existingTitle)\" has the same conversation contents."
    }
    return "\"\(conflict.existingTitle)\" uses this title with different conversation contents."
  }

  private func infoRow(_ title: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
      Spacer(minLength: 12)
      Text(displayValue(value))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
    }
  }

  private func displayValue(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Not specified" : trimmed
  }

  private func formattedDate(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
  }

  private func normalizedTitle(_ title: String) -> String {
    title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}

struct SettingsToastModifier: ViewModifier {
  @Binding var message: String?

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .top) {
        if let message {
          Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.red, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            .padding(.top, 12)
            .padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
            .zIndex(1)
        }
      }
      .onChange(of: message) { _, newValue in
        guard let newValue else { return }
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(3))
          guard message == newValue else { return }
          withAnimation(.snappy) {
            message = nil
          }
        }
      }
  }
}

extension View {
  func settingsToast(_ message: Binding<String?>) -> some View {
    modifier(SettingsToastModifier(message: message))
  }
}

private struct EndpointDetailView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @Binding private var savedEndpoint: OpenAIEndpoint
  @State private var endpoint: OpenAIEndpoint
  @State private var modelFilter = ""
  @State private var toastMessage: String?
  @State private var isSigningIn = false
  @State private var showAdvancedOAuthConfiguration = false
  @State private var showOllamaScanner = false
  private let onSave: ((OpenAIEndpoint) -> Void)?

  init(endpoint: Binding<OpenAIEndpoint>, onSave: ((OpenAIEndpoint) -> Void)? = nil) {
    self._savedEndpoint = endpoint
    self._endpoint = State(initialValue: endpoint.wrappedValue)
    self.onSave = onSave
  }

  var body: some View {
    Form {
      Section {
        Toggle("Enabled", isOn: $endpoint.isEnabled)
        TextField(OpenAIEndpoint.defaultDisplayName, text: $endpoint.name)
      } footer: {
        Text("A friendly name shown in the provider picker.")
      }

      Section {
        Picker("Provider", selection: providerPresetBinding) {
          ForEach(endpointProviderPresets, id: \.tag) { preset in
            Text(preset.name).tag(preset.tag)
          }
          Text("Custom").tag(customProviderTag)
        }
        .pickerStyle(.menu)
        TextField("https://api.example.com/v1", text: $endpoint.baseURL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
        authenticationControls
        if showsOllamaScanButton {
          Button {
            showOllamaScanner = true
          } label: {
            Label("Scan Local Network", systemImage: "network")
          }
        }
        Button {
          if let message = EndpointNameResolution.connectionValidationMessage(for: endpoint) {
            showToast(message)
            return
          }
          let snapshot = endpoint
          Task { await store.refreshEndpoint(snapshot) }
        } label: {
          if isChecking {
            HStack {
              ProgressView()
              Text("Testing connection…")
            }
          } else {
            Label("Test & Refresh Models & Voices", systemImage: "arrow.clockwise")
          }
        }
        .disabled(isChecking)
        if let scheme = URL(string: endpoint.baseURL)?.scheme?.lowercased(),
          !scheme.isEmpty,
          !["http", "https"].contains(scheme)
        {
          Label("Only http and https are supported", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
        }
      } header: {
        Text("Connection")
      } footer: {
        Text(
          "Pick a provider to autofill the base URL, or choose Custom to enter your own. OAuth setup is shown only for providers that support it, or for Custom endpoints."
        )
      }

      if effectiveAuthMethod == .oauth {
        oauthConfigSection
      }

      Section {
        modelField
        reasoningLevelField
      } header: {
        Text("Default Model")
      } footer: {
        statusFooter
      }
    }
    .navigationTitle(endpoint.displayName)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { saveEndpointAndDismiss() }
      }
    }
    .onAppear(perform: normalizeAuthForSelectedProvider)
    .onChange(of: endpoint.baseURL) { _, _ in normalizeAuthForSelectedProvider() }
    .sheet(isPresented: $showOllamaScanner) {
      OllamaPortScanView(
        initialRange: OllamaNetworkScanner.defaultRange(),
        initialPort: OllamaNetworkScanner.defaultPort
      ) { url in
        applyScannedOllamaURL(url)
        showOllamaScanner = false
      }
    }
    .settingsToast($toastMessage)
  }

  @ViewBuilder
  private var authenticationControls: some View {
    let methods = authMethodsForCurrentProvider
    if methods.count > 1 {
      Picker("Authentication", selection: authMethodBinding) {
        ForEach(methods) { method in
          Text(method.displayName).tag(method)
        }
      }
      .pickerStyle(.menu)
    } else if methods.first == .oauth {
      LabeledContent("Authentication") {
        Text(EndpointAuthMethod.oauth.displayName)
          .foregroundStyle(.secondary)
      }
    }

    switch effectiveAuthMethod {
    case .apiKey:
      SecureField("API Key", text: $endpoint.apiKey)
      if let apiKeyOnlyProvider {
        apiKeyOnlyGuidance(for: apiKeyOnlyProvider)
      }
    case .oauth:
      oauthCredentialsView
    }
  }

  @ViewBuilder
  private var oauthCredentialsView: some View {
    let signedIn = !endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let expired = endpoint.oauthAccessTokenExpired
    let hasRefresh =
      !endpoint.oauthRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let setupMessage = oauthSetupMessage
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(
          systemName: signedIn && !expired
            ? "checkmark.seal.fill"
            : (signedIn ? "exclamationmark.triangle.fill" : "person.crop.circle.badge.questionmark")
        )
        .foregroundStyle(
          signedIn && !expired
            ? Color.green
            : (signedIn ? Color.orange : Color.secondary))
        Text(oauthStatusText(signedIn: signedIn, expired: expired))
          .font(.subheadline)
      }
      if let expiry = endpoint.oauthAccessTokenExpiresAt {
        Text(
          "Access token \(expired ? "expired" : "expires") \(expiry.formatted(date: .abbreviated, time: .shortened))."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      if let setupMessage {
        Label(setupMessage, systemImage: "info.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 10) {
        Button {
          Task { await runSignIn() }
        } label: {
          if isSigningIn {
            HStack(spacing: 6) {
              ProgressView()
              Text("Signing in…")
            }
          } else {
            Label(
              signedIn ? "Sign In Again" : "Sign In",
              systemImage: "person.crop.circle.badge.checkmark")
          }
        }
        .disabled(isSigningIn || setupMessage != nil)
        if signedIn {
          Button(role: .destructive) {
            signOut()
          } label: {
            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
          }
          .disabled(isSigningIn)
        }
      }
      if signedIn && hasRefresh {
        Button {
          Task { await runRefresh() }
        } label: {
          Label("Refresh Token", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(isSigningIn)
      }
    }
  }

  private var oauthConfigSection: some View {
    Section {
      if isOpenAIEndpoint {
        openAIOAuthGuidance
      } else if let apiKeyOnlyProvider {
        apiKeyOnlyGuidance(for: apiKeyOnlyProvider)
      } else {
        genericOAuthGuidance
      }
      DisclosureGroup(isExpanded: $showAdvancedOAuthConfiguration) {
        TextField("Issuer (https://auth.example.com)", text: $endpoint.oauthIssuer)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
        TextField("Client ID", text: $endpoint.oauthClientID)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        TextField("Audience (optional)", text: $endpoint.oauthAudience)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        TextField("Scope", text: $endpoint.oauthScope)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        TextField("Redirect URI", text: $endpoint.oauthRedirectURI)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
        TextField("Authorize URL (optional)", text: $endpoint.oauthAuthorizeURL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
        TextField("Token URL (optional)", text: $endpoint.oauthTokenURL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
      } label: {
        Label("Advanced OAuth Configuration", systemImage: "slider.horizontal.3")
      }
    } header: {
      Text("OAuth")
    } footer: {
      Text(
        "These fields are only needed for providers that require a registered OAuth application. Leave Authorize and Token URLs blank to derive them from the issuer."
      )
    }
  }

  private func apiKeyOnlyGuidance(for provider: APIKeyOnlyProvider) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("No \(provider.name) OAuth client ID", systemImage: "key.slash")
        .font(.subheadline.weight(.semibold))
      Text(provider.message)
        .font(.caption)
        .foregroundStyle(.secondary)
      Button {
        endpoint.authMethod = .apiKey
        clearCredentials()
        UIApplication.shared.open(provider.apiKeyURL)
      } label: {
        Label("Open \(provider.name) API Keys", systemImage: "arrow.up.right.square")
      }
      .buttonStyle(.borderless)
      if let dashboardURL = provider.dashboardURL {
        Button {
          UIApplication.shared.open(dashboardURL)
        } label: {
          Label("Open \(provider.name) Dashboard", systemImage: "safari")
        }
        .buttonStyle(.borderless)
      }
    }
  }

  private var openAIOAuthGuidance: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("OpenAI OAuth", systemImage: "person.crop.circle.badge.checkmark")
        .font(.subheadline.weight(.semibold))
      Text(
        "Use OAuth here if you have an OpenAI OAuth client ID registered for pocketmai://oauth/callback. Otherwise use API Key above."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Button {
        if let url = URL(string: "https://platform.openai.com") {
          UIApplication.shared.open(url)
        }
      } label: {
        Label("Open OpenAI Dashboard", systemImage: "safari")
      }
      .buttonStyle(.borderless)
    }
  }

  private var genericOAuthGuidance: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("OAuth client ID", systemImage: "person.badge.key")
        .font(.subheadline.weight(.semibold))
      Text(
        "Create an OAuth client in the provider's developer console, copy its client ID here, and register pocketmai://oauth/callback as an allowed redirect URI."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      if isGoogleVertexEndpoint,
        let url = URL(string: "https://console.cloud.google.com/apis/credentials")
      {
        Link(destination: url) {
          Label("Open Google OAuth Clients", systemImage: "arrow.up.right.square")
        }
      }
    }
  }

  private var oauthSetupMessage: String? {
    guard effectiveAuthMethod == .oauth else { return nil }
    let clientID = endpoint.oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard clientID.isEmpty else { return nil }
    if isOpenAIEndpoint {
      return "OpenAI OAuth needs a client ID before Sign In can open."
    }
    if isAnthropicEndpoint {
      return "Anthropic API auth uses API keys here. Use the button below."
    }
    return "OAuth needs a client ID before Sign In can open."
  }

  private struct APIKeyOnlyProvider {
    let name: String
    let message: String
    let apiKeyURL: URL
    let dashboardURL: URL?
  }

  private var apiKeyOnlyProvider: APIKeyOnlyProvider? {
    if isAnthropicEndpoint,
      let apiKeyURL = URL(string: "https://console.anthropic.com/settings/keys"),
      let dashboardURL = URL(string: "https://console.anthropic.com")
    {
      return APIKeyOnlyProvider(
        name: "Anthropic",
        message:
          "There is no Anthropic OAuth client ID you can generate here for the public API. Use OAuth only if you own a registered OAuth app that allows pocketmai://oauth/callback.",
        apiKeyURL: apiKeyURL,
        dashboardURL: dashboardURL
      )
    }
    return nil
  }

  private var isOpenAIEndpoint: Bool {
    endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
      == OpenAIEndpoint.openAIAuthDefaults.baseURL
  }

  private var isAnthropicEndpoint: Bool {
    endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
      == OpenAIEndpoint.anthropicOAuthDefaults.baseURL
  }

  private var isGoogleVertexEndpoint: Bool {
    endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
      == OpenAIEndpoint.googleOAuthDefaults.baseURL
  }

  private var showsOllamaScanButton: Bool {
    if selectedProviderPreset?.name == "Ollama" {
      return true
    }
    if endpoint.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ollama" {
      return true
    }
    return OllamaNetworkScanner.isLikelyLocalOllamaBaseURL(endpoint.baseURL)
  }

  private var selectedProviderPreset: EndpointProviderPreset? {
    EndpointNameResolution.providerPreset(forBaseURL: endpoint.baseURL)
  }

  private var authMethodsForCurrentProvider: [EndpointAuthMethod] {
    if let selectedProviderPreset {
      return selectedProviderPreset.authMethods
    }
    return [.apiKey]
  }

  private var effectiveAuthMethod: EndpointAuthMethod {
    let methods = authMethodsForCurrentProvider
    if methods.contains(endpoint.authMethod) {
      return endpoint.authMethod
    }
    return methods.first ?? .apiKey
  }

  private func oauthStatusText(signedIn: Bool, expired: Bool) -> String {
    if !signedIn { return "Not signed in" }
    if expired { return "Signed in (token expired)" }
    return "Signed in"
  }

  @MainActor
  private func runSignIn() async {
    isSigningIn = true
    defer { isSigningIn = false }
    do {
      let tokens = try await OAuthService.signIn(endpoint: endpoint)
      applyTokens(tokens)
      persistOAuthState()
      showToast("Signed in successfully.")
    } catch let error as OAuthError {
      if case .userCancelled = error { return }
      showToast(error.localizedDescription)
    } catch {
      showToast(error.localizedDescription)
    }
  }

  @MainActor
  private func runRefresh() async {
    isSigningIn = true
    defer { isSigningIn = false }
    do {
      let tokens = try await OAuthService.refresh(endpoint: endpoint)
      applyTokens(tokens)
      persistOAuthState()
      showToast("Access token refreshed.")
    } catch {
      showToast(error.localizedDescription)
    }
  }

  private func applyTokens(_ tokens: OAuthTokens) {
    endpoint.apiKey = tokens.accessToken
    if let refresh = tokens.refreshToken {
      endpoint.oauthRefreshToken = refresh
    }
    endpoint.oauthAccessTokenExpiresAt = tokens.expiresAt
  }

  private func signOut() {
    endpoint.apiKey = ""
    endpoint.oauthRefreshToken = ""
    endpoint.oauthAccessTokenExpiresAt = nil
    persistOAuthState()
    showToast("Signed out.")
  }

  /// Persist the current OAuth credential state immediately so a successful sign-in
  /// survives navigating away without an explicit Save tap.
  private func persistOAuthState() {
    if let index = store.settings.openAIEndpoints.firstIndex(where: { $0.id == endpoint.id }) {
      store.settings.openAIEndpoints[index] = endpoint
      savedEndpoint = endpoint
      store.saveSettings()
    }
  }

  @ViewBuilder
  private var modelField: some View {
    let models = store.endpointModels[endpoint.id] ?? []
    if models.isEmpty {
      TextField("Model name", text: $endpoint.defaultModel)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    } else {
      FilteredModelPicker(
        selection: $endpoint.defaultModel,
        filter: $modelFilter,
        models: models,
        emptySelectionTitle: "Select a model"
      )
    }
  }

  private var reasoningLevelField: some View {
    ReasoningLevelControl(level: $endpoint.defaultReasoningLevel)
  }

  @ViewBuilder
  private var statusFooter: some View {
    let status = store.endpointStatuses[endpoint.id] ?? .unknown
    let models = store.endpointModels[endpoint.id] ?? []
    let voices = store.endpointVoices[endpoint.id] ?? []
    switch status {
    case .unknown:
      Text("Tap “Test & Refresh Models & Voices” to verify the connection and load capabilities.")
    case .checking:
      Text("Testing connection…")
    case .available:
      if models.isEmpty && voices.isEmpty {
        Text("Connected.")
      } else if voices.isEmpty {
        Text("Connected. \(models.count) models available.")
      } else if models.isEmpty {
        Text("Connected. \(voices.count) voices available.")
      } else {
        Text("Connected. \(models.count) models and \(voices.count) voices available.")
      }
    case .failed(let message):
      Text(message).foregroundStyle(.red)
    }
  }

  private var isChecking: Bool {
    if case .checking = store.endpointStatuses[endpoint.id] {
      return true
    }
    return false
  }

  private func saveEndpointAndDismiss() {
    normalizeAuthForSelectedProvider()
    if let message = EndpointNameResolution.validationMessage(
      for: endpoint,
      in: store.settings.openAIEndpoints)
    {
      showToast(message)
      return
    }
    if let savedName = EndpointNameResolution.savedName(for: endpoint) {
      endpoint.name = savedName
    }
    let connectionChanged =
      endpoint.baseURL != savedEndpoint.baseURL || endpoint.apiKey != savedEndpoint.apiKey
    savedEndpoint = endpoint
    onSave?(endpoint)
    if connectionChanged {
      store.resetEndpointStatus(endpoint.id)
    }
    store.saveSettings()
    dismiss()
  }

  private func showToast(_ message: String) {
    withAnimation(.snappy) {
      toastMessage = message
    }
  }

  private func applyScannedOllamaURL(_ url: String) {
    endpoint.baseURL = url
    endpoint.authMethod = .apiKey
    clearCredentials()
    if endpoint.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      endpoint.name = "Ollama"
    }
  }

  private var providerPresetBinding: Binding<String> {
    Binding(
      get: {
        let trimmed = endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let preset = EndpointNameResolution.providerPreset(forBaseURL: trimmed) {
          return preset.tag
        }
        return customProviderTag
      },
      set: { newValue in
        if newValue == customProviderTag {
          if endpoint.authMethod != .apiKey {
            clearCredentials()
            endpoint.authMethod = .apiKey
          }
          endpoint.baseURL = ""
          return
        }
        guard let preset = endpointProviderPresets.first(where: { $0.tag == newValue }) else {
          return
        }
        let oldAuthMethod = endpoint.authMethod
        let oldBaseURL = endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        endpoint.baseURL = preset.url
        if let preferredAuthMethod = preset.preferredAuthMethod,
          preset.authMethods.contains(preferredAuthMethod)
        {
          endpoint.authMethod = preferredAuthMethod
        } else if !preset.authMethods.contains(endpoint.authMethod) {
          endpoint.authMethod = preset.authMethods.first ?? .apiKey
        }
        let authChanged = oldAuthMethod != endpoint.authMethod
        let oauthProviderChanged =
          endpoint.authMethod == .oauth && oldBaseURL != preset.url
        if authChanged || oauthProviderChanged {
          clearCredentials()
        }
        if endpoint.authMethod == .oauth,
          preset.authMethods.contains(.oauth),
          let defaults = preset.oauthDefaults
        {
          applyOAuthDefaults(defaults, overwriteExisting: true)
        }
      }
    )
  }

  private var authMethodBinding: Binding<EndpointAuthMethod> {
    Binding(
      get: { endpoint.authMethod },
      set: { newValue in
        guard newValue != endpoint.authMethod else { return }
        clearCredentials()
        endpoint.authMethod = newValue
        if newValue == .oauth {
          applyOAuthDefaultsIfMissing()
        }
      }
    )
  }

  private func applyOAuthDefaults(
    _ defaults: OAuthPresetDefaults,
    overwriteExisting: Bool = false
  ) {
    endpoint.authMethod = .oauth
    endpoint.baseURL = defaults.baseURL
    fillOAuthDefaults(defaults, overwriteExisting: overwriteExisting)
  }

  private func fillOAuthDefaults(_ defaults: OAuthPresetDefaults, overwriteExisting: Bool) {
    if overwriteExisting
      || endpoint.oauthIssuer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      endpoint.oauthIssuer = defaults.issuer
    }
    if overwriteExisting
      || endpoint.oauthAudience.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      endpoint.oauthAudience = defaults.audience
    }
    if overwriteExisting
      || endpoint.oauthScope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      endpoint.oauthScope = defaults.scope
    }
    if overwriteExisting
      || endpoint.oauthRedirectURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      endpoint.oauthRedirectURI = defaults.redirectURI
    }
    if overwriteExisting
      || endpoint.oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      endpoint.oauthClientID = defaults.clientID
    }
    if overwriteExisting
      || endpoint.oauthAuthorizeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      endpoint.oauthAuthorizeURL = defaults.authorizeURL
    }
    if overwriteExisting
      || endpoint.oauthTokenURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      endpoint.oauthTokenURL = defaults.tokenURL
    }
  }

  private func applyOAuthDefaultsIfMissing() {
    let providerPreset = EndpointNameResolution.providerPreset(forBaseURL: endpoint.baseURL)
    let matchingPreset = EndpointNameResolution.matchingOAuthPreset(for: endpoint)
    let defaults: OAuthPresetDefaults?
    if let providerPreset, providerPreset.authMethods.contains(.oauth) {
      defaults = providerPreset.oauthDefaults
    } else {
      defaults = matchingPreset?.oauthDefaults
    }
    guard let defaults else { return }
    let shouldOverwrite =
      providerPreset?.oauthDefaults != nil
      && matchingPreset != nil
      && providerPreset?.tag != matchingPreset?.tag
    fillOAuthDefaults(defaults, overwriteExisting: shouldOverwrite)
  }

  private func normalizeAuthForSelectedProvider() {
    let methods = authMethodsForCurrentProvider
    guard !methods.contains(endpoint.authMethod) else { return }
    clearCredentials()
    endpoint.authMethod = methods.first ?? .apiKey
    if endpoint.authMethod == .oauth {
      applyOAuthDefaultsIfMissing()
    }
  }

  private func clearCredentials() {
    endpoint.apiKey = ""
    endpoint.oauthRefreshToken = ""
    endpoint.oauthAccessTokenExpiresAt = nil
  }
}

private struct OllamaPortScanView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var rangeText: String
  @State private var portText: String
  @State private var isScanning = false
  @State private var results: [OllamaScanResult] = []
  @State private var message: String?
  @State private var scanTask: Task<Void, Never>?

  let onSelect: (String) -> Void

  init(
    initialRange: String,
    initialPort: Int,
    onSelect: @escaping (String) -> Void
  ) {
    self._rangeText = State(initialValue: initialRange)
    self._portText = State(initialValue: String(initialPort))
    self.onSelect = onSelect
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("192.168.1.x", text: $rangeText)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.numbersAndPunctuation)
            .submitLabel(.search)
            .onSubmit { startScan() }
          TextField("Port", text: $portText)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.numberPad)
          Button {
            startScan()
          } label: {
            if isScanning {
              HStack {
                ProgressView()
                Text("Scanning…")
              }
            } else {
              Label("Scan", systemImage: "dot.radiowaves.left.and.right")
            }
          }
          .disabled(isScanning || parsedPort == nil)
          if let message {
            Text(message)
              .font(.caption)
              .foregroundStyle(messageIsError ? .red : .secondary)
          }
        } header: {
          Text("Network")
        } footer: {
          Text("Use x, *, a single host, or a final-octet range such as 192.168.1.20-40.")
        }

        Section {
          if results.isEmpty {
            Text(isScanning ? "Looking for Ollama endpoints…" : "No scan results yet.")
              .foregroundStyle(.secondary)
          } else {
            ForEach(results) { result in
              Button {
                scanTask?.cancel()
                onSelect(result.url)
                dismiss()
              } label: {
                HStack {
                  Text(result.url)
                    .textSelection(.enabled)
                  Spacer()
                  Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                }
              }
            }
          }
        } header: {
          Text("Results")
        }
      }
      .navigationTitle("Find Ollama")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            scanTask?.cancel()
            dismiss()
          }
        }
      }
    }
    .onDisappear {
      scanTask?.cancel()
    }
  }

  private var parsedPort: Int? {
    let trimmed = portText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let port = Int(trimmed), (1...65535).contains(port) else { return nil }
    return port
  }

  private var messageIsError: Bool {
    guard let message else { return false }
    return message.hasPrefix("Invalid") || message.hasPrefix("Enter")
  }

  private func startScan() {
    guard !isScanning else { return }
    guard let port = parsedPort else {
      message = "Invalid port. Use a number from 1 to 65535."
      return
    }

    scanTask?.cancel()
    results = []
    message = "Scanning \(rangeText):\(port)…"
    isScanning = true
    let range = rangeText
    scanTask = Task {
      do {
        let found = try await OllamaNetworkScanner.scan(rangeText: range, port: port) { result in
          if !results.contains(result) {
            results.append(result)
          }
        }
        guard !Task.isCancelled else { return }
        await MainActor.run {
          results = found
          message =
            found.isEmpty
            ? "No Ollama endpoints found."
            : "Found \(found.count) endpoint\(found.count == 1 ? "" : "s")."
          isScanning = false
        }
      } catch {
        guard !Task.isCancelled else { return }
        await MainActor.run {
          message = error.localizedDescription
          isScanning = false
        }
      }
    }
  }
}

private enum PromptNameResolution {
  static func savedName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func validationMessage(
    forName name: String,
    excludingSystemPromptID: UUID?,
    excludingUserPromptID: UUID?,
    systemPrompts: [SystemPrompt],
    userPrompts: [UserPrompt]
  ) -> String? {
    let savedName = savedName(name)
    guard !savedName.isEmpty else {
      return "Specify a prompt name."
    }
    if savedName.contains(where: { $0.isWhitespace }) || savedName.contains("/") {
      return "Prompt names cannot contain spaces or /."
    }
    if hasDuplicateCommandName(
      savedName,
      excludingSystemPromptID: excludingSystemPromptID,
      excludingUserPromptID: excludingUserPromptID,
      systemPrompts: systemPrompts,
      userPrompts: userPrompts)
    {
      return "A prompt named \"\(savedName)\" already exists."
    }
    return nil
  }

  private static func hasDuplicateCommandName(
    _ name: String,
    excludingSystemPromptID: UUID?,
    excludingUserPromptID: UUID?,
    systemPrompts: [SystemPrompt],
    userPrompts: [UserPrompt]
  ) -> Bool {
    let normalized = normalizedName(PromptSlashCommand.commandName(for: name))
    if systemPrompts.contains(where: { prompt in
      guard prompt.id != excludingSystemPromptID else { return false }
      return normalizedName(prompt.slashCommandName) == normalized
    }) {
      return true
    }
    return userPrompts.contains { prompt in
      guard prompt.id != excludingUserPromptID else { return false }
      return normalizedName(prompt.slashCommandName) == normalized
    }
  }

  private static func normalizedName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}

private struct SystemPromptDetailView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @FocusState private var isNameFocused: Bool

  private static let newPromptText = "You are a helpful assistant."

  private let promptID: UUID?
  private let originalName: String
  private let originalText: String
  private let originalIsDefault: Bool

  @State private var draftName: String
  @State private var draftText: String
  @State private var draftIsDefault: Bool
  @State private var showingLeaveConfirmation = false
  @State private var toastMessage: String?

  init(prompt: SystemPrompt? = nil, isDefault: Bool = false) {
    let initialName = prompt?.name ?? ""
    let initialText = prompt?.text ?? Self.newPromptText

    promptID = prompt?.id
    originalName = initialName
    originalText = initialText
    originalIsDefault = isDefault

    _draftName = State(initialValue: initialName)
    _draftText = State(initialValue: initialText)
    _draftIsDefault = State(initialValue: isDefault)
  }

  var body: some View {
    Form {
      Section {
        TextField("Name", text: $draftName)
          .focused($isNameFocused)
      } footer: {
        Text("Shown in the prompt picker.")
      }
      Section {
        TextEditor(text: $draftText)
          .frame(minHeight: 220)
          .font(.callout)
      } header: {
        Text("Instructions")
      } footer: {
        Text("Sent to the model at the start of each chat.")
      }
    }
    .navigationTitle(navigationTitle)
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(true)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button {
          requestDismiss()
        } label: {
          Label(isNewPrompt ? "Cancel" : "Back", systemImage: "chevron.left")
        }
      }
      ToolbarItemGroup(placement: .confirmationAction) {
        Button {
          draftIsDefault = true
        } label: {
          Image(systemName: draftIsDefault ? "star.fill" : "star")
        }
        .accessibilityLabel(draftIsDefault ? "Default Prompt" : "Make Default Prompt")
        .foregroundStyle(draftIsDefault ? Color.accentColor : .primary)
        Button("Save") {
          savePromptAndDismiss()
        }
      }
    }
    .alert("Save changes?", isPresented: $showingLeaveConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Discard Changes", role: .destructive) {
        dismiss()
      }
      Button("Save") {
        savePromptAndDismiss()
      }
    } message: {
      Text("Save or discard changes before leaving this prompt.")
    }
    .settingsToast($toastMessage)
    .onAppear {
      if isNewPrompt {
        isNameFocused = true
      }
    }
  }

  private var isNewPrompt: Bool {
    promptID == nil
  }

  private var navigationTitle: String {
    let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
    return isNewPrompt ? "New Prompt" : "Prompt"
  }

  private var hasUnsavedChanges: Bool {
    draftName != originalName
      || draftText != originalText
      || draftIsDefault != originalIsDefault
  }

  private func requestDismiss() {
    guard hasUnsavedChanges else {
      dismiss()
      return
    }
    showingLeaveConfirmation = true
  }

  private func savePromptAndDismiss() {
    let savedName = PromptNameResolution.savedName(draftName)
    let originalSavedName = PromptNameResolution.savedName(originalName)
    if isNewPrompt || savedName != originalSavedName {
      if let message = PromptNameResolution.validationMessage(
        forName: draftName,
        excludingSystemPromptID: promptID,
        excludingUserPromptID: nil,
        systemPrompts: store.settings.systemPrompts,
        userPrompts: store.settings.userPrompts)
      {
        showToast(message)
        return
      }
    }

    if let promptID {
      guard let index = store.settings.systemPrompts.firstIndex(where: { $0.id == promptID })
      else {
        showToast("This prompt no longer exists.")
        return
      }
      store.settings.systemPrompts[index].name = savedName
      store.settings.systemPrompts[index].text = draftText
      if draftIsDefault {
        store.settings.defaultSystemPromptID = promptID
      }
    } else {
      let prompt = SystemPrompt(name: savedName, text: draftText)
      store.settings.systemPrompts.append(prompt)
      if draftIsDefault {
        store.settings.defaultSystemPromptID = prompt.id
      }
    }

    store.saveSettings()
    dismiss()
  }

  private func showToast(_ message: String) {
    withAnimation(.snappy) {
      toastMessage = message
    }
  }
}

private struct UserPromptDetailView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @FocusState private var isNameFocused: Bool

  private static let newPromptText = "Use these instructions when answering."

  private let promptID: UUID?
  private let originalName: String
  private let originalText: String

  @State private var draftName: String
  @State private var draftText: String
  @State private var showingLeaveConfirmation = false
  @State private var toastMessage: String?

  init(prompt: UserPrompt? = nil) {
    let initialName = prompt?.name ?? ""
    let initialText = prompt?.text ?? Self.newPromptText

    promptID = prompt?.id
    originalName = initialName
    originalText = initialText

    _draftName = State(initialValue: initialName)
    _draftText = State(initialValue: initialText)
  }

  var body: some View {
    Form {
      Section {
        TextField("Name", text: $draftName)
          .focused($isNameFocused)
      } footer: {
        Text("Used as /name in the chat composer.")
      }
      Section {
        TextEditor(text: $draftText)
          .frame(minHeight: 220)
          .font(.callout)
      } header: {
        Text("Prompt")
      } footer: {
        Text("Prepended to the user message before sending to the model.")
      }
    }
    .navigationTitle(navigationTitle)
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(true)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button {
          requestDismiss()
        } label: {
          Label(isNewPrompt ? "Cancel" : "Back", systemImage: "chevron.left")
        }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          savePromptAndDismiss()
        }
      }
    }
    .alert("Save changes?", isPresented: $showingLeaveConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Discard Changes", role: .destructive) {
        dismiss()
      }
      Button("Save") {
        savePromptAndDismiss()
      }
    } message: {
      Text("Save or discard changes before leaving this prompt.")
    }
    .settingsToast($toastMessage)
    .onAppear {
      if isNewPrompt {
        isNameFocused = true
      }
    }
  }

  private var isNewPrompt: Bool {
    promptID == nil
  }

  private var navigationTitle: String {
    let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
    return isNewPrompt ? "New User Prompt" : "User Prompt"
  }

  private var hasUnsavedChanges: Bool {
    draftName != originalName || draftText != originalText
  }

  private func requestDismiss() {
    guard hasUnsavedChanges else {
      dismiss()
      return
    }
    showingLeaveConfirmation = true
  }

  private func savePromptAndDismiss() {
    let savedName = PromptNameResolution.savedName(draftName)
    let originalSavedName = PromptNameResolution.savedName(originalName)
    if isNewPrompt || savedName != originalSavedName {
      if let message = PromptNameResolution.validationMessage(
        forName: draftName,
        excludingSystemPromptID: nil,
        excludingUserPromptID: promptID,
        systemPrompts: store.settings.systemPrompts,
        userPrompts: store.settings.userPrompts)
      {
        showToast(message)
        return
      }
    }

    if let promptID {
      guard let index = store.settings.userPrompts.firstIndex(where: { $0.id == promptID })
      else {
        showToast("This prompt no longer exists.")
        return
      }
      store.settings.userPrompts[index].name = savedName
      store.settings.userPrompts[index].text = draftText
    } else {
      store.settings.userPrompts.append(UserPrompt(name: savedName, text: draftText))
    }

    store.saveSettings()
    dismiss()
  }

  private func showToast(_ message: String) {
    withAnimation(.snappy) {
      toastMessage = message
    }
  }
}

private struct CompactPromptDetailView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss

  @State private var draftText = ""
  @State private var showingLeaveConfirmation = false

  var body: some View {
    Form {
      Section {
        TextEditor(text: $draftText)
          .frame(minHeight: 320)
          .font(.callout.monospaced())
          .autocorrectionDisabled()
      } header: {
        Text("Instructions")
      } footer: {
        Text(
          "Use {{transcript}} where the conversation transcript should be inserted. If omitted, the transcript is appended after the prompt."
        )
      }

      Section {
        Button {
          draftText = AppSettings.defaultCompactPrompt
        } label: {
          Label("Reset to Default", systemImage: "arrow.counterclockwise")
        }
      }
    }
    .navigationTitle("Compact Prompt")
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(true)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button {
          requestDismiss()
        } label: {
          Label("Back", systemImage: "chevron.left")
        }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          saveAndDismiss()
        }
      }
    }
    .alert("Save changes?", isPresented: $showingLeaveConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Discard Changes", role: .destructive) {
        dismiss()
      }
      Button("Save") {
        saveAndDismiss()
      }
    } message: {
      Text("Save or discard changes before leaving this prompt.")
    }
    .onAppear {
      if draftText.isEmpty {
        draftText = store.settings.compactPrompt
      }
    }
  }

  private var hasUnsavedChanges: Bool {
    draftText != store.settings.compactPrompt
  }

  private func requestDismiss() {
    guard hasUnsavedChanges else {
      dismiss()
      return
    }
    showingLeaveConfirmation = true
  }

  private func saveAndDismiss() {
    let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    store.settings.compactPrompt = trimmed.isEmpty ? AppSettings.defaultCompactPrompt : draftText
    store.saveSettings()
    dismiss()
  }
}

private enum MCPServerNameResolution {
  static func savedName(for server: MCPServer) -> String {
    server.name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func savedBaseURL(for server: MCPServer) -> String {
    server.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func validationMessage(for server: MCPServer, in servers: [MCPServer]) -> String? {
    let name = savedName(for: server)
    if !name.isEmpty, hasDuplicateName(name, excluding: server.id, in: servers) {
      return "Another MCP server is already named \"\(name)\"."
    }
    return endpointValidationMessage(for: server)
  }

  static func resolvedName(
    for server: MCPServer,
    serverInfoName: String?,
    in servers: [MCPServer]
  ) -> String {
    let manualName = savedName(for: server)
    if !manualName.isEmpty {
      return manualName
    }

    let detectedName =
      serverInfoName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let baseName = detectedName.isEmpty ? hostName(for: server) : detectedName
    return uniqueName(baseName.isEmpty ? "MCP Server" : baseName, excluding: server.id, in: servers)
  }

  static func endpointValidationMessage(for server: MCPServer) -> String? {
    let baseURL = savedBaseURL(for: server)
    guard !baseURL.isEmpty else {
      return "Specify an endpoint URL for this MCP server."
    }
    guard let components = URLComponents(string: baseURL),
      let scheme = components.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      let host = components.host,
      !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return "Specify a valid http or https endpoint URL."
    }
    return nil
  }

  private static func hasDuplicateName(
    _ name: String,
    excluding serverID: UUID,
    in servers: [MCPServer]
  ) -> Bool {
    let normalized = normalizedName(name)
    return servers.contains { server in
      guard server.id != serverID else { return false }
      return normalizedName(server.name) == normalized
    }
  }

  private static func hostName(for server: MCPServer) -> String {
    let baseURL = savedBaseURL(for: server)
    guard let host = URL(string: baseURL)?.host?.trimmingCharacters(in: .whitespacesAndNewlines),
      !host.isEmpty
    else {
      return "MCP Server"
    }
    return host
  }

  private static func uniqueName(
    _ name: String,
    excluding serverID: UUID,
    in servers: [MCPServer]
  ) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = trimmed.isEmpty ? "MCP Server" : trimmed
    guard hasDuplicateName(base, excluding: serverID, in: servers) else {
      return base
    }
    for suffix in 2...999 {
      let candidate = "\(base) \(suffix)"
      if !hasDuplicateName(candidate, excluding: serverID, in: servers) {
        return candidate
      }
    }
    return "\(base) \(UUID().uuidString.prefix(4))"
  }

  private static func normalizedName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}

private struct MCPServerDetailView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @Binding private var savedServer: MCPServer
  @State private var server: MCPServer
  @State private var draftStatus: EndpointConnectionState = .unknown
  @State private var draftTools: [MCPToolDescriptor] = []
  @State private var draftResources: [MCPResourceDescriptor] = []
  @State private var draftTransport: MCPTransport?
  @State private var draftProtocolVersion: String?
  @State private var draftServerName: String?
  @State private var draftStatusBaseURL: String
  @State private var toastMessage: String?
  @State private var isSaving = false
  @FocusState private var isNameFocused: Bool
  @FocusState private var isEndpointFocused: Bool
  private let isNew: Bool
  private let onSave: ((MCPServer) -> Void)?

  init(
    server: Binding<MCPServer>,
    isNew: Bool = false,
    onSave: ((MCPServer) -> Void)? = nil
  ) {
    self._savedServer = server
    self._server = State(initialValue: server.wrappedValue)
    self._draftTransport = State(initialValue: server.wrappedValue.transport)
    self._draftStatusBaseURL = State(
      initialValue: MCPServerNameResolution.savedBaseURL(for: server.wrappedValue))
    self.isNew = isNew
    self.onSave = onSave
  }

  var body: some View {
    Form {
      Section {
        Toggle("Enabled", isOn: $server.isEnabled)
        TextField("Name", text: $server.name)
          .focused($isNameFocused)
      } footer: {
        Text("Leave blank to use the name reported by the server.")
      }

      Section {
        TextField("https://example.com/mcp", text: $server.baseURL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
          .focused($isEndpointFocused)
        if !server.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && MCPServerNameResolution.endpointValidationMessage(for: server) != nil
        {
          Label(
            "Specify a valid http or https endpoint URL.", systemImage: "exclamationmark.triangle"
          )
          .foregroundStyle(.red)
        }
      } header: {
        Text("Endpoint")
      } footer: {
        Text("HTTP and HTTPS URLs are accepted. The transport is detected when connecting.")
      }

      Section {
        Button {
          if let message = MCPServerNameResolution.endpointValidationMessage(for: server) {
            showToast(message)
            return
          }
          let snapshot = normalizedServerForSaving
          refreshTools(snapshot)
        } label: {
          if isChecking {
            HStack {
              ProgressView()
              Text("Connecting…")
            }
          } else {
            Label("Refresh MCP", systemImage: "arrow.clockwise")
          }
        }
        .disabled(
          isChecking || isSaving
            || MCPServerNameResolution.endpointValidationMessage(for: server) != nil)
        if let transport = currentTransport {
          LabeledContent("Transport", value: transport.displayName)
        }
        if let protocolVersion = currentProtocolVersion, !protocolVersion.isEmpty {
          LabeledContent("Protocol", value: protocolVersion)
        }
      } header: {
        Text("Connection")
      } footer: {
        statusFooter
      }

      if !currentTools.isEmpty {
        let tools = currentTools
        Section("Available Tools (\(tools.count))") {
          ForEach(tools) { tool in
            VStack(alignment: .leading, spacing: 4) {
              Text(tool.name)
                .font(.callout.weight(.semibold))
              if !tool.description.isEmpty {
                Text(tool.description)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(4)
              }
            }
            .padding(.vertical, 2)
          }
        }
      }

      if !currentResources.isEmpty {
        let resources = currentResources
        Section("Available Resources (\(resources.count))") {
          ForEach(resources) { resource in
            VStack(alignment: .leading, spacing: 4) {
              Text(resource.uri)
                .font(.callout.weight(.semibold))
              if !resource.name.isEmpty {
                Text(resource.name)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
              }
              if !resource.description.isEmpty {
                Text(resource.description)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(4)
              }
            }
            .padding(.vertical, 2)
          }
        }
      }
    }
    .navigationTitle(navigationTitle)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button {
          saveServerAndDismiss()
        } label: {
          if isSaving {
            ProgressView()
          } else {
            Text("Save")
          }
        }
        .disabled(isSaving)
      }
    }
    .settingsToast($toastMessage)
    .onAppear {
      if isNew {
        isEndpointFocused = true
      }
    }
    .onDisappear {
      if hasUnsavedConnectionChanges {
        Task { await MCPHTTPClient.resetSession(for: server.id) }
      }
    }
  }

  private var navigationTitle: String {
    let name = MCPServerNameResolution.savedName(for: server)
    return name.isEmpty ? "MCP Server" : name
  }

  private var normalizedServerForSaving: MCPServer {
    var normalized = server
    normalized.name = MCPServerNameResolution.savedName(for: server)
    normalized.baseURL = MCPServerNameResolution.savedBaseURL(for: server)
    normalized.transport = currentTransport
    return normalized
  }

  private var hasUnsavedConnectionChanges: Bool {
    MCPServerNameResolution.savedBaseURL(for: server)
      != MCPServerNameResolution.savedBaseURL(for: savedServer)
  }

  private var draftStateMatchesCurrentEndpoint: Bool {
    draftStatusBaseURL == MCPServerNameResolution.savedBaseURL(for: server)
  }

  private var currentStatus: EndpointConnectionState {
    if hasUnsavedConnectionChanges {
      return draftStateMatchesCurrentEndpoint ? draftStatus : .unknown
    }
    return store.mcpStatuses[server.id] ?? .unknown
  }

  private var currentTools: [MCPToolDescriptor] {
    if hasUnsavedConnectionChanges {
      return draftStateMatchesCurrentEndpoint ? draftTools : []
    }
    return store.mcpTools[server.id] ?? []
  }

  private var currentResources: [MCPResourceDescriptor] {
    if hasUnsavedConnectionChanges {
      return draftStateMatchesCurrentEndpoint ? draftResources : []
    }
    return store.mcpResources[server.id] ?? []
  }

  private var currentTransport: MCPTransport? {
    if hasUnsavedConnectionChanges {
      return draftStateMatchesCurrentEndpoint ? draftTransport : server.transport
    }
    return server.transport ?? draftTransport
  }

  private var currentProtocolVersion: String? {
    guard draftStateMatchesCurrentEndpoint else { return nil }
    return draftProtocolVersion
  }

  private var isChecking: Bool {
    if case .checking = currentStatus {
      return true
    }
    return false
  }

  @ViewBuilder
  private var statusFooter: some View {
    let status = currentStatus
    let tools = currentTools
    let resources = currentResources
    switch status {
    case .unknown:
      Text("Transport will be detected when this server is refreshed or saved.")
    case .checking:
      Text("Connecting…")
    case .available:
      let transportText = currentTransport?.displayName ?? "MCP"
      if tools.isEmpty && resources.isEmpty {
        Text("Connected over \(transportText), but the server reports no tools or resources.")
      } else {
        Text(
          "Connected over \(transportText). \(tools.count) tool\(tools.count == 1 ? "" : "s"), \(resources.count) resource\(resources.count == 1 ? "" : "s") available."
        )
      }
    case .failed(let message):
      Text(message).foregroundStyle(.red)
    }
  }

  private func refreshTools(_ snapshot: MCPServer) {
    guard hasUnsavedConnectionChanges else {
      Task { await store.refreshMCP(snapshot) }
      return
    }

    draftStatusBaseURL = snapshot.baseURL
    draftStatus = .checking
    draftTools = []
    draftResources = []
    draftTransport = snapshot.transport
    draftProtocolVersion = nil
    draftServerName = nil
    Task {
      do {
        let catalog = try await MCPHTTPClient.fetchCatalog(server: snapshot)
        await MainActor.run {
          guard MCPServerNameResolution.savedBaseURL(for: server) == snapshot.baseURL else {
            return
          }
          draftTools = catalog.tools
          draftResources = catalog.resources
          draftTransport = catalog.transport
          draftProtocolVersion = catalog.protocolVersion
          draftServerName = catalog.serverName
          draftStatus = .available
        }
      } catch {
        await MainActor.run {
          guard MCPServerNameResolution.savedBaseURL(for: server) == snapshot.baseURL else {
            return
          }
          draftTools = []
          draftResources = []
          draftTransport = nil
          draftProtocolVersion = nil
          draftServerName = nil
          draftStatus = .failed(error.localizedDescription)
        }
      }
    }
  }

  private func saveServerAndDismiss() {
    guard !isSaving else { return }
    if let message = MCPServerNameResolution.validationMessage(
      for: server,
      in: store.settings.mcpServers)
    {
      showToast(message)
      return
    }

    var snapshot = normalizedServerForSaving
    if shouldProbeBeforeSave(snapshot) {
      probeAndSave(snapshot)
      return
    }

    snapshot.name = MCPServerNameResolution.resolvedName(
      for: snapshot,
      serverInfoName: draftServerName,
      in: store.settings.mcpServers)
    finalizeSave(snapshot)
  }

  private func shouldProbeBeforeSave(_ snapshot: MCPServer) -> Bool {
    guard snapshot.hasValidEndpointURL, !store.settings.airplaneModeEnabled else {
      return false
    }
    if snapshot.transport != nil, hasDraftConnectionState(for: snapshot) {
      return false
    }
    let connectionChanged =
      snapshot.baseURL != MCPServerNameResolution.savedBaseURL(for: savedServer)
    return isNew || connectionChanged || snapshot.transport == nil
  }

  private func probeAndSave(_ snapshot: MCPServer) {
    isSaving = true
    draftStatusBaseURL = snapshot.baseURL
    draftStatus = .checking
    draftTools = []
    draftResources = []
    draftTransport = snapshot.transport
    draftProtocolVersion = nil
    draftServerName = nil

    Task {
      do {
        let catalog = try await MCPHTTPClient.fetchCatalog(server: snapshot)
        await MainActor.run {
          guard MCPServerNameResolution.savedBaseURL(for: server) == snapshot.baseURL else {
            isSaving = false
            return
          }
          draftTools = catalog.tools
          draftResources = catalog.resources
          draftTransport = catalog.transport
          draftProtocolVersion = catalog.protocolVersion
          draftServerName = catalog.serverName
          draftStatus = .available

          var probed = snapshot
          probed.transport = catalog.transport ?? snapshot.transport
          probed.name = MCPServerNameResolution.resolvedName(
            for: probed,
            serverInfoName: catalog.serverName,
            in: store.settings.mcpServers)
          finalizeSave(probed)
          isSaving = false
        }
      } catch {
        await MainActor.run {
          guard MCPServerNameResolution.savedBaseURL(for: server) == snapshot.baseURL else {
            isSaving = false
            return
          }
          draftTools = []
          draftResources = []
          draftTransport = nil
          draftProtocolVersion = nil
          draftServerName = nil
          draftStatus = .failed(error.localizedDescription)
          isSaving = false
          showToast(error.localizedDescription)
        }
      }
    }
  }

  private func finalizeSave(_ normalized: MCPServer) {
    let connectionChanged =
      normalized.baseURL != MCPServerNameResolution.savedBaseURL(for: savedServer)
    server = normalized
    savedServer = normalized
    onSave?(normalized)
    if connectionChanged || hasDraftConnectionState(for: normalized) {
      applyDraftConnectionStateAfterSave(for: normalized)
    }
    store.saveSettings()
    dismiss()
  }

  private func hasDraftConnectionState(for server: MCPServer) -> Bool {
    guard draftStatusBaseURL == server.baseURL else {
      return false
    }
    switch draftStatus {
    case .available, .failed:
      return true
    case .unknown, .checking:
      return false
    }
  }

  private func applyDraftConnectionStateAfterSave(for server: MCPServer) {
    guard draftStatusBaseURL == server.baseURL else {
      store.resetMCPStatus(server.id)
      return
    }
    switch draftStatus {
    case .available:
      store.mcpTools[server.id] = draftTools
      store.mcpResources[server.id] = draftResources
      store.mcpStatuses[server.id] = .available
    case .failed(let message):
      store.mcpTools[server.id] = nil
      store.mcpResources[server.id] = nil
      store.mcpStatuses[server.id] = .failed(message)
    case .unknown, .checking:
      store.resetMCPStatus(server.id)
    }
  }

  private func showToast(_ message: String) {
    withAnimation(.snappy) {
      toastMessage = message
    }
  }
}
