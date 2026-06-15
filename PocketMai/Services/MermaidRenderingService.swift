import BeautifulMermaid
import CoreGraphics
import Foundation
import UIKit

enum MarkdownMermaidRenderStyle: String, Hashable, Sendable {
  case light
  case dark
}

struct MarkdownMermaidRenderedPNG: Sendable {
  let data: Data
  let width: Int
  let height: Int

  var aspectRatio: CGSize {
    CGSize(width: max(width, 1), height: max(height, 1))
  }

  var displayWidth: CGFloat {
    CGFloat(min(max(width, 180), 680))
  }
}

enum MarkdownMermaidRenderer {
  static func isMermaidLanguage(_ raw: String) -> Bool {
    let language =
      raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard !language.isEmpty else { return false }

    let firstToken =
      language
      .split(whereSeparator: { $0.isWhitespace })
      .first
      .map(String.init) ?? language

    return firstToken == "mermaid" || firstToken == "mmd" || firstToken == "{.mermaid}"
      || firstToken == "language-mermaid"
  }

  static func normalizedSource(_ source: String) -> String {
    source.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func renderedPNG(
    source: String,
    style: MarkdownMermaidRenderStyle,
    scale: Double = 2.0
  ) throws -> MarkdownMermaidRenderedPNG? {
    let normalized = normalizedSource(source)
    guard !normalized.isEmpty else { return nil }

    let renderer = MermaidImageRenderer(theme: theme(for: style))
    renderer.scale = CGFloat(max(1.0, min(scale, 4.0)))
    guard let image = try renderer.renderImage(from: normalized),
      let data = image.pngData()
    else {
      return nil
    }

    let width = image.cgImage?.width ?? Int((image.size.width * image.scale).rounded())
    let height = image.cgImage?.height ?? Int((image.size.height * image.scale).rounded())
    return MarkdownMermaidRenderedPNG(
      data: data,
      width: max(width, 1),
      height: max(height, 1))
  }

  private static func theme(for style: MarkdownMermaidRenderStyle) -> DiagramTheme {
    switch style {
    case .light:
      return .githubLight
    case .dark:
      return .githubDark
    }
  }
}

actor MarkdownMermaidRenderCache {
  static let shared = MarkdownMermaidRenderCache()

  private struct Key: Hashable {
    let source: String
    let style: MarkdownMermaidRenderStyle
    let scaleKey: Int
  }

  private var renderedByKey: [Key: MarkdownMermaidRenderedPNG] = [:]
  private var accessOrder: [Key] = []
  private let maxEntries = 48

  func renderedPNG(
    source: String,
    style: MarkdownMermaidRenderStyle,
    scale: Double = 2.0
  ) async throws -> MarkdownMermaidRenderedPNG? {
    let normalized = MarkdownMermaidRenderer.normalizedSource(source)
    let scale = max(1.0, min(scale, 4.0))
    let key = Key(
      source: normalized,
      style: style,
      scaleKey: Int((scale * 100).rounded()))

    if let rendered = renderedByKey[key] {
      markAccessed(key)
      return rendered
    }

    let rendered = try await Task.detached(priority: .userInitiated) {
      try MarkdownMermaidRenderer.renderedPNG(
        source: normalized,
        style: style,
        scale: scale)
    }.value

    if let rendered {
      renderedByKey[key] = rendered
      markAccessed(key)
      trimCache()
    }
    return rendered
  }

  private func markAccessed(_ key: Key) {
    accessOrder.removeAll { $0 == key }
    accessOrder.append(key)
  }

  private func trimCache() {
    while accessOrder.count > maxEntries, let oldest = accessOrder.first {
      accessOrder.removeFirst()
      renderedByKey.removeValue(forKey: oldest)
    }
  }
}
