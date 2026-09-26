import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../../l10n/strings.g.dart';
import '../../rpc/rpc_providers.dart' show attachmentsProvider;
import '../../rpc/workspace_providers.dart';
import '../../widgets/form_field.dart';
import 'workspace_common.dart';
import '../../widgets/ui.dart';

/// A knowledge base's files, folder by folder: upload, new folders, and
/// per file rename, move, re-read, remove or delete.
class KnowledgeFiles extends StatefulComponent {
  const KnowledgeFiles({
    required this.knowledgeId,
    required this.canWrite,
    super.key,
  });

  final String knowledgeId;
  final bool canWrite;

  @override
  State<KnowledgeFiles> createState() => _KnowledgeFilesState();
}

class _KnowledgeFilesState extends State<KnowledgeFiles> {
  String? _status;
  bool _statusIsError = false;
  bool _busy = false;

  /// The folder being named, new (`''`) or renamed (its id).
  String? _naming;
  String _name = '';

  /// The file being renamed or moved, by id.
  String? _renaming;
  String? _moving;

  /// The file whose removal is being confirmed, and whether the file
  /// itself goes too.
  String? _removing;
  bool _deleteUnderlying = false;
  String? _deletingFolder;

  WorkspaceFilesNotifier _notifier(BuildContext context) =>
      context.read(workspaceFilesProvider(component.knowledgeId).notifier);

  void _say(String text, {bool error = false}) => setState(() {
    _status = text;
    _statusIsError = error;
  });

