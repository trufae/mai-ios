import AVFoundation
import CoreMedia
import Foundation
import Speech

enum LiveVoiceState: Equatable {
  case idle
  case requestingPermission
  case listening
  case paused
  case thinking
  case speaking
  case error(String)

  var statusText: String {
    switch self {
    case .idle:
      return "Voice off"
    case .requestingPermission:
      return "Requesting access"
    case .listening:
      return "Listening"
    case .paused:
      return "Paused"
    case .thinking:
      return "Thinking"
    case .speaking:
      return "Speaking"
    case .error:
      return "Voice error"
    }
  }
}

struct LiveSpeechRecognitionEvent: Sendable {
  var text: String
  var isFinal: Bool
  var languageIdentifier: String
}

@MainActor
protocol LiveSpeechRecognitionEngine: AnyObject {
  var onTranscript: ((LiveSpeechRecognitionEvent) -> Void)? { get set }
  var languageIdentifier: String { get }
  var recordingFilename: String? { get }

  func start() async throws
  func finalize() async throws -> LiveSpeechRecognitionEvent?
  func stop()
}

private enum LiveSpeechRecognitionError: LocalizedError {
  case microphoneDenied
  case speechRecognitionDenied
  case recognizerUnavailable(String)
  case audioInputUnavailable
  case speechTranscriberUnavailable(String)
  case speechTranscriberAssetsUnavailable(String)

  var errorDescription: String? {
    switch self {
    case .microphoneDenied:
      return "Microphone access is required for voice conversation."
    case .speechRecognitionDenied:
      return "Speech recognition access is required for voice conversation."
    case .recognizerUnavailable(let language):
      return "Speech recognition is not available for \(language)."
    case .audioInputUnavailable:
      return "No microphone input is available."
    case .speechTranscriberUnavailable(let language):
      return
        "Native live transcription is not available for \(language). Select Native iOS File or choose another language."
    case .speechTranscriberAssetsUnavailable(let language):
      return
        "Native live transcription assets are not available for \(language). Select Native iOS File or choose another language."
    }
  }
}

private enum LiveSpeechPermissionRequester {
  static func requestMicrophonePermission() async -> Bool {
    await withCheckedContinuation { continuation in
      if #available(iOS 17.0, *) {
        AVAudioApplication.requestRecordPermission { granted in
          continuation.resume(returning: granted)
        }
      } else {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
          continuation.resume(returning: granted)
        }
      }
    }
  }

  static func requestSpeechRecognitionPermission() async -> SFSpeechRecognizerAuthorizationStatus {
    await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status)
      }
    }
  }
}

@MainActor
final class LiveVoiceSession: ObservableObject {
  @Published private(set) var state: LiveVoiceState = .idle
  @Published private(set) var transcript: String = ""
  @Published private(set) var languageIdentifier: String = Locale.current.identifier
  @Published private(set) var errorMessage: String?

  private weak var store: AppStore?
  private weak var ttsPlayer: TTSPlayer?
  private var engine: LiveSpeechRecognitionEngine?
  private var activityTask: Task<Void, Never>?
  private var silenceTask: Task<Void, Never>?
  private var sessionGeneration = 0
  private var recognitionGeneration = 0
  private var isCommittingTurn = false
  private(set) var previewMessageID = UUID()

  var isActive: Bool {
    switch state {
    case .idle:
      return false
    default:
      return true
    }
  }

  var primaryControlSystemImage: String {
    switch state {
    case .requestingPermission:
      return "hourglass.circle"
    case .listening:
      return "pause.circle.fill"
    default:
      return "record.circle"
    }
  }

  var primaryControlHelp: String {
    switch state {
    case .listening:
      return "Pause and send"
    case .requestingPermission:
      return "Requesting access"
    default:
      return "Record"
    }
  }

  var previewMessage: ChatMessage? {
    let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard isActive else { return nil }
    if !text.isEmpty {
      return ChatMessage(id: previewMessageID, role: .user, text: text)
    }
    switch state {
    case .requestingPermission, .listening:
      return ChatMessage(id: previewMessageID, role: .user, text: "")
    default:
      return nil
    }
  }

  func start(store: AppStore, ttsPlayer: TTSPlayer) {
    configure(store: store, ttsPlayer: ttsPlayer)
    ttsPlayer.stop()
    beginListening(resetTranscript: true)
  }

