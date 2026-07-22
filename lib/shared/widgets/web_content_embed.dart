import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:conduit/l10n/app_localizations.dart';

import '../theme/theme_extensions.dart';
import 'webview_content_height.dart';

const _embedDefaultHeight = 360.0;
const _embedFallbackHeight = 160.0;
const _embedMinHeight = 220.0;
const _embedMaxHeight = 900.0;

class WebContentEmbed extends StatefulWidget {
  const WebContentEmbed({
    super.key,
    required this.source,
    this.argsText = '',
    this.deferUntilExpanded = true,
    this.initiallyExpanded = false,
    this.showChrome = true,
    this.fillAvailableHeight = false,
    this.previewTitle,
    this.previewDescription,
    @visibleForTesting this.debugTreatAsSupported,
    @visibleForTesting this.debugSeedControllerForTesting = false,
    @visibleForTesting this.debugOnControllerReset,
  });

  final String source;
  final String argsText;
  final bool deferUntilExpanded;
  final bool initiallyExpanded;
  final bool showChrome;
  final bool fillAvailableHeight;
  final String? previewTitle;
  final String? previewDescription;
  @visibleForTesting
  final bool? debugTreatAsSupported;
  @visibleForTesting
  final bool debugSeedControllerForTesting;
  @visibleForTesting
  final VoidCallback? debugOnControllerReset;

  @visibleForTesting
  static String debugWrapHtmlDocument(
    String source, {
    String argsText = '',
    bool fillAvailableHeight = false,
  }) {
    return _WebContentEmbedState._wrapHtmlDocument(
      source,
      argsText: argsText,
      fillAvailableHeight: fillAvailableHeight,
    );
  }

  @override
  State<WebContentEmbed> createState() => _WebContentEmbedState();
}

class _WebContentEmbedState extends State<WebContentEmbed> {
  final Set<Factory<OneSequenceGestureRecognizer>> _gestureRecognizers =
      <Factory<OneSequenceGestureRecognizer>>{
        Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
      };

  InAppWebViewController? _controller;
  double _height = _embedDefaultHeight;
  bool _isLoading = true;
  bool _loadScheduled = false;
  bool _retryLoadScheduled = false;
  String? _loadError;
  int _loadRequestId = 0;
  late bool _isExpanded;
  bool _debugHasSeededController = false;
  bool _shouldRenderWebView = false;

  bool get _isRunningInTestEnvironment {
    return WidgetsBinding.instance.runtimeType.toString().contains(
      'TestWidgetsFlutterBinding',
    );
  }

  bool get _isSupported {
    if (widget.debugTreatAsSupported != null) {
      return widget.debugTreatAsSupported!;
    }
    if (kIsWeb) {
      return false;
    }
    if (_isRunningInTestEnvironment) {
      return false;
    }

    return switch (defaultTargetPlatform) {
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.macOS => true,
      _ => false,
    };
  }

  bool get _isRemoteUrl {
    final raw = widget.source.trim();
    return raw.startsWith('http://') ||
        raw.startsWith('https://') ||
        raw.startsWith('//');
  }

  Uri? get _resolvedRemoteUri {
    if (!_isRemoteUrl) {
      return null;
    }
    return Uri.tryParse(
      widget.source.startsWith('//') ? 'https:${widget.source}' : widget.source,
    );
  }

  bool get _hasController =>
      _controller != null || _debugHasSeededController || _shouldRenderWebView;

  String get _unsupportedMessage {
    if (_isRunningInTestEnvironment) {
      return 'Embedded content preview is unavailable in widget tests.';
    }
    return 'Embedded content is available on supported mobile and macOS builds.';
  }

  @override
  void initState() {
    super.initState();
    _isExpanded = widget.initiallyExpanded || !widget.deferUntilExpanded;
    if (widget.debugSeedControllerForTesting) {
      _debugHasSeededController = true;
      _isLoading = false;
    }
  }

