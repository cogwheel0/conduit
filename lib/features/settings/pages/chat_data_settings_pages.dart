import 'dart:async';
import 'dart:ui' show Offset, PlatformDispatcher, Rect;

import 'package:conduit/core/utils/account_display.dart';
import 'package:conduit/features/chat/services/chat_backup_files.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/database/daos/chats_dao.dart'
    show ServerChatBulkScope;
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/services/chat_backup.dart';
import 'package:conduit_core/features/chat/services/chat_data_controls.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:dio/dio.dart' show CancelToken, DioException;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../settings_page_module.dart';
import '../settings_pages.dart';

/// Id of the Chat Data Controls page, which the root's row opens.
const chatDataControlsPageId = NativeSheetRoutes.chatDataControls;

/// A row of the page: `chat-data.<action>`.
String chatDataRowId(String action) => 'chat-data.$action';

/// What the page is doing. [preparing] covers choosing, counting and
/// confirming: nothing runs yet, but no second action may start.
enum ChatDataActivity { idle, syncing, preparing, exporting, importing, changing }

/// The row an action started from: its progress shows in that row, and its
/// result under the group that holds it.
enum ChatDataOrigin { sync, export, import, archive, unarchive, unshare, delete }

enum _Bulk { archive, unarchive, unshare, delete }

/// What the page shows, as its module holds it.
@immutable
class ChatDataPageState {
  const ChatDataPageState({
    this.advanced = true,
    this.accountName,
    this.serverName,
    this.accountChanged = false,
    this.canExport = false,
    this.canImport = false,
    this.canDelete = false,
    this.localOnly = 0,
    this.unsent = 0,
    this.activity = ChatDataActivity.idle,
    this.origin,
    this.chatsRead = 0,
    this.importing = 0,
    this.pickedName,
    this.importError,
    this.status,
    this.statusIsError = false,
  });

  /// Advanced is on: the page belongs to it.
  final bool advanced;

  /// The account the page acts on, and its server; null with none.
  final String? accountName;
  final String? serverName;

  /// Another account signed in since the page opened: the page acts on none.
  final bool accountChanged;
  final bool canExport;
  final bool canImport;
  final bool canDelete;

  /// Chats only on this device, and chats with work the server lacks.
  final int localOnly;
  final int unsent;
  final ChatDataActivity activity;
  final ChatDataOrigin? origin;
  final int chatsRead;
  final int importing;

  /// The file chosen to import, and why it was refused.
  final String? pickedName;
  final String? importError;

  /// The latest result, said under the group of [origin].
  final String? status;
  final bool statusIsError;

  bool get busy => activity != ChatDataActivity.idle;
}

