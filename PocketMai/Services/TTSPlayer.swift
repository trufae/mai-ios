import AVFoundation
import Foundation
import MediaPlayer

@MainActor
final class TTSPlayer: NSObject, ObservableObject {
  static let shared = TTSPlayer()

  @Published private(set) var isSpeaking: Bool = false
  @Published private(set) var isPaused: Bool = false
  @Published private(set) var currentRole: VoiceRole?
  @Published private(set) var currentTitle: String?
  @Published private(set) var currentText: String?
  @Published private(set) var currentTag: String?
  @Published private(set) var currentMessageID: UUID?

  private let synthesizer = AVSpeechSynthesizer()
  private var remoteCommandsConfigured = false
  private var queuedSpeech: [QueuedSpeech] = []
  private var pendingSpeechAfterCancel: QueuedSpeech?
  private var providerSpeechTask: Task<Void, Never>?
  private var audioPlayer: AVAudioPlayer?
  private var audioFileURL: URL?
  private var speechGeneration = 0

  override init() {
    super.init()
    synthesizer.delegate = self
    setupRemoteCommands()
  }

  func speak(
    text: String,
    voice: RoleVoiceSettings,
    role: VoiceRole,
    title: String? = nil,
    tag: String? = nil,
    messageID: UUID? = nil,
    openAIEndpoints: [OpenAIEndpoint] = [],
    interrupt: Bool = true
  ) {
    guard
      let speech = QueuedSpeech(
        text: text,
        voice: voice,
        role: role,
        title: title,
        tag: tag,
        messageID: messageID,
        openAIEndpoints: openAIEndpoints
      )
    else { return }

    if hasActiveSpeech {
      if interrupt {
        queuedSpeech.removeAll()
        pendingSpeechAfterCancel = speech
        cancelActiveSpeech()
      } else {
        return
      }
      return
    }

    queuedSpeech.removeAll()
    pendingSpeechAfterCancel = nil
    beginSpeaking(speech)
  }

  func speakFromHere(
    messages: [ChatMessage],
    voices: VoiceSettings,
    openAIEndpoints: [OpenAIEndpoint] = []
  ) {
    let items = messages.compactMap { message -> QueuedSpeech? in
      let role: VoiceRole
      switch message.role {
      case .user: role = .user
      case .assistant: role = .assistant
      default: return nil
      }
      return QueuedSpeech(
        text: MessageContentFilter.render(message.text).visibleText,
        voice: voices.settings(for: role),
        role: role,
        title: message.role.displayName,
        tag: nil,
        messageID: message.id,
        openAIEndpoints: openAIEndpoints
      )
    }
    guard let first = items.first else { return }

    queuedSpeech = Array(items.dropFirst())
    if hasActiveSpeech {
      pendingSpeechAfterCancel = first
      cancelActiveSpeech()
      return
    }

    pendingSpeechAfterCancel = nil
    beginSpeaking(first)
  }

  private func beginSpeaking(_ speech: QueuedSpeech) {
    activateAudioSession()
    speechGeneration += 1

    currentRole = speech.role
    currentTitle = speech.title
    currentText = speech.text
    currentTag = speech.tag
    currentMessageID = speech.messageID
    isSpeaking = true
    isPaused = false
    updateNowPlaying()

    if speech.voice.provider == .openAICompatible,
      let endpoint = speech.openAIEndpoint,
      !speech.voice.openAIVoice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      beginProviderSpeaking(speech, endpoint: endpoint, generation: speechGeneration)
      return
    }

