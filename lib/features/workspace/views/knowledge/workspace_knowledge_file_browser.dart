import 'dart:async';
import 'dart:io';

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit/core/models/file_info.dart';
import 'package:conduit/core/utils/debug_logger.dart';
import 'package:conduit/features/chat/widgets/server_file_picker_sheet.dart';
import 'package:conduit/features/workspace/models/workspace_knowledge.dart';
import 'package:conduit/features/workspace/providers/workspace_knowledge_files.dart';
import 'package:conduit/features/workspace/widgets/workspace_tiles.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/conduit_loading.dart';
import 'package:conduit/shared/widgets/themed_dialogs.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';

/// File/directory browser embedded in the knowledge editor. Renders breadcrumbs,
/// nested directories, files with ingestion status, and (when writable) the
/// upload / attach / add-text / new-folder affordances. Polls the pending
/// endpoint while ingestion is in flight.
class WorkspaceKnowledgeFileBrowser extends ConsumerStatefulWidget {
  const WorkspaceKnowledgeFileBrowser({
    super.key,
    required this.knowledgeId,
    required this.readOnly,
    required this.canDeleteUnderlying,
  });

  final String knowledgeId;

  /// True for external/connected bases or when the caller lacks write access:
  /// no mutation controls are shown.
  final bool readOnly;

  /// Whether "also delete the underlying file" may be offered on detach
  /// (owner/admin only).
  final bool canDeleteUnderlying;

  @override
  ConsumerState<WorkspaceKnowledgeFileBrowser> createState() =>
      _WorkspaceKnowledgeFileBrowserState();
}

class _WorkspaceKnowledgeFileBrowserState
    extends ConsumerState<WorkspaceKnowledgeFileBrowser> {
  Timer? _pollTimer;

  WorkspaceKnowledgeFilesProvider get _provider =>
      workspaceKnowledgeFilesProvider(widget.knowledgeId);

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _syncPolling(WorkspaceKnowledgeBrowserState state) {
    final hasPending = state.pending.isNotEmpty;
    if (hasPending && _pollTimer == null) {
      _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        ref.read(_provider.notifier).refreshPending();
      });
    } else if (!hasPending && _pollTimer != null) {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final async = ref.watch(_provider);

    return async.when(
      loading: () => Padding(
        key: const Key('knowledge-files-loading'),
        padding: const EdgeInsets.all(Spacing.xl),
        child: Center(
          child: ConduitLoading.primary(message: l10n.loadingShort),
        ),
      ),
      error: (_, _) =>
          _ErrorState(onRetry: () => ref.read(_provider.notifier).refresh()),
      data: (state) {
        _syncPolling(state);
        return _Browser(
          knowledgeId: widget.knowledgeId,
          state: state,
          readOnly: widget.readOnly,
          canDeleteUnderlying: widget.canDeleteUnderlying,
        );
      },
    );
  }
}

class _Browser extends ConsumerWidget {
  const _Browser({
    required this.knowledgeId,
    required this.state,
    required this.readOnly,
    required this.canDeleteUnderlying,
  });

  final String knowledgeId;
  final WorkspaceKnowledgeBrowserState state;
  final bool readOnly;
  final bool canDeleteUnderlying;