/// The Chat Data Controls page: the account it acts on; chats this device
/// has not sent yet, with Sync Now; backing up and restoring the library;
/// and changing every chat at once.
///
/// While an action runs, its row turns and says how far it got, and every
/// other row waits, dimmed. Its result shows under the group of the row it
/// started from, and is read out.
@visibleForTesting
NativeSheetDetailConfig buildChatDataPage(
  AppLocalizations l10n,
  ChatDataPageState state,
) {
  NativeSheetItemConfig note(String id, String title, String symbol) =>
      NativeSheetItemConfig(
        id: id,
        title: title,
        sfSymbol: symbol,
        kind: NativeSheetItemKind.info,
      );
  if (!state.advanced) {
    return NativeSheetDetailConfig(
      id: chatDataControlsPageId,
      title: l10n.chatDataControlsTitle,
      items: [
        note(
          '$chatDataControlsPageId-advanced',
          l10n.advancedRequiredMessage(l10n.chatDataControlsTitle),
          'slider.horizontal.3',
        ),
      ],
    );
  }
  final accountName = state.accountName;
  final serverName = state.serverName;
  if (accountName == null || serverName == null || state.accountChanged) {
    return NativeSheetDetailConfig(
      id: chatDataControlsPageId,
      title: l10n.chatDataControlsTitle,
      items: [
        note(
          '$chatDataControlsPageId-account',
          state.accountChanged
              ? l10n.chatDataControlsAccountChanged
              : l10n.chatDataControlsNoAccount,
          'person.crop.circle',
        ),
      ],
    );
  }

  bool running(ChatDataOrigin origin) =>
      state.origin == origin &&
      (state.activity == ChatDataActivity.syncing ||
          state.activity == ChatDataActivity.exporting ||
          state.activity == ChatDataActivity.importing ||
          state.activity == ChatDataActivity.changing);
  NativeSheetItemConfig action(
    ChatDataOrigin origin, {
    required String id,
    required String title,
    required String symbol,
    String? progress,
    bool destructive = false,
    bool accent = false,
  }) {
    final runs = running(origin);
    return NativeSheetItemConfig(
      id: chatDataRowId(id),
      title: title,
      subtitle:
          progress ??
          (runs && state.activity == ChatDataActivity.changing
              ? l10n.chatDataControlsWaiting
              : null),
      sfSymbol: symbol,
      destructive: destructive,
      accent: accent,
      showsDisclosure: false,
      pending: runs,
      // While one action runs the others wait; its own row stays bright.
      disabled: state.busy && state.origin != origin,
    );
  }

  String? statusFor(Set<ChatDataOrigin> origins) =>
      state.status != null && origins.contains(state.origin)
      ? state.status
      : null;
  // A result is said under its group; a failure shows in it instead, as a
  // row with a warning sign, as an import's error does.
  String? said(String? status) => state.statusIsError ? null : status;
  NativeSheetItemConfig? failure(String group, String? status) =>
      status != null && state.statusIsError
      ? note(
          '$chatDataControlsPageId-$group-failure',
          status,
          'exclamationmark.triangle',
        )
      : null;
  String? footer(Iterable<String?> parts) {
    final shown = parts.nonNulls.where((part) => part.isNotEmpty).toList();
    return shown.isEmpty ? null : shown.join('\n\n');
  }

  final backupStatus = statusFor(const {
    ChatDataOrigin.export,
    ChatDataOrigin.import,
  });
  final manageStatus = statusFor(const {
    ChatDataOrigin.archive,
    ChatDataOrigin.unarchive,
    ChatDataOrigin.unshare,
  });
  final deleteStatus = statusFor(const {ChatDataOrigin.delete});
  final syncStatus = statusFor(const {ChatDataOrigin.sync});

  return NativeSheetDetailConfig(
    id: chatDataControlsPageId,
    title: l10n.chatDataControlsTitle,
    announcement: state.status,
    sections: [
      NativeSheetSectionConfig(
        items: [
          note(
            '$chatDataControlsPageId-account',
            l10n.chatDataControlsStoredOn(accountName, serverName),
            'person.crop.circle',
          ),
        ],
      ),
      if (state.localOnly > 0 || state.unsent > 0)
        NativeSheetSectionConfig(
          footer: footer([l10n.chatDataControlsUnsyncedNote, said(syncStatus)]),
          items: [
            if (state.localOnly > 0)
              note(
                '$chatDataControlsPageId-local-only',
                l10n.chatDataControlsLocalOnly(state.localOnly),
                'iphone',
              ),
            if (state.unsent > 0)
              note(
                '$chatDataControlsPageId-unsent',
                l10n.chatDataControlsUnsent(state.unsent),
                'arrow.up.circle',
              ),
            action(
              ChatDataOrigin.sync,
              id: 'sync',
              title: state.activity == ChatDataActivity.syncing
                  ? l10n.chatDataControlsSyncing
                  : l10n.chatDataControlsSyncNow,
              symbol: 'arrow.triangle.2.circlepath',
              accent: true,
            ),
            ?failure('sync', syncStatus),
          ],
        ),
      if (state.canExport || state.canImport)
        NativeSheetSectionConfig(
          title: l10n.chatDataControlsBackupSection,
          footer: footer([
            if (state.canExport) l10n.chatDataControlsMediaNote,
            if (state.canImport) l10n.chatDataControlsImportFooter,
            said(backupStatus),
          ]),
          items: [
            if (state.canExport)
              action(
                ChatDataOrigin.export,
                id: 'export',
                title: l10n.chatDataControlsExportLibrary,
                symbol: 'square.and.arrow.up',
                progress: state.activity == ChatDataActivity.exporting
                    ? l10n.chatDataControlsExporting(state.chatsRead)
                    : null,
              ),
            if (state.activity == ChatDataActivity.exporting)
              NativeSheetItemConfig(
                id: chatDataRowId('cancel-export'),
                title: l10n.cancel,
                sfSymbol: 'xmark.circle',
                showsDisclosure: false,
              ),
            if (state.canImport)
              action(
                ChatDataOrigin.import,
                id: 'import',
                title: l10n.chatDataControlsImport,
                symbol: 'square.and.arrow.down',
                progress: state.activity == ChatDataActivity.importing
                    ? l10n.chatDataControlsImporting(state.importing)
                    : null,
              ),
            ?failure('backup', backupStatus),
          ],
        ),
      if (state.pickedName != null && state.importError != null)
        NativeSheetSectionConfig(
          items: [
            note(
              '$chatDataControlsPageId-import-file',
              l10n.chatDataControlsImportFile(state.pickedName!),
              'doc',
            ),
            note(
              '$chatDataControlsPageId-import-error',
              state.importError!,
              'exclamationmark.triangle',
            ),
            NativeSheetItemConfig(
              id: chatDataRowId('choose-another'),
              title: l10n.chatDataControlsImportChooseAnother,
              sfSymbol: 'doc.badge.plus',
              accent: true,
              showsDisclosure: false,
              disabled: state.busy,
            ),
          ],
        ),
      NativeSheetSectionConfig(
        title: l10n.chatDataControlsManageSection,
        footer: said(manageStatus),
        items: [
          action(
            ChatDataOrigin.archive,
            id: 'archive',
            title: l10n.chatDataControlsArchiveAll,
            symbol: 'archivebox',
          ),
          action(
            ChatDataOrigin.unarchive,
            id: 'unarchive',
            title: l10n.chatDataControlsUnarchiveAll,
            symbol: 'tray.and.arrow.up',
          ),
          action(
            ChatDataOrigin.unshare,
            id: 'unshare',
            title: l10n.chatDataControlsUnshareAll,
            symbol: 'link',
          ),
          ?failure('manage', manageStatus),
        ],
      ),
      if (state.canDelete)
        NativeSheetSectionConfig(
          footer: footer([
            l10n.chatDataControlsDeleteFooter(accountName, serverName),
            said(deleteStatus),
          ]),
          items: [
            action(
              ChatDataOrigin.delete,
              id: 'delete',
              title: l10n.chatDataControlsDeleteAll,
              symbol: 'trash',
              destructive: true,
            ),
            ?failure('delete', deleteStatus),
          ],
        ),
    ],
  );
}

