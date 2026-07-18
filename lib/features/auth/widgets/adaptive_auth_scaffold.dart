import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_route_shell.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';

/// Shared adaptive shell for the Open WebUI connection and sign-in flow.
///
/// These routes can be entered with replacement navigation, so callers provide
/// an explicit back destination instead of relying on an implicit route stack.
class AdaptiveAuthScaffold extends StatelessWidget {
  const AdaptiveAuthScaffold({
    super.key,
    required this.title,
    required this.backLabel,
    required this.backButtonKey,
    required this.onBack,
    required this.body,
    required this.bottomAction,
  });

  final String title;
  final String backLabel;
  final Key backButtonKey;
  final VoidCallback onBack;
  final Widget body;
  final Widget bottomAction;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final topPadding = context.usesCupertinoChrome
        ? mediaQuery.padding.top + kTextTabBarHeight + Spacing.lg
        : Spacing.lg;
    final backButton = AdaptiveTooltip(
      message: backLabel,
      child: Semantics(
        label: backLabel,
        button: true,
        child: ConduitAdaptiveAppBarIconButton(
          key: backButtonKey,
          icon: context.usesCupertinoChrome
              ? CupertinoIcons.chevron_back
              : Icons.arrow_back,
          onPressed: onBack,
        ),
      ),
    );

    return AdaptiveRouteShell(
      backgroundColor: context.conduitTheme.surfaceBackground,
      appBar: AdaptiveAppBar(
        title: title,
        tintColor: context.conduitTheme.textPrimary,
        // Material gives AppBar.leading tight 56x56 constraints. Loosen them
        // so the adaptive surface stays at the standard 44dp action size.
        leading: context.usesCupertinoChrome
            ? backButton
            : Center(
                child: SizedBox.square(
                  dimension: TouchTarget.minimum,
                  child: backButton,
                ),
              ),
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              padding: EdgeInsets.fromLTRB(
                Spacing.pagePadding,
                topPadding,
                Spacing.pagePadding,
                Spacing.xl,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: body,
                ),
              ),
            ),
          ),
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
                  child: bottomAction,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
