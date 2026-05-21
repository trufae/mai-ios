import Foundation

struct OneShotPromptRequest: Sendable {
  let title: String
  let prompt: String
  let provider: ProviderKind
  let modelID: String
  let endpointID: UUID?
}

struct CompactConversationRequest: Sendable {
  let conversationID: UUID
  let oneShot: OneShotPromptRequest
}

enum ConversationPromptBuilder {
  static let transcriptPlaceholder = "{{transcript}}"

  static func compactPrompt(conversation: Conversation, settings: AppSettings) async -> String? {
    await Task.detached(priority: .userInitiated) {
      compactPromptText(conversation: conversation, template: settings.compactPrompt)
    }.value
  }

  static func compactRequest(
    conversation: Conversation,
    settings: AppSettings,
    prompt: String? = nil
  ) async -> CompactConversationRequest? {
    await Task.detached(priority: .userInitiated) {
      let promptText: String
      if let prompt {
        promptText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !promptText.isEmpty else { return nil }
      } else {
        guard
          let generated = compactPromptText(
            conversation: conversation,
            template: settings.compactPrompt)
        else { return nil }
        promptText = generated
      }
      let model: String = {
        let m = conversation.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !m.isEmpty { return m }
        if conversation.provider == .apple { return settings.appleModelID }
        if conversation.provider == .mlx {
          return LocalMLXProvider.effectiveModelID(conversation: conversation, settings: settings)
        }
        if let endpoint = OpenAICompatibleProvider.selectedEndpoint(
          for: conversation, settings: settings)
        {
          return endpoint.defaultModel
        }
        return ""
      }()

      return CompactConversationRequest(
        conversationID: conversation.id,
        oneShot: OneShotPromptRequest(
          title: "Compact",
          prompt: promptText,
          provider: conversation.provider,
          modelID: model,
          endpointID: conversation.endpointID
        )
      )
    }.value
  }

  private static func compactPromptText(conversation: Conversation, template: String) -> String? {
    let transcriptEntries = conversation.messages.compactMap { msg -> String? in
      guard msg.role != .error else { return nil }
      let text = MessageContentFilter.promptSafeText(from: msg.text)
      guard !text.isEmpty else { return nil }
      return "\(msg.role.displayName):\n\(text)"
    }
    guard transcriptEntries.count >= 2 else { return nil }

    let transcript = transcriptEntries.joined(separator: "\n\n---\n\n")
    let promptTemplate = template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? AppSettings.defaultCompactPrompt
      : template
    if promptTemplate.contains(transcriptPlaceholder) {
      return promptTemplate.replacingOccurrences(of: transcriptPlaceholder, with: transcript)
    }
    return "\(promptTemplate)\n\nTranscript:\n\n\(transcript)"
  }

  static func memoryUpdateRequest(
    conversations: [Conversation],
    settings: AppSettings
  ) async -> OneShotPromptRequest? {
    await Task.detached(priority: .userInitiated) {
      let transcript =
        conversations
        .flatMap { conversation in
          conversation.messages.compactMap { message -> String? in
            guard message.role != .error else { return nil }
            let text = MessageContentFilter.promptSafeText(from: message.text)
            guard !text.isEmpty else { return nil }
            return "\(message.role.displayName):\n\(text)"
          }
        }
        .joined(separator: "\n\n")
      guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
      }

      let prompt = """
        Extract durable user memory from these conversations.

        Output only concise memory notes. Do not include hidden reasoning, XML tags, prompt scaffolding, or commentary about this task.

        Keep stable facts and recurring preferences: names, locations, projects, technical preferences, workflow habits, and standing instructions. Ignore one-off tasks, transient chat state, assistant behavior, tool outputs unless they reveal a durable user preference, and sensitive secrets such as credentials or tokens.

        \(transcript)
        """
      let defaultProvider = settings.defaultProviderConfiguration
      return OneShotPromptRequest(
        title: "Memory update",
        prompt: prompt,
        provider: defaultProvider.provider,
        modelID: defaultProvider.modelID,
        endpointID: defaultProvider.endpointID
      )
    }.value
  }
}

enum OneShotPromptRunner {
  static func run(_ prompt: OneShotPromptRequest, settings: AppSettings) async throws -> String {
    var oneShot = Conversation()
    oneShot.title = prompt.title
    oneShot.provider = prompt.provider
    oneShot.modelID = prompt.modelID
    oneShot.endpointID = prompt.endpointID
    oneShot.toolsEnabled = false
    oneShot.enabledTools = []
    oneShot.usesStreaming = false
    oneShot.messages = [ChatMessage(role: .user, text: prompt.prompt)]
    let request = ChatCompletionRequest(
      conversation: oneShot,
      settings: settings,
      context: "",
      assistantMessageID: UUID()
    )
    return try await ChatProviderRouter.complete(request: request) { _ in }
  }
}
