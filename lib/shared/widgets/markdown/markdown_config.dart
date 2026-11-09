import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:highlight/highlight.dart' show Node, highlight;
import 'package:mermaid_core/mermaid_core.dart' as mermaid_core;
import 'package:mermaid_flutter/mermaid_flutter.dart' as mermaid_flutter;

import 'package:conduit/l10n/app_localizations.dart';

import '../chat_action_button.dart' show NativeSymbolGlyph;
import '../web_content_embed.dart';
import '../webview_content_height.dart';
import '../horizontal_gesture_ownership.dart';
import '../themed_sheets.dart';
import '../../theme/color_tokens.dart';
import '../../theme/theme_extensions.dart';
import 'renderer/code_syntax_theme.dart';
import 'renderer/horizontal_overflow_fade.dart';
import 'renderer/markdown_style.dart';

import 'package:conduit/core/network/self_signed_image_cache_manager.dart';
import 'package:conduit/core/network/image_header_utils.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_markdown/conduit_markdown.dart'
    show codeLanguageDisplayName;
import 'package:conduit/shared/services/raster_media_policy.dart';
import 'package:conduit/shared/utils/platform_utils.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';

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
      _position?.isScrollingNotifier.removeListener(_scheduleViewportCheck);
      _position = nextPosition;
      _position?.addListener(_scheduleViewportCheck);
      // Hydration waits for the scroll to rest, so the transition back to
      // idle must re-run eligibility even though it changes no offset.
      _position?.isScrollingNotifier.addListener(_scheduleViewportCheck);
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
    _position?.isScrollingNotifier.removeListener(_scheduleViewportCheck);
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
    // Platform-view creation is a guaranteed hitch mid-fling. A preview that
    // is not yet hydrated keeps its fixed placeholder while the enclosing
    // scrollable is moving; the notifier's return to idle re-runs this check
    // and hydrates at rest. Already-active previews keep their eligibility so
    // motion never unmounts a live platform view.
    final scrollAtRest = !(_position?.isScrollingNotifier.value ?? false);
    final nextEligible =
        nextNearViewport && _routeVisible && (scrollAtRest || _active);
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
    String? stateId,
  }) {
    return CodeBlockCard(
      code: code,
      language: language,
      onPreview: onPreview,
      stateId: stateId,
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
      final decodeTarget = RasterMediaPolicy.forBox(
        context,
        profile: RasterDecodeProfile.inline,
        logicalWidth: math.min(MediaQuery.sizeOf(context).width, 480),
        logicalHeight: 480,
      );

      return Container(
        margin: const EdgeInsets.symmetric(vertical: Spacing.sm),
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 480),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppBorderRadius.md),
          child: Image(
            image: RasterMediaPolicy.resizeProvider(
              MemoryImage(imageBytes),
              decodeTarget,
            ),
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
        // Open WebUI stores an image a tool returned as a path on the server.
        final resolvedUrl = resolveServerRelativeImageUrlFromWidgetRef(
          ref,
          url,
        );
        final headers = buildImageHeadersForUrlFromWidgetRef(ref, resolvedUrl);
        final cacheKey = buildImageCacheKeyForUrlFromWidgetRef(
          ref,
          resolvedUrl,
        );
        final cacheManager = ref.watch(selfSignedImageCacheManagerProvider);
        final decodeTarget = RasterMediaPolicy.forBox(
          context,
          profile: RasterDecodeProfile.inline,
          logicalWidth: math.min(MediaQuery.sizeOf(context).width, 480),
          logicalHeight: 480,
        );

        final placeholder = Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: theme.surfaceContainer.withValues(alpha: 0.68),
          ),
          child: Center(
            child: SizedBox.square(
              dimension: IconSize.medium,
              child: AdaptiveProgressIndicator(
                color: theme.loadingIndicator,
                strokeWidth: 2,
              ),
            ),
          ),
        );
        return Container(
          margin: const EdgeInsets.symmetric(vertical: Spacing.sm),
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 480),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppBorderRadius.md),
            child: Image(
              image: RasterMediaPolicy.resizeProvider(
                CachedNetworkImageProvider(
                  resolvedUrl,
                  cacheKey: cacheKey,
                  cacheManager: cacheManager,
                  headers: headers,
                ),
                decodeTarget,
              ),
              width: double.infinity,
              fit: BoxFit.contain,
              frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                final loaded = wasSynchronouslyLoaded || frame != null;
                if (!loaded) {
                  return AspectRatio(aspectRatio: 16 / 9, child: placeholder);
                }
                return AnimatedOpacity(
                  opacity: 1,
                  duration: context.motionDuration(
                    AnimationDuration.microInteraction,
                  ),
                  curve: Curves.easeOutCubic,
                  child: child,
                );
              },
              errorBuilder: (context, error, stackTrace) =>
                  Center(child: buildImageError(context, theme)),
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
            magnifierConfiguration: nativeIosTextMagnifierConfiguration,
            style: markdownStyle.detailCode.copyWith(
              color: conduitTheme.codeText,
            ),
            contextMenuBuilder: AdaptiveTextSelectionMenu.editableText,
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

/// A fenced code block: a quiet rounded card with a header (the language,
/// a soft-wrap toggle once a line is too long, and Copy) above the code.
///
/// In a compact window (an iPhone, or a narrow iPad split) long lines wrap
/// inside the card, each continuation hanging under its line's indentation;
/// in a wide one they scroll sideways, fading out at the edge that hides
/// more, with a thin indicator while they move. The toggle switches one
/// block between the two, and the block keeps that choice while its page
/// lives.
class CodeBlockCard extends StatefulWidget {
  const CodeBlockCard({
    super.key,
    required this.code,
    required this.language,
    this.onPreview,
    this.stateId,
  });

  final String code;
  final String language;
  final VoidCallback? onPreview;

