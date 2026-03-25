import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:conduit/core/services/haptic_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/folder.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
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
  static Future<void> show(
    BuildContext context,
    WidgetRef ref, {
    String? parentId,
    required Future<void> Function(String message) onError,
  }) async {
    final l10n = AppLocalizations.of(context)!;

    String? name;
    String? selectedParentId = parentId;
    final canSelectParent = parentId == null;

    if (!canSelectParent) {
      name = await ThemedDialogs.promptTextInput(
        context,
        title: l10n.newSubfolder,
        hintText: l10n.folderName,
        confirmText: l10n.create,
        cancelText: l10n.cancel,
      );
    } else {
      final folders = ref
          .read(foldersProvider)
          .maybeWhen(data: (value) => value, orElse: () => const <Folder>[]);
      final sortedFolders = <Folder>[...folders]
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      final controller = TextEditingController();

      final confirmed = await ThemedDialogs.show<bool>(
        context,
        title: l10n.newFolder,
        content: StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final theme = dialogContext.conduitTheme;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: l10n.folderName,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(
                        AppBorderRadius.small,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: Spacing.sm),
                Text(
                  l10n.parentFolder,
                  style: AppTypography.bodySmallStyle.copyWith(
                    color: theme.textSecondary,
                  ),
                ),
                const SizedBox(height: Spacing.xs),
                DropdownButtonFormField<String?>(
                  initialValue: selectedParentId,
                  decoration: InputDecoration(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: Spacing.sm,
                      vertical: Spacing.sm,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(
                        AppBorderRadius.small,
                      ),
                    ),
                  ),
                  items: [
                    DropdownMenuItem<String?>(
                      value: null,
                      child: Text(l10n.topLevel),
                    ),
                    ...sortedFolders.map(
                      (folder) => DropdownMenuItem<String?>(
                        value: folder.id,
                        child: Text(folder.name),
                      ),
                    ),
                  ],
                  onChanged: (value) {
                    setDialogState(() => selectedParentId = value);
                  },
                ),
              ],
            );
          },
        ),
        actions: [
          ConduitTextButton(
            text: l10n.cancel,
            onPressed: () => Navigator.of(context).pop(false),
          ),
          ConduitTextButton(
            text: l10n.create,
            isPrimary: true,
            onPressed: () {
              name = controller.text;
              Navigator.of(context).pop(true);
            },
          ),
        ],
      );
      controller.dispose();
      if (confirmed != true) return;
    }

    final folderName = name?.trim();
    if (folderName == null || folderName.isEmpty) return;

    try {
      final api = ref.read(apiServiceProvider);
      if (api == null) throw Exception('No API service');
      final created = await api.createFolder(
        name: folderName,
        parentId: selectedParentId,
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
