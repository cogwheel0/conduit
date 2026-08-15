import 'package:material_ui/material_ui.dart';

import '../../../../core/utils/debug_logger.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../widgets/workspace_export_controller.dart';

/// Shares one or more model definitions as a JSON file via the OS share sheet.
Future<void> exportWorkspaceModelsToShare(
  BuildContext context, {
  required List<Map<String, dynamic>> models,
  required String filename,
}) async {
  final l10n = AppLocalizations.of(context)!;
  try {
    await WorkspaceExportController().shareJson(
      filename: filename,
      data: models,
    );
  } catch (error, stackTrace) {
    DebugLogger.error(
      'model export share failed',
      scope: 'workspace/models',
      error: error,
      stackTrace: stackTrace,
    );
    if (context.mounted) {
      AdaptiveSnackBar.show(
        context,
        message: l10n.workspaceModelExportFailed,
        type: AdaptiveSnackBarType.error,
      );
    }
  }
}
