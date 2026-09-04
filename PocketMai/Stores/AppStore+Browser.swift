import UIKit

extension AppStore {
  /// The single in-app browser page, created on the first tool call and kept
  /// until the user closes the card.
  func ensureBrowserSession() -> BrowserSession {
    if let browserSession {
      return browserSession
    }
    let session = BrowserSession(viewportSize: Self.browserViewportSize())
    browserSession = session
    return session
  }

  func closeBrowserSession() {
    browserSession?.tearDown()
    browserSession = nil
  }

  /// A phone-sized page regardless of how small the card is drawn. The height
  /// leaves room for the expanded view's bars so it shows the page 1:1.
  private static func browserViewportSize() -> CGSize {
    let screen =
      UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first?.screen.bounds.size ?? CGSize(width: 390, height: 844)
    return CGSize(width: screen.width, height: max(500, screen.height - 150))
  }
}
