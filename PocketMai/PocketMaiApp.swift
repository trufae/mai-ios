import SwiftUI

@main
struct PocketMaiApp: App {
  @StateObject private var store = AppStore()
  @StateObject private var ttsPlayer = TTSPlayer.shared

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(store)
        .environmentObject(store.streamingTextStore)
        .environmentObject(ttsPlayer)
    }
  }
}
