import Foundation

enum FollowUpPromptBuilder {
  static func request(
    conversation: Conversation,
    settings: AppSettings
  ) -> OneShotPromptRequest? {
    let followUps = settings.followUps
    guard followUps.isEnabled else { return nil }

    let contextCount = FollowUpSettings.clampedContextMessageCount(
      followUps.contextMessageCount)
    let transcriptEntries = conversation.messages.compactMap { message -> String? in
      guard message.role != .error else { return nil }
      let text = MessageContentFilter.promptSafeText(from: message.text)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return nil }
      return "\(message.role.displayName):\n\(text)"
    }
    guard !transcriptEntries.isEmpty else { return nil }

    let transcript = transcriptEntries.suffix(contextCount).joined(separator: "\n\n---\n\n")
    let count = FollowUpSettings.clampedSuggestionCount(followUps.suggestionCount)
    let customPrompt = settings.followUpPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
    let instruction = customPrompt.isEmpty ? FollowUpSettings.defaultPrompt : customPrompt
    let outputInstruction: String
    if conversation.provider == .apple {
      outputInstruction =
        "Write exactly \(count) options. Keep each option to one sentence and at most 12 words."
    } else {
      outputInstruction = """
        Generate exactly \(count) options. Each option must be a single short sentence of no more than 12 words. Questions and brief statements are both allowed.

        Return only one valid JSON object in this exact shape, with no Markdown or commentary:
        {"options":["First option","Second option"]}
        """
    }
    let prompt = """
      \(instruction)

      \(outputInstruction)

      Recent conversation:

      \(transcript)
      """

    return OneShotPromptRequest(
      title: "Follow-ups",
      prompt: prompt,
      provider: conversation.provider,
      modelID: effectiveModelID(for: conversation, settings: settings),
      endpointID: conversation.endpointID,
      responseFormat: .followUpSuggestions(count: count))
  }

  private static func effectiveModelID(
    for conversation: Conversation,
    settings: AppSettings
  ) -> String {
    let configured = conversation.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    if !configured.isEmpty { return configured }
    switch conversation.provider {
    case .apple:
      return settings.appleModelID
    case .mlx:
      return LocalMLXProvider.effectiveModelID(conversation: conversation, settings: settings)
    case .openAICompatible:
      return OpenAICompatibleProvider.selectedEndpoint(for: conversation, settings: settings)?
        .defaultModel ?? ""
    }
  }
}

enum FollowUpSuggestionParser {
  private static let maximumAcceptedWordCount = 24

  private struct Payload: Decodable {
    let options: [String]
  }

  static func parse(_ response: String, limit: Int) -> [String] {
    let limit = FollowUpSettings.clampedSuggestionCount(limit)
    let visibleResponse = MessageContentFilter.removingReasoningSections(from: response)
    let candidates = decodedOptions(from: visibleResponse) ?? fallbackOptions(from: visibleResponse)
    var seen = Set<String>()
    var result: [String] = []

    for candidate in candidates {
      let option = normalizedOption(candidate)
      let key = option.folding(
        options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      let wordCount = option.split(whereSeparator: \Character.isWhitespace).count
      guard !option.isEmpty, wordCount <= maximumAcceptedWordCount,
        seen.insert(key).inserted
      else { continue }
      result.append(option)
      if result.count == limit { break }
    }
    return result
  }

  private static func decodedOptions(from response: String) -> [String]? {
    let decoder = JSONDecoder()
    for candidate in jsonCandidates(from: response) {
      guard let data = candidate.data(using: .utf8) else { continue }
      if let payload = try? decoder.decode(Payload.self, from: data) {
        return payload.options
      }
      if let options = try? decoder.decode([String].self, from: data) {
        return options
      }
    }
    return nil
  }

  private static func jsonCandidates(from response: String) -> [String] {
    let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
    var candidates = [trimmed]
    if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start <= end {
      candidates.append(String(trimmed[start...end]))
    }
    if let start = trimmed.firstIndex(of: "["), let end = trimmed.lastIndex(of: "]"), start <= end {
      candidates.append(String(trimmed[start...end]))
    }
    return candidates
  }

  private static func fallbackOptions(from response: String) -> [String] {
    response.split(whereSeparator: \Character.isNewline).map { line in
      var option = line.trimmingCharacters(in: .whitespacesAndNewlines)
      while let first = option.first, "-•*0123456789.) ".contains(first) {
        option.removeFirst()
      }
      return option
    }
  }

  private static func normalizedOption(_ raw: String) -> String {
    let collapsed = raw.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    return collapsed.trimmingCharacters(
      in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”")))
  }
}
