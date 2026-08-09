import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/platform_service.dart';
import '../../../core/services/settings_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_route_shell.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';
import '../../../shared/widgets/utility_components.dart';

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

class ConnectionIdentityHeader extends StatelessWidget {
  const ConnectionIdentityHeader({
    super.key,
    required this.mark,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final Widget mark;
  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return UtilityIdentityHeader(
      leading: mark,
      title: title,
      subtitle: subtitle,
      trailing: trailing,
    );
  }
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

class ConnectionSection extends StatelessWidget {
  const ConnectionSection({
    super.key,
    required this.title,
    required this.child,
    this.description,
    this.padding = const EdgeInsets.all(Spacing.md),
  });

  final String title;
  final String? description;
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return InsetGroupedSection(
      title: title,
      description: description,
      padding: padding,
      child: child,
    );
  }
}

class ConnectionChoiceRow extends ConsumerStatefulWidget {
  const ConnectionChoiceRow({
    super.key,
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.showDivider = false,
    this.showSelectionIndicator = true,
    this.trailing,
  });

  final Widget leading;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  final bool showDivider;
  final bool showSelectionIndicator;
  final Widget? trailing;

  @override
  ConsumerState<ConnectionChoiceRow> createState() =>
      _ConnectionChoiceRowState();
}

class _ConnectionChoiceRowState extends ConsumerState<ConnectionChoiceRow> {
  bool _pressed = false;

  void _handleTap() {
    PlatformService.hapticFeedbackWithSettings(
      type: HapticType.selection,
      hapticEnabled: ref.read(hapticEnabledProvider),
    );
    widget.onTap();
  }

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final duration = context.motionDuration(AnimationDuration.buttonPress);
    return Semantics(
      button: true,
      selected: widget.selected,
      label: '${widget.title}. ${widget.subtitle}',
      onTap: _handleTap,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) {
          _setPressed(true);
        },
        onTapUp: (_) => _setPressed(false),
        onTapCancel: () => _setPressed(false),
        onTap: _handleTap,
        child: AnimatedScale(
          scale: _pressed && !context.reduceMotion ? 0.98 : 1,
          duration: duration,
          curve: Curves.easeOutCubic,
          child: Container(
            constraints: const BoxConstraints(minHeight: TouchTarget.minimum),
            padding: const EdgeInsets.symmetric(vertical: Spacing.md),
            decoration: BoxDecoration(
              border: widget.showDivider
                  ? Border(
                      bottom: BorderSide(
                        color: theme.dividerColor,
                        width: BorderWidth.thin,
                      ),
                    )
                  : null,
            ),
            child: Row(
              children: [
                widget.leading,
                const SizedBox(width: Spacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: AppTypography.bodyMediumStyle.copyWith(
                          color: theme.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: Spacing.xxs),
                      Text(
                        widget.subtitle,
                        style: AppTypography.bodySmallStyle.copyWith(
                          color: theme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                if (widget.trailing != null)
                  widget.trailing!
                else if (widget.showSelectionIndicator)
                  AnimatedSwitcher(
                    duration: context.motionDuration(
                      AnimationDuration.microInteraction,
                    ),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeOutCubic,
                    child: widget.selected
                        ? Icon(
                            context.usesCupertinoChrome
                                ? CupertinoIcons.check_mark_circled_solid
                                : Icons.check_circle,
                            key: const ValueKey<String>('selected'),
                            color: theme.buttonPrimary,
                            size: IconSize.medium,
                          )
                        : SizedBox.square(
                            key: const ValueKey<String>('unselected'),
                            dimension: IconSize.medium,
                          ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ConnectionValueRow extends StatelessWidget {
  const ConnectionValueRow({
    super.key,
    required this.label,
    required this.value,
    this.leading,
    this.trailing,
    this.monospace = false,
  });

  final String label;
  final String value;
  final Widget? leading;
  final Widget? trailing;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    return UtilityValueRow(
      label: label,
      value: value,
      leading: leading,
      trailing: trailing,
      monospace: monospace,
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

class ConnectionDisclosure extends StatelessWidget {
  const ConnectionDisclosure({
    super.key,
    required this.title,
    required this.expanded,
    required this.onChanged,
    required this.child,
    this.subtitle,
    this.leading,
    this.contentPadding = const EdgeInsets.all(Spacing.md),
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final EdgeInsetsGeometry contentPadding;
  final bool expanded;
  final ValueChanged<bool> onChanged;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return UtilityDisclosureSection(
      title: title,
      subtitle: subtitle,
      leading: leading,
      expanded: expanded,
      onChanged: onChanged,
      contentPadding: contentPadding,
      child: child,
    );
  }
}

class ConnectionAttemptBanner extends StatelessWidget {
  const ConnectionAttemptBanner({super.key, required this.state});

  final ConnectionAttemptState state;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return AnimatedSwitcher(
      duration: context.motionDuration(AnimationDuration.microInteraction),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeOutCubic,
      child: !state.isVisible
          ? const SizedBox.shrink(key: ValueKey<String>('connection-idle'))
          : Semantics(
              key: ValueKey<ConnectionAttemptPhase>(state.phase),
              liveRegion: true,
              container: true,
              label: state.message,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.md,
                  vertical: Spacing.sm,
                ),
                decoration: BoxDecoration(
                  color: _color(theme).withValues(alpha: Alpha.subtle),
                  borderRadius: BorderRadius.circular(AppBorderRadius.md),
                ),
                child: Row(
                  children: [
                    _icon(context, theme),
                    const SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Text(
                        state.message ?? '',
                        style: AppTypography.bodySmallStyle.copyWith(
                          color: state.phase == ConnectionAttemptPhase.failed
                              ? theme.error
                              : theme.textPrimary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Color _color(ConduitThemeExtension theme) => switch (state.phase) {
    ConnectionAttemptPhase.connected => theme.success,
    ConnectionAttemptPhase.failed => theme.error,
    ConnectionAttemptPhase.connecting => theme.buttonPrimary,
    ConnectionAttemptPhase.idle => Colors.transparent,
  };

  Widget _icon(BuildContext context, ConduitThemeExtension theme) =>
      switch (state.phase) {
        ConnectionAttemptPhase.connecting => SizedBox.square(
          dimension: IconSize.small,
          child: CircularProgressIndicator.adaptive(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(theme.buttonPrimary),
          ),
        ),
        ConnectionAttemptPhase.connected => Icon(
          context.usesCupertinoChrome
              ? CupertinoIcons.check_mark_circled_solid
              : Icons.check_circle,
          color: theme.success,
          size: IconSize.medium,
        ),
        ConnectionAttemptPhase.failed => Icon(
          context.usesCupertinoChrome
              ? CupertinoIcons.exclamationmark_circle_fill
              : Icons.error,
          color: theme.error,
          size: IconSize.medium,
        ),
        ConnectionAttemptPhase.idle => const SizedBox.shrink(),
      };
}
