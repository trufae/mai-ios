import Foundation

@MainActor
enum AssistantTurnRunner {
  static func run(
    conversationID: UUID,
    context: String,
    store: AppStore
  ) async {
    guard !Task.isCancelled else { return }
    guard let assistantID = store.appendAssistantMessage(to: conversationID) else {
      return
    }

    do {
      try await AssistantToolLoop.run(
        conversationID: conversationID,
        assistantID: assistantID,
        baseContext: context,
        store: store)
    } catch is CancellationError {
      store.markAssistantStopped(id: assistantID)
    } catch {
      let nsError = error as NSError
      if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
        store.markAssistantStopped(id: assistantID)
      } else {
        let text = error.localizedDescription
        store.setAssistantMessage(id: assistantID, text: text, role: .error)
        store.errorMessage = text
      }
    }
  }
}
