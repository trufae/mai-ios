import Foundation
import Testing

@testable import MaiCore
@testable import MaiStandardTools

@Test("Shared Files tools manage a root-scoped text workspace")
func fileWorkspaceToolsManageFiles() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("mai-files-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let configuration = MaiFileWorkspaceConfiguration(
    rootURL: root,
    displayName: "test-workspace")
  let tools = MaiFileWorkspaceTool.makeTools(configuration: configuration)
  #expect(Set(tools.map(\.definition.name)) == Set(MaiFileWorkspaceTool.toolNames))
  #expect(tool(tools, .delete).definition.annotations.approval == .dangerous)
  #expect(tool(tools, .delete).definition.annotations.destructive)

  let write = try await call(
    tool(tools, .write),
    ["path": .string("notes/todo.md"), "content": .string("one")])
  #expect(!write.isError)
  #expect(write.structuredContent?.objectValue?["bytes"] == .integer(3))

  _ = try await call(
    tool(tools, .write),
    [
      "path": .string("notes/todo.md"),
      "content": .string("\ntwo"),
      "append": .bool(true),
    ])
  let read = try await call(tool(tools, .read), ["path": .string("notes/todo.md")])
  #expect(read.text == "one\ntwo")
  #expect(read.structuredContent?.objectValue?["truncated"] == .bool(false))

  _ = try await call(
    tool(tools, .write),
    ["path": .string("record.json"), "content": .string("{\"name\":\"Mai\"}")])
  let document = try await call(
    tool(tools, .readDocument),
    ["path": .string("record.json"), "max_bytes": .integer(4)])
  #expect(document.text == "name")
  #expect(document.structuredContent?.objectValue?["nextOffset"] == .integer(4))
  #expect(document.structuredContent?.objectValue?["truncated"] == .bool(true))
  #expect(
    document.structuredContent?.objectValue?["conversion"]
      == .string("converted from JSON to an indented outline"))

  let listing = try await call(tool(tools, .list), ["path": .string("notes")])
  let entries = listing.structuredContent?.objectValue?["entries"]?.arrayValue
  #expect(entries?.first?.objectValue?["path"] == .string("notes/todo.md"))

  let found = try await call(tool(tools, .find), ["query": .string("tdmd")])
  #expect(found.structuredContent?.objectValue?["matches"]?.arrayValue?.first?.objectValue?["path"] == .string("notes/todo.md"))
  let grepped = try await call(tool(tools, .grep), ["query": .string("two")])
  let grepMatch = grepped.structuredContent?.objectValue?["matches"]?.arrayValue?.first
  #expect(grepMatch?.objectValue?["path"] == .string("notes/todo.md"))
  #expect(grepMatch?.objectValue?["line"] == .integer(2))

  _ = try await call(
    tool(tools, .rename),
    ["path": .string("notes/todo.md"), "new_path": .string("notes/done.md")])
  #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("notes/done.md").path))

  _ = try await call(tool(tools, .delete), ["path": .string("notes/done.md")])
  #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("notes/done.md").path))
}

@Test("Shared Files tools reject traversal and symlink escapes")
func fileWorkspaceToolsStayInsideRoot() async throws {
  let base = FileManager.default.temporaryDirectory
    .appendingPathComponent("mai-files-boundary-\(UUID().uuidString)", isDirectory: true)
  let root = base.appendingPathComponent("root", isDirectory: true)
  let outside = base.appendingPathComponent("outside", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
  try Data("private".utf8).write(to: outside.appendingPathComponent("secret.txt"))
  try FileManager.default.createSymbolicLink(
    at: root.appendingPathComponent("escape"),
    withDestinationURL: outside)
  defer { try? FileManager.default.removeItem(at: base) }

  let tools = MaiFileWorkspaceTool.makeTools(
    configuration: MaiFileWorkspaceConfiguration(rootURL: root))
  let traversal = try await call(
    tool(tools, .write),
    ["path": .string("../outside/new.txt"), "content": .string("no")])
  #expect(traversal.isError)
  #expect(traversal.text.contains("outside the configured workspace"))
  #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("new.txt").path))

  let symlink = try await call(
    tool(tools, .read),
    ["path": .string("escape/secret.txt")])
  #expect(symlink.isError)
  #expect(symlink.text.contains("outside the configured workspace"))

  let grep = try await call(tool(tools, .grep), ["query": .string("private")])
  #expect(grep.text == "No matching lines.")
}

@Test("Files group can expose a read-only workspace")
func fileWorkspaceCanDisableChanges() async throws {
  let root = FileManager.default.temporaryDirectory
  let context = PluginFactoryContext(
    id: "standard",
    options: [
      "filesRoot": .string(root.path),
      "filesWriteEnabled": .bool(false),
    ])
  let factory = MaiStandardToolFactory()
  let tools = try await factory.makeTools(context: context)
  let names = Set(tools.map(\.definition.name))
  #expect(names.contains(MaiFileWorkspaceTool.Operation.list.rawValue))
  #expect(names.contains(MaiFileWorkspaceTool.Operation.read.rawValue))
  #expect(!names.contains(MaiFileWorkspaceTool.Operation.write.rawValue))
  #expect(!names.contains(MaiFileWorkspaceTool.Operation.rename.rawValue))
  #expect(!names.contains(MaiFileWorkspaceTool.Operation.delete.rawValue))

  let group = try #require(try await factory.toolGroups(context: context).first { $0.id == "files" })
  #expect(group.toolNames.contains(MaiReadTextFileTool.name))
  #expect(group.toolNames.contains(MaiFileWorkspaceTool.Operation.read.rawValue))
  #expect(!group.toolNames.contains(MaiFileWorkspaceTool.Operation.write.rawValue))
  #expect(group.options.contains { $0.id == "filesWriteEnabled" })
}

@Test("Files tools propagate task cancellation")
func fileWorkspaceToolsPropagateCancellation() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("mai-files-cancel-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let grep = MaiFileWorkspaceTool(
    operation: .grep,
    configuration: MaiFileWorkspaceConfiguration(rootURL: root))
  let (stream, continuation) = AsyncStream<Void>.makeStream()
  let task = Task {
    for await _ in stream { break }
    return try await call(grep, ["query": .string("needle")])
  }

  task.cancel()
  continuation.yield()
  continuation.finish()
  do {
    _ = try await task.value
    Issue.record("Expected files_grep to propagate cancellation")
  } catch is CancellationError {
    // Expected: the runtime can return to the REPL instead of treating cancellation as tool output.
  }
}

private func tool(
  _ tools: [MaiFileWorkspaceTool],
  _ operation: MaiFileWorkspaceTool.Operation
) -> MaiFileWorkspaceTool {
  tools.first { $0.operation == operation }!
}

private func call(
  _ tool: MaiFileWorkspaceTool,
  _ arguments: [String: JSONValue]
) async throws -> ToolOutput {
  try await tool.call(
    arguments: .object(arguments),
    context: ToolExecutionContext(
      run: AgentEventContext(
        runID: UUID(),
        parentRunID: nil,
        agentID: "files-test",
        depth: 0),
      modelTurn: 1))
}