  WorkspaceKnowledgeFiles _notifier(WidgetRef ref) =>
      ref.read(workspaceKnowledgeFilesProvider(knowledgeId).notifier);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                l10n.workspaceKnowledgeFilesTitle,
                style: theme.headingSmall,
              ),
            ),
            IconButton(
              key: const Key('knowledge-files-refresh'),
              tooltip: l10n.workspaceKnowledgeRefreshFiles,
              onPressed: () => _notifier(ref).refresh(),
              icon: const Icon(Icons.refresh),
            ),
            if (!readOnly)
              _AddMenu(
                onUpload: () => _uploadSingle(context, ref),
                onUploadMultiple: () => _uploadMultiple(context, ref),
                onAttachExisting: () => _attachExisting(context, ref),
                onAddText: () => _addText(context, ref),
                onNewFolder: () => _newFolder(context, ref),
              ),
          ],
        ),
        if (readOnly)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
            child: _Notice(message: l10n.workspaceKnowledgeExternalReadOnly),
          ),
        _Breadcrumbs(
          breadcrumbs: state.breadcrumbs,
          onOpen: (id) => _notifier(ref).openBreadcrumb(id),
        ),
        if (state.upload != null) _UploadBanner(progress: state.upload!),
        if (state.isBusy && state.upload == null)
          const LinearProgressIndicator(minHeight: 2),
        if (state.error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
            child: _Notice(
              message: l10n.workspaceKnowledgeFilesLoadFailed,
              isError: true,
            ),
          ),
        const SizedBox(height: Spacing.sm),
        if (state.isEmpty)
          ConduitEmptyState(
            key: const Key('knowledge-files-empty'),
            isCompact: true,
            icon: Icons.folder_open_outlined,
            title: l10n.workspaceKnowledgeFilesTitle,
            message: l10n.workspaceKnowledgeFilesEmpty,
          )
        else ...[
          for (final dir in state.directories)
            _DirectoryTile(
              key: Key('knowledge-directory-${dir.id}'),
              directory: dir,
              readOnly: readOnly,
              onOpen: () => _notifier(ref).openDirectory(dir.id),
              onRename: () => _renameDirectory(context, ref, dir),
              onDelete: () => _deleteDirectory(context, ref, dir),
            ),
          for (final pending in state.pending)
            _PendingTile(
              key: Key('knowledge-pending-${pending.id}'),
              pending: pending,
            ),
          for (final file in state.files)
            _FileTile(
              key: Key('knowledge-file-${file.id}'),
              file: file,
              readOnly: readOnly,
              onRename: () => _renameFile(context, ref, file),
              onRefresh: () => _reindex(context, ref, file),
              onMove: () => _moveFile(context, ref, file),
              onDetach: () => _detachFile(context, ref, file),
            ),
          if (state.hasMore)
            Padding(
              padding: const EdgeInsets.all(Spacing.sm),
              child: Center(
                child: state.isLoadingMore
                    ? ConduitLoading.inline(context: context)
                    : AdaptiveButton(
                        key: const Key('knowledge-files-load-more'),
                        onPressed: () => _notifier(ref).loadMore(),
                        style: AdaptiveButtonStyle.plain,
                        size: AdaptiveButtonSize.small,
                        label: l10n.workspaceLoadMore,
                      ),
              ),
            ),
        ],
      ],
    );
  }

  // --- Actions --------------------------------------------------------------

  Future<void> _uploadSingle(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final notifier = _notifier(ref);
    final picked = await FilePicker.pickFile(type: FileType.any);
    if (picked == null || !context.mounted) return;
    await _guard(context, () async {
      final bytes = picked.path != null
          ? await File(picked.path!).readAsBytes()
          : await picked.readAsBytes();
      if (bytes.isEmpty) return;
      await notifier.uploadBytes(picked.name, bytes);
    }, failureText: l10n.workspaceKnowledgeUploadFailed);
  }

  Future<void> _uploadMultiple(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final notifier = _notifier(ref);
    final result = await FilePicker.pickFiles(type: FileType.any);
    final files = result?.files ?? const [];
    if (files.isEmpty || !context.mounted) return;
    await _guard(context, () async {
      final ids = <String>[];
      for (final picked in files) {
        final bytes = picked.path != null
            ? await File(picked.path!).readAsBytes()
            : await picked.readAsBytes();
        if (bytes.isEmpty) continue;
        ids.add(await notifier.uploadForBatch(picked.name, bytes));
      }
      await notifier.batchAttach(ids);
    }, failureText: l10n.workspaceKnowledgeUploadFailed);
  }

  Future<void> _attachExisting(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final notifier = _notifier(ref);
    await ThemedSheets.showCustom<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ServerFilePickerSheet(
        onSelected: (FileInfo file) async {
          await _guard(
            context,
            () => notifier.attachExisting(file.id),
            failureText: l10n.workspaceKnowledgeAttachFailed,
          );
        },
      ),
    );
  }

  Future<void> _addText(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final notifier = _notifier(ref);
    final result = await _AddTextDialog.show(context);
    if (result == null || !context.mounted) return;
    await _guard(
      context,
      () => notifier.addTextFile(result.$1, result.$2),
      failureText: l10n.workspaceKnowledgeAddTextFailed,
    );
  }

  Future<void> _newFolder(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final notifier = _notifier(ref);
    final name = await _promptText(
      context,
      title: l10n.workspaceKnowledgeNewFolder,
      label: l10n.workspaceKnowledgeFolderName,
    );
    if (name == null || name.trim().isEmpty || !context.mounted) return;
    await _guard(
      context,
      () => notifier.createDirectory(name.trim()),
      failureText: l10n.workspaceKnowledgeFolderCreateFailed,
    );
  }

  Future<void> _renameDirectory(
    BuildContext context,
    WidgetRef ref,
    WorkspaceKnowledgeDirectory dir,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final notifier = _notifier(ref);
    final name = await _promptText(
      context,
      title: l10n.workspaceKnowledgeRenameFolder,
      label: l10n.workspaceKnowledgeFolderName,
      initial: dir.name,
    );
    if (name == null ||
        name.trim().isEmpty ||
        name.trim() == dir.name ||
        !context.mounted) {
      return;
    }
    await _guard(
      context,
      () => notifier.updateDirectory(dir.id, name.trim()),
      failureText: l10n.workspaceKnowledgeFolderCreateFailed,
    );
  }

  Future<void> _deleteDirectory(
    BuildContext context,
    WidgetRef ref,
    WorkspaceKnowledgeDirectory dir,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final notifier = _notifier(ref);
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.workspaceKnowledgeDeleteFolderConfirmTitle,
      message: l10n.workspaceKnowledgeDeleteFolderConfirmMessage(dir.name),
      confirmText: l10n.delete,
      cancelText: l10n.cancel,
      isDestructive: true,
    );
    if (!confirmed || !context.mounted) return;
    await _guard(
      context,
      () => notifier.deleteDirectory(dir.id),
      failureText: l10n.workspaceKnowledgeFolderDeleteFailed,
    );
  }

  Future<void> _renameFile(
    BuildContext context,
    WidgetRef ref,
    WorkspaceKnowledgeFile file,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final notifier = _notifier(ref);
    final name = await _promptText(
      context,
      title: l10n.workspaceKnowledgeFileRename,
      label: l10n.workspaceKnowledgeAddTextName,
      initial: file.filename,
    );
    if (name == null ||
        name.trim().isEmpty ||
        name.trim() == file.filename ||
        !context.mounted) {
      return;
    }
    await _guard(
      context,
      () => notifier.rename(file.id, name.trim()),
      failureText: l10n.workspaceKnowledgeFileRenameFailed,
    );
  }

  Future<void> _reindex(
    BuildContext context,
    WidgetRef ref,
    WorkspaceKnowledgeFile file,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final notifier = _notifier(ref);
    await _guard(
      context,
      () => notifier.reindex(file.id),
      failureText: l10n.workspaceKnowledgeSaveFailed,
      successText: l10n.workspaceKnowledgeFileReindexed,
    );
  }

  Future<void> _moveFile(
    BuildContext context,
    WidgetRef ref,
    WorkspaceKnowledgeFile file,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final notifier = _notifier(ref);
    final target = await _MoveSheet.show(
      context,
      breadcrumbs: state.breadcrumbs,
      directories: state.directories,
      currentDirectoryId: file.directoryId ?? '',
    );
    if (target == null || !context.mounted) return;
    await _guard(
      context,
      () => notifier.move(file.id, target.id),
      failureText: l10n.workspaceKnowledgeFileMoveFailed,
    );
  }

  Future<void> _detachFile(
    BuildContext context,
    WidgetRef ref,
    WorkspaceKnowledgeFile file,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final notifier = _notifier(ref);
    final choice = await _DetachDialog.show(
      context,
      filename: file.filename,
      canDeleteUnderlying: canDeleteUnderlying,
    );
    if (choice == null || !context.mounted) return;
    await _guard(
      context,
      () => notifier.detach(file.id, deleteUnderlying: choice),
      failureText: l10n.workspaceKnowledgeFileDetachFailed,
    );
  }

  Future<void> _guard(
    BuildContext context,
    Future<void> Function() action, {
    required String failureText,
    String? successText,
  }) async {
    try {
      await action();
      if (successText != null && context.mounted) {
        AdaptiveSnackBar.show(
          context,
          message: successText,
          type: AdaptiveSnackBarType.success,
        );
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'knowledge file action failed',
        scope: 'workspace/knowledge',
        error: error,
        stackTrace: stackTrace,
      );
      if (context.mounted) {
        AdaptiveSnackBar.show(
          context,
          message: failureText,
          type: AdaptiveSnackBarType.error,
        );
      }
    }
  }
}

