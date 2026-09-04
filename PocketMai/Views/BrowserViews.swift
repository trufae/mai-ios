import SwiftUI
import WebKit

/// Hosts the session's web view at its fixed viewport size and scales it to
/// whatever frame SwiftUI provides, so the page layout and the coordinates the
/// model works with stay the same in the card and in the expanded view.
struct BrowserWebViewHost: UIViewRepresentable {
  let session: BrowserSession
  let interactive: Bool

  func makeUIView(context: Context) -> BrowserHostView {
    BrowserHostView()
  }

  func updateUIView(_ view: BrowserHostView, context: Context) {
    view.adopt(session.webView, viewportSize: session.viewportSize, interactive: interactive)
  }
}

final class BrowserHostView: UIView {
  private weak var webView: WKWebView?
  private var viewportSize: CGSize = .zero

  func adopt(_ webView: WKWebView, viewportSize: CGSize, interactive: Bool) {
    self.viewportSize = viewportSize
    if webView.superview !== self {
      addSubview(webView)
    }
    self.webView = webView
    webView.isUserInteractionEnabled = interactive
    clipsToBounds = true
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard let webView, viewportSize.width > 0, viewportSize.height > 0,
      bounds.width > 0, bounds.height > 0
    else {
      return
    }
    let scale = min(bounds.width / viewportSize.width, bounds.height / viewportSize.height)
    webView.transform = .identity
    webView.frame = CGRect(origin: .zero, size: viewportSize)
    webView.transform = CGAffineTransform(scaleX: scale, y: scale)
    webView.center = CGPoint(x: bounds.midX, y: bounds.midY)
  }
}

/// The picture-in-picture card: a live, scaled-down view of the page that can
/// be dragged around the chat. Tapping it opens the page full size.
struct BrowserPiPCard: View {
  @ObservedObject var session: BrowserSession
  let onClose: () -> Void

  @State private var dragTranslation: CGSize = .zero
  @State private var restingOffset: CGSize = .zero

  private let cardSize = CGSize(width: 150, height: 232)
  private let captionHeight: CGFloat = 26

  var body: some View {
    VStack(spacing: 0) {
      BrowserWebViewHost(session: session, interactive: false)
        .frame(width: cardSize.width, height: cardSize.height - captionHeight)
        .allowsHitTesting(false)
      HStack(spacing: 5) {
        if session.isLoading {
          ProgressView()
            .controlSize(.mini)
        } else {
          Image(systemName: "safari")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Text(session.displayHost)
          .font(.caption2)
          .lineLimit(1)
        Spacer(minLength: 0)
        Image(systemName: "arrow.up.left.and.arrow.down.right")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 8)
      .frame(height: captionHeight)
      .background(.thinMaterial)
    }
    .frame(width: cardSize.width, height: cardSize.height)
    .background(Color(uiColor: .systemBackground))
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(.quaternary)
    )
    .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
    .overlay(alignment: .topTrailing) {
      Button(action: onClose) {
        Image(systemName: "xmark.circle.fill")
          .font(.title3)
          .symbolRenderingMode(.palette)
          .foregroundStyle(.white, .black.opacity(0.55))
      }
      .buttonStyle(.plain)
      .padding(4)
      .accessibilityLabel("Close browser")
    }
    .contentShape(Rectangle())
    .onTapGesture {
      session.isExpanded = true
    }
    .offset(
      x: restingOffset.width + dragTranslation.width,
      y: restingOffset.height + dragTranslation.height
    )
    .gesture(
      DragGesture(minimumDistance: 6)
        .onChanged { value in
          dragTranslation = value.translation
        }
        .onEnded { value in
          restingOffset.width += value.translation.width
          restingOffset.height += value.translation.height
          dragTranslation = .zero
        }
    )
    .fullScreenCover(isPresented: $session.isExpanded) {
      BrowserExpandedView(session: session, onClose: onClose)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Browser preview of \(session.displayHost). Tap to expand.")
  }
}

/// Full-size, hand-operated presentation of the page.
struct BrowserExpandedView: View {
  @ObservedObject var session: BrowserSession
  let onClose: () -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var addressText = ""
  @FocusState private var addressFocused: Bool

  var body: some View {
    NavigationStack {
      BrowserWebViewHost(session: session, interactive: true)
        .background(Color(uiColor: .systemBackground))
        .safeAreaInset(edge: .top, spacing: 0) {
          addressBar
        }
        .navigationTitle(session.title.isEmpty ? "Browser" : session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button {
              dismiss()
            } label: {
              Label("Minimize", systemImage: "pip.exit")
            }
            .help("Back to the small card")
          }
          ToolbarItem(placement: .topBarTrailing) {
            Button(role: .destructive) {
              dismiss()
              // Let the cover finish dismissing before the card that presents it goes away.
              Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                onClose()
              }
            } label: {
              Label("Close", systemImage: "xmark")
            }
            .help("Close the browser")
          }
        }
    }
    .onAppear {
      addressText = session.currentURL?.absoluteString ?? ""
    }
    .onChange(of: session.currentURL) { _, url in
      guard !addressFocused else { return }
      addressText = url?.absoluteString ?? ""
    }
  }

  private var addressBar: some View {
    HStack(spacing: 8) {
      Button {
        Task { await session.goBack() }
      } label: {
        Image(systemName: "chevron.left")
      }
      .disabled(!session.canGoBack)
      Button {
        session.goForward()
      } label: {
        Image(systemName: "chevron.right")
      }
      .disabled(!session.canGoForward)
      TextField("Address", text: $addressText)
        .textFieldStyle(.roundedBorder)
        .keyboardType(.URL)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.go)
        .focused($addressFocused)
        .onSubmit {
          session.load(urlString: addressText)
          addressFocused = false
        }
      if session.isLoading {
        ProgressView()
          .controlSize(.small)
      } else {
        Button {
          session.reload()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.bar)
  }
}
