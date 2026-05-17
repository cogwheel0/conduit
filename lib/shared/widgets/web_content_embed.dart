import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter_plus/webview_flutter_plus.dart';
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
  final String? previewTitle;
  final String? previewDescription;
  @visibleForTesting
  final bool? debugTreatAsSupported;
  @visibleForTesting
  final bool debugSeedControllerForTesting;
  @visibleForTesting
  final VoidCallback? debugOnControllerReset;

  @override
  State<WebContentEmbed> createState() => _WebContentEmbedState();
}

class _WebContentEmbedState extends State<WebContentEmbed> {
  final Set<Factory<OneSequenceGestureRecognizer>> _gestureRecognizers =
      <Factory<OneSequenceGestureRecognizer>>{
        Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
      };

  WebViewControllerPlus? _controller;
  double _height = _embedDefaultHeight;
  bool _isLoading = true;
  bool _loadScheduled = false;
  bool _retryLoadScheduled = false;
  String? _loadError;
  int _loadRequestId = 0;
  late bool _isExpanded;
  bool _debugHasSeededController = false;

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

  bool get _hasController => _controller != null || _debugHasSeededController;

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
        oldWidget.initiallyExpanded != widget.initiallyExpanded) {
      _loadScheduled = false;
      _retryLoadScheduled = false;
      _isExpanded = widget.initiallyExpanded || !widget.deferUntilExpanded;
      _resetControllerState(isLoading: _isExpanded);
      if (_isExpanded) {
        unawaited(_initializeController());
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
        _height = _embedDefaultHeight;
        _isLoading = isLoading;
        _loadError = null;
      });
    } else {
      _loadRequestId += 1;
      _controller = null;
      _debugHasSeededController = false;
      _height = _embedDefaultHeight;
      _isLoading = isLoading;
      _loadError = null;
    }
    if (hadController) {
      widget.debugOnControllerReset?.call();
    }
  }

  void _scheduleControllerInitialization(BuildContext context) {
    if (!_isExpanded || _loadScheduled || _hasController || !_isSupported) {
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
      _initializeController();
    });
  }

  Future<void> _initializeController() async {
    if (!_isSupported || !_isExpanded) {
      return;
    }

    setState(() {
      _controller = null;
      _height = _embedDefaultHeight;
      _isLoading = true;
      _loadError = null;
    });

    try {
      final requestId = ++_loadRequestId;
      final controller = WebViewControllerPlus();
      controller
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.transparent)
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageFinished: (_) async {
              if (requestId != _loadRequestId) {
                return;
              }
              await _injectArguments(controller);
              _scheduleHeightUpdates(controller, requestId);
            },
          ),
        );

      if (mounted) {
        setState(() {
          _controller = controller;
        });
      } else {
        _controller = controller;
      }

      if (_isRemoteUrl) {
        final uri = Uri.tryParse(
          widget.source.startsWith('//')
              ? 'https:${widget.source}'
              : widget.source,
        );
        if (uri == null) {
          throw StateError('Invalid embed URL');
        }
        await controller.loadRequest(uri);
      } else {
        await controller.loadHtmlString(_wrapHtmlDocument(widget.source));
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _loadError = 'Unable to load embedded content.';
      });
    }
  }

  Future<void> _injectArguments(WebViewControllerPlus controller) async {
    final argsText = widget.argsText.trim();
    if (argsText.isEmpty) {
      return;
    }

    try {
      await controller.runJavaScript('window.args = ${jsonEncode(argsText)};');
    } catch (_) {}
  }

  void _scheduleHeightUpdates(WebViewControllerPlus controller, int requestId) {
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
    WebViewControllerPlus controller,
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
      final clampedHeight = measuredHeight
          .clamp(_embedMinHeight, _embedMaxHeight)
          .toDouble();
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

    if (_controller == null) {
      _scheduleControllerInitialization(context);
      return const _EmbedLoadingCard();
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
        child: SizedBox(
          height: _height,
          child: Stack(
            children: [
              Positioned.fill(
                child: WebViewWidget(
                  controller: _controller!,
                  gestureRecognizers: _gestureRecognizers,
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
          ),
        ),
      ),
    );
  }

  static String _wrapHtmlDocument(String source) {
    final trimmed = source.trimLeft();
    if (trimmed.startsWith('<!DOCTYPE html') || trimmed.startsWith('<html')) {
      return source;
    }

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
      }
    </style>
  </head>
  <body>
    $source
  </body>
</html>
''';
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
