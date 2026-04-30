import SwiftUI

@main
struct PocketMaiApp: App {
  @StateObject private var store = AppStore()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(store)
        .environmentObject(store.streamingTextStore)
    }
  }
}
