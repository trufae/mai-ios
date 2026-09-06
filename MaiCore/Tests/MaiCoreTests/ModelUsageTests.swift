import Foundation
import Testing

@testable import MaiCore

private let start = Date(timeIntervalSince1970: 1_000)

@Test("Streamed timing splits prompt wait from generation")
func streamedTimingSplitsPromptAndGeneration() {
  var observation = StreamTimingObservation(requestStart: start)
  observation.noteTokenChunk(at: start.addingTimeInterval(0.8))
  observation.noteTokenChunk(at: start.addingTimeInterval(2.0))
  observation.noteTokenChunk(at: start.addingTimeInterval(4.5))
  observation.noteTokenChunk(at: start.addingTimeInterval(6.8))

  let resolved = ModelCallStats.resolveTiming(observation, end: start.addingTimeInterval(7.1))

  #expect(abs((resolved.firstTokenSeconds ?? -1) - 0.8) < 0.0001)
  #expect(abs(resolved.promptSeconds - 0.8) < 0.0001)
  // First→last token window; the trailing usage/[DONE] wait is excluded.
  #expect(abs(resolved.generationSeconds - 6.0) < 0.0001)
}

@Test("Burst delivery falls back to total wall time")
func burstDeliveryFallsBackToTotalWallTime() {
  var observation = StreamTimingObservation(requestStart: start)
  observation.noteTokenChunk(at: start.addingTimeInterval(9.98))
  observation.noteTokenChunk(at: start.addingTimeInterval(9.99))

  let resolved = ModelCallStats.resolveTiming(observation, end: start.addingTimeInterval(10.0))

  #expect(resolved.promptSeconds == 0)
  #expect(abs(resolved.generationSeconds - 10.0) < 0.0001)
  #expect(abs((resolved.firstTokenSeconds ?? -1) - 9.98) < 0.0001)

  var burst = StreamTimingObservation(requestStart: start)
  for offset in stride(from: 5.00, through: 5.10, by: 0.01) {
    burst.noteTokenChunk(at: start.addingTimeInterval(offset))
  }
  let short = ModelCallStats.resolveTiming(burst, end: start.addingTimeInterval(5.2))
  #expect(short.promptSeconds == 0)
  #expect(abs(short.generationSeconds - 5.2) < 0.0001)

  let unstreamed = ModelCallStats.resolveTiming(
    StreamTimingObservation(requestStart: start), end: start.addingTimeInterval(3.0))
  #expect(unstreamed.firstTokenSeconds == nil)
  #expect(unstreamed.promptSeconds == 0)
  #expect(abs(unstreamed.generationSeconds - 3.0) < 0.0001)
}

@Test("The recorder counts generated events, not usage payloads")
func recorderCountsGeneratedEvents() {
  let recorder = StreamTimingRecorder(requestStart: start)
  recorder.note(.usage(TokenUsage(inputTokens: 1, outputTokens: 1)), at: start)
  #expect(recorder.observation.firstTokenAt == nil)
  recorder.note(.textDelta("a"), at: start.addingTimeInterval(1))
  recorder.note(.reasoningDelta("b"), at: start.addingTimeInterval(2))
  recorder.note(
    .toolCallDelta(ToolCallDelta(index: 0, id: "1", name: "echo", argumentsFragment: "{")),
    at: start.addingTimeInterval(3))
  let observation = recorder.observation
  #expect(observation.tokenChunkCount == 3)
  #expect(observation.firstTokenAt == start.addingTimeInterval(1))
  #expect(observation.lastTokenAt == start.addingTimeInterval(3))
}

