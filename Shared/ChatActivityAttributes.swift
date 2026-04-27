import ActivityKit
import Foundation

struct ChatActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var status: String
    var preview: String
    var tokenCount: Int
  }

  var conversationID: String
  var title: String
}
