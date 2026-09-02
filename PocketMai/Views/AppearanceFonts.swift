import SwiftUI
import UIKit

extension AppearanceSettings {
  func fontFamily(for role: ChatRole) -> AppearanceFontFamily {
    role == .user ? userFontFamily : assistantFontFamily
  }

  func swiftUIFont(for role: ChatRole) -> Font {
    fontFamily(for: role).swiftUIFont(size: fontSize)
  }

  func uiFont(for role: ChatRole) -> UIFont {
    fontFamily(for: role).uiFont(size: fontSize)
  }

  var userSwiftUIFont: Font { swiftUIFont(for: .user) }
  var assistantSwiftUIFont: Font { swiftUIFont(for: .assistant) }
  var userUIFont: UIFont { uiFont(for: .user) }
  var assistantUIFont: UIFont { uiFont(for: .assistant) }

  var codeFont: Font {
    .system(size: Self.clampedFontSize(fontSize - 1), design: .monospaced)
  }

  var tintColor: Color? {
    tint.color
  }
}

extension AppearanceFontFamily {
  static let builtInPickerOptions: [AppearanceFontFamily] = [
    .system, .serif, .rounded, .monospaced,
  ]

  static var fontPickerGroups: [AppearanceFontPickerGroup] {
    let builtIns = builtInPickerOptions.map {
      AppearanceFontPickerGroup(id: $0.pickerGroupID, displayName: $0.displayName, faces: [])
    }
    return builtIns + installedFontPickerGroups
  }

  static var installedFontPickerGroups: [AppearanceFontPickerGroup] {
    UIFont.familyNames
      .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
      .compactMap { familyName in
        let faces = UIFont.fontNames(forFamilyName: familyName)
          .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
          .map { fontName in
            AppearanceFontPickerFace(
              fontName: fontName,
              displayName: Self.faceDisplayName(fontName: fontName, familyName: familyName))
          }
        guard !faces.isEmpty else { return nil }
        return AppearanceFontPickerGroup(
          id: installedPickerGroupID(familyName),
          displayName: familyName,
          faces: faces)
      }
  }

  var pickerGroupID: String {
    switch self {
    case .system, .serif, .rounded, .monospaced:
      return id
    case .installed(let fontName):
      if let group = Self.installedFontPickerGroups.first(where: {
        $0.faces.contains { $0.fontName == fontName }
      }) {
        return group.id
      }
      if let familyName = UIFont(name: fontName, size: 12)?.familyName {
        return Self.installedPickerGroupID(familyName)
      }
      return Self.installedPickerGroupID(fontName)
    }
  }

  static func font(forPickerGroupID groupID: String, current: AppearanceFontFamily)
    -> AppearanceFontFamily
  {
    switch groupID {
    case AppearanceFontFamily.system.id:
      return .system
    case AppearanceFontFamily.serif.id:
      return .serif
    case AppearanceFontFamily.rounded.id:
      return .rounded
    case AppearanceFontFamily.monospaced.id:
      return .monospaced
    default:
      guard let group = fontPickerGroups.first(where: { $0.id == groupID }),
        let face = group.preferredFace(currentFontName: current.installedFontName)
      else {
        return current
      }
      return .installed(face.fontName)
    }
  }

  static func installedPickerGroup(for groupID: String) -> AppearanceFontPickerGroup? {
    installedFontPickerGroups.first { $0.id == groupID }
  }

  var installedFontName: String? {
    guard case .installed(let fontName) = self else { return nil }
    return fontName
  }

  private static func installedPickerGroupID(_ familyName: String) -> String {
    "installed-family:\(familyName)"
  }

  private static func faceDisplayName(fontName: String, familyName: String) -> String {
    if let face = UIFont(name: fontName, size: 12)?.fontDescriptor.object(forKey: .face) as? String,
      !face.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return face
    }

