/// The dashboard's cookie-authenticated HTTP surface.
///
/// Hermes' dashboard authenticates with cookies a WebView holds, so requests
/// to it have to be issued from inside that WebView rather than from a Dart
/// HTTP client. That makes the implementation inescapably Flutter — it drives
/// `flutter_inappwebview` — while everything that *uses* it is ordinary
/// transport code.
///
/// So the interface lives here and the host supplies the implementation. A
/// host with no WebView registers nothing, and the dashboard paths report
/// that they are unavailable rather than failing in a way callers cannot
/// interpret.
abstract interface class HermesDashboardBridge {
  /// Issues [method] against [url] from inside the authenticated context.
  Future<({int status, String body})> request(
    String method,
    Uri url, {
    String? body,
  });

  /// Reloads the dashboard, re-establishing cookies after a 401 or 403.
  Future<void> reload();

  Future<void> close();
}

/// Builds a [HermesDashboardBridge] for one Hermes deployment.
typedef HermesDashboardBridgeFactory = HermesDashboardBridge Function({
  required Uri root,
});