  func togglePauseOrRecord(store: AppStore, ttsPlayer: TTSPlayer) {
    configure(store: store, ttsPlayer: ttsPlayer)
    switch state {
    case .listening:
      commitCurrentTurn()
    case .requestingPermission:
      break
    default:
      interruptAssistantIfNeeded()
      beginListening(resetTranscript: true)
    }
  }

  private func beginListening(resetTranscript: Bool) {
    guard let store else { return }
    sessionGeneration += 1
    let generation = sessionGeneration
    if resetTranscript {
      previewMessageID = UUID()
      transcript = ""
    }
    errorMessage = nil
    languageIdentifier = Self.configuredLanguageIdentifier(from: store.settings)
    isCommittingTurn = false
    activityTask?.cancel()
    activityTask = Task { @MainActor [weak self] in
      _ = await self?.beginRecognition(
        displayState: .listening,
        resetTranscript: resetTranscript,
        generation: generation)
    }
  }

  private static func configuredLanguageIdentifier(from settings: AppSettings) -> String {
    let identifier = settings.conversation.speechRecognitionLanguageIdentifier
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return identifier.isEmpty ? Locale.current.identifier : identifier
  }

  func stop(cancelResponse: Bool) {
    sessionGeneration += 1
    activityTask?.cancel()
    activityTask = nil
    silenceTask?.cancel()
    silenceTask = nil
    stopRecognition()
    if cancelResponse, let conversationID = store?.currentConversation?.id {
      store?.cancelResponse(in: conversationID)
    }
    ttsPlayer?.stop()
    state = .idle
    transcript = ""
    errorMessage = nil
    isCommittingTurn = false
    previewMessageID = UUID()
  }

  func stopForDraft(cancelResponse: Bool) async -> String {
    sessionGeneration += 1
    activityTask?.cancel()
    activityTask = nil
    silenceTask?.cancel()
    silenceTask = nil

    let draft = await finalizedDraftTranscript()
    stopRecognition()
    if cancelResponse, let conversationID = store?.currentConversation?.id {
      store?.cancelResponse(in: conversationID)
    }
    ttsPlayer?.stop()
    state = .idle
    transcript = ""
    errorMessage = nil
    isCommittingTurn = false
    previewMessageID = UUID()
    return draft
  }

  private func configure(store: AppStore, ttsPlayer: TTSPlayer) {
    self.store = store
    self.ttsPlayer = ttsPlayer
  }

  private func finalizedDraftTranscript() async -> String {
    var draft = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let engine else { return draft }

    recognitionGeneration += 1
    engine.onTranscript = nil
    do {
      if let event = try await engine.finalize() {
        languageIdentifier = event.languageIdentifier
        let finalized = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalized.isEmpty {
          draft = finalized
        }
      }
    } catch {
      // Keep the best partial transcript already visible in the UI.
    }
    return draft
  }

  @discardableResult
  private func beginRecognition(
    displayState: LiveVoiceState,
    resetTranscript: Bool,
    generation: Int
  ) async -> Bool {
    guard generation == sessionGeneration, let store else { return false }
    silenceTask?.cancel()
    stopRecognition()
    if resetTranscript {
      previewMessageID = UUID()
      transcript = ""
    }
    state = .requestingPermission
    errorMessage = nil
    languageIdentifier = Self.configuredLanguageIdentifier(from: store.settings)

    do {
      let engine = try makeSpeechRecognitionEngine(settings: store.settings)
      recognitionGeneration += 1
      let engineGeneration = recognitionGeneration
      engine.onTranscript = { [weak self] event in
        Task { @MainActor in
          guard let self, engineGeneration == self.recognitionGeneration else { return }
          self.handleTranscript(event)
        }
      }
      self.engine = engine
      try await engine.start()
      guard generation == sessionGeneration else {
        stopRecognition()
        return false
      }
      languageIdentifier = engine.languageIdentifier
      state = displayState
      return true
    } catch {
      guard generation == sessionGeneration else { return false }
      let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      errorMessage = text
      state = .error(text)
      stopRecognition()
      return false
    }
  }

