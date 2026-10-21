import AuthenticationServices
import Flutter
import UIKit

/// The redirect a browser sign-in must end on, matched exactly.
private struct BrowserAuthRedirect {
  let scheme: String
  let host: String
  let path: String

  init?(_ request: PlatformBrowserAuthRequest) {
    let scheme = request.callbackScheme.lowercased()
    guard
      !scheme.isEmpty,
      scheme != "http",
      scheme != "https",
      scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }),
      request.callbackPath.hasPrefix("/")
    else { return nil }
    self.scheme = scheme
    host = request.callbackHost.lowercased()
    path = request.callbackPath
  }

  /// Only a query may follow the redirect: no port, user, password or
  /// fragment, and the same scheme, host and path.
  func matches(_ url: URL) -> Bool {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == scheme,
      (components.host ?? "").lowercased() == host,
      components.path == path,
      components.port == nil,
      components.user == nil,
      components.password == nil,
      components.fragment == nil
    else { return false }
    return true
  }
}

/// Runs a sign-in page in `ASWebAuthenticationSession`, where passkeys and
/// security keys work, and returns the redirect it ends on.
///
/// The session shares Safari's cookies, so a provider the user already
/// signed in to does not ask again. It hands only the matching redirect
/// back to the app, never through the scene's URL routing. Every ending
/// completes Dart's call exactly once, and nothing here logs a URL: the
/// redirect carries a one-time code.
final class BrowserAuthBridge: NSObject, ConduitBridge, BrowserAuthHostApi,
  ASWebAuthenticationPresentationContextProviding
{
  static let shared = BrowserAuthBridge()

  private weak var host: ConduitBridgeHost?
  private var session: ASWebAuthenticationSession?
  private var completion: ((Result<PlatformBrowserAuthResult, Error>) -> Void)?
  /// Tells a late session callback from the sign-in it belonged to.
  private var flowId = 0

  private override init() {}

  func attach(to host: ConduitBridgeHost) {
    self.host = host
    BrowserAuthHostApiSetup.setUp(binaryMessenger: host.messenger, api: self)
  }

  /// Whether `url` is the default sign-in redirect arriving through URL
  /// routing instead of the session: a stale or forged link the app
  /// ignores.
  static func isStrayCallback(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "conduit"
      && url.host?.lowercased() == "oauth"
      && url.path == "/callback"
  }

  // MARK: - BrowserAuthHostApi

  func authenticate(
    request: PlatformBrowserAuthRequest,
    completion: @escaping (Result<PlatformBrowserAuthResult, Error>) -> Void
  ) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.start(request, completion: completion)
    }
  }

  func cancel() throws {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let session = self.session
      self.finish(self.flowId, .cancelled)
      session?.cancel()
    }
  }

  // MARK: - Flow

  private func start(
    _ request: PlatformBrowserAuthRequest,
    completion: @escaping (Result<PlatformBrowserAuthResult, Error>) -> Void
  ) {
    guard
      let url = URL(string: request.authorizationUrl),
      let scheme = url.scheme?.lowercased(),
      scheme == "https" || scheme == "http",
      url.host?.isEmpty == false,
      let redirect = BrowserAuthRedirect(request)
    else {
      completion(.success(BrowserAuthEnding.failed("invalid_request").result))
      return
    }

    if self.completion != nil {
      let previous = session
      finish(flowId, .failed("superseded"))
      previous?.cancel()
    }

    flowId += 1
    let id = flowId
    self.completion = completion

    let handler: (URL?, Error?) -> Void = { [weak self] callbackURL, error in
      DispatchQueue.main.async {
        self?.sessionEnded(id, redirect: redirect, callbackURL: callbackURL, error: error)
      }
    }
    let session: ASWebAuthenticationSession
    if #available(iOS 17.4, *) {
      session = ASWebAuthenticationSession(
        url: url,
        callback: .customScheme(redirect.scheme),
        completionHandler: handler
      )
    } else {
      session = ASWebAuthenticationSession(
        url: url,
        callbackURLScheme: redirect.scheme,
        completionHandler: handler
      )
    }
    session.presentationContextProvider = self
    session.prefersEphemeralWebBrowserSession = request.preferEphemeralSession
    self.session = session

    guard session.start() else {
      finish(id, .failed("presentation_failed"))
      return
    }
  }

  private func sessionEnded(
    _ id: Int,
    redirect: BrowserAuthRedirect,
    callbackURL: URL?,
    error: Error?
  ) {
    if let error {
      switch (error as? ASWebAuthenticationSessionError)?.code {
      case .some(.canceledLogin):
        finish(id, .cancelled)
      case .some(.presentationContextNotProvided), .some(.presentationContextInvalid):
        finish(id, .failed("presentation_failed"))
      default:
        finish(id, .failed("start_failed"))
      }
      return
    }
    guard let callbackURL, redirect.matches(callbackURL) else {
      finish(id, .failed("unexpected_callback"))
      return
    }
    finish(id, .success(callbackURL.absoluteString))
  }

  /// Completes sign-in `id` once; a later ending for it, or one for a
  /// sign-in already replaced, is dropped.
  private func finish(_ id: Int, _ ending: BrowserAuthEnding) {
    guard id == flowId, let completion else { return }
    self.completion = nil
    session = nil
    completion(.success(ending.result))
  }

  // MARK: - ASWebAuthenticationPresentationContextProviding

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    if let window = host?.presentingViewController?.view.window {
      return window
    }
    if let scene = host?.activeWindowScene {
      if let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
        return window
      }
      return ASPresentationAnchor(windowScene: scene)
    }
    // No window to show over: the session reports
    // `presentationContextInvalid`, which ends the sign-in as failed.
    return ASPresentationAnchor()
  }
}

/// How a sign-in ended, before it is sent to Dart.
private enum BrowserAuthEnding {
  case success(String)
  case cancelled
  case failed(String)

  private static let channel = "web_authentication_session"

  var result: PlatformBrowserAuthResult {
    switch self {
    case .success(let callbackUrl):
      return PlatformBrowserAuthResult(
        outcome: .success,
        callbackUrl: callbackUrl,
        channel: Self.channel
      )
    case .cancelled:
      return PlatformBrowserAuthResult(outcome: .cancelled, channel: Self.channel)
    case .failed(let code):
      return PlatformBrowserAuthResult(
        outcome: .failed,
        errorCode: code,
        channel: Self.channel
      )
    }
  }
}
