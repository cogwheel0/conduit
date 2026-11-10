import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../theme/theme_extensions.dart';
import '../adaptive_route_shell.dart';
import '../adaptive_toolbar_components.dart';
import '../chrome_gradient_fade.dart';
import '../platform_ui/platform_ui.dart';
import 'utility_grouped_surfaces.dart';

/// Standard shell for settings and other calm, grouped utility screens.
///
/// The native scaffold owns the navigation inset. Content therefore starts at
/// one standard page gap, avoiding a second status-bar and app-bar offset on
/// iOS.
@immutable
final class UtilityBackNavigation {
  const UtilityBackNavigation({
    required this.label,
    required this.buttonKey,
    required this.onPressed,
  });

  final String label;
  final Key buttonKey;
  final VoidCallback onPressed;
}

class UtilityPageScaffold extends StatefulWidget {
  UtilityPageScaffold._({
    super.key,
    required this.title,
    required List<Widget> content,
    required this.maxWidth,
    required this.interactiveScrollbar,
    this.bottomAction,
    this.backgroundColor,
    this.physics,
    this.contentPadding,
    this.backNavigation,
    this.bottomActionPadding,
    this.onTitleLongPress,
    this.trailing,
    this.largeTitle = false,
    this.largeTitleHeader,
    this.systemListMargins = false,
  }) : content = List<Widget>.unmodifiable(content);

  factory UtilityPageScaffold.auth({
    Key? key,
    required String title,
    required Widget body,
    UtilityBackNavigation? backNavigation,
    Widget? bottomAction,
    Color? backgroundColor,
    VoidCallback? onTitleLongPress,
    bool largeTitle = false,
    Widget? largeTitleHeader,
  }) => UtilityPageScaffold._(
    key: key,
    title: title,
    content: [body],
    maxWidth: 480,
    bottomAction: bottomAction,
    backgroundColor: backgroundColor,
    physics: const BouncingScrollPhysics(
      parent: AlwaysScrollableScrollPhysics(),
    ),
    contentPadding: const EdgeInsets.fromLTRB(
      Spacing.pagePadding,
      Spacing.lg,
      Spacing.pagePadding,
      Spacing.xl,
    ),
    backNavigation: backNavigation,
    interactiveScrollbar: true,
    bottomActionPadding: const EdgeInsets.fromLTRB(
      Spacing.pagePadding,
      Spacing.md,
      Spacing.pagePadding,
      Spacing.md,
    ),
    onTitleLongPress: onTitleLongPress,
    largeTitle: largeTitle,
    largeTitleHeader: largeTitleHeader,
    systemListMargins: true,
  );

  factory UtilityPageScaffold.settings({
    Key? key,
    required String title,
    required List<Widget> children,
    Color? backgroundColor,
    Widget? trailing,
    EdgeInsetsGeometry? contentPadding,
  }) => UtilityPageScaffold._(
    key: key,
    title: title,
    content: children,
    maxWidth: 640,
    interactiveScrollbar: false,
    backgroundColor: backgroundColor,
    trailing: trailing,
    contentPadding: contentPadding,
  );

  final String title;
  final List<Widget> content;
  final double maxWidth;
  final Widget? bottomAction;
  final Color? backgroundColor;
  final ScrollPhysics? physics;
  final EdgeInsetsGeometry? contentPadding;
  final UtilityBackNavigation? backNavigation;
  final bool interactiveScrollbar;
  final EdgeInsets? bottomActionPadding;
  final VoidCallback? onTitleLongPress;
  final Widget? trailing;

  /// On iOS, shows [title] as a large title at the top of the content, and
  /// in the bar, semibold, only once the large title has scrolled under it.
  /// Material keeps its regular app bar title.
  final bool largeTitle;

  /// A header of the page's own in the large title's place, such as a
  /// welcome hero, on every platform; the bar shows [title] only once it has
  /// scrolled away.
  final Widget? largeTitleHeader;

  /// On iOS, insets the content and the bottom action by the margins UIKit
  /// gives an inset-grouped list on this screen width, so grouped cards
  /// line up with the native settings sheets' cards.
  final bool systemListMargins;

  @override
  State<UtilityPageScaffold> createState() => _UtilityPageScaffoldState();
}

class _UtilityPageScaffoldState extends State<UtilityPageScaffold> {
  final ScrollController _controller = ScrollController();
  final GlobalKey _largeTitleKey = GlobalKey();

  /// Content inset above the large title, from the last build.
  double _largeTitleTop = 0;
  bool _inlineTitleShown = false;

  /// Whether content continues below the bottom edge. A page with nothing
  /// pinned under its list fades its rows out above the home indicator
  /// then, as iOS's scroll edge does, instead of cutting them off under it.
  bool _contentBelow = false;

  bool _handleScrollMetrics(ScrollMetrics metrics) {
    if (metrics.axis != Axis.vertical) return false;
    final below = metrics.extentAfter > 0.5;
    if (below != _contentBelow) setState(() => _contentBelow = below);
    return false;
  }

