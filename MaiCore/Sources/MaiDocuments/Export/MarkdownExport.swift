import Foundation

/// The conversation as one markdown file: a title, the dates, and a section
/// per entry with hidden reasoning quoted above the reply.
public enum MarkdownExport {
  public static func text(for document: ExportDocument) -> String {
    let summary = document.summary
    var sections = ["# \(summary.title)"]
    sections.append(
      "Started \(summary.started) · Last updated \(summary.lastUpdated) · \(summary.messageCount)")
    for entry in document.exportedEntries {
      var parts = ["## \(entry.role.displayName)"]
      for section in entry.reasoning {
        let trimmed = section.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        let quoted = trimmed.components(separatedBy: "\n")
          .map { $0.isEmpty ? ">" : "> \($0)" }
          .joined(separator: "\n")
        parts.append("> **Reasoning**\n>\n\(quoted)")
      }
      let body = entry.body.trimmingCharacters(in: .whitespacesAndNewlines)
      if !body.isEmpty { parts.append(body) }
      for image in entry.attachments {
        parts.append("*Attached image: \(image.name)*")
      }
      sections.append(parts.joined(separator: "\n\n"))
    }
    return sections.joined(separator: "\n\n") + "\n"
  }
}
