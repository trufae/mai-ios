import SwiftUI

@main
struct PocketMaiApp: App {
  @StateObject private var store = AppStore()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(store)
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        store.refreshAppleAvailability()
      }
    }
  }
}
