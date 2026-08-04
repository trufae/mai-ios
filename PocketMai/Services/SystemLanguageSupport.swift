import AVFoundation
import Foundation
import Speech

enum SystemLanguageSupport {
  private struct Catalog {
    let textToSpeechVoices: [AVSpeechSynthesisVoice]
    let textToSpeechLanguageIdentifiers: [String]
    let speechRecognitionLocaleIdentifiers: [String]
    let chatLanguageIdentifiers: [String]
    let chatLanguageIdentifierSet: Set<String>
    let displayNames: [String: String]

    init() {
      let voices = AVSpeechSynthesisVoice.speechVoices()
      let textToSpeech = SystemLanguageSupport.sortedLanguageIdentifiersUncached(
        voices.map(\.language)
      )
      let speechRecognition = SystemLanguageSupport.sortedLanguageIdentifiersUncached(
        SFSpeechRecognizer.supportedLocales().map(\.identifier)
      )
      let speechRecognitionSet = Set(speechRecognition)
      let chat = SystemLanguageSupport.sortedLanguageIdentifiersUncached(
        textToSpeech.filter { speechRecognitionSet.contains($0) }
      )

      textToSpeechVoices = voices
      textToSpeechLanguageIdentifiers = textToSpeech
      speechRecognitionLocaleIdentifiers = speechRecognition
      chatLanguageIdentifiers = chat
      chatLanguageIdentifierSet = Set(chat)
      displayNames = Dictionary(
        uniqueKeysWithValues: Set(textToSpeech + speechRecognition).map { identifier in
          (identifier, SystemLanguageSupport.uncachedLanguageDisplayName(identifier))
        }
      )
    }
  }

  private static let catalog = Catalog()

  static func preload() {
    _ = catalog
  }

  static var textToSpeechVoices: [AVSpeechSynthesisVoice] {
    catalog.textToSpeechVoices
  }

  static var textToSpeechLanguageIdentifiers: [String] {
    catalog.textToSpeechLanguageIdentifiers
  }

  static var speechRecognitionLocaleIdentifiers: [String] {
    catalog.speechRecognitionLocaleIdentifiers
  }

  static func chatLanguageIdentifiers(including selected: String? = nil) -> [String] {
    guard let selected = normalizedLanguageIdentifier(selected),
      !catalog.chatLanguageIdentifierSet.contains(selected)
    else { return catalog.chatLanguageIdentifiers }
    return sortedLanguageIdentifiers(catalog.chatLanguageIdentifiers + [selected])
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
    return catalog.displayNames[normalized] ?? uncachedLanguageDisplayName(normalized)
  }

  static func sortedLanguageIdentifiers(_ identifiers: [String]) -> [String] {
    sortLanguageIdentifiers(identifiers, displayName: languageDisplayName)
  }

  private static func sortedLanguageIdentifiersUncached(_ identifiers: [String]) -> [String] {
    sortLanguageIdentifiers(identifiers, displayName: uncachedLanguageDisplayName)
  }

  private static func sortLanguageIdentifiers(
    _ identifiers: [String],
    displayName: (String) -> String
  ) -> [String] {
    let unique = Set(identifiers.map(canonicalLanguageIdentifier).filter { !$0.isEmpty })
    return unique
      .map { identifier in (identifier, displayName(identifier)) }
      .sorted { lhs, rhs in
        let order = lhs.1.localizedCaseInsensitiveCompare(rhs.1)
        return order == .orderedSame ? lhs.0 < rhs.0 : order == .orderedAscending
      }
      .map(\.0)
  }

  private static func uncachedLanguageDisplayName(_ identifier: String) -> String {
    let normalized = canonicalLanguageIdentifier(identifier)
    let name = Locale.current.localizedString(forIdentifier: normalized) ?? normalized
    return "\(name) (\(normalized))"
  }
}