    beginSystemSpeaking(speech)
  }

  private func beginSystemSpeaking(_ speech: QueuedSpeech) {
    let utterance = AVSpeechUtterance(string: speech.text)
    if !speech.voice.voiceIdentifier.isEmpty,
      let v = AVSpeechSynthesisVoice(identifier: speech.voice.voiceIdentifier)
    {
      utterance.voice = v
    } else if !speech.voice.language.isEmpty {
      utterance.voice = AVSpeechSynthesisVoice(language: speech.voice.language)
    }
    utterance.rate = Float(max(0, min(1, speech.voice.rate)))
    utterance.pitchMultiplier = Float(max(0.5, min(2, speech.voice.pitch)))

    synthesizer.speak(utterance)
  }

  private func beginProviderSpeaking(
    _ speech: QueuedSpeech,
    endpoint: OpenAIEndpoint,
    generation: Int
  ) {
    let voice = speech.voice.openAIVoice.trimmingCharacters(in: .whitespacesAndNewlines)
    providerSpeechTask = Task { [weak self] in
      let formats = ["wav"]
      for format in formats {
        guard !Task.isCancelled else { return }
        do {
          let data = try await OpenAICompatibleProvider.synthesizeSpeechAudio(
            endpoint: endpoint,
            input: speech.text,
            voice: voice,
            responseFormat: format)
          try Task.checkCancellation()
          let didStart = await MainActor.run {
            self?.playProviderAudio(data, fileExtension: format, generation: generation) ?? false
          }
          if didStart { return }
        } catch is CancellationError {
          return
        } catch {
          continue
        }
      }

      await MainActor.run {
        guard let self, self.speechGeneration == generation else { return }
        self.handleStopped()
      }
    }
  }

  private func playProviderAudio(
    _ data: Data,
    fileExtension: String,
    generation: Int
  ) -> Bool {
    guard speechGeneration == generation else { return true }
    var url: URL?
    do {
      cleanupAudioFile()
      let candidateURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("PocketMaiTTS-\(UUID().uuidString)")
        .appendingPathExtension(fileExtension)
      url = candidateURL
      let url = candidateURL
      let playableData = normalizedProviderAudioData(data, fileExtension: fileExtension)
      try playableData.write(to: url, options: .atomic)
      let player = try AVAudioPlayer(contentsOf: url)
      player.delegate = self
      player.prepareToPlay()
      if player.play() {
        audioFileURL = url
        audioPlayer = player
        providerSpeechTask = nil
        return true
      }
      try? FileManager.default.removeItem(at: url)
      return false
    } catch {
      if let url {
        try? FileManager.default.removeItem(at: url)
      }
      cleanupAudioFile()
      return false
    }
  }

  private func normalizedProviderAudioData(_ data: Data, fileExtension: String) -> Data {
    guard fileExtension.lowercased() == "wav" else { return data }
    return data.withRepairedWAVChunkSizes()
  }


  func pause() {
    if let audioPlayer, audioPlayer.isPlaying, !isPaused {
      audioPlayer.pause()
      isPaused = true
      updateNowPlaying()
      return
    }
    guard synthesizer.isSpeaking, !isPaused else { return }
    synthesizer.pauseSpeaking(at: .word)
  }

  func resume() {
    guard isPaused else { return }
    if let audioPlayer {
      audioPlayer.play()
      isPaused = false
      updateNowPlaying()
      return
    }
    synthesizer.continueSpeaking()
  }

  func stop() {
    queuedSpeech.removeAll()
    pendingSpeechAfterCancel = nil
    if synthesizer.isSpeaking {
      synthesizer.stopSpeaking(at: .immediate)
      return
    }
    if providerSpeechTask != nil || audioPlayer != nil {
      cancelProviderSpeech()
      handleStopped()
      return
    }
    handleStopped()
  }

  func isPlaying(tag: String) -> Bool {
    isSpeaking && currentTag == tag
  }

  private func handleFinished() {
    if audioPlayer != nil {
      audioPlayer = nil
      cleanupAudioFile()
    }
    if !queuedSpeech.isEmpty {
      let next = queuedSpeech.removeFirst()
      beginSpeaking(next)
      return
    }
    handleStopped()
  }

  private func handleCancelled() {
    if let next = pendingSpeechAfterCancel {
      pendingSpeechAfterCancel = nil
      beginSpeaking(next)
      return
    }
    handleStopped()
  }

  private func handleStopped() {
    queuedSpeech.removeAll()
    pendingSpeechAfterCancel = nil
    providerSpeechTask?.cancel()
    providerSpeechTask = nil
    audioPlayer?.stop()
    audioPlayer = nil
    cleanupAudioFile()
    isSpeaking = false
    isPaused = false
    currentRole = nil
    currentTitle = nil
    currentText = nil
    currentTag = nil
    currentMessageID = nil
    clearNowPlaying()
    deactivateAudioSession()
  }

  private var hasActiveSpeech: Bool {
    synthesizer.isSpeaking || providerSpeechTask != nil || audioPlayer != nil
  }

  private func cancelActiveSpeech() {
    if synthesizer.isSpeaking {
      synthesizer.stopSpeaking(at: .immediate)
      return
    }
    cancelProviderSpeech()
    handleCancelled()
  }

  private func cancelProviderSpeech() {
    providerSpeechTask?.cancel()
    providerSpeechTask = nil
    audioPlayer?.stop()
    audioPlayer = nil
    cleanupAudioFile()
  }

  private func cleanupAudioFile() {
    if let audioFileURL {
      try? FileManager.default.removeItem(at: audioFileURL)
    }
    audioFileURL = nil
  }

  private func activateAudioSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .spokenAudio, options: [])
      try session.setActive(true, options: [])
    } catch {
      // Best-effort: TTS still plays in foreground without an active session.
    }
  }

  private func deactivateAudioSession() {
    do {
      try AVAudioSession.sharedInstance().setActive(
        false, options: .notifyOthersOnDeactivation)
    } catch {
      // Ignore: the session may already be inactive.
    }
  }

  private func updateNowPlaying() {
    var info: [String: Any] = [:]
    info[MPMediaItemPropertyTitle] = currentTitle ?? "Spoken Message"
    if let role = currentRole {
      info[MPMediaItemPropertyArtist] = role == .user ? "User" : "Assistant"
    }
    if let text = currentText, !text.isEmpty {
      info[MPMediaItemPropertyAlbumTitle] = String(text.prefix(120))
    }
    info[MPNowPlayingInfoPropertyPlaybackRate] = isPaused ? 0.0 : 1.0
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  private func clearNowPlaying() {
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
  }

  private func setupRemoteCommands() {
    guard !remoteCommandsConfigured else { return }
    remoteCommandsConfigured = true
    let center = MPRemoteCommandCenter.shared()

    center.playCommand.isEnabled = true
    center.playCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.resume() }
      return .success
    }
    center.pauseCommand.isEnabled = true
    center.pauseCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.pause() }
      return .success
    }
    center.stopCommand.isEnabled = true
    center.stopCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.stop() }
      return .success
    }
    center.togglePlayPauseCommand.isEnabled = true
    center.togglePlayPauseCommand.addTarget { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        if self.isPaused {
          self.resume()
        } else if self.isSpeaking {
          self.pause()
        }
      }
      return .success
    }
  }

  private struct QueuedSpeech {
    let text: String
    let voice: RoleVoiceSettings
    let role: VoiceRole
    let title: String?
    let tag: String?
    let messageID: UUID?
    let openAIEndpoints: [OpenAIEndpoint]
    var openAIEndpoint: OpenAIEndpoint? {
      guard let id = voice.openAIEndpointID else { return nil }
      return openAIEndpoints.first(where: { $0.id == id && $0.isEnabled })
    }

    init?(
      text: String,
      voice: RoleVoiceSettings,
      role: VoiceRole,
      title: String?,
      tag: String?,
      messageID: UUID?,
      openAIEndpoints: [OpenAIEndpoint]
    ) {
      let sanitized = TTSSpeechTextSanitizer.sanitized(text)
      guard !sanitized.isEmpty else { return nil }
      self.text = sanitized
      self.voice = voice
      self.role = role
      self.title = title
      self.tag = tag
      self.messageID = messageID
      self.openAIEndpoints = openAIEndpoints
    }
  }
}