  @override
  void didUpdateWidget(covariant WebContentEmbed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source ||
        oldWidget.argsText != widget.argsText ||
        oldWidget.deferUntilExpanded != widget.deferUntilExpanded ||
        oldWidget.initiallyExpanded != widget.initiallyExpanded ||
        oldWidget.fillAvailableHeight != widget.fillAvailableHeight) {
      _loadScheduled = false;
      _retryLoadScheduled = false;
      _isExpanded = widget.initiallyExpanded || !widget.deferUntilExpanded;
      _resetControllerState(isLoading: _isExpanded);
      if (_isExpanded) {
        unawaited(_initializeController(reuseCurrentRequestId: true));
      }
    }
  }

  void _resetControllerState({required bool isLoading}) {
    final hadController = _hasController;
    if (mounted) {
      setState(() {
        _loadRequestId += 1;
        _controller = null;
        _debugHasSeededController = false;
        _shouldRenderWebView = false;
        _height = _embedDefaultHeight;
        _isLoading = isLoading;
        _loadError = null;
      });
    } else {
      _loadRequestId += 1;
      _controller = null;
      _debugHasSeededController = false;
      _shouldRenderWebView = false;
      _height = _embedDefaultHeight;
      _isLoading = isLoading;
      _loadError = null;
    }
    if (hadController) {
      widget.debugOnControllerReset?.call();
    }
  }

  void _scheduleControllerInitialization(BuildContext context) {
    if (!_isExpanded ||
        _loadScheduled ||
        _shouldRenderWebView ||
        !_isSupported) {
      return;
    }

    if (Scrollable.recommendDeferredLoadingForContext(context)) {
      if (_retryLoadScheduled) {
        return;
      }
      _retryLoadScheduled = true;
      Future<void>.delayed(const Duration(milliseconds: 250), () {
        if (!mounted) {
          return;
        }
        _retryLoadScheduled = false;
        if (!_hasController && !_loadScheduled) {
          setState(() {});
        }
      });
      return;
    }

    _retryLoadScheduled = false;
    _loadScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(_initializeController());
    });
  }

  Future<void> _initializeController({
    bool reuseCurrentRequestId = false,
  }) async {
    if (!_isSupported || !_isExpanded) {
      _loadScheduled = false;
      return;
    }

    if (_isRemoteUrl && _resolvedRemoteUri == null) {
      _loadScheduled = false;
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _loadError = 'Unable to load embedded content.';
      });
      return;
    }

    try {
      if (!reuseCurrentRequestId) {
        _loadRequestId += 1;
      }
      setState(() {
        _controller = null;
        _debugHasSeededController = false;
        _shouldRenderWebView = true;
        _height = _embedDefaultHeight;
        _isLoading = true;
        _loadError = null;
      });
    } finally {
      _loadScheduled = false;
    }
  }

  Future<void> _handleWebViewCreated(
    InAppWebViewController controller,
    int requestId,
  ) async {
    if (requestId != _loadRequestId) {
      return;
    }

    if (mounted) {
      setState(() {
        _controller = controller;
      });
    } else {
      _controller = controller;
    }

    try {
      if (_isRemoteUrl) {
        final uri = _resolvedRemoteUri;
        if (uri == null) {
          throw StateError('Invalid embed URL');
        }
        await controller.loadUrl(urlRequest: URLRequest(url: WebUri.uri(uri)));
      } else {
        final baseUrl = WebUri('https://embed.conduit.local/');
        await controller.loadData(
          data: _wrapHtmlDocument(
            widget.source,
            argsText: widget.argsText,
            fillAvailableHeight: widget.fillAvailableHeight,
          ),
          baseUrl: baseUrl,
          historyUrl: baseUrl,
        );
      }
    } catch (_) {
      if (!mounted || requestId != _loadRequestId) {
        return;
      }
      setState(() {
        _controller = null;
        _shouldRenderWebView = false;
        _isLoading = false;
        _loadError = 'Unable to load embedded content.';
      });
    }
  }

  Future<void> _injectArguments(InAppWebViewController controller) async {
    final argsText = widget.argsText.trim();
    if (argsText.isEmpty) {
      return;
    }

    try {
      await controller.evaluateJavascript(
        source: 'window.args = ${jsonEncode(argsText)};',
      );
    } catch (_) {}
  }

  void _scheduleHeightUpdates(
    InAppWebViewController controller,
    int requestId,
  ) {
    _updateHeight(controller, requestId);
    for (final delay in <int>[60, 250, 600]) {
      Future<void>.delayed(Duration(milliseconds: delay), () {
        _updateHeight(controller, requestId);
      });
    }
    Future<void>.delayed(const Duration(milliseconds: 900), () {
      if (!mounted || requestId != _loadRequestId || !_isLoading) {
        return;
      }
      setState(() {
        _isLoading = false;
      });
    });
  }

  Future<void> _updateHeight(
    InAppWebViewController controller,
    int requestId,
  ) async {
    try {
      final measuredHeight = await measureWebViewContentHeight(controller);
      if (!mounted ||
          requestId != _loadRequestId ||
          measuredHeight == null ||
          measuredHeight <= 0) {
        return;
      }
      final clampedHeight = widget.fillAvailableHeight
          ? _height
          : measuredHeight.clamp(_embedMinHeight, _embedMaxHeight).toDouble();
      setState(() {
        _height = clampedHeight;
        _isLoading = false;
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    if (!_isSupported) {
      return _EmbedFallbackCard(
        source: widget.source,
        message: _unsupportedMessage,
      );
    }

    if (_loadError != null) {
      return _EmbedFallbackCard(source: widget.source, message: _loadError!);
    }

    if (!_isExpanded) {
      return _EmbedDeferredCard(
        title: widget.previewTitle ?? 'Embedded Preview',
        description:
            widget.previewDescription ??
            (_isRemoteUrl
                ? (widget.source.startsWith('//')
                      ? 'https:${widget.source}'
                      : widget.source)
                : 'Load the embedded preview when you need it.'),
        onOpen: () {
          if (!mounted) {
            return;
          }
          setState(() {
            _isExpanded = true;
          });
        },
      );
    }

    if (!_shouldRenderWebView) {
      _scheduleControllerInitialization(context);
      if (!widget.showChrome) {
        return const Center(child: CircularProgressIndicator());
      }
      return const _EmbedLoadingCard();
    }

    final requestId = _loadRequestId;
    final webView = Stack(
      children: [
        Positioned.fill(
          child: InAppWebView(
            key: ValueKey<int>(requestId),
            gestureRecognizers: _gestureRecognizers,
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              transparentBackground: true,
            ),
            onWebViewCreated: (controller) {
              unawaited(_handleWebViewCreated(controller, requestId));
            },
            onLoadStop: (controller, _) async {
              if (requestId != _loadRequestId) {
                return;
              }
              if (_isRemoteUrl) {
                await _injectArguments(controller);
              }
              _scheduleHeightUpdates(controller, requestId);
            },
            onReceivedError: (controller, request, error) {
              if (requestId != _loadRequestId ||
                  !(request.isForMainFrame ?? false) ||
                  !mounted) {
                return;
              }
              setState(() {
                _controller = null;
                _shouldRenderWebView = false;
                _isLoading = false;
                _loadError = error.description;
              });
            },
          ),
        ),
        if (_isLoading)
          const Positioned.fill(
            child: ColoredBox(
              color: Colors.transparent,
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );

    final sizedWebView = widget.fillAvailableHeight
        ? LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.hasBoundedHeight) {
                return SizedBox.expand(child: webView);
              }
              return SizedBox(height: _height, child: webView);
            },
          )
        : SizedBox(height: _height, child: webView);

    if (!widget.showChrome) {
      return sizedWebView;
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.cardBackground,
        border: Border.all(color: theme.cardBorder),
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
        boxShadow: theme.cardShadows,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
        child: sizedWebView,
      ),
    );
  }

  static String _wrapHtmlDocument(
    String source, {
    String argsText = '',
    bool fillAvailableHeight = false,
  }) {
    final sandboxedSource = _injectSandboxBootstrap(source, argsText: argsText);
    final encodedSource = _escapeHtmlAttribute(sandboxedSource);
    return '''
<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <style>
      html, body {
        margin: 0;
        padding: 0;
        background: transparent;
        width: 100%;
      }
      #embed-frame {
        display: block;
        width: 100%;
        height: ${fillAvailableHeight ? '100vh' : '${_embedDefaultHeight}px'};
        min-height: ${_embedMinHeight}px;
        border: 0;
        background: transparent;
      }
    </style>
    <script>
      (() => {
        const minHeight = $_embedMinHeight;
        const maxHeight = $_embedMaxHeight;
        const fillAvailableHeight = $fillAvailableHeight;
        window.addEventListener('message', (event) => {
          const data = event.data || {};
          if (data.type !== 'conduit-embed-height') return;

          const height = Number(data.height);
          if (!Number.isFinite(height) || height <= 0) return;

          const frame = document.getElementById('embed-frame');
          if (!frame) return;
          if (fillAvailableHeight) return;

          const clamped = Math.min(Math.max(height, minHeight), maxHeight);
          frame.style.height = `\${clamped}px`;
        });
      })();
    </script>
  </head>
  <body>
    <iframe
      id="embed-frame"
      sandbox="allow-scripts allow-forms"
      referrerpolicy="no-referrer"
      srcdoc="$encodedSource"
    ></iframe>
  </body>
</html>
''';
  }

  static String _injectSandboxBootstrap(
    String source, {
    required String argsText,
  }) {
    final assignments = <String>[];
    if (argsText.trim().isNotEmpty) {
      assignments.add('window.args = ${_jsonForInlineScript(argsText)};');
    }

    final bootstrap =
        '''
<script>
  ${assignments.join('\n  ')}
  (() => {
    const reportHeight = () => {
      const body = document.body;
      const html = document.documentElement;
      const height = Math.ceil(Math.max(
        body?.scrollHeight || 0,
        body?.offsetHeight || 0,
        html?.clientHeight || 0,
        html?.scrollHeight || 0,
        html?.offsetHeight || 0
      ));
      parent.postMessage({ type: 'conduit-embed-height', height }, '*');
    };

    window.addEventListener('load', reportHeight);
    if (typeof ResizeObserver !== 'undefined') {
      const observer = new ResizeObserver(reportHeight);
      observer.observe(document.documentElement);
      if (document.body) observer.observe(document.body);
    }
    setTimeout(reportHeight, 0);
    setTimeout(reportHeight, 250);
    setTimeout(reportHeight, 1000);
  })();
</script>
''';

    final headMatch = RegExp(
      r'<head\b[^>]*>',
      caseSensitive: false,
    ).firstMatch(source);
    if (headMatch != null) {
      return source.replaceRange(headMatch.end, headMatch.end, bootstrap);
    }

    final htmlMatch = RegExp(
      r'<html\b[^>]*>',
      caseSensitive: false,
    ).firstMatch(source);
    if (htmlMatch != null) {
      return source.replaceRange(htmlMatch.end, htmlMatch.end, bootstrap);
    }

    return '$bootstrap$source';
  }

  static String _jsonForInlineScript(String value) {
    return jsonEncode(value)
        .replaceAll('&', r'\u0026')
        .replaceAll('<', r'\u003C')
        .replaceAll('>', r'\u003E');
  }

  static String _escapeHtmlAttribute(String value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }
}

