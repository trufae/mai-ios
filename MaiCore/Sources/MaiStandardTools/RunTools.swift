import Foundation
import MaiCore

#if canImport(Glibc)
  import Glibc
#endif

/// Configuration for the Run tool group, which executes code on the host with
/// the privileges of the pmai process. Interpreters are names looked up in
/// `PATH` or absolute paths, optionally followed by leading arguments.
public struct MaiRunConfiguration: Equatable, Sendable {
  public static let defaultShell = "/bin/sh"
  public static let defaultPython = "python3"
  public static let defaultNode = "node"
  public static let defaultTimeout: TimeInterval = 60
  public static let maximumTimeout: TimeInterval = 600
  public static let defaultOutputLimit = 100_000

  public var shell: String
  public var python: String
  public var node: String
  public var defaultTimeout: TimeInterval
  public var outputLimit: Int

  public init(
    shell: String = Self.defaultShell,
    python: String = Self.defaultPython,
    node: String = Self.defaultNode,
    defaultTimeout: TimeInterval = Self.defaultTimeout,
    outputLimit: Int = Self.defaultOutputLimit
  ) {
    self.shell = shell.isEmpty ? Self.defaultShell : shell
    self.python = python.isEmpty ? Self.defaultPython : python
    self.node = node.isEmpty ? Self.defaultNode : node
    self.defaultTimeout = min(max(defaultTimeout, 1), Self.maximumTimeout)
    self.outputLimit = max(outputLimit, 1_024)
  }
}

/// One operation in the Run tool group: a shell one-liner, or a shell, Python,
/// or Node.js script written to a temporary file and executed on the host.
public struct MaiRunTool: AgentTool {
  public enum Operation: String, CaseIterable, Sendable {
    case system = "run_system"
    case shell = "run_sh"
    case python = "run_python"
    case javascript = "run_js"

    var scriptExtension: String {
      switch self {
      case .system, .shell: "sh"
      case .python: "py"
      case .javascript: "js"
      }
    }
  }

  public static let toolNames = Operation.allCases.map(\.rawValue)

  /// Spawning processes is unavailable on iOS, where the group is simply absent.
  public static var isSupported: Bool {
    #if os(macOS) || os(Linux)
      true
    #else
      false
    #endif
  }

  public let operation: Operation
  public let configuration: MaiRunConfiguration
  public let definition: ToolDefinition

  public init(operation: Operation, configuration: MaiRunConfiguration) {
    self.operation = operation
    self.configuration = configuration
    definition = Self.definition(for: operation, configuration: configuration)
  }

  public static func makeTools(configuration: MaiRunConfiguration) -> [MaiRunTool] {
    guard isSupported else { return [] }
    return Operation.allCases.map { MaiRunTool(operation: $0, configuration: configuration) }
  }

  var interpreter: String {
    switch operation {
    case .system, .shell: configuration.shell
    case .python: configuration.python
    case .javascript: configuration.node
    }
  }