Future<String?> _promptText(
  BuildContext context, {
  required String title,
  required String label,
  String? initial,
}) {
  final controller = TextEditingController(text: initial ?? '');
  return ThemedDialogs.showCustom<String>(
    context: context,
    builder: (dialogContext) {
      final l10n = AppLocalizations.of(dialogContext)!;
      return ThemedDialogs.buildBase(
        context: dialogContext,
        title: title,
        content: ConduitInput(
          key: const Key('knowledge-text-prompt'),
          controller: controller,
          label: label,
          autofocus: true,
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          ConduitTextButton(
            text: l10n.cancel,
            onPressed: () => Navigator.of(dialogContext).pop(),
          ),
          ConduitTextButton(
            key: const Key('knowledge-text-prompt-confirm'),
            text: l10n.save,
            isPrimary: true,
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
          ),
        ],
      );
    },
  );
}

// ---------------------------------------------------------------------------

class _AddMenu extends StatelessWidget {
  const _AddMenu({
    required this.onUpload,
    required this.onUploadMultiple,
    required this.onAttachExisting,
    required this.onAddText,
    required this.onNewFolder,
  });

  final VoidCallback onUpload;
  final VoidCallback onUploadMultiple;
  final VoidCallback onAttachExisting;
  final VoidCallback onAddText;
  final VoidCallback onNewFolder;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PopupMenuButton<int>(
      key: const Key('knowledge-add-menu'),
      tooltip: l10n.workspaceKnowledgeAddMenu,
      icon: const Icon(Icons.add),
      onSelected: (value) {
        switch (value) {
          case 0:
            onUpload();
          case 1:
            onUploadMultiple();
          case 2:
            onAttachExisting();
          case 3:
            onAddText();
          case 4:
            onNewFolder();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          key: const Key('knowledge-add-upload'),
          value: 0,
          child: Text(l10n.workspaceKnowledgeUpload),
        ),
        PopupMenuItem(
          key: const Key('knowledge-add-upload-multiple'),
          value: 1,
          child: Text(l10n.workspaceKnowledgeBatchAttach),
        ),
        PopupMenuItem(
          key: const Key('knowledge-add-attach'),
          value: 2,
          child: Text(l10n.workspaceKnowledgeAttachExisting),
        ),
        PopupMenuItem(
          key: const Key('knowledge-add-text'),
          value: 3,
          child: Text(l10n.workspaceKnowledgeAddText),
        ),
        PopupMenuItem(
          key: const Key('knowledge-add-folder'),
          value: 4,
          child: Text(l10n.workspaceKnowledgeNewFolder),
        ),
      ],
    );
  }
}