  /// Identifies this block on its page, so a wrap choice survives the block
  /// scrolling out of a list and back. Null keeps the choice in the widget.
  final String? stateId;

  /// Windows narrower than this are compact (every iPhone in portrait, an
  /// iPad split to a third or half): code wraps there by default.
  static const double compactWindowWidth = 600;

  /// Whether long code lines wrap by default in [context]'s window.
  static bool wrapsByDefault(BuildContext context) =>
      MediaQuery.sizeOf(context).width < compactWindowWidth;

  @override
  State<CodeBlockCard> createState() => _CodeBlockCardState();
}

class _CodeBlockCardState extends State<CodeBlockCard> {
  /// The reader's choice for this block; null follows the window's default.
  bool? _chosenSoftWrap;
  String? _restoredStateId;

  /// Whether a line is too long to show unwrapped: measured by the scroll
  /// view while lines scroll, or by the wrapped lines while they wrap.
  bool _overflows = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final stateId = widget.stateId;
    if (stateId != null && stateId != _restoredStateId) {
      _restoredStateId = stateId;
      final restored = PageStorage.maybeOf(context)
          ?.readState(context, identifier: stateId);
      if (restored is bool) _chosenSoftWrap = restored;
    }
  }

  /// Another block in this card's place takes that block's own choice, or
  /// the window's default when it has none.
  @override
  void didUpdateWidget(covariant CodeBlockCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final stateId = widget.stateId;
    if (stateId != null && stateId != oldWidget.stateId) {
      _restoredStateId = stateId;
      final restored = PageStorage.maybeOf(context)
          ?.readState(context, identifier: stateId);
      _chosenSoftWrap = restored is bool ? restored : null;
    }
  }

  bool _softWrap(BuildContext context) =>
      _chosenSoftWrap ?? CodeBlockCard.wrapsByDefault(context);

  void _toggleSoftWrap() {
    final next = !_softWrap(context);
    setState(() => _chosenSoftWrap = next);
    final stateId = widget.stateId;
    if (stateId != null) {
      PageStorage.maybeOf(context)
          ?.writeState(context, next, identifier: stateId);
    }
  }

  void _handleOverflowChanged(bool overflows) {
    if (!mounted || overflows == _overflows) return;
    setState(() => _overflows = overflows);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final markdownStyle = ConduitMarkdownStyle.fromTheme(context);
    final normalizedLanguage = widget.language.trim().isEmpty
        ? 'plaintext'
        : widget.language.trim();

    // Map common language aliases to highlight.js recognized names
    final highlightLanguage = ConduitMarkdown.mapLanguage(normalizedLanguage);

    // The card is a neutral tint of the label colour so it sits in the
    // monochrome page; syntax colours stay muted inside it.
    final highlightTheme = CodeSyntaxTheme.highlightTheme(isDark: isDark);
    final ink = markdownStyle.textPrimary;
    final codeBackground = ink.withValues(alpha: isDark ? 0.09 : 0.04);
    final borderColor = ink.withValues(alpha: isDark ? 0.10 : 0.07);
    final code = widget.code;
    final softWrap = _softWrap(context);

    return Container(
      decoration: BoxDecoration(
        color: codeBackground,
        borderRadius: BorderRadius.circular(markdownStyle.codeBlockRadius),
        border: Border.all(color: borderColor, width: BorderWidth.thin),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CodeBlockHeader(
            language: normalizedLanguage,
            backgroundColor: Colors.transparent,
            borderColor: borderColor,
            isDark: isDark,
            onPreview: widget.onPreview,
            // The source as written, however it is laid out on screen.
            onCopy: () => Clipboard.setData(ClipboardData(text: code)),
            softWrap: softWrap,
            // Only while a line is too long to show unwrapped; with every
            // line fitting, the toggle would change nothing.
            onToggleSoftWrap: _overflows ? _toggleSoftWrap : null,
          ),
          _CodeBlockBody(
            code: code,
            highlightLanguage: highlightLanguage,
            highlightTheme: highlightTheme,
            codeStyle: markdownStyle.codeBlock,
            isDark: isDark,
            dividerColor: borderColor,
            softWrap: softWrap,
            scrollIndicatorColor: markdownStyle.scrollIndicatorColor,
            scrollIndicatorInset: markdownStyle.codeBlockRadius,
            onOverflowChanged: _handleOverflowChanged,
          ),
        ],
      ),
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
  // Sized past one transcript's worth of code blocks: an entry is a small
  // span list, and a fling that cycles the cache re-runs highlight.parse.
  static const int maxEntries = 128;

  final LinkedHashMap<_HighlightCacheKey, List<TextSpan>> _cache =
      LinkedHashMap<_HighlightCacheKey, List<TextSpan>>();

  List<TextSpan>? peek(_HighlightCacheKey key) {
    final cached = _cache.remove(key);
    if (cached == null) return null;
    _cache[key] = cached;
    return cached;
  }

  void store(_HighlightCacheKey key, List<TextSpan> spans) {
    _cache.remove(key);
    if (_cache.length >= maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = spans;
  }

  List<TextSpan> resolve(
    _HighlightCacheKey key,
    List<TextSpan> Function() build,
  ) {
    final cached = peek(key);
    if (cached != null) return cached;
    final spans = build();
    store(key, spans);
    return spans;
  }
}

/// Runs `highlight.parse` off the UI isolate, one request at a time.
///
/// `highlight.parse` is regex-heavy and previously ran synchronously inside
/// the first build of every code block — a guaranteed frame spike when a
/// code-bearing row entered the cache extent mid-fling. Node trees are not
/// isolate-sendable with their styles attached, so the worker returns a plain
/// nested list and the caller applies the theme on the UI side (cheap object
/// construction).
class _HighlightParseQueue {
  final Map<String, Future<List<Object?>?>> _pending =
      <String, Future<List<Object?>?>>{};
  Future<void> _tail = Future<void>.value();

  Future<List<Object?>?> parse(String language, String code) {
    // Length-prefixing the language makes the concatenated key unambiguous:
    // without it, ("dart", "xcode") and ("dartx", "code") would collide.
    final key = '${language.length}:$language$code';
    final existing = _pending[key];
    if (existing != null) return existing;
    final request = _tail.then(
      (_) => compute(_highlightParseWorker, <String, String>{
        'language': language,
        'code': code,
      }),
    );
    _tail = request.then<void>((_) {}, onError: (_) {});
    _pending[key] = request;
    request.whenComplete(() {
      _pending.remove(key);
    });
    return request;
  }
}

final _highlightParseQueue = _HighlightParseQueue();

/// Top-level worker for [compute]: parse and encode as sendable nested lists
/// of `[value, className, children]`.
///
/// Language registration is isolate-safe by construction: `highlight` is
/// package:highlight's top-level `final Highlight()..registerLanguages(
/// allLanguages)`, a lazy static that re-initializes with the full language
/// set on first access in ANY isolate — nothing depends on UI-isolate-only
/// registration. Null (unknown language, malformed source) falls back to
/// plain monospace at the call site.
List<Object?>? _highlightParseWorker(Map<String, String> payload) {
  try {
    final nodes = highlight
        .parse(payload['code']!, language: payload['language']!)
        .nodes;
    if (nodes == null || nodes.isEmpty) return null;
    return nodes.map(_encodeHighlightNode).toList(growable: false);
  } catch (error) {
    // The caller renders plain text on null; surface the cause in debug
    // builds so a broken language pack doesn't silently disable
    // highlighting.
    DebugLogger.warning(
      'highlight-parse-failed',
      scope: 'markdown/highlight',
      data: {
        'language': payload['language'],
        'codeLength': payload['code']?.length,
        'error': error.toString(),
      },
    );
    return null;
  }
}

List<Object?> _encodeHighlightNode(Node node) => <Object?>[
  node.value,
  node.className,
  node.children?.map(_encodeHighlightNode).toList(growable: false),
];

List<TextSpan> _convertEncodedHighlightNodes(
  List<Object?> encodedNodes,
  Map<String, TextStyle> theme,
) {
  final spans = <TextSpan>[];
  for (final encoded in encodedNodes) {
    final node = encoded as List<Object?>;
    final value = node[0] as String?;
    final className = node[1] as String?;
    final children = node[2] as List<Object?>?;
    if (value != null) {
      spans.add(
        className == null
            ? TextSpan(text: value)
            : TextSpan(text: value, style: theme[className]),
      );
      continue;
    }
    if (children == null || children.isEmpty) continue;
    spans.add(
      TextSpan(
        children: _convertEncodedHighlightNodes(children, theme),
        style: className == null ? null : theme[className],
      ),
    );
  }
  return spans;
}

class _HighlightedCodeText extends StatefulWidget {
  const _HighlightedCodeText({
    required this.source,
    required this.language,
    required this.theme,
    required this.textStyle,
    required this.isDark,
    this.plainText = false,
    this.softWrap = false,
    this.onWrapsChanged,
  });

  static const _rootKey = 'root';
  static const _defaultFontColor = Color(0xff000000);
  static const _defaultFontFamily = 'monospace';

  /// At or below this size `highlight.parse` stays synchronous: the parse is
  /// cheaper than a queue round-trip and small snippets never flash unstyled.
  static const int _synchronousHighlightCharThreshold = 512;

  final String source;
  final String language;
  final Map<String, TextStyle> theme;
  final TextStyle textStyle;
  final bool isDark;
  final bool plainText;

  /// Wraps long lines, each continuation hanging under its line's
  /// indentation.
  final bool softWrap;

  /// With [softWrap], reports whether any line had to wrap.
  final ValueChanged<bool>? onWrapsChanged;

  @override
  State<_HighlightedCodeText> createState() => _HighlightedCodeTextState();
}

class _HighlightedCodeTextState extends State<_HighlightedCodeText> {
  List<TextSpan>? _spans;
  _HighlightCacheKey? _spansKey;
  _HighlightCacheKey? _requestedKey;

  _HighlightCacheKey get _cacheKey => _HighlightCacheKey(
    language: widget.language,
    code: widget.source,
    isDark: widget.isDark,
  );

  /// Highlighted spans if available now, otherwise null after arranging for
  /// them to arrive.
  ///
  /// Large sources parse on a worker isolate; plain monospace paints in the
  /// interim. The plain and highlighted trees hold identical text in one
  /// monospaced face (bold and italic keep its advance), so scrolling or
  /// wrapped, they occupy the same extent and the swap is paint-only — no
  /// timeline shift mid-scroll.
  List<TextSpan>? _resolveSpans() {
    final key = _cacheKey;
    if (_spans != null && key == _spansKey) {
      return _spans;
    }
    final cached = _highlightSpanCache.peek(key);
    if (cached != null) {
      _spans = cached;
      _spansKey = key;
      return cached;
    }
    // On web `compute` runs on the main thread anyway, so the queue would
    // only add latency. Widget tests stay synchronous for deterministic pumps.
    if (widget.source.length <=
            _HighlightedCodeText._synchronousHighlightCharThreshold ||
        kIsWeb ||
        _isRunningInWidgetTest()) {
      final spans = _buildHighlightedSpans(
        source: widget.source,
        language: widget.language,
        theme: widget.theme,
      );
      _highlightSpanCache.store(key, spans);
      _spans = spans;
      _spansKey = key;
      return spans;
    }
    if (key != _requestedKey) {
      _requestedKey = key;
      unawaited(
        _highlightParseQueue.parse(widget.language, widget.source).then((
          encoded,
        ) {
          if (!mounted || _cacheKey != key) return;
          final spans = encoded == null
              ? <TextSpan>[TextSpan(text: widget.source)]
              : _convertEncodedHighlightNodes(encoded, widget.theme);
          _highlightSpanCache.store(key, spans);
          setState(() {
            _spans = spans;
            _spansKey = key;
          });
        }),
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final rootStyle = TextStyle(
      fontFamily: _HighlightedCodeText._defaultFontFamily,
      color:
          widget.theme[_HighlightedCodeText._rootKey]?.color ??
          _HighlightedCodeText._defaultFontColor,
    ).merge(widget.textStyle);

    final children = widget.plainText
        ? <TextSpan>[TextSpan(text: widget.source)]
        : _resolveSpans() ?? <TextSpan>[TextSpan(text: widget.source)];

    if (widget.softWrap) {
      return _WrappedCodeLines(
        spans: children,
        rootStyle: rootStyle,
        textScaler: MediaQuery.textScalerOf(context),
        onWrapsChanged: widget.onWrapsChanged,
      );
    }

    return RichText(
      text: TextSpan(style: rootStyle, children: children),
      textScaler: MediaQuery.textScalerOf(context),
      textHeightBehavior: _codeTextHeightBehavior,
    );
  }
}

/// Code's 19 pt lines keep their leading between lines but not above the
/// first or below the last, where the block's padding alone sets the space;
/// otherwise the first line sits a near-empty line's depth below the header.
const _codeTextHeightBehavior = TextHeightBehavior(
  applyHeightToFirstAscent: false,
  applyHeightToLastDescent: false,
);

/// Soft-wrapped code, one source line at a time, so a wrapped line never
/// runs back to the left edge, where it would read as a new statement: the
/// line starts at its own indentation and its continuation hangs a little
/// further in, under its first characters, as an editor indents wrapped
/// lines, behind a dim ↳ at the line's own indentation. A hang alone read as
/// one more level of nesting (in Python, as code inside the line above).
///
/// Copy in the header copies the source as written, whatever the layout.
class _WrappedCodeLines extends StatelessWidget {
  const _WrappedCodeLines({
    required this.spans,
    required this.rootStyle,
    required this.textScaler,
    this.onWrapsChanged,
  });

  /// Columns a tab advances in leading indentation.
  static const int tabColumns = 4;

  /// Columns a wrapped line's continuation hangs in from the line's start:
  /// the continuation mark and a space, little enough to keep a phone's
  /// width for code.
  static const int hangingIndentColumns = 2;

  final List<TextSpan> spans;
  final TextStyle rootStyle;
  final TextScaler textScaler;

  /// Called after layout with whether any line wrapped.
  final ValueChanged<bool>? onWrapsChanged;

  @override
  Widget build(BuildContext context) {
    final lines = splitCodeLines(spans);
    final space = TextPainter(
      text: TextSpan(text: ' ', style: rootStyle),
      textScaler: textScaler,
      textDirection: TextDirection.ltr,
    )..layout();
    final columnWidth = space.width;
    space.dispose();

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        // Deeply nested lines still keep half the width for their text.
        final maxIndent = maxWidth.isFinite ? maxWidth / 2 : double.infinity;
        var wraps = false;
        final children = <Widget>[];
        for (final (index, line) in lines.indexed) {
          final indent = math.min(line.indentColumns * columnWidth, maxIndent);
          final textWidth = maxWidth - indent;
          final split = maxWidth.isFinite
              ? _splitAtFirstBreak(line.runs, textWidth, columnWidth)
              : null;
          wraps = wraps || split != null;
          final child = _CodeLineText(
            head: split?.head ?? line.runs,
            tail: split?.tail,
            // Never more than a quarter of the line's room.
            hang: math.min(
              hangingIndentColumns * columnWidth,
              math.max(0, textWidth / 4),
            ),
            columnWidth: columnWidth,
            rootStyle: rootStyle,
            textScaler: textScaler,
            isFirst: index == 0,
            isLast: index == lines.length - 1,
          );
          children.add(
            Padding(
              padding: EdgeInsets.only(left: indent),
              child: child,
            ),
          );
        }
        final onWrapsChanged = this.onWrapsChanged;
        if (onWrapsChanged != null) {
          final wrapped = wraps;
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => onWrapsChanged(wrapped),
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        );
      },
    );
  }

  /// [runs] split where they first wrap at [width], or null when they fit
  /// on one line.
  ({List<TextSpan> head, List<TextSpan> tail})? _splitAtFirstBreak(
    List<TextSpan> runs,
    double width,
    double columnWidth,
  ) {
    if (runs.isEmpty || width <= 0) return null;
    // Plain ASCII advances exactly one column per character, so a line
    // with a column to spare fits without laying it out.
    var length = 0;
    var ascii = true;
    for (final run in runs) {
      final text = run.text!;
      length += text.length;
      if (ascii) {
        for (final unit in text.codeUnits) {
          if (unit < 0x20 || unit > 0x7e) {
            ascii = false;
            break;
          }
        }
      }
    }
    if (ascii && (length + 1) * columnWidth <= width) return null;

    final painter = TextPainter(
      text: TextSpan(style: rootStyle, children: runs),
      textScaler: textScaler,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width);
    try {
      final metrics = painter.computeLineMetrics();
      if (metrics.length < 2) return null;
      // The first character of the second line.
      final breakAt = painter
          .getPositionForOffset(Offset(0, metrics[1].baseline))
          .offset;
      if (breakAt <= 0 || breakAt >= length) return null;
      return _splitRuns(runs, breakAt);
    } finally {
      painter.dispose();
    }
  }

  static ({List<TextSpan> head, List<TextSpan> tail}) _splitRuns(
    List<TextSpan> runs,
    int offset,
  ) {
    final head = <TextSpan>[];
    final tail = <TextSpan>[];
    var start = 0;
    for (final run in runs) {
      final text = run.text!;
      final end = start + text.length;
      if (end <= offset) {
        head.add(run);
      } else if (start >= offset) {
        tail.add(run);
      } else {
        head.add(
          TextSpan(text: text.substring(0, offset - start), style: run.style),
        );
        tail.add(
          TextSpan(text: text.substring(offset - start), style: run.style),
        );
      }
      start = end;
    }
    return (head: head, tail: tail);
  }

  /// Splits highlighted [spans] into source lines of flat, fully styled
  /// runs, with each line's leading indentation removed and counted.
  static List<({int indentColumns, List<TextSpan> runs})> splitCodeLines(
    List<TextSpan> spans,
  ) {
    final lines = <List<TextSpan>>[<TextSpan>[]];
    void visit(InlineSpan span, TextStyle? inherited) {
      if (span is! TextSpan) return;
      final own = span.style;
      final style = inherited == null
          ? own
          : (own == null ? inherited : inherited.merge(own));
      final text = span.text;
      if (text != null && text.isNotEmpty) {
        final parts = text.split('\n');
        for (var i = 0; i < parts.length; i++) {
          if (i > 0) lines.add(<TextSpan>[]);
          if (parts[i].isNotEmpty) {
            lines.last.add(TextSpan(text: parts[i], style: style));
          }
        }
      }
      for (final child in span.children ?? const <InlineSpan>[]) {
        visit(child, style);
      }
    }

    for (final span in spans) {
      visit(span, null);
    }
    return [for (final runs in lines) _stripIndent(runs)];
  }

  static ({int indentColumns, List<TextSpan> runs}) _stripIndent(
    List<TextSpan> runs,
  ) {
    var columns = 0;
    var leading = true;
    final stripped = <TextSpan>[];
    for (final run in runs) {
      if (!leading) {
        stripped.add(run);
        continue;
      }
      final text = run.text!;
      var index = 0;
      while (index < text.length &&
          (text[index] == ' ' || text[index] == '\t')) {
        columns += text[index] == '\t' ? tabColumns : 1;
        index++;
      }
      if (index < text.length) {
        leading = false;
        stripped.add(TextSpan(text: text.substring(index), style: run.style));
      }
    }
    return (indentColumns: leading ? 0 : columns, runs: stripped);
  }
}

/// One source line of wrapped code: its first visual line, then the rest
/// hanging [hang] further in, each of its lines led by a dim continuation
/// mark in the hang.
class _CodeLineText extends StatelessWidget {
  const _CodeLineText({
    required this.head,
    required this.tail,
    required this.hang,
    required this.columnWidth,
    required this.rootStyle,
    required this.textScaler,
    required this.isFirst,
    required this.isLast,
  });

  final List<TextSpan> head;
  final List<TextSpan>? tail;
  final double hang;

  /// One character's advance: the hang needs room for the mark and a space.
  final double columnWidth;
  final TextStyle rootStyle;
  final TextScaler textScaler;
  final bool isFirst;
  final bool isLast;

  Widget _paragraph(
    List<TextSpan> runs, {
    required bool first,
    required bool last,
  }) => RichText(
    text: TextSpan(
      style: rootStyle,
      // A blank line keeps its height.
      children: runs.isEmpty ? const [TextSpan(text: ' ')] : runs,
    ),
    textScaler: textScaler,
    // Only the block's outer edges drop their leading, as the unwrapped
    // paragraph does.
    textHeightBehavior: TextHeightBehavior(
      applyHeightToFirstAscent: !first,
      applyHeightToLastDescent: !last,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final tail = this.tail;
    if (tail == null) {
      return _paragraph(head, first: isFirst, last: isLast);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _paragraph(head, first: isFirst, last: false),
        Stack(
          children: [
            Padding(
              padding: EdgeInsets.only(left: hang),
              child: _paragraph(tail, first: false, last: isLast),
            ),
            // A dim return arrow leads each continuation in the hang, so a
            // wrapped line never reads as a nested one. Painted rather than
            // set as text: it is not part of the code, to read or to copy.
            if (hang >= columnWidth * 1.5)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: hang,
                child: CustomPaint(
                  key: const ValueKey<String>('code-continuation-mark'),
                  painter: _ContinuationMarkPainter(
                    style: rootStyle.copyWith(
                      color: (rootStyle.color ?? const Color(0xFF000000))
                          .withValues(
                            alpha:
                                (rootStyle.color?.a ?? 1) *
                                _ContinuationMarkPainter.opacity,
                          ),
                      fontWeight: FontWeight.w400,
                    ),
                    textScaler: textScaler,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Paints [mark] at the start of every visual line of a wrapped line's
/// continuation, on the code's own baseline.
class _ContinuationMarkPainter extends CustomPainter {
  _ContinuationMarkPainter({required this.style, required this.textScaler});

  /// Down-then-right: this line goes on from the one above.
  static const String mark = '↳';

  /// Share of the code's colour the mark is drawn in: present, but quieter
  /// than any code.
  static const double opacity = 0.4;

  final TextStyle style;
  final TextScaler textScaler;

  @override
  void paint(Canvas canvas, Size size) {
    final fontSize = style.fontSize ?? 13;
    final lineHeight = textScaler.scale(fontSize) * (style.height ?? 1);
    if (lineHeight <= 0) return;
    final painter = TextPainter(
      text: TextSpan(text: mark, style: style),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      // The code's own line box, whatever font the arrow falls back to, so
      // it sits on the code's baseline.
      strutStyle: StrutStyle.fromTextStyle(style, forceStrutHeight: true),
      textHeightBehavior: const TextHeightBehavior(),
    )..layout();
    final lines = math.max(1, (size.height / lineHeight).round());
    for (var line = 0; line < lines; line++) {
      painter.paint(canvas, Offset(0, line * lineHeight));
    }
    painter.dispose();
  }

  @override
  bool shouldRepaint(_ContinuationMarkPainter oldDelegate) =>
      oldDelegate.style != style || oldDelegate.textScaler != textScaler;
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
    required this.dividerColor,
    required this.softWrap,
    required this.scrollIndicatorColor,
    required this.scrollIndicatorInset,
    required this.onOverflowChanged,
  });

  final String code;
  final String highlightLanguage;
  final Map<String, TextStyle> highlightTheme;
  final TextStyle codeStyle;
  final bool isDark;
  final Color dividerColor;

  /// Wraps long lines inside the card instead of scrolling sideways.
  final bool softWrap;
  final Color scrollIndicatorColor;
  final double scrollIndicatorInset;

  /// Reports whether unwrapped code is wider than the card: while lines
  /// scroll, from the scroll view; while they wrap, from whether any did.
  final ValueChanged<bool> onOverflowChanged;

  /// Inner padding before the code's leading edge, and on both sides of
  /// wrapped code.
  static const double padding = Spacing.md - Spacing.xs;

  /// Padding after the end of a line that scrolls: when a line runs on, the
  /// fade ends this far inside the card's edge; scrolled to its end, the
  /// line rests this far from it.
  static const double trailingPadding = Spacing.md;

  /// Padding above the first line and below the last. With the lines'
  /// outer leading trimmed (see [_codeTextHeightBehavior]), SF Mono's cap
  /// height sits about 13 pt below the header and the last baseline about
  /// 13 pt above the card's edge: the same optical inset as the glyphs keep
  /// from the leading edge.
  static const double verticalPadding = Spacing.sm + Spacing.xxs;

  static const EdgeInsetsDirectional scrollingPadding =
      EdgeInsetsDirectional.fromSTEB(
        padding,
        verticalPadding,
        trailingPadding,
        verticalPadding,
      );

  static const EdgeInsets wrappedPadding = EdgeInsets.symmetric(
    horizontal: padding,
    vertical: verticalPadding,
  );

  /// Width of the fade at an edge that hides part of a long line, inside the
  /// padding margin: about three characters, so a cut line visibly runs on.
  static const double edgeFadeExtent = 24;

  /// Lines above this count trigger collapse behavior.
  static const collapseThreshold = 15;

  /// Number of lines visible when collapsed.
  static const previewLines = 10;

  static const largeJsonPlainPreviewLineThreshold = 60;
  static const largeJsonPlainPreviewCharThreshold = 4000;

  /// Above this size, code renders unhighlighted in any language.
  /// `highlight.parse` runs synchronously in build; on an expanded block that
  /// is still streaming it would re-parse the whole source on every flush.
  // ponytail: hard cap instead of incremental/off-thread highlighting; move
  // highlighting into the compiler isolate if large code blocks matter.
  static const largePlainRenderCharThreshold = 50000;

  @override
  State<_CodeBlockBody> createState() => _CodeBlockBodyState();
}

class _CodeBlockBodyState extends State<_CodeBlockBody> {
  bool _isCollapsed = true;
  String? _linesSource;
  List<String> _lines = const <String>[];

  List<String> _splitLines() {
    if (!identical(_linesSource, widget.code)) {
      _linesSource = widget.code;
      _lines = widget.code.split('\n');
    }
    return _lines;
  }

  @override
  Widget build(BuildContext context) {
    final lines = _splitLines();
    final isCollapsible = lines.length > _CodeBlockBody.collapseThreshold;
    final displayCode = (isCollapsible && _isCollapsed)
        ? lines.take(_CodeBlockBody.previewLines).join('\n')
        : widget.code;
    final hiddenCount = lines.length - _CodeBlockBody.previewLines;
    final renderPlainPreview =
        displayCode.length > _CodeBlockBody.largePlainRenderCharThreshold ||
        (_isCollapsed &&
            widget.highlightLanguage == 'json' &&
            (lines.length > _CodeBlockBody.largeJsonPlainPreviewLineThreshold ||
                widget.code.length >
                    _CodeBlockBody.largeJsonPlainPreviewCharThreshold));

    final highlighted = _HighlightedCodeText(
      source: displayCode,
      language: widget.highlightLanguage,
      theme: widget.highlightTheme,
      textStyle: widget.codeStyle,
      isDark: widget.isDark,
      plainText: renderPlainPreview,
      softWrap: widget.softWrap,
      // A line that wraps is one that would run past the card unwrapped.
      onWrapsChanged: widget.softWrap ? widget.onOverflowChanged : null,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.softWrap)
          Padding(padding: _CodeBlockBody.wrappedPadding, child: highlighted)
        else
          // Long lines scroll sideways. At an edge that hides more of a line
          // the code fades out over a few characters before the padding, so
          // the line visibly runs on and no glyph is cut at the card's edge,
          // and a thin indicator shows where the view is while it moves.
          HorizontalOverflowFade(
            fadeExtent: _CodeBlockBody.edgeFadeExtent,
            edgeInset: _CodeBlockBody.padding,
            endEdgeInset: _CodeBlockBody.trailingPadding,
            scrollIndicatorColor: widget.scrollIndicatorColor,
            scrollIndicatorInset: widget.scrollIndicatorInset,
            onOverflowChanged: widget.onOverflowChanged,
            builder: (context, controller) => HorizontalScrollGestureBoundary(
              child: SingleChildScrollView(
                controller: controller,
                scrollDirection: Axis.horizontal,
                padding: _CodeBlockBody.scrollingPadding,
                child: highlighted,
              ),
            ),
          ),
        if (isCollapsible)
          _CollapseToggle(
            isCollapsed: _isCollapsed,
            hiddenLineCount: hiddenCount,
            dividerColor: widget.dividerColor,
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
    required this.dividerColor,
    required this.onToggle,
  });

  final bool isCollapsed;
  final int hiddenLineCount;
  final Color dividerColor;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final labelColor = ConduitMarkdownStyle.fromTheme(context).textSecondary;
    final borderColor = dividerColor;

    return GestureDetector(
      onTap: onToggle,
      behavior: HitTestBehavior.opaque,
      child: Container(
        constraints: const BoxConstraints(minHeight: CodeBlockHeader.height),
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.md - Spacing.xs,
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
                isCollapsed
                    ? AppLocalizations.of(context)!
                          .markdownShowMoreLines(hiddenLineCount)
                    : AppLocalizations.of(context)!.markdownShowLess,
                key: ValueKey(isCollapsed),
                style: AppTypography.bodySmallStyle.copyWith(color: labelColor),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Code block header: the language's proper name in secondary system text,
/// a soft-wrap toggle when lines are too long to show, and a copy button
/// that confirms in place ("Copied" with a checkmark) instead of raising a
/// toast.
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
    this.softWrap = false,
    this.onToggleSoftWrap,
  });

  /// How long the copied confirmation stays before the button resets.
  static const copiedConfirmationDuration = Duration(milliseconds: 1200);

  /// Header height, matching a compact iOS toolbar row.
  static const double height = 36;

  /// Copy's glyph: the same two squares as the reply actions' Copy, so the
  /// action reads the same wherever it appears.
  static const String copySymbol = 'square.on.square';

  /// Point size of the native copy and copied glyphs: the squares ink about
  /// 14 pt across, no taller than the glyph they replace and in step with
  /// the 13 pt label and the wrap glyph. The reply row draws the same symbol
  /// at 16 pt, in proportion to its larger glyphs.
  static const double copyGlyphSize = 14;

  final String language;
  final Color backgroundColor;
  final Color borderColor;
  final bool isDark;
  final VoidCallback? onPreview;
  final FutureOr<void> Function() onCopy;

  /// Whether long lines currently wrap.
  final bool softWrap;

  /// Toggles [softWrap]; null hides the toggle (every line fits).
  final VoidCallback? onToggleSoftWrap;

  @override
  State<CodeBlockHeader> createState() => _CodeBlockHeaderState();
}

class _CodeBlockHeaderState extends State<CodeBlockHeader> {
  bool _isCopied = false;
  Timer? _resetTimer;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  Future<void> _handleCopy() async {
    await widget.onCopy();
    if (!mounted) return;
    PlatformUtils.lightHaptic();
    final l10n = AppLocalizations.of(context);
    final view = View.maybeOf(context);
    if (view != null && l10n != null) {
      unawaited(
        SemanticsService.sendAnnouncement(
          view,
          l10n.codeCopiedToClipboard,
          Directionality.of(context),
        ),
      );
    }
    _resetTimer?.cancel();
    setState(() => _isCopied = true);
    _resetTimer = Timer(CodeBlockHeader.copiedConfirmationDuration, () {
      if (mounted) setState(() => _isCopied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final markdownStyle = ConduitMarkdownStyle.fromTheme(context);
    final l10n = AppLocalizations.of(context);
    final label =
        codeLanguageDisplayName(widget.language) ??
        l10n?.codeBlockPlainText ??
        'Plain Text';
    final cupertino = context.usesCupertinoChrome;
    final secondary = markdownStyle.textSecondary;
    final chromeText = AppTypography.bodySmallStyle.copyWith(
      color: secondary,
      fontWeight: FontWeight.w400,
    );
    final duration = context.motionDuration(AnimationDuration.fast);

    final copyIcon = _isCopied
        ? (cupertino ? CupertinoIcons.checkmark_alt : Icons.check_rounded)
        : (cupertino
              ? CupertinoIcons.square_on_square
              : Icons.content_copy_rounded);
    // On iOS the glyph is UIKit's own SF Symbol, drawn as the reply actions
    // draw theirs.
    final Widget copyGlyph = cupertino && NativeSymbolGlyph.isAvailable
        ? NativeSymbolGlyph(
            key: ValueKey(_isCopied),
            symbol: _isCopied ? 'checkmark' : CodeBlockHeader.copySymbol,
            fallbackIcon: copyIcon,
            pointSize: CodeBlockHeader.copyGlyphSize,
            color: secondary,
          )
        : Icon(
            copyIcon,
            key: ValueKey(_isCopied),
            size: IconSize.sm,
            color: secondary,
          );

    return Container(
      height: CodeBlockHeader.height,
      padding: const EdgeInsetsDirectional.only(start: Spacing.md - Spacing.xs),
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
          Expanded(
            child: Text(
              label,
              style: chromeText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (widget.onPreview != null)
            _CodeBlockActionButton(
              icon: cupertino ? CupertinoIcons.eye : Icons.visibility_outlined,
              label: l10n?.preview ?? 'Preview',
              color: secondary,
              onTap: widget.onPreview!,
            ),
          _SoftWrapToggle(
            visible: widget.onToggleSoftWrap != null,
            selected: widget.softWrap,
            label: l10n?.codeBlockWrapLines ?? 'Wrap Lines',
            color: secondary,
            selectedColor: markdownStyle.textPrimary,
            selectedBackground: markdownStyle.textPrimary.withValues(
              alpha: widget.isDark ? 0.14 : 0.08,
            ),
            duration: duration,
            onTap: widget.onToggleSoftWrap,
          ),
          Semantics(
            button: true,
            label: _isCopied ? l10n?.codeCopied : l10n?.copy,
            onTap: _handleCopy,
            excludeSemantics: true,
            child: GestureDetector(
              onTap: _handleCopy,
              behavior: HitTestBehavior.opaque,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minWidth: 44,
                  minHeight: CodeBlockHeader.height,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Spacing.md - Spacing.xs,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      AnimatedSize(
                        duration: duration,
                        curve: Curves.easeOutCubic,
                        child: AnimatedSwitcher(
                          duration: duration,
                          child: _isCopied
                              ? Padding(
                                  key: const ValueKey('copied'),
                                  padding: const EdgeInsetsDirectional.only(
                                    end: Spacing.xs + Spacing.xxs,
                                  ),
                                  child: Text(
                                    l10n?.codeCopied ?? 'Copied',
                                    style: chromeText,
                                  ),
                                )
                              : const SizedBox.shrink(key: ValueKey('idle')),
                        ),
                      ),
                      AnimatedSwitcher(
                        duration: duration,
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: ScaleTransition(
                            scale: Tween<double>(
                              begin: 0.8,
                              end: 1,
                            ).animate(animation),
                            child: child,
                          ),
                        ),
                        child: copyGlyph,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Header toggle that wraps long code lines. Fades in once a line is too
/// long to show and sits in a soft capsule while wrapping is on.
class _SoftWrapToggle extends StatelessWidget {
  const _SoftWrapToggle({
    required this.visible,
    required this.selected,
    required this.label,
    required this.color,
    required this.selectedColor,
    required this.selectedBackground,
    required this.duration,
    required this.onTap,
  });

  final bool visible;
  final bool selected;
  final String label;
  final Color color;
  final Color selectedColor;
  final Color selectedBackground;
  final Duration duration;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final toggle = Semantics(
      button: true,
      enabled: onTap != null,
      toggled: selected,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: 44,
            minHeight: CodeBlockHeader.height,
          ),
          child: Center(
            child: AnimatedContainer(
              duration: duration,
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.xs + Spacing.xxs,
                vertical: Spacing.xxs,
              ),
              decoration: BoxDecoration(
                color: selected
                    ? selectedBackground
                    : selectedBackground.withValues(alpha: 0),
                borderRadius: BorderRadius.circular(AppBorderRadius.xs + 2),
              ),
              child: Icon(
                Icons.wrap_text_rounded,
                size: IconSize.sm + 2,
                color: selected ? selectedColor : color,
              ),
            ),
          ),
        ),
      ),
    );
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeOutCubic,
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: visible
          ? KeyedSubtree(key: const ValueKey('wrap'), child: toggle)
          : const SizedBox.shrink(key: ValueKey('none')),
    );
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
    return Semantics(
      button: true,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: 44,
            minHeight: CodeBlockHeader.height,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: IconSize.sm, color: color),
                const SizedBox(width: Spacing.xs),
                Text(
                  label,
                  style: AppTypography.bodySmallStyle.copyWith(color: color),
                ),
              ],
            ),
          ),
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
        child: Center(child: AdaptiveProgressIndicator()),
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
                child: Center(child: AdaptiveProgressIndicator()),
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
    if (_renderedCode != widget.code) {
      _renderedCode = widget.code;
      _lightRender = null;
      _darkRender = null;
      _renderError = null;
    }

    final needsActiveRender = widget.brightness == Brightness.dark
        ? _darkRender == null
        : _lightRender == null;
    if (!needsActiveRender) return;

    try {
      if (widget.brightness == Brightness.dark) {
        _darkRender = _render(widget.code, mermaid_core.MermaidTheme.darkTheme);
      } else {
        _lightRender = _render(
          widget.code,
          mermaid_core.MermaidTheme.defaultTheme,
        );
      }
      _renderError = null;
    } catch (error) {
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
    if (callback == null || _presentingFullscreen) {
      return;
    }
    final code = widget.code;
    setState(() {
      _presentingFullscreen = true;
    });
    await WidgetsBinding.instance.endOfFrame;
    try {
      if (!mounted || widget.code != code) return;

      MermaidRenderResult light;
      MermaidRenderResult dark;
      try {
        light =
            _lightRender ??
            _render(code, mermaid_core.MermaidTheme.defaultTheme);
        dark =
            _darkRender ?? _render(code, mermaid_core.MermaidTheme.darkTheme);
        _lightRender = light;
        _darkRender = dark;
        _renderError = null;
      } catch (error) {
        if (mounted) {
          setState(() {
            _renderError = error;
          });
        }
        return;
      }

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
          magnifierConfiguration: nativeIosTextMagnifierConfiguration,
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.error),
          contextMenuBuilder: AdaptiveTextSelectionMenu.editableText,
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
                          label: 'Pan Up',
                          icon: Icons.arrow_upward_rounded,
                          onPressed: () => _pan(const Offset(0, -64)),
                        ),
                        const SizedBox(width: _controlGap),
                        _MermaidCanvasControlButton(
                          label: 'Zoom In',
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
                          label: 'Pan Left',
                          icon: Icons.arrow_back_rounded,
                          onPressed: () => _pan(const Offset(-64, 0)),
                        ),
                        const SizedBox(width: _controlGap),
                        _MermaidCanvasControlButton(
                          label: 'Reset Diagram Position',
                          icon: Icons.center_focus_strong_rounded,
                          onPressed: _reset,
                        ),
                        const SizedBox(width: _controlGap),
                        _MermaidCanvasControlButton(
                          label: 'Pan Right',
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
                          label: 'Pan Down',
                          icon: Icons.arrow_downward_rounded,
                          onPressed: () => _pan(const Offset(0, 64)),
                        ),
                        const SizedBox(width: _controlGap),
                        _MermaidCanvasControlButton(
                          label: 'Zoom Out',
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
    if (PlatformUiCapabilities.usesNativeIOS26) {
      return AdaptiveTooltip(
        message: label,
        excludeFromSemantics: true,
        child: AdaptiveButton.icon(
          onPressed: onPressed,
          icon: icon,
          iconSize: 18,
          semanticLabel: label,
          style: active
              ? AdaptiveButtonStyle.prominentGlass
              : AdaptiveButtonStyle.glass,
          minSize: const Size.square(_MermaidSheetCanvasState._controlSize),
          padding: EdgeInsets.zero,
          borderRadius: BorderRadius.circular(AppBorderRadius.sm),
          useSmoothRectangleBorder: false,
        ),
      );
    }
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        onTap: onPressed,
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
                child: Icon(
                  icon,
                  size: 18,
                  color: active
                      ? colorScheme.onSecondaryContainer
                      : colorScheme.onSurface,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
