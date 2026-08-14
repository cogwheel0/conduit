import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/services/haptic_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';

/// A generic segmented selector that adapts to Cupertino on iOS/macOS
/// and Material SegmentedButton on other platforms.
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
    final selectedValue =
        options.any((option) => option.value == value && option.enabled)
        ? value
        : null;
    void commitSelection(T next) {
      if (next == value) return;
      ConduitHaptics.selectionClick();
      onChanged(next);
    }

    if (isCupertino) {
      return CupertinoSlidingSegmentedControl<T>(
        groupValue: selectedValue,
        disabledChildren: {
          for (final option in options)
            if (!option.enabled) option.value,
        },
        onValueChanged: (next) {
          if (next == null) return;
          final selected = options.any(
            (option) => option.value == next && option.enabled,
          );
          if (selected) {
            commitSelection(next);
          }
        },
        children: {
          for (final option in options)
            option.value: showIcons
                ? ThemeModeSegmentLabel(
                    icon: option.cupertinoIcon,
                    label: option.label,
                  )
                : Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Spacing.sm,
                      vertical: Spacing.xs,
                    ),
                    child: Text(option.label),
                  ),
        },
      );
    }

    return SegmentedButton<T>(
      selected: selectedValue == null ? <T>{} : <T>{selectedValue},
      emptySelectionAllowed: selectedValue == null,
      showSelectedIcon: false,
      segments: [
        for (final option in options)
          ButtonSegment<T>(
            value: option.value,
            icon: showIcons ? Icon(option.materialIcon) : null,
            label: Text(option.label),
            enabled: option.enabled,
          ),
      ],
      onSelectionChanged: (selection) {
        if (selection.isEmpty) return;
        final next = selection.first;
        final selected = options.any(
          (option) => option.value == next && option.enabled,
        );
        if (selected) {
          commitSelection(next);
        }
      },
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
    final platform = Theme.of(context).platform;
    final isCupertino =
        platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
    void commitSelection(ThemeMode next) {
      if (next == value) return;
      ConduitHaptics.selectionClick();
      onChanged(next);
    }

    if (isCupertino) {
      return CupertinoSlidingSegmentedControl<ThemeMode>(
        groupValue: value,
        onValueChanged: (next) {
          if (next != null) {
            commitSelection(next);
          }
        },
        children: {
          ThemeMode.system: ThemeModeSegmentLabel(
            icon: CupertinoIcons.sparkles,
            label: l10n.system,
          ),
          ThemeMode.light: ThemeModeSegmentLabel(
            icon: CupertinoIcons.sun_max,
            label: l10n.themeLight,
          ),
          ThemeMode.dark: ThemeModeSegmentLabel(
            icon: CupertinoIcons.moon_fill,
            label: l10n.themeDark,
          ),
        },
      );
    }

    return SegmentedButton<ThemeMode>(
      selected: {value},
      segments: [
        ButtonSegment<ThemeMode>(
          value: ThemeMode.system,
          icon: const Icon(Icons.auto_mode),
          label: Text(l10n.system),
        ),
        ButtonSegment<ThemeMode>(
          value: ThemeMode.light,
          icon: const Icon(Icons.light_mode),
          label: Text(l10n.themeLight),
        ),
        ButtonSegment<ThemeMode>(
          value: ThemeMode.dark,
          icon: const Icon(Icons.dark_mode),
          label: Text(l10n.themeDark),
        ),
      ],
      showSelectedIcon: false,
      onSelectionChanged: (selection) {
        if (selection.isNotEmpty) {
          commitSelection(selection.first);
        }
      },
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
