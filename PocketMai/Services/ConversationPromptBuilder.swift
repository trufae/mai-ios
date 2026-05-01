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
  static func compactRequest(
    conversation: Conversation,
    settings: AppSettings
  ) async -> CompactConversationRequest? {
    await Task.detached(priority: .userInitiated) {
      let transcriptEntries = conversation.messages.compactMap { msg -> String? in
        guard msg.role != .error else { return nil }
        let text = MessageContentFilter.promptSafeText(from: msg.text)
        guard !text.isEmpty else { return nil }
        return "\(msg.role.displayName):\n\(text)"
      }
      guard transcriptEntries.count >= 2 else { return nil }

      let transcript = transcriptEntries.joined(separator: "\n\n---\n\n")
      let model: String = {
        let m = conversation.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !m.isEmpty { return m }
        if conversation.provider == .apple { return settings.appleModelID }
        if let endpoint = settings.openAIEndpoints.first(where: { $0.id == conversation.endpointID }
        ) {
          return endpoint.defaultModel
        }
        return ""
      }()

      let prompt = """
        Compact the transcript below into durable context for continuing the same chat.

        Output only the compacted context. Do not include hidden reasoning, XML tags, prompt scaffolding, or commentary about the task.

        Preserve:
        - User goals, preferences, constraints, and decisions
        - Important names, projects, files, commands, code snippets, errors, and results
        - Current state, unresolved questions, and next steps

        Drop greetings, filler, repeated text, tool protocol blocks, and implementation details that no longer matter. Write concise bullets grouped by topic when useful.

        Transcript:

        \(transcript)
        """
      return CompactConversationRequest(
        conversationID: conversation.id,
        oneShot: OneShotPromptRequest(
          title: "Compact",
          prompt: prompt,
          provider: conversation.provider,
          modelID: model,
          endpointID: conversation.endpointID
        )
      )
    }.value
  }

  static func memoryUpdateRequest(
    conversations: [Conversation],
    settings: AppSettings
  ) async -> OneShotPromptRequest? {
    await Task.detached(priority: .userInitiated) {
      let transcript =
        conversations
        .filter { !$0.isIncognito }
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
      let provider = settings.defaultProvider
      let model =
        provider == .apple
        ? settings.appleModelID : (settings.openAIEndpoints.first?.defaultModel ?? "")
      return OneShotPromptRequest(
        title: "Memory update",
        prompt: prompt,
        provider: provider,
        modelID: model,
        endpointID: settings.selectedEndpointID
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
    oneShot.enabledTools = []
    oneShot.usesStreaming = false
    oneShot.messages = [ChatMessage(role: .user, text: prompt.prompt)]
    let request = ChatCompletionRequest(
      conversation: oneShot,
      settings: settings,
      toolContext: "",
      assistantMessageID: UUID()
    )
    return try await ChatProviderRouter.complete(request: request) { _ in }
  }
}
