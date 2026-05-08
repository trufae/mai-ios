enum ToolCallingMode: String, CaseIterable {
  case text
  case xml
  case json
  case native

  var displayName: String {
    switch self {
    case .text: "Text"
    case .xml: "XML"
    case .json: "JSON"
    case .native: "Native"
    }
  }

  var textProtocolFallback: ToolCallingMode {
    self == .native ? .text : self
  }
}
