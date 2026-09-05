import Foundation
import MaiCore
import SwiftTUIRuntime

/// Two-column configuration screens: a live registry on the left, a
/// registration form on the right. Narrow terminals stack the columns.
private struct ConfigScreen<Registry: View, Form: View>: View {
  let registry: Registry
  let form: Form

  init(@ViewBuilder registry: () -> Registry, @ViewBuilder form: () -> Form) {
    self.registry = registry()
    self.form = form()
  }

  var body: some View {
    GeometryReader { proxy in
      if proxy.size.width >= 100 {
        HStack(alignment: .top, spacing: 0) {
          ScrollView(.vertical) {
            registry.padding(1).frame(maxWidth: .infinity, alignment: .topLeading)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          ScrollView(.vertical) {
            form.padding(1).frame(maxWidth: .infinity, alignment: .topLeading)
          }
          .frame(width: 52)
          .frame(maxHeight: .infinity, alignment: .topLeading)
          .border(.separator, placement: .outset, sides: .leading)
        }
      } else {
        ScrollView(.vertical) {
          VStack(alignment: .leading, spacing: 1) {
            registry
            Divider()
            form
          }
          .padding(1)
          .frame(maxWidth: .infinity, alignment: .topLeading)
        }
      }
    }
  }
}

private struct SaveConfigurationRow: View {
  @Bindable var workspace: VisualWorkspace
  @State private var message: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Divider()
      Text("Configuration file").bold()
      TextField("Path", text: $workspace.configurationPath)
      HStack(spacing: 1) {
        Button("Save configuration") {
          do {
            try workspace.saveConfiguration()
            message = "Saved."
          } catch {
            message = "error: \(error.localizedDescription)"
          }
        }
        if workspace.configurationNeedsSave {
          Text("unsaved changes").foregroundStyle(.warning)
        }
      }
      if let message {
        Text(message).foregroundStyle(message.hasPrefix("error") ? .danger : .muted).lineLimit(3)
      }
    }
  }
}

// MARK: - Providers

struct ProvidersScreen: View {
  let workspace: VisualWorkspace

  var body: some View {
    ConfigScreen {
      VStack(alignment: .leading, spacing: 1) {
        Text("Registered providers").bold()
        if workspace.providers.isEmpty {
          Text("No providers are registered.").foregroundStyle(.muted)
        }
        ForEach(workspace.providers, id: \.id.rawValue) { provider in
          ProviderRow(provider: provider, workspace: workspace)
        }
      }
    } form: {
      ProviderFormView(workspace: workspace)
      SaveConfigurationRow(workspace: workspace)
    }
  }
}

private struct ProviderRow: View {
  let provider: ProviderDescriptor
  let workspace: VisualWorkspace

  var body: some View {
    let isCurrent = workspace.focusedConversation?.profile.provider == provider.id
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 1) {
        Text(isCurrent ? "▶" : " ").foregroundStyle(.tint)
        Text(provider.id.rawValue).bold()
        Text(provider.displayName).foregroundStyle(.muted).lineLimit(1)
        Spacer(minLength: 1)
        Button(isCurrent ? "In use" : "Use") { workspace.useProvider(provider.id) }
          .disabled(isCurrent)
      }
      if let configured = workspace.configuredProvider(provider.id) {
        Text(
          "  kind \(configured.kind.rawValue)"
            + (configured.baseURL.map { " · \($0.absoluteString)" } ?? "")
            + (configured.apiKeyEnvironment.map { " · key from $\($0)" } ?? "")
        )
        .foregroundStyle(.separator)
        .lineLimit(1)
        .truncationMode(.tail)
      }
    }
  }
}

