import 'dart:async';

import 'package:conduit/features/chat/services/chat_backup_files.dart';
import 'package:conduit/shared/utils/ui_utils.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/themed_dialogs.dart';
import 'package:conduit/shared/widgets/utility_components.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/services/chat_backup.dart';
import 'package:conduit_core/features/chat/services/chat_data_controls.dart';
import 'package:conduit_core/database/daos/chats_dao.dart'
    show ServerChatBulkScope;
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:dio/dio.dart' show CancelToken, DioException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';

/// Back up and restore the signed-in Open WebUI account's chats, and change
/// every one of them at once.
///
/// The page belongs to the Advanced disclosure. It names the server and account
/// it acts on, captured when it opened: a different account signing in does not
/// retarget it, and anything still running for the first is dropped. A backup
/// is the server's history only, and the page says what it leaves out.
class ChatDataControlsPage extends ConsumerStatefulWidget {
  const ChatDataControlsPage({super.key});

  @override
  ConsumerState<ChatDataControlsPage> createState() =>
      _ChatDataControlsPageState();
}

/// [preparing] covers choosing, counting and confirming: nothing is running
/// yet, but the page must not start a second action.
enum _Activity { idle, syncing, preparing, exporting, importing, changing }

enum _Bulk { archive, unarchive, unshare, delete }

class _ChatDataControlsPageState extends ConsumerState<ChatDataControlsPage> {
  late final ProviderContainer _container;
  ChatDataControlsOwner? _owner;
  ServerChatBulkScope? _scope;
  _Activity _activity = _Activity.idle;
  int _chatsRead = 0;
  CancelToken? _cancel;

  PickedChatFile? _picked;
  String? _importError;
  String? _status;
  bool _statusIsError = false;

  @override
  void initState() {
    super.initState();
    _container = ProviderScope.containerOf(context, listen: false);
    // The account this page acts on is fixed now, before anything is awaited.
    _owner = captureChatDataControlsOwner(_container);
    unawaited(_refreshScope());
  }

  @override
  void dispose() {
    // A download that nobody is waiting for must not keep running.
    _cancel?.cancel();
    super.dispose();
  }

  ChatDataControlsService _service(ChatDataControlsOwner owner) =>
      chatDataControlsServiceForOwner(_container, owner);

  bool get _busy => _activity != _Activity.idle;

  bool _ownerIsCurrent() {
    final owner = _owner;
    return owner != null && chatDataControlsOwnerIsCurrent(_container, owner);
  }

  Future<void> _refreshScope() async {
    final owner = _owner;
    if (owner == null) return;
    try {
      final scope = await _service(owner).scope();
      if (!mounted) return;
      setState(() => _scope = scope);
    } catch (_) {
      // The counts are a disclosure; the actions re-read them themselves.
    }
  }