/// Backs up and restores the signed-in Open WebUI account's chats, and
/// changes every one of them at once, for the Chat Data Controls page.
///
/// The page acts on the account signed in as it opens: another signing in
/// does not retarget it, and what still runs for the first is dropped. A
/// backup still being written stops once its page is gone.
class ChatDataSettingsPages extends SettingsPageModule {
  ChatDataSettingsPages(this._ref);

  final Ref _ref;
  ChatDataControlsOwner? _owner;
  ServerChatBulkScope? _scope;
  ChatDataActivity _activity = ChatDataActivity.idle;
  ChatDataOrigin? _origin;
  int _chatsRead = 0;
  int _importing = 0;
  CancelToken? _cancel;
  PickedChatFile? _picked;
  String? _importError;
  String? _status;
  bool _statusIsError = false;
  AppLocalizations? _l10n;

  /// The progress patch waiting to go out; at most a few a second.
  Timer? _progressTick;

  ProviderContainer get _container => _ref.container;
  SettingsSurface get _surface => _ref.read(settingsSurfaceProvider);
  bool get _busy => _activity != ChatDataActivity.idle || _importSending;

  /// Whether an import is with the server. It outlives its visit: a page
  /// opened again waits for it rather than send the same chats twice.
  bool _importSending = false;

  @override
  bool ownsPage(String detailId) => detailId == chatDataControlsPageId;

  @override
  Future<void> hydrate(String detailId, AppLocalizations l10n) async {
    _l10n = l10n;
    // The page acts on the account signed in as it opened. Described again
    // while open -- as it is once another account signs in -- it keeps that
    // account, and says it changed; opened anew, it starts from the one
    // signed in now.
    if (_owner == null) {
      _owner = captureChatDataControlsOwner(_container);
      if (!_busy) {
        _picked = null;
        _importError = null;
        _status = null;
        _origin = null;
        _scope = null;
      }
    }
    await _apply();
    await _refreshScope();
  }

  @override
  void pageLeft(String detailId) => _stop();

  @override
  void settingsClosed() => _stop();

