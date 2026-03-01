import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:conduit/l10n/app_localizations.dart';

import '../../theme/color_tokens.dart';
import '../../theme/theme_extensions.dart';
import 'package:conduit/core/network/self_signed_image_cache_manager.dart';
import 'package:conduit/core/network/image_header_utils.dart';

typedef MarkdownLinkTapCallback = void Function(String url, String title);

class ConduitMarkdown {
  const ConduitMarkdown._();

  /// Builds a syntax-highlighted code block with a
  /// language header and copy button.
  static Widget buildCodeBlock({
    required BuildContext context,
    required String code,
    required String language,
    required ConduitThemeExtension theme,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final normalizedLanguage = language.trim().isEmpty
        ? 'plaintext'
        : language.trim();

    // Map common language aliases to highlight.js recognized names
    final highlightLanguage = mapLanguage(normalizedLanguage);

    // Use Atom One Dark for dark mode, GitHub for light mode
    // These colors must match the highlight themes for visual consistency
    final highlightTheme = isDark ? atomOneDarkTheme : githubTheme;
    final codeBackground = isDark
        ? const Color(0xFF282c34) // Atom One Dark
        : const Color(0xFFF6F8FA); // GitHub light

    // Derive border color from background for consistency
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.1);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: Spacing.sm),
      decoration: BoxDecoration(
        color: codeBackground,
        borderRadius: BorderRadius.circular(AppBorderRadius.lg),
        border: Border.all(color: borderColor, width: BorderWidth.thin),
        boxShadow: isDark
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CodeBlockHeader(
            language: normalizedLanguage,
            backgroundColor: codeBackground,
            borderColor: borderColor,
            isDark: isDark,
            onCopy: () async {
              await Clipboard.setData(ClipboardData(text: code));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).hideCurrentSnackBar();
              final l10n = AppLocalizations.of(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    l10n?.codeCopiedToClipboard ?? 'Code copied to clipboard.',
                  ),
                ),
              );
            },
          ),
          _CodeBlockBody(
            code: code,
            highlightLanguage: highlightLanguage,
            highlightTheme: highlightTheme,
            codeStyle: AppTypography.codeStyle.copyWith(
              fontFamily: AppTypography.monospaceFontFamily,
              fontSize: 13,
              height: 1.55,
            ),
            isDark: isDark,
          ),
        ],
      ),
    );
  }

  /// Maps common language names/aliases to
  /// highlight.js recognized names.
  static String mapLanguage(String language) {
    final lower = language.toLowerCase();

    // Common language aliases mapping
    const languageMap = <String, String>{
      'js': 'javascript',
      'ts': 'typescript',
      'py': 'python',
      'rb': 'ruby',
      'sh': 'bash',
      'shell': 'bash',
      'zsh': 'bash',
      'yml': 'yaml',
      'dockerfile': 'docker',
      'kt': 'kotlin',
      'cs': 'csharp',
      'c++': 'cpp',
      'objc': 'objectivec',
      'objective-c': 'objectivec',
      'txt': 'plaintext',
      'text': 'plaintext',
      'md': 'markdown',
    };

    return languageMap[lower] ?? lower;
  }

  /// Builds an image widget from a [uri].
  ///
  /// Supports `data:` URIs (base64), HTTP(S) network
  /// images, and returns an error placeholder for
  /// unsupported schemes.
  static Widget buildImage(
    BuildContext context,
    Uri uri,
    ConduitThemeExtension theme,
  ) {
    if (uri.scheme == 'data') {
      return _buildBase64Image(uri.toString(), context, theme);
    }
    if (uri.scheme.isEmpty || uri.scheme == 'http' || uri.scheme == 'https') {
      return _buildNetworkImage(uri.toString(), context, theme);
    }
    return buildImageError(context, theme);
  }

  static Widget _buildBase64Image(
    String dataUrl,
    BuildContext context,
    ConduitThemeExtension theme,
  ) {
    try {
      final commaIndex = dataUrl.indexOf(',');
      if (commaIndex == -1) {
        throw FormatException(
          AppLocalizations.of(context)?.invalidDataUrl ??
              'Invalid data URL format',
        );
      }

      final base64String = dataUrl.substring(commaIndex + 1);
      final imageBytes = base64.decode(base64String);

      return Container(
        margin: const EdgeInsets.symmetric(vertical: Spacing.sm),
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 480),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppBorderRadius.md),
          child: Image.memory(
            imageBytes,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) {
              return buildImageError(context, theme);
            },
          ),
        ),
      );
    } catch (_) {
      return buildImageError(context, theme);
    }
  }

  static Widget _buildNetworkImage(
    String url,
    BuildContext context,
    ConduitThemeExtension theme,
  ) {
    // Read headers and optional self-signed cache manager from Riverpod
    final container = ProviderScope.containerOf(context, listen: false);
    final headers = buildImageHeadersFromContainer(container);
    final cacheManager = container.read(selfSignedImageCacheManagerProvider);

    return CachedNetworkImage(
      imageUrl: url,
      cacheManager: cacheManager,
      httpHeaders: headers,
      placeholder: (context, _) => Container(
        height: 200,
        decoration: BoxDecoration(
          color: theme.surfaceBackground.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(AppBorderRadius.md),
        ),
        child: Center(
          child: CircularProgressIndicator(
            color: theme.loadingIndicator,
            strokeWidth: 2,
          ),
        ),
      ),
      errorWidget: (context, url, error) => buildImageError(context, theme),
      imageBuilder: (context, imageProvider) => Container(
        margin: const EdgeInsets.symmetric(vertical: Spacing.sm),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppBorderRadius.md),
          image: DecorationImage(image: imageProvider, fit: BoxFit.contain),
        ),
      ),
    );
  }

  /// Builds an error placeholder for broken images.
  static Widget buildImageError(
    BuildContext context,
    ConduitThemeExtension theme,
  ) {
    return Container(
      height: 120,
      decoration: BoxDecoration(
        color: theme.surfaceBackground.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
        border: Border.all(
          color: theme.cardBorder.withValues(alpha: 0.4),
          width: BorderWidth.micro,
        ),
      ),
      child: Center(
        child: Icon(Icons.broken_image_outlined, color: theme.iconSecondary),
      ),
    );
  }

  static Widget buildMermaidBlock(BuildContext context, String code) {
    final conduitTheme = context.conduitTheme;
    final materialTheme = Theme.of(context);

    if (MermaidDiagram.isSupported) {
      return _buildMermaidContainer(
        context: context,
        conduitTheme: conduitTheme,
        materialTheme: materialTheme,
        code: code,
      );
    }

    return _buildUnsupportedMermaidContainer(
      context: context,
      conduitTheme: conduitTheme,
      code: code,
    );
  }

  static Widget _buildMermaidContainer({
    required BuildContext context,
    required ConduitThemeExtension conduitTheme,
    required ThemeData materialTheme,
    required String code,
  }) {
    final tokens = context.colorTokens;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: Spacing.sm),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppBorderRadius.sm),
        border: Border.all(
          color: conduitTheme.cardBorder.withValues(alpha: 0.4),
          width: BorderWidth.micro,
        ),
      ),
      height: 360,
      width: double.infinity,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppBorderRadius.sm),
        child: MermaidDiagram(
          code: code,
          brightness: materialTheme.brightness,
          colorScheme: materialTheme.colorScheme,
          tokens: tokens,
        ),
      ),
    );
  }

  static Widget _buildUnsupportedMermaidContainer({
    required BuildContext context,
    required ConduitThemeExtension conduitTheme,
    required String code,
  }) {
    final l10n = AppLocalizations.of(context);
    final textStyle = AppTypography.bodySmallStyle.copyWith(
      color: conduitTheme.codeText.withValues(alpha: 0.7),
    );

    return Container(
      margin: const EdgeInsets.symmetric(vertical: Spacing.sm),
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: conduitTheme.surfaceContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(AppBorderRadius.sm),
        border: Border.all(
          color: conduitTheme.cardBorder.withValues(alpha: 0.4),
          width: BorderWidth.micro,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l10n?.mermaidPreviewUnavailable ??
                'Mermaid preview is not available on this platform.',
            style: textStyle,
          ),
          const SizedBox(height: Spacing.xs),
          SelectableText(
            code,
            maxLines: null,
            textAlign: TextAlign.left,
            textDirection: TextDirection.ltr,
            textWidthBasis: TextWidthBasis.parent,
            style: AppTypography.codeStyle.copyWith(
              color: conduitTheme.codeText,
            ),
          ),
        ],
      ),
    );
  }

  /// Checks if HTML content contains ChartJS code patterns.
  static bool containsChartJs(String html) {
    return html.contains('new Chart(') || html.contains('Chart.');
  }

  /// Converts a Color to a hex string for use in HTML/CSS.
  static String colorToHex(Color color) {
    int channel(double value) => (value * 255).round().clamp(0, 255);
    final rgba =
        (channel(color.r) << 24) |
        (channel(color.g) << 16) |
        (channel(color.b) << 8) |
        channel(color.a);
    return '#${rgba.toRadixString(16).padLeft(8, '0')}';
  }

  /// Builds a ChartJS block for rendering in a WebView.
  static Widget buildChartJsBlock(BuildContext context, String htmlContent) {
    final conduitTheme = context.conduitTheme;
    final materialTheme = Theme.of(context);

    if (ChartJsDiagram.isSupported) {
      return _buildChartJsContainer(
        context: context,
        conduitTheme: conduitTheme,
        materialTheme: materialTheme,
        htmlContent: htmlContent,
      );
    }

    return _buildUnsupportedChartJsContainer(
      context: context,
      conduitTheme: conduitTheme,
    );
  }

  static Widget _buildChartJsContainer({
    required BuildContext context,
    required ConduitThemeExtension conduitTheme,
    required ThemeData materialTheme,
    required String htmlContent,
  }) {
    final tokens = context.colorTokens;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: Spacing.sm),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppBorderRadius.sm),
        border: Border.all(
          color: conduitTheme.cardBorder.withValues(alpha: 0.4),
          width: BorderWidth.micro,
        ),
      ),
      height: 320,
      width: double.infinity,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppBorderRadius.sm),
        child: ChartJsDiagram(
          htmlContent: htmlContent,
          brightness: materialTheme.brightness,
          colorScheme: materialTheme.colorScheme,
          tokens: tokens,
        ),
      ),
    );
  }

  static Widget _buildUnsupportedChartJsContainer({
    required BuildContext context,
    required ConduitThemeExtension conduitTheme,
  }) {
    final l10n = AppLocalizations.of(context);
    final textStyle = AppTypography.bodySmallStyle.copyWith(
      color: conduitTheme.codeText.withValues(alpha: 0.7),
    );

    return Container(
      margin: const EdgeInsets.symmetric(vertical: Spacing.sm),
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: conduitTheme.surfaceContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(AppBorderRadius.sm),
        border: Border.all(
          color: conduitTheme.cardBorder.withValues(alpha: 0.4),
          width: BorderWidth.micro,
        ),
      ),
      child: Text(
        l10n?.chartPreviewUnavailable ??
            'Chart preview is not available on this platform.',
        style: textStyle,
      ),
    );
  }
}