  @override
  void initState() {
    super.initState();
    _controller.addListener(_syncInlineTitle);
  }

  @override
  void dispose() {
    _controller.removeListener(_syncInlineTitle);
    _controller.dispose();
    super.dispose();
  }

  /// The bar's title appears once half the large title has scrolled
  /// under the bar, as a native large title collapses into it. A header of
  /// the page's own (a welcome hero) leads with artwork above its title, so
  /// its title reaches the bar sooner: at [_customHeaderCollapseShare] of
  /// its height. Either way the bar takes the title by the end of the list,
  /// so a short page never rests with its title cut off and none in the bar.
  void _syncInlineTitle() {
    if (!_largeTitleActive(context) || !_controller.hasClients) return;
    final box = _largeTitleKey.currentContext?.findRenderObject();
    final height = box is RenderBox && box.hasSize ? box.size.height : 0.0;
    final share = widget.largeTitleHeader == null
        ? 0.5
        : _customHeaderCollapseShare;
    final position = _controller.position;
    final threshold = _largeTitleTop + height * share;
    final atEnd =
        position.hasContentDimensions &&
        position.maxScrollExtent > _largeTitleTop + height * 0.25 &&
        position.pixels >= position.maxScrollExtent - 0.5;
    final shown = _controller.offset > threshold || atEnd;
    if (shown != _inlineTitleShown) {
      setState(() => _inlineTitleShown = shown);
    }
  }

  bool _largeTitleActive(BuildContext context) =>
      widget.largeTitleHeader != null ||
      (widget.largeTitle && context.usesCupertinoChrome);

