import 'dart:io' show Platform;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_route_shell.dart';
import '../../../shared/widgets/modal_safe_area.dart';
import '../../../shared/widgets/sheet_handle.dart';
import '../../../shared/widgets/themed_sheets.dart';

const settingsSectionGap = SizedBox(height: Spacing.lg);

/// Returns the clear modal barrier used by settings bottom sheets.
Color settingsSheetBarrierColor(BuildContext context) {
  return Colors.transparent;
}

Future<T?> showSettingsSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = true,
  bool useSafeArea = false,
}) {
  return ThemedSheets.showCustom<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    useSafeArea: useSafeArea,
    barrierColor: settingsSheetBarrierColor(context),
    builder: builder,
  );
}

/// Model-selector style shell for settings pickers.
class SettingsSelectorSheet extends StatelessWidget {
  const SettingsSelectorSheet({
    super.key,
    required this.title,
    required this.itemCount,
    required this.itemBuilder,
    this.description,
    this.initialChildSize = 0.55,
    this.minChildSize = 0.32,
    this.maxChildSize = 0.82,
  });

  final String title;
  final String? description;
  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final double initialChildSize;
  final double minChildSize;
  final double maxChildSize;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).maybePop(),
            child: const SizedBox.shrink(),
          ),
        ),
        DraggableScrollableSheet(
          expand: false,
          initialChildSize: initialChildSize,
          minChildSize: minChildSize,
          maxChildSize: maxChildSize,
          builder: (context, scrollController) {
            final theme = context.conduitTheme;

            return Container(
              decoration: BoxDecoration(
                color: theme.surfaceBackground,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(AppBorderRadius.bottomSheet),
                ),
                border: Border.all(
                  color: theme.dividerColor,
                  width: BorderWidth.regular,
                ),
                boxShadow: ConduitShadows.modal(context),
              ),
              child: ModalSheetSafeArea(
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.modalPadding,
                  vertical: Spacing.modalPadding,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SheetHandle(),
                    _SettingsSelectorHeader(
                      title: title,
                      description: description,
                    ),
                    const SizedBox(height: Spacing.md),
                    Expanded(
                      child: Scrollbar(
                        controller: scrollController,
                        child: ListView.builder(
                          controller: scrollController,
                          padding: EdgeInsets.zero,
                          itemCount: itemCount,
                          itemBuilder: itemBuilder,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class SettingsSelectorTile extends StatelessWidget {
  const SettingsSelectorTile({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.leading,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final bool selected;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final borderRadius = BorderRadius.circular(AppBorderRadius.card);
    final background = selected
        ? Color.alphaBlend(
            theme.buttonPrimary.withValues(alpha: 0.1),
            theme.surfaceBackground,
          )
        : Colors.transparent;
    final titleStyle =
        (Platform.isAndroid
                ? AppTypography.titleMediumStyle
                : AppTypography.bodyMediumStyle)
            .copyWith(
              color: selected ? theme.textPrimary : theme.textSecondary,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            );
    final subtitleStyle =
        (Platform.isAndroid
                ? AppTypography.bodyMediumStyle
                : AppTypography.labelSmallStyle)
            .copyWith(color: theme.textSecondary);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.xxs),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: background,
            borderRadius: borderRadius,
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm,
            vertical: Spacing.xs,
          ),
          child: Row(
            children: [
              if (leading != null) ...[
                leading!,
                const SizedBox(width: Spacing.sm),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: titleStyle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: subtitleStyle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: Spacing.xs),
                trailing!,
              ],
              if (selected) ...[
                const SizedBox(width: Spacing.xs),
                Icon(
                  Icons.check,
                  color: theme.buttonPrimary,
                  size: IconSize.medium,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsSelectorHeader extends StatelessWidget {
  const _SettingsSelectorHeader({required this.title, this.description});

  final String title;
  final String? description;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.headingSmall?.copyWith(
            color: theme.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (description != null && description!.isNotEmpty) ...[
          const SizedBox(height: Spacing.xs),
          Text(
            description!,
            style: theme.bodySmall?.copyWith(color: theme.textSecondary),
          ),
        ],
      ],
    );
  }
}

class SettingsPageScaffold extends StatelessWidget {
  const SettingsPageScaffold({
    super.key,
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final topPadding = Theme.of(context).platform == TargetPlatform.iOS
        ? mediaQuery.padding.top + kTextTabBarHeight + Spacing.lg
        : Spacing.lg;

    return AdaptiveRouteShell(
      backgroundColor: context.conduitTheme.surfaceBackground,
      appBar: AdaptiveAppBar(title: title),
      body: ListView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        padding: EdgeInsets.fromLTRB(
          Spacing.pagePadding,
          topPadding,
          Spacing.pagePadding,
          Spacing.pagePadding + mediaQuery.padding.bottom,
        ),
        children: children,
      ),
    );
  }
}

class SettingsSectionHeader extends StatelessWidget {
  const SettingsSectionHeader({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: context.conduitTheme.headingSmall?.copyWith(
        color: context.conduitTheme.sidebarForeground,
      ),
    );
  }
}

class SettingsIconBadge extends StatelessWidget {
  const SettingsIconBadge({super.key, required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppBorderRadius.small),
        border: Border.all(
          color: color.withValues(alpha: 0.2),
          width: BorderWidth.thin,
        ),
      ),
      alignment: Alignment.center,
      child: Icon(icon, color: color, size: IconSize.medium),
    );
  }
}
