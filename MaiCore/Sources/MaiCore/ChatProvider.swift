public protocol ChatProvider: Sendable {
  var descriptor: ProviderDescriptor { get }

  func availableModels() async throws -> [ModelDescriptor]

  func complete(
    _ request: ProviderRequest,
    emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse
}

extension ChatProvider {
  public func availableModels() async throws -> [ModelDescriptor] { [] }

  public func complete(_ request: ProviderRequest) async throws -> ProviderResponse {
    try await complete(request) { _ in }
  }
}
