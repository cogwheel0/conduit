import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:highlight/highlight.dart' show Node, highlight;
import 'package:mermaid_core/mermaid_core.dart' as mermaid_core;
import 'package:mermaid_flutter/mermaid_flutter.dart' as mermaid_flutter;

import 'package:conduit/l10n/app_localizations.dart';

import '../web_content_embed.dart';
import '../webview_content_height.dart';
import '../themed_sheets.dart';
import '../../theme/color_tokens.dart';
import '../../theme/theme_extensions.dart';
import 'renderer/markdown_style.dart';
import 'package:conduit/core/network/self_signed_image_cache_manager.dart';
import 'package:conduit/core/network/image_header_utils.dart';

typedef MarkdownLinkTapCallback = void Function(String url, String title);

const _chartPreviewMinHeight = 320.0;
const _mermaidPreviewMinHeight = 360.0;
const _embeddedPreviewMaxHeight = 1200.0;
const _maxConcurrentEmbeddedPreviews = 2;

final _embeddedPreviewBudget = _EmbeddedPreviewBudget(
  maxActive: _maxConcurrentEmbeddedPreviews,
);
final Set<_DeferredEmbeddedPreviewState> _embeddedPreviewRegistry =
    HashSet<_DeferredEmbeddedPreviewState>.identity();
bool _embeddedPreviewRegistryCheckScheduled = false;

/// Re-evaluates every retained preview after markdown registry/layout changes.
///
/// Scroll listeners cover ordinary viewport movement, but inserting/removing a
/// markdown block can move sibling previews without changing scroll offset.
void scheduleEmbeddedPreviewEligibilityRecheck() {
  if (_embeddedPreviewRegistryCheckScheduled ||
      _embeddedPreviewRegistry.isEmpty) {
    return;
  }
  _embeddedPreviewRegistryCheckScheduled = true;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    _embeddedPreviewRegistryCheckScheduled = false;
    for (final preview in _embeddedPreviewRegistry.toList(growable: false)) {
      if (preview.mounted) {
        preview._updateViewportEligibility();
      }
    }
  });
  WidgetsBinding.instance.ensureVisualUpdate();
}

@visibleForTesting
void debugResetEmbeddedPreviewBudget() => _embeddedPreviewBudget.reset();

@visibleForTesting
void debugRequestEmbeddedPreviewBudget(
  Object token, {
  required bool eligible,
  bool prioritize = false,
}) {
  _embeddedPreviewBudget.update(token, eligible: eligible);
  if (prioritize) {
    _embeddedPreviewBudget.prioritize(token);
  }
}

@visibleForTesting
bool debugHasEmbeddedPreviewBudget(Object token) =>
    _embeddedPreviewBudget.isActive(token);

@visibleForTesting
int get debugActiveEmbeddedPreviewCount => _embeddedPreviewBudget.activeCount;

class _EmbeddedPreviewBudget extends ChangeNotifier {
  _EmbeddedPreviewBudget({required this.maxActive});

  final int maxActive;
  final LinkedHashSet<Object> _eligible = LinkedHashSet<Object>.identity();
  final Set<Object> _active = HashSet<Object>.identity();

  int get activeCount => _active.length;

  bool isActive(Object token) => _active.contains(token);

  void update(Object token, {required bool eligible}) {
    final changed = eligible ? _eligible.add(token) : _eligible.remove(token);
    if (changed) {
      _recompute();
      scheduleEmbeddedPreviewEligibilityRecheck();
    }
  }

  void prioritize(Object token) {
    if (!_eligible.contains(token)) {
      _eligible.add(token);
    }
    final ordered = <Object>[
      token,
      ..._eligible.where((item) => item != token),
    ];
    _eligible
      ..clear()
      ..addAll(ordered);
    _recompute();
    scheduleEmbeddedPreviewEligibilityRecheck();
  }

  void reset() {
    if (_eligible.isEmpty && _active.isEmpty) {
      return;
    }
    _eligible.clear();
    _active.clear();
    notifyListeners();
    scheduleEmbeddedPreviewEligibilityRecheck();
  }

  void _recompute() {
    final next = HashSet<Object>.identity()..addAll(_eligible.take(maxActive));
    if (setEquals(next, _active)) {
      return;
    }
    _active
      ..clear()
      ..addAll(next);
    notifyListeners();
  }
}

class _DeferredEmbeddedPreview extends StatefulWidget {
  const _DeferredEmbeddedPreview({
    required this.placeholderHeight,
    required this.loadActionLabel,
    required this.icon,
    required this.builder,
    this.requiresExplicitActivation = false,
    this.activationIdentity,
  });

