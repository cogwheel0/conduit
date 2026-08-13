import 'package:material_ui/material_ui.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../../shared/theme/theme_extensions.dart';
import '../../../../shared/widgets/conduit_components.dart';
import '../../../../shared/widgets/utility_components.dart';
import '../../widgets/workspace_editor_fields.dart';

final class WorkspaceModelEditorField extends StatelessWidget {
  const WorkspaceModelEditorField({
    super.key,
    required this.fieldKey,
    required this.controller,
    required this.label,
    required this.isDetail,
    required this.enabled,
    required this.onChanged,
    this.helperText,
    this.minLines = 1,
    this.maxLines = 1,
    this.json = false,
    this.hasError = false,
  });

  final String fieldKey;
  final TextEditingController controller;
  final String label;
  final bool isDetail;
  final bool enabled;
  final VoidCallback onChanged;
  final String? helperText;
  final int minLines;
  final int maxLines;
  final bool json;
  final bool hasError;

  @override
  Widget build(BuildContext context) {
    if (isDetail) {
      return UtilityValueRow(
        key: Key(fieldKey),
        label: label,
        value: controller.text.trim().isEmpty
            ? AppLocalizations.of(context)!.workspaceModelBaseModelNone
            : controller.text,
      );
    }
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: WorkspaceLabeledField(
        helperText: helperText,
        child: ConduitInput(
          key: Key(fieldKey),
          controller: controller,
          label: label,
          enabled: enabled,
          minLines: json ? 2 : minLines,
          maxLines: json ? 8 : (maxLines < minLines ? minLines : maxLines),
          style: json ? theme.code?.copyWith(color: theme.textPrimary) : null,
          errorText: hasError
              ? AppLocalizations.of(context)!.workspaceModelInvalidJson
              : null,
          onChanged: (_) => onChanged(),
        ),
      ),
    );
  }
}
