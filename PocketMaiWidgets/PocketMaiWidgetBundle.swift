import SwiftUI
import WidgetKit

@main
struct PocketMaiWidgetBundle: WidgetBundle {
  var body: some Widget {
    PromptWidget()
    VoiceWidget()
  }
}