  final double placeholderHeight;
  final String loadActionLabel;
  final IconData icon;
  final WidgetBuilder builder;
  final bool requiresExplicitActivation;
  final Object? activationIdentity;

  @override
  State<_DeferredEmbeddedPreview> createState() =>
      _DeferredEmbeddedPreviewState();
}

class _DeferredEmbeddedPreviewState extends State<_DeferredEmbeddedPreview> {
  final Object _budgetToken = Object();
  final GlobalKey _previewKey = GlobalKey();
  ScrollPosition? _position;
  bool _viewportCheckScheduled = false;
  bool _measurementScheduled = false;
  bool _nearViewport = false;
  bool _routeVisible = true;
  bool _eligible = false;
  bool _explicitlyActivated = false;
  bool _lastActive = false;
  double? _lastMeasuredHeight;

  bool get _active => _embeddedPreviewBudget.isActive(_budgetToken);

  @override
  void initState() {
    super.initState();
    _embeddedPreviewRegistry.add(this);
    _embeddedPreviewBudget.addListener(_handleBudgetChanged);
    scheduleEmbeddedPreviewEligibilityRecheck();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Register a dependency on the enclosing route so covered chat pages stop
    // competing with the current route for the global platform-view budget.
    _routeVisible =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    final nextPosition = Scrollable.maybeOf(context)?.position;
    if (!identical(nextPosition, _position)) {
      _position?.removeListener(_scheduleViewportCheck);
      _position = nextPosition;
      _position?.addListener(_scheduleViewportCheck);
    }
    _scheduleViewportCheck();
  }

  @override
  void didUpdateWidget(covariant _DeferredEmbeddedPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.requiresExplicitActivation &&
        widget.activationIdentity != oldWidget.activationIdentity) {
      _explicitlyActivated = false;
      _lastMeasuredHeight = null;
      _embeddedPreviewBudget.update(_budgetToken, eligible: false);
    }
    scheduleEmbeddedPreviewEligibilityRecheck();
  }

  @override
  void dispose() {
    _position?.removeListener(_scheduleViewportCheck);
    _embeddedPreviewRegistry.remove(this);
    _embeddedPreviewBudget.removeListener(_handleBudgetChanged);
    final budgetToken = _budgetToken;
    // Removing this token can activate a waiting sibling and synchronously
    // notify its State. Element disposal happens inside finalizeTree, where a
    // sibling setState is illegal, so release the global budget post-frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _embeddedPreviewBudget.update(budgetToken, eligible: false);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
    super.dispose();
  }

  void _handleBudgetChanged() {
    final nextActive = _active;
    if (!mounted || nextActive == _lastActive) return;
    _lastActive = nextActive;
    setState(() {});
  }

  void _activate() {
    if (widget.requiresExplicitActivation) {
      _explicitlyActivated = true;
      _embeddedPreviewBudget.update(_budgetToken, eligible: _eligible);
    }
    _embeddedPreviewBudget.prioritize(_budgetToken);
  }

  void _scheduleMeasurement() {
    if (_measurementScheduled || !mounted) return;
    _measurementScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measurementScheduled = false;
      if (!mounted) return;
      final renderObject = _previewKey.currentContext?.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.hasSize) return;
      final height = renderObject.size.height;
      if (height.isFinite && height > 0) {
        _lastMeasuredHeight = height;
      }
    });
  }

  void _scheduleViewportCheck() {
    if (_viewportCheckScheduled || !mounted) {
      return;
    }
    _viewportCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _viewportCheckScheduled = false;
      if (mounted) {
        _updateViewportEligibility();
      }
    });
  }

  void _updateViewportEligibility() {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return;
    }
    final margin = widget.placeholderHeight * 0.75;
    final nextNearViewport = _isNearEnclosingViewport(
      renderObject,
      margin: margin,
    );
    final nextEligible = nextNearViewport && _routeVisible;
    if (_nearViewport == nextNearViewport && _eligible == nextEligible) {
      return;
    }
    _nearViewport = nextNearViewport;
    _eligible = nextEligible;
    _embeddedPreviewBudget.update(
      _budgetToken,
      eligible:
          nextEligible &&
          (!widget.requiresExplicitActivation || _explicitlyActivated),
    );
  }

  bool _isNearEnclosingViewport(RenderBox target, {required double margin}) {
    final position = _position;
    final viewport = RenderAbstractViewport.maybeOf(target);
    final RenderBox? viewportRenderObject = viewport is RenderBox
        ? viewport as RenderBox
        : null;
    if (position != null &&
        position.hasViewportDimension &&
        viewportRenderObject != null &&
        viewportRenderObject.hasSize) {
      // Compare in the viewport's own coordinate system. Global screen bounds
      // incorrectly admit previews clipped below a short/nested scroll view.
      final targetRect = MatrixUtils.transformRect(
        target.getTransformTo(viewportRenderObject),
        target.paintBounds,
      );
      final viewportRect = viewportRenderObject.paintBounds;
      return _rectIsNearViewport(
        targetRect,
        viewportRect,
        axis: axisDirectionToAxis(position.axisDirection),
        margin: margin,
      );
    }

    // Non-scrollable markdown can still contain a preview (for example in a
    // fixed sheet). Fall back to the visible media rectangle, while retaining
    // cross-axis clipping instead of checking vertical coordinates alone.
    final targetRect = MatrixUtils.transformRect(
      target.getTransformTo(null),
      target.paintBounds,
    );
    final viewportRect = Offset.zero & MediaQuery.sizeOf(context);
    return _rectIsNearViewport(
      targetRect,
      viewportRect,
      axis: Axis.vertical,
      margin: margin,
    );
  }

  bool _rectIsNearViewport(
    Rect target,
    Rect viewport, {
    required Axis axis,
    required double margin,
  }) {
    if (axis == Axis.vertical) {
      return target.bottom >= viewport.top - margin &&
          target.top <= viewport.bottom + margin &&
          target.right >= viewport.left &&
          target.left <= viewport.right;
    }
    return target.right >= viewport.left - margin &&
        target.left <= viewport.right + margin &&
        target.bottom >= viewport.top &&
        target.top <= viewport.bottom;
  }

  @override
  Widget build(BuildContext context) {
    // Ancestor markdown/layout rebuilds can move this preview while the scroll
    // position remains unchanged. Recheck against its post-layout geometry.
    _scheduleViewportCheck();
    // Platform views are intentionally absent in widget tests; keeping
    // non-sensitive previews in the tree preserves structural assertions.
    // Explicitly activated previews still require the same user action in tests.
    if (_active ||
        (_isRunningInWidgetTest() && !widget.requiresExplicitActivation)) {
      return NotificationListener<SizeChangedLayoutNotification>(
        onNotification: (_) {
          _scheduleMeasurement();
          return false;
        },
        child: SizeChangedLayoutNotifier(
          child: SizedBox(
            key: _previewKey,
            width: double.infinity,
            child: widget.builder(context),
          ),
        ),
      );
    }
    return SizedBox(
      height: _lastMeasuredHeight ?? widget.placeholderHeight,
      width: double.infinity,
      child: Center(
        child: TextButton.icon(
          onPressed: _activate,
          icon: Icon(widget.icon),
          label: Text(widget.loadActionLabel),
        ),
      ),
    );
  }
}

