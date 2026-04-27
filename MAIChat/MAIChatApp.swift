import SwiftUI

@main
struct MAIChatApp: App {
  @StateObject private var store = AppStore()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(store)
    }
  }
}