  private func makeSpeechRecognitionEngine(settings: AppSettings) throws
    -> LiveSpeechRecognitionEngine
  {
    switch settings.conversation.speechRecognitionBackend {
    case .nativeIOSSpeechTranscriber:
      return NativeIOSSpeechTranscriberRecognitionEngine(
        localeIdentifier: settings.conversation.speechRecognitionLanguageIdentifier)
    case .nativeIOS:
      return NativeIOSSpeechRecognitionEngine(
        localeIdentifier: settings.conversation.speechRecognitionLanguageIdentifier,
        silenceTimeoutSeconds: settings.conversation.silenceTimeoutSeconds)
    }
  }

  private func stopRecognition(keepingRecording: Bool = false) {
    let recordingFilename = engine?.recordingFilename
    recognitionGeneration += 1
    engine?.onTranscript = nil
    engine?.stop()
    engine = nil
    if !keepingRecording,
      let recordingFilename,
      let url = PocketMaiDirectories.voiceRecordingURL(filename: recordingFilename)
    {
      try? FileManager.default.removeItem(at: url)
    }
  }

  private func handleTranscript(_ event: LiveSpeechRecognitionEvent) {
    languageIdentifier = event.languageIdentifier
    let normalized = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return }

    if transcript != normalized {
      transcript = normalized
    }

    if event.isFinal {
      commitCurrentTurn()
      return
    }

    scheduleSilenceCommit(for: normalized)
  }

  private func scheduleSilenceCommit(for scheduledTranscript: String) {
    guard !isCommittingTurn else { return }
    guard let timeout = store?.settings.conversation.silenceTimeoutSeconds else { return }
    let clampedTimeout = ConversationSettings.clampedSilenceTimeout(timeout)
    let generation = sessionGeneration
    silenceTask?.cancel()
    silenceTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(Int(clampedTimeout * 1000)))
      } catch {
        return
      }
      guard let self,
        generation == self.sessionGeneration,
        self.transcript.trimmingCharacters(in: .whitespacesAndNewlines) == scheduledTranscript
      else {
        return
      }
      self.commitCurrentTurn()
    }
  }

  private func commitCurrentTurn() {
    guard isActive, !isCommittingTurn else { return }
    silenceTask?.cancel()
    silenceTask = nil
    let generation = sessionGeneration
    state = .thinking
    isCommittingTurn = true

    activityTask?.cancel()
    activityTask = Task { @MainActor [weak self] in
      await self?.finalizeAndSubmitCurrentTurn(generation: generation)
    }
  }

  private func finalizeAndSubmitCurrentTurn(generation: Int) async {
    guard generation == sessionGeneration else {
      isCommittingTurn = false
      return
    }

    var finalTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    if finalTranscript.isEmpty {
      do {
        if let event = try await engine?.finalize() {
          languageIdentifier = event.languageIdentifier
          finalTranscript = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
          transcript = finalTranscript
        }
      } catch {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        errorMessage = text
        state = .error(text)
        stopRecognition()
        isCommittingTurn = false
        return
      }
    }

    guard !finalTranscript.isEmpty else {
      stopRecognition()
      state = .paused
      isCommittingTurn = false
      return
    }

    let prompt = promptText(transcript: finalTranscript, language: languageIdentifier)
    let recordingFilename = engine?.recordingFilename
    stopRecognition(keepingRecording: true)
    state = .thinking
    await sendAndSpeak(
      prompt: prompt,
      voiceRecordingFilename: recordingFilename,
      visibleTranscript: finalTranscript,
      generation: generation)
  }

  private func sendAndSpeak(
    prompt: String,
    voiceRecordingFilename: String?,
    visibleTranscript: String,
    generation: Int
  ) async {
    guard let store, let ttsPlayer else { return }
    let conversationIDBeforeSend = store.currentConversation?.id
    let sent = await store.send(prompt: prompt, voiceRecordingFilename: voiceRecordingFilename)
    guard generation == sessionGeneration else { return }

    if !sent {
      if let voiceRecordingFilename,
        let url = PocketMaiDirectories.voiceRecordingURL(filename: voiceRecordingFilename)
      {
        try? FileManager.default.removeItem(at: url)
      }
      errorMessage = store.errorMessage ?? "The voice message could not be sent."
      transcript = visibleTranscript
      state = .paused
      isCommittingTurn = false
      return
    }

    transcript = ""
    previewMessageID = UUID()
    let conversationID = store.currentConversation?.id ?? conversationIDBeforeSend
    if let conversationID {
      await waitForAssistantResponse(in: conversationID, generation: generation)
    }
    guard generation == sessionGeneration else { return }

    isCommittingTurn = false
    guard let assistant = latestSpeakableAssistantMessage() else {
      _ = await beginRecognition(
        displayState: .listening,
        resetTranscript: true,
        generation: generation)
      return
    }

    stopRecognition()
    transcript = ""
    previewMessageID = UUID()
    state = .speaking
    ttsPlayer.speak(
      text: assistant.text,
      voice: store.settings.toolSettings.voices.assistant,
      role: .assistant,
      title: "Assistant",
      messageID: assistant.id,
      openAIEndpoints: store.settings.openAIEndpoints)
    await waitForSpeechToFinish(ttsPlayer, generation: generation)
    guard generation == sessionGeneration else { return }
    _ = await beginRecognition(
      displayState: .listening,
      resetTranscript: true,
      generation: generation)
  }

  private func waitForAssistantResponse(in conversationID: UUID, generation: Int) async {
    while generation == sessionGeneration, !Task.isCancelled {
      guard store?.isResponding(in: conversationID) == true else { return }
      try? await Task.sleep(for: .milliseconds(150))
    }
  }

  private func waitForSpeechToFinish(_ ttsPlayer: TTSPlayer, generation: Int) async {
    while generation == sessionGeneration, !Task.isCancelled {
      guard ttsPlayer.isSpeaking else { return }
      try? await Task.sleep(for: .milliseconds(150))
    }
  }

  private func latestSpeakableAssistantMessage() -> ChatMessage? {
    guard
      let message = store?.currentConversation?.messages.reversed().first(where: {
        $0.role == .assistant
      })
    else {
      return nil
    }
    let visible = MessageContentFilter.render(message.text).visibleText
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !visible.isEmpty, visible != "[stopped]" else { return nil }
    return ChatMessage(
      id: message.id,
      role: message.role,
      text: visible,
      createdAt: message.createdAt)
  }

  private func interruptAssistantIfNeeded() {
    if ttsPlayer?.isSpeaking == true {
      ttsPlayer?.stop()
    }
    if let conversationID = store?.currentConversation?.id,
      store?.isResponding(in: conversationID) == true
    {
      store?.cancelResponse(in: conversationID)
    }
  }

  private func promptText(transcript: String, language: String) -> String {
    let languageLine = language.trimmingCharacters(in: .whitespacesAndNewlines)
    let metadata =
      languageLine.isEmpty
      ? "Input mode: voice"
      : "Input mode: voice\nSpoken language: \(languageLine)"
    return """
      <speech>
      \(metadata)
      </speech>

      \(transcript)
      """
  }
}