  /// A backup nobody is waiting for any more must not keep running, and
  /// the page opened next acts on the account signed in then.
  void _stop() {
    _cancel?.cancel();
    _cancel = null;
    _progressTick?.cancel();
    _progressTick = null;
    _owner = null;
    // The next visit starts clear: no action shown running, no counts or
    // results from this one. An action still finishing changes nothing on
    // it (see [_openFor]).
    _activity = ChatDataActivity.idle;
    _origin = null;
    _scope = null;
    _status = null;
    _statusIsError = false;
    _picked = null;
    _importError = null;
    _chatsRead = 0;
    _importing = 0;
  }

  ChatDataControlsService _service(ChatDataControlsOwner owner) =>
      chatDataControlsServiceForOwner(_container, owner);

  /// Whether the page that started an action for [owner] is still open.
  /// Left, or closed with Settings, the page lets go of its owner; opened
  /// again, it holds a new one. Either way nothing is asked or done for it
  /// any more.
  bool _openFor(ChatDataControlsOwner owner) => identical(_owner, owner);

  /// Whether Advanced is on, which these controls need: a row left from
  /// before it was turned off does nothing.
  bool get _advanced => _ref.read(appSettingsProvider).advancedFeaturesEnabled;

  bool _ownerIsCurrent() {
    final owner = _owner;
    return owner != null && chatDataControlsOwnerIsCurrent(_container, owner);
  }

  bool _allowed(String action) =>
      _ref.read(openWebUiChatActionAllowedProvider(action)).asData?.value ??
      false;

  /// The page as it stands.
  @visibleForTesting
  ChatDataPageState get state {
    final owner = _owner;
    return ChatDataPageState(
      advanced: _ref.read(appSettingsProvider).advancedFeaturesEnabled,
      accountName: owner?.accountName,
      serverName: owner == null
          ? null
          : configServerDisplayName(
              owner.api.serverConfig,
              _ref.read(openWebUiAccountsProvider).value,
            ),
      accountChanged: owner != null && !_ownerIsCurrent(),
      canExport: _allowed('export'),
      canImport: _allowed('import'),
      canDelete: _allowed('delete'),
      localOnly: _scope?.localOnlyChatIds.length ?? 0,
      unsent: _scope?.chatsWithUnsentWork ?? 0,
      // An import from an earlier visit still with the server shows as
      // running here, so the rows read as waiting rather than doing nothing.
      activity: _importSending && _activity == ChatDataActivity.idle
          ? ChatDataActivity.importing
          : _activity,
      origin: _importSending && _activity == ChatDataActivity.idle
          ? ChatDataOrigin.import
          : _origin,
      chatsRead: _chatsRead,
      importing: _importing,
      pickedName: _picked?.name,
      importError: _importError,
      status: _status,
      statusIsError: _statusIsError,
    );
  }

  Future<void> _apply() async {
    final l10n = _l10n;
    if (l10n == null) return;
    // The actions' permissions read on first use, all at once, so one slow
    // read holds the page no longer than its own wait; listened to
    // meanwhile.
    const actions = ['export', 'import', 'delete'];
    final listening = [
      for (final action in actions)
        _ref.listen(openWebUiChatActionAllowedProvider(action), (_, _) {}),
    ];
    try {
      await Future.wait([
        for (final action in actions)
          _ref
              .read(openWebUiChatActionAllowedProvider(action).future)
              .timeout(const Duration(seconds: 5))
              .then<Object?>((value) => value, onError: (_) => null),
      ]);
    } finally {
      for (final subscription in listening) {
        subscription.close();
      }
    }
    await _surface.applyDetail(buildChatDataPage(l10n, state));
  }

  Future<void> _refreshScope() async {
    final owner = _owner;
    if (owner == null || !_ownerIsCurrent()) return;
    try {
      final scope = await _service(owner).scope();
      // Counted for a visit since closed: the open one counts its own.
      if (!_openFor(owner)) return;
      _scope = scope;
      await _apply();
    } catch (_) {
      // The counts are a disclosure; the actions read them again themselves.
    }
  }

  /// Shows [message] as the outcome of an action for [owner], when the page
  /// it ran from is still open.
  void _showFor(
    ChatDataControlsOwner owner,
    String message, {
    bool error = false,
  }) {
    if (_openFor(owner)) _show(message, error: error);
  }

  /// An action for [owner] is over: its page, when still open, shows it so.
  Future<void> _settle(ChatDataControlsOwner owner) async {
    if (!_openFor(owner)) return;
    _activity = ChatDataActivity.idle;
    await _apply();
  }

  void _show(String message, {bool error = false}) {
    _status = message;
    _statusIsError = error;
  }

