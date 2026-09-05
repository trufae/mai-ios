import Foundation
import Testing

@testable import MaiCore
@testable import MaiStandardTools

@Test("Run tools execute shell command lines and report output and exit codes")
func runSystemCapturesOutput() async throws {
  let tools = MaiRunTool.makeTools(configuration: MaiRunConfiguration())
  #expect(Set(tools.map(\.definition.name)) == Set(MaiRunTool.toolNames))
  #expect(tools.allSatisfy { $0.definition.annotations.approval == .dangerous })
  #expect(tools.allSatisfy { $0.definition.annotations.destructive })

  let ok = try await call(tool(tools, .system), ["command": .string("printf 'hello world'")])
  #expect(!ok.isError)
  #expect(ok.text == "hello world")
  #expect(ok.structuredContent?.objectValue?["exitCode"] == .integer(0))
  #expect(ok.structuredContent?.objectValue?["timedOut"] == .bool(false))

  let failed = try await call(
    tool(tools, .system),
    ["command": .string("printf out; printf oops >&2; exit 3")])
  #expect(failed.isError)
  #expect(failed.text.contains("out"))
  #expect(failed.text.contains("[stderr]\noops"))
  #expect(failed.text.contains("[exit code 3]"))
  #expect(failed.structuredContent?.objectValue?["exitCode"] == .integer(3))

  let silent = try await call(tool(tools, .system), ["command": .string("true")])
  #expect(silent.text == "(no output; exit code 0)")

  let missing = try await call(tool(tools, .system), [:])
  #expect(missing.isError)
  #expect(missing.text.contains("command is required"))
}

@Test("Run tools pass stdin, arguments, and the working directory to scripts")
func runShellScriptUsesArgumentsAndStdin() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("mai-run-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let tools = MaiRunTool.makeTools(configuration: MaiRunConfiguration())

  let output = try await call(
    tool(tools, .shell),
    [
      "script": .string("echo \"first=$1 second=$2\"\ncat\npwd"),
      "args": .array([.string("a b"), .string("c")]),
      "stdin": .string("from stdin\n"),
      "cwd": .string(directory.path),
    ])
  #expect(!output.isError)
  let lines = output.text.split(separator: "\n").map(String.init)
  #expect(lines.first == "first=a b second=c")
  #expect(lines.dropFirst().first == "from stdin")
  #expect(lines.last.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
    == directory.standardizedFileURL.resolvingSymlinksInPath().path)

  let badDirectory = try await call(
    tool(tools, .shell),
    ["script": .string("true"), "cwd": .string(directory.appendingPathComponent("nope").path)])
  #expect(badDirectory.isError)
  #expect(badDirectory.text.contains("is not a directory"))
}

@Test("Run tools execute Python and Node.js scripts when the interpreters are installed")
func runPythonAndJavaScript() async throws {
  let tools = MaiRunTool.makeTools(configuration: MaiRunConfiguration())
  let environment = ProcessInfo.processInfo.environment
  if (try? MaiHostProcess.resolve("python3", environment: environment)) != nil {
    let output = try await call(
      tool(tools, .python),
      [
        "script": .string("import sys\nprint('py', sys.argv[1], sys.stdin.read().strip())"),
        "args": .array([.string("arg")]),
        "stdin": .string("in"),
      ])
    #expect(!output.isError)
    #expect(output.text == "py arg in")
  }
  if (try? MaiHostProcess.resolve("node", environment: environment)) != nil {
    let output = try await call(
      tool(tools, .javascript),
      [
        "script": .string("console.log('js', process.argv[2]); process.exitCode = 2"),
        "args": .array([.string("arg")]),
      ])
    #expect(output.isError)
    #expect(output.text.contains("js arg"))
    #expect(output.structuredContent?.objectValue?["exitCode"] == .integer(2))
  }
  let missing = MaiRunTool(
    operation: .python,
    configuration: MaiRunConfiguration(python: "pmai-no-such-interpreter"))
  let unavailable = try await call(missing, ["script": .string("print(1)")])
  #expect(unavailable.isError)
  #expect(unavailable.text.contains("was not found in PATH"))
}

