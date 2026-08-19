import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/utility_components.dart';
import 'package:conduit/core/services/haptic_service.dart';

abstract final class WorkspaceEditorMetrics {
  static double sectionGap(BuildContext context) =>
      context.usesCupertinoChrome ? Spacing.md : Spacing.xl;

  static EdgeInsets bodyPadding(BuildContext context) {
    final horizontal = context.usesCupertinoChrome
        ? Spacing.md
        : Spacing.pagePadding;
    return EdgeInsets.fromLTRB(
      horizontal,
      context.usesCupertinoChrome ? Spacing.sm : Spacing.md,
      horizontal,
      horizontal + MediaQuery.paddingOf(context).bottom,
    );
  }
}

/// Shared detail/edit representation for workspace text fields.
class WorkspaceEditorField extends StatelessWidget {
  const WorkspaceEditorField({
    super.key,
    required this.fieldKey,
    required this.controller,
    required this.label,
    required this.isDetail,
    required this.enabled,
    required this.onChanged,
    this.detailValue,
    this.hint,
    this.helperText,
    this.errorText,
    this.prefixIcon,
    this.style,
    this.minLines = 1,
    this.maxLines = 1,
    this.textInputAction,
  });

  final String fieldKey;
  final TextEditingController controller;
  final String label;
  final bool isDetail;
  final bool enabled;
  final ValueChanged<String> onChanged;
  final String? detailValue;
  final String? hint;
  final String? helperText;
  final String? errorText;
  final Widget? prefixIcon;
  final TextStyle? style;
  final int minLines;
  final int maxLines;
  final TextInputAction? textInputAction;

  @override
  Widget build(BuildContext context) {
    if (isDetail) {
      return UtilityValueRow(
        key: Key(fieldKey),
        label: label,
        value: detailValue ?? controller.text,
      );
    }
    return WorkspaceLabeledField(
      helperText: helperText,
      child: AccessibleFormField(
        key: Key(fieldKey),
        controller: controller,
        label: label,
        hint: hint,
        enabled: enabled,
        minLines: minLines,
        maxLines: maxLines < minLines ? minLines : maxLines,
        style: style,
        errorText: errorText,
        prefixIcon: prefixIcon,
        textInputAction: textInputAction,
        iosSettingsRow: true,
        onChanged: onChanged,
      ),
    );
  }
}

/// A field group that follows each platform's form rhythm.
///
/// iOS uses the same inset grouped list and quiet dividers as app settings.
/// Android keeps the existing padded section with explicit field spacing.
class WorkspaceEditorFieldGroup extends StatelessWidget {
  const WorkspaceEditorFieldGroup({
    super.key,
    required this.children,
    this.title,
    this.description,
    this.footer,
    this.androidGap = Spacing.md,
  });

  final List<Widget> children;
  final String? title;
  final String? description;
  final String? footer;
  final double androidGap;

  @override
  Widget build(BuildContext context) {
    if (context.usesCupertinoChrome) {
      return InsetGroupedList(
        title: title,
        description: description,
        footer: footer,
        useNativeSurface: true,
        children: children,
      );
    }

    return InsetGroupedSection(
      title: title,
      description: description,
      footer: footer,
      child: WorkspaceEditorRows(androidGap: androidGap, children: children),
    );
  }
}

/// Adds native dividers between editor rows without introducing another
/// grouped surface. Useful inside disclosure sections.
class WorkspaceEditorRows extends StatelessWidget {
  const WorkspaceEditorRows({
    super.key,
    required this.children,
    this.androidGap = Spacing.md,
  });

  final List<Widget> children;
  final double androidGap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, child) in children.indexed) ...[
          child,
          if (index != children.length - 1)
            context.usesCupertinoChrome
                ? Divider(
                    height: BorderWidth.thin,
                    thickness: BorderWidth.thin,
                    indent: Spacing.md,
                    endIndent: Spacing.md,
                    color: context.conduitTheme.dividerColor,
                  )
                : SizedBox(height: androidGap),
        ],
      ],
    );
  }
}