private struct ProviderFormView: View {
  let workspace: VisualWorkspace
  @State private var form = ProviderForm()
  @State private var message: String?
  @State private var isSubmitting = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Register a provider").bold()
      TextField("Identifier", text: $form.id)
      TextField("Kind (openAICompatible, hello, plugin kind)", text: $form.kind)
      TextField("Display name", text: $form.displayName)
      TextField("Base URL, e.g. http://127.0.0.1:11434/v1", text: $form.baseURL)
      TextField("API key environment variable", text: $form.apiKeyEnvironment)
      SecureField("API key (saved to the config file if no variable)", text: $form.apiKey)
      HStack(spacing: 1) {
        Button("Register") { submit() }
          .disabled(isSubmitting || form.id.isEmpty)
        if isSubmitting { Spinner() }
      }
      if let message {
        Text(message).foregroundStyle(message.hasPrefix("error") ? .danger : .muted).lineLimit(3)
      }
    }
  }

  private func submit() {
    isSubmitting = true
    let form = form
    Task {
      do {
        try await workspace.registerProvider(form)
        message = "Registered '\(form.id)'."
        self.form = ProviderForm()
      } catch {
        message = "error: \(error.localizedDescription)"
      }
      isSubmitting = false
    }
  }
}

// MARK: - MCP

struct MCPScreen: View {
  let workspace: VisualWorkspace

  var body: some View {
    ConfigScreen {
      VStack(alignment: .leading, spacing: 1) {
        Text("Connected MCP servers").bold()
        if workspace.catalogs.isEmpty {
          Text("No MCP servers are connected.").foregroundStyle(.muted)
        }
        ForEach(workspace.catalogs, id: \.serverID) { catalog in
          VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 1) {
              Text(catalog.serverID).bold()
              if let name = catalog.serverName { Text(name).foregroundStyle(.muted) }
              Spacer(minLength: 1)
              Text("MCP \(catalog.protocolVersion)").foregroundStyle(.separator)
            }
            Text(
              "  \(catalog.tools.count) tools, \(catalog.resources.count) resources: "
                + catalog.tools.map(\.name).joined(separator: ", ")
            )
            .foregroundStyle(.separator)
            .lineLimit(2)
            .truncationMode(.tail)
          }
        }
        if !workspace.disabledMCPServers.isEmpty {
          Text("Configured but not connected").bold()
          ForEach(workspace.disabledMCPServers, id: \.id) { server in
            Text("  \(server.id) · \(server.url?.absoluteString ?? "no URL")")
              .foregroundStyle(.muted)
              .lineLimit(1)
          }
        }
      }
    } form: {
      MCPFormView(workspace: workspace)
      SaveConfigurationRow(workspace: workspace)
    }
  }
}

private struct MCPFormView: View {
  let workspace: VisualWorkspace
  @State private var form = MCPServerForm()
  @State private var message: String?
  @State private var isSubmitting = false

  private let approvals: [ToolApprovalRequirement] = [.automatic, .confirm, .dangerous]

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Connect an MCP server").bold()
      TextField("Identifier", text: $form.id)
      TextField("Kind", text: $form.kind)
      TextField("Display name", text: $form.displayName)
      TextField("URL, e.g. https://host/mcp", text: $form.url)
      TextField("Bearer token environment variable", text: $form.bearerTokenEnvironment)
      SecureField("Bearer token (saved to the config file if no variable)", text: $form.bearerToken)
      TextField("Tool name prefix", text: $form.toolNamePrefix)
      Picker("Default approval", selection: $form.approval) {
        ForEach(approvals, id: \.rawValue) { approval in
          Text(approval.rawValue).tag(approval)
        }
      }
      .pickerStyle(.segmented)
      HStack(spacing: 1) {
        Button("Connect") { submit() }
          .disabled(isSubmitting || form.id.isEmpty || form.url.isEmpty)
        if isSubmitting { Spinner() }
      }
      if let message {
        Text(message).foregroundStyle(message.hasPrefix("error") ? .danger : .muted).lineLimit(4)
      }
    }
  }

  private func submit() {
    isSubmitting = true
    let form = form
    Task {
      do {
        try await workspace.connectMCPServer(form)
        message = "Connected '\(form.id)'."
        self.form = MCPServerForm()
      } catch {
        message = "error: \(error.localizedDescription)"
      }
      isSubmitting = false
    }
  }
}

