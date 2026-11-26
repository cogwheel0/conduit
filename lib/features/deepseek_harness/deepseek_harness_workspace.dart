import 'dart:async';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:conduit_core/features/deepseek_harness/deepseek_harness.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' hide Cookie;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/widgets/adaptive_route_shell.dart';
import '../../shared/widgets/adaptive_toolbar_components.dart';
import '../../shared/widgets/platform_ui/vocabulary.dart';
import '../../shared/widgets/platform_ui/platform_ui.dart';
import 'deepseek_harness_browser_data.dart';

InAppWebViewSettings harnessWebViewSettings(Uri root) {
  final ios = defaultTargetPlatform == TargetPlatform.iOS;
  return InAppWebViewSettings(
    javaScriptEnabled: true,
    javaScriptBridgeEnabled: false,
    javaScriptCanOpenWindowsAutomatically: false,
    supportMultipleWindows: true, // Route every popup to onCreateWindow.
    useShouldOverrideUrlLoading: true,
    useShouldInterceptRequest: !ios,
    useOnRenderProcessGone: !ios,
    thirdPartyCookiesEnabled: false,
    sharedCookiesEnabled: false,
    allowFileAccess: false,
    allowFileAccessFromFileURLs: false,
    allowUniversalAccessFromFileURLs: false,
    allowContentAccess: false,
    geolocationEnabled: false,
    allowsLinkPreview: false,
    isInspectable: false,
    mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
    // WebKit doesn't offer Android's per-request interception callback.
    contentBlockers: ios
        ? [
            for (final scheme in ['http', 'ws'])
              ContentBlocker(
                trigger: ContentBlockerTrigger(urlFilter: '^$scheme'),
                action: ContentBlockerAction(
                  type: ContentBlockerActionType.BLOCK,
                ),
              ),
            for (final url in [
              root.toString(),
              root
                  .replace(scheme: root.scheme == 'https' ? 'wss' : 'ws')
                  .toString(),
            ])
              ContentBlocker(
                trigger: ContentBlockerTrigger(
                  urlFilter: '^${RegExp.escape(url)}',
                  urlFilterIsCaseSensitive: true,
                ),
                action: ContentBlockerAction(
                  type: ContentBlockerActionType.IGNORE_PREVIOUS_RULES,
                ),
              ),
          ]
        : [],
  );
}

WebResourceResponse _denied(int status) => WebResourceResponse(
  statusCode: status,
  reasonPhrase: status == 401 ? 'Unauthorized' : 'Unavailable',
  headers: const {'Cache-Control': 'no-store'},
  contentType: 'text/plain',
  contentEncoding: 'utf-8',
  data: Uint8List(0),
);

// Chromium enforces a document response policy on the final origin of a
// redirected subresource. Android's interception callback sees only its first URL.
Future<WebResourceResponse> harnessAndroidDocument(
  DeepSeekHarnessConnection connection,
  Uri url,
) async {
  if (!connection.allowsNavigation(url)) return _denied(403);
  if (connection.isExpired) return _denied(401);
  final client = HttpClient();
  Future<WebResourceResponse> load() async {
    final request = await client.getUrl(url);
    request.followRedirects = false;
    request.cookies.add(Cookie(connection.cookieName, connection.cookieValue));
    final response = await request.close();
    if (response.statusCode != 200) {
      return _denied(
        response.statusCode == 401 || response.statusCode == 403 ? 401 : 502,
      );
    }
    final type = response.headers.contentType;
    if (type?.mimeType != 'text/html') return _denied(403);
    final body = BytesBuilder(copy: false);
    await for (final chunk in response) {
      if (body.length + chunk.length > 4 * 1024 * 1024) return _denied(502);
      body.add(chunk);
    }
    final ws = connection.root.origin.replaceFirst('http', 'ws');
    final policy =
        "default-src 'self' blob: data:; "
        "script-src 'self' blob: 'unsafe-inline' 'unsafe-eval'; "
        "style-src 'self' blob: 'unsafe-inline'; connect-src 'self' $ws; "
        "worker-src blob:; frame-src blob: about:; object-src 'none'; base-uri 'self'; form-action 'none'";
    return WebResourceResponse(
      statusCode: 200,
      reasonPhrase: 'OK',
      contentType: 'text/html',
      contentEncoding: type?.charset ?? 'utf-8',
      headers: {
        'Content-Security-Policy': [
          ...?response.headers['content-security-policy'],
          policy,
        ].join(', '),
        'Cache-Control': 'no-store',
        'Referrer-Policy': 'no-referrer',
      },
      data: body.takeBytes(),
    );
  }

  try {
    return await load().timeout(const Duration(seconds: 15));
  } on IOException {
    return _denied(502);
  } on TimeoutException {
    return _denied(502);
  } finally {
    client.close(force: true);
  }
}

/// Advanced operations run inside the workspace served by the connected host.
class DeepSeekHarnessWorkspacePage extends ConsumerWidget {
  const DeepSeekHarnessWorkspacePage({
    super.key,
    required this.sessionTitle,
    required this.onExit,
    required this.onReconnect,
  });