  /// A progress line, sent at most a few times a second.
  void _progress() {
    if (_progressTick?.isActive ?? false) return;
    _progressTick = Timer(const Duration(milliseconds: 250), () {
      unawaited(_apply());
    });
  }

  /// Where an iPad anchors the share sheet: the middle of the window, as
  /// the row that asked for it has no place Dart knows.
  Rect? _shareOrigin() {
    final view = PlatformDispatcher.instance.views.firstOrNull;
    if (view == null) return null;
    final size = view.physicalSize / view.devicePixelRatio;
    return Rect.fromCenter(
      center: size.center(Offset.zero),
      width: 1,
      height: 1,
    );
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

  String _serverName(ChatDataControlsOwner owner) => configServerDisplayName(
    owner.api.serverConfig,
    _ref.read(openWebUiAccountsProvider).value,
  );

  /// Asks [title] over Settings; true when [confirm] was chosen.
  Future<bool> _confirm(
    AppLocalizations l10n, {
    required String title,
    required String message,
    required String confirm,
    bool destructive = false,
  }) async =>
      await _surface.ask(
        title: title,
        message: message,
        actions: [
          NativeSheetAlertAction(
            'cancel',
            l10n.cancel,
            style: NativeSheetAlertStyle.cancel,
          ),
          NativeSheetAlertAction(
            'go',
            confirm,
            style: destructive
                ? NativeSheetAlertStyle.destructive
                : NativeSheetAlertStyle.normal,
          ),
        ],
      ) ==
      'go';

  @override
  Future<bool> handleChange(
    String id,
    Object? value,
    AppLocalizations l10n,
  ) async {
    if (!id.startsWith('chat-data.')) return false;
    _l10n = l10n;
    final owner = _owner;
    switch (id.substring('chat-data.'.length)) {
      case 'cancel-export':
        _cancel?.cancel();
        return true;
      case _ when owner == null || _busy || !_ownerIsCurrent() || !_advanced:
        // A row of a page another account took over, or a second tap while
        // one runs, does nothing.
        return true;
      case 'export' when !_allowed('export'):
      case 'import' || 'choose-another' when !_allowed('import'):
      case 'delete' when !_allowed('delete'):
        // A row left from before the account lost the right to it: the
        // page is drawn again without it. (The server checks as well.)
        await _apply();
        return true;
      case 'sync':
        await _sync(owner);
      case 'export':
        await _export(l10n, owner);
      case 'import' || 'choose-another':
        await _import(l10n, owner);
      case 'archive':
        await _change(l10n, owner, _Bulk.archive);
      case 'unarchive':
        await _change(l10n, owner, _Bulk.unarchive);
      case 'unshare':
        await _change(l10n, owner, _Bulk.unshare);
      case 'delete':
        await _change(l10n, owner, _Bulk.delete);
    }
    return true;
  }

  Future<void> _sync(ChatDataControlsOwner owner) async {
    _activity = ChatDataActivity.syncing;
    _origin = ChatDataOrigin.sync;
    _status = null;
    await _apply();
    try {
      await syncChatDataControlsOwner(_container, owner);
    } catch (_) {
      // Whatever could not be sent stays counted on the page.
    }
    if (!_openFor(owner)) return;
    _activity = ChatDataActivity.idle;
    await _apply();
    await _refreshScope();
  }

  Future<void> _export(
    AppLocalizations l10n,
    ChatDataControlsOwner owner,
  ) async {
    final files = _ref.read(chatBackupFilesProvider);
    final service = _service(owner);
    // Bound to this run before anything waits, so closing the page at any
    // point stops it.
    final cancel = _cancel = CancelToken();
    _activity = ChatDataActivity.preparing;
    _origin = ChatDataOrigin.export;
    _chatsRead = 0;
    _status = null;
    await _apply();
    ChatBackupFile? file;
    var delivered = false;
    try {
      final scope = await service.scope();
      if (!_openFor(owner)) return;
      final leavesOut =
          scope.localOnlyChatIds.isNotEmpty ||
          scope.unsyncedEdits > 0 ||
          scope.queuedResponses > 0;
      if (leavesOut &&
          !await _confirm(
            l10n,
            title: l10n.chatDataControlsExportConfirmTitle,
            message:
                '${l10n.chatDataControlsExportConfirmMessage(owner.accountName, _serverName(owner))}'
                '\n\n${l10n.chatDataControlsUnsyncedNote}',
            confirm: l10n.chatDataControlsExportAction,
          )) {
        return;
      }
      if (!_openFor(owner) || cancel.isCancelled || !_advanced) return;
      _activity = ChatDataActivity.exporting;
      await _apply();
      // Closed, or Advanced turned off, while the page was drawn busy.
      if (!_openFor(owner) || cancel.isCancelled || !_advanced) return;
      file = await files.create(libraryBackupFileName(DateTime.now()));
      final result = await service.exportLibrary(
        _CountingSink(file, (count) {
          _chatsRead = count;
          _progress();
        }),
        cancelToken: cancel,
      );
      if (result.chats == 0) {
        await file.abort();
        _showFor(owner, l10n.chatDataControlsExportEmpty);
      } else {
        // Left as the last chats arrived: nobody is there to share it with,
        // and the file is thrown away.
        if (!_openFor(owner)) return;
        // Handed over only now, every line having arrived intact; the share
        // sheet opens over Settings.
        await files.deliver(file, origin: _shareOrigin());
        delivered = true;
        _showFor(owner, l10n.chatDataControlsExportReady(result.chats));
      }
    } on ChatBackupException catch (error) {
      _showFor(owner, switch (error.failure) {
        ChatBackupFailure.cancelled => l10n.chatDataControlsExportStopped,
        ChatBackupFailure.ownerChanged => l10n.chatDataControlsOwnerChanged,
        _ => l10n.chatDataControlsExportFailed,
      }, error: error.failure != ChatBackupFailure.cancelled);
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      _showFor(
        owner,
        status == 401 || status == 403
            ? l10n.chatDataControlsForbidden
            : l10n.chatDataControlsExportFailed,
        error: true,
      );
    } catch (_) {
      _showFor(owner, l10n.chatDataControlsExportFailed, error: true);
    } finally {
      if (identical(_cancel, cancel)) _cancel = null;
      if (_openFor(owner)) _progressTick?.cancel();
      // A file never handed over must not be left behind; one that was is
      // the share sheet's to read, and the next backup clears it.
      final staged = file;
      if (staged != null && !delivered) await staged.abort();
      await _settle(owner);
    }
  }

  Future<void> _import(
    AppLocalizations l10n,
    ChatDataControlsOwner owner,
  ) async {
    final files = _ref.read(chatBackupFilesProvider);
    // Over the Settings sheet, as a picker opened from one of its rows.
    final picked = await files.pickImportFile();
    if (picked == null || !_openFor(owner)) return;
    _picked = picked;
    _importError = null;
    _status = null;
    _activity = ChatDataActivity.preparing;
    _origin = ChatDataOrigin.import;
    await _apply();

    ChatImportPreview preview;
    try {
      // Refused before it is read, so a file past the limit never has to
      // fit in memory.
      final size = await picked.length();
      if (size != null && size > kMaxChatImportBytes) {
        throw const ChatBackupException(ChatBackupFailure.fileTooLarge);
      }
      preview = await prepareChatImportFile(_container, await picked.read());
    } on ChatBackupException catch (error) {
      if (!_openFor(owner)) return;
      // The choice stays on the page, so the user sees which file it was.
      _importError = switch (error.failure) {
        ChatBackupFailure.emptyImport => l10n.chatDataControlsImportEmpty,
        ChatBackupFailure.fileTooLarge => l10n.chatDataControlsImportTooLarge,
        ChatBackupFailure.invalidField || ChatBackupFailure.unrecognizedChat
            when error.index != null =>
          l10n.chatDataControlsImportBadEntry(error.index! + 1),
        _ => l10n.chatDataControlsImportInvalid,
      };
      await _settle(owner);
      return;
    } catch (_) {
      if (!_openFor(owner)) return;
      _importError = l10n.chatDataControlsImportInvalid;
      await _settle(owner);
      return;
    }

    if (!_openFor(owner) ||
        !await _confirm(
          l10n,
          title: l10n.chatDataControlsImportConfirmTitle,
          message: l10n.chatDataControlsImportConfirmMessage(
            owner.accountName,
            _serverName(owner),
            preview.chats,
            preview.messages,
          ),
          confirm: l10n.chatDataControlsImportAction,
        ) ||
        !_openFor(owner) ||
        !_advanced) {
      await _settle(owner);
      return;
    }

    _activity = ChatDataActivity.importing;
    _importing = preview.chats;
    await _apply();
    // Closed, or Advanced turned off, while the page was drawn busy.
    if (!_openFor(owner) || !_advanced) {
      await _settle(owner);
      return;
    }
    _importSending = true;
    try {
      final result = await _service(owner).importChats(preview);
      // The chats are on the server whether or not the page is still up;
      // the app's list follows them for the account they went to.
      if (chatDataControlsOwnerIsCurrent(_container, owner)) {
        refreshConversationsCache(_container);
      }
      if (!_openFor(owner)) return;
      _showFor(
        owner,
        result.stored < result.imported
            ? '${l10n.chatDataControlsImported(result.imported)} '
                  '${l10n.chatDataControlsImportedSyncNote}'
            : l10n.chatDataControlsImported(result.imported),
      );
      _picked = null;
    } catch (error) {
      // Sent again, an import duplicates every chat, so when no answer came
      // the user is told it may have happened rather than that it is safe
      // to repeat.
      _showFor(
        owner,
        error is ChatDataControlsException &&
                error.failure == ChatDataControlsFailure.outcomeUnknown
            ? l10n.chatDataControlsImportUnknown
            : _failureText(l10n, error),
        error: true,
      );
    } finally {
      _importSending = false;
      // A page opened again meanwhile can import once more.
      if (!_openFor(owner) && _owner != null) unawaited(_apply());
      await _settle(owner);
      unawaited(_refreshScope());
    }
  }

  Future<void> _change(
    AppLocalizations l10n,
    ChatDataControlsOwner owner,
    _Bulk kind,
  ) async {
    final service = _service(owner);
    _activity = ChatDataActivity.preparing;
    _origin = switch (kind) {
      _Bulk.archive => ChatDataOrigin.archive,
      _Bulk.unarchive => ChatDataOrigin.unarchive,
      _Bulk.unshare => ChatDataOrigin.unshare,
      _Bulk.delete => ChatDataOrigin.delete,
    };
    _status = null;
    await _apply();
    try {
      final scope = await service.scope();
      if (!_openFor(owner)) return;
      var discard = false;
      if (kind == _Bulk.delete &&
          (scope.runningResponses > 0 || _ref.read(isChatStreamingProvider))) {
        _showFor(owner, l10n.chatDataControlsResponseRunning, error: true);
        return;
      }
      if (kind == _Bulk.delete) discard = scope.hasWorkTheServerLacks;

      // Each answer names what it does; only deleting is destructive, as
      // removed share links and archived chats can be brought back.
      final proceed = await _confirm(
        l10n,
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
            '${l10n.chatDataControlsDeleteAllMessage(owner.accountName, _serverName(owner))}'
                '${discard ? '\n\n${l10n.chatDataControlsDeleteUnsentMessage(scope.unsyncedEdits, scope.queuedResponses)}' : ''}',
        },
        confirm: switch (kind) {
          _Bulk.archive => l10n.chatDataControlsArchiveAllConfirm,
          _Bulk.unarchive => l10n.chatDataControlsUnarchiveAllConfirm,
          _Bulk.unshare => l10n.chatDataControlsUnshareAllConfirm,
          _Bulk.delete =>
            discard
                ? l10n.chatDataControlsDiscardAndDeleteConfirm
                : l10n.chatDataControlsDeleteAllConfirm,
        },
        destructive: kind == _Bulk.delete,
      );
      if (!proceed || !_openFor(owner) || !_advanced) return;

      _activity = ChatDataActivity.changing;
      await _apply();
      // Closed, or Advanced turned off, while the page was drawn busy.
      if (!_openFor(owner) || !_advanced) return;
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
      // The stored chats are changed already; the app follows them.
      applyChatBulkOutcome(_container, owner, change, outcome);
      // It reaches every chat on the server, so the result names no count:
      // the outcome counts only the chats this device had.
      _showFor(owner, switch (kind) {
        _Bulk.archive => l10n.chatDataControlsArchivedAll,
        _Bulk.unarchive => l10n.chatDataControlsUnarchivedAll,
        _Bulk.unshare => l10n.chatDataControlsUnsharedAll,
        _Bulk.delete => l10n.chatDataControlsDeletedAll,
      });
    } catch (error) {
      _showFor(owner, _failureText(l10n, error), error: true);
    } finally {
      await _settle(owner);
      unawaited(_refreshScope());
    }
  }
}

/// Counts the chats a library backup writes, for the progress line. The
/// last writes of a backup close the array and are not chats.
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
