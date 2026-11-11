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
  ///
  /// Requests run one at a time, in order. An [urgent] one runs at once on a
  /// context that is already open instead: for a request whose order does
  /// not matter and that must not wait behind a long one, such as a Stop
  /// behind the Run now it stops (Hermes answers that only once the run
  /// ends).
  ///
  /// [beforeSend] runs right before the request is sent: false drops it
  /// unsent, failing it with [HermesDashboardRequestWithdrawn]. A request
  /// still waiting in the queue can so be withdrawn, such as a Run now its
  /// Stop overtook.
  Future<({int status, String body})> request(
    String method,
    Uri url, {
    String? body,
    bool urgent = false,
    bool Function()? beforeSend,
  });

  /// Reloads the dashboard, re-establishing cookies after a 401 or 403.
  Future<void> reload();

  Future<void> close();
}

/// Builds a [HermesDashboardBridge] for one Hermes deployment: its dashboard
/// [root] and the gateway [accessHeaders] of the same configuration. Both
/// come from the service that asks, never from whatever configuration the
/// host holds at that moment, so one server's headers never reach another's
/// dashboard.
typedef HermesDashboardBridgeFactory = HermesDashboardBridge Function({
  required Uri root,
  required Map<String, String> accessHeaders,
});

/// The dashboard can't be reached from this device at all: its gateway
/// access headers can't be added safely here (iOS, or an Android WebView
/// without document-start scripts). Signing in again can't change that.
///
/// A [StateError], as before, for callers that only tell sign-in problems
/// apart from network ones.
final class HermesDashboardUnavailable extends StateError {
  HermesDashboardUnavailable(super.message);
}

/// A dashboard request withdrawn before it was sent: Hermes never saw it.
final class HermesDashboardRequestWithdrawn implements Exception {
  const HermesDashboardRequestWithdrawn();

  @override
  String toString() => 'The Hermes dashboard request was withdrawn unsent.';
}

/// Signs one Hermes deployment's dashboard session out on the server, from
/// a page on its dashboard [root], with the gateway [accessHeaders] of the
/// same configuration: Hermes ends the session and deletes its own cookies,
/// which only it can tell from another gateway's on the same host. True when
/// Hermes signed it out. A host with no WebView registers none.
typedef HermesDashboardSignOut =
    Future<bool> Function({
      required Uri root,
      required Map<String, String> accessHeaders,
    });