  void _show(String message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _status = message;
      _statusIsError = error;
    });
  }

  Rect? _shareOrigin() {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return null;
    return renderObject.localToGlobal(Offset.zero) & renderObject.size;
  }

  String _failureText(AppLocalizations l10n, Object error) {
    if (error is ChatDataControlsException) {
      return switch (error.failure) {
        ChatDataControlsFailure.ownerChanged =>
          l10n.chatDataControlsOwnerChanged,
        ChatDataControlsFailure.accountUnknown =>
          l10n.chatDataControlsAccountUnknown,
        ChatDataControlsFailure.forbidden => l10n.chatDataControlsForbidden,
        ChatDataControlsFailure.pendingWork => l10n.chatDataControlsWorkChanged,
        ChatDataControlsFailure.responseRunning =>
          l10n.chatDataControlsResponseRunning,
        ChatDataControlsFailure.localWorkChanged =>
          l10n.chatDataControlsLocalChanged,
        ChatDataControlsFailure.serverRefused => l10n.chatDataControlsRefused,
        ChatDataControlsFailure.outcomeUnknown => l10n.chatDataControlsUnknown,
        ChatDataControlsFailure.unavailable => l10n.chatDataControlsRefused,
      };
    }
    return l10n.chatDataControlsRefused;
  }

  // ---- Sync ----

  Future<void> _syncNow() async {
    final owner = _owner;
    if (owner == null || _busy) return;
    setState(() {
      _activity = _Activity.syncing;
      _status = null;
    });
    try {
      await syncChatDataControlsOwner(_container, owner);
    } catch (_) {
      // Whatever could not be sent stays counted below.
    }
    if (!mounted) return;
    setState(() => _activity = _Activity.idle);
    await _refreshScope();
  }

  // ---- Library backup ----

  Future<void> _exportLibrary() async {
    final owner = _owner;
    if (owner == null || _busy) return;
    final l10n = AppLocalizations.of(context)!;
    final files = _container.read(chatBackupFilesProvider);
    final service = _service(owner);

    setState(() {
      _activity = _Activity.preparing;
      _chatsRead = 0;
      _status = null;
    });
    ChatBackupFile? file;
    var delivered = false;
    try {
      final scope = await service.scope();
      if (!mounted) return;
      final leavesOut =
          scope.localOnlyChatIds.isNotEmpty ||
          scope.unsyncedEdits > 0 ||
          scope.queuedResponses > 0;
      if (leavesOut) {
        final proceed = await ThemedDialogs.confirm(
          context,
          title: l10n.chatDataControlsExportConfirmTitle,
          message:
              '${l10n.chatDataControlsExportConfirmMessage(owner.accountName, owner.serverName)}\n\n'
              '${l10n.chatDataControlsUnsyncedNote}',
          confirmText: l10n.chatDataControlsExportAction,
        );
        if (!proceed || !mounted) {
          if (mounted) setState(() => _activity = _Activity.idle);
          return;
        }
      }

      final cancel = _cancel = CancelToken();
      if (mounted) setState(() => _activity = _Activity.exporting);
      file = await files.create(libraryBackupFileName(DateTime.now()));
      final result = await service.exportLibrary(
        _CountingSink(file, (count) {
          if (mounted) setState(() => _chatsRead = count);
        }),
        cancelToken: cancel,
      );
      if (!mounted) {
        await file.abort();
        return;
      }
      if (result.chats == 0) {
        await file.abort();
        _show(l10n.chatDataControlsExportEmpty);
      } else {
        // The file is delivered only now, after every line arrived intact.
        await files.deliver(file, origin: _shareOrigin());
        delivered = true;
        _show(l10n.chatDataControlsExportReady(result.chats));
      }
    } on ChatBackupException catch (error) {
      _show(switch (error.failure) {
        ChatBackupFailure.cancelled => l10n.chatDataControlsExportStopped,
        ChatBackupFailure.ownerChanged => l10n.chatDataControlsOwnerChanged,
        _ => l10n.chatDataControlsExportFailed,
      }, error: error.failure != ChatBackupFailure.cancelled);
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      _show(
        status == 401 || status == 403
            ? l10n.chatDataControlsForbidden
            : l10n.chatDataControlsExportFailed,
        error: true,
      );
    } catch (_) {
      _show(l10n.chatDataControlsExportFailed, error: true);
    } finally {
      _cancel = null;
      // A file that was never handed over (a refused request, a failure before
      // the first line) must not be left behind. One that was is the share
      // sheet's to read; the next backup clears old ones.
      final staged = file;
      if (staged != null && !delivered) await staged.abort();
      if (mounted) setState(() => _activity = _Activity.idle);
    }
  }

  // ---- Restore ----

  Future<void> _chooseImportFile() async {
    final owner = _owner;
    if (owner == null || _busy) return;
    final l10n = AppLocalizations.of(context)!;
    final files = _container.read(chatBackupFilesProvider);

    final picked = await files.pickImportFile();
    if (picked == null || !mounted) return;
    setState(() {
      _picked = picked;
      _importError = null;
      _status = null;
      _activity = _Activity.preparing;
    });

    ChatImportPreview preview;
    try {
      // Refused before it is read, so a file past the limit never has to fit
      // in memory.
      final size = await picked.length();
      if (size != null && size > kMaxChatImportBytes) {
        throw const ChatBackupException(ChatBackupFailure.fileTooLarge);
      }
      final bytes = await picked.read();
      preview = await prepareChatImportFile(_container, bytes);
    } on ChatBackupException catch (error) {
      if (!mounted) return;
      // The choice stays on screen, so the user sees which file was refused.
      setState(() {
        _importError = switch (error.failure) {
          ChatBackupFailure.emptyImport => l10n.chatDataControlsImportEmpty,
          ChatBackupFailure.fileTooLarge => l10n.chatDataControlsImportTooLarge,
          ChatBackupFailure.invalidField || ChatBackupFailure.unrecognizedChat
              when error.index != null =>
            l10n.chatDataControlsImportBadEntry(error.index! + 1),
          _ => l10n.chatDataControlsImportInvalid,
        };
        _activity = _Activity.idle;
      });
      return;
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _importError = l10n.chatDataControlsImportInvalid;
        _activity = _Activity.idle;
      });
      return;
    }
    if (!mounted) return;

    final proceed = await ThemedDialogs.confirm(
      context,
      title: l10n.chatDataControlsImportConfirmTitle,
      message: l10n.chatDataControlsImportConfirmMessage(
        owner.accountName,
        owner.serverName,
        preview.chats,
        preview.messages,
      ),
      confirmText: l10n.chatDataControlsImportAction,
    );
    if (!proceed || !mounted) {
      if (mounted) setState(() => _activity = _Activity.idle);
      return;
    }

    setState(() => _activity = _Activity.importing);
    try {
      final result = await _service(owner).importChats(preview);
      if (!_ownerIsCurrent()) return;
      refreshConversationsCache(_container);
      _show(
        result.stored < result.imported
            ? '${l10n.chatDataControlsImported(result.imported)} '
                  '${l10n.chatDataControlsImportedSyncNote}'
            : l10n.chatDataControlsImported(result.imported),
      );
      if (mounted) setState(() => _picked = null);
    } catch (error) {
      // Sent again, an import duplicates every chat, so when no answer came
      // the user is told it may have happened rather than that it is safe to
      // repeat.
      _show(
        error is ChatDataControlsException &&
                error.failure == ChatDataControlsFailure.outcomeUnknown
            ? l10n.chatDataControlsImportUnknown
            : _failureText(l10n, error),
        error: true,
      );
    } finally {
      if (mounted) setState(() => _activity = _Activity.idle);
      unawaited(_refreshScope());
    }
  }

  // ---- Account-wide changes ----

  Future<void> _change(_Bulk kind) async {
    final owner = _owner;
    if (owner == null || _busy) return;
    final l10n = AppLocalizations.of(context)!;
    final service = _service(owner);

    setState(() {
      _activity = _Activity.preparing;
      _status = null;
    });
    try {
      final scope = await service.scope();
      if (!mounted) return;
      var discard = false;
      if (kind == _Bulk.delete &&
          (scope.runningResponses > 0 ||
              _container.read(isChatStreamingProvider))) {
        _show(l10n.chatDataControlsResponseRunning, error: true);
        return;
      }
      if (kind == _Bulk.delete) discard = scope.hasWorkTheServerLacks;

      final proceed = await ThemedDialogs.confirm(
        context,
        title: switch (kind) {
          _Bulk.archive => l10n.chatDataControlsArchiveAll,
          _Bulk.unarchive => l10n.chatDataControlsUnarchiveAll,
          _Bulk.unshare => l10n.chatDataControlsUnshareAll,
          _Bulk.delete => l10n.chatDataControlsDeleteAll,
        },
        message: switch (kind) {
          _Bulk.archive => l10n.chatDataControlsArchiveAllMessage,
          _Bulk.unarchive => l10n.chatDataControlsUnarchiveAllMessage,
          _Bulk.unshare => l10n.chatDataControlsUnshareAllMessage,
          _Bulk.delete =>
            '${l10n.chatDataControlsDeleteAllMessage(owner.accountName, owner.serverName)}'
                '${discard ? '\n\n${l10n.chatDataControlsDeleteUnsentMessage(scope.unsyncedEdits, scope.queuedResponses)}' : ''}',
        },
        confirmText: kind == _Bulk.delete
            ? (discard ? l10n.chatDataControlsDiscardAndDelete : l10n.delete)
            : null,
        isDestructive: kind == _Bulk.delete || kind == _Bulk.unshare,
      );
      if (!proceed || !mounted) return;

      setState(() => _activity = _Activity.changing);
      final ChatBulkOutcome outcome;
      final ChatBulkChange change;
      switch (kind) {
        case _Bulk.archive:
          change = ChatBulkChange.archive;
          outcome = await service.archiveAll();
        case _Bulk.unarchive:
          change = ChatBulkChange.unarchive;
          outcome = await service.unarchiveAll();
        case _Bulk.unshare:
          change = ChatBulkChange.unshare;
          outcome = await service.unshareAll();
        case _Bulk.delete:
          change = ChatBulkChange.delete;
          outcome = await service.deleteAll(
            discardUnsyncedWork: discard,
            knownLocalOnlyChatIds: scope.localOnlyChatIds.toSet(),
          );
      }
      // The stored chats are already changed; bring the screen in line even if
      // this page was left meanwhile.
      applyChatBulkOutcome(_container, owner, change, outcome);
      _show(l10n.chatDataControlsDone);
    } catch (error) {
      _show(_failureText(l10n, error), error: true);
    } finally {
      if (mounted) setState(() => _activity = _Activity.idle);
      unawaited(_refreshScope());
    }
  }

  // ---- Build ----

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final advanced = ref.watch(
      appSettingsProvider.select((s) => s.advancedFeaturesEnabled),
    );
    // Rebuild when the server, the account or the sign-in session changes under
    // the page: even the same user signing in again is a new session.
    ref.watch(apiServiceProvider);
    ref.watch(currentUserProvider2);
    ref.watch(openWebUiAuthSessionEpochProvider);
    final owner = _owner;
    if (!advanced || owner == null || !_ownerIsCurrent()) {
      return UtilityPageScaffold.settings(
        title: l10n.chatDataControlsTitle,
        children: [
          Text(
            l10n.chatDataControlsUnavailable,
            key: const Key('chat-data-controls-unavailable'),
          ),
        ],
      );
    }

    final theme = context.conduitTheme;
    final canExport =
        ref.watch(openWebUiChatActionAllowedProvider('export')).asData?.value ??
        false;
    final canImport =
        ref.watch(openWebUiChatActionAllowedProvider('import')).asData?.value ??
        false;
    final canDelete =
        ref.watch(openWebUiChatActionAllowedProvider('delete')).asData?.value ??
        false;
    final scope = _scope;
    final unsynced =
        scope != null &&
        (scope.localOnlyChatIds.isNotEmpty ||
            scope.unsyncedEdits > 0 ||
            scope.queuedResponses > 0);

    return UtilityPageScaffold.settings(
      title: l10n.chatDataControlsTitle,
      children: [
        Text(
          l10n.chatDataControlsStoredOn(owner.accountName, owner.serverName),
          key: const Key('chat-data-controls-account'),
          style: AppTypography.bodyMediumStyle.copyWith(
            color: theme.textPrimary,
          ),
        ),
        const SizedBox(height: Spacing.xs),
        Text(
          l10n.chatDataControlsMediaNote,
          key: const Key('chat-data-controls-media-note'),
          style: AppTypography.bodySmallStyle.copyWith(
            color: theme.textSecondary,
          ),
        ),
        if (unsynced) ...[
          const SizedBox(height: Spacing.md),
          InsetGroupedSection(
            key: const Key('chat-data-controls-unsynced'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (scope.localOnlyChatIds.isNotEmpty)
                  Text(
                    l10n.chatDataControlsLocalOnly(
                      scope.localOnlyChatIds.length,
                    ),
                  ),
                if (scope.unsyncedEdits + scope.queuedResponses > 0)
                  Text(
                    l10n.chatDataControlsUnsent(
                      scope.unsyncedEdits + scope.queuedResponses,
                    ),
                  ),
                const SizedBox(height: Spacing.xs),
                Text(
                  l10n.chatDataControlsUnsyncedNote,
                  style: AppTypography.bodySmallStyle.copyWith(
                    color: theme.textSecondary,
                  ),
                ),
                const SizedBox(height: Spacing.sm),
                ConduitButton(
                  key: const Key('chat-data-sync'),
                  text: _activity == _Activity.syncing
                      ? l10n.chatDataControlsSyncing
                      : l10n.chatDataControlsSyncNow,
                  isSecondary: true,
                  isLoading: _activity == _Activity.syncing,
                  onPressed: _busy ? null : _syncNow,
                ),
              ],
            ),
          ),
        ],
        if (canExport || canImport) ...[
          const SizedBox(height: Spacing.lg),
          InsetGroupedList(
            title: l10n.chatDataControlsBackupSection,
            children: [
              if (canExport)
                UtilityRow(
                  key: const Key('chat-data-export'),
                  title: l10n.chatDataControlsExportLibrary,
                  leading: Icon(
                    UiUtils.platformIcon(
                      ios: CupertinoIcons.square_arrow_up,
                      android: Icons.ios_share,
                    ),
                  ),
                  enabled: !_busy,
                  onTap: _exportLibrary,
                ),
              if (canImport)
                UtilityRow(
                  key: const Key('chat-data-import'),
                  title: l10n.chatDataControlsImport,
                  leading: Icon(
                    UiUtils.platformIcon(
                      ios: CupertinoIcons.square_arrow_down,
                      android: Icons.file_download_outlined,
                    ),
                  ),
                  enabled: !_busy,
                  onTap: _chooseImportFile,
                ),
            ],
          ),
        ],
        if (_picked != null && _importError != null) ...[
          const SizedBox(height: Spacing.sm),
          InsetGroupedSection(
            key: const Key('chat-data-import-error'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.chatDataControlsImportFile(_picked!.name)),
                const SizedBox(height: Spacing.xs),
                Text(
                  _importError!,
                  style: AppTypography.bodyMediumStyle.copyWith(
                    color: theme.error,
                  ),
                ),
                const SizedBox(height: Spacing.sm),
                ConduitButton(
                  key: const Key('chat-data-choose-another'),
                  text: l10n.chatDataControlsImportChooseAnother,
                  isSecondary: true,
                  onPressed: _busy ? null : _chooseImportFile,
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: Spacing.lg),
        InsetGroupedList(
          title: l10n.chatDataControlsManageSection,
          children: [
            UtilityRow(
              key: const Key('chat-data-archive-all'),
              title: l10n.chatDataControlsArchiveAll,
              enabled: !_busy,
              onTap: () => _change(_Bulk.archive),
            ),
            UtilityRow(
              key: const Key('chat-data-unarchive-all'),
              title: l10n.chatDataControlsUnarchiveAll,
              enabled: !_busy,
              onTap: () => _change(_Bulk.unarchive),
            ),
            UtilityRow(
              key: const Key('chat-data-unshare-all'),
              title: l10n.chatDataControlsUnshareAll,
              enabled: !_busy,
              onTap: () => _change(_Bulk.unshare),
            ),
            if (canDelete)
              UtilityRow(
                key: const Key('chat-data-delete-all'),
                title: l10n.chatDataControlsDeleteAll,
                destructive: true,
                enabled: !_busy,
                onTap: () => _change(_Bulk.delete),
              ),
          ],
        ),
        if (_activity == _Activity.exporting) ...[
          const SizedBox(height: Spacing.md),
          Row(
            key: const Key('chat-data-progress'),
            children: [
              const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator.adaptive(strokeWidth: 2),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(child: Text(l10n.chatDataControlsExporting(_chatsRead))),
              TextButton(
                key: const Key('chat-data-cancel-export'),
                onPressed: () => _cancel?.cancel(),
                child: Text(l10n.cancel),
              ),
            ],
          ),
        ] else if (_activity == _Activity.changing ||
            _activity == _Activity.importing) ...[
          const SizedBox(height: Spacing.md),
          Row(
            key: const Key('chat-data-progress'),
            children: [
              const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator.adaptive(strokeWidth: 2),
              ),
              const SizedBox(width: Spacing.sm),
              if (_activity == _Activity.changing)
                Expanded(child: Text(l10n.chatDataControlsWaiting)),
            ],
          ),
        ],
        if (_status != null) ...[
          const SizedBox(height: Spacing.md),
          Text(
            _status!,
            key: const Key('chat-data-status'),
            style: AppTypography.bodyMediumStyle.copyWith(
              color: _statusIsError ? theme.error : theme.textPrimary,
            ),
          ),
        ],
      ],
    );
  }
}

/// Counts the envelopes a library backup writes, for the progress line. The
/// last two writes of a backup close the array and are not chats.
final class _CountingSink implements ChatBackupSink {
  _CountingSink(this._inner, this._onCount);

  final ChatBackupSink _inner;
  final void Function(int count) _onCount;
  var _count = 0;

  @override
  Future<void> write(String text) {
    if (!text.startsWith('\n]') && !text.startsWith('[]')) {
      _onCount(++_count);
    }
    return _inner.write(text);
  }

  @override
  Future<void> commit() => _inner.commit();

  @override
  Future<void> abort() => _inner.abort();
}
