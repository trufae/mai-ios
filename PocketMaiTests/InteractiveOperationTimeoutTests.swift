import XCTest

@testable import PocketMai

@MainActor
final class InteractiveOperationTimeoutTests: XCTestCase {
  private actor ExecutionCounter {
    private(set) var value = 0

    func increment() {
      value += 1
    }
  }

  func testContinueResetsTimerWithoutRestartingOperation() async throws {
    let executions = ExecutionCounter()
    var timeoutCount = 0

    let result = try await InteractiveOperationTimeout.run(
      seconds: 0.01,
      context: context
    ) { _ in
      timeoutCount += 1
      return .continue
    } operation: {
      await executions.increment()
      try await Task.sleep(for: .milliseconds(35))
      return "finished"
    }

    let executionCount = await executions.value
    XCTAssertEqual(result, "finished")
    XCTAssertGreaterThanOrEqual(timeoutCount, 1)
    XCTAssertEqual(executionCount, 1)
  }

  func testSkipCancelsOnlyTheTimedOperation() async {
    do {
      _ = try await InteractiveOperationTimeout.run(
        seconds: 0.01,
        context: context,
        onTimeout: { _ in .skip }
      ) {
        try await Task.sleep(for: .seconds(1))
        return "unexpected"
      }
      XCTFail("Expected the operation to be skipped")
    } catch is LongRunningOperationSkipped {
      // Expected control flow.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testInterruptThrowsCancellation() async {
    do {
      _ = try await InteractiveOperationTimeout.run(
        seconds: 0.01,
        context: context,
        onTimeout: { _ in .interrupt }
      ) {
        try await Task.sleep(for: .seconds(1))
        return "unexpected"
      }
      XCTFail("Expected the operation to be interrupted")
    } catch is CancellationError {
      // Expected control flow.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  private var context: LongRunningOperationContext {
    LongRunningOperationContext(
      kind: .modelResponse,
      conversationID: nil,
      assistantMessageID: nil,
      operationName: "Test operation",
      conversationTitle: nil,
      timeoutInterval: 0.01)
  }
}
