import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme/theme_extensions.dart';
import 'adaptive_route_shell.dart';
import 'adaptive_toolbar_components.dart';
import 'platform_ui/platform_ui.dart';
import 'utility_components.dart';

export 'utility_components.dart';

enum ConnectionAttemptPhase { idle, connecting, connected, failed }

@immutable
class ConnectionAttemptState {
  const ConnectionAttemptState._(this.phase, this.message);

  const ConnectionAttemptState.idle()
    : this._(ConnectionAttemptPhase.idle, null);

  const ConnectionAttemptState.connecting(String message)
    : this._(ConnectionAttemptPhase.connecting, message);

  const ConnectionAttemptState.connected(String message)
    : this._(ConnectionAttemptPhase.connected, message);

  const ConnectionAttemptState.failed(String message)
    : this._(ConnectionAttemptPhase.failed, message);

  final ConnectionAttemptPhase phase;
  final String? message;

  bool get isBusy => phase == ConnectionAttemptPhase.connecting;
  bool get isVisible => phase != ConnectionAttemptPhase.idle;
}

class ConnectionMark extends StatelessWidget {
  const ConnectionMark({
    super.key,
    required this.child,
    this.color,
    this.padding = const EdgeInsets.all(Spacing.sm),
  });

  final Widget child;
  final Color? color;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color ?? theme.buttonPrimary.withValues(alpha: Alpha.highlight),
        borderRadius: BorderRadius.circular(AppBorderRadius.md),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

class OpenWebUiConnectionMark extends StatelessWidget {
  const OpenWebUiConnectionMark({
    super.key,
    this.size = TouchTarget.comfortable,
  });

  final double size;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppBorderRadius.md),
      child: Image.asset(
        'assets/icons/open_webui.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        excludeFromSemantics: true,
      ),
    );
  }
}

class ConnectionWebAuthScaffold extends StatelessWidget {
  const ConnectionWebAuthScaffold({
    super.key,
    required this.title,
    required this.body,
    this.onBack,
    this.backLabel,
    this.onRefresh,
    this.bottomChrome,
  });

  final String title;
  final Widget body;
  final VoidCallback? onBack;
  final String? backLabel;
  final VoidCallback? onRefresh;
  final Widget? bottomChrome;

  @override
  Widget build(BuildContext context) {
    final backButton = onBack == null
        ? null
        : AdaptiveTooltip(
            message:
                backLabel ??
                MaterialLocalizations.of(context).backButtonTooltip,
            child: ConduitAdaptiveAppBarIconButton(
              icon: context.usesCupertinoChrome
                  ? CupertinoIcons.chevron_back
                  : Icons.arrow_back,
              onPressed: onBack,
            ),
          );

    return AdaptiveRouteShell(
      backgroundColor: context.conduitTheme.surfaceBackground,
      bodySafeArea: true,
      appBar: AdaptiveAppBar(
        title: title,
        leading: backButton,
        actions: [
          if (onRefresh != null)
            AdaptiveAppBarAction(
              iosSymbol: 'arrow.clockwise',
              icon: context.usesCupertinoChrome
                  ? CupertinoIcons.refresh
                  : Icons.refresh,
              onPressed: onRefresh!,
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: body),
          if (bottomChrome != null) SafeArea(top: false, child: bottomChrome!),
        ],
      ),
    );
  }
}

class ConnectionAttemptBanner extends StatelessWidget {
  const ConnectionAttemptBanner({super.key, required this.state});

  final ConnectionAttemptState state;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: context.motionDuration(AnimationDuration.microInteraction),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeOutCubic,
      child: !state.isVisible
          ? const SizedBox.shrink(key: ValueKey<String>('connection-idle'))
          : KeyedSubtree(
              key: ValueKey<ConnectionAttemptPhase>(state.phase),
              child: UtilityStatusBanner(
                message: state.message ?? '',
                tone: switch (state.phase) {
                  ConnectionAttemptPhase.connecting => UtilityStatusTone.info,
                  ConnectionAttemptPhase.connected => UtilityStatusTone.success,
                  ConnectionAttemptPhase.failed => UtilityStatusTone.error,
                  ConnectionAttemptPhase.idle => UtilityStatusTone.neutral,
                },
                progress: state.isBusy,
              ),
            ),
    );
  }
}