// MARK: - Tools

struct ToolsScreen: View {
  let workspace: VisualWorkspace

  var body: some View {
    ConfigScreen {
      VStack(alignment: .leading, spacing: 1) {
        if let focused = workspace.focusedConversation {
          FocusedToolsList(conversation: focused, workspace: workspace)
        } else {
          Text("No conversation is focused.").foregroundStyle(.muted)
        }
      }
    } form: {
      ToolSourceFormView(workspace: workspace)
      SaveConfigurationRow(workspace: workspace)
    }
  }
}

private struct FocusedToolsList: View {
  @Bindable var conversation: VisualConversation
  let workspace: VisualWorkspace

  private var enabledGroupCount: Int {
    workspace.toolGroups.filter { workspace.isToolGroupEnabled($0, for: conversation) }.count
  }

  var body: some View {
    Text("Tool groups allowed in '\(conversation.title)'").bold()
    Text(
      "\(enabledGroupCount) of \(workspace.toolGroups.count) groups enabled. Each group is saved on agent '\(conversation.profile.id)'."
    )
    .foregroundStyle(.muted)
    Toggle(
      "Tool proxy (models see list-tools and call-tool)",
      isOn: Binding(
        get: { conversation.profile.useToolProxy },
        set: { workspace.setToolProxy($0, for: conversation) }))
    Divider()
    if workspace.toolGroups.isEmpty {
      Text("No tool groups are registered.").foregroundStyle(.muted)
    }
    ForEach(workspace.toolGroups, id: \.catalogID) { group in
      ToolGroupRow(group: group, conversation: conversation, workspace: workspace)
    }
  }
}

private struct ToolGroupRow: View {
  let group: ToolGroupDefinition
  @Bindable var conversation: VisualConversation
  let workspace: VisualWorkspace
  @State private var draft: [String: JSONValue]
  @State private var message: String?
  @State private var isSaving = false

  init(
    group: ToolGroupDefinition,
    conversation: VisualConversation,
    workspace: VisualWorkspace
  ) {
    self.group = group
    self.conversation = conversation
    self.workspace = workspace
    _draft = State(initialValue: workspace.configuredToolGroupOptions(group))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Toggle(
        "\(group.displayName) (\(group.toolNames.count))",
        isOn: Binding(
          get: { workspace.isToolGroupEnabled(group, for: conversation) },
          set: { workspace.setToolGroup(group, allowed: $0, for: conversation) }))
      if !group.description.isEmpty {
        Text("  \(group.description)")
          .foregroundStyle(.separator)
          .lineLimit(2)
          .truncationMode(.tail)
      }
      if !group.options.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(group.options) { option in
            optionField(option)
          }
          HStack(spacing: 1) {
            Button(isSaving ? "Applying…" : "Apply \(group.displayName) settings") {
              apply()
            }
            .disabled(isSaving || group.sourceID == "runtime")
            if let message {
              Text(message)
                .foregroundStyle(message.hasPrefix("error") ? .danger : .muted)
                .lineLimit(1)
            }
          }
        }
        .padding(.leading, 2)
      }
    }
  }

  @ViewBuilder
  private func optionField(_ option: ToolGroupOptionDefinition) -> some View {
    switch option.kind {
    case .boolean:
      Toggle(option.label, isOn: booleanBinding(option))
    case .choice:
      Picker(option.label, selection: stringBinding(option)) {
        ForEach(option.choices, id: \.self) { choice in
          Text(choice).tag(choice)
        }
      }
      .pickerStyle(.segmented)
    case .secret:
      SecureField(option.label, text: stringBinding(option))
    case .text, .number:
      TextField(option.label, text: stringBinding(option))
    }
    if let help = option.help {
      Text("  \(help)").foregroundStyle(.separator).lineLimit(2)
    }
  }

  private func stringBinding(_ option: ToolGroupOptionDefinition) -> Binding<String> {
    Binding(
      get: { stringValue(for: option) },
      set: { value in
        if option.kind == .number {
          draft[option.id] = Double(value).map(JSONValue.number)
        } else {
          draft[option.id] = .string(value)
        }
      })
  }

  private func stringValue(for option: ToolGroupOptionDefinition) -> String {
    if let value = draft[option.id]?.stringValue { return value }
    if let value = draft[option.id]?.numberValue { return String(value) }
    if let value = option.defaultValue?.stringValue { return value }
    if let value = option.defaultValue?.numberValue { return String(value) }
    return ""
  }

  private func booleanBinding(_ option: ToolGroupOptionDefinition) -> Binding<Bool> {
    Binding(
      get: { draft[option.id]?.boolValue ?? option.defaultValue?.boolValue ?? false },
      set: { draft[option.id] = .bool($0) })
  }

  private func apply() {
    isSaving = true
    Task {
      do {
        try await workspace.configureToolGroup(group, options: draft)
        message = "Saved."
      } catch {
        message = "error: \(error.localizedDescription)"
      }
      isSaving = false
    }
  }
}