  Widget _buildLargeTitle(BuildContext context) {
    final header =
        widget.largeTitleHeader ??
        Padding(
          padding: const EdgeInsets.only(bottom: Spacing.md),
          child: Semantics(
            header: true,
            child: Text(
              widget.title,
              style: AppTypography.displayLargeStyle.copyWith(
                color: context.conduitTheme.textPrimary,
              ),
            ),
          ),
        );
    final onLongPress = widget.onTitleLongPress;
    return KeyedSubtree(
      key: _largeTitleKey,
      child: onLongPress == null
          ? header
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onLongPress: onLongPress,
              child: header,
            ),
    );
  }

  EdgeInsets _bottomActionPadding(double? listMargin) {
    final padding =
        widget.bottomActionPadding ??
        const EdgeInsets.fromLTRB(
          Spacing.pagePadding,
          Spacing.sm,
          Spacing.pagePadding,
          Spacing.sm,
        );
    return listMargin == null
        ? padding
        : padding.copyWith(left: listMargin, right: listMargin);
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final largeTitleActive = _largeTitleActive(context);
    var basePadding =
        (widget.contentPadding ??
                (context.usesCupertinoChrome
                    ? const EdgeInsets.fromLTRB(
                        Spacing.screenPadding,
                        Spacing.sm,
                        Spacing.screenPadding,
                        Spacing.lg,
                      )
                    : const EdgeInsets.fromLTRB(
                        Spacing.pagePadding,
                        Spacing.lg,
                        Spacing.pagePadding,
                        Spacing.pagePadding,
                      )))
            .resolve(Directionality.of(context));
    if (largeTitleActive) {
      // A large title sits right under the bar, as on iOS.
      basePadding = basePadding.copyWith(top: Spacing.xs);
    }
    final listMargin = widget.systemListMargins && context.usesCupertinoChrome
        ? iosInsetGroupedMargin(mediaQuery.size.width)
        : null;
    if (listMargin != null) {
      basePadding = basePadding.copyWith(left: listMargin, right: listMargin);
    }
    final contentPadding = basePadding.copyWith(
      top: context.usesCupertinoChrome
          ? basePadding.top +
                mediaQuery.viewPadding.top +
                conduitAdaptiveToolbarHeightOf(context)
          : basePadding.top,
      bottom: basePadding.bottom + mediaQuery.viewPadding.bottom,
    );
    _largeTitleTop = basePadding.top;
    final content = [
      if (largeTitleActive) _buildLargeTitle(context),
      ...widget.content,
    ];
    final list = ListView(
      controller: _controller,
      primary: false,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics:
          widget.physics ??
          const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      padding: contentPadding,
      children: [
        for (final child in content)
          Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: widget.maxWidth),
              child: SizedBox(width: double.infinity, child: child),
            ),
          ),
      ],
    );
    final scrollbar = context.usesCupertinoChrome
        ? CupertinoScrollbar(controller: _controller, child: list)
        : Scrollbar(
            controller: _controller,
            interactive: widget.interactiveScrollbar,
            child: list,
          );
    final fadesBottomEdge =
        context.usesCupertinoChrome && widget.bottomAction == null;
    final scrollable = !fadesBottomEdge
        ? scrollbar
        : NotificationListener<ScrollMetricsNotification>(
            onNotification: (notification) =>
                notification.depth == 0 &&
                _handleScrollMetrics(notification.metrics),
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) =>
                  notification.depth == 0 &&
                  _handleScrollMetrics(notification.metrics),
              child: scrollbar,
            ),
          );

    final backNavigation = widget.backNavigation;
    final canPop = Navigator.of(context).canPop();
    final backLabel =
        backNavigation?.label ??
        (context.usesCupertinoChrome
            ? CupertinoLocalizations.of(context).backButtonLabel
            : MaterialLocalizations.of(context).backButtonTooltip);
    final backButton = backNavigation == null && !canPop
        ? null
        : AdaptiveTooltip(
            message: backLabel,
            child: Semantics(
              label: backLabel,
              button: true,
              child: ConduitAdaptiveAppBarIconButton(
                key:
                    backNavigation?.buttonKey ??
                    const ValueKey<String>('utility-route-back-button'),
                icon: context.usesCupertinoChrome
                    ? CupertinoIcons.chevron_back
                    : Icons.arrow_back,
                onPressed:
                    backNavigation?.onPressed ??
                    () => Navigator.of(context).maybePop(),
              ),
            ),
          );
    final leading = backButton == null
        ? null
        : context.usesCupertinoChrome
        ? backButton
        : Center(
            child: SizedBox.square(
              dimension: TouchTarget.minimum,
              child: backButton,
            ),
          );
    final titleText = largeTitleActive
        ? _InlineTitle(title: widget.title, shown: _inlineTitleShown)
        : Text(widget.title);
    final title = widget.onTitleLongPress == null
        ? titleText
        : GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: widget.onTitleLongPress,
            child: titleText,
          );
    final appBar = context.usesCupertinoChrome
        ? AdaptiveAppBar(
            useNativeToolbar: false,
            tintColor: context.conduitTheme.textPrimary,
            cupertinoNavigationBar: ConduitAdaptiveCupertinoNavigationBar(
              textScaler: MediaQuery.textScalerOf(context),
              leading: leading ?? const SizedBox.shrink(),
              middle: title,
              trailing: widget.trailing,
              blurWhenScrolledUnder: true,
              systemOverlayStyle: Theme.of(context)
                  .appBarTheme
                  .systemOverlayStyle,
            ),
          )
        : AdaptiveAppBar(
            title: widget.title,
            titleWidget: widget.onTitleLongPress == null && !largeTitleActive
                ? null
                : title,
            tintColor: context.conduitTheme.textPrimary,
            leading: leading,
            appBar: AppBar(
              leading: leading,
              title: title,
              actions: widget.trailing == null ? null : [widget.trailing!],
            ),
          );

    return AdaptiveRouteShell(
      backgroundColor:
          widget.backgroundColor ?? context.conduitTheme.groupedBackground,
      appBar: appBar,
      body: Stack(
        children: [
          Positioned.fill(
            child: PrimaryScrollController(
              controller: _controller,
              child: Column(
                children: [
                  Expanded(child: scrollable),
                  if (widget.bottomAction != null)
                    SafeArea(
                      top: false,
                      minimum: _bottomActionPadding(listMargin),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: widget.maxWidth,
                          ),
                          child: widget.bottomAction!,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (fadesBottomEdge)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: AnimatedOpacity(
                key: const ValueKey<String>('utility-bottom-scroll-edge'),
                opacity: _contentBelow ? 1 : 0,
                duration: context.motionDuration(AnimationDuration.fast),
                curve: Curves.easeOut,
                child: ConduitChromeGradientFade.bottom(
                  contentHeight: mediaQuery.viewPadding.bottom,
                  fadeHeight: _bottomScrollEdgeFadeHeight,
                  backgroundColor:
                      widget.backgroundColor ??
                      context.conduitTheme.groupedBackground,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The share of a custom large-title header's height that has scrolled
/// under the bar when its title (below the header's artwork) reaches it.
const double _customHeaderCollapseShare = 0.4;

/// How far above the home indicator the bottom scroll edge reaches before
/// rows are clear: about one row's subtitle line.
const double _bottomScrollEdgeFadeHeight = 40;

/// The bar title of a large-title page: semibold, shown only once the large
/// title has scrolled under the bar, and silent to assistive tech until then
/// so the title is not read twice.
class _InlineTitle extends StatelessWidget {
  const _InlineTitle({required this.title, required this.shown});

  final String title;
  final bool shown;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      excluding: !shown,
      child: AnimatedOpacity(
        opacity: shown ? 1 : 0,
        duration: context.motionDuration(AnimationDuration.fast),
        curve: Curves.easeOutCubic,
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.usesCupertinoChrome
              ? AppTypography.headlineSmallStyle.copyWith(
                  color: context.conduitTheme.textPrimary,
                )
              : null,
        ),
      ),
    );
  }
}