bool _isRunningInWidgetTest() {
  return WidgetsBinding.instance.runtimeType.toString().contains(
    'TestWidgetsFlutterBinding',
  );
}

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
          _DeferredEmbeddedPreview(
            placeholderHeight: _mermaidPreviewMinHeight,
            loadActionLabel: 'Load SVG preview',
            icon: Icons.image_outlined,
            requiresExplicitActivation: true,
            activationIdentity: code,
            builder: (_) => WebContentEmbed(
              source: code,
              deferUntilExpanded: false,
              initiallyExpanded: true,
              previewTitle: _previewTitleForLanguage(language),
            ),
          ),
        ],
      ),
    );
  }

  static Future<void> showCodePreviewSheet(
    BuildContext context, {
    required String code,
    required String language,
  }) async {
    final theme = context.conduitTheme;
    final title = _previewTitleForLanguage(language);

    if (!context.mounted) {
      return;
    }

    return ThemedSheets.showRoundedPage<void>(
      context: context,
      builder: (sheetContext) {
        final markdownStyle = ConduitMarkdownStyle.fromTheme(sheetContext);
        return SizedBox.expand(
          child: ColoredBox(
            color: theme.surfaceBackground,
            child: Column(
              children: [
                ConduitModalSheetHeader(
                  leading: Icon(
                    Icons.visibility_outlined,
                    size: 18,
                    color: theme.textSecondary,
                  ),
                  title: title,
                  titleStyle: markdownStyle.sheetTitle,
                  onClose: () => Navigator.of(sheetContext).pop(),
                  onVerticalDragEnd: (details) {
                    if ((details.primaryVelocity ?? 0) > 500) {
                      Navigator.of(sheetContext).pop();
                    }
                  },
                ),
                Expanded(
                  child: WebContentEmbed(
                    source: code,
                    deferUntilExpanded: false,
                    initiallyExpanded: true,
                    showChrome: false,
                    fillAvailableHeight: true,
                    previewTitle: title,
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
    // A markdown document can remain mounted across an account transition.
    // Watch ownership here so both stale credentials and the URL cache identity
    // are replaced without requiring the whole document to rebuild.
    return Consumer(
      builder: (context, ref, child) {
        final headers = buildImageHeadersForUrlFromWidgetRef(ref, url);
        final cacheKey = buildImageCacheKeyForUrlFromWidgetRef(ref, url);
        final cacheManager = ref.watch(selfSignedImageCacheManagerProvider);

        return CachedNetworkImage(
          imageUrl: url,
          cacheKey: cacheKey,
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
          errorBuilder: (context, error, stackTrace) =>
              buildImageError(context, theme),
          imageBuilder: (context, imageProvider) => Container(
            margin: const EdgeInsets.symmetric(vertical: Spacing.sm),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppBorderRadius.md),
              image: DecorationImage(image: imageProvider, fit: BoxFit.contain),
            ),
          ),
        );
      },
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
    final l10n = AppLocalizations.of(context);
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
        child: _DeferredEmbeddedPreview(
          placeholderHeight: _mermaidPreviewMinHeight,
          loadActionLabel: l10n?.loadMermaidPreview ?? 'Load Mermaid preview',
          icon: Icons.account_tree_outlined,
          builder: (_) => MermaidDiagram(
            code: code,
            brightness: materialTheme.brightness,
            colorScheme: materialTheme.colorScheme,
            tokens: tokens,
            onRequestFullscreen: (light, dark) =>
                showMermaidPreviewSheet(context, light: light, dark: dark),
          ),
        ),
      ),
    );
  }

  static Future<void> showMermaidPreviewSheet(
    BuildContext context, {
    required MermaidRenderResult light,
    required MermaidRenderResult dark,
  }) async {
    if (!context.mounted) {
      return;
    }

    return ThemedSheets.showRoundedPage<void>(
      context: context,
      builder: (sheetContext) {
        final conduitTheme = sheetContext.conduitTheme;
        final markdownStyle = ConduitMarkdownStyle.fromTheme(sheetContext);
        final diagram = Theme.of(sheetContext).brightness == Brightness.dark
            ? dark
            : light;
        return SizedBox.expand(
          child: ColoredBox(
            color: conduitTheme.surfaceBackground,
            child: Column(
              children: [
                ConduitModalSheetHeader(
                  leading: Icon(
                    Icons.account_tree_outlined,
                    size: 18,
                    color: conduitTheme.textSecondary,
                  ),
                  title: 'Mermaid Preview',
                  titleStyle: markdownStyle.sheetTitle,
                  onClose: () => Navigator.of(sheetContext).pop(),
                  closeTooltip: 'Close Mermaid preview',
                  onVerticalDragEnd: (details) {
                    if ((details.primaryVelocity ?? 0) > 500) {
                      Navigator.of(sheetContext).pop();
                    }
                  },
                ),
                Expanded(
                  child: _MermaidSheetCanvas(
                    svg: diagram.svg,
                    sceneSize: diagram.sceneSize,
                  ),
                ),
              ],
            ),
          ),
        );
      },
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
    final l10n = AppLocalizations.of(context);
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
        child: _DeferredEmbeddedPreview(
          placeholderHeight: _chartPreviewMinHeight,
          loadActionLabel: l10n?.loadChartPreview ?? 'Load chart preview',
          icon: Icons.bar_chart_outlined,
          builder: (_) => ChartJsDiagram(
            htmlContent: htmlContent,
            brightness: materialTheme.brightness,
            colorScheme: materialTheme.colorScheme,
            tokens: tokens,
          ),
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
final _highlightSpanCache = _HighlightSpanCache();

class _HighlightCacheKey {
  _HighlightCacheKey({
    required this.language,
    required this.code,
    required this.isDark,
  }) : codeHash = Object.hash(code, code.length);

  final String language;
  final String code;
  final bool isDark;
  final int codeHash;

  @override
  bool operator ==(Object other) {
    return other is _HighlightCacheKey &&
        other.language == language &&
        other.isDark == isDark &&
        other.code == code;
  }

  @override
  int get hashCode => Object.hash(language, codeHash, isDark);
}

class _HighlightSpanCache {
  static const int maxEntries = 48;

  final LinkedHashMap<_HighlightCacheKey, List<TextSpan>> _cache =
      LinkedHashMap<_HighlightCacheKey, List<TextSpan>>();

  List<TextSpan> resolve(
    _HighlightCacheKey key,
    List<TextSpan> Function() build,
  ) {
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return cached;
    }

    final spans = build();
    if (_cache.length >= maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = spans;
    return spans;
  }
}

class _HighlightedCodeText extends StatelessWidget {
  const _HighlightedCodeText({
    required this.source,
    required this.language,
    required this.theme,
    required this.textStyle,
    required this.isDark,
    this.plainText = false,
  });

  static const _rootKey = 'root';
  static const _defaultFontColor = Color(0xff000000);
  static const _defaultFontFamily = 'monospace';

  final String source;
  final String language;
  final Map<String, TextStyle> theme;
  final TextStyle textStyle;
  final bool isDark;
  final bool plainText;

  @override
  Widget build(BuildContext context) {
    final rootStyle = TextStyle(
      fontFamily: _defaultFontFamily,
      color: theme[_rootKey]?.color ?? _defaultFontColor,
    ).merge(textStyle);

    final children = plainText
        ? <TextSpan>[TextSpan(text: source)]
        : _highlightSpanCache.resolve(
            _HighlightCacheKey(
              language: language,
              code: source,
              isDark: isDark,
            ),
            () => _buildHighlightedSpans(
              source: source,
              language: language,
              theme: theme,
            ),
          );

    return RichText(
      text: TextSpan(style: rootStyle, children: children),
      textScaler: MediaQuery.textScalerOf(context),
    );
  }
}

List<TextSpan> _buildHighlightedSpans({
  required String source,
  required String language,
  required Map<String, TextStyle> theme,
}) {
  try {
    final nodes = highlight.parse(source, language: language).nodes;
    if (nodes == null || nodes.isEmpty) {
      return <TextSpan>[TextSpan(text: source)];
    }
    return _convertHighlightNodes(nodes, theme);
  } catch (_) {
    return <TextSpan>[TextSpan(text: source)];
  }
}

List<TextSpan> _convertHighlightNodes(
  List<Node> nodes,
  Map<String, TextStyle> theme,
) {
  final spans = <TextSpan>[];
  var currentSpans = spans;
  final stack = <List<TextSpan>>[];

  void traverse(Node node) {
    if (node.value != null) {
      currentSpans.add(
        node.className == null
            ? TextSpan(text: node.value)
            : TextSpan(text: node.value, style: theme[node.className!]),
      );
      return;
    }

    final children = node.children;
    if (children == null || children.isEmpty) {
      return;
    }

    final nested = <TextSpan>[];
    currentSpans.add(
      TextSpan(
        children: nested,
        style: node.className == null ? null : theme[node.className!],
      ),
    );
    stack.add(currentSpans);
    currentSpans = nested;
    for (final child in children) {
      traverse(child);
    }
    currentSpans = stack.isEmpty ? spans : stack.removeLast();
  }

  for (final node in nodes) {
    traverse(node);
  }
  return spans;
}

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

  static const largeJsonPlainPreviewLineThreshold = 60;
  static const largeJsonPlainPreviewCharThreshold = 4000;

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
    final renderPlainPreview =
        _isCollapsed &&
        widget.highlightLanguage == 'json' &&
        (lines.length > _CodeBlockBody.largeJsonPlainPreviewLineThreshold ||
            widget.code.length >
                _CodeBlockBody.largeJsonPlainPreviewCharThreshold);

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
          child: _HighlightedCodeText(
            source: displayCode,
            language: widget.highlightLanguage,
            theme: widget.highlightTheme,
            textStyle: widget.codeStyle,
            isDark: widget.isDark,
            plainText: renderPlainPreview,
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
              duration: context.motionDuration(AnimationDuration.fast),
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
              duration: context.motionDuration(AnimationDuration.fast),
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
              label: AppLocalizations.of(context)!.preview,
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
                duration: context.motionDuration(AnimationDuration.fast),
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
                      duration: context.motionDuration(AnimationDuration.fast),
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
                      Text(
                        _isCopied ? 'Copied!' : 'Copy',
                        style: markdownStyle.codeChrome.copyWith(
                          color: _isCopied ? successColor : iconColor,
                          fontWeight: FontWeight.w500,
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
  InAppWebViewController? _controller;
  String? _script;
  double _height = _chartPreviewMinHeight;
  bool _isLoading = true;
  int _loadRequestId = 0;
  bool _loadScheduled = false;
  bool _retryLoadScheduled = false;
  final Set<Factory<OneSequenceGestureRecognizer>> _gestureRecognizers =
      <Factory<OneSequenceGestureRecognizer>>{
        Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
      };

  bool get _isRunningInTestEnvironment => _isRunningInWidgetTest();

  @override
  void dispose() {
    _loadRequestId += 1;
    _controller = null;
    super.dispose();
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
      unawaited(_loadHtml());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isRunningInTestEnvironment) {
      return const SizedBox(
        height: _chartPreviewMinHeight,
        width: double.infinity,
      );
    }

    if (_script == null) {
      _scheduleInitialization(context);
      return const SizedBox(
        height: _chartPreviewMinHeight,
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return SizedBox(
      height: _height,
      width: double.infinity,
      child: Stack(
        children: [
          Positioned.fill(
            child: InAppWebView(
              gestureRecognizers: _gestureRecognizers,
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                transparentBackground: true,
              ),
              onWebViewCreated: (controller) {
                _controller = controller;
                unawaited(_loadHtml());
              },
              onLoadStop: (controller, _) async {
                if (!mounted || controller != _controller) {
                  return;
                }
                await _scheduleHeightUpdates(_loadRequestId);
              },
              onReceivedError: (controller, request, error) {
                if (!mounted ||
                    controller != _controller ||
                    !(request.isForMainFrame ?? false)) {
                  return;
                }
                setState(() {
                  _isLoading = false;
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
      ),
    );
  }

  void _scheduleInitialization(BuildContext context) {
    if (_isRunningInTestEnvironment ||
        _loadScheduled ||
        _script != null ||
        !ChartJsDiagram.isSupported) {
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
        if (_script == null && !_loadScheduled) {
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

  Future<void> _initializeController() async {
    if (_isRunningInTestEnvironment ||
        !ChartJsDiagram.isSupported ||
        _script != null) {
      _loadScheduled = false;
      return;
    }

    try {
      final value = await ChartJsDiagram._loadScript();
      if (!mounted) {
        return;
      }
      setState(() {
        _script = value;
      });
    } finally {
      _loadScheduled = false;
    }
  }

  Future<void> _loadHtml() async {
    final controller = _controller;
    final script = _script;
    if (controller == null || script == null) {
      return;
    }
    final requestId = ++_loadRequestId;
    if (mounted) {
      setState(() {
        _height = _chartPreviewMinHeight;
        _isLoading = true;
      });
    }
    final baseUrl = WebUri('https://chart-preview.conduit.local/');
    try {
      await controller.loadData(
        data: _buildHtml(widget.htmlContent, script),
        baseUrl: baseUrl,
        historyUrl: baseUrl,
      );
      if (!mounted ||
          controller != _controller ||
          requestId != _loadRequestId) {
        return;
      }
      await _scheduleHeightUpdates(requestId);
    } catch (_) {
      if (!mounted || controller != _controller) {
        return;
      }
      setState(() {
        _isLoading = false;
      });
    }
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
    container.textContent = '';
    const p = document.createElement('p');
    p.style.color = 'red';
    p.style.padding = '16px';
    p.textContent = 'Error rendering chart: ' + (e && e.message ? e.message : 'unknown error');
    container.appendChild(p);
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

// Native Flutter Mermaid diagram widget.
@immutable
class MermaidRenderResult {
  const MermaidRenderResult({required this.svg, required this.sceneSize});

  final String svg;
  final Size sceneSize;
}

class MermaidDiagram extends StatefulWidget {
  const MermaidDiagram({
    super.key,
    required this.code,
    required this.brightness,
    required this.colorScheme,
    required this.tokens,
    this.allowFullscreen = true,
    this.onRequestFullscreen,
  });

  final String code;
  final Brightness brightness;
  final ColorScheme colorScheme;
  final AppColorTokens tokens;
  final bool allowFullscreen;
  final Future<void> Function(
    MermaidRenderResult light,
    MermaidRenderResult dark,
  )?
  onRequestFullscreen;

  static bool get isSupported => true;

  @override
  State<MermaidDiagram> createState() => _MermaidDiagramState();
}

class _MermaidDiagramState extends State<MermaidDiagram> {
  bool _presentingFullscreen = false;
  String? _renderedCode;
  MermaidRenderResult? _lightRender;
  MermaidRenderResult? _darkRender;
  Object? _renderError;

  void _renderIfNeeded() {
    if (_renderedCode == widget.code) {
      return;
    }
    _renderedCode = widget.code;
    try {
      _lightRender = _render(
        widget.code,
        mermaid_core.MermaidTheme.defaultTheme,
      );
      _darkRender = _render(widget.code, mermaid_core.MermaidTheme.darkTheme);
      _renderError = null;
    } catch (error) {
      _lightRender = null;
      _darkRender = null;
      _renderError = error;
    }
  }

  MermaidRenderResult _render(String code, mermaid_core.MermaidTheme theme) {
    final scene = mermaid_core.Mermaid(
      measurer: const mermaid_flutter.FlutterTextMeasurer(),
      theme: theme,
    ).render(code);
    return MermaidRenderResult(
      svg: mermaid_core.renderSceneToSvg(scene),
      sceneSize: Size(scene.size.width, scene.size.height),
    );
  }

  Future<void> _openFullscreen() async {
    final callback = widget.onRequestFullscreen;
    final light = _lightRender;
    final dark = _darkRender;
    if (callback == null ||
        light == null ||
        dark == null ||
        _presentingFullscreen) {
      return;
    }
    setState(() {
      _presentingFullscreen = true;
    });
    await WidgetsBinding.instance.endOfFrame;
    try {
      await callback(light, dark);
    } finally {
      if (mounted) {
        setState(() {
          _presentingFullscreen = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    _renderIfNeeded();
    final render = widget.brightness == Brightness.dark
        ? _darkRender
        : _lightRender;
    Widget view = render != null
        ? Padding(
            padding: const EdgeInsets.all(Spacing.md),
            child: FittedBox(
              fit: BoxFit.contain,
              child: SvgPicture.string(
                render.svg,
                key: ValueKey(
                  'mermaid-${widget.brightness.name}-${widget.code.hashCode}',
                ),
                width: render.sceneSize.width,
                height: render.sceneSize.height,
              ),
            ),
          )
        : _buildError(
            context,
            _renderError ?? 'Unable to render Mermaid diagram.',
          );

    if (widget.allowFullscreen && widget.onRequestFullscreen != null) {
      view = Stack(
        children: [
          Positioned.fill(child: view),
          Positioned(
            top: 8,
            right: 8,
            child: Semantics(
              button: true,
              label: 'Open Mermaid preview',
              child: Material(
                color: Theme.of(context).colorScheme.surface,
                elevation: 1,
                shape: RoundedRectangleBorder(
                  side: BorderSide(
                    color: Theme.of(context).dividerColor,
                    width: BorderWidth.thin,
                  ),
                  borderRadius: BorderRadius.circular(AppBorderRadius.sm),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: _openFullscreen,
                  child: const SizedBox(
                    width: 36,
                    height: 36,
                    child: Icon(Icons.open_in_full, size: 18),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return SizedBox(
      height: _mermaidPreviewMinHeight,
      width: double.infinity,
      child: view,
    );
  }

  Widget _buildError(BuildContext context, Object error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: SelectableText(
          '$error',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.error,
          ),
        ),
      ),
    );
  }
}

class _MermaidSheetCanvas extends StatefulWidget {
  const _MermaidSheetCanvas({required this.svg, required this.sceneSize});

  final String svg;
  final Size sceneSize;

  @override
  State<_MermaidSheetCanvas> createState() => _MermaidSheetCanvasState();
}

class _MermaidSheetCanvasState extends State<_MermaidSheetCanvas> {
  static const double _minScale = 0.2;
  static const double _maxScale = 8;
  static const double _controlSize = 32;
  static const double _controlGap = 6;

  final TransformationController _controller = TransformationController();
  Size _viewportSize = Size.zero;
  bool _interactive = true;
  bool _resetScheduled = false;

  @override
  void didUpdateWidget(covariant _MermaidSheetCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.svg != widget.svg ||
        oldWidget.sceneSize != widget.sceneSize) {
      _scheduleReset(_viewportSize);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _scheduleReset(Size viewportSize) {
    if (viewportSize.isEmpty || _resetScheduled) return;
    _resetScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _resetScheduled = false;
      if (!mounted) return;
      _reset(viewportSize);
    });
  }

  void _reset([Size? viewportSize]) {
    final viewport = viewportSize ?? _viewportSize;
    if (viewport.isEmpty || widget.sceneSize.isEmpty) return;

    final availableWidth = math.max(1.0, viewport.width - (Spacing.lg * 2));
    final availableHeight = math.max(1.0, viewport.height - (Spacing.lg * 2));
    final scale = math
        .min(
          availableWidth / widget.sceneSize.width,
          availableHeight / widget.sceneSize.height,
        )
        .clamp(_minScale, 1.0)
        .toDouble();
    final dx = (viewport.width - (widget.sceneSize.width * scale)) / 2;
    final dy = (viewport.height - (widget.sceneSize.height * scale)) / 2;

    _controller.value = Matrix4.identity()
      ..setEntry(0, 0, scale)
      ..setEntry(1, 1, scale)
      ..setTranslationRaw(dx, dy, 0);
  }

  void _pan(Offset delta) {
    final next = Matrix4.copy(_controller.value);
    final translation = next.getTranslation();
    next.setTranslationRaw(
      translation.x + delta.dx,
      translation.y + delta.dy,
      translation.z,
    );
    _controller.value = next;
  }

  void _zoom(double factor) {
    if (_viewportSize.isEmpty) return;
    final current = _controller.value;
    final currentScale = current.getMaxScaleOnAxis();
    final targetScale = (currentScale * factor)
        .clamp(_minScale, _maxScale)
        .toDouble();
    if (targetScale == currentScale) return;

    final ratio = targetScale / currentScale;
    final center = _viewportSize.center(Offset.zero);
    final translation = current.getTranslation();
    final dx = center.dx - ((center.dx - translation.x) * ratio);
    final dy = center.dy - ((center.dy - translation.y) * ratio);

    _controller.value = Matrix4.identity()
      ..setEntry(0, 0, targetScale)
      ..setEntry(1, 1, targetScale)
      ..setTranslationRaw(dx, dy, 0);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final safePadding = MediaQuery.viewPaddingOf(context);
    final lockLabel = _interactive
        ? 'Lock pan and zoom'
        : 'Enable pan and zoom';

    return ColoredBox(
      color: colorScheme.surface,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final viewportSize = constraints.biggest;
          if (_viewportSize != viewportSize) {
            _viewportSize = viewportSize;
            _scheduleReset(viewportSize);
          }

          return Stack(
            children: [
              Positioned.fill(
                child: Semantics(
                  label: 'Interactive Mermaid diagram',
                  child: InteractiveViewer(
                    key: const ValueKey<String>(
                      'mermaid-sheet-interactive-viewer',
                    ),
                    transformationController: _controller,
                    constrained: false,
                    alignment: Alignment.topLeft,
                    boundaryMargin: const EdgeInsets.all(double.infinity),
                    minScale: _minScale,
                    maxScale: _maxScale,
                    panEnabled: _interactive,
                    scaleEnabled: _interactive,
                    child: SizedBox(
                      width: widget.sceneSize.width,
                      height: widget.sceneSize.height,
                      child: SvgPicture.string(
                        widget.svg,
                        key: ValueKey<String>(
                          'mermaid-sheet-${Theme.of(context).brightness.name}',
                        ),
                        width: widget.sceneSize.width,
                        height: widget.sceneSize.height,
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: Spacing.md,
                right: Spacing.lg,
                child: _MermaidCanvasControlButton(
                  label: lockLabel,
                  icon: Icons.open_with_rounded,
                  active: _interactive,
                  onPressed: () {
                    setState(() => _interactive = !_interactive);
                  },
                ),
              ),
              Positioned(
                right: Spacing.lg + safePadding.right,
                bottom: Spacing.lg + safePadding.bottom,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox.square(dimension: _controlSize),
                        const SizedBox(width: _controlGap),
                        _MermaidCanvasControlButton(
                          label: 'Pan up',
                          icon: Icons.arrow_upward_rounded,
                          onPressed: () => _pan(const Offset(0, -64)),
                        ),
                        const SizedBox(width: _controlGap),
                        _MermaidCanvasControlButton(
                          label: 'Zoom in',
                          icon: Icons.add_rounded,
                          onPressed: () => _zoom(1.25),
                        ),
                      ],
                    ),
                    const SizedBox(height: _controlGap),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _MermaidCanvasControlButton(
                          label: 'Pan left',
                          icon: Icons.arrow_back_rounded,
                          onPressed: () => _pan(const Offset(-64, 0)),
                        ),
                        const SizedBox(width: _controlGap),
                        _MermaidCanvasControlButton(
                          label: 'Reset diagram position',
                          icon: Icons.center_focus_strong_rounded,
                          onPressed: _reset,
                        ),
                        const SizedBox(width: _controlGap),
                        _MermaidCanvasControlButton(
                          label: 'Pan right',
                          icon: Icons.arrow_forward_rounded,
                          onPressed: () => _pan(const Offset(64, 0)),
                        ),
                      ],
                    ),
                    const SizedBox(height: _controlGap),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox.square(dimension: _controlSize),
                        const SizedBox(width: _controlGap),
                        _MermaidCanvasControlButton(
                          label: 'Pan down',
                          icon: Icons.arrow_downward_rounded,
                          onPressed: () => _pan(const Offset(0, 64)),
                        ),
                        const SizedBox(width: _controlGap),
                        _MermaidCanvasControlButton(
                          label: 'Zoom out',
                          icon: Icons.remove_rounded,
                          onPressed: () => _zoom(0.8),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _MermaidCanvasControlButton extends StatelessWidget {
  const _MermaidCanvasControlButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.active = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        child: ExcludeSemantics(
          child: SizedBox.square(
            dimension: _MermaidSheetCanvasState._controlSize,
            child: Material(
              color: active
                  ? colorScheme.secondaryContainer
                  : colorScheme.surfaceContainerHighest,
              elevation: Elevation.low,
              shape: RoundedRectangleBorder(
                side: BorderSide(
                  color: colorScheme.outlineVariant,
                  width: BorderWidth.thin,
                ),
                borderRadius: BorderRadius.circular(AppBorderRadius.sm),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onPressed,
                child: Icon(icon, size: 18, color: colorScheme.onSurface),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
