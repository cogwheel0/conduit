/// Whether Hermes' dashboard can be reached on this platform.
///
/// Split from the WebView policy so the transport layer can ask the question
/// without importing `flutter_inappwebview`. The rule itself is one line and
/// has nothing to do with WebViews; it is about which platform can carry
/// gateway headers to the dashboard.
library;

/// Whether the dashboard may be reached with gateway access headers.
///
/// Takes a bool rather than Flutter's `TargetPlatform` so callers outside the
/// widget layer can ask: the question is only ever "is this iOS", and the
/// REST client that needs the answer has no business importing Flutter to
/// phrase it.
bool hermesDashboardHeadersSupported({
  required bool isIOS,
  required Map<String, String> accessHeaders,
}) => !isIOS || accessHeaders.isEmpty;