/// Collapsible code block body with syntax highlighting.
///
/// When the code exceeds [collapseThreshold] lines, only the
/// first [previewLines] are shown with a toggle to reveal the
/// rest. Short code blocks render normally.
class _CodeBlockBody extends StatefulWidget {
  const _CodeBlockBody({
    required this.code,
    required this.highlightLanguage,
    required this.highlightTheme,
    required this.codeStyle,
    required this.isDark,
  });

  final String code;
  final String highlightLanguage;
  final Map<String, TextStyle> highlightTheme;
  final TextStyle codeStyle;
  final bool isDark;

  /// Lines above this count trigger collapse behavior.
  static const collapseThreshold = 15;

  /// Number of lines visible when collapsed.
  static const previewLines = 10;

  @override
  State<_CodeBlockBody> createState() => _CodeBlockBodyState();
}

class _CodeBlockBodyState extends State<_CodeBlockBody> {
  bool _isCollapsed = true;

  @override
  Widget build(BuildContext context) {
    final lines = widget.code.split('\n');
    final isCollapsible =
        lines.length > _CodeBlockBody.collapseThreshold;
    final displayCode = (isCollapsible && _isCollapsed)
        ? lines
            .take(_CodeBlockBody.previewLines)
            .join('\n')
        : widget.code;
    final hiddenCount =
        lines.length - _CodeBlockBody.previewLines;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.md,
            vertical: Spacing.sm + 4,
          ),
          child: HighlightView(
            displayCode,
            language: widget.highlightLanguage,
            theme: widget.highlightTheme,
            padding: EdgeInsets.zero,
            textStyle: widget.codeStyle,
          ),
        ),
        if (isCollapsible)
          _CollapseToggle(
            isCollapsed: _isCollapsed,
            hiddenLineCount: hiddenCount,
            isDark: widget.isDark,
            onToggle: () {
              setState(() => _isCollapsed = !_isCollapsed);
            },
          ),
      ],
    );
  }
}

