import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_route_shell.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';

/// Shared adaptive shell for the Open WebUI connection and sign-in flow.
///
/// These routes can be entered with replacement navigation, so callers provide
/// an explicit back destination instead of relying on an implicit route stack.
class AdaptiveAuthScaffold extends StatefulWidget {
  const AdaptiveAuthScaffold({
    super.key,
    required this.title,
    required this.body,
    this.backLabel,
    this.backButtonKey,
    this.onBack,
    this.bottomAction,
  }) : assert(
         (backLabel == null && backButtonKey == null && onBack == null) ||
             (backLabel != null && backButtonKey != null && onBack != null),
         'Back label, key, and callback must be supplied together.',
       );

  final String title;
  final String? backLabel;
  final Key? backButtonKey;
  final VoidCallback? onBack;
  final Widget body;
  final Widget? bottomAction;

  @override
  State<AdaptiveAuthScaffold> createState() => _AdaptiveAuthScaffoldState();
}

class _AdaptiveAuthScaffoldState extends State<AdaptiveAuthScaffold> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final backButton = widget.onBack == null
        ? null
        : AdaptiveTooltip(
            message: widget.backLabel!,
            child: Semantics(
              label: widget.backLabel,
              button: true,
              child: ConduitAdaptiveAppBarIconButton(
                key: widget.backButtonKey,
                icon: context.usesCupertinoChrome
                    ? CupertinoIcons.chevron_back
                    : Icons.arrow_back,
                onPressed: widget.onBack,
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

    final scrollable = SingleChildScrollView(
      controller: _scrollController,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(
        Spacing.pagePadding,
        Spacing.lg,
        Spacing.pagePadding,
        Spacing.xl,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: widget.body,
        ),
      ),
    );

    return AdaptiveRouteShell(
      backgroundColor: context.conduitTheme.surfaceBackground,
      appBar: AdaptiveAppBar(
        title: widget.title,
        tintColor: context.conduitTheme.textPrimary,
        // Material gives AppBar.leading tight 56x56 constraints. Loosen them
        // so the adaptive surface stays at the standard 44dp action size.
        leading: leading,
      ),
      body: Column(
        children: [
          Expanded(
            child: Scrollbar(
              controller: _scrollController,
              interactive: true,
              child: scrollable,
            ),
          ),
          if (widget.bottomAction != null)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  Spacing.pagePadding,
                  Spacing.md,
                  Spacing.pagePadding,
                  Spacing.md,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: widget.bottomAction!,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
