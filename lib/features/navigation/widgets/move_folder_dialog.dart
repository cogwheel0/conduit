import 'package:conduit/core/models/folder_tree.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/folder.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/services/haptic_service.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/themed_dialogs.dart';

/// Dialog helpers for moving folders to another parent folder.
class MoveFolderDialog {
  MoveFolderDialog._();

  /// Shows a parent picker and applies the folder move when confirmed.
  static Future<void> show(
    BuildContext context,
    WidgetRef ref, {
    required Folder folder,
    required List<Folder> allFolders,
    required Future<void> Function(String message) onError,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final blockedIds = <String>{
      folder.id,
      ...FolderTreeNode.getDescendantIds(folder.id, allFolders),
    };

    final candidates = allFolders
        .where((candidate) => !blockedIds.contains(candidate.id))
        .toList(growable: false)
      ..sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );

    String? selectedParentId = folder.parentId;
    final confirmed = await ThemedDialogs.show<bool>(
      context,
      title: l10n.moveToFolder,
      content: StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final theme = dialogContext.conduitTheme;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
                    borderRadius: BorderRadius.circular(AppBorderRadius.small),
                  ),
                ),
                items: [
                  DropdownMenuItem<String?>(
                    value: null,
                    child: Text(l10n.topLevel),
                  ),
                  ...candidates.map(
                    (candidate) => DropdownMenuItem<String?>(
                      value: candidate.id,
                      child: Text(candidate.name),
                    ),
                  ),
                ],
                onChanged: (value) => setDialogState(() {
                  selectedParentId = value;
                }),
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
          text: l10n.save,
          isPrimary: true,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );

    if (confirmed != true) return;
    if (selectedParentId == folder.parentId) return;

    try {
      final api = ref.read(apiServiceProvider);
      if (api == null) throw Exception('No API service');
      await api.updateFolder(
        folder.id,
        parentId: selectedParentId,
        updateParent: true,
      );
      ref.read(foldersProvider.notifier).updateFolder(
            folder.id,
            (existing) => existing.copyWith(
              parentId: selectedParentId,
              updatedAt: DateTime.now(),
            ),
          );
      ConduitHaptics.selectionClick();
      refreshConversationsCache(ref, includeFolders: true);
    } catch (e, stackTrace) {
      DebugLogger.error(
        'move-folder-failed',
        scope: 'drawer',
        error: e,
        stackTrace: stackTrace,
      );
      await onError(l10n.failedToMoveFolder);
    }
  }
}
