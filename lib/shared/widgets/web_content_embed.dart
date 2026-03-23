import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter_plus/webview_flutter_plus.dart';

import '../theme/theme_extensions.dart';

const _embedDefaultHeight = 360.0;
const _embedFallbackHeight = 160.0;
const _embedMinHeight = 220.0;
const _embedMaxHeight = 900.0;

class WebContentEmbed extends StatefulWidget {
  const WebContentEmbed({super.key, required this.source, this.argsText = ''});

  final String source;
  final String argsText;

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
  String? _loadError;
  int _loadRequestId = 0;

  bool get _isRunningInTestEnvironment {
    return WidgetsBinding.instance.runtimeType.toString().contains(
      'TestWidgetsFlutterBinding',
    );
  }

  bool get _isSupported {
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

  String get _unsupportedMessage {
    if (_isRunningInTestEnvironment) {
      return 'Embedded content preview is unavailable in widget tests.';
    }
    return 'Embedded content is available on supported mobile and macOS builds.';
  }

  @override
  void initState() {
    super.initState();
    _initializeController();
  }

  @override
  void didUpdateWidget(covariant WebContentEmbed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source ||
        oldWidget.argsText != widget.argsText) {
      _initializeController();
    }
  }

  Future<void> _initializeController() async {
    if (!_isSupported) {
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
              await _updateHeight(controller);
              if (!mounted || requestId != _loadRequestId) {
                return;
              }
              setState(() {
                _isLoading = false;
              });
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

  Future<void> _updateHeight(WebViewControllerPlus controller) async {
    try {
      final measuredHeight = await controller.webViewHeight;
      if (!mounted || measuredHeight <= 0) {
        return;
      }
      final clampedHeight = measuredHeight
          .clamp(_embedMinHeight, _embedMaxHeight)
          .toDouble();
      setState(() {
        _height = clampedHeight;
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

    if (_controller == null) {
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
              style: TextStyle(
                color: theme.textSecondary,
                fontSize: AppTypography.bodySmall,
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
