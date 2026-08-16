import 'dart:collection';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/utils/debug_logger.dart';
import '../../../shared/widgets/connection_components.dart';
import '../models/hermes_config.dart';
import '../services/hermes_dashboard_cookie_store.dart';
import '../services/hermes_dashboard_webview_policy.dart';

/// Dashboard-owned sign-in. Passwords and identity-provider credentials remain
/// inside the WebView and are never captured by Conduit.
final class HermesDashboardAuthPage extends StatefulWidget {
  const HermesDashboardAuthPage({super.key, required this.config});

  final HermesConfig config;

  @override
  State<HermesDashboardAuthPage> createState() =>
      _HermesDashboardAuthPageState();
}

final class _HermesDashboardAuthPageState
    extends State<HermesDashboardAuthPage> {
  InAppWebViewController? _controller;
  bool _loading = true;
  bool _leftDashboard = false;
  bool _returnedToDashboard = false;
  bool _checking = false;
  String? _error;
  Set<String>? _cookieBaseline;
  late final int _cookieGeneration;
  late final HermesDashboardWebViewPolicy _policy;

  Uri get _root => Uri.parse(widget.config.baseUrl.trim()).replace(
    path: Uri.parse(widget.config.baseUrl.trim()).path
        .replaceFirst(RegExp(r'/v1/?$'), ''),
  );

  Uri get _login =>
      _root.replace(path: '${_root.path == '/' ? '' : _root.path}/login');

  @override
  void initState() {
    super.initState();
    _policy = HermesDashboardWebViewPolicy(
      root: _root,
      accessHeaders: widget.config.accessHeaders,
    );
    _cookieGeneration = HermesDashboardCookieStore.begin(_root.toString());
    HermesDashboardCookieStore.snapshot(_root.toString()).then(
      (value) {
        if (mounted) setState(() => _cookieBaseline = value);
      },
      onError: (_, _) {
        if (mounted) setState(() => _cookieBaseline = const {});
      },
    );
  }

  @override
  void dispose() {
    _policy.close();
    super.dispose();
  }

  Future<bool> _isAuthenticated(InAppWebViewController controller) async {
    final result = await controller.callAsyncJavaScript(
      functionBody: '''
        const response = await fetch(url, {
          headers,
          credentials: 'include',
          redirect: 'error'
        });
        return response.ok;
      ''',
      arguments: {
        'url': _root
            .replace(path: '${_root.path == '/' ? '' : _root.path}/api/auth/me')
            .toString(),
        'headers': _policy.accessHeaders,
      },
    );
    return result?.error == null && result?.value == true;
  }

  @override
  Widget build(BuildContext context) => ConnectionWebAuthScaffold(
    title: 'Hermes sign in',
    backLabel: 'Back',
    onBack: () => Navigator.of(context).pop(false),
    onRefresh: _controller == null || !_policy.supported
        ? null
        : () => _controller!.loadUrl(
            urlRequest: URLRequest(
              url: WebUri(_login.toString()),
              headers: _policy.sameOriginHeaders(null),
            ),
          ),
    body: !_policy.supported
        ? const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Dashboard sign-in with custom gateway headers is not '
                'supported on iOS. Use native PKCE or remove the headers.',
                textAlign: TextAlign.center,
              ),
            ),
          )
        : _cookieBaseline == null
        ? const Center(child: CircularProgressIndicator.adaptive())
        : Stack(
            children: [
              InAppWebView(
                initialUrlRequest: URLRequest(
                  url: WebUri(_login.toString()),
                  headers: _policy.sameOriginHeaders(null),
                ),
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  useShouldOverrideUrlLoading: true,
                  useShouldInterceptAjaxRequest: true,
                  useShouldInterceptFetchRequest: true,
                  useShouldInterceptRequest: true,
                ),
                initialUserScripts: UnmodifiableListView([
                  UserScript(
                    source: _policy.bootstrapScript,
                    injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                  ),
                ]),
                shouldInterceptRequest: (_, request) =>
                    _policy.interceptSubresource(request),
                shouldInterceptAjaxRequest: (_, request) async {
                  final target = request.url?.uriValue;
                  if (target != null && _policy.isExact(target)) {
                    request.headers ??= AjaxRequestHeaders({});
                    for (final entry in _policy.accessHeaders.entries) {
                      request.headers!.setRequestHeader(entry.key, entry.value);
                    }
                  } else {
                    final current = request.headers?.getHeaders().map(
                      (key, value) => MapEntry(key, value.toString()),
                    );
                    request.headers = AjaxRequestHeaders(
                      _policy.crossOriginHeaders(current),
                    );
                  }
                  return request;
                },
                shouldInterceptFetchRequest: (_, request) async {
                  final target = request.url?.uriValue;
                  if (target != null && _policy.isExact(target)) {
                    request.headers = _policy.sameOriginHeaders(
                      request.headers,
                    );
                  } else {
                    request.headers = _policy.crossOriginHeaders(
                      request.headers?.map(
                        (key, value) => MapEntry(key, value.toString()),
                      ),
                    );
                  }
                  return request;
                },
                onWebViewCreated: (controller) => _controller = controller,
                onLoadStart: (_, _) {
                  if (mounted) {
                    setState(() {
                      _loading = true;
                      _error = null;
                    });
                  }
                },
                onLoadStop: (controller, url) async {
                  if (!mounted) return;
                  setState(() => _loading = false);
                  final text = url?.toString() ?? '';
                  if (!_policy.isExact(Uri.parse(text))) {
                    return;
                  }
                  if (url?.path.endsWith('/login') == true || _checking) return;
                  _checking = true;
                  try {
                    final authenticated = await _isAuthenticated(controller);
                    if (mounted && authenticated) {
                      await HermesDashboardCookieStore.register(
                        _root.toString(),
                        generation: _cookieGeneration,
                        baseline: _cookieBaseline!,
                        retainedNames: const {
                          'hermes_session_at',
                          'hermes_session_pkce',
                          'hermes_session_rt',
                          'hermes_session_provider',
                        },
                      );
                      if (!mounted) return;
                      Navigator.of(this.context).pop(true);
                    }
                  } finally {
                    _checking = false;
                  }
                },
                onReceivedError: (_, request, error) {
                  if (request.isForMainFrame != true || !mounted) return;
                  DebugLogger.warning(
                    'webview-load-failed',
                    scope: 'hermes/desktop/auth',
                    data: {'errorType': error.type.toString()},
                  );
                  setState(() {
                    _loading = false;
                    _error = 'Hermes sign-in could not be loaded.';
                  });
                },
                shouldOverrideUrlLoading: (controller, action) async {
                  if (action.isForMainFrame != true) {
                    return NavigationActionPolicy.ALLOW;
                  }
                  final target = action.request.url?.uriValue;
                  if (target == null) return NavigationActionPolicy.CANCEL;
                  final transition = hermesDashboardNavigationTransition(
                    target: target,
                    dashboardRoot: _root,
                    leftDashboard: _leftDashboard,
                    returnedToDashboard: _returnedToDashboard,
                  );
                  _leftDashboard = transition.leftDashboard;
                  _returnedToDashboard = transition.returnedToDashboard;
                  final exact = _policy.isExact(target);
                  if (exact) {
                    final accessHeaders = _policy.accessHeaders;
                    final currentHeaders = action.request.headers ?? const {};
                    final alreadyInjected = accessHeaders.entries.every(
                      (entry) => currentHeaders[entry.key] == entry.value,
                    );
                    if (accessHeaders.isNotEmpty && !alreadyInjected) {
                      await controller.loadUrl(
                        urlRequest: URLRequest(
                          url: action.request.url,
                          method: action.request.method,
                          body: action.request.body,
                          headers: _policy.sameOriginHeaders(currentHeaders),
                        ),
                      );
                      return NavigationActionPolicy.CANCEL;
                    }
                    return NavigationActionPolicy.ALLOW;
                  }
                  if (!transition.allowed) {
                    return NavigationActionPolicy.CANCEL;
                  }
                  final currentHeaders = (action.request.headers ?? const {})
                      .cast<String, String>();
                  final sanitized = _policy.crossOriginHeaders(currentHeaders);
                  if (sanitized.length != currentHeaders.length) {
                    await controller.loadUrl(
                      urlRequest: URLRequest(
                        url: action.request.url,
                        method: action.request.method,
                        body: action.request.body,
                        headers: sanitized,
                      ),
                    );
                    return NavigationActionPolicy.CANCEL;
                  }
                  return NavigationActionPolicy.ALLOW;
                },
              ),
              if (_loading)
                const Positioned.fill(
                  child: ColoredBox(
                    color: Color(0xAAFFFFFF),
                    child: Center(child: CircularProgressIndicator.adaptive()),
                  ),
                ),
              if (_error != null)
                Positioned.fill(
                  child: ColoredBox(
                    color: Theme.of(context).colorScheme.surface,
                    child: Center(child: Text(_error!)),
                  ),
                ),
            ],
          ),
  );
}