private struct ToolSourceFormView: View {
  let workspace: VisualWorkspace
  @State private var form = ToolSourceForm()
  @State private var message: String?
  @State private var isSubmitting = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Register a tool source").bold()
      Text("Kinds come from installed plugins, e.g. \(MaiStandardToolsKind).")
        .foregroundStyle(.muted)
        .lineLimit(2)
      TextField("Identifier", text: $form.id)
      TextField("Kind", text: $form.kind)
      TextField("Display name", text: $form.displayName)
      Text("Options (JSON object)")
      TextEditor(text: $form.optionsJSON)
        .frame(height: 4)
        .border(.separator, placement: .outset)
      HStack(spacing: 1) {
        Button("Register tools") { submit() }
          .disabled(isSubmitting || form.id.isEmpty || form.kind.isEmpty)
        if isSubmitting { Spinner() }
      }
      if let message {
        Text(message).foregroundStyle(message.hasPrefix("error") ? .danger : .muted).lineLimit(4)
      }
    }
  }

  private func submit() {
    isSubmitting = true
    let form = form
    Task {
      do {
        try await workspace.registerToolSource(form)
        message = "Registered tools from '\(form.id)'."
        self.form = ToolSourceForm()
      } catch {
        message = "error: \(error.localizedDescription)"
      }
      isSubmitting = false
    }
  }
}

/// The standard tools factory kind, spelled here so MaiVisual does not depend on
/// the MaiStandardTools module.
private let MaiStandardToolsKind = "standard-tools"

// MARK: - Agents

struct AgentsScreen: View {
  let workspace: VisualWorkspace

  var body: some View {
    ConfigScreen {
      VStack(alignment: .leading, spacing: 1) {
        if let focused = workspace.focusedConversation {
          FocusedChatSettings(conversation: focused, workspace: workspace)
        } else {
          Text("No conversation is focused.").foregroundStyle(.muted)
        }
      }
    } form: {
      VStack(alignment: .leading, spacing: 1) {
        Text("Configured agents").bold()
        if workspace.agents.isEmpty {
          Text("No agents are registered.").foregroundStyle(.muted)
        }
        ForEach(workspace.agents, id: \.id) { agent in
          HStack(spacing: 1) {
            Text(agent.id).bold()
            Text(agent.displayName == agent.id ? agent.subtitle : agent.displayName)
              .foregroundStyle(.muted)
              .lineLimit(1)
              .truncationMode(.tail)
            Spacer(minLength: 1)
            Button("Use") { workspace.useAgent(agent) }
          }
        }
        Divider()
        AgentFormView(workspace: workspace)
      }
      SaveConfigurationRow(workspace: workspace)
    }
  }
}

private struct FocusedChatSettings: View {
  @Bindable var conversation: VisualConversation
  let workspace: VisualWorkspace

