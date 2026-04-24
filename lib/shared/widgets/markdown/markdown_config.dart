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
import 'package:webview_flutter_plus/webview_flutter_plus.dart';

import 'package:conduit/l10n/app_localizations.dart';

import '../web_content_embed.dart';
import '../webview_content_height.dart';
import '../../theme/color_tokens.dart';
import '../../theme/theme_extensions.dart';
import 'renderer/markdown_style.dart';
import 'package:conduit/core/network/self_signed_image_cache_manager.dart';
import 'package:conduit/core/network/image_header_utils.dart';

typedef MarkdownLinkTapCallback = void Function(String url, String title);

const _chartPreviewMinHeight = 320.0;
const _mermaidPreviewMinHeight = 360.0;
const _embeddedPreviewMaxHeight = 1200.0;

class ConduitMarkdown {
  const ConduitMarkdown._();

  /// Builds a syntax-highlighted code block with a
  /// language header and copy button.
  static Widget buildCodeBlock({
    required BuildContext context,
    required String code,
    required String language,
    required ConduitThemeExtension theme,
    VoidCallback? onPreview,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final markdownStyle = ConduitMarkdownStyle.fromTheme(context);
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
      margin: const EdgeInsets.symmetric(vertical: Spacing.xs + 2),
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
            onPreview: onPreview,
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
            codeStyle: markdownStyle.codeBlock,
            isDark: isDark,
          ),
        ],
      ),
    );
  }

  static bool isPreviewableCodeBlock(String language, String code) {
    final normalized = language.trim().toLowerCase();
    return normalized == 'html' ||
        normalized == 'svg' ||
        (normalized == 'xml' && code.contains('<svg'));
  }

  static bool shouldInlinePreviewCodeBlock(String language, String code) {
    final normalized = language.trim().toLowerCase();
    return normalized == 'svg' ||
        (normalized == 'xml' && code.contains('<svg'));
  }

  static Widget buildInlineCodePreview(
    BuildContext context, {
    required String code,
    required String language,
  }) {
    final theme = context.conduitTheme;
    final markdownStyle = ConduitMarkdownStyle.fromTheme(context);
    final previewLabel = _previewTitleForLanguage(language);

    return Container(
      margin: const EdgeInsets.only(top: Spacing.sm, bottom: Spacing.xs + 2),
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: theme.surfaceContainer.withValues(alpha: 0.32),
        borderRadius: BorderRadius.circular(AppBorderRadius.lg),
        border: Border.all(
          color: theme.cardBorder.withValues(alpha: 0.55),
          width: BorderWidth.thin,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            previewLabel,
            style: markdownStyle.codeChrome.copyWith(
              color: theme.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: Spacing.xs),
          WebContentEmbed(source: code),
        ],
      ),
    );
  }

  static Future<void> showCodePreviewSheet(
    BuildContext context, {
    required String code,
    required String language,
  }) {
    final theme = context.conduitTheme;
    final title = _previewTitleForLanguage(language);

    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: theme.surfaceBackground,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppBorderRadius.dialog),
        ),
      ),
      builder: (sheetContext) {
        final markdownStyle = ConduitMarkdownStyle.fromTheme(sheetContext);
        return SafeArea(
          child: FractionallySizedBox(
            heightFactor: 0.9,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: Spacing.sm),
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: theme.dividerColor.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Spacing.lg,
                    Spacing.sm,
                    Spacing.lg,
                    Spacing.sm,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.visibility_outlined,
                        size: 18,
                        color: theme.textSecondary,
                      ),
                      const SizedBox(width: Spacing.sm),
                      Expanded(
                        child: Text(
                          title,
                          overflow: TextOverflow.ellipsis,
                          style: markdownStyle.sheetTitle,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () => Navigator.of(sheetContext).pop(),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        color: theme.textSecondary,
                      ),
                    ],
                  ),
                ),
                Divider(
                  height: 1,
                  color: theme.dividerColor.withValues(alpha: 0.3),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(Spacing.lg),
                    children: [WebContentEmbed(source: code)],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static String _previewTitleForLanguage(String language) {
    final normalized = language.trim().toLowerCase();
    if (normalized == 'svg' || normalized == 'xml') {
      return 'SVG Preview';
    }
    return 'HTML Preview';
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
    final markdownStyle = ConduitMarkdownStyle.fromTheme(context);
    final textStyle = _unsupportedPreviewTextStyle(markdownStyle, conduitTheme);

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
            style: markdownStyle.detailCode.copyWith(
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
    final markdownStyle = ConduitMarkdownStyle.fromTheme(context);
    final textStyle = _unsupportedPreviewTextStyle(markdownStyle, conduitTheme);

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

  static TextStyle _unsupportedPreviewTextStyle(
    ConduitMarkdownStyle markdownStyle,
    ConduitThemeExtension conduitTheme,
  ) {
    return markdownStyle.detailAction.copyWith(
      color: conduitTheme.codeText.withValues(alpha: 0.7),
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
    final isCollapsible = lines.length > _CodeBlockBody.collapseThreshold;
    final displayCode = (isCollapsible && _isCollapsed)
        ? lines.take(_CodeBlockBody.previewLines).join('\n')
        : widget.code;
    final hiddenCount = lines.length - _CodeBlockBody.previewLines;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm + 2,
            vertical: Spacing.sm,
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
    final markdownStyle = ConduitMarkdownStyle.fromTheme(context);
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
          horizontal: Spacing.sm + 2,
          vertical: Spacing.xs + 1,
        ),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: borderColor, width: BorderWidth.thin),
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
                isCollapsed ? 'Show $hiddenLineCount more lines' : 'Show less',
                key: ValueKey(isCollapsed),
                style: markdownStyle.codeChrome.copyWith(
                  color: labelColor,
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
    this.onPreview,
    required this.onCopy,
  });

  final String language;
  final Color backgroundColor;
  final Color borderColor;
  final bool isDark;
  final VoidCallback? onPreview;
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
    final markdownStyle = ConduitMarkdownStyle.fromTheme(context);
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
        horizontal: Spacing.sm + 2,
        vertical: Spacing.xs + 1,
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
            style: markdownStyle.codeChrome.copyWith(
              color: labelColor,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          if (widget.onPreview != null) ...[
            _CodeBlockActionButton(
              icon: Icons.visibility_outlined,
              label: 'Preview',
              color: iconColor,
              onTap: widget.onPreview!,
            ),
            const SizedBox(width: Spacing.xs),
          ],
          // Copy button with hover effect
          MouseRegion(
            onEnter: (_) => setState(() => _isHovering = true),
            onExit: (_) => setState(() => _isHovering = false),
            child: GestureDetector(
              onTap: _handleCopy,
              child: AnimatedContainer(
                duration: AnimationDuration.fast,
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.xs + 2,
                  vertical: Spacing.xs - 1,
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
                          style: markdownStyle.codeChrome.copyWith(
                            color: _isCopied ? successColor : iconColor,
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

class _CodeBlockActionButton extends StatelessWidget {
  const _CodeBlockActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final markdownStyle = ConduitMarkdownStyle.fromTheme(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.xs + 2,
          vertical: Spacing.xs - 1,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppBorderRadius.xs),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: Spacing.xs),
            Text(
              label,
              style: markdownStyle.codeChrome.copyWith(
                color: color,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
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

  /// Builds the Chart.js preview document used by tests.
  @visibleForTesting
  static String buildPreviewHtmlForTesting({
    required String htmlContent,
    String script = '/* chartjs */',
  }) {
    return const _ChartJsDocumentComposer().build(
      htmlContent: htmlContent,
      script: script,
    );
  }

  @override
  State<ChartJsDiagram> createState() => _ChartJsDiagramState();
}

class _ChartJsDiagramState extends State<ChartJsDiagram> {
  WebViewControllerPlus? _controller;
  String? _script;
  double _height = _chartPreviewMinHeight;
  bool _isLoading = true;
  int _loadRequestId = 0;
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
      _controller = WebViewControllerPlus()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.transparent)
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageFinished: (_) {
              _scheduleHeightUpdates(_loadRequestId);
            },
          ),
        );
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
    return SizedBox(
      height: _height,
      width: double.infinity,
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
    );
  }

  void _loadHtml() {
    if (_controller == null || _script == null) {
      return;
    }
    ++_loadRequestId;
    if (mounted) {
      setState(() {
        _height = _chartPreviewMinHeight;
        _isLoading = true;
      });
    }
    _controller!.loadHtmlString(_buildHtml(widget.htmlContent, _script!));
  }

  Future<void> _scheduleHeightUpdates(int requestId) async {
    await _updateHeight(requestId);
    for (final delay in <int>[60, 250, 600]) {
      Future<void>.delayed(Duration(milliseconds: delay), () {
        _updateHeight(requestId);
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

  Future<void> _updateHeight(int requestId) async {
    final controller = _controller;
    if (controller == null) {
      return;
    }

    try {
      final measuredHeight = await measureWebViewContentHeight(controller);
      if (!mounted ||
          requestId != _loadRequestId ||
          measuredHeight == null ||
          measuredHeight <= 0) {
        return;
      }

      final clampedHeight = measuredHeight
          .clamp(_chartPreviewMinHeight, _embeddedPreviewMaxHeight)
          .toDouble();
      setState(() {
        _height = clampedHeight;
        _isLoading = false;
      });
    } catch (_) {}
  }

  String _buildHtml(String htmlContent, String script) {
    return const _ChartJsDocumentComposer().build(
      htmlContent: htmlContent,
      script: script,
    );
  }
}

class _ChartJsDocumentComposer {
  const _ChartJsDocumentComposer();

  String build({required String htmlContent, required String script}) {
    final inlineScripts = _extractInlineScripts(htmlContent);
    final markupWithoutInlineScripts = _stripInlineScripts(htmlContent);
    final hasCanvasTag = _containsHtmlTag(markupWithoutInlineScripts, 'canvas');
    final fallbackCanvasMarkup = hasCanvasTag
        ? ''
        : '''
<div id="chart-container">
  <canvas id="chart-canvas"></canvas>
</div>
''';
    final runtimeScript = _buildChartRuntimeScript(
      inlineScripts: inlineScripts,
      useCanvasFallback: !hasCanvasTag,
    );
    final headInjection =
        '''
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<style>
  html {
    width: 100%;
    background-color: #ffffff;
  }
  body {
    margin: 0;
    overflow-x: hidden;
  }
  #chart-container {
    width: 100%;
    min-height: 280px;
    display: flex;
    justify-content: center;
    align-items: center;
  }
  canvas {
    max-width: 100% !important;
    height: auto !important;
  }
</style>
<script>$script</script>
''';

    return _composeChartDocument(
      markup: markupWithoutInlineScripts,
      headInjection: headInjection,
      fallbackCanvasMarkup: fallbackCanvasMarkup,
      runtimeScript: runtimeScript,
    );
  }

  List<String> _extractInlineScripts(String htmlContent) {
    final matches = RegExp(
      r'<script(?![^>]*\bsrc\b)[^>]*>([\s\S]*?)<\/script>',
      caseSensitive: false,
    ).allMatches(htmlContent);

    return matches
        .map((match) => (match.group(1) ?? '').trim())
        .where((script) => script.isNotEmpty)
        .toList(growable: false);
  }

  String _stripInlineScripts(String htmlContent) {
    return htmlContent.replaceAll(
      RegExp(
        r'<script(?![^>]*\bsrc\b)[^>]*>[\s\S]*?<\/script>',
        caseSensitive: false,
      ),
      '',
    );
  }

  bool _containsHtmlTag(String html, String tagName) {
    return RegExp('<$tagName\\b', caseSensitive: false).hasMatch(html);
  }

  String _buildChartRuntimeScript({
    required List<String> inlineScripts,
    required bool useCanvasFallback,
  }) {
    final userScript = inlineScripts.join('\n').trim();
    final encodedScript = jsonEncode(userScript).replaceAll('</', r'<\/');
    final fallbackShim = useCanvasFallback
        ? '''
  const _origGet = document.getElementById.bind(document);
  document.getElementById = function(id) {
    return _origGet(id) || _origGet('chart-canvas');
  };
'''
        : '';

    return '''
<script>
(function() {
  try {
$fallbackShim
    const userScript = $encodedScript;
    if (userScript) {
      eval(userScript); // ignore: eval
    }
  } catch (e) {
    console.error('Error creating chart:', e);
    const container = document.getElementById('chart-container') || document.body;
    container.innerHTML =
      '<p style="color: red; padding: 16px;">Error rendering chart: ' + e.message + '</p>';
  }
})();
</script>
''';
  }

  String _composeChartDocument({
    required String markup,
    required String headInjection,
    required String fallbackCanvasMarkup,
    required String runtimeScript,
  }) {
    final trimmedMarkup = markup.trim();
    final hasHtmlTag = _containsHtmlTag(trimmedMarkup, 'html');
    final hasBodyTag = _containsHtmlTag(trimmedMarkup, 'body');
    final hasHeadTag = _containsHtmlTag(trimmedMarkup, 'head');
    final fallbackBodyContent = fallbackCanvasMarkup.isNotEmpty
        ? '$fallbackCanvasMarkup\n'
        : '';

    if (!hasHtmlTag) {
      return '''
<!DOCTYPE html>
<html>
<head>
$headInjection
</head>
<body>
$fallbackBodyContent$trimmedMarkup
$runtimeScript
</body>
</html>
''';
    }

    var documentHtml = trimmedMarkup;
    if (hasHeadTag) {
      documentHtml = _insertAfterFirstMatch(
        documentHtml,
        RegExp(r'<head\b[^>]*>', caseSensitive: false),
        headInjection,
      );
    } else {
      documentHtml = _insertAfterFirstMatch(
        documentHtml,
        RegExp(r'<html\b[^>]*>', caseSensitive: false),
        '<head>\n$headInjection\n</head>',
      );
    }

    if (hasBodyTag) {
      if (fallbackCanvasMarkup.isNotEmpty) {
        documentHtml = _insertAfterFirstMatch(
          documentHtml,
          RegExp(r'<body\b[^>]*>', caseSensitive: false),
          fallbackCanvasMarkup,
        );
      }
      return _insertBeforeFirstMatch(
        documentHtml,
        RegExp(r'</body>', caseSensitive: false),
        runtimeScript,
      );
    }

    documentHtml = _insertAfterFirstMatch(
      documentHtml,
      RegExp(r'</head>', caseSensitive: false),
      '<body>\n$fallbackBodyContent',
    );

    return _insertBeforeFirstMatch(
      documentHtml,
      RegExp(r'</html>', caseSensitive: false),
      '$runtimeScript\n</body>',
    );
  }

  String _insertAfterFirstMatch(String input, RegExp pattern, String content) {
    final match = pattern.firstMatch(input);
    if (match == null) {
      return '$input\n$content';
    }
    return input.replaceRange(match.end, match.end, '\n$content');
  }

  String _insertBeforeFirstMatch(String input, RegExp pattern, String content) {
    final match = pattern.firstMatch(input);
    if (match == null) {
      return '$input\n$content';
    }
    return input.replaceRange(match.start, match.start, '$content\n');
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
  WebViewControllerPlus? _controller;
  String? _script;
  double _height = _mermaidPreviewMinHeight;
  bool _isLoading = true;
  int _loadRequestId = 0;
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
      _controller = WebViewControllerPlus()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.transparent)
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageFinished: (_) {
              _scheduleHeightUpdates(_loadRequestId);
            },
          ),
        );
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
    return SizedBox(
      height: _height,
      width: double.infinity,
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
    );
  }

  void _loadHtml() {
    if (_controller == null || _script == null) {
      return;
    }
    ++_loadRequestId;
    if (mounted) {
      setState(() {
        _height = _mermaidPreviewMinHeight;
        _isLoading = true;
      });
    }
    _controller!.loadHtmlString(
      _buildHtml(_sanitizeMermaidCode(widget.code), _script!),
    );
  }

  Future<void> _scheduleHeightUpdates(int requestId) async {
    await _updateHeight(requestId);
    for (final delay in <int>[60, 250, 600]) {
      Future<void>.delayed(Duration(milliseconds: delay), () {
        _updateHeight(requestId);
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

  Future<void> _updateHeight(int requestId) async {
    final controller = _controller;
    if (controller == null) {
      return;
    }

    try {
      final measuredHeight = await measureWebViewContentHeight(controller);
      if (!mounted ||
          requestId != _loadRequestId ||
          measuredHeight == null ||
          measuredHeight <= 0) {
        return;
      }

      final clampedHeight = measuredHeight
          .clamp(_mermaidPreviewMinHeight, _embeddedPreviewMaxHeight)
          .toDouble();
      setState(() {
        _height = clampedHeight;
        _isLoading = false;
      });
    } catch (_) {}
  }

  String _sanitizeMermaidCode(String source) {
    final lines = source.split('\n');
    final normalized = <String>[];

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed == 'end' || trimmed.startsWith('end %%')) {
        normalized.add(line);
        continue;
      }

      var updated = line;
      updated = updated.replaceFirstMapped(
        RegExp(r'^(\s*classDef\s+)end(\b)'),
        (match) => '${match[1]}endNode${match[2]}',
      );
      updated = updated.replaceFirstMapped(
        RegExp(r'^(\s*class\s+[^;\n]+\s+)end(\s*;?\s*)$'),
        (match) => '${match[1]}endNode${match[2]}',
      );

      normalized.add(updated);
    }

    return normalized.join('\n');
  }

  String _buildHtml(String code, String script) {
    final theme = widget.brightness == Brightness.dark ? 'dark' : 'default';

    return '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8" />
<style>
  html, body {
    width: 100%;
    margin: 0;
    background-color: transparent;
  }
  body {
    box-sizing: border-box;
    overflow-x: hidden;
  }
  #container {
    width: 100%;
    background-color: transparent;
  }
  #mermaid-diagram {
    width: 100%;
  }
  #mermaid-diagram,
  #mermaid-diagram svg {
    display: block;
  }
  #mermaid-diagram svg {
    max-width: 100%;
    height: auto;
    margin: 0 auto;
  }
</style>
</head>
<body>
<div id="container">
  <div class="mermaid" id="mermaid-diagram"></div>
</div>
<script>$script</script>
<script>
  mermaid.initialize({
    startOnLoad: false,
    theme: '$theme',
    securityLevel: 'loose'
  });

  var diagramCode = ${jsonEncode(code)};

  async function renderValidated(id, source) {
    var parseResult = await mermaid.parse(source, { suppressErrors: false });
    if (!parseResult) {
      throw new Error('Mermaid parse failed');
    }
    var rendered = await mermaid.render(id, source);
    if (
      rendered &&
      rendered.svg &&
      rendered.svg.indexOf('Syntax error in text') !== -1
    ) {
      throw new Error('Mermaid render produced syntax error svg');
    }
    return rendered;
  }

  renderValidated('mermaid-svg', diagramCode).then(function(result) {
    document.getElementById('mermaid-diagram').innerHTML = result.svg;
  }).catch(function(err) {
    var message = err.message || String(err);
    document.getElementById('mermaid-diagram').innerHTML =
      '<pre style="color:red;padding:16px;">' + message + '</pre>';
  });
</script>
</body>
</html>
''';
  }
}