  Future<void> _run(
    Future<void> Function() action, {
    required String failed,
    String? done,
  }) async {
    setState(() => _busy = true);
    try {
      await action();
      if (done != null) {
        _say(done);
      } else if (mounted) {
        setState(() => _status = null);
      }
    } on Object {
      _say(failed, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _upload(BuildContext context) async {
    final attachments = context.read(attachmentsProvider);
    final notifier = _notifier(context);
    final picked = await attachments.pick();
    if (picked.isEmpty) return;
    await _run(() async {
      final ids = <String>[];
      for (final file in picked) {
        _say(t.app.workspaceKnowledgeUploading(name: file.name));
        ids.add(await attachments.upload(file.handle));
      }
      await notifier.attach(ids);
    }, failed: t.app.workspaceKnowledgeUploadFailed);
  }

  @override
  Component build(BuildContext context) {
    final files = context.watch(workspaceFilesProvider(component.knowledgeId));
    final value = files.value;
    final canWrite = component.canWrite;
    final folders = value?.directories ?? const <WorkspaceDirectory>[];
    final failed = [
      for (final f in value?.pending ?? const <WorkspaceFile>[])
        if (f.status == 'failed' || f.error != null) f,
    ];
    return section(
      classes: 'space-y-3 rounded-lg border border-border p-4',
      attributes: <String, String>{
        'aria-label': t.app.workspaceKnowledgeFilesTitle,
      },
      [
        div(classes: 'flex flex-wrap items-center gap-2', [
          h3(classes: 'flex-1 text-ui-base font-semibold', [
            Component.text(t.app.workspaceKnowledgeFilesTitle),
            if (value != null)
              span(
                classes: 'ml-2 text-ui-sm font-normal text-foreground-subtle',
                [Component.text('${value.total}')],
              ),
          ]),
          actionButton(
            t.app.workspaceKnowledgeRefreshFiles,
            disabled: _busy,
            onClick: () => unawaited(
              _run(
                _notifier(context).refresh,
                failed: t.app.workspaceKnowledgeFilesLoadFailed,
              ),
            ),
          ),
          if (canWrite) ...[
            actionButton(
              t.app.workspaceKnowledgeNewFolder,
              id: 'knowledge-new-folder',
              disabled: _busy,
              onClick: () => setState(() {
                _naming = '';
                _name = '';
              }),
            ),
            actionButton(
              t.app.workspaceKnowledgeUpload,
              primary: true,
              id: 'knowledge-upload',
              disabled: _busy,
              onClick: () => unawaited(_upload(context)),
            ),
          ],
        ]),
        // Where this folder is, from the top.
        nav(
          classes: 'flex flex-wrap items-center gap-1 text-ui-sm',
          attributes: <String, String>{
            'aria-label': t.app.workspaceKnowledgeRoot,
          },
          [
            _crumb(context, t.app.workspaceKnowledgeRoot, ''),
            for (final crumb
                in value?.breadcrumbs ?? const <WorkspaceDirectory>[]) ...[
              span(classes: 'text-foreground-subtle', [Component.text('/')]),
              _crumb(context, crumb.name, crumb.id),
            ],
          ],
        ),
        if (_status case final status?)
          statusLine(status, error: _statusIsError),
        if (_naming case final naming?)
          div(classes: 'flex items-end gap-2', [
            div(classes: 'flex-1', [
              textField(
                id: 'knowledge-folder-name',
                labelText: t.app.workspaceKnowledgeFolderName,
                value: _name,
                autofocus: true,
                onInput: (text) => setState(() => _name = text),
              ),
            ]),
            actionButton(
              t.app.save,
              primary: true,
              id: 'knowledge-folder-save',
              disabled: _name.trim().isEmpty || _busy,
              onClick: () {
                final name = _name.trim();
                setState(() => _naming = null);
                unawaited(
                  _run(
                    () => naming.isEmpty
                        ? _notifier(
                            context,
                          ).directory(WorkspaceDirectoryOp.create, name: name)
                        : _notifier(context).directory(
                            WorkspaceDirectoryOp.rename,
                            targetId: naming,
                            name: name,
                          ),
                    failed: t.app.workspaceKnowledgeFolderCreateFailed,
                  ),
                );
              },
            ),
            actionButton(
              t.app.cancel,
              onClick: () => setState(() => _naming = null),
            ),
          ]),
        if (files.isLoading && value == null)
          statusLine(t.app.loadingShort)
        else if (files.hasError && value == null)
          statusLine(t.app.workspaceKnowledgeFilesLoadFailed, error: true)
        else if (value != null &&
            value.files.isEmpty &&
            folders.isEmpty &&
            value.pending.isEmpty)
          statusLine(t.app.workspaceKnowledgeFilesEmpty),
        ul(classes: 'divide-y divide-border', [
          for (final folder in folders) _folderRow(context, folder),
          for (final file in value?.pending ?? const <WorkspaceFile>[])
            li(classes: 'flex items-center gap-2 py-1.5 text-ui-base', [
              span(classes: 'min-w-0 flex-1 truncate', [
                Component.text(file.filename),
              ]),
              badge(
                file.status == 'failed' || file.error != null
                    ? t.app.workspaceKnowledgeStatusFailed
                    : t.app.workspaceKnowledgeStatusPending,
              ),
            ]),
          for (final file in value?.files ?? const <WorkspaceFile>[])
            _fileRow(context, file, folders),
        ]),
        if (failed.isNotEmpty && canWrite)
          actionButton(
            t.desktop.desktopWorkspaceCleanupFailed,
            destructive: true,
            onClick: () => unawaited(
              _run(
                _notifier(context).cleanup,
                failed: t.app.workspaceKnowledgeFileDetachFailed,
              ),
            ),
          ),
        if (value?.hasMore ?? false)
          actionButton(
            t.app.workspaceLoadMore,
            onClick: () => unawaited(
              _run(
                _notifier(context).loadMore,
                failed: t.app.workspaceKnowledgeFilesLoadFailed,
              ),
            ),
          ),
      ],
    );
  }

  Component _crumb(BuildContext context, String text, String directoryId) =>
      button(
        [Component.text(text)],
        classes: 'rounded-lg px-1 hover:bg-hover',
        type: ButtonType.button,
        onClick: () => unawaited(
          _run(
            () => _notifier(context).open(directoryId),
            failed: t.app.workspaceKnowledgeFilesLoadFailed,
          ),
        ),
      );

  Component _folderRow(BuildContext context, WorkspaceDirectory folder) => li(
    classes: 'space-y-2 py-1.5',
    attributes: <String, String>{'data-folder': folder.id},
    [
      div(classes: 'flex items-center gap-2 text-ui-base', [
        button(
          [
            icon(
              LucideIcon.folder,
              classes: 'size-3.5 shrink-0 text-foreground-subtle',
            ),
            span(classes: 'sr-only', [
              Component.text('${t.app.folderIconFolder} '),
            ]),
            span(classes: 'truncate', [Component.text(folder.name)]),
          ],
          classes:
              'flex min-w-0 flex-1 items-center gap-1.5 text-left '
              'hover:underline',
          type: ButtonType.button,
          onClick: () => unawaited(
            _run(
              () => _notifier(context).open(folder.id),
              failed: t.app.workspaceKnowledgeFilesLoadFailed,
            ),
          ),
        ),
        if (component.canWrite) ...[
          actionButton(
            t.app.rename,
            onClick: () => setState(() {
              _naming = folder.id;
              _name = folder.name;
            }),
          ),
          actionButton(
            t.app.delete,
            destructive: true,
            onClick: () => setState(() => _deletingFolder = folder.id),
          ),
        ],
      ]),
      if (_deletingFolder == folder.id)
        confirmBox(
          title: t.app.workspaceKnowledgeDeleteFolderConfirmTitle,
          message: t.app.workspaceKnowledgeDeleteFolderConfirmMessage(
            name: folder.name,
          ),
          confirmText: t.app.delete,
          onConfirm: () {
            setState(() => _deletingFolder = null);
            unawaited(
              _run(
                () => _notifier(
                  context,
                ).directory(WorkspaceDirectoryOp.delete, targetId: folder.id),
                failed: t.app.workspaceKnowledgeFolderDeleteFailed,
              ),
            );
          },
          onCancel: () => setState(() => _deletingFolder = null),
        ),
    ],
  );

  Component _fileRow(
    BuildContext context,
    WorkspaceFile file,
    List<WorkspaceDirectory> folders,
  ) {
    final crumbs =
        context
            .read(workspaceFilesProvider(component.knowledgeId))
            .value
            ?.breadcrumbs ??
        const <WorkspaceDirectory>[];
    // Where a file can move: the top, the folders here, and this folder's
    // parent.
    final targets = <(String, String)>[
      ('', t.app.workspaceKnowledgeMoveRoot),
      if (crumbs.length > 1)
        (crumbs[crumbs.length - 2].id, crumbs[crumbs.length - 2].name),
      for (final folder in folders) (folder.id, folder.name),
    ];
    return li(
      classes: 'space-y-2 py-1.5',
      attributes: <String, String>{'data-file': file.id},
      [
        div(classes: 'flex items-center gap-2 text-ui-base', [
          span(classes: 'min-w-0 flex-1 truncate', [
            Component.text(file.filename),
            if (file.size case final size?)
              span(classes: 'ml-2 text-ui-sm text-foreground-subtle', [
                Component.text(_size(size)),
              ]),
          ]),
          if (file.status == 'failed')
            badge(t.app.workspaceKnowledgeStatusFailed),
          if (component.canWrite) ...[
            actionButton(
              t.app.workspaceKnowledgeFileRename,
              onClick: () => setState(() {
                _renaming = file.id;
                _name = file.filename;
              }),
            ),
            actionButton(
              t.app.workspaceKnowledgeFileMove,
              onClick: () => setState(() => _moving = file.id),
            ),
            actionButton(
              t.app.workspaceKnowledgeFileRefresh,
              onClick: () => unawaited(
                _run(
                  () =>
                      _notifier(context).file(file.id, WorkspaceFileOp.reindex),
                  failed: t.app.workspaceKnowledgeFilesLoadFailed,
                  done: t.app.workspaceKnowledgeFileReindexed,
                ),
              ),
            ),
            actionButton(
              t.app.workspaceKnowledgeFileDetach,
              destructive: true,
              onClick: () => setState(() {
                _removing = file.id;
                _deleteUnderlying = false;
              }),
            ),
          ],
        ]),
        if (_renaming == file.id)
          div(classes: 'flex items-end gap-2', [
            div(classes: 'flex-1', [
              textField(
                id: 'knowledge-file-name',
                labelText: t.app.workspaceKnowledgeFileRename,
                value: _name,
                autofocus: true,
                onInput: (text) => setState(() => _name = text),
              ),
            ]),
            actionButton(
              t.app.save,
              primary: true,
              disabled: _name.trim().isEmpty,
              onClick: () {
                final name = _name.trim();
                setState(() => _renaming = null);
                unawaited(
                  _run(
                    () => _notifier(context)
                        .file(file.id, WorkspaceFileOp.rename, filename: name),
                    failed: t.app.workspaceKnowledgeFileRenameFailed,
                  ),
                );
              },
            ),
            actionButton(
              t.app.cancel,
              onClick: () => setState(() => _renaming = null),
            ),
          ]),
        if (_moving == file.id)
          div(classes: 'flex flex-wrap items-center gap-1 text-ui-sm', [
            span(classes: 'text-foreground-subtle', [
              Component.text(t.app.workspaceKnowledgeMoveTitle),
            ]),
            for (final (id, name) in targets)
              actionButton(
                name,
                onClick: () {
                  setState(() => _moving = null);
                  unawaited(
                    _run(
                      () => _notifier(context).file(
                        file.id,
                        WorkspaceFileOp.move,
                        targetDirectoryId: id,
                      ),
                      failed: t.app.workspaceKnowledgeFileMoveFailed,
                    ),
                  );
                },
              ),
            actionButton(
              t.app.cancel,
              onClick: () => setState(() => _moving = null),
            ),
          ]),
        if (_removing == file.id)
          div(classes: 'space-y-2', [
            confirmBox(
              title: t.app.workspaceKnowledgeFileDetachTitle,
              message: t.app.workspaceKnowledgeFileDetachMessage(
                name: file.filename,
              ),
              confirmText: t.app.workspaceKnowledgeFileDetach,
              onConfirm: () {
                final op = _deleteUnderlying
                    ? WorkspaceFileOp.delete
                    : WorkspaceFileOp.remove;
                setState(() => _removing = null);
                unawaited(
                  _run(
                    () => _notifier(context).file(file.id, op),
                    failed: t.app.workspaceKnowledgeFileDetachFailed,
                  ),
                );
              },
              onCancel: () => setState(() => _removing = null),
            ),
            checkboxField(
              id: 'knowledge-delete-underlying',
              text: t.app.workspaceKnowledgeFileDeleteUnderlying,
              checked: _deleteUnderlying,
              onChanged: ({required value}) =>
                  setState(() => _deleteUnderlying = value),
            ),
          ]),
      ],
    );
  }

  static String _size(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
