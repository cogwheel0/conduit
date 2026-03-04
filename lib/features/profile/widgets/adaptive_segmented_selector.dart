import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

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

  @override
  Widget build(BuildContext context) {
    final isCupertino =
        Platform.isIOS || Theme.of(context).platform == TargetPlatform.macOS;

    if (isCupertino) {
      return CupertinoSlidingSegmentedControl<T>(
        groupValue: value,
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
            onChanged(next);
          }
        },
        children: {
          for (final option in options)
            option.value: ThemeModeSegmentLabel(
              icon: option.cupertinoIcon,
              label: option.label,
            ),
        },
      );
    }

    return SegmentedButton<T>(
      selected: {value},
      showSelectedIcon: false,
      segments: [
        for (final option in options)
          ButtonSegment<T>(
            value: option.value,
            icon: Icon(option.materialIcon),
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
          onChanged(next);
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
    final isCupertino =
        Platform.isIOS || Theme.of(context).platform == TargetPlatform.macOS;

    if (isCupertino) {
      return CupertinoSlidingSegmentedControl<ThemeMode>(
        groupValue: value,
        onValueChanged: (next) {
          if (next != null) {
            onChanged(next);
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
          onChanged(selection.first);
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