  final String? sessionTitle;
  final VoidCallback onExit;
  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final connection = ref.watch(deepSeekHarnessConnectionProvider);
    return AdaptiveRouteShell(
      bodySafeArea: true,
      safeAreaTop: false,
      appBar: AdaptiveAppBar(
        title: l10n.deepSeekHarnessTitle,
        leading: ConduitAdaptiveAppBarIconButton(
          icon: Icons.arrow_back,
          iosSymbol: 'chevron.backward',
          semanticLabel: l10n.back,
          onPressed: onExit,
        ),
      ),
      body: connection.when(
        data: (saved) => saved == null || saved.isExpired
            ? Center(
                child: AdaptiveButton(
                  label: l10n.connectToServerButton,
                  onPressed: onReconnect,
                ),
              )
            : Column(
                children: [
                  if (sessionTitle case final title?)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Text(
                        title.isEmpty
                            ? l10n.deepSeekHarnessSelectCurrentSession
                            : l10n.deepSeekHarnessSelectSession(title),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  Expanded(
                    child: DeepSeekHarnessWorkspace(
                      key: ObjectKey(saved),
                      connection: saved,
                      onReconnect: onReconnect,
                    ),
                  ),
                ],
              ),
        loading: () => const Center(child: AdaptiveProgressIndicator()),
        error: (_, _) => Center(
          child: AdaptiveButton(
            label: l10n.retry,
            onPressed: () => ref.invalidate(deepSeekHarnessConnectionProvider),
          ),
        ),
      ),
    );
  }
}

class DeepSeekHarnessWorkspace extends ConsumerStatefulWidget {
  const DeepSeekHarnessWorkspace({
    super.key,
    required this.connection,
    required this.onReconnect,
  });

  final DeepSeekHarnessConnection connection;
  final VoidCallback onReconnect;

  @override
  ConsumerState<DeepSeekHarnessWorkspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends ConsumerState<DeepSeekHarnessWorkspace> {
  late final HarnessBrowserData _cookies;
  late Future<void> _install;
  DeepSeekHarnessFailure? _failure;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _cookies = ref.read(deepSeekHarnessBrowserDataProvider);
    _install = _cookies.install(widget.connection);
  }

  @override
  void dispose() {
    _cookies.remove(widget.connection).ignore();
    super.dispose();
  }

  void _retry() => setState(() {
    _failure = null;
    _loading = true;
    _install = _cookies.install(widget.connection);
  });

  void _fail(DeepSeekHarnessFailure failure) {
    if (mounted && _failure == null) setState(() => _failure = failure);
  }

  @override
  Widget build(BuildContext context) {
    final connection = widget.connection;
    final l10n = AppLocalizations.of(context)!;
    return FutureBuilder<void>(
      future: _install,
      builder: (context, result) {
        if (_failure != null || result.hasError) {
          final unauthorized = _failure == DeepSeekHarnessFailure.unauthorized;
          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    unauthorized
                        ? l10n.deepSeekHarnessUnauthorized
                        : l10n.deepSeekHarnessUnavailable,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  AdaptiveButton(
                    label: unauthorized
                        ? l10n.connectToServerButton
                        : l10n.retry,
                    onPressed: unauthorized ? widget.onReconnect : _retry,
                  ),
                ],
              ),
            ),
          );
        }
        if (result.connectionState != ConnectionState.done) {
          return const Center(child: AdaptiveProgressIndicator());
        }
        return Stack(
          children: [
            InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri.uri(connection.root)),
              initialSettings: harnessWebViewSettings(connection.root),
              shouldOverrideUrlLoading: (_, action) async {
                final url = action.request.url?.uriValue;
                return url != null && connection.allowsNavigation(url)
                    ? NavigationActionPolicy.ALLOW
                    : NavigationActionPolicy.CANCEL;
              },
              shouldInterceptRequest: (_, request) async {
                final uri = request.url.uriValue;
                if ((uri.isScheme('http') || uri.isScheme('https')) &&
                    !connection.allowsNavigation(uri)) {
                  return _denied(403);
                }
                if (request.isForMainFrame == true) {
                  if (request.method != 'GET') return _denied(403);
                  return harnessAndroidDocument(connection, uri);
                }
                return null;
              },
              onWebContentProcessDidTerminate: (_) =>
                  _fail(DeepSeekHarnessFailure.unavailable),
              onRenderProcessGone: (_, _) =>
                  _fail(DeepSeekHarnessFailure.unavailable),
              onCreateWindow: (_, _) async => false,
              onPermissionRequest: (_, request) async => PermissionResponse(
                resources: request.resources,
                action: PermissionResponseAction.DENY,
              ),
              onLoadStart: (controller, url) {
                // Android skips its navigation callback for form submissions.
                if (url != null && !connection.allowsNavigation(url.uriValue)) {
                  unawaited(controller.stopLoading());
                  _fail(DeepSeekHarnessFailure.untrustedHost);
                }
              },
              onLoadStop: (_, url) {
                if (!mounted ||
                    _failure != null ||
                    url == null ||
                    !connection.allowsNavigation(url.uriValue)) {
                  return;
                }
                if (_loading) setState(() => _loading = false);
              },
              onReceivedError: (_, request, error) {
                if (request.isForMainFrame == true &&
                    error.type != WebResourceErrorType.CANCELLED) {
                  _fail(DeepSeekHarnessFailure.unavailable);
                }
              },
              onReceivedHttpError: (_, request, response) {
                if (request.isForMainFrame != true) return;
                _fail(
                  response.statusCode == 401 || response.statusCode == 403
                      ? DeepSeekHarnessFailure.unauthorized
                      : DeepSeekHarnessFailure.unavailable,
                );
              },
            ),
            if (_loading)
              const Align(
                alignment: Alignment.topCenter,
                child: AdaptiveProgressIndicator.linear(),
              ),
          ],
        );
      },
    );
  }
}