  private var providerBinding: Binding<String> {
    Binding(
      get: { conversation.profile.provider.rawValue },
      set: { workspace.useProvider(ProviderID($0), for: conversation) })
  }

  private var modelBinding: Binding<String> {
    Binding(
      get: { conversation.profile.model },
      set: { workspace.useModel($0, for: conversation) })
  }

  private var instructionsBinding: Binding<String> {
    Binding(
      get: { conversation.profile.instructions },
      set: { workspace.updateInstructions($0, for: conversation) })
  }

  private var streamingBinding: Binding<Bool> {
    Binding(
      get: { conversation.profile.stream },
      set: { workspace.setStreaming($0, for: conversation) })
  }

  private var toolProxyBinding: Binding<Bool> {
    Binding(
      get: { conversation.profile.useToolProxy },
      set: { workspace.setToolProxy($0, for: conversation) })
  }

  var body: some View {
    Text("Focused chat: \(conversation.title)").bold()
    TextField("Title", text: $conversation.title)
    if workspace.providers.isEmpty {
      Text("No providers are registered.").foregroundStyle(.muted)
    } else {
      Picker("Provider", selection: providerBinding) {
        ForEach(workspace.providers, id: \.id.rawValue) { provider in
          Text(provider.id.rawValue).tag(provider.id.rawValue)
        }
      }
      .pickerStyle(.segmented)
    }
    HStack(spacing: 1) {
      TextField("Model", text: modelBinding)
      Button(workspace.isFetchingModels ? "Fetching…" : "Fetch models") {
        let provider = conversation.profile.provider
        Task { await workspace.fetchModels(for: provider) }
      }
      .disabled(workspace.isFetchingModels)
    }
    if workspace.modelCatalogProvider == conversation.profile.provider,
      !workspace.modelCatalog.isEmpty
    {
      ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(workspace.modelCatalog, id: \.id) { model in
            Button {
              workspace.useModel(model.id)
            } label: {
              HStack(spacing: 1) {
                Text(model.id == conversation.profile.model ? "▶" : " ").foregroundStyle(.tint)
                Text(model.id)
                if model.displayName != model.id {
                  Text(model.displayName).foregroundStyle(.muted)
                }
              }
            }
            .buttonStyle(.plain)
          }
        }
      }
      .frame(height: min(8, workspace.modelCatalog.count), alignment: .topLeading)
      .border(.separator, placement: .outset)
    }
    Text("Instructions (system prompt)")
    TextEditor(text: instructionsBinding)
      .frame(height: 5)
      .border(.separator, placement: .outset)
    Toggle("Stream replies", isOn: streamingBinding)
    Toggle("Tool proxy", isOn: toolProxyBinding)
    HStack(spacing: 1) {
      Text("Tools: \(conversation.profile.toolNames.sorted().joined(separator: ", "))")
        .foregroundStyle(.muted)
        .lineLimit(2)
    }
    Button("Reset conversation with these settings") { conversation.resetTranscript() }
  }
}

private struct AgentFormView: View {
  let workspace: VisualWorkspace
  @State private var form = AgentForm()
  @State private var message: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Save the focused chat as an agent").bold()
      Text("Provider, model, instructions, tools, and proxy settings are captured.")
        .foregroundStyle(.muted)
        .lineLimit(2)
      TextField("Agent identifier", text: $form.id)
      TextField("Display name", text: $form.displayName)
      Button("Save agent") { submit() }
        .disabled(form.id.isEmpty)
      if let message {
        Text(message).foregroundStyle(message.hasPrefix("error") ? .danger : .muted).lineLimit(3)
      }
    }
  }

  private func submit() {
    let form = form
    Task {
      do {
        try await workspace.saveFocusedConversationAsAgent(form)
        message = "Saved agent '\(form.id)'."
        self.form = AgentForm()
      } catch {
        message = "error: \(error.localizedDescription)"
      }
    }
  }
}

extension AgentDefinition {
  fileprivate var subtitle: String {
    model.isEmpty ? provider.rawValue : "\(provider.rawValue)/\(model)"
  }
}