@Test("Speed uses visible output tokens and needs a duration")
func speedExcludesReasoningAndNeedsDuration() {
  let stats = ModelCallStats(
    providerLabel: "p", modelID: "m", outputTokens: 300, reasoningTokens: 100,
    generationSeconds: 10)
  #expect(abs((stats.tokensPerSecond ?? -1) - 20.0) < 0.0001)
  #expect(
    ModelCallStats(providerLabel: "p", modelID: "m", outputTokens: 300).tokensPerSecond == nil)

  var observation = StreamTimingObservation(requestStart: start)
  observation.noteTokenChunk(at: start.addingTimeInterval(9.95))
  observation.noteTokenChunk(at: start.addingTimeInterval(10.0))
  let resolved = ModelCallStats.resolveTiming(observation, end: start.addingTimeInterval(10.0))
  let burst = ModelCallStats(
    providerLabel: "Ollama", modelID: "llama3", inputTokens: 100, outputTokens: 500,
    promptSeconds: resolved.promptSeconds, generationSeconds: resolved.generationSeconds,
    firstTokenSeconds: resolved.firstTokenSeconds)
  // 500 tokens over 10s delivered at once reads as ~50 tok/s, never tokens
  // divided by the burst window.
  #expect(abs((burst.tokensPerSecond ?? -1) - 50.0) < 0.01)
}

@Test("Merging keeps the first round's first-token latency")
func mergeKeepsEarliestFirstToken() {
  var first = ModelCallStats(
    providerLabel: "p", modelID: "m", outputTokens: 10, firstTokenSeconds: 0.9)
  let second = ModelCallStats(
    providerLabel: "p", modelID: "m", outputTokens: 20, firstTokenSeconds: 0.2)
  first.merge(second)
  #expect(abs((first.firstTokenSeconds ?? -1) - 0.9) < 0.0001)
  #expect(first.outputTokens == 30)
  #expect(first.callCount == 2)

  var missing = ModelCallStats(providerLabel: "p", modelID: "m", outputTokens: 5)
  missing.merge(second)
  #expect(abs((missing.firstTokenSeconds ?? -1) - 0.2) < 0.0001)
}

@Test("Measured stats estimate what the provider did not report")
func measuredStatsEstimateMissingCounts() {
  let messages: [AgentMessage] = [
    .system("Be brief."),
    AgentMessage(
      role: .user,
      content: [
        .text(String(repeating: "x", count: 40)),
        .image(ImageContent(source: .data(Data([1, 2, 3])), mimeType: "image/png")),
      ]),
  ]
  var observation = StreamTimingObservation(requestStart: start)
  observation.noteTokenChunk(at: start.addingTimeInterval(1))
  observation.noteTokenChunk(at: start.addingTimeInterval(2))
  observation.noteTokenChunk(at: start.addingTimeInterval(3))
  let estimated = ModelCallStats.measured(
    providerLabel: "hello",
    modelID: "",
    messages: messages,
    response: ProviderResponse(message: .assistant(String(repeating: "y", count: 80))),
    timing: observation,
    end: start.addingTimeInterval(3.5),
    userInputTokens: 10)
  #expect(estimated.tokensEstimated)
  #expect(estimated.inputTokens == 12)
  #expect(estimated.outputTokens == 20)
  #expect(estimated.receivedTextTokens == 20)
  #expect(estimated.imageInputs == 1)
  #expect(estimated.userInputTokens == 10)
  #expect(abs(estimated.promptSeconds - 1) < 0.0001)
  #expect(abs(estimated.generationSeconds - 2) < 0.0001)

  let reported = ModelCallStats.measured(
    providerLabel: "thor",
    modelID: "qwen",
    messages: [.user("hi")],
    response: ProviderResponse(
      message: .assistant("hello"),
      usage: TokenUsage(
        inputTokens: 30, outputTokens: 12, cachedTokens: 5, reasoningTokens: 4)),
    timing: StreamTimingObservation(requestStart: start),
    end: start.addingTimeInterval(2))
  #expect(!reported.tokensEstimated)
  #expect(reported.inputTokens == 30)
  #expect(reported.outputTokens == 12)
  #expect(reported.reasoningTokens == 4)
  #expect(reported.cachedTokens == 5)
  #expect(reported.imageInputs == nil)
  #expect(reported.firstTokenSeconds == nil)
}