  public func call(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolOutput {
    #if os(macOS) || os(Linux)
      let arguments = arguments.objectValue ?? [:]
      do {
        try Task.checkCancellation()
        return try await execute(arguments)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        return ToolOutput(text: "Error: \(error.localizedDescription)", isError: true)
      }
    #else
      return ToolOutput(text: "Error: running programs is not supported on this platform.", isError: true)
    #endif
  }

  #if os(macOS) || os(Linux)
    private func execute(_ arguments: [String: JSONValue]) async throws -> ToolOutput {
      let environment = ProcessInfo.processInfo.environment
      let launcher = try MaiHostProcess.resolve(interpreter, environment: environment)
      let workingDirectory = try Self.workingDirectory(arguments["cwd"]?.stringValue)
      let timeout = min(
        max(
          arguments["timeout_seconds"]?.numberValue ?? configuration.defaultTimeout, 1),
        MaiRunConfiguration.maximumTimeout)
      let stdin = arguments["stdin"]?.stringValue
      var extraArguments: [String] = []
      var scriptURL: URL?
      switch operation {
      case .system:
        let command = try Self.requiredText(arguments, key: "command")
        extraArguments = ["-c", command]
      case .shell, .python, .javascript:
        let script = try Self.requiredText(arguments, key: "script")
        let url = try Self.writeScript(script, extension: operation.scriptExtension)
        scriptURL = url
        extraArguments = [url.path]
        if let args = arguments["args"]?.arrayValue {
          extraArguments += args.map { $0.stringValue ?? $0.compactJSONString }
        }
      }
      defer { if let scriptURL { try? FileManager.default.removeItem(at: scriptURL) } }

      let outcome = try await MaiHostProcess.run(
        executable: launcher.executable,
        arguments: launcher.arguments + extraArguments,
        workingDirectory: workingDirectory,
        environment: environment,
        stdin: stdin,
        timeout: timeout,
        outputLimit: configuration.outputLimit)
      return Self.output(for: outcome, timeout: timeout, workingDirectory: workingDirectory)
    }

    private static func output(
      for outcome: MaiHostProcessOutcome,
      timeout: TimeInterval,
      workingDirectory: URL
    ) -> ToolOutput {
      let stdout = String(decoding: outcome.stdout, as: UTF8.self)
        .trimmingCharacters(in: .newlines)
      let stderr = String(decoding: outcome.stderr, as: UTF8.self)
        .trimmingCharacters(in: .newlines)
      var sections: [String] = []
      if !stdout.isEmpty { sections.append(stdout) }
      if outcome.stdoutDropped > 0 {
        sections.append("[stdout truncated: \(outcome.stdoutDropped) more bytes not shown]")
      }
      if !stderr.isEmpty { sections.append("[stderr]\n\(stderr)") }
      if outcome.stderrDropped > 0 {
        sections.append("[stderr truncated: \(outcome.stderrDropped) more bytes not shown]")
      }
      if outcome.timedOut {
        sections.append("[timed out after \(Int(timeout)) seconds; the process was killed]")
      } else if outcome.exitCode != 0 {
        sections.append("[exit code \(outcome.exitCode)]")
      }
      if sections.isEmpty { sections.append("(no output; exit code 0)") }
      return ToolOutput(
        content: [.text(sections.joined(separator: "\n"))],
        structuredContent: .object([
          "exitCode": .integer(Int(outcome.exitCode)),
          "timedOut": .bool(outcome.timedOut),
          "durationMs": .integer(Int(outcome.duration * 1000)),
          "truncated": .bool(outcome.stdoutDropped > 0 || outcome.stderrDropped > 0),
          "cwd": .string(workingDirectory.path),
        ]),
        isError: outcome.timedOut || outcome.exitCode != 0)
    }

    private static func workingDirectory(_ rawPath: String?) throws -> URL {
      let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      guard let rawPath, !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return current
      }
      let expanded = NSString(string: rawPath.trimmingCharacters(in: .whitespacesAndNewlines))
        .expandingTildeInPath
      let target = URL(fileURLWithPath: expanded, isDirectory: true, relativeTo: current)
        .standardizedFileURL
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else { throw MaiRunToolError.notDirectory(rawPath) }
      return target
    }

    private static func writeScript(_ script: String, extension ext: String) throws -> URL {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("pmai-run-\(UUID().uuidString).\(ext)")
      guard
        FileManager.default.createFile(
          atPath: url.path,
          contents: Data(script.utf8),
          attributes: [.posixPermissions: 0o600])
      else { throw MaiRunToolError.scriptWriteFailed(url.path) }
      return url
    }

    private static func requiredText(_ arguments: [String: JSONValue], key: String) throws -> String {
      guard let value = arguments[key]?.stringValue,
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { throw MaiRunToolError.missingArgument(key) }
      return value
    }
  #endif

  private static func definition(
    for operation: Operation,
    configuration: MaiRunConfiguration
  ) -> ToolDefinition {
    var properties: [String: JSONValue] = [:]
    var required: [String] = []
    let description: String
    switch operation {
    case .system:
      description =
        "Run one shell command line on this computer with '\(configuration.shell) -c' and return its stdout, stderr, and exit code."
      properties["command"] = stringProperty(
        "Shell command line. Pipes, globs, redirections, and && chains are allowed.")
      required = ["command"]
    case .shell:
      description =
        "Run a multi-line shell script on this computer with '\(configuration.shell)' and return its stdout, stderr, and exit code."
      properties["script"] = stringProperty(
        "Shell script source. It is saved to a temporary file and run as '\(configuration.shell) FILE ARGS'.")
      required = ["script"]
    case .python:
      description =
        "Run a Python script on this computer with '\(configuration.python)' and return its stdout, stderr, and exit code."
      properties["script"] = stringProperty(
        "Python source. It is saved to a temporary .py file and run as '\(configuration.python) FILE ARGS'.")
      required = ["script"]
    case .javascript:
      description =
        "Run a JavaScript script on this computer with Node.js ('\(configuration.node)') and return its stdout, stderr, and exit code."
      properties["script"] = stringProperty(
        "JavaScript source. It is saved to a temporary .js file and run as '\(configuration.node) FILE ARGS'.")
      required = ["script"]
    }
    if operation != .system {
      properties["args"] = .object([
        "type": .string("array"),
        "items": .object(["type": .string("string")]),
        "description": .string("Command-line arguments passed to the script."),
      ])
    }
    properties["stdin"] = stringProperty(
      "Text piped to the process's standard input. Omit to provide no input.")
    properties["cwd"] = stringProperty(
      "Working directory, absolute or relative to the current directory. Default: the current directory.")
    properties["timeout_seconds"] = .object([
      "type": .string("number"),
      "description": .string(
        "Seconds before the process is killed, 1-\(Int(MaiRunConfiguration.maximumTimeout)). Default: \(Int(configuration.defaultTimeout))."),
    ])
    return ToolDefinition(
      name: operation.rawValue,
      description: description,
      inputSchema: objectSchema(properties: properties, required: required),
      annotations: ToolAnnotations(
        readOnly: false,
        destructive: true,
        idempotent: false,
        openWorld: true,
        approval: .dangerous))
  }

