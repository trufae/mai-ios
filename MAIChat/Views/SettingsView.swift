import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

enum DefaultProviderSelection: Hashable {
  case apple
  case endpoint(UUID)
}

struct SettingsView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @State private var showingFileImporter = false
  @State private var newTodoTitle = ""
  @State private var showingClearAllConfirmation = false

  var body: some View {
    NavigationStack {
      Form {
        providerSection
        endpointSection
        promptSection
        toolsSection
        mcpSection
        memorySection
        aboutSection
        dangerSection
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
      .navigationTitle("Settings")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .fileImporter(
        isPresented: $showingFileImporter,
        allowedContentTypes: [.text, .plainText, .json, .sourceCode]
      ) { result in
        if case .success(let url) = result {
          store.importToolFile(from: url)
        }
      }
    }
  }

  private var providerSection: some View {
    Section {
      Picker("Default Provider", selection: defaultProviderBinding) {
        Label("Apple Intelligence", systemImage: "apple.logo")
          .tag(DefaultProviderSelection.apple)
        ForEach(store.settings.openAIEndpoints) { endpoint in
          Label(
            endpoint.name.isEmpty ? "Untitled Endpoint" : endpoint.name,
            systemImage: "network"
          )
          .tag(DefaultProviderSelection.endpoint(endpoint.id))
        }
      }
      .pickerStyle(.menu)
      Toggle("Stream Responses", isOn: settingsBinding(\.streamByDefault))
      Picker("Context", selection: settingsBinding(\.contextWindowMode)) {
        ForEach(ContextWindowMode.allCases) { mode in
          Text(mode.displayName).tag(mode)
        }
      }
      .pickerStyle(.menu)
    } header: {
      Text("Default Provider")
    } footer: {
      Text(providerFooterText)
    }
  }

  private var toolProxySummary: String {
    "Off: every enabled tool is described in each request. On: only `list-tools` and `call-tool` wrappers go to the model — it lists matching tools by keyword, then calls the chosen one. Saves prompt context with many tools, adds one extra round-trip per call. Combines with both Text and Native modes."
  }

  private var providerFooterText: String {
    if store.settings.openAIEndpoints.isEmpty {
      return
        "Apple Intelligence runs on-device. Add an endpoint below to use OpenAI-compatible providers."
    }
    return "Choose which provider answers new chats. Apple Intelligence runs on-device."
  }

  private var endpointSection: some View {
    Section {
      ForEach($store.settings.openAIEndpoints) { $endpoint in
        NavigationLink {
          EndpointDetailView(endpoint: $endpoint)
        } label: {
          endpointRow(endpoint)
        }
      }
      .onDelete { offsets in
        let removedIDs = offsets.map { store.settings.openAIEndpoints[$0].id }
        store.settings.openAIEndpoints.remove(atOffsets: offsets)
        if let selected = store.settings.selectedEndpointID, removedIDs.contains(selected) {
          store.settings.selectedEndpointID = store.settings.openAIEndpoints.first?.id
          if store.settings.selectedEndpointID == nil {
            store.settings.defaultProvider = .apple
          }
        }
        store.saveSettings()
      }
      Button {
        let endpoint = OpenAIEndpoint()
        store.settings.openAIEndpoints.append(endpoint)
        store.settings.selectedEndpointID = endpoint.id
        store.saveSettings()
        Task { await store.refreshEndpoint(endpoint) }
      } label: {
        Label("Add Endpoint", systemImage: "plus")
      }
    } header: {
      Text("Endpoints")
    } footer: {
      Text("Tap an endpoint to edit credentials and pick a default model.")
    }
    .onChange(of: store.settings.openAIEndpoints) { _, _ in store.saveSettings() }
  }

  private func endpointRow(_ endpoint: OpenAIEndpoint) -> some View {
    let status = store.endpointStatuses[endpoint.id] ?? .unknown
    let summary = endpointStatusSummary(status)
    let subtitle: String = {
      let trimmedModel = endpoint.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmedModel.isEmpty {
        return trimmedModel
      }
      let host = URL(string: endpoint.baseURL)?.host ?? endpoint.baseURL
      return host.isEmpty ? "No model selected" : host
    }()
    return HStack(spacing: 12) {
      Image(systemName: summary.systemImage)
        .imageScale(.medium)
        .foregroundStyle(summary.color)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(endpoint.name.isEmpty ? "Untitled Endpoint" : endpoint.name)
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

  private func endpointStatusSummary(_ status: EndpointConnectionState) -> (
    text: String, systemImage: String, color: Color
  ) {
    switch status {
    case .unknown:
      return ("Not checked", "circle", .secondary)
    case .checking:
      return ("Checking", "arrow.triangle.2.circlepath", .orange)
    case .available:
      return ("Connected", "checkmark.circle.fill", .green)
    case .failed:
      return ("Failed", "exclamationmark.circle.fill", .red)
    }
  }

  private var promptSection: some View {
    Section {
      Picker("Default Prompt", selection: settingsBinding(\.defaultSystemPromptID)) {
        ForEach(store.settings.systemPrompts) { prompt in
          Text(prompt.name.isEmpty ? "Untitled" : prompt.name).tag(prompt.id)
        }
      }
      .pickerStyle(.menu)
      ForEach($store.settings.systemPrompts) { $prompt in
        NavigationLink {
          SystemPromptDetailView(prompt: $prompt)
        } label: {
          promptRow(prompt)
        }
      }
      .onDelete { offsets in
        store.settings.systemPrompts.remove(atOffsets: offsets)
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
      }
      Button {
        let prompt = SystemPrompt(name: "Custom prompt", text: "You are a helpful assistant.")
        store.settings.systemPrompts.append(prompt)
        store.settings.defaultSystemPromptID = prompt.id
        store.saveSettings()
      } label: {
        Label("Add Prompt", systemImage: "plus")
      }
    } header: {
      Text("System Prompts")
    } footer: {
      Text("Tap a prompt to edit. The default is sent to the model at the start of every chat.")
    }
    .onChange(of: store.settings.systemPrompts) { _, _ in store.saveSettings() }
  }

  private func promptRow(_ prompt: SystemPrompt) -> some View {
    let isDefault = prompt.id == store.settings.defaultSystemPromptID
    let trimmed = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let preview = trimmed.split(separator: "\n").first.map(String.init) ?? ""
    return HStack(spacing: 12) {
      Image(systemName: isDefault ? "checkmark.circle.fill" : "text.bubble")
        .imageScale(.medium)
        .foregroundStyle(isDefault ? Color.accentColor : .secondary)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(prompt.name.isEmpty ? "Untitled" : prompt.name)
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
      Picker("Usage", selection: settingsBinding(\.nativeToolMode)) {
        ForEach(NativeToolMode.allCases) { mode in
          Text(mode.displayName).tag(mode)
        }
      }
      .pickerStyle(.menu)
      Text(store.settings.nativeToolMode.summary)
        .font(.caption)
        .foregroundStyle(.secondary)
      ForEach(NativeToolID.allCases.filter { $0 != .memory }) { tool in
        toolRow(tool)
      }
    } header: {
      Text("Native Tools")
    } footer: {
      Text(
        "Tap the checkbox to enable. Tap the row to expand options where available. Usage applies to Date & Time, Location, and Weather."
      )
    }
    .onChange(of: store.settings.defaultEnabledTools) { _, _ in store.saveSettings() }
    .onChange(of: store.settings.toolSettings) { _, _ in store.saveSettings() }
  }

  @ViewBuilder
  private func toolRow(_ tool: NativeToolID) -> some View {
    if toolHasOptions(tool) {
      DisclosureGroup {
        toolOptions(tool)
      } label: {
        toolLabel(tool)
      }
    } else {
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

  private func toolHasOptions(_ tool: NativeToolID) -> Bool {
    switch tool {
    case .memory: return false
    default: return true
    }
  }

  @ViewBuilder
  private func toolOptions(_ tool: NativeToolID) -> some View {
    switch tool {
    case .datetime:
      Toggle("Include time zone", isOn: settingsBinding(\.toolSettings.includeTimeZone))
      Toggle("Include current time", isOn: settingsBinding(\.toolSettings.includeCurrentTime))
      Toggle("Include year", isOn: settingsBinding(\.toolSettings.includeYear))
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
    case .todo:
      HStack {
        TextField("New todo", text: $newTodoTitle)
        Button {
          let trimmed = newTodoTitle.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmed.isEmpty else { return }
          store.settings.toolSettings.todos.append(TodoItem(title: trimmed))
          newTodoTitle = ""
          store.saveSettings()
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
        store.settings.toolSettings.todos.remove(atOffsets: offsets)
        store.saveSettings()
      }
    case .textToSpeech:
      Picker("Language", selection: settingsBinding(\.toolSettings.textToSpeechLanguage)) {
        Text("System Default").tag("")
        ForEach(textToSpeechLanguages, id: \.self) { language in
          Text(languageDisplayName(language)).tag(language)
        }
      }
      .onChange(of: store.settings.toolSettings.textToSpeechLanguage) { _, language in
        guard !language.isEmpty,
          let voice = textToSpeechVoices.first(where: {
            $0.identifier == store.settings.toolSettings.textToSpeechVoiceIdentifier
          }),
          voice.language != language
        else { return }
        store.settings.toolSettings.textToSpeechVoiceIdentifier = ""
        store.saveSettings()
      }

      Picker("Voice", selection: settingsBinding(\.toolSettings.textToSpeechVoiceIdentifier)) {
        Text("Default Voice").tag("")
        ForEach(textToSpeechVoiceOptions, id: \.identifier) { voice in
          Text("\(voice.name) (\(languageDisplayName(voice.language)))")
            .tag(voice.identifier)
        }
      }

      VStack(alignment: .leading) {
        Text("Rate")
        Slider(value: settingsBinding(\.toolSettings.textToSpeechRate), in: 0...1, step: 0.05)
      }

      VStack(alignment: .leading) {
        Text("Pitch")
        Slider(value: settingsBinding(\.toolSettings.textToSpeechPitch), in: 0.5...2, step: 0.05)
      }
    case .files:
      Button {
        showingFileImporter = true
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
        store.settings.toolSettings.files.remove(atOffsets: offsets)
        store.saveSettings()
      }
    case .memory:
      EmptyView()
    }
  }

  private var mcpSection: some View {
    Section {
      Picker("Tool Calling", selection: settingsBinding(\.toolCallingMode)) {
        ForEach(ToolCallingMode.allCases) { mode in
          Text(mode.displayName).tag(mode)
        }
      }
      .pickerStyle(.menu)
      Text(store.settings.toolCallingMode.summary)
        .font(.caption)
        .foregroundStyle(.secondary)
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
        store.settings.mcpServers.remove(atOffsets: offsets)
        store.saveSettings()
      }
      Button {
        store.settings.mcpServers.append(MCPServer())
        store.saveSettings()
      } label: {
        Label("Add MCP Server", systemImage: "plus")
      }
    } header: {
      Text("MCP Servers")
    } footer: {
      Text("HTTP and HTTPS endpoints are accepted. Tap a server to edit its details.")
    }
    .onChange(of: store.settings.mcpServers) { _, _ in store.saveSettings() }
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
      Text("About MAI")
    }
  }

  private var dangerSection: some View {
    Section {
      Button {
        showingClearAllConfirmation = true
      } label: {
        Label("Clear All Conversations", systemImage: "trash")
          .foregroundStyle(hasConversationContent ? Color.red : Color.secondary)
      }
      .disabled(!hasConversationContent)
    } header: {
      Text("Danger Zone")
    } footer: {
      Text("Removes every chat from this device.")
    }
  }

  private var hasConversationContent: Bool {
    store.conversations.contains { !$0.messages.isEmpty }
  }

  private var memorySection: some View {
    Section {
      Toggle("Embed memory in conversations", isOn: settingsBinding(\.embedMemory))
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
        store.settings.memory = ""
        store.saveSettings()
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
    } header: {
      Text("Memory")
    } footer: {
      Text(
        "Memory is added to the system prompt as durable context. Toggle off to keep it locally without sending it to the model."
      )
    }
  }

  private var defaultProviderBinding: Binding<DefaultProviderSelection> {
    Binding(
      get: {
        switch store.settings.defaultProvider {
        case .apple:
          return .apple
        case .openAICompatible:
          if let id = store.settings.selectedEndpointID,
            store.settings.openAIEndpoints.contains(where: { $0.id == id })
          {
            return .endpoint(id)
          }
          if let first = store.settings.openAIEndpoints.first {
            return .endpoint(first.id)
          }
          return .apple
        }
      },
      set: { newValue in
        switch newValue {
        case .apple:
          store.settings.defaultProvider = .apple
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

  private var textToSpeechVoices: [AVSpeechSynthesisVoice] {
    AVSpeechSynthesisVoice.speechVoices().sorted {
      if $0.language != $1.language { return $0.language < $1.language }
      return $0.name < $1.name
    }
  }

  private var textToSpeechLanguages: [String] {
    Array(Set(textToSpeechVoices.map(\.language))).sorted {
      languageDisplayName($0) < languageDisplayName($1)
    }
  }

  private var textToSpeechVoiceOptions: [AVSpeechSynthesisVoice] {
    let language = store.settings.toolSettings.textToSpeechLanguage
    guard !language.isEmpty else { return textToSpeechVoices }
    return textToSpeechVoices.filter { $0.language == language }
  }

  private func languageDisplayName(_ language: String) -> String {
    let name = Locale.current.localizedString(forIdentifier: language) ?? language
    return "\(name) (\(language))"
  }

  private func toggleTool(_ tool: NativeToolID) {
    if store.settings.defaultEnabledTools.contains(tool) {
      store.settings.defaultEnabledTools.remove(tool)
    } else {
      store.settings.defaultEnabledTools.insert(tool)
    }
    store.saveSettings()
  }

  private func toolBinding(_ tool: NativeToolID) -> Binding<Bool> {
    Binding(
      get: { store.settings.defaultEnabledTools.contains(tool) },
      set: { isOn in
        if isOn {
          store.settings.defaultEnabledTools.insert(tool)
        } else {
          store.settings.defaultEnabledTools.remove(tool)
        }
        store.saveSettings()
      }
    )
  }
}

private struct EndpointDetailView: View {
  @EnvironmentObject private var store: AppStore
  @Binding var endpoint: OpenAIEndpoint

  var body: some View {
    Form {
      Section {
        Toggle("Enabled", isOn: $endpoint.isEnabled)
        TextField("Name", text: $endpoint.name)
      } footer: {
        Text("A friendly name shown in the provider picker.")
      }

      Section {
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
          "Use any OpenAI-compatible API: OpenAI, OpenRouter, Ollama, llama.cpp, LM Studio, etc.")
      }

      Section {
        modelField
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
            Label("Test & Refresh Models", systemImage: "arrow.clockwise")
          }
        }
        .disabled(isChecking)
      }
    }
    .navigationTitle(endpoint.name.isEmpty ? "Endpoint" : endpoint.name)
    .navigationBarTitleDisplayMode(.inline)
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
      Picker("Model", selection: $endpoint.defaultModel) {
        let selected = endpoint.defaultModel
        if !selected.isEmpty && !models.contains(selected) {
          Text(selected).tag(selected)
        }
        if selected.isEmpty {
          Text("Select a model").tag("")
        }
        ForEach(models, id: \.self) { model in
          Text(model).tag(model)
        }
      }
      .pickerStyle(.menu)
    }
  }

  @ViewBuilder
  private var statusFooter: some View {
    let status = store.endpointStatuses[endpoint.id] ?? .unknown
    let models = store.endpointModels[endpoint.id] ?? []
    switch status {
    case .unknown:
      Text("Tap “Test & Refresh Models” to verify the connection and load the model list.")
    case .checking:
      Text("Testing connection…")
    case .available:
      if models.isEmpty {
        Text("Connected.")
      } else {
        Text("Connected. \(models.count) models available.")
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
}

private struct SystemPromptDetailView: View {
  @Binding var prompt: SystemPrompt

  var body: some View {
    Form {
      Section {
        TextField("Name", text: $prompt.name)
      } footer: {
        Text("Shown in the prompt picker.")
      }
      Section {
        TextEditor(text: $prompt.text)
          .frame(minHeight: 220)
          .font(.callout)
      } header: {
        Text("Instructions")
      } footer: {
        Text("Sent to the model at the start of each chat.")
      }
    }
    .navigationTitle(prompt.name.isEmpty ? "Prompt" : prompt.name)
    .navigationBarTitleDisplayMode(.inline)
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