/// Toggle row for expanding or collapsing a code block.
///
/// Displays a chevron icon and descriptive text such as
/// "Show N more lines" or "Show less", separated from the
/// code by a subtle top border.
class _CollapseToggle extends StatelessWidget {
  const _CollapseToggle({
    required this.isCollapsed,
    required this.hiddenLineCount,
    required this.isDark,
    required this.onToggle,
  });

  final bool isCollapsed;
  final int hiddenLineCount;
  final bool isDark;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final labelColor = isDark
        ? const Color(0xFF9DA5B4)
        : const Color(0xFF57606A);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.1);

    return GestureDetector(
      onTap: onToggle,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.md,
          vertical: Spacing.xs + 2,
        ),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: borderColor,
              width: BorderWidth.thin,
            ),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSwitcher(
              duration: AnimationDuration.fast,
              child: Icon(
                isCollapsed
                    ? Icons.expand_more_rounded
                    : Icons.expand_less_rounded,
                key: ValueKey(isCollapsed),
                size: 16,
                color: labelColor,
              ),
            ),
            const SizedBox(width: Spacing.xs),
            AnimatedSwitcher(
              duration: AnimationDuration.fast,
              child: Text(
                isCollapsed
                    ? 'Show $hiddenLineCount more lines'
                    : 'Show less',
                key: ValueKey(isCollapsed),
                style: AppTypography.codeStyle.copyWith(
                  color: labelColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Code block header with language label and copy button.
class CodeBlockHeader extends StatefulWidget {
  /// Creates a code block header.
  const CodeBlockHeader({
    super.key,
    required this.language,
    required this.backgroundColor,
    required this.borderColor,
    required this.isDark,
    required this.onCopy,
  });

  final String language;
  final Color backgroundColor;
  final Color borderColor;
  final bool isDark;
  final VoidCallback onCopy;

  @override
  State<CodeBlockHeader> createState() => _CodeBlockHeaderState();
}

class _CodeBlockHeaderState extends State<CodeBlockHeader> {
  bool _isHovering = false;
  bool _isCopied = false;

  void _handleCopy() {
    widget.onCopy();
    setState(() => _isCopied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _isCopied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.language.isEmpty ? 'plaintext' : widget.language;

    // Colors derived from the code block theme for consistency
    final labelColor = widget.isDark
        ? const Color(0xFF9DA5B4) // Atom One Dark muted
        : const Color(0xFF57606A); // GitHub muted

    final iconColor = _isHovering
        ? (widget.isDark ? const Color(0xFFABB2BF) : const Color(0xFF24292F))
        : labelColor;

    final successColor = widget.isDark
        ? const Color(0xFF98C379)
        : const Color(0xFF1A7F37);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.xs + 2,
      ),
      decoration: BoxDecoration(
        color: widget.backgroundColor,
        border: Border(
          bottom: BorderSide(
            color: widget.borderColor,
            width: BorderWidth.thin,
          ),
        ),
      ),
      child: Row(
        children: [
          // Language icon
          Icon(
            _getLanguageIcon(label),
            size: 14,
            color: labelColor.withValues(alpha: 0.7),
          ),
          const SizedBox(width: Spacing.xs),
          // Language label
          Text(
            label,
            style: AppTypography.codeStyle.copyWith(
              color: labelColor,
              fontSize: 12,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.3,
            ),
          ),
          const Spacer(),
          // Copy button with hover effect
          MouseRegion(
            onEnter: (_) => setState(() => _isHovering = true),
            onExit: (_) => setState(() => _isHovering = false),
            child: GestureDetector(
              onTap: _handleCopy,
              child: AnimatedContainer(
                duration: AnimationDuration.fast,
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.sm,
                  vertical: Spacing.xs,
                ),
                decoration: BoxDecoration(
                  color: _isHovering
                      ? widget.borderColor.withValues(alpha: 0.5)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppBorderRadius.xs),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedSwitcher(
                      duration: AnimationDuration.fast,
                      child: Icon(
                        _isCopied
                            ? Icons.check_rounded
                            : Icons.content_copy_rounded,
                        key: ValueKey(_isCopied),
                        size: 14,
                        color: _isCopied ? successColor : iconColor,
                      ),
                    ),
                    if (_isHovering || _isCopied) ...[
                      const SizedBox(width: Spacing.xs),
                      AnimatedOpacity(
                        duration: AnimationDuration.fast,
                        opacity: 1.0,
                        child: Text(
                          _isCopied ? 'Copied!' : 'Copy',
                          style: AppTypography.codeStyle.copyWith(
                            color: _isCopied ? successColor : iconColor,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Returns an appropriate icon for the language.
  IconData _getLanguageIcon(String language) {
    final lower = language.toLowerCase();
    return switch (lower) {
      'dart' || 'flutter' => Icons.flutter_dash_rounded,
      'python' || 'py' => Icons.code_rounded,
      'javascript' || 'js' || 'typescript' || 'ts' => Icons.javascript_rounded,
      'html' || 'css' || 'scss' => Icons.html_rounded,
      'json' || 'yaml' || 'yml' => Icons.data_object_rounded,
      'sql' || 'mysql' || 'postgresql' => Icons.storage_rounded,
      'bash' || 'shell' || 'sh' || 'zsh' => Icons.terminal_rounded,
      'markdown' || 'md' => Icons.article_rounded,
      'swift' || 'kotlin' || 'java' => Icons.phone_iphone_rounded,
      'rust' || 'go' || 'c' || 'cpp' || 'c++' => Icons.memory_rounded,
      'docker' || 'dockerfile' => Icons.cloud_rounded,
      _ => Icons.code_rounded,
    };
  }
}

// ChartJS diagram WebView widget
class ChartJsDiagram extends StatefulWidget {
  const ChartJsDiagram({
    super.key,
    required this.htmlContent,
    required this.brightness,
    required this.colorScheme,
    required this.tokens,
  });

  final String htmlContent;
  final Brightness brightness;
  final ColorScheme colorScheme;
  final AppColorTokens tokens;

  static bool get isSupported => !kIsWeb;

  static Future<String> _loadScript() {
    return _scriptFuture ??= rootBundle.loadString('assets/chartjs.min.js');
  }

  static Future<String>? _scriptFuture;

  @override
  State<ChartJsDiagram> createState() => _ChartJsDiagramState();
}

class _ChartJsDiagramState extends State<ChartJsDiagram> {
  WebViewController? _controller;
  String? _script;
  final Set<Factory<OneSequenceGestureRecognizer>> _gestureRecognizers =
      <Factory<OneSequenceGestureRecognizer>>{
        Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
      };

  @override
  void initState() {
    super.initState();
    if (!ChartJsDiagram.isSupported) {
      return;
    }
    ChartJsDiagram._loadScript().then((value) {
      if (!mounted) {
        return;
      }
      _script = value;
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.transparent);
      _loadHtml();
      setState(() {});
    });
  }

  @override
  void didUpdateWidget(ChartJsDiagram oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_controller == null || _script == null) {
      return;
    }
    final contentChanged = oldWidget.htmlContent != widget.htmlContent;
    final themeChanged =
        oldWidget.brightness != widget.brightness ||
        oldWidget.colorScheme != widget.colorScheme ||
        oldWidget.tokens != widget.tokens;
    if (contentChanged || themeChanged) {
      _loadHtml();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return SizedBox.expand(
      child: WebViewWidget(
        controller: _controller!,
        gestureRecognizers: _gestureRecognizers,
      ),
    );
  }

  void _loadHtml() {
    if (_controller == null || _script == null) {
      return;
    }
    _controller!.loadHtmlString(_buildHtml(widget.htmlContent, _script!));
  }

  String _buildHtml(String htmlContent, String script) {
    final isDark = widget.brightness == Brightness.dark;
    final background = ConduitMarkdown.colorToHex(
      isDark ? widget.tokens.codeBackground : Colors.white,
    );
    final textColor = ConduitMarkdown.colorToHex(widget.tokens.codeText);
    final gridColor = ConduitMarkdown.colorToHex(
      isDark
          ? Colors.white.withValues(alpha: 0.1)
          : Colors.black.withValues(alpha: 0.1),
    );

    return '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<style>
  * {
    margin: 0;
    padding: 0;
    box-sizing: border-box;
  }
  html, body {
    width: 100%;
    height: 100%;
    background-color: $background;
    color: $textColor;
    overflow: hidden;
  }
  #chart-container {
    width: 100%;
    height: 100%;
    display: flex;
    justify-content: center;
    align-items: center;
    padding: 8px;
  }
  canvas {
    max-width: 100%;
    max-height: 100%;
  }
</style>
</head>
<body>
<div id="chart-container">
  <canvas id="chart-canvas"></canvas>
</div>
<script>$script</script>
<script>
(function() {
  Chart.defaults.color = '$textColor';
  Chart.defaults.borderColor = '$gridColor';
  Chart.defaults.backgroundColor = '$background';
  
  try {
    const htmlContent = ${jsonEncode(htmlContent)};
    const chartMatch = htmlContent.match(/new\\s+Chart\\s*\\([^,]+,\\s*([\\s\\S]*?)\\)\\s*;?\\s*(?:<\\/script>|\$)/);
    
    if (chartMatch) {
      let configStr = chartMatch[1].trim();
      
      if (configStr.startsWith('{')) {
        let braceCount = 0;
        let endIndex = 0;
        let inString = null;
        let escaped = false;
        
        for (let i = 0; i < configStr.length; i++) {
          const char = configStr[i];
          
          if (escaped) {
            escaped = false;
            continue;
          }
          
          if (char === '\\\\' && inString) {
            escaped = true;
            continue;
          }
          
          if (!inString && (char === "'" || char === '"' || char === '`')) {
            inString = char;
            continue;
          }
          
          if (inString && char === inString) {
            inString = null;
            continue;
          }
          
          if (!inString) {
            if (char === '{') braceCount++;
            else if (char === '}') braceCount--;
            
            if (braceCount === 0 && i > 0) {
              endIndex = i + 1;
              break;
            }
          }
        }
        
        if (endIndex > 0) {
          configStr = configStr.substring(0, endIndex);
        }
      }
      
      const config = eval('(' + configStr + ')');
      const ctx = document.getElementById('chart-canvas').getContext('2d');
      new Chart(ctx, config);
    }
  } catch (e) {
    console.error('Error creating chart:', e);
    document.getElementById('chart-container').innerHTML = 
      '<p style="color: red; padding: 16px;">Error rendering chart: ' + e.message + '</p>';
  }
})();
</script>
</body>
</html>
''';
  }
}

// Mermaid diagram WebView widget
class MermaidDiagram extends StatefulWidget {
  const MermaidDiagram({
    super.key,
    required this.code,
    required this.brightness,
    required this.colorScheme,
    required this.tokens,
  });

  final String code;
  final Brightness brightness;
  final ColorScheme colorScheme;
  final AppColorTokens tokens;

  static bool get isSupported => !kIsWeb;

  static Future<String> _loadScript() {
    return _scriptFuture ??= rootBundle.loadString('assets/mermaid.min.js');
  }

  static Future<String>? _scriptFuture;

  @override
  State<MermaidDiagram> createState() => _MermaidDiagramState();
}

class _MermaidDiagramState extends State<MermaidDiagram> {
  WebViewController? _controller;
  String? _script;
  final Set<Factory<OneSequenceGestureRecognizer>> _gestureRecognizers =
      <Factory<OneSequenceGestureRecognizer>>{
        Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
      };

  @override
  void initState() {
    super.initState();
    if (!MermaidDiagram.isSupported) {
      return;
    }
    MermaidDiagram._loadScript().then((value) {
      if (!mounted) {
        return;
      }
      _script = value;
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.transparent);
      _loadHtml();
      setState(() {});
    });
  }

  @override
  void didUpdateWidget(MermaidDiagram oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_controller == null || _script == null) {
      return;
    }
    final codeChanged = oldWidget.code != widget.code;
    final themeChanged =
        oldWidget.brightness != widget.brightness ||
        oldWidget.colorScheme != widget.colorScheme ||
        oldWidget.tokens != widget.tokens;
    if (codeChanged || themeChanged) {
      _loadHtml();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return SizedBox.expand(
      child: WebViewWidget(
        controller: _controller!,
        gestureRecognizers: _gestureRecognizers,
      ),
    );
  }

  void _loadHtml() {
    if (_controller == null || _script == null) {
      return;
    }
    _controller!.loadHtmlString(_buildHtml(widget.code, _script!));
  }

  String _buildHtml(String code, String script) {
    final theme = widget.brightness == Brightness.dark ? 'dark' : 'default';
    final primary = ConduitMarkdown.colorToHex(widget.tokens.brandTone60);
    final secondary = ConduitMarkdown.colorToHex(widget.tokens.accentTeal60);
    final background = ConduitMarkdown.colorToHex(widget.tokens.codeBackground);
    final onBackground = ConduitMarkdown.colorToHex(widget.tokens.codeText);

    return '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8" />
<style>
  body {
    margin: 0;
    background-color: transparent;
  }
  #container {
    width: 100%;
    height: 100%;
    display: flex;
    justify-content: center;
    align-items: center;
    background-color: transparent;
  }
</style>
</head>
<body>
<div id="container">
  <div class="mermaid">$code</div>
</div>
<script>$script</script>
<script>
  mermaid.initialize({
    theme: '$theme',
    themeVariables: {
      primaryColor: '$primary',
      primaryTextColor: '$onBackground',
      primaryBorderColor: '$secondary',
      background: '$background'
    },
  });
  mermaid.contentLoaded();
</script>
</body>
</html>
''';
  }
}
