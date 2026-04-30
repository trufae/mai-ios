import SwiftUI
import UIKit

extension AppearanceSettings {
  var swiftUIFont: Font {
    fontFamily.swiftUIFont(size: fontSize)
  }

  var uiFont: UIFont {
    fontFamily.uiFont(size: fontSize)
  }

  var codeFont: Font {
    .system(size: max(11, fontSize - 1), design: .monospaced)
  }

  var tintColor: Color? {
    tint.color
  }
}

extension AppearanceFontFamily {
  static var pickerOptions: [AppearanceFontFamily] {
    let builtIns: [AppearanceFontFamily] = [.system, .serif, .rounded, .monospaced]
    let installed = UIFont.familyNames
      .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
      .flatMap { familyName in
        UIFont.fontNames(forFamilyName: familyName)
          .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
          .map(AppearanceFontFamily.installed)
      }
    return builtIns + installed
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

extension AppearanceTint {
  var color: Color? {
    switch self {
    case .system: nil
    case .blue: .blue
    case .purple: .purple
    case .pink: .pink
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
