import AVFoundation
import Foundation

@MainActor
final class TTSExporter: ObservableObject {
  enum ExportError: LocalizedError {
    case noSpeakableMessages
    case voiceCannotRenderOffline

    var errorDescription: String? {
      switch self {
      case .noSpeakableMessages: "This conversation has no spoken content to export."
      case .voiceCannotRenderOffline:
        "The selected voice cannot be rendered offline. Try a system voice."
      }
    }
  }

  @Published private(set) var isExporting: Bool = false
  @Published private(set) var progress: Double = 0
  @Published private(set) var phase: String = ""

  private let synthesizer = AVSpeechSynthesizer()
  private var audioFile: AVAudioFile?
  private var cancelled: Bool = false

  func cancel() {
    cancelled = true
    synthesizer.stopSpeaking(at: .immediate)
  }

  func export(
    messages: [ChatMessage],
    voices: VoiceSettings,
    to url: URL
  ) async throws {
    cancelled = false
    audioFile = nil
    isExporting = true
    progress = 0
    phase = "Preparing…"
    defer {
      isExporting = false
      audioFile = nil
    }

    let speakable = messages.filter { msg in
      (msg.role == .user || msg.role == .assistant)
        && !msg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard !speakable.isEmpty else { throw ExportError.noSpeakableMessages }

    if FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.removeItem(at: url)
    }

    let total = speakable.count
    for (index, msg) in speakable.enumerated() {
      if cancelled { throw CancellationError() }
      phase = "Synthesizing \(index + 1) of \(total)"
      let role: VoiceRole = msg.role == .user ? .user : .assistant
      let preferred = voices.settings(for: role)
      do {
        try await synthesize(text: msg.text, voice: preferred, fileURL: url)
      } catch ExportError.voiceCannotRenderOffline {
        // Fallback: drop the custom voice identifier and retry with the
        // language-default voice. This recovers from Personal/Premium voices
        // that refuse offline buffer writes.
        var fallback = preferred
        fallback.voiceIdentifier = ""
        try await synthesize(text: msg.text, voice: fallback, fileURL: url)
      }
      progress = Double(index + 1) / Double(total)
    }

    phase = "Done"
  }

  private func synthesize(
    text: String,
    voice: RoleVoiceSettings,
    fileURL: URL
  ) async throws {
    let utterance = AVSpeechUtterance(
      string: text.trimmingCharacters(in: .whitespacesAndNewlines))
    if !voice.voiceIdentifier.isEmpty,
      let v = AVSpeechSynthesisVoice(identifier: voice.voiceIdentifier)
    {
      utterance.voice = v
    } else if !voice.language.isEmpty {
      utterance.voice = AVSpeechSynthesisVoice(language: voice.language)
    }
    utterance.rate = Float(max(0, min(1, voice.rate)))
    utterance.pitchMultiplier = Float(max(0.5, min(2, voice.pitch)))

    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      let state = SynthesisState()
      synthesizer.write(utterance) { [weak self] buffer in
        guard let self else { return }
        Task { @MainActor in
          self.handleBuffer(buffer, fileURL: fileURL, state: state, continuation: cont)
        }
      }
    }
  }

  private func handleBuffer(
    _ buffer: AVAudioBuffer,
    fileURL: URL,
    state: SynthesisState,
    continuation: CheckedContinuation<Void, Error>
  ) {
    guard !state.didFinish else { return }
    guard let pcm = buffer as? AVAudioPCMBuffer else { return }
    if pcm.frameLength == 0 {
      state.didFinish = true
      if state.didReceiveAnyAudio {
        continuation.resume()
      } else {
        continuation.resume(throwing: ExportError.voiceCannotRenderOffline)
      }
      return
    }
    state.didReceiveAnyAudio = true
    do {
      if audioFile == nil {
        audioFile = try makeAudioFile(at: fileURL, format: pcm.format)
      }
      try audioFile?.write(from: pcm)
    } catch {
      state.didFinish = true
      continuation.resume(throwing: error)
    }
  }

  private func makeAudioFile(at url: URL, format: AVAudioFormat) throws -> AVAudioFile {
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: format.sampleRate,
      AVNumberOfChannelsKey: Int(format.channelCount),
      AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
    ]
    return try AVAudioFile(
      forWriting: url,
      settings: settings,
      commonFormat: format.commonFormat,
      interleaved: format.isInterleaved)
  }

  private final class SynthesisState {
    var didFinish: Bool = false
    var didReceiveAnyAudio: Bool = false
  }
}
