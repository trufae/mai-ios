import AVFoundation
import Foundation
import Speech

enum SystemLanguageSupport {
  static var textToSpeechLanguageIdentifiers: [String] {
    sortedLanguageIdentifiers(AVSpeechSynthesisVoice.speechVoices().map(\.language))
  }

  static var speechRecognitionLocaleIdentifiers: [String] {
    sortedLanguageIdentifiers(SFSpeechRecognizer.supportedLocales().map(\.identifier))
  }

  static func chatLanguageIdentifiers(including selected: String? = nil) -> [String] {
    let speech = Set(speechRecognitionLocaleIdentifiers.map(canonicalLanguageIdentifier))
    let speechAndVoice = textToSpeechLanguageIdentifiers
      .map(canonicalLanguageIdentifier)
      .filter { speech.contains($0) }
    var identifiers = Array(Set(speechAndVoice))
    if let selected = normalizedLanguageIdentifier(selected), !identifiers.contains(selected) {
      identifiers.append(selected)
    }
    return sortedLanguageIdentifiers(identifiers)
  }

  static func normalizedLanguageIdentifier(_ identifier: String?) -> String? {
    guard let identifier else { return nil }
    let normalized = canonicalLanguageIdentifier(identifier)
    return normalized.isEmpty ? nil : normalized
  }

  static func canonicalLanguageIdentifier(_ identifier: String) -> String {
    identifier.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "_", with: "-")
  }

  static func primaryLanguageCode(_ identifier: String) -> String? {
    let code = Locale(identifier: identifier).language.languageCode?.identifier
    return code?.isEmpty == false ? code : nil
  }

  static func primaryLanguageDisplayName(_ code: String) -> String {
    Locale.current.localizedString(forLanguageCode: code) ?? code
  }

  static func variantDisplayName(_ identifier: String) -> String {
    let locale = Locale(identifier: identifier)
    if let region = locale.region?.identifier,
      let regionName = Locale.current.localizedString(forRegionCode: region)
    {
      return "\(regionName) (\(canonicalLanguageIdentifier(identifier)))"
    }
    return languageDisplayName(identifier)
  }

  static func languageDisplayName(_ identifier: String) -> String {
    let normalized = canonicalLanguageIdentifier(identifier)
    let name = Locale.current.localizedString(forIdentifier: normalized) ?? normalized
    return "\(name) (\(normalized))"
  }

  static func sortedLanguageIdentifiers(_ identifiers: [String]) -> [String] {
    Array(Set(identifiers.map(canonicalLanguageIdentifier).filter { !$0.isEmpty }))
      .sorted {
        languageDisplayName($0).localizedCaseInsensitiveCompare(languageDisplayName($1))
          == .orderedAscending
      }
  }
}