    let readableName = fontName.replacingOccurrences(of: "-", with: " ")
    let prefixes = [
      familyName,
      familyName.replacingOccurrences(of: " ", with: ""),
      familyName.replacingOccurrences(of: " ", with: "-"),
    ]
    for prefix in prefixes where readableName.localizedCaseInsensitiveContains(prefix) {
      let value =
        readableName
        .replacingOccurrences(of: prefix, with: "", options: [.caseInsensitive])
        .trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
      if !value.isEmpty { return value }
    }
    return readableName == familyName ? "Regular" : readableName
  }

  func swiftUIFont(size: Double) -> Font {
    switch self {
    case .system:
      return .system(size: size)
    case .serif:
      return .system(size: size, design: .serif)
    case .rounded:
      return .system(size: size, design: .rounded)
    case .monospaced:
      return .system(size: size, design: .monospaced)
    case .installed(let fontName):
      return .custom(fontName, size: size, relativeTo: .body)
    }
  }

  func uiFont(size: Double) -> UIFont {
    let textStyle = UIFont.TextStyle.body
    let pointSize = CGFloat(size)
    let descriptor: UIFontDescriptor
    switch self {
    case .system:
      descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: textStyle)
    case .serif:
      descriptor =
        UIFontDescriptor.preferredFontDescriptor(withTextStyle: textStyle)
        .withDesign(.serif) ?? UIFontDescriptor.preferredFontDescriptor(withTextStyle: textStyle)
    case .rounded:
      descriptor =
        UIFontDescriptor.preferredFontDescriptor(withTextStyle: textStyle)
        .withDesign(.rounded) ?? UIFontDescriptor.preferredFontDescriptor(withTextStyle: textStyle)
    case .monospaced:
      descriptor =
        UIFontDescriptor.preferredFontDescriptor(withTextStyle: textStyle)
        .withDesign(.monospaced)
        ?? UIFontDescriptor.preferredFontDescriptor(withTextStyle: textStyle)
    case .installed(let fontName):
      let font = UIFont(name: fontName, size: pointSize) ?? .preferredFont(forTextStyle: textStyle)
      return UIFontMetrics(forTextStyle: textStyle).scaledFont(for: font)
    }
    return UIFontMetrics(forTextStyle: textStyle)
      .scaledFont(for: UIFont(descriptor: descriptor, size: pointSize))
  }
}

struct AppearanceFontPickerGroup: Identifiable, Hashable {
  let id: String
  let displayName: String
  let faces: [AppearanceFontPickerFace]

  func preferredFace(currentFontName: String?) -> AppearanceFontPickerFace? {
    if let currentFontName, let currentFace = faces.first(where: { $0.fontName == currentFontName })
    {
      return currentFace
    }
    return faces.first { $0.displayName.localizedCaseInsensitiveCompare("Regular") == .orderedSame }
      ?? faces.first { $0.fontName == displayName }
      ?? faces.first
  }
}

struct AppearanceFontPickerFace: Identifiable, Hashable {
  var id: String { fontName }
  let fontName: String
  let displayName: String
}

extension AppearanceTint {
  var color: Color? {
    switch self {
    case .system: nil
    case .blue: .blue
    case .purple: .purple
    case .pink: Color(red: 1.0, green: 0.45, blue: 0.72)
    case .red: .red
    case .orange: .orange
    case .yellow: .yellow
    case .green: .green
    case .mint: .mint
    case .teal: .teal
    case .cyan: .cyan
    case .indigo: .indigo
    }
  }

  var swatchColor: Color {
    color ?? .accentColor
  }
}

extension ConversationFolderTint {
  var color: Color? {
    switch self {
    case .preset(let tint): tint.color
    case .custom(let hex): Color(folderTintHex: hex)
    }
  }

  var swatchColor: Color {
    color ?? .accentColor
  }
}

extension Color {
  init?(folderTintHex hex: String) {
    guard let normalized = ConversationFolderTint.normalizedHex(hex),
      let value = UInt64(normalized.dropFirst(), radix: 16)
    else {
      return nil
    }
    self.init(
      red: Double((value >> 16) & 0xFF) / 255,
      green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255)
  }

  /// `#RRGGBB` for the resolved color, so a picked color can be persisted.
  var folderTintHex: String? {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
      return nil
    }
    let channel = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
    return String(format: "#%02X%02X%02X", channel(red), channel(green), channel(blue))
  }
}

extension AppStore {
  /// The accent color to paint the app with: the selected folder wins over the app tint.
  var effectiveTintColor: Color? {
    selectedConversationFolder.tint?.color ?? settings.appearance.tintColor
  }
}

extension AppearanceTheme {
  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}