@MainActor
private final class NativeIOSSpeechTranscriberRecognitionEngine: LiveSpeechRecognitionEngine {
  var onTranscript: ((LiveSpeechRecognitionEvent) -> Void)?
  private(set) var languageIdentifier: String
  private(set) var recordingFilename: String?

  private let requestedLocale: Locale
  private var transcriber: SpeechTranscriber?
  private var analyzer: SpeechAnalyzer?
  private var audioEngine: AVAudioEngine?
  private var audioSink: NativeSpeechTranscriberAudioSink?
  private var analysisTask: Task<Void, Never>?
  private var resultsTask: Task<Void, Never>?
  private var audioSessionActivated = false
  private var latestTranscript = ""
  private var transcriptSegments: [NativeSpeechTranscriberSegment] = []

  init(localeIdentifier: String) {
    let identifier = localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    requestedLocale = identifier.isEmpty ? Locale.current : Locale(identifier: identifier)
    languageIdentifier = identifier.isEmpty ? Locale.current.identifier : identifier
  }

  func start() async throws {
    let microphoneGranted = await LiveSpeechPermissionRequester.requestMicrophonePermission()
    guard microphoneGranted else { throw LiveSpeechRecognitionError.microphoneDenied }

    guard SpeechTranscriber.isAvailable else {
      throw LiveSpeechRecognitionError.speechTranscriberUnavailable(requestedLocale.identifier)
    }
    guard
      let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale)
    else {
      throw LiveSpeechRecognitionError.speechTranscriberUnavailable(requestedLocale.identifier)
    }

    languageIdentifier = supportedLocale.identifier
    let transcriber = SpeechTranscriber(
      locale: supportedLocale,
      transcriptionOptions: [],
      reportingOptions: [.volatileResults, .fastResults],
      attributeOptions: [.audioTimeRange])
    try await ensureAssetsAvailable(for: transcriber, locale: supportedLocale)