@Test("The ledger folds calls into provider:model rows")
func ledgerAccumulatesRows() {
  var ledger = ModelUsageLedger()
  #expect(ledger.record(ModelCallStats(providerLabel: "p", modelID: "m")) == nil)
  ledger.record(
    ModelCallStats(
      providerLabel: "thor", modelID: "qwen", inputTokens: 100, outputTokens: 200,
      promptSeconds: 1, generationSeconds: 10, firstTokenSeconds: 1),
    at: start)
  ledger.record(
    ModelCallStats(
      providerLabel: "thor", modelID: "qwen", inputTokens: 50, outputTokens: 100,
      promptSeconds: 2, generationSeconds: 5, firstTokenSeconds: 2, tokensEstimated: true),
    at: start.addingTimeInterval(60))
  ledger.record(
    ModelCallStats(
      providerLabel: "openai", modelID: "big", inputTokens: 10, outputTokens: 30,
      generationSeconds: 3),
    at: start.addingTimeInterval(30))

  #expect(ledger.totals.count == 2)
  let qwen = try! #require(ledger.totals(id: "thor|qwen"))
  #expect(qwen.callCount == 2)
  #expect(qwen.estimatedCallCount == 1)
  #expect(qwen.inputTokens == 150)
  #expect(qwen.outputTokens == 300)
  #expect(abs(qwen.totalSeconds - 18) < 0.0001)
  #expect(abs((qwen.averageTokensPerSecond ?? 0) - 20) < 0.0001)
  #expect(abs((qwen.lastOutputTokensPerSecond ?? 0) - 20) < 0.0001)
  #expect(abs((qwen.averageFirstTokenSeconds ?? 0) - 1.5) < 0.0001)
  #expect(qwen.lastUsedAt == start.addingTimeInterval(60))
  #expect(qwen.title == "thor — qwen")

  #expect(ledger.sortedBySpeed.map(\.id) == ["thor|qwen", "openai|big"])
  #expect(ledger.sortedByLastUsed.map(\.id) == ["thor|qwen", "openai|big"])
  #expect(ledger.callCount == 3)
  #expect(abs(ledger.totalSeconds - 21) < 0.0001)
  let providers = ledger.providerTotals
  #expect(providers.map(\.providerLabel) == ["openai", "thor"])
  #expect(providers[1].modelCount == 1)
  #expect(providers[1].callCount == 2)

  #expect(ledger.remove(id: "nope") == false)
  #expect(ledger.remove(providerLabel: "thor") == 1)
  #expect(ledger.totals.map(\.id) == ["openai|big"])
  ledger.reset()
  #expect(ledger.isEmpty)
}

@Test("Ledgers decode PocketMai's earlier numeric-date rows and round-trip")
func ledgerPersistenceFormats() throws {
  let legacy = """
    [{"providerLabel":"Ollama","modelID":"llama3","inputTokens":10,
     "outputTokens":20,"cachedTokens":0,"promptSeconds":1,
     "generationSeconds":2,"callCount":1,"estimatedCallCount":0,
     "lastUsedAt":0}]
    """
  let decoded = try ModelUsageLedger.decode(Data(legacy.utf8))
  let row = try #require(decoded.totals.first)
  #expect(row.lastFirstTokenSeconds == nil)
  #expect(row.averageFirstTokenSeconds == nil)
  #expect(row.outputTokens == 20)
  #expect(row.lastUsedAt == Date(timeIntervalSinceReferenceDate: 0))

  let plain = try JSONDecoder().decode(
    ModelUsageTotals.self, from: Data(legacy.dropFirst().dropLast().utf8))
  #expect(plain.outputTokens == 20)

  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "pmai-stats-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("stats.json")
  try decoded.save(to: url)
  let reloaded = try ModelUsageLedger.load(from: url)
  #expect(reloaded == decoded)
  let text = try String(contentsOf: url, encoding: .utf8)
  #expect(text.hasPrefix("["))
  #expect(text.contains("\"lastUsedAt\" : \"2001-01-01T00:00:00.000Z\""))
  #expect(try ModelUsageLedger.load(from: directory.appendingPathComponent("none.json")).isEmpty)
}