class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({required this.breadcrumbs, required this.onOpen});

  final List<WorkspaceKnowledgeDirectory> breadcrumbs;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return SizedBox(
      height: 36,
      child: ListView(
        key: const Key('knowledge-breadcrumbs'),
        scrollDirection: Axis.horizontal,
        children: [
          AdaptiveButton(
            key: const Key('knowledge-breadcrumb-root'),
            onPressed: () => onOpen(''),
            style: AdaptiveButtonStyle.plain,
            size: AdaptiveButtonSize.small,
            label: l10n.workspaceKnowledgeRoot,
          ),
          for (final crumb in breadcrumbs) ...[
            Icon(
              Icons.chevron_right,
              size: IconSize.small,
              color: theme.iconSecondary,
            ),
            AdaptiveButton(
              key: Key('knowledge-breadcrumb-${crumb.id}'),
              onPressed: () => onOpen(crumb.id),
              style: AdaptiveButtonStyle.plain,
              size: AdaptiveButtonSize.small,
              label: crumb.name,
            ),
          ],
        ],
      ),
    );
  }
}

class _DirectoryTile extends StatelessWidget {
  const _DirectoryTile({
    super.key,
    required this.directory,
    required this.readOnly,
    required this.onOpen,
    required this.onRename,
    required this.onDelete,
  });

  final WorkspaceKnowledgeDirectory directory;
  final bool readOnly;
  final VoidCallback onOpen;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: WorkspaceResourceTile(
        icon: Icons.folder_outlined,
        title: directory.name,
        onTap: onOpen,
        showChevron: readOnly,
        trailing: readOnly
            ? null
            : PopupMenuButton<int>(
                key: Key('knowledge-directory-menu-${directory.id}'),
                tooltip: l10n.workspaceKnowledgeRenameFolder,
                icon: const Icon(Icons.more_vert),
                onSelected: (value) => value == 0 ? onRename() : onDelete(),
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 0,
                    child: Text(l10n.workspaceKnowledgeRenameFolder),
                  ),
                  PopupMenuItem(
                    value: 1,
                    child: Text(l10n.workspaceKnowledgeDeleteFolder),
                  ),
                ],
              ),
      ),
    );
  }
}