    try activateAudioSession()
    let audioEngine = AVAudioEngine()
    let inputNode = audioEngine.inputNode
    let inputFormat = inputNode.outputFormat(forBus: 0)
    guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
      throw LiveSpeechRecognitionError.audioInputUnavailable
    }
    let analysisFormat =
      await SpeechAnalyzer.bestAvailableAudioFormat(
        compatibleWith: [transcriber],
        considering: inputFormat)
      ?? NativeSpeechTranscriberAudioSink.preferredAnalysisFormat(matching: inputFormat)

    let recordingFile = try makeRecordingFile(format: inputFormat)
    let (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    let audioSink = NativeSpeechTranscriberAudioSink(
      continuation: continuation,
      analysisFormat: analysisFormat,
      recordingFile: recordingFile)
    let analyzer = SpeechAnalyzer(
      modules: [transcriber],
      options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse))
    try await analyzer.prepareToAnalyze(in: analysisFormat)

    self.transcriber = transcriber
    self.analyzer = analyzer
    self.audioEngine = audioEngine
    self.audioSink = audioSink

    resultsTask = Task { @MainActor [weak self, transcriber] in
      do {
        for try await result in transcriber.results {
          guard let self else { return }
          self.receiveTranscriberResult(result)
        }
      } catch {
        guard !Task.isCancelled else { return }
      }
    }

    analysisTask = Task { [analyzer, inputStream] in
      do {
        try await analyzer.start(inputSequence: inputStream)
      } catch {
        guard !Task.isCancelled else { return }
      }
    }

    NativeSpeechTranscriberAudioTap.install(
      on: inputNode,
      format: inputFormat,
      audioSink: audioSink)
    audioEngine.prepare()
    try audioEngine.start()
  }

  func finalize() async throws -> LiveSpeechRecognitionEvent? {
    stopAudioCapture()
    audioSink?.finish()
    try? await analyzer?.finalizeAndFinishThroughEndOfInput()
    if latestTranscript.isEmpty {
      try? await Task.sleep(for: .milliseconds(200))
    }
    return currentEvent(isFinal: true)
  }

  func stop() {
    stopAudioCapture()
    audioSink?.finish()
    audioSink = nil
    analysisTask?.cancel()
    analysisTask = nil
    resultsTask?.cancel()
    resultsTask = nil
    Task { [analyzer] in
      await analyzer?.cancelAndFinishNow()
    }
    analyzer = nil
    transcriber = nil
    deactivateAudioSession()
  }

  private func ensureAssetsAvailable(for transcriber: SpeechTranscriber, locale: Locale)
    async throws
  {
    let modules: [any SpeechModule] = [transcriber]
    let status = await AssetInventory.status(forModules: modules)
    switch status {
    case .installed:
      return
    case .supported, .downloading:
      guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules)
      else {
        return
      }
      try await request.downloadAndInstall()
    case .unsupported:
      throw LiveSpeechRecognitionError.speechTranscriberAssetsUnavailable(locale.identifier)
    @unknown default:
      throw LiveSpeechRecognitionError.speechTranscriberAssetsUnavailable(locale.identifier)
    }
  }

  private func activateAudioSession() throws {
    let audioSession = AVAudioSession.sharedInstance()
    try audioSession.setCategory(
      .playAndRecord,
      mode: .voiceChat,
      options: [.defaultToSpeaker, .allowBluetoothHFP])
    try audioSession.setActive(true, options: [])
    audioSessionActivated = true
    if audioSession.isInputGainSettable {
      try? audioSession.setInputGain(1.0)
    }
  }

  private func deactivateAudioSession() {
    guard audioSessionActivated else { return }
    audioSessionActivated = false
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  private func makeRecordingFile(format: AVAudioFormat) throws -> AVAudioFile {
    let directory = try PocketMaiDirectories.ensureVoiceRecordings()
    let filename = "voice-\(UUID().uuidString).caf"
    let url = directory.appendingPathComponent(filename)
    recordingFilename = filename
    return try AVAudioFile(forWriting: url, settings: format.settings)
  }

  private func stopAudioCapture() {
    guard let audioEngine else { return }
    audioEngine.inputNode.removeTap(onBus: 0)
    audioEngine.stop()
    self.audioEngine = nil
  }

  private func receiveTranscriberResult(_ result: SpeechTranscriber.Result) {
    let text = String(result.text.characters)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    let normalized = updateTranscriptSegments(range: result.range, text: text)
    guard !normalized.isEmpty else { return }
    latestTranscript = normalized
    onTranscript?(
      LiveSpeechRecognitionEvent(
        text: normalized,
        isFinal: false,
        languageIdentifier: languageIdentifier))
  }

  private func updateTranscriptSegments(range: CMTimeRange, text: String) -> String {
    transcriptSegments.removeAll { $0.overlaps(range) }
    transcriptSegments.append(NativeSpeechTranscriberSegment(range: range, text: text))
    transcriptSegments.sort {
      CMTimeCompare($0.range.start, $1.range.start) < 0
    }
    return
      transcriptSegments
      .map(\.text)
      .joined(separator: " ")
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  private func currentEvent(isFinal: Bool) -> LiveSpeechRecognitionEvent? {
    let text = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    return LiveSpeechRecognitionEvent(
      text: text,
      isFinal: isFinal,
      languageIdentifier: languageIdentifier)
  }
}

private struct NativeSpeechTranscriberSegment {
  let range: CMTimeRange
  let text: String

  func overlaps(_ other: CMTimeRange) -> Bool {
    let intersection = CMTimeRangeGetIntersection(range, otherRange: other)
    if CMTimeCompare(intersection.duration, .zero) > 0 {
      return true
    }
    return abs(CMTimeGetSeconds(range.start) - CMTimeGetSeconds(other.start)) < 0.001
  }
}

private enum NativeSpeechTranscriberAudioTap {
  static func install(
    on inputNode: AVAudioNode,
    format: AVAudioFormat,
    audioSink: NativeSpeechTranscriberAudioSink
  ) {
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
      audioSink.process(buffer: buffer)
    }
  }
}

