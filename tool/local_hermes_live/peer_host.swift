// Runs the fake GPT-Live voice's peer page (fake_gpt_live.py's /peer) in a
// WKWebView of its own, out of sight: no Dock icon, no window shown, never
// the microphone or the camera. The page answers the app's offers with
// WebKit's WebRTC, as GPT-Live's servers would.
//
//   swiftc -O -o peer-host peer_host.swift -framework AppKit -framework WebKit
//   ./peer-host http://127.0.0.1:19335/peer
//
// Runs until it is killed, or until the page's server has been gone a while.
import AppKit
import WebKit

/// Sets a private WKPreferences switch where this WebKit has it.
func setSwitch(_ object: NSObject, _ name: String, _ value: Bool) {
  let selector = NSSelectorFromString(name)
  guard object.responds(to: selector) else {
    FileHandle.standardError.write("peer-host: no \(name)\n".data(using: .utf8)!)
    return
  }
  typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
  let setter = unsafeBitCast(object.method(for: selector), to: Setter.self)
  setter(object, selector, value)
}

final class Host: NSObject, NSApplicationDelegate, WKUIDelegate, WKNavigationDelegate {
  let url: URL
  var window: NSWindow?
  var web: WKWebView?
  var misses = 0
  var activity: NSObjectProtocol?

  init(url: URL) {
    self.url = url
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.mediaTypesRequiringUserActionForPlayback = []
    // No mDNS names for its candidates (they would be registered on the
    // local network); with the vendor's relay it uses only 127.0.0.1.
    setSwitch(configuration.preferences, "_setICECandidateFilteringEnabled:", false)
    // Never shown, yet never suspended: WebKit would stop a hidden page a few
    // seconds in, and App Nap the process.
    setSwitch(configuration.preferences, "_setPageVisibilityBasedProcessSuppressionEnabled:", false)
    setSwitch(configuration.preferences, "_setHiddenPageDOMTimerThrottlingEnabled:", false)
    activity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiated, .latencyCritical], reason: "Fake GPT-Live peer")
    let web = WKWebView(
      frame: NSRect(x: 0, y: 0, width: 8, height: 8), configuration: configuration)
    web.uiDelegate = self
    web.navigationDelegate = self
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 8, height: 8), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = web
    self.window = window
    self.web = web
    web.load(URLRequest(url: url))
    // Gone with its server.
    Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      self?.checkServer()
    }
  }

  func checkServer() {
    var request = URLRequest(url: url.deletingLastPathComponent().appendingPathComponent("stats"))
    request.timeoutInterval = 3
    URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
      DispatchQueue.main.async {
        guard let self else { return }
        if (response as? HTTPURLResponse)?.statusCode == 200 {
          self.misses = 0
        } else {
          self.misses += 1
          if self.misses >= 6 { NSApp.terminate(nil) }
        }
      }
    }.resume()
  }

  // Never the microphone or the camera.
  func webView(
    _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
    initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
    decisionHandler: @escaping (WKPermissionDecision) -> Void
  ) {
    decisionHandler(.deny)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    webView.load(URLRequest(url: url))
  }
}

guard CommandLine.arguments.count > 1, let url = URL(string: CommandLine.arguments[1]) else {
  FileHandle.standardError.write("usage: peer-host <page url>\n".data(using: .utf8)!)
  exit(64)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let host = Host(url: url)
app.delegate = host
app.run()
