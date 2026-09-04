public struct HelloProvider: ChatProvider {
  public let descriptor: ProviderDescriptor
  private let prefix: String

  public init(
    id: ProviderID = .hello,
    displayName: String = "MaiCore Hello",
    prefix: String = "Hello from MaiCore"
  ) {
    descriptor = ProviderDescriptor(
      id: id,
      displayName: displayName,
      capabilities: [.streaming, .imageInput])
    self.prefix = prefix
  }

  public func complete(
    _ request: ProviderRequest,
    emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    try Task.checkCancellation()
    let prompt =
      request.messages.last(where: { $0.role == .user })?.text
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let text = prompt.isEmpty ? "\(prefix)." : "\(prefix): \(prompt)"
    await emit(.textDelta(text))
    return ProviderResponse(
      message: .assistant(text),
      stopReason: .stop)
  }

  public func availableModels() async throws -> [ModelDescriptor] {
    [ModelDescriptor(id: "hello", displayName: "Offline hello")]
  }
}
