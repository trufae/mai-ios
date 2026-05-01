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
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    if synthesizer.isSpeaking {
      if interrupt {
        synthesizer.stopSpeaking(at: .immediate)
      } else {
        return
      }
    }

    activateAudioSession()

    let utterance = AVSpeechUtterance(string: trimmed)
    if !voice.voiceIdentifier.isEmpty,
      let v = AVSpeechSynthesisVoice(identifier: voice.voiceIdentifier)
    {
      utterance.voice = v
    } else if !voice.language.isEmpty {
      utterance.voice = AVSpeechSynthesisVoice(language: voice.language)
    }
    utterance.rate = Float(max(0, min(1, voice.rate)))
    utterance.pitchMultiplier = Float(max(0.5, min(2, voice.pitch)))

    currentRole = role
    currentTitle = title
    currentText = trimmed
    currentTag = tag
    currentMessageID = messageID
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
    if synthesizer.isSpeaking {
      synthesizer.stopSpeaking(at: .immediate)
      return
    }
    handleStopped()
  }

  func isPlaying(tag: String) -> Bool {
    isSpeaking && currentTag == tag
  }

  private func handleStopped() {
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
}

extension TTSPlayer: AVSpeechSynthesizerDelegate {
  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in self.handleStopped() }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in self.handleStopped() }
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
