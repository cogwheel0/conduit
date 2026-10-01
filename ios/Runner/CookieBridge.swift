import Flutter
import Foundation
import WebKit

/// Matches an HTTP cookie using its host-only/domain scope, Secure attribute,
/// and RFC 6265 path boundary rules.
func cookieMatchesUrl(cookie: HTTPCookie, url: URL) -> Bool {
    guard let host = url.host?.lowercased(), !host.isEmpty else {
        return false
    }

    if cookie.isSecure && url.scheme?.lowercased() != "https" {
        return false
    }

    let rawDomain = cookie.domain.lowercased()
    let isDomainCookie = rawDomain.hasPrefix(".")
    let cookieHost = isDomainCookie
        ? String(rawDomain.dropFirst())
        : rawDomain
    guard !cookieHost.isEmpty else { return false }

    if isDomainCookie {
        guard host == cookieHost || host.hasSuffix(".\(cookieHost)") else {
            return false
        }
    } else if host != cookieHost {
        return false
    }

    // RFC 6265 compares the request-target path as encoded octets. `URL.path`
    // decodes `%2F` into `/`, which would incorrectly broaden `/admin` to
    // match a request for `/admin%2Fpublic`.
    let encodedPath = URLComponents(
        url: url,
        resolvingAgainstBaseURL: false
    )?.percentEncodedPath ?? ""
    let requestPath = encodedPath.isEmpty ? "/" : encodedPath
    let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
    guard requestPath.hasPrefix(cookiePath) else { return false }
    if requestPath == cookiePath || cookiePath.hasSuffix("/") {
        return true
    }

    let boundary = requestPath.index(
        requestPath.startIndex,
        offsetBy: cookiePath.count
    )
    return requestPath[boundary] == "/"
}

/// Collapses matching cookies to the name/value map expected by Dart.
///
/// WKHTTPCookieStore does not promise a useful order. Prefer the cookie with
/// the longest matching path for duplicate names, then apply stable scope and
/// lexical tie-breakers so store enumeration order cannot change the result.
func cookieValuesForUrl(cookies: [HTTPCookie], url: URL) -> [String: String] {
    var selected: [String: HTTPCookie] = [:]
    for cookie in cookies where cookieMatchesUrl(cookie: cookie, url: url) {
        guard let current = selected[cookie.name] else {
            selected[cookie.name] = cookie
            continue
        }
        if cookieIsPreferred(candidate: cookie, over: current) {
            selected[cookie.name] = cookie
        }
    }
    return selected.mapValues(\.value)
}

private func cookieIsPreferred(
    candidate: HTTPCookie,
    over current: HTTPCookie
) -> Bool {
    let candidatePath = candidate.path.isEmpty ? "/" : candidate.path
    let currentPath = current.path.isEmpty ? "/" : current.path
    if candidatePath.utf8.count != currentPath.utf8.count {
        return candidatePath.utf8.count > currentPath.utf8.count
    }

    let candidateHostOnly = !candidate.domain.hasPrefix(".")
    let currentHostOnly = !current.domain.hasPrefix(".")
    if candidateHostOnly != currentHostOnly {
        return candidateHostOnly
    }

    if candidate.isSecure != current.isSecure {
        return candidate.isSecure
    }

    let candidateDomain = candidate.domain.lowercased()
    let currentDomain = current.domain.lowercased()
    if candidateDomain.utf8.count != currentDomain.utf8.count {
        return candidateDomain.utf8.count > currentDomain.utf8.count
    }
    if candidatePath != currentPath {
        return candidatePath < currentPath
    }
    if candidateDomain != currentDomain {
        return candidateDomain < currentDomain
    }
    return candidate.value < current.value
}

/// Reads the WebView cookie store for Dart, which cannot see it directly.
final class CookieBridge: ConduitBridge {
  static let shared = CookieBridge()

  private var cookieChannel: FlutterMethodChannel?

  private init() {}

  func attach(to host: ConduitBridgeHost) {
    let cookieChannel = FlutterMethodChannel(
      name: "com.conduit.app/cookies",
      binaryMessenger: host.messenger
    )
    self.cookieChannel = cookieChannel

    cookieChannel.setMethodCallHandler { (call, result) in
      if call.method == "getCookies" {
        guard let args = call.arguments as? [String: Any],
              let urlString = args["url"] as? String,
              let url = URL(string: urlString) else {
          result(FlutterError(code: "INVALID_ARGS", message: "Invalid URL", details: nil))
          return
        }

        // Get cookies from WKWebView's cookie store
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
          result(cookieValuesForUrl(cookies: cookies, url: url))
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
