import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

enum DefaultProviderSelection: Hashable {
  case apple
  case mlx
  case endpoint(UUID)
}

struct EndpointProviderPreset {
  let name: String
  let url: String
}

private struct PendingSettingsDeletion: Identifiable {
  let id = UUID()
  let kind: SettingsDeletionKind
  let offsets: IndexSet
}

private enum SettingsDeletionKind {
  case endpoint
  case systemPrompt
  case file
  case mcpServer

  var title: String {
    switch self {
    case .endpoint: "Delete provider?"
    case .systemPrompt: "Delete system prompt?"
    case .file: "Delete file?"
    case .mcpServer: "Delete MCP server?"
    }
  }

  func buttonTitle(count: Int) -> String {
    switch self {
    case .endpoint: "Delete \(itemName("Provider", count: count))"
    case .systemPrompt: "Delete \(itemName("Prompt", count: count))"
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
  EndpointProviderPreset(name: "OpenAI", url: "https://api.openai.com/v1"),
  EndpointProviderPreset(name: "Ollama Cloud", url: "https://ollama.com/v1"),
  EndpointProviderPreset(name: "OpenRouter", url: "https://openrouter.ai/api/v1"),
  EndpointProviderPreset(name: "OpenCode Zen", url: "https://opencode.ai/zen/v1"),
  EndpointProviderPreset(name: "Hugging Face", url: "https://router.huggingface.co/v1"),
  EndpointProviderPreset(name: "Mistral", url: "https://api.mistral.ai/v1"),
  EndpointProviderPreset(name: "xAI", url: "https://api.x.ai/v1"),
  EndpointProviderPreset(name: "DeepSeek", url: "https://api.deepseek.com/v1"),
  EndpointProviderPreset(name: "Groq", url: "https://api.groq.com/openai/v1"),
  EndpointProviderPreset(name: "Cerebras", url: "https://api.cerebras.ai/v1"),
  EndpointProviderPreset(name: "NVIDIA", url: "https://integrate.api.nvidia.com/v1"),
]

private let customProviderTag = "__custom__"

private enum TTSVoiceCache {
  static let voices: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices().sorted {
    if $0.language != $1.language { return $0.language < $1.language }
    return $0.name < $1.name
  }

  static let languages: [String] = Array(Set(voices.map(\.language))).sorted {
    languageDisplayName($0) < languageDisplayName($1)
  }

  static func voiceOptions(for language: String) -> [AVSpeechSynthesisVoice] {
    guard !language.isEmpty else { return voices }
    return voices.filter { $0.language == language }
  }

  static func languageDisplayName(_ language: String) -> String {
    let name = Locale.current.localizedString(forIdentifier: language) ?? language
    return "\(name) (\(language))"
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
  @State private var showingConversationImporter = false
  @State private var pendingConversationImport: ConversationImportPreview?
  @State private var newTodoTitle = ""
  @State private var showingClearAllConfirmation = false
  @State private var showingFactoryResetConfirmation = false
  @State private var showingClearMemoryConfirmation = false
  @State private var pendingDeletion: PendingSettingsDeletion?
  @State private var endpointPath: [UUID] = []
  @State private var toastMessage: String?

  var body: some View {
    NavigationStack(path: $endpointPath) {
      Form {
        providerSection
        appearanceSection
        toolsSection
        aboutSection
        dangerSection
      }
      .navigationDestination(for: UUID.self) { id in
        if let index = store.settings.openAIEndpoints.firstIndex(where: { $0.id == id }) {
          EndpointDetailView(endpoint: $store.settings.openAIEndpoints[index])
        }
      }
      .alert(
        "Clear all conversations?",
        isPresented: $showingClearAllConfirmation
      ) {
        Button("Cancel", role: .cancel) {}
        Button("Clear", role: .destructive) {
          store.clearAllConversations()
        }
      } message: {
        Text("Every chat and its messages will be deleted. This cannot be undone.")
      }
      .alert(
        "Factory reset PocketMai?",
        isPresented: $showingFactoryResetConfirmation
      ) {
        Button("Cancel", role: .cancel) {}
        Button("Factory Reset", role: .destructive) {
          store.factoryReset()
          dismiss()
        }
      } message: {
        Text(
          "All conversations, settings, providers, API keys, memory, tools, and local app data will be removed from this device. This cannot be undone."
        )
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
      .navigationTitle("Settings")
      .toolbar {
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
      .fileImporter(
        isPresented: $showingConversationImporter,
        allowedContentTypes: [.json]
      ) { result in
        switch result {
        case .success(let url):
          Task { await prepareConversationImport(from: url) }
        case .failure(let error):
          showToast(error.localizedDescription)
        }
      }
      .sheet(item: $pendingConversationImport) { preview in
        ConversationImportConfirmationView(
          preview: preview,
          onCancel: {
            pendingConversationImport = nil
          },
          onImportAsNew: { title in
            finishConversationImport(preview, resolution: .create(title: title))
          },
          onUpdateExisting: {
            finishConversationImport(preview, resolution: .updateExisting)
          }
        )
      }
    }
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
      Picker("Default", selection: defaultProviderBinding) {
        Label("Apple Intelligence", systemImage: "apple.logo")
          .tag(DefaultProviderSelection.apple)
        Label("MLX Local", systemImage: "cpu")
          .tag(DefaultProviderSelection.mlx)
        ForEach(store.settings.openAIEndpoints.filter(\.isEnabled)) { endpoint in
          Label(endpoint.displayName, systemImage: "network")
            .tag(DefaultProviderSelection.endpoint(endpoint.id))
        }
      }
      .pickerStyle(.menu)

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
        advancedOptionsContent
      } label: {
        Label("Advanced Options", systemImage: "slider.horizontal.3")
      }
    } header: {
      Text("Inference")
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

    Toggle(
      "Solid response bubbles",
      isOn: settingsBinding(\.appearance.solidResponseBubbles))
    Toggle("Render Markdown", isOn: settingsBinding(\.renderMarkdownInChat))
    Toggle("Live Markdown", isOn: settingsBinding(\.appearance.liveMarkdown))
  }

  @ViewBuilder
  private var fontOptionsContent: some View {
    Picker("User Font", selection: settingsBinding(\.appearance.userFontFamily)) {
      ForEach(AppearanceFontFamily.pickerOptions) { font in
        Text(font.displayName).tag(font)
      }
    }
    .pickerStyle(.menu)

    Picker("Assistant Font", selection: settingsBinding(\.appearance.assistantFontFamily)) {
      ForEach(AppearanceFontFamily.pickerOptions) { font in
        Text(font.displayName).tag(font)
      }
    }
    .pickerStyle(.menu)

    Stepper(
      value: settingsBinding(\.appearance.fontSize),
      in: AppearanceSettings.fontSizeRange,
      step: AppearanceSettings.fontSizeStep
    ) {
      Text(
        "Size \(store.settings.appearance.fontSize.formatted(.number.precision(.fractionLength(0...1)))) pt"
      )
    }

    VStack(alignment: .leading, spacing: 4) {
      Text("User: the quick brown fox jumps over the lazy dog.")
        .font(store.settings.appearance.userSwiftUIFont)
        .foregroundStyle(.secondary)
      Text("Assistant: the quick brown fox jumps over the lazy dog.")
        .font(store.settings.appearance.assistantSwiftUIFont)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 2)
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
  private var endpointContent: some View {
    appleIntelligenceProviderRow

    NavigationLink {
      LocalLLMView()
    } label: {
      mlxProviderRow
    }

    ForEach(store.settings.openAIEndpoints) { endpoint in
      NavigationLink(value: endpoint.id) {
        endpointRow(endpoint)
      }
    }
    .onDelete { offsets in
      pendingDeletion = PendingSettingsDeletion(kind: .endpoint, offsets: offsets)
    }
    Button {
      let endpoint = OpenAIEndpoint()
      store.settings.openAIEndpoints.append(endpoint)
      store.settings.selectedEndpointID = endpoint.id
      store.saveSettings()
      Task { await store.refreshEndpoint(endpoint) }
      endpointPath.append(endpoint.id)
    } label: {
      Label("Add Provider", systemImage: "plus")
    }
    Text(
      "Apple Intelligence and MLX are built in. OpenAI-compatible providers can be added, edited, or removed."
    )
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private var appleIntelligenceProviderRow: some View {
    let report = store.appleAvailabilityReport
    return providerStatusRow(
      title: "Apple Intelligence",
      subtitle: report.providerListSubtitle,
      systemImage: appleIntelligenceStatusIcon(report.kind),
      color: appleIntelligenceStatusColor(report.kind),
      badge: report.statusLabel
    )
  }

  private var mlxProviderRow: some View {
    let modelID = store.settings.localMLXModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    return providerStatusRow(
      title: "Local MLX LLM",
      subtitle: modelID.isEmpty ? "Available. No model selected" : "Available. \(modelID)",
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
      if !endpoint.isEnabled {
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
      "Tap a prompt to edit. Use the star in the editor to choose the default prompt sent to the model at the start of every chat."
    )
      .font(.caption)
      .foregroundStyle(.secondary)
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

  private var toolsSection: some View {
    Section {
      DisclosureGroup {
        contextToolsContent
      } label: {
        Label("Contextual", systemImage: "text.append")
      }

      DisclosureGroup {
        nativeToolsContent
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
  private var nativeToolsContent: some View {
    ForEach(NativeToolID.allCases.filter { !contextToolIDs.contains($0) }) { tool in
      toolRow(tool)
    }
    Text("Tap the checkbox to enable. Tap the row to expand options where available.")
      .font(.caption)
      .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private var contextToolsContent: some View {
    ForEach(Array(contextToolIDs)) { tool in
      toolRow(tool)
    }
    Text(
      "Context tools are rendered into the system prompt instead of being called on-demand. Toggle each tool to include its content in every chat."
    )
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private var contextToolIDs: [NativeToolID] {
    [.datetime, .location, .memory]
  }

  private func toolRow(_ tool: NativeToolID) -> some View {
    DisclosureGroup {
      toolOptions(tool)
    } label: {
      toolLabel(tool)
    }
  }

  private func toolLabel(_ tool: NativeToolID) -> some View {
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
  private func toolOptions(_ tool: NativeToolID) -> some View {
    switch tool {
    case .datetime:
      Toggle("Include time zone", isOn: settingsBinding(\.toolSettings.includeTimeZone))
      Toggle("Include moon phase", isOn: settingsBinding(\.toolSettings.includeMoonPhase))
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
      TextField("SearXNG URL", text: settingsBinding(\.toolSettings.webSearchSearXNGURL))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      TextField("SearXNG username", text: settingsBinding(\.toolSettings.webSearchSearXNGUsername))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      SecureField("SearXNG password", text: settingsBinding(\.toolSettings.webSearchSearXNGPassword))
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
    case .textToSpeech:
      Text("Configure user and assistant voices in Look and Feel.")
        .font(.footnote)
        .foregroundStyle(.secondary)
    case .files:
      Toggle(
        "Enable FilesData tools",
        isOn: settingsBinding(\.toolSettings.filesWorkspaceAccessEnabled))
      Text(
        "The callable Files tools can list, read, write, append, rename, and delete top-level text files in FilesData. Downloaded MLX models are available read-only under Models."
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
    ForEach($store.settings.mcpServers) { $server in
      NavigationLink {
        MCPServerDetailView(server: $server)
      } label: {
        mcpRow(server)
      }
    }
    .onDelete { offsets in
      pendingDeletion = PendingSettingsDeletion(kind: .mcpServer, offsets: offsets)
    }
    Button {
      store.settings.mcpServers.append(MCPServer())
      store.saveSettings()
    } label: {
      Label("Add MCP Server", systemImage: "plus")
    }
    Text("HTTP and HTTPS endpoints are accepted. Tap a server to edit its details.")
      .font(.caption)
      .foregroundStyle(.secondary)
  }

  private func mcpRow(_ server: MCPServer) -> some View {
    let subtitle: String = {
      if let tools = store.mcpTools[server.id], !tools.isEmpty {
        return "\(tools.count) tool\(tools.count == 1 ? "" : "s")"
      }
      let url = server.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
      if url.isEmpty || url == "https://" {
        return "No URL set"
      }
      return URL(string: url)?.host ?? url
    }()
    let icon: String = {
      if server.isHTTPS { return "lock.fill" }
      if server.hasValidScheme { return "globe" }
      return "lock.trianglebadge.exclamationmark"
    }()
    let iconColor: Color = {
      if server.isHTTPS { return .green }
      if server.hasValidScheme { return .orange }
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
      Button {
        showingConversationImporter = true
      } label: {
        Label("Import Conversation", systemImage: "square.and.arrow.down")
      }

      Button {
        showingClearAllConfirmation = true
      } label: {
        Label("Clear All Conversations", systemImage: "trash")
          .foregroundStyle(hasConversationContent ? Color.red : Color.secondary)
      }
      .disabled(!hasConversationContent)

      Button(role: .destructive) {
        showingFactoryResetConfirmation = true
      } label: {
        Label("Factory Reset", systemImage: "arrow.counterclockwise.circle")
          .foregroundStyle(Color.red)
      }
    } header: {
      Text("Danger Zone")
    } footer: {
      Text(
        "Import adds or updates chats from PocketMai JSON. Clear conversations removes chats. Factory Reset removes chats, settings, providers, API keys, memory, tools, and local app data from this device."
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
          store.settings.defaultProvider = .apple
        }
      }
      endpointPath.removeAll { removedIDs.contains($0) }
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
    case .file:
      guard deletion.offsets.allSatisfy({ store.settings.toolSettings.files.indices.contains($0) })
      else { return }
      store.settings.toolSettings.files.remove(atOffsets: deletion.offsets)
      store.saveSettings()
    case .mcpServer:
      guard deletion.offsets.allSatisfy({ store.settings.mcpServers.indices.contains($0) })
      else { return }
      store.settings.mcpServers.remove(atOffsets: deletion.offsets)
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

  @MainActor
  private func prepareConversationImport(from url: URL) async {
    do {
      pendingConversationImport = try await store.previewConversationImport(from: url)
    } catch {
      showToast(error.localizedDescription)
    }
  }

  private func finishConversationImport(
    _ preview: ConversationImportPreview,
    resolution: ConversationImportResolution
  ) -> String? {
    do {
      try store.importConversation(preview, resolution: resolution)
      pendingConversationImport = nil
      dismiss()
      return nil
    } catch {
      return error.localizedDescription
    }
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

      if let message = EndpointNameResolution.validationMessage(
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

  private func showToast(_ message: String) {
    withAnimation(.snappy) {
      toastMessage = message
    }
  }

  private var defaultProviderBinding: Binding<DefaultProviderSelection> {
    Binding(
      get: {
        switch store.settings.defaultProvider {
        case .apple:
          return .apple
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
          return .apple
        }
      },
      set: { newValue in
        switch newValue {
        case .apple:
          store.settings.defaultProvider = .apple
        case .mlx:
          store.settings.defaultProvider = .mlx
        case .endpoint(let id):
          store.settings.defaultProvider = .openAICompatible
          store.settings.selectedEndpointID = id
        }
        store.saveSettings()
      }
    )
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

  private var availableWebSearchProviders: [WebSearchProvider] {
    let hasOllama = WebSearchService.ollamaEndpoint(in: store.settings) != nil
    return WebSearchProvider.allCases.filter { provider in
      provider != .ollama || hasOllama
    }
  }

  private func toggleTool(_ tool: NativeToolID) {
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
            Text(endpoint.displayName).tag(VoiceProviderSelection.openAI(endpoint.id))
          }
        }
      } footer: {
        Text("Only OpenAI-compatible providers with discovered /v1/voices are listed.")
      }

      if voice.provider == .openAICompatible {
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
          Picker("Language", selection: voiceBinding(\.language)) {
            Text("System Default").tag("")
            ForEach(TTSVoiceCache.languages, id: \.self) { lang in
              Text(TTSVoiceCache.languageDisplayName(lang)).tag(lang)
            }
          }

          Picker("Voice", selection: voiceBinding(\.voiceIdentifier)) {
            Text("Default Voice").tag("")
            ForEach(TTSVoiceCache.voiceOptions(for: voice.language), id: \.identifier) { option in
              Text("\(option.name) (\(TTSVoiceCache.languageDisplayName(option.language)))")
                .tag(option.identifier)
            }
          }
        }

        Section {
          VStack(alignment: .leading) {
            Text("Rate")
            Slider(value: voiceBinding(\.rate), in: 0...1, step: 0.05)
          }

          VStack(alignment: .leading) {
            Text("Pitch")
            Slider(value: voiceBinding(\.pitch), in: 0.5...2, step: 0.05)
          }
        }
      }

      Section {
        Button {
          VoiceTest.toggle(
            role: role,
            voice: voice,
            openAIEndpoints: store.settings.openAIEndpoints,
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
      guard voice.provider == .system else { return }
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

  private var providerBinding: Binding<VoiceProviderSelection> {
    Binding(
      get: {
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
    guard voice.provider == .openAICompatible,
      let id = voice.openAIEndpointID
    else { return [] }
    return store.endpointVoices[id] ?? []
  }

  private var openAIVoiceEndpoints: [OpenAIEndpoint] {
    store.settings.openAIEndpoints.filter { endpoint in
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
    let trimmedName = endpoint.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedName.isEmpty else { return nil }
    guard let fallbackName = providerName(for: endpoint) else {
      return "Specify a name for this provider."
    }
    if hasDuplicateName(fallbackName, excluding: endpoint.id, in: endpoints) {
      return "Another provider is already named \"\(fallbackName)\". Specify a name."
    }
    return nil
  }

  private static func providerName(for endpoint: OpenAIEndpoint) -> String? {
    let baseURL = endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    return endpointProviderPresets.first(where: { $0.url == baseURL })?.name
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

private struct ConversationImportConfirmationView: View {
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

private struct SettingsToastModifier: ViewModifier {
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
  fileprivate func settingsToast(_ message: Binding<String?>) -> some View {
    modifier(SettingsToastModifier(message: message))
  }
}

private struct EndpointDetailView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @Binding var endpoint: OpenAIEndpoint
  @State private var modelFilter = ""
  @State private var toastMessage: String?

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
          ForEach(endpointProviderPresets, id: \.url) { preset in
            Text(preset.name).tag(preset.url)
          }
          Text("Custom").tag(customProviderTag)
        }
        .pickerStyle(.menu)
        TextField("https://api.example.com/v1", text: $endpoint.baseURL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
        SecureField("API Key", text: $endpoint.apiKey)
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
          "Pick a provider to autofill the base URL, or choose Custom to enter your own. Any OpenAI-compatible API works (Ollama, llama.cpp, LM Studio, etc.)."
        )
      }

      Section {
        modelField
        reasoningLevelField
      } header: {
        Text("Default Model")
      } footer: {
        statusFooter
      }

      Section {
        Button {
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
      }
    }
    .navigationTitle(endpoint.displayName)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { saveEndpointAndDismiss() }
      }
    }
    .settingsToast($toastMessage)
    .onChange(of: endpoint) { _, _ in store.saveSettings() }
    .onChange(of: endpoint.baseURL) { _, _ in store.resetEndpointStatus(endpoint.id) }
    .onChange(of: endpoint.apiKey) { _, _ in store.resetEndpointStatus(endpoint.id) }
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
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Label("Reasoning", systemImage: endpoint.defaultReasoningLevel.systemImage)
          .contentTransition(.symbolEffect(.replace))
        Spacer()
        Text(endpoint.defaultReasoningLevel.displayName)
          .foregroundStyle(.secondary)
          .contentTransition(.numericText())
          .animation(.snappy, value: endpoint.defaultReasoningLevel)
      }
      Slider(
        value: reasoningSliderBinding,
        in: 0...Double(ReasoningLevel.allCases.count - 1),
        step: 1
      )
    }
  }

  private var reasoningSliderBinding: Binding<Double> {
    Binding(
      get: {
        Double(ReasoningLevel.allCases.firstIndex(of: endpoint.defaultReasoningLevel) ?? 0)
      },
      set: { value in
        let cases = ReasoningLevel.allCases
        let index = max(0, min(cases.count - 1, Int(value.rounded())))
        endpoint.defaultReasoningLevel = cases[index]
      }
    )
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
    store.saveSettings()
    dismiss()
  }

  private func showToast(_ message: String) {
    withAnimation(.snappy) {
      toastMessage = message
    }
  }

  private var providerPresetBinding: Binding<String> {
    Binding(
      get: {
        let trimmed = endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let preset = endpointProviderPresets.first(where: { $0.url == trimmed }) {
          return preset.url
        }
        return customProviderTag
      },
      set: { newValue in
        if newValue == customProviderTag {
          endpoint.baseURL = ""
        } else {
          endpoint.baseURL = newValue
        }
      }
    )
  }
}

private enum SystemPromptNameResolution {
  static func savedName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func validationMessage(
    forName name: String,
    excluding promptID: UUID?,
    in prompts: [SystemPrompt]
  ) -> String? {
    let savedName = savedName(name)
    guard !savedName.isEmpty else {
      return "Specify a prompt name."
    }
    if hasDuplicateDisplayName(savedName, excluding: promptID, in: prompts) {
      return "A prompt named \"\(savedName)\" already exists."
    }
    return nil
  }

  private static func hasDuplicateDisplayName(
    _ name: String,
    excluding promptID: UUID?,
    in prompts: [SystemPrompt]
  ) -> Bool {
    let normalized = normalizedName(name)
    return prompts.contains { prompt in
      guard prompt.id != promptID else { return false }
      return normalizedName(prompt.displayName) == normalized
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
    if let message = SystemPromptNameResolution.validationMessage(
      forName: draftName,
      excluding: promptID,
      in: store.settings.systemPrompts)
    {
      showToast(message)
      return
    }

    let savedName = SystemPromptNameResolution.savedName(draftName)
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

private struct MCPServerDetailView: View {
  @EnvironmentObject private var store: AppStore
  @Binding var server: MCPServer

  var body: some View {
    Form {
      Section {
        Toggle("Enabled", isOn: $server.isEnabled)
        TextField("Name", text: $server.name)
      } footer: {
        Text("A friendly name shown in the server list.")
      }

      Section {
        TextField("https://example.com/mcp", text: $server.baseURL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .keyboardType(.URL)
        if !server.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && !server.hasValidScheme
        {
          Label("URL must start with http:// or https://", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
        }
      } header: {
        Text("Endpoint")
      } footer: {
        Text("HTTP and HTTPS URLs are accepted. Prefer HTTPS for non-local servers.")
      }

      Section {
        Button {
          let snapshot = server
          Task { await store.refreshMCP(snapshot) }
        } label: {
          if isChecking {
            HStack {
              ProgressView()
              Text("Connecting…")
            }
          } else {
            Label("Refresh Tools", systemImage: "arrow.clockwise")
          }
        }
        .disabled(isChecking || !server.hasValidScheme)
      } header: {
        Text("Connection")
      } footer: {
        statusFooter
      }

      if let tools = store.mcpTools[server.id], !tools.isEmpty {
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
    }
    .navigationTitle(server.name.isEmpty ? "MCP Server" : server.name)
    .navigationBarTitleDisplayMode(.inline)
    .onChange(of: server.baseURL) { _, _ in store.resetMCPStatus(server.id) }
  }

  private var isChecking: Bool {
    if case .checking = store.mcpStatuses[server.id] {
      return true
    }
    return false
  }

  @ViewBuilder
  private var statusFooter: some View {
    let status = store.mcpStatuses[server.id] ?? .unknown
    let tools = store.mcpTools[server.id] ?? []
    switch status {
    case .unknown:
      Text("Tap “Refresh Tools” to connect and list the tools this server provides.")
    case .checking:
      Text("Connecting…")
    case .available:
      if tools.isEmpty {
        Text("Connected, but the server reports no tools.")
      } else {
        Text("Connected. \(tools.count) tool\(tools.count == 1 ? "" : "s") available.")
      }
    case .failed(let message):
      Text(message).foregroundStyle(.red)
    }
  }
}