class _EmbedLoadingCard extends StatelessWidget {
  const _EmbedLoadingCard();

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.cardBackground,
        border: Border.all(color: theme.cardBorder),
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
      ),
      child: const SizedBox(
        height: _embedFallbackHeight,
        child: Center(child: CircularProgressIndicator()),
      ),
    );
  }
}

class _EmbedDeferredCard extends StatelessWidget {
  const _EmbedDeferredCard({
    required this.title,
    required this.description,
    required this.onOpen,
  });

  final String title;
  final String description;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.cardBackground,
        border: Border.all(color: theme.cardBorder),
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: AppTypography.bodyMediumStyle.copyWith(
                color: theme.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              description,
              style: AppTypography.bodySmallStyle.copyWith(
                color: theme.textSecondary,
              ),
            ),
            const SizedBox(height: Spacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: onOpen,
                child: Text(l10n?.openPreview ?? 'Open preview'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmbedFallbackCard extends StatelessWidget {
  const _EmbedFallbackCard({required this.source, required this.message});

  final String source;
  final String message;

  bool get _isRemoteUrl =>
      source.startsWith('http://') ||
      source.startsWith('https://') ||
      source.startsWith('//');

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.cardBackground,
        border: Border.all(color: theme.cardBorder),
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message,
              style: AppTypography.bodySmallStyle.copyWith(
                color: theme.textSecondary,
              ),
            ),
            if (_isRemoteUrl) ...[
              const SizedBox(height: Spacing.xs),
              SelectableText(
                source.startsWith('//') ? 'https:$source' : source,
                style: AppTypography.codeStyle.copyWith(color: theme.codeText),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
