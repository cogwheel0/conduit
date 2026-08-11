import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../theme/theme_extensions.dart';
import '../adaptive_route_shell.dart';
import '../adaptive_toolbar_components.dart';
import '../platform_ui/platform_ui.dart';

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
  }) : content = List<Widget>.unmodifiable(content);

  factory UtilityPageScaffold.auth({
    Key? key,
    required String title,
    required Widget body,
    UtilityBackNavigation? backNavigation,
    Widget? bottomAction,
    Color? backgroundColor,
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
  );

  factory UtilityPageScaffold.settings({
    Key? key,
    required String title,
    required List<Widget> children,
  }) => UtilityPageScaffold._(
    key: key,
    title: title,
    content: children,
    maxWidth: 640,
    interactiveScrollbar: false,
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

  @override
  State<UtilityPageScaffold> createState() => _UtilityPageScaffoldState();
}

class _UtilityPageScaffoldState extends State<UtilityPageScaffold> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final defaultPadding = EdgeInsets.fromLTRB(
      Spacing.pagePadding,
      Spacing.lg,
      Spacing.pagePadding,
      Spacing.pagePadding + mediaQuery.viewPadding.bottom,
    );
    final list = ListView(
      controller: _controller,
      primary: false,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics:
          widget.physics ??
          const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      padding: widget.contentPadding ?? defaultPadding,
      children: [
        for (final child in widget.content)
          Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: widget.maxWidth),
              child: SizedBox(width: double.infinity, child: child),
            ),
          ),
      ],
    );
    final scrollable = context.usesCupertinoChrome
        ? CupertinoScrollbar(controller: _controller, child: list)
        : Scrollbar(
            controller: _controller,
            interactive: widget.interactiveScrollbar,
            child: list,
          );

    final backNavigation = widget.backNavigation;
    final backButton = backNavigation == null
        ? null
        : AdaptiveTooltip(
            message: backNavigation.label,
            child: Semantics(
              label: backNavigation.label,
              button: true,
              child: ConduitAdaptiveAppBarIconButton(
                key: backNavigation.buttonKey,
                icon: context.usesCupertinoChrome
                    ? CupertinoIcons.chevron_back
                    : Icons.arrow_back,
                onPressed: backNavigation.onPressed,
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
    final appBar = AdaptiveAppBar(
      title: widget.title,
      tintColor: context.conduitTheme.textPrimary,
      leading: leading,
    );

    return AdaptiveRouteShell(
      backgroundColor:
          widget.backgroundColor ?? context.conduitTheme.surfaceBackground,
      appBar: appBar,
      body: PrimaryScrollController(
        controller: _controller,
        child: Column(
          children: [
            Expanded(child: scrollable),
            if (widget.bottomAction != null)
              SafeArea(
                top: false,
                minimum:
                    widget.bottomActionPadding ??
                    const EdgeInsets.fromLTRB(
                      Spacing.pagePadding,
                      Spacing.sm,
                      Spacing.pagePadding,
                      Spacing.sm,
                    ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: widget.maxWidth),
                    child: widget.bottomAction!,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