@Test("The store persists every change and reopens from its file")
func storePersistsAndReloads() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "pmai-stats-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("stats.json")
  let store = ModelUsageStore(url: url)
  #expect(await store.location == url)
  let recorded = await store.record(
    ModelCallStats(
      providerLabel: "thor", modelID: "qwen", inputTokens: 5, outputTokens: 10,
      generationSeconds: 1))
  #expect(recorded?.callCount == 1)
  #expect(FileManager.default.fileExists(atPath: url.path))

  let reopened = ModelUsageStore(url: url)
  #expect(await reopened.totals().map(\.id) == ["thor|qwen"])
  #expect(await reopened.remove(id: "thor|qwen"))
  #expect(await ModelUsageStore(url: url).totals().isEmpty)
  #expect(await store.lastPersistenceError == nil)
}

@Test("The runtime records every provider call into its usage store")
func runtimeRecordsProviderCalls() async throws {
  let runtime = AgentRuntime()
  try await runtime.register(HelloProvider())
  let store = ModelUsageStore()
  await runtime.configureUsageStats(store)
  #expect(await runtime.usageStatsStore() != nil)

  let result = try await runtime.run(
    AgentRequest(provider: .hello, model: "hello", messages: [.user("ping pong")])
  ) { _ in }
  #expect(result.response.text == "Hello from MaiCore: ping pong")

  let totals = await store.totals()
  let row = try #require(totals.first)
  #expect(totals.count == 1)
  #expect(row.providerLabel == "hello")
  #expect(row.modelID == "hello")
  #expect(row.callCount == 1)
  #expect(row.estimatedCallCount == 1)
  #expect(row.userInputTokens == ModelCallStats.estimatedTokenCount(forCharacterCount: 9))
  #expect(row.outputTokens > 0)
  #expect(row.totalSeconds >= 0)

  await runtime.configureUsageStats(nil)
  _ = try await runtime.run(AgentRequest(provider: .hello, messages: [.user("again")])) { _ in }
  #expect(await store.totals().first?.callCount == 1)
}

@Test("Reports rank rows by speed and render aligned bars")
func reportRanksAndRenders() {
  var ledger = ModelUsageLedger()
  ledger.record(
    ModelCallStats(
      providerLabel: "thor", modelID: "qwen3.8:27b", inputTokens: 1_000, outputTokens: 4_000,
      promptSeconds: 4, generationSeconds: 100),
    at: start)
  ledger.record(
    ModelCallStats(
      providerLabel: "openai", modelID: "big-pickle", inputTokens: 500, outputTokens: 400,
      generationSeconds: 20, tokensEstimated: true),
    at: start)
  ledger.record(
    ModelCallStats(providerLabel: "hello", modelID: "hello", inputTokens: 3, outputTokens: 0),
    at: start)

  let report = ModelUsageReport(ledger)
  #expect(report.rows.map(\.id) == ["thor|qwen3.8:27b", "openai|big-pickle", "hello|hello"])
  #expect(report.rows[0].speedFraction == 1)
  #expect(abs(report.rows[1].speedFraction - 0.5) < 0.0001)
  #expect(report.rows[2].speed == nil)
  #expect(report.rows[0].secondsFraction == 1)
  #expect(report.rows(for: .time).map(\.id).first == "thor|qwen3.8:27b")
  #expect(report.rows[0].color == ModelUsagePalette.color(forProviderLabel: "thor"))
  #expect(report.headline.contains("3 models"))
  #expect(report.headline.contains("3 requests"))
  #expect(report.headline.contains("2m4s in use"))
  #expect(report.headline.contains("~5.9k tokens"))
  #expect(report.rows[1].detail(.speed) == "20s · 1 req · ~900 tok")
  #expect(report.rows[0].value(.time) == "1m44s")

  var painted: [ModelUsageColor] = []
  let lines = report.lines(width: 100) { bar, color in
    painted.append(color)
    return "<\(bar)>"
  }
  #expect(lines.first == "Model usage: \(report.headline)")
  #expect(lines.contains("Average output speed"))
  #expect(lines.contains("Time in use"))
  #expect(lines.contains { $0.contains("thor — qwen3.8:27b") && $0.contains("40.0 tok/s") })
  #expect(lines.contains { $0.contains("openai — big-pickle") && $0.contains("20.0 tok/s") })
  #expect(lines.contains { $0.contains("hello") && $0.contains("no speed") })
  #expect(lines.last?.hasPrefix("~ marks") == true)
  #expect(painted.count == 6)
  let speedBars = lines.filter { $0.contains("<") }.prefix(3).map {
    $0.split(separator: "<")[1].split(separator: ">")[0]
  }
  #expect(Set(speedBars.map(\.count)).count == 1)
  #expect(speedBars[0].allSatisfy { $0 == "█" })
  #expect(speedBars[2].allSatisfy { $0 == " " })

  #expect(ModelUsageReport(ModelUsageLedger()).lines() == [ModelUsageReport.emptyMessage])
}