  private static func stringProperty(_ description: String) -> JSONValue {
    .object(["type": .string("string"), "description": .string(description)])
  }
}

enum MaiRunToolError: LocalizedError {
  case missingArgument(String)
  case notDirectory(String)
  case scriptWriteFailed(String)
  case interpreterNotFound(String)

  var errorDescription: String? {
    switch self {
    case .missingArgument(let name): "\(name) is required."
    case .notDirectory(let path): "'\(path)' is not a directory."
    case .scriptWriteFailed(let path): "Could not write the temporary script '\(path)'."
    case .interpreterNotFound(let name):
      "Interpreter '\(name)' was not found in PATH; configure the Run group with its full path."
    }
  }
}

#if os(macOS) || os(Linux)
  struct MaiHostProcessOutcome: Sendable {
    var stdout: Data
    var stderr: Data
    var stdoutDropped: Int
    var stderrDropped: Int
    var exitCode: Int32
    var timedOut: Bool
    var duration: TimeInterval
  }

  /// Runs one child process with bounded output, a kill-on-timeout watchdog,
  /// and termination when the surrounding task is cancelled.
  enum MaiHostProcess {
    private static let terminationGrace: TimeInterval = 2

    /// Splits a configured interpreter such as `python3`, `/usr/bin/env node`,
    /// or `node --no-warnings` into an executable found in `PATH` plus leading arguments.
    static func resolve(
      _ interpreter: String,
      environment: [String: String]
    ) throws -> (executable: URL, arguments: [String]) {
      let parts = interpreter.split(whereSeparator: \.isWhitespace).map(String.init)
      guard let command = parts.first else { throw MaiRunToolError.interpreterNotFound(interpreter) }
      let expanded = NSString(string: command).expandingTildeInPath
      if expanded.contains("/") {
        guard FileManager.default.isExecutableFile(atPath: expanded) else {
          throw MaiRunToolError.interpreterNotFound(command)
        }
        return (URL(fileURLWithPath: expanded), Array(parts.dropFirst()))
      }
      let searchPath = (environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin")
        .split(separator: ":").map(String.init)
      for directory in searchPath where !directory.isEmpty {
        let candidate = (directory as NSString).appendingPathComponent(command)
        if FileManager.default.isExecutableFile(atPath: candidate) {
          return (URL(fileURLWithPath: candidate), Array(parts.dropFirst()))
        }
      }
      throw MaiRunToolError.interpreterNotFound(command)
    }

    static func run(
      executable: URL,
      arguments: [String],
      workingDirectory: URL,
      environment: [String: String],
      stdin: String?,
      timeout: TimeInterval,
      outputLimit: Int
    ) async throws -> MaiHostProcessOutcome {
      let session = ProcessSession(
        executable: executable,
        arguments: arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        hasInput: stdin != nil,
        outputLimit: outputLimit)
      try session.start()
      if let stdin { session.send(stdin) }
      let watchdog = Task {
        try await Task.sleep(for: .seconds(timeout))
        session.stop(timedOut: true)
      }
      defer { watchdog.cancel() }
      await withTaskCancellationHandler {
        await session.wait()
      } onCancel: {
        session.stop(timedOut: false)
      }
      try Task.checkCancellation()
      return session.outcome
    }

    /// Owns the non-Sendable `Process` and pipes; every mutation goes through `lock`.
    private final class ProcessSession: @unchecked Sendable {
      private let lock = NSLock()
      private let process = Process()
      private let stdoutPipe = Pipe()
      private let stderrPipe = Pipe()
      private let stdinPipe: Pipe?
      private let outputLimit: Int
      private let started = Date()
      private var stdout = Data()
      private var stderr = Data()
      private var stdoutDropped = 0
      private var stderrDropped = 0
      private var stdoutClosed = false
      private var stderrClosed = false
      private var exited = false
      private var finished = false
      private var timedOut = false
      private var stopping = false
      private var drainScheduled = false
      private var continuation: CheckedContinuation<Void, Never>?

      init(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        hasInput: Bool,
        outputLimit: Int
      ) {
        self.outputLimit = outputLimit
        stdinPipe = hasInput ? Pipe() : nil
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe ?? FileHandle.nullDevice
      }

      var outcome: MaiHostProcessOutcome {
        lock.withLock {
          MaiHostProcessOutcome(
            stdout: stdout,
            stderr: stderr,
            stdoutDropped: stdoutDropped,
            stderrDropped: stderrDropped,
            exitCode: exited ? process.terminationStatus : -1,
            timedOut: timedOut,
            duration: Date().timeIntervalSince(started))
        }
      }

      func start() throws {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
          self?.receive(handle.availableData, isStderr: false)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
          self?.receive(handle.availableData, isStderr: true)
        }
        process.terminationHandler = { [weak self] _ in self?.markExited() }
        try process.run()
      }

      func send(_ input: String) {
        guard let handle = stdinPipe?.fileHandleForWriting else { return }
        #if os(macOS)
          _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        #else
          signal(SIGPIPE, SIG_IGN)
        #endif
        DispatchQueue.global(qos: .utility).async {
          try? handle.write(contentsOf: Data(input.utf8))
          try? handle.close()
        }
      }

      func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          let resumeNow = lock.withLock {
            if finished { return true }
            self.continuation = continuation
            return false
          }
          if resumeNow { continuation.resume() }
        }
      }

      /// Sends SIGTERM, escalates to SIGKILL, and finally stops waiting on pipes
      /// that background grandchildren may still hold open.
      func stop(timedOut: Bool) {
        let shouldStop = lock.withLock {
          if timedOut { self.timedOut = true }
          guard !stopping, !finished else { return false }
          stopping = true
          return true
        }
        guard shouldStop else { return }
        if process.isRunning { process.terminate() }
        let grace = MaiHostProcess.terminationGrace
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) { [weak self] in
          guard let self else { return }
          if process.isRunning { kill(process.processIdentifier, SIGKILL) }
          DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.finish()
          }
        }
      }

      private func receive(_ data: Data, isStderr: Bool) {
        lock.withLock {
          if data.isEmpty {
            if isStderr {
              stderrClosed = true
              stderrPipe.fileHandleForReading.readabilityHandler = nil
            } else {
              stdoutClosed = true
              stdoutPipe.fileHandleForReading.readabilityHandler = nil
            }
            return
          }
          if isStderr {
            append(data, to: &stderr, dropped: &stderrDropped)
          } else {
            append(data, to: &stdout, dropped: &stdoutDropped)
          }
        }
        finishIfComplete()
      }

      private func append(_ data: Data, to buffer: inout Data, dropped: inout Int) {
        let room = outputLimit - buffer.count
        if room >= data.count {
          buffer.append(data)
        } else {
          if room > 0 { buffer.append(data.prefix(room)) }
          dropped += data.count - max(room, 0)
        }
      }

      private func markExited() {
        lock.withLock { exited = true }
        finishIfComplete()
      }

      private func finishIfComplete() {
        let action: (complete: Bool, scheduleDrain: Bool) = lock.withLock {
          guard exited, !finished else { return (false, false) }
          if stdoutClosed && stderrClosed { return (true, false) }
          guard !drainScheduled else { return (false, false) }
          drainScheduled = true
          return (false, true)
        }
        if action.complete {
          finish()
        } else if action.scheduleDrain {
          let grace = MaiHostProcess.terminationGrace
          DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) { [weak self] in
            self?.finish()
          }
        }
      }

      private func finish() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
          guard !finished else { return nil }
          finished = true
          stdoutPipe.fileHandleForReading.readabilityHandler = nil
          stderrPipe.fileHandleForReading.readabilityHandler = nil
          try? stdoutPipe.fileHandleForReading.close()
          try? stderrPipe.fileHandleForReading.close()
          defer { self.continuation = nil }
          return self.continuation
        }
        continuation?.resume()
      }
    }
  }
#endif