@Test("Run tools kill processes that exceed their timeout")
func runToolsEnforceTimeout() async throws {
  let tools = MaiRunTool.makeTools(configuration: MaiRunConfiguration())
  let started = Date()
  let output = try await call(
    tool(tools, .system),
    ["command": .string("echo started; sleep 30; echo finished"), "timeout_seconds": .integer(1)])
  #expect(Date().timeIntervalSince(started) < 10)
  #expect(output.isError)
  #expect(output.text.contains("started"))
  #expect(!output.text.contains("finished"))
  #expect(output.text.contains("timed out after 1 seconds"))
  #expect(output.structuredContent?.objectValue?["timedOut"] == .bool(true))
}

@Test("Run tools cap captured output")
func runToolsTruncateOutput() async throws {
  let tool = MaiRunTool(
    operation: .system,
    configuration: MaiRunConfiguration(outputLimit: 1_024))
  let output = try await call(tool, ["command": .string("head -c 5000 /dev/zero | tr '\\0' x")])
  #expect(!output.isError)
  #expect(output.text.hasPrefix(String(repeating: "x", count: 1_024)))
  #expect(output.text.contains("[stdout truncated: 3976 more bytes not shown]"))
  #expect(output.structuredContent?.objectValue?["truncated"] == .bool(true))
}

@Test("Run tools terminate the child when the task is cancelled")
func runToolsPropagateCancellation() async throws {
  let tools = MaiRunTool.makeTools(configuration: MaiRunConfiguration())
  let marker = FileManager.default.temporaryDirectory
    .appendingPathComponent("mai-run-cancel-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: marker) }
  let task = Task {
    try await call(
      tool(tools, .system),
      ["command": .string("sleep 30; touch '\(marker.path)'")])
  }
  try await Task.sleep(for: .milliseconds(300))
  let started = Date()
  task.cancel()
  do {
    _ = try await task.value
    Issue.record("Expected run_system to propagate cancellation")
  } catch is CancellationError {
    // Expected: the REPL regains control and the child is gone.
  }
  #expect(Date().timeIntervalSince(started) < 10)
  #expect(!FileManager.default.fileExists(atPath: marker.path))
}

@Test("Standard tool factory exposes the Run group with its options")
func standardFactoryExposesRunGroup() async throws {
  let context = PluginFactoryContext(
    id: "standard",
    options: ["runPython": .string("python3 -u"), "runTimeoutSeconds": .integer(5)])
  let factory = MaiStandardToolFactory()
  let tools = try await factory.makeTools(context: context)
  let python = try #require(
    tools.first { $0.definition.name == MaiRunTool.Operation.python.rawValue } as? MaiRunTool)
  #expect(python.configuration.python == "python3 -u")
  #expect(python.configuration.defaultTimeout == 5)
  #expect(python.definition.description.contains("python3 -u"))

  let group = try #require(try await factory.toolGroups(context: context).first { $0.id == "run" })
  #expect(group.toolNames == Set(MaiRunTool.toolNames))
  #expect(group.options.map(\.id) == ["runShell", "runPython", "runNode", "runTimeoutSeconds"])
}

private func tool(_ tools: [MaiRunTool], _ operation: MaiRunTool.Operation) -> MaiRunTool {
  tools.first { $0.operation == operation }!
}

private func call(
  _ tool: MaiRunTool,
  _ arguments: [String: JSONValue]
) async throws -> ToolOutput {
  try await tool.call(
    arguments: .object(arguments),
    context: ToolExecutionContext(
      run: AgentEventContext(
        runID: UUID(),
        parentRunID: nil,
        agentID: "run-test",
        depth: 0),
      modelTurn: 1))
}
