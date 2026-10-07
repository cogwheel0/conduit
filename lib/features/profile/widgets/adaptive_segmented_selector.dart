import 'package:flutter/widgets.dart';

import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/platform_ui/vocabulary.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';

/// A typed settings selector with platform-specific labels.
class AdaptiveSegmentedSelector<T extends Object> extends StatelessWidget {
  const AdaptiveSegmentedSelector({
    super.key,
    required this.value,
    required this.onChanged,
    required this.options,
    this.showIcons = true,
  });

  final T value;
  final ValueChanged<T> onChanged;
  final List<
    ({
      T value,
      String label,
      IconData cupertinoIcon,
      IconData materialIcon,
      bool enabled,
    })
  >
  options;
  final bool showIcons;

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final isCupertino =
        platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
    return AdaptiveValueSegmentedControl<T>(
      value: value,
      onChanged: onChanged,
      segments: [
        for (final option in options)
          AdaptiveSegment<T>(
            value: option.value,
            enabled: option.enabled,
            semanticLabel: option.label,
            label: isCupertino && showIcons
                ? ThemeModeSegmentLabel(
                    icon: option.cupertinoIcon,
                    label: option.label,
                  )
                : isCupertino
                ? Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Spacing.sm,
                      vertical: Spacing.xs,
                    ),
                    child: Text(option.label),
                  )
                : Text(option.label),
            icon: showIcons && !isCupertino ? Icon(option.materialIcon) : null,
          ),
      ],
    );
  }
}

/// Segmented control specifically for ThemeMode selection with
/// system/light/dark options.
class ThemeModeSegmentedControl extends StatelessWidget {
  const ThemeModeSegmentedControl({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final ThemeMode value;
  final ValueChanged<ThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AdaptiveSegmentedSelector<ThemeMode>(
      value: value,
      onChanged: onChanged,
      options: [
        (
          value: ThemeMode.system,
          label: l10n.system,
          cupertinoIcon: CupertinoIcons.sparkles,
          materialIcon: Icons.auto_mode,
          enabled: true,
        ),
        (
          value: ThemeMode.light,
          label: l10n.themeLight,
          cupertinoIcon: CupertinoIcons.sun_max,
          materialIcon: Icons.light_mode,
          enabled: true,
        ),
        (
          value: ThemeMode.dark,
          label: l10n.themeDark,
          cupertinoIcon: CupertinoIcons.moon_fill,
          materialIcon: Icons.dark_mode,
          enabled: true,
        ),
      ],
    );
  }
}

/// Label widget used inside segmented controls showing an icon and text.
class ThemeModeSegmentLabel extends StatelessWidget {
  const ThemeModeSegmentLabel({
    super.key,
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.sm,
        vertical: Spacing.xs,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: IconSize.small),
          const SizedBox(width: Spacing.xs),
          Text(label),
        ],
      ),
    );
  }
}
