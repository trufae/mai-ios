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
        if workspace.configurationChanged {
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

  var body: some View {
    Text("Tools allowed in '\(conversation.title)'").bold()
    Text(
      "\(conversation.profile.toolNames.count) of \(workspace.tools.count) enabled. Return toggles the focused row."
    )
    .foregroundStyle(.muted)
    Toggle("Tool proxy (models see list-tools and call-tool)", isOn: $conversation.profile.useToolProxy)
    Divider()
    if workspace.tools.isEmpty {
      Text("No tools are registered.").foregroundStyle(.muted)
    }
    ForEach(workspace.tools, id: \.name) { tool in
      VStack(alignment: .leading, spacing: 0) {
        Toggle(
          "\(tool.name) [\(tool.annotations.approval.rawValue)]",
          isOn: Binding(
            get: { conversation.profile.toolNames.contains(tool.name) },
            set: { workspace.setTool(tool.name, allowed: $0, for: conversation) }))
        Text("  \(tool.description)").foregroundStyle(.separator).lineLimit(1).truncationMode(.tail)
      }
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
      set: { workspace.useProvider(ProviderID($0)) })
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
      TextField("Model", text: $conversation.profile.model)
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
    TextEditor(text: $conversation.profile.instructions)
      .frame(height: 5)
      .border(.separator, placement: .outset)
      .onChange(of: conversation.profile.instructions) { conversation.applyInstructions() }
    Toggle("Stream replies", isOn: $conversation.profile.stream)
    Toggle("Tool proxy", isOn: $conversation.profile.useToolProxy)
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
