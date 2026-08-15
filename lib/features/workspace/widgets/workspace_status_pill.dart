import 'package:material_ui/material_ui.dart';

import '../../../shared/theme/theme_extensions.dart';

enum WorkspaceStatusTone { neutral, success, warning, info }

class WorkspaceStatusPill extends StatelessWidget {
  const WorkspaceStatusPill({
    super.key,
    required this.label,
    this.tone = WorkspaceStatusTone.neutral,
  });

  final String label;
  final WorkspaceStatusTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final color = switch (tone) {
      WorkspaceStatusTone.neutral => theme.textSecondary,
      WorkspaceStatusTone.success => theme.success,
      WorkspaceStatusTone.warning => theme.warning,
      WorkspaceStatusTone.info => theme.info,
    };
    return Semantics(
      label: label,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm,
          vertical: Spacing.xxs,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(AppBorderRadius.pill),
        ),
        child: Text(
          label,
          maxLines: 1,
          style: AppTypography.captionStyle.copyWith(
            color: color,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