extension TTSPlayer: AVSpeechSynthesizerDelegate {
  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in self.handleFinished() }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in self.handleCancelled() }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in
      self.isPaused = true
      self.updateNowPlaying()
    }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in
      self.isPaused = false
      self.updateNowPlaying()
    }
  }
}

extension TTSPlayer: AVAudioPlayerDelegate {
  nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    Task { @MainActor in self.handleFinished() }
  }

  nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    Task { @MainActor in self.handleStopped() }
  }
}

private extension Data {
  func withRepairedWAVChunkSizes() -> Data {
    guard count >= 44,
      matchesASCII("RIFF", at: 0),
      matchesASCII("WAVE", at: 8)
    else { return self }

    var repaired = self
    repaired.writeLittleEndianUInt32(UInt32(clamping: count - 8), at: 4)

    var offset = 12
    while offset + 8 <= repaired.count {
      let chunkIDOffset = offset
      let chunkSizeOffset = offset + 4
      let chunkSize = repaired.littleEndianUInt32(at: chunkSizeOffset)
      let chunkDataOffset = offset + 8
      if repaired.matchesASCII("data", at: chunkIDOffset) {
        let actualDataSize = Swift.max(0, repaired.count - chunkDataOffset)
        repaired.writeLittleEndianUInt32(UInt32(clamping: actualDataSize), at: chunkSizeOffset)
        return repaired
      }

      let nextOffset = chunkDataOffset + Int(chunkSize) + (Int(chunkSize) & 1)
      guard nextOffset > offset else { return repaired }
      if nextOffset > repaired.count {
        return repaired
      }
      offset = nextOffset
    }

    return repaired
  }

  func matchesASCII(_ string: String, at offset: Int) -> Bool {
    let bytes = Array(string.utf8)
    guard offset >= 0, offset + bytes.count <= count else { return false }
    for index in bytes.indices where self[offset + index] != bytes[index] {
      return false
    }
    return true
  }

  func littleEndianUInt32(at offset: Int) -> UInt32 {
    guard offset >= 0, offset + 4 <= count else { return 0 }
    return UInt32(self[offset])
      | (UInt32(self[offset + 1]) << 8)
      | (UInt32(self[offset + 2]) << 16)
      | (UInt32(self[offset + 3]) << 24)
  }

  mutating func writeLittleEndianUInt32(_ value: UInt32, at offset: Int) {
    guard offset >= 0, offset + 4 <= count else { return }
    self[offset] = UInt8(value & 0xff)
    self[offset + 1] = UInt8((value >> 8) & 0xff)
    self[offset + 2] = UInt8((value >> 16) & 0xff)
    self[offset + 3] = UInt8((value >> 24) & 0xff)
  }
}
