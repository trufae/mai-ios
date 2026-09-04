import Foundation
import MaiCore
import SwiftTUICLI
import SwiftTUIRuntime

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Runs the SwiftTUI workspace over the caller's terminal and returns the state
/// the host should adopt once the user leaves it.
public enum VisualMode {
  @MainActor
  public static func run(
    _ launch: VisualLaunch,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    approvals: VisualApprovalHandler
  ) async throws -> VisualOutcome {
    let workspace = VisualWorkspace(
      launch: launch,
      runtime: runtime,
      plugins: plugins,
      approvals: approvals)
    await approvals.attach { pending in
      await workspace.present(pending)
    }
    await workspace.refreshRegistries()
    VisualAppContext.workspace = workspace
    defer { VisualAppContext.workspace = nil }

    let configuration = RuntimeConfiguration.detect(
      environment: launch.environment,
      isStdoutTTY: isatty(STDOUT_FILENO) != 0)
    do {
      try await TerminalRunner.run(VisualApp(), configuration: configuration)
    } catch {
      _ = workspace.shutdown()
      await approvals.detach()
      throw error
    }
    let outcome = workspace.shutdown()
    await approvals.detach()
    return outcome
  }
}

/// `App` types need a parameterless initializer, so the running workspace is
/// handed over through this main-actor slot for the duration of one session.
@MainActor
enum VisualAppContext {
  static var workspace: VisualWorkspace?
}

struct VisualApp: App {
  nonisolated init() {}

  var body: some Scene {
    WindowGroup("pmai") {
      if let workspace = VisualAppContext.workspace {
        VisualRootView(workspace: workspace)
      } else {
        Text("The visual workspace is not available.")
      }
    }
    .exitOnKeys([
      KeyPress(.character("c"), modifiers: .ctrl),
      KeyPress(.character("q"), modifiers: .ctrl),
    ])
  }
}