private final class NativeSpeechTranscriberAudioSink: @unchecked Sendable {
  private let lock = NSLock()
  private let analysisFormat: AVAudioFormat
  private let converter: AVAudioConverter?
  private var continuation: AsyncStream<AnalyzerInput>.Continuation?
  private var recordingFile: AVAudioFile?

  init(
    continuation: AsyncStream<AnalyzerInput>.Continuation,
    analysisFormat: AVAudioFormat,
    recordingFile: AVAudioFile
  ) {
    self.continuation = continuation
    self.analysisFormat = analysisFormat
    self.converter =
      recordingFile.processingFormat == analysisFormat
      ? nil
      : AVAudioConverter(from: recordingFile.processingFormat, to: analysisFormat)
    self.recordingFile = recordingFile
  }

  func process(buffer: AVAudioPCMBuffer) {
    lock.lock()
    let continuation = self.continuation
    let analyzerBuffer = convertedBufferForSpeechTranscriber(from: buffer)
    do {
      try recordingFile?.write(from: buffer)
    } catch {
      // Keep transcription alive even if recording preservation fails.
    }
    lock.unlock()

    if let analyzerBuffer {
      continuation?.yield(AnalyzerInput(buffer: analyzerBuffer))
    }
  }

  func finish() {
    lock.lock()
    let continuation = self.continuation
    self.continuation = nil
    recordingFile = nil
    lock.unlock()
    continuation?.finish()
  }

  static func preferredAnalysisFormat(matching format: AVAudioFormat) -> AVAudioFormat {
    AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: format.sampleRate,
      channels: 1,
      interleaved: false
    ) ?? format
  }

  private func convertedBufferForSpeechTranscriber(from buffer: AVAudioPCMBuffer)
    -> AVAudioPCMBuffer?
  {
    if converter == nil, buffer.format == analysisFormat {
      return buffer.copyForSpeechTranscriber()
    }
    guard let converter else { return nil }
    converter.reset()
    let ratio = analysisFormat.sampleRate / buffer.format.sampleRate
    let capacity = max(1, AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16)
    guard let converted = AVAudioPCMBuffer(pcmFormat: analysisFormat, frameCapacity: capacity)
    else {
      return nil
    }
    let inputProvider = OneShotAudioConverterInput(buffer: buffer)
    var conversionError: NSError?
    let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
      inputProvider.consume(outStatus: outStatus)
    }
    switch status {
    case .haveData, .inputRanDry:
      return converted.frameLength > 0 ? converted : nil
    case .endOfStream, .error:
      return nil
    @unknown default:
      return nil
    }
  }
}

