import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/folder.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../shared/widgets/themed_dialogs.dart';

/// Handles showing the create-folder dialog and persisting the result.
class CreateFolderDialog {
  CreateFolderDialog._();

  /// Shows a dialog prompting the user to enter a folder name, then creates
  /// the folder via the API and updates the local cache.
  ///
  /// [context] is used for dialog presentation and localization.
  /// [ref] is used for reading providers (API service, folders).
  /// [onError] is called with an error message if creation fails.
  /// [parentId] optionally nests the new folder beneath an existing folder.
  static Future<void> show(
    BuildContext context,
    WidgetRef ref, {
    required Future<void> Function(String message) onError,
    String? parentId,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final name = await ThemedDialogs.promptTextInput(
      context,
      title: l10n.newFolder,
      hintText: l10n.folderName,
      confirmText: l10n.create,
      cancelText: l10n.cancel,
    );

    if (name == null) return;
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) return;
    try {
      final api = ref.read(apiServiceProvider);
      if (api == null) throw Exception('No API service');
      final created = await api.createFolder(
        name: trimmedName,
        parentId: parentId,
      );
      final folder = Folder.fromJson(Map<String, dynamic>.from(created));
      ConduitHaptics.lightImpact();
      ref.read(foldersProvider.notifier).upsertFolder(folder);
      refreshConversationsCache(ref, includeFolders: true);
    } catch (e, stackTrace) {
      DebugLogger.error(
        'create-folder-failed',
        scope: 'drawer',
        error: e,
        stackTrace: stackTrace,
      );
      await onError(l10n.failedToCreateFolder);
    }
  }
}