/// Wraps a form input and renders optional helper text beneath it.
///
/// Adaptive form inputs ([ConduitInput]/[AdaptiveTextField]) do not carry a
/// Material-style `helperText`, so section editors compose it here to keep the
/// same guidance copy the raw fields used to show.
class WorkspaceLabeledField extends StatelessWidget {
  const WorkspaceLabeledField({
    super.key,
    required this.child,
    this.helperText,
  });

  final Widget child;
  final String? helperText;

  @override
  Widget build(BuildContext context) {
    final helper = helperText;
    if (helper == null || helper.isEmpty) {
      return child;
    }
    final theme = context.conduitTheme;
    final usesCupertinoChrome = context.usesCupertinoChrome;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        child,
        if (!usesCupertinoChrome) const SizedBox(height: Spacing.xs),
        Padding(
          padding: EdgeInsets.fromLTRB(
            usesCupertinoChrome ? Spacing.md : Spacing.xs,
            0,
            usesCupertinoChrome ? Spacing.md : Spacing.xs,
            usesCupertinoChrome ? Spacing.sm : 0,
          ),
          child: Text(
            helper,
            style: AppTypography.bodySmallStyle.copyWith(
              color: theme.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

class WorkspaceTagField extends StatelessWidget {
  const WorkspaceTagField({
    super.key,
    required this.keyPrefix,
    required this.label,
    required this.addLabel,
    required this.tags,
    required this.readOnly,
    required this.onRemove,
    required this.onAdd,
  });

  final String keyPrefix;
  final String label;
  final String addLabel;
  final List<String> tags;
  final bool readOnly;
  final ValueChanged<String> onRemove;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final usesCupertinoChrome = context.usesCupertinoChrome;
    return Padding(
      padding: usesCupertinoChrome
          ? const EdgeInsets.symmetric(
              horizontal: Spacing.md,
              vertical: Spacing.sm,
            )
          : EdgeInsets.zero,
      child: SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.label),
            const SizedBox(height: Spacing.xs),
            Wrap(
              spacing: Spacing.xs,
              runSpacing: Spacing.xs,
              children: [
                for (final tag in tags)
                  InputChip(
                    key: Key('$keyPrefix-tag-$tag'),
                    label: Text(tag),
                    onDeleted: readOnly
                        ? null
                        : () {
                            ConduitHaptics.selectionClick();
                            onRemove(tag);
                          },
                  ),
                if (!readOnly)
                  WorkspacePlainIconButton(
                    buttonKey: Key('$keyPrefix-tag-add'),
                    icon: Icons.add,
                    label: addLabel,
                    onPressed: onAdd,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A plain (borderless) adaptive text+icon button used for inline editor
/// affordances such as "Change image" or "Add" actions, replacing Material
/// [TextButton.icon] with a native-feeling control.
class WorkspacePlainIconButton extends StatelessWidget {
  const WorkspacePlainIconButton({
    super.key,
    this.buttonKey,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.isDestructive = false,
  });

  /// Key applied to the underlying button so widget tests can target it.
  final Key? buttonKey;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  /// Uses the theme error color for destructive actions (e.g. delete).
  final bool isDestructive;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final color = onPressed == null
        ? theme.iconSecondary
        : isDestructive
        ? theme.error
        : theme.buttonPrimary;
    return AdaptiveButton.child(
      key: buttonKey,
      onPressed: onPressed,
      enabled: onPressed != null,
      style: AdaptiveButtonStyle.plain,
      size: AdaptiveButtonSize.small,
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.sm,
        vertical: Spacing.xs,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: IconSize.small, color: color),
          const SizedBox(width: Spacing.xs),
          Text(
            label,
            style: AppTypography.standard.copyWith(
              color: color,
              fontWeight: context.usesCupertinoChrome
                  ? FontWeight.w400
                  : FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
