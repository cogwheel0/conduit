import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/conduit_input_styles.dart';
import '../theme/theme_extensions.dart';
import 'platform_ui/platform_ui.dart';

/// Places a form field in an [InsetGroupedList] row.
///
/// On iOS an `AccessibleFormField(iosSettingsRow: true)` is already a settings
/// row; elsewhere the field brings its own label and outline, so it gets the
/// row's padding instead of sitting against the group's edge.
Widget editorGroupField(Widget field) => PlatformInfo.isIOS
    ? field
    : Padding(padding: const EdgeInsets.all(Spacing.md), child: field);

/// A multi-line field for machine-read text such as an OpenAPI document or a
/// recurrence rule.
///
/// The text is shown in a monospace face, and the keyboard neither suggests
/// nor corrects it, nor turns quotes and dashes into typographic ones, any of
/// which would make the text unreadable to the server.
class CodeEntryField extends StatelessWidget {
  const CodeEntryField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.helperText,
    this.errorText,
    this.onChanged,
    this.enabled = true,
    this.minLines = 2,
    this.maxLines = 8,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? helperText;
  final String? errorText;
  final ValueChanged<String>? onChanged;
  final bool enabled;
  final int minLines;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final error = errorText?.trim().isNotEmpty ?? false ? errorText : null;
    final style = AppTypography.bodySmallStyle.copyWith(
      color: theme.textPrimary,
      fontFamily: AppTypography.monospaceFontFamily,
    );
    final hintStyle = style.copyWith(color: theme.inputPlaceholder);
    final Widget input;
    if (PlatformInfo.isIOS) {
      input = CupertinoTextField(
        controller: controller,
        placeholder: hint,
        placeholderStyle: hintStyle,
        style: style,
        minLines: minLines,
        maxLines: maxLines,
        enabled: enabled,
        keyboardType: TextInputType.multiline,
        autocorrect: false,
        enableSuggestions: false,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
        onChanged: onChanged,
        padding: const EdgeInsets.all(Spacing.md),
        decoration: BoxDecoration(
          color: enabled ? theme.groupedSurface : theme.buttonDisabled,
          border: Border.all(
            color: error == null ? theme.inputBorder : theme.error,
            width: BorderWidth.regular,
          ),
          borderRadius: BorderRadius.circular(AppBorderRadius.lg),
        ),
      );
    } else {
      input = TextField(
        controller: controller,
        style: style,
        minLines: minLines,
        maxLines: maxLines,
        enabled: enabled,
        keyboardType: TextInputType.multiline,
        autocorrect: false,
        enableSuggestions: false,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
        onChanged: onChanged,
        decoration: context.conduitInputStyles
            .standard(hint: hint)
            .copyWith(
              hintStyle: hintStyle,
              enabledBorder: error == null
                  ? null
                  : OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppBorderRadius.input),
                      borderSide: BorderSide(color: theme.error),
                    ),
            ),
      );
    }
    final note = error ?? helperText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: AppTypography.bodyMediumStyle.copyWith(
            color: theme.textPrimary,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: Spacing.sm),
        Semantics(label: label, textField: true, child: input),
        if (note != null && note.isNotEmpty) ...[
          const SizedBox(height: Spacing.xs),
          Semantics(
            liveRegion: error != null,
            child: Text(
              note,
              style: AppTypography.bodySmallStyle.copyWith(
                color: error != null ? theme.error : theme.textSecondary,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