@Test("Formats and the palette are stable")
func formatsAndPalette() {
  #expect(ModelUsageFormat.duration(0) == "<1s")
  #expect(ModelUsageFormat.duration(0.4) == "<1s")
  #expect(ModelUsageFormat.duration(5) == "5s")
  #expect(ModelUsageFormat.duration(64) == "1m4s")
  #expect(ModelUsageFormat.duration(7_384) == "2h3m4s")
  #expect(ModelUsageFormat.speed(42.06) == "42.1 tok/s")
  #expect(ModelUsageFormat.seconds(0.854) == "0.85s")
  #expect(ModelUsageFormat.seconds(12.34) == "12.3s")
  #expect(ModelUsageFormat.count(950) == "950")
  #expect(ModelUsageFormat.count(1_234) == "1.2k")
  #expect(ModelUsageFormat.count(552_185) == "552.2k")
  #expect(ModelUsageFormat.count(999_949) == "999.9k")
  #expect(ModelUsageFormat.count(999_950) == "1.0M")
  #expect(ModelUsageFormat.count(3_450_000) == "3.5M")
  #expect(ModelUsageFormat.tokens(552_185) == "552.2k tok")
  #expect(ModelUsageFormat.tokens(12_040, estimated: true) == "~12.0k tok")
  #expect(AgentProcessInfo.compactCount(1_500_000) == "1.5M")
  #expect(ModelUsageFormat.bar(fraction: 1, width: 4) == "████")
  #expect(ModelUsageFormat.bar(fraction: 0.5, width: 4) == "██  ")
  #expect(ModelUsageFormat.bar(fraction: 0.625, width: 4) == "██▌ ")
  #expect(ModelUsageFormat.bar(fraction: 0.5625, width: 4) == "██▎ ")
  #expect(ModelUsageFormat.bar(fraction: 0, width: 3) == "   ")
  #expect(ModelUsageFormat.bar(fraction: 2, width: 2) == "██")

  let thor = ModelUsagePalette.color(forProviderLabel: "thor")
  #expect(thor == ModelUsagePalette.color(forProviderLabel: "thor"))
  #expect(thor != ModelUsagePalette.color(forProviderLabel: "openai"))
  #expect(thor.hex.count == 7)
  #expect(thor.hex.hasPrefix("#"))
  let hue = ModelUsagePalette.hue(forProviderLabel: "thor")
  #expect(hue >= 0 && hue < 1)
  let red = ModelUsagePalette.color(hue: 0, saturation: 1, brightness: 1)
  #expect(red == ModelUsageColor(red: 1, green: 0, blue: 0))
  #expect(red.hex == "#ff0000")
  let cyan = ModelUsagePalette.color(hue: 0.5, saturation: 1, brightness: 1)
  #expect(cyan.hex == "#00ffff")
}

@Test("Process summaries say how long a run has been going")
func processSummaryShowsElapsedTime() {
  var info = AgentProcessInfo(
    pid: AgentPID(3),
    runID: UUID(),
    agentID: "coder",
    state: .running,
    startedAt: start,
    modelTurns: 2,
    activity: "thinking")
  #expect(
    info.summaryLine(at: start.addingTimeInterval(64))
      == "#3 coder  [run]  2 turns · 1m4s — thinking")

  info.runStartedAt = start.addingTimeInterval(100)
  info.finishedAt = start.addingTimeInterval(105)
  info.state = .completed
  info.activity = ""
  #expect(info.summaryLine(at: start.addingTimeInterval(1_000)).hasSuffix("2 turns · 5s"))

  let starting = AgentProcessInfo(pid: AgentPID(4), runID: UUID(), agentID: "new")
  #expect(starting.summaryLine == "#4 new  [start]")
}
