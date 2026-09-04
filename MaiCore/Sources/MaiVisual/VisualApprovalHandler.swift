import Foundation
import MaiCore

/// Routes interactive tool approvals to the visual workspace while it owns the
/// terminal. Hosts install it as the delegate of their usual approval handler
/// and detach it when the workspace exits; pending requests are then denied.
public actor VisualApprovalHandler: ApprovalHandler {
  public struct Pending: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let request: ApprovalRequest
  }

  private var presenter: (@Sendable (Pending) async -> Void)?
  private var continuations: [UUID: CheckedContinuation<ApprovalDecision, any Error>] = [:]

  public init() {}

  public var pendingCount: Int { continuations.count }

  func attach(presenter: @escaping @Sendable (Pending) async -> Void) {
    self.presenter = presenter
  }

  func detach() {
    presenter = nil
    let waiting = continuations
    continuations.removeAll()
    for continuation in waiting.values {
      continuation.resume(returning: .deny(reason: "Visual mode ended before the approval."))
    }
  }

  public func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
    guard let presenter else {
      return .deny(reason: "No interactive approval surface is available.")
    }
    let pending = Pending(id: UUID(), request: request)
    return try await withCheckedThrowingContinuation { continuation in
      continuations[pending.id] = continuation
      Task { await presenter(pending) }
    }
  }

  /// Completes a pending request. Unknown identifiers are ignored so a dismissed
  /// sheet can safely deny a request that was already answered.
  public func resolve(_ id: UUID, with decision: ApprovalDecision) {
    continuations.removeValue(forKey: id)?.resume(returning: decision)
  }
}
