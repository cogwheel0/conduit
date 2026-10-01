/// The pure rules of the Hermes dashboard WebView: where its pages live,
/// which navigations it may follow, and which requests carry the gateway's
/// access headers (Cloudflare Access and similar).
///
/// The WebView glue (flutter_inappwebview) stays in the app; only these
/// decisions live here, where they are tested without a WebView.
library;

import 'dart:convert';

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

/// Whether the hidden REST page may follow a navigation: its main frame
/// never leaves the dashboard's exact origin (it carries the dashboard's
/// cookies and header script), frames load as the dashboard asks.
bool hermesDashboardRestPageAllowsNavigation({
  required Uri? target,
  required bool isMainFrame,
  required Uri root,
}) =>
    !isMainFrame ||
    (target != null && hermesDashboardIsExactOrigin(target, root));

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

/// Body of an async JavaScript function (argument `url`) that answers
/// whether the dashboard session is signed in. The access headers are never
/// arguments: the host adds them to this GET natively.
const String kHermesDashboardSignInCheckScript = '''
  const response = await fetch(url, {
    credentials: 'include',
    redirect: 'error'
  });
  return response.ok;
''';

/// Body of an async JavaScript function (arguments `url`, `method`, `headers`,
/// `bodyValue`) that issues one dashboard REST request with the page's
/// cookies and answers `{status, body}`. `headers` never holds the access
/// headers: the host adds them natively (GET) or through
/// [hermesDashboardRequestHeaderScript] (other methods). Responses over 4 MiB, or 2 Mi
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