private final class OneShotAudioConverterInput: @unchecked Sendable {
  private let lock = NSLock()
  private let buffer: AVAudioPCMBuffer
  private var didProvideInput = false

  init(buffer: AVAudioPCMBuffer) {
    self.buffer = buffer
  }

  func consume(outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
    lock.lock()
    defer { lock.unlock() }
    if didProvideInput {
      outStatus.pointee = .noDataNow
      return nil
    }
    didProvideInput = true
    outStatus.pointee = .haveData
    return buffer
  }
}

extension AVAudioPCMBuffer {
  fileprivate func copyForSpeechTranscriber() -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
      return nil
    }
    copy.frameLength = frameLength
    let frameCount = Int(frameLength)
    let channelCount = Int(format.channelCount)
    guard frameCount > 0, channelCount > 0 else { return copy }

    if let source = floatChannelData, let destination = copy.floatChannelData {
      for channel in 0..<channelCount {
        destination[channel].update(from: source[channel], count: frameCount)
      }
      return copy
    }
    if let source = int16ChannelData, let destination = copy.int16ChannelData {
      for channel in 0..<channelCount {
        destination[channel].update(from: source[channel], count: frameCount)
      }
      return copy
    }
    if let source = int32ChannelData, let destination = copy.int32ChannelData {
      for channel in 0..<channelCount {
        destination[channel].update(from: source[channel], count: frameCount)
      }
      return copy
    }
    return nil
  }
}

@MainActor
private final class NativeIOSSpeechRecognitionEngine: NSObject, LiveSpeechRecognitionEngine {
  var onTranscript: ((LiveSpeechRecognitionEvent) -> Void)?
  private(set) var languageIdentifier: String

  private let locale: Locale
  private let silenceTimeoutSeconds: Double
  private var recognizer: SFSpeechRecognizer?
  private var recorder: AVAudioRecorder?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var meteringTask: Task<Void, Never>?
  private var cachedFinalEvent: LiveSpeechRecognitionEvent?
  private var finalizationTask: Task<LiveSpeechRecognitionEvent?, Error>?
  private(set) var recordingFilename: String?
  private var recordingURL: URL?
  private var audioSessionActivated = false
  private var hasDetectedSpeech = false
  private var lastSoundDate = Date()
  private let speechPowerThreshold: Float = -45

  init(localeIdentifier: String, silenceTimeoutSeconds: Double) {
    let identifier = localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    self.locale = identifier.isEmpty ? Locale.current : Locale(identifier: identifier)
    self.languageIdentifier = identifier.isEmpty ? Locale.current.identifier : identifier
    self.silenceTimeoutSeconds = ConversationSettings.clampedSilenceTimeout(silenceTimeoutSeconds)
  }

  func start() async throws {
    let microphoneGranted = await LiveSpeechPermissionRequester.requestMicrophonePermission()
    guard microphoneGranted else { throw LiveSpeechRecognitionError.microphoneDenied }

    let speechStatus = await LiveSpeechPermissionRequester.requestSpeechRecognitionPermission()
    guard speechStatus == .authorized else {
      throw LiveSpeechRecognitionError.speechRecognitionDenied
    }

    guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
      throw LiveSpeechRecognitionError.recognizerUnavailable(locale.identifier)
    }
    self.recognizer = recognizer
    languageIdentifier = recognizer.locale.identifier