class _PendingTile extends StatelessWidget {
  const _PendingTile({super.key, required this.pending});

  final WorkspacePendingFile pending;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final failed =
        (pending.status ?? '').toLowerCase() == 'failed' ||
        pending.error != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: WorkspaceResourceTile(
        leading: failed
            ? WorkspaceIconBadge(icon: Icons.error_outline, color: theme.error)
            : SizedBox(
                width: 40,
                height: 40,
                child: Center(child: ConduitLoading.inline(context: context)),
              ),
        title: pending.raw['filename']?.toString() ?? pending.id,
        subtitle: failed
            ? l10n.workspaceKnowledgeStatusFailed
            : l10n.workspaceKnowledgeStatusPending,
      ),
    );
  }
}

class _FileTile extends StatelessWidget {
  const _FileTile({
    super.key,
    required this.file,
    required this.readOnly,
    required this.onRename,
    required this.onRefresh,
    required this.onMove,
    required this.onDetach,
  });

  final WorkspaceKnowledgeFile file;
  final bool readOnly;
  final VoidCallback onRename;
  final VoidCallback onRefresh;
  final VoidCallback onMove;
  final VoidCallback onDetach;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: WorkspaceResourceTile(
        icon: Icons.insert_drive_file_outlined,
        title: file.filename,
        subtitle: file.size == null ? null : _formatSize(file.size!),
        trailing: readOnly
            ? null
            : PopupMenuButton<int>(
                key: Key('knowledge-file-menu-${file.id}'),
                tooltip: l10n.workspaceKnowledgeFileRename,
                icon: const Icon(Icons.more_vert),
                onSelected: (value) {
                  switch (value) {
                    case 0:
                      onRename();
                    case 1:
                      onRefresh();
                    case 2:
                      onMove();
                    case 3:
                      onDetach();
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 0,
                    child: Text(l10n.workspaceKnowledgeFileRename),
                  ),
                  PopupMenuItem(
                    value: 1,
                    child: Text(l10n.workspaceKnowledgeFileRefresh),
                  ),
                  PopupMenuItem(
                    value: 2,
                    child: Text(l10n.workspaceKnowledgeFileMove),
                  ),
                  PopupMenuItem(
                    key: Key('knowledge-file-detach-${file.id}'),
                    value: 3,
                    child: Text(l10n.workspaceKnowledgeFileDetach),
                  ),
                ],
              ),
      ),
    );
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _UploadBanner extends StatelessWidget {
  const _UploadBanner({required this.progress});

  final WorkspaceUploadProgress progress;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return Padding(
      key: const Key('knowledge-upload-banner'),
      padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.workspaceKnowledgeUploading(progress.filename),
            style: theme.caption?.copyWith(color: theme.textSecondary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: Spacing.xxs),
          LinearProgressIndicator(value: progress.fraction, minHeight: 3),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.message, this.isError = false});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final color = isError ? theme.error : theme.textSecondary;
    return Container(
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: isError ? theme.errorBackground : theme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppBorderRadius.small),
      ),
      child: Row(
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.lock_outline,
            size: IconSize.small,
            color: color,
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              message,
              style: theme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      key: const Key('knowledge-files-error'),
      padding: const EdgeInsets.all(Spacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, color: context.conduitTheme.error),
          const SizedBox(height: Spacing.sm),
          Text(l10n.workspaceKnowledgeFilesLoadFailed),
          const SizedBox(height: Spacing.sm),
          ConduitButton(
            key: const Key('knowledge-files-retry'),
            text: l10n.workspaceRetry,
            isCompact: true,
            onPressed: onRetry,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _AddTextDialog {
  static Future<(String, String)?> show(BuildContext context) {
    final nameController = TextEditingController();
    final contentController = TextEditingController();
    return ThemedDialogs.showCustom<(String, String)>(
      context: context,
      builder: (dialogContext) {
        final l10n = AppLocalizations.of(dialogContext)!;
        return ThemedDialogs.buildBase(
          context: dialogContext,
          title: l10n.workspaceKnowledgeAddText,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConduitInput(
                key: const Key('knowledge-add-text-name'),
                controller: nameController,
                label: l10n.workspaceKnowledgeAddTextName,
              ),
              const SizedBox(height: Spacing.sm),
              ConduitInput(
                key: const Key('knowledge-add-text-content'),
                controller: contentController,
                label: l10n.workspaceKnowledgeAddTextContent,
                minLines: 3,
                maxLines: 6,
              ),
            ],
          ),
          actions: [
            ConduitTextButton(
              text: l10n.cancel,
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
            ConduitTextButton(
              key: const Key('knowledge-add-text-confirm'),
              text: l10n.save,
              isPrimary: true,
              onPressed: () {
                final name = nameController.text.trim();
                if (name.isEmpty) return;
                Navigator.of(dialogContext).pop((name, contentController.text));
              },
            ),
          ],
        );
      },
    );
  }
}

class _DetachDialog {
  /// Returns null on cancel, or whether to delete the underlying file.
  static Future<bool?> show(
    BuildContext context, {
    required String filename,
    required bool canDeleteUnderlying,
  }) {
    var deleteUnderlying = false;
    return ThemedDialogs.showCustom<bool>(
      context: context,
      builder: (dialogContext) {
        final l10n = AppLocalizations.of(dialogContext)!;
        return StatefulBuilder(
          builder: (context, setState) => ThemedDialogs.buildBase(
            context: dialogContext,
            title: l10n.workspaceKnowledgeFileDetachTitle,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.workspaceKnowledgeFileDetachMessage(filename)),
                if (canDeleteUnderlying)
                  AdaptiveListTile(
                    key: const Key('knowledge-detach-delete-underlying'),
                    padding: EdgeInsets.zero,
                    title: Text(l10n.workspaceKnowledgeFileDeleteUnderlying),
                    trailing: AdaptiveCheckbox(
                      value: deleteUnderlying,
                      onChanged: (value) =>
                          setState(() => deleteUnderlying = value ?? false),
                    ),
                    onTap: () =>
                        setState(() => deleteUnderlying = !deleteUnderlying),
                  ),
              ],
            ),
            actions: [
              ConduitTextButton(
                text: l10n.cancel,
                onPressed: () => Navigator.of(dialogContext).pop(),
              ),
              ConduitTextButton(
                key: const Key('knowledge-detach-confirm'),
                text: l10n.workspaceKnowledgeFileDetach,
                isPrimary: true,
                onPressed: () =>
                    Navigator.of(dialogContext).pop(deleteUnderlying),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Simple move-target picker offering root, breadcrumb ancestors, and the
/// directories visible at the current level.
class _MoveSheet {
  static Future<WorkspaceKnowledgeDirectory?> show(
    BuildContext context, {
    required List<WorkspaceKnowledgeDirectory> breadcrumbs,
    required List<WorkspaceKnowledgeDirectory> directories,
    required String currentDirectoryId,
  }) {
    final options = <WorkspaceKnowledgeDirectory>[
      for (final crumb in breadcrumbs) crumb,
      for (final dir in directories) dir,
    ];
    final seen = <String>{};
    final unique = [
      for (final dir in options)
        if (seen.add(dir.id)) dir,
    ];
    return ThemedSheets.showSurface<WorkspaceKnowledgeDirectory>(
      context: context,
      padding: EdgeInsets.zero,
      builder: (sheetContext) {
        final l10n = AppLocalizations.of(sheetContext)!;
        return SafeArea(
          child: ListView(
            key: const Key('knowledge-move-sheet'),
            shrinkWrap: true,
            children: [
              AdaptiveListTile(
                title: Text(
                  l10n.workspaceKnowledgeMoveTitle,
                  style: context.conduitTheme.label,
                ),
              ),
              AdaptiveListTile(
                key: const Key('knowledge-move-root'),
                leading: const Icon(Icons.home_outlined),
                title: Text(l10n.workspaceKnowledgeMoveRoot),
                onTap: () => Navigator.of(sheetContext).pop(
                  const WorkspaceKnowledgeDirectory(
                    id: '',
                    knowledgeId: '',
                    name: '',
                    userId: '',
                  ),
                ),
              ),
              for (final dir in unique)
                AdaptiveListTile(
                  key: Key('knowledge-move-${dir.id}'),
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(dir.name),
                  enabled: dir.id != currentDirectoryId,
                  onTap: () => Navigator.of(sheetContext).pop(dir),
                ),
            ],
          ),
        );
      },
    );
  }
}
