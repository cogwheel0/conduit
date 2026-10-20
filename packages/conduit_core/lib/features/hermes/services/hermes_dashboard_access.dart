/// Whether Hermes' dashboard can be reached on this platform.
///
/// Split from the WebView policy so the transport layer can ask the question
/// without importing `flutter_inappwebview`. The rule itself is one line and
/// has nothing to do with WebViews; it is about which platform can carry
/// gateway headers to the dashboard.
library;

/// Whether the dashboard may be reached with gateway access headers.
///
/// Takes bools rather than Flutter's `TargetPlatform` so callers outside the
/// widget layer can ask: the question is "is this iOS", and, where the
/// headers go through a page script, whether the WebView can run a script
/// before the page's own ([documentStartScripts]; Android WebViews without
/// the document-start feature cannot, and a script that runs late could be
/// shadowed by page code that replaced `fetch` first). The REST client that
/// needs the answer has no business importing Flutter to phrase it.
bool hermesDashboardHeadersSupported({
  required bool isIOS,
  required Map<String, String> accessHeaders,
  bool documentStartScripts = true,
}) => accessHeaders.isEmpty || (!isIOS && documentStartScripts);