    try activateAudioSession()
    try startRecording()
    startMetering()
  }

  func finalize() async throws -> LiveSpeechRecognitionEvent? {
    if let cachedFinalEvent {
      return cachedFinalEvent
    }
    if let finalizationTask {
      return try await finalizationTask.value
    }

    let task = Task<LiveSpeechRecognitionEvent?, Error> { @MainActor [weak self] in
      guard let self else { return nil }
      self.stopRecordingOnly()
      self.deactivateAudioSession()
      guard let url = self.recordingURL else { return nil }
      let event = try await self.recognizeRecording(at: url)
      self.cachedFinalEvent = event
      return event
    }
    finalizationTask = task
    do {
      let event = try await task.value
      finalizationTask = nil
      return event
    } catch {
      finalizationTask = nil
      throw error
    }
  }

  func stop() {
    meteringTask?.cancel()
    meteringTask = nil
    recorder?.stop()
    recorder = nil
    recognitionTask?.cancel()
    recognitionTask = nil
    finalizationTask?.cancel()
    finalizationTask = nil
    recognizer = nil
    deactivateAudioSession()
  }

  private func activateAudioSession() throws {
    let audioSession = AVAudioSession.sharedInstance()
    try audioSession.setCategory(
      .playAndRecord,
      mode: .voiceChat,
      options: [.defaultToSpeaker, .allowBluetoothHFP])
    try audioSession.setActive(true, options: [])
    audioSessionActivated = true
    if audioSession.isInputGainSettable {
      try? audioSession.setInputGain(1.0)
    }
  }

  private func deactivateAudioSession() {
    guard audioSessionActivated else { return }
    audioSessionActivated = false
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  private func startRecording() throws {
    let directory = try PocketMaiDirectories.ensureVoiceRecordings()
    let filename = "voice-\(UUID().uuidString).m4a"
    let url = directory.appendingPathComponent(filename)
    recordingFilename = filename
    recordingURL = url
    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
      AVSampleRateKey: 44100,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 64000,
      AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]
    let recorder = try AVAudioRecorder(url: url, settings: settings)
    recorder.isMeteringEnabled = true
    recorder.prepareToRecord()
    guard recorder.record() else {
      throw LiveSpeechRecognitionError.audioInputUnavailable
    }
    self.recorder = recorder
    hasDetectedSpeech = false
    lastSoundDate = Date()
  }

  private func startMetering() {
    meteringTask?.cancel()
    meteringTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(100))
        self?.pollRecorderMeter()
      }
    }
  }

  private func pollRecorderMeter() {
    guard let recorder, recorder.isRecording, finalizationTask == nil else { return }
    recorder.updateMeters()
    let power = recorder.averagePower(forChannel: 0)
    if power > speechPowerThreshold {
      hasDetectedSpeech = true
      lastSoundDate = Date()
      return
    }

    guard hasDetectedSpeech,
      Date().timeIntervalSince(lastSoundDate) >= silenceTimeoutSeconds
    else {
      return
    }
    finalizeFromEndpoint()
  }

  private func finalizeFromEndpoint() {
    guard finalizationTask == nil else { return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        guard let event = try await self.finalize(),
          !event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          return
        }
        self.onTranscript?(event)
      } catch {
        self.stop()
      }
    }
  }

  private func stopRecordingOnly() {
    meteringTask?.cancel()
    meteringTask = nil
    if recorder?.isRecording == true {
      recorder?.stop()
    }
    recorder = nil
  }

  private func recognizeRecording(at url: URL) async throws -> LiveSpeechRecognitionEvent? {
    guard let recognizer else {
      throw LiveSpeechRecognitionError.recognizerUnavailable(languageIdentifier)
    }

    return try await withCheckedThrowingContinuation { continuation in
      let resumeBox = RecognitionContinuationBox()
      let request = SFSpeechURLRecognitionRequest(url: url)
      request.shouldReportPartialResults = false
      request.taskHint = .dictation

      let languageIdentifier = self.languageIdentifier
      let completion: @Sendable (SFSpeechRecognitionResult?, Error?) -> Void = { result, error in
        if let error {
          resumeBox.resume(continuation, throwing: error)
          return
        }
        guard let result, result.isFinal else { return }
        let text = result.bestTranscription.formattedString
        let event = LiveSpeechRecognitionEvent(
          text: text,
          isFinal: true,
          languageIdentifier: languageIdentifier)
        resumeBox.resume(continuation, returning: event)
      }
      recognitionTask = recognizer.recognitionTask(with: request, resultHandler: completion)
    }
  }
}

private final class RecognitionContinuationBox: @unchecked Sendable {
  private let lock = NSLock()
  private var didResume = false

  func resume(
    _ continuation: CheckedContinuation<LiveSpeechRecognitionEvent?, Error>,
    returning event: LiveSpeechRecognitionEvent?
  ) {
    lock.lock()
    defer { lock.unlock() }
    guard !didResume else { return }
    didResume = true
    continuation.resume(returning: event)
  }

  func resume(
    _ continuation: CheckedContinuation<LiveSpeechRecognitionEvent?, Error>,
    throwing error: Error
  ) {
    lock.lock()
    defer { lock.unlock() }
    guard !didResume else { return }
    didResume = true
    continuation.resume(throwing: error)
  }
}
