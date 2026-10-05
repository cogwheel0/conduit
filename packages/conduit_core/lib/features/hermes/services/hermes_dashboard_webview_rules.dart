/// The pure rules of the Hermes dashboard WebView: where its pages live,
/// which navigations it may follow, and which requests carry the gateway's
/// access headers (Cloudflare Access and similar).
///
/// The WebView glue (flutter_inappwebview) stays in the app; only these
/// decisions live here, where they are tested without a WebView.
library;

import 'package:conduit_core/auth/webview_origin.dart';

/// The dashboard's session cookies. They are kept in the sign-in registry
/// even when the WebView held them before the sign-in began (an automatic
/// sign-in refreshes them in place).
const Set<String> kHermesDashboardRetainedCookieNames = {
  'hermes_session_at',
  'hermes_session_pkce',
  'hermes_session_rt',
  'hermes_session_provider',
};

/// The dashboard root for a configured Hermes base URL: the base URL
/// without a trailing `/v1` API segment.
Uri hermesDashboardRoot(String baseUrl) {
  final base = Uri.parse(baseUrl.trim());
  return base.replace(path: base.path.replaceFirst(RegExp(r'/v1/?$'), ''));
}

/// [path] (starting with `/`) under the dashboard [root].
Uri hermesDashboardUrl(Uri root, String path) =>
    root.replace(path: '${root.path == '/' ? '' : root.path}$path');

/// The dashboard's own sign-in page.
Uri hermesDashboardLoginUrl(Uri root) => hermesDashboardUrl(root, '/login');

/// The endpoint that answers 2xx only for a signed-in dashboard session.
Uri hermesDashboardAuthCheckUrl(Uri root) =>
    hermesDashboardUrl(root, '/api/auth/me');

/// Whether [target] has the dashboard's exact scheme, host and port.
bool hermesDashboardIsExactOrigin(Uri target, Uri root) =>
    webViewUrlHasExactServerOrigin(target.toString(), root.toString());

/// [headers] without any header the access credentials use, compared
/// without case: what may go to an origin other than the dashboard.
Map<String, String> hermesHeadersWithoutAccessCredentials(
  Map<String, String> headers,
  Map<String, String> accessHeaders,
) {
  final reserved = accessHeaders.keys.map((name) => name.toLowerCase()).toSet();
  return {
    for (final entry in headers.entries)
      if (!reserved.contains(entry.key.toLowerCase())) entry.key: entry.value,
  };
}

/// [headers] (values stringified) with the access credentials added, which
/// replace a header of the same name: what goes to the dashboard origin.
Map<String, String> hermesDashboardSameOriginHeaders(
  Map<String, Object?>? headers,
  Map<String, String> accessHeaders,
) => {
  for (final entry in (headers ?? const <String, Object?>{}).entries)
    entry.key: entry.value.toString(),
  ...accessHeaders,
};

/// One main-frame navigation of the sign-in WebView.
///
/// The dashboard may send the user to an HTTPS identity provider once; after
/// the flow returns to the dashboard, leaving it again is refused, so a page
/// on the dashboard cannot walk the WebView (and its cookies) elsewhere.
({bool allowed, bool leftDashboard, bool returnedToDashboard})
hermesDashboardNavigationTransition({
  required Uri target,
  required Uri dashboardRoot,
  required bool leftDashboard,
  required bool returnedToDashboard,
}) {
  final exact = hermesDashboardIsExactOrigin(target, dashboardRoot);
  if (exact) {
    return (
      allowed: true,
      leftDashboard: leftDashboard,
      returnedToDashboard: returnedToDashboard || leftDashboard,
    );
  }
  final allowed = !returnedToDashboard && target.scheme == 'https';
  return (
    allowed: allowed,
    leftDashboard: leftDashboard || allowed,
    returnedToDashboard: returnedToDashboard,
  );
}

/// Whether a subresource request is fetched by the host with the access
/// headers added: a GET to the dashboard's exact origin that is not the main
/// frame. The main frame is reloaded with the headers by the navigation
/// policy instead, and nothing else ever sees the headers.
bool hermesDashboardInterceptsSubresource({
  required String? method,
  required bool isMainFrame,
  required Uri target,
  required Uri root,
}) =>
    !isMainFrame &&
    method?.toUpperCase() == 'GET' &&
    hermesDashboardIsExactOrigin(target, root);

/// Whether a finished main-frame load at [loaded] should ask the dashboard
/// whether the user is signed in: on the dashboard's origin, not on its sign-in
/// page, and not while a check is already running.
bool hermesDashboardShouldCheckSignIn({
  required Uri? loaded,
  required Uri root,
  required bool checking,
}) =>
    loaded != null &&
    hermesDashboardIsExactOrigin(loaded, root) &&
    !loaded.path.endsWith('/login') &&
    !checking;

/// Body of an async JavaScript function (arguments `url`, `headers`) that
/// answers whether the dashboard session is signed in.
const String kHermesDashboardSignInCheckScript = '''
  const response = await fetch(url, {
    headers,
    credentials: 'include',
    redirect: 'error'
  });
  return response.ok;
''';

/// Body of an async JavaScript function (arguments `url`, `method`, `headers`,
/// `bodyValue`) that issues one dashboard REST request with the page's
/// cookies and answers `{status, body}`. Responses over 4 MiB, or 2 Mi
/// characters of text, are refused.
const String kHermesDashboardFetchScript = '''
  const response = await fetch(url, {
    method,
    headers,
    credentials: 'include',
    redirect: 'error',
    body: bodyValue
  });
  const size = Number(response.headers.get('content-length') || 0);
  if (size > 4194304) throw new Error('response-too-large');
  const reader = response.body?.getReader();
  const decoder = new TextDecoder();
  let bytes = 0;
  let text = '';
  while (reader) {
    const chunk = await reader.read();
    if (chunk.done) break;
    bytes += chunk.value.byteLength;
    if (bytes > 4194304) throw new Error('response-too-large');
    text += decoder.decode(chunk.value, {stream: true});
    if (text.length > 2097152) throw new Error('response-too-large');
  }
  text += decoder.decode();
  return {status: response.status, body: text};
''';
