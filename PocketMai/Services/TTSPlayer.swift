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
    interrupt: Bool = true
  ) {
    guard
      let speech = QueuedSpeech(
        text: text,
        voice: voice,
        role: role,
        title: title,
        tag: tag,
        messageID: messageID
      )
    else { return }

    if synthesizer.isSpeaking {
      if interrupt {
        queuedSpeech.removeAll()
        pendingSpeechAfterCancel = speech
        synthesizer.stopSpeaking(at: .immediate)
      } else {
        return
      }
      return
    }

    queuedSpeech.removeAll()
    pendingSpeechAfterCancel = nil
    beginSpeaking(speech)
  }

  func speakFromHere(messages: [ChatMessage], voices: VoiceSettings) {
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
        messageID: message.id
      )
    }
    guard let first = items.first else { return }

    queuedSpeech = Array(items.dropFirst())
    if synthesizer.isSpeaking {
      pendingSpeechAfterCancel = first
      synthesizer.stopSpeaking(at: .immediate)
      return
    }

    pendingSpeechAfterCancel = nil
    beginSpeaking(first)
  }

  private func beginSpeaking(_ speech: QueuedSpeech) {
    activateAudioSession()

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

    currentRole = speech.role
    currentTitle = speech.title
    currentText = speech.text
    currentTag = speech.tag
    currentMessageID = speech.messageID
    isSpeaking = true
    isPaused = false
    updateNowPlaying()

    synthesizer.speak(utterance)
  }

  func pause() {
    guard synthesizer.isSpeaking, !isPaused else { return }
    synthesizer.pauseSpeaking(at: .word)
  }

  func resume() {
    guard isPaused else { return }
    synthesizer.continueSpeaking()
  }

  func stop() {
    queuedSpeech.removeAll()
    pendingSpeechAfterCancel = nil
    if synthesizer.isSpeaking {
      synthesizer.stopSpeaking(at: .immediate)
      return
    }
    handleStopped()
  }

  func isPlaying(tag: String) -> Bool {
    isSpeaking && currentTag == tag
  }

  private func handleFinished() {
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

    init?(
      text: String,
      voice: RoleVoiceSettings,
      role: VoiceRole,
      title: String?,
      tag: String?,
      messageID: UUID?
    ) {
      let sanitized = TTSSpeechTextSanitizer.sanitized(text)
      guard !sanitized.isEmpty else { return nil }
      self.text = sanitized
      self.voice = voice
      self.role = role
      self.title = title
      self.tag = tag
      self.messageID = messageID
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
