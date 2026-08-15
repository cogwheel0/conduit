import 'package:material_ui/material_ui.dart';

import '../../../../l10n/app_localizations.dart';
import '../../../../shared/theme/theme_extensions.dart';
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
    final theme = context.conduitTheme;
    return WorkspaceEditorField(
      fieldKey: fieldKey,
      controller: controller,
      label: label,
      isDetail: isDetail,
      enabled: enabled,
      onChanged: (_) => onChanged(),
      detailValue: controller.text.trim().isEmpty
          ? AppLocalizations.of(context)!.workspaceModelBaseModelNone
          : controller.text,
      helperText: helperText,
      minLines: json ? 2 : minLines,
      maxLines: json ? 8 : maxLines,
      style: json ? theme.code?.copyWith(color: theme.textPrimary) : null,
      errorText: hasError
          ? AppLocalizations.of(context)!.workspaceModelInvalidJson
          : null,
    );
  }
}