/// A document-start script that adds [accessHeaders] to the page's own
/// `fetch` and `XMLHttpRequest` calls to the dashboard origin, for methods
/// other than GET. GETs are left to the host, which adds the headers
/// natively to the dashboard's subresource GETs (the app's
/// `shouldInterceptRequest`); that does not cover HEAD, so the script does.
///
/// The header values must never become readable by the page: a script on the
/// dashboard origin (or anything it loads) is not trusted with the gateway
/// secret. So the script
///  * does nothing outside the dashboard origin;
///  * captures, before any page script runs, every function it calls later
///    (`Reflect.apply`, the `URL`/`Request`/`Headers` accessors, the XHR
///    methods, `WeakMap`, `String`) and calls only those, with indexed loops
///    and null-prototype objects, so a replaced prototype method, getter or
///    iterator never sees the values;
///  * hands the values only to the captured native `fetch` (inside a
///    null-prototype header record) and to the captured `setRequestHeader`
///    right before the captured `send`;
///  * resolves each URL once and sends exactly what it checked (a fetch goes
///    out as the `Request` it built; an XHR is reopened on the resolved URL
///    before its headers are set);
///  * defaults a fetch that carries the headers to `redirect: 'error'`
///    (`'manual'` is kept), so a redirect cannot take them elsewhere;
///  * refuses `navigator.serviceWorker.register` and adds nothing while a
///    service worker controls the page, since a worker sees every request.
String hermesDashboardRequestHeaderScript({
  required Uri root,
  required Map<String, String> accessHeaders,
}) {
  final origin = jsonEncode(root.origin);
  final names = jsonEncode(accessHeaders.keys.toList());
  final values = jsonEncode(accessHeaders.values.toList());
  final reserved = jsonEncode([
    for (final name in accessHeaders.keys) name.toLowerCase(),
  ]);
  return '''(() => {
  const dashboardOrigin = $origin;
  if (window.location.origin !== dashboardOrigin) return;
  const apply = Reflect.apply;
  const getDescriptor = Object.getOwnPropertyDescriptor;
  const defineProperty = Object.defineProperty;
  const createObject = Object.create;
  const toText = String;
  const toLowerCase = String.prototype.toLowerCase;
  const toUpperCase = String.prototype.toUpperCase;
  const getter = (target, name) => getDescriptor(target, name).get;
  const NativeURL = window.URL;
  const urlOrigin = getter(NativeURL.prototype, 'origin');
  const urlHref = getter(NativeURL.prototype, 'href');
  const currentDocument = window.document;
  const baseURI = getter(window.Node.prototype, 'baseURI');
  const NativeRequest = window.Request;
  const requestUrl = getter(NativeRequest.prototype, 'url');
  const requestMethod = getter(NativeRequest.prototype, 'method');
  const requestHeaders = getter(NativeRequest.prototype, 'headers');
  const requestRedirect = getter(NativeRequest.prototype, 'redirect');
  const headersForEach = window.Headers.prototype.forEach;
  const nativeFetch = window.fetch;
  const NativeWeakMap = window.WeakMap;
  const weakGet = NativeWeakMap.prototype.get;
  const weakSet = NativeWeakMap.prototype.set;
  const xhrProto = window.XMLHttpRequest.prototype;
  const xhrOpen = xhrProto.open;
  const xhrSetRequestHeader = xhrProto.setRequestHeader;
  const xhrSend = xhrProto.send;
  const xhrReadyState = getter(xhrProto, 'readyState');
  const workers = window.navigator.serviceWorker;
  const workerProto = workers ? window.ServiceWorkerContainer.prototype : null;
  const workerController = workerProto ? getter(workerProto, 'controller') : null;
  const NativePromise = window.Promise;
  const rejectPromise = NativePromise.reject;
  const NativeDOMException = window.DOMException;
  const accessNames = $names;
  const accessValues = $values;
  const reservedNames = $reserved;
  const isReserved = (lowerName) => {
    for (let i = 0; i < reservedNames.length; i++) {
      if (reservedNames[i] === lowerName) return true;
    }
    return false;
  };
  const isDashboard = (url) => {
    try {
      return apply(urlOrigin, new NativeURL(url), []) === dashboardOrigin;
    } catch (_) {
      return false;
    }
  };
  // A service worker sees every request of the pages it controls.
  const controlled = () => {
    if (!workerController) return false;
    try {
      return apply(workerController, workers, []) !== null;
    } catch (_) {
      return true;
    }
  };
  const addsHeaders = (method, url) =>
    method !== 'GET' && isDashboard(url) && !controlled();
  if (workerProto) {
    defineProperty(workerProto, 'register', {
      value: function register() {
        return apply(rejectPromise, NativePromise, [
          new NativeDOMException('Service workers are disabled here.', 'SecurityError')
        ]);
      },
      writable: false,
      configurable: false
    });
  }
  window.fetch = function fetch(input, init) {
    let request;
    try {
      request = new NativeRequest(input, init);
    } catch (_) {
      // Let fetch reject with its own error; nothing is added.
      return apply(nativeFetch, window, [input, init]);
    }
    if (!addsHeaders(apply(requestMethod, request, []), apply(requestUrl, request, []))) {
      return apply(nativeFetch, window, [request]);
    }
    const headers = createObject(null);
    apply(headersForEach, apply(requestHeaders, request, []), [(value, name) => {
      if (!isReserved(name)) headers[name] = value;
    }]);
    for (let i = 0; i < accessNames.length; i++) {
      headers[accessNames[i]] = accessValues[i];
    }
    const options = createObject(null);
    options.headers = headers;
    options.redirect = apply(requestRedirect, request, []) === 'manual' ? 'manual' : 'error';
    return apply(nativeFetch, window, [request, options]);
  };
  const xhrState = new NativeWeakMap();
  xhrProto.open = function open(method, url) {
    const count = arguments.length;
    if (count < 2) return apply(xhrOpen, this, arguments);
    const methodText = toText(method);
    let target = toText(url);
    try {
      target = apply(urlHref, new NativeURL(target, apply(baseURI, currentDocument, [])), []);
    } catch (_) {
      // open() reports the invalid URL itself.
    }
    const args = count === 2
      ? [methodText, target]
      : count === 3
        ? [methodText, target, arguments[2]]
        : count === 4
          ? [methodText, target, arguments[2], arguments[3]]
          : [methodText, target, arguments[2], arguments[3], arguments[4]];
    const result = apply(xhrOpen, this, args);
    const entry = createObject(null);
    entry.args = args;
    entry.add = addsHeaders(apply(toUpperCase, methodText, []), target);
    entry.headers = createObject(null);
    entry.count = 0;
    entry.sent = false;
    apply(weakSet, xhrState, [this, entry]);
    return result;
  };
  xhrProto.setRequestHeader = function setRequestHeader(name, value) {
    const nameText = toText(name);
    const valueText = toText(value);
    if (isReserved(apply(toLowerCase, nameText, []))) return;
    const result = apply(xhrSetRequestHeader, this, [nameText, valueText]);
    const entry = apply(weakGet, xhrState, [this]);
    if (entry !== undefined && entry.add) {
      entry.headers[entry.count] = [nameText, valueText];
      entry.count = entry.count + 1;
    }
    return result;
  };
  xhrProto.send = function send() {
    const entry = apply(weakGet, xhrState, [this]);
    if (entry === undefined || !entry.add || entry.sent ||
        apply(xhrReadyState, this, []) !== 1 || controlled()) {
      return apply(xhrSend, this, arguments);
    }
    entry.sent = true;
    // Reopen on the URL that was checked (open() from another realm could
    // have changed it), replay the page's headers, then add the access
    // headers; nothing of the page runs between these calls.
    apply(xhrOpen, this, entry.args);
    for (let i = 0; i < entry.count; i++) {
      apply(xhrSetRequestHeader, this, entry.headers[i]);
    }
    for (let i = 0; i < accessNames.length; i++) {
      apply(xhrSetRequestHeader, this, [accessNames[i], accessValues[i]]);
    }
    return apply(xhrSend, this, arguments);
  };
})();''';
}
