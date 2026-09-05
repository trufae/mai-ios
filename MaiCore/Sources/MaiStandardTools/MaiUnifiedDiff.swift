import Foundation

enum MaiUnifiedDiff {
  private enum Kind {
    case context
    case removal
    case addition

    var marker: Character {
      switch self {
      case .context: " "
      case .removal: "-"
      case .addition: "+"
      }
    }
  }

  private struct Line {
    let kind: Kind
    let text: String
    let oldPosition: Int
    let newPosition: Int

    var consumesOld: Bool { kind != .addition }
    var consumesNew: Bool { kind != .removal }
  }

  static func render(old: String, new: String, path: String, context: Int = 3) -> String {
    guard old != new else { return "" }
    let oldLines = lines(old)
    let newLines = lines(new)
    let difference = newLines.difference(from: oldLines)
    let removals = Set(
      difference.removals.map { change in
        guard case .remove(let offset, _, _) = change else { return 0 }
        return offset
      })
    let additions = Set(
      difference.insertions.map { change in
        guard case .insert(let offset, _, _) = change else { return 0 }
        return offset
      })
    var operations: [Line] = []
    var oldIndex = 0
    var newIndex = 0
    while oldIndex < oldLines.count || newIndex < newLines.count {
      if oldIndex < oldLines.count, removals.contains(oldIndex) {
        operations.append(
          Line(
            kind: .removal,
            text: oldLines[oldIndex],
            oldPosition: oldIndex + 1,
            newPosition: newIndex + 1))
        oldIndex += 1
      } else if newIndex < newLines.count, additions.contains(newIndex) {
        operations.append(
          Line(
            kind: .addition,
            text: newLines[newIndex],
            oldPosition: oldIndex + 1,
            newPosition: newIndex + 1))
        newIndex += 1
      } else if oldIndex < oldLines.count, newIndex < newLines.count {
        operations.append(
          Line(
            kind: .context,
            text: oldLines[oldIndex],
            oldPosition: oldIndex + 1,
            newPosition: newIndex + 1))
        oldIndex += 1
        newIndex += 1
      } else if oldIndex < oldLines.count {
        operations.append(
          Line(
            kind: .removal,
            text: oldLines[oldIndex],
            oldPosition: oldIndex + 1,
            newPosition: newIndex + 1))
        oldIndex += 1
      } else {
        operations.append(
          Line(
            kind: .addition,
            text: newLines[newIndex],
            oldPosition: oldIndex + 1,
            newPosition: newIndex + 1))
        newIndex += 1
      }
    }

    let context = max(0, context)
    let changed = operations.indices.filter { operations[$0].kind != .context }
    var hunks: [Range<Int>] = []
    for index in changed {
      let range = max(0, index - context)..<min(operations.count, index + context + 1)
      if let last = hunks.last, range.lowerBound <= last.upperBound {
        hunks[hunks.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
      } else {
        hunks.append(range)
      }
    }

    var rendered = ["--- a/\(path)", "+++ b/\(path)"]
    for hunk in hunks {
      let selected = operations[hunk]
      guard let first = selected.first else { continue }
      let oldCount = selected.reduce(0) { $0 + ($1.consumesOld ? 1 : 0) }
      let newCount = selected.reduce(0) { $0 + ($1.consumesNew ? 1 : 0) }
      rendered.append(
        "@@ -\(range(first.oldPosition, oldCount)) +\(range(first.newPosition, newCount)) @@")
      rendered.append(contentsOf: selected.map { String($0.kind.marker) + $0.text })
    }
    return rendered.joined(separator: "\n")
  }

  private static func lines(_ text: String) -> [String] {
    guard !text.isEmpty else { return [] }
    var result = text.components(separatedBy: "\n")
    if result.last == "" { result.removeLast() }
    return result
  }

  private static func range(_ start: Int, _ count: Int) -> String {
    count == 1 ? String(start) : "\(count == 0 ? max(0, start - 1) : start),\(count)"
  }
}
