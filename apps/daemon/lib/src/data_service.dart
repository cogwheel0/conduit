import 'dart:async';
import 'dart:io';

import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/chat/services/chat_backup.dart';
import 'package:conduit_core/features/chat/services/chat_data_controls.dart';
import 'package:conduit_core/models/socket_health.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/socket_service.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

import 'event_bus.dart';
import 'settled.dart';

/// `data.*`: Chat Data Controls over core's `ChatDataControlsService` (the
/// whole library's export and import, and the account-wide archive,
/// unarchive, unshare and delete), and the realtime socket's health for
/// Settings › Data & Connection.
///
/// Each action captures the signed-in account when it starts, as the phone's
/// page does when it opens, and core refuses to apply an answer once that
/// account is no longer the one signed in.
final class DataService {
  DataService(this._container, {EventBus? events}) : _events = events {
    if (events != null) {
      _container.listen<SocketService?>(
        socketServiceProvider,
        (_, next) => _follow(next),
        fireImmediately: true,
      );
    }
  }

  final ProviderContainer _container;
  final EventBus? _events;
  StreamSubscription<SocketHealth>? _health;

  /// The chats only on this computer that each window's last summary
  /// counted, with the account it counted them for: a delete all refuses to
  /// go ahead if one of them reached the server since (core's
  /// `localWorkChanged`), as the phone's page holds them, and when the
  /// window's summary was another account's or it was shown none, since
  /// what it confirmed is not this account's.
  final Expando<_Shown> _shown = Expando<_Shown>('data.summary');

  /// The key for a caller that names no window (one window, or a test).
  static final Object _anyCaller = Object();

  void _follow(SocketService? service) {
    unawaited(_health?.cancel());
    _health = null;
    _events?.emit(ConduitEventSpecs.socketHealth, null);
    if (service == null) return;
    _health = service.healthStream.listen(
      (_) => _events?.emit(ConduitEventSpecs.socketHealth, null),
    );
  }

  Future<void> dispose() async => _health?.cancel();

  ChatDataControlsOwner? _owner() => captureChatDataControlsOwner(_container);

  ChatDataControlsOwner _requireOwner() =>
      _owner() ??
      (throw const RpcError(
        code: ConduitErrorCodes.unauthenticated,
        debugMessage: 'no Open WebUI account is in use',
      ));

  Future<bool> _allowed(String action) async {
    try {
      return await readSettled(
        _container,
        openWebUiChatActionAllowedProvider(action).future,
      );
    } on Object {
      return false;
    }
  }

  Future<ChatDataSummary> summary({Object? caller}) async {
    final owner = _owner();
    if (owner == null) return const ChatDataSummary();
    final scope = await chatDataControlsServiceForOwner(
      _container,
      owner,
    ).scope();
    _shown[caller ?? _anyCaller] = (
      owner: owner,
      localOnly: scope.localOnlyChatIds.toSet(),
    );
    return ChatDataSummary(
      available: true,
      serverChats: scope.serverChats,
      localOnly: scope.localOnlyChatIds.length,
      unsent: scope.chatsWithUnsentWork,
      running: scope.runningResponses,
      canExport: await _allowed('export'),
      canImport: await _allowed('import'),
      canDelete: await _allowed('delete'),
    );
  }

  /// Sends what this computer holds for the account and pulls, then counts.
  Future<ChatDataSummary> sync({Object? caller}) async {
    await syncChatDataControlsOwner(_container, _requireOwner());
    return summary(caller: caller);
  }

  Future<DataActionResult> export(DataExportRequest request) async {
    final owner = _requireOwner();
    final sink = BackupFileSink(File(request.path));
    try {
      final result = await chatDataControlsServiceForOwner(
        _container,
        owner,
      ).exportLibrary(sink);
      // Core's last check passed after the sink committed: only now does the
      // file take the place of whatever was there.
      await sink.deliver();
      return DataActionResult(count: result.chats);
    } on ChatBackupException catch (error) {
      await sink.abort();
      return DataActionResult(failure: error.failure.name, index: error.index);
    } on ChatDataControlsException catch (error) {
      await sink.abort();
      return DataActionResult(failure: error.failure.name);
    } on Object {
      await sink.abort();
      return const DataActionResult(failure: 'failed');
    }
  }

  Future<ChatImportPreview> _prepare(DataImportRequest request) async {
    final file = File(request.path);
    if (!file.existsSync()) {
      throw const ChatBackupException(ChatBackupFailure.notJson);
    }
    if (file.lengthSync() > kMaxChatImportBytes) {
      throw const ChatBackupException(ChatBackupFailure.fileTooLarge);
    }
    return prepareChatImportFile(_container, await file.readAsBytes());
  }

  /// Reads and checks a backup and counts it, sending nothing (what the
  /// confirmation names).
  Future<DataActionResult> previewImport(DataImportRequest request) async {
    try {
      final preview = await _prepare(request);
      return DataActionResult(count: preview.chats, messages: preview.messages);
    } on ChatBackupException catch (error) {
      return DataActionResult(failure: error.failure.name, index: error.index);
    } on Object {
      // A file that cannot be read: as the import itself answers it.
      return const DataActionResult(failure: 'failed');
    }
  }

  Future<DataActionResult> import(DataImportRequest request) async {
    final owner = _requireOwner();
    try {
      final preview = await _prepare(request);
      final result = await chatDataControlsServiceForOwner(
        _container,
        owner,
      ).importChats(preview);
      if (chatDataControlsOwnerIsCurrent(_container, owner)) {
        refreshConversationsCache(_container);
      }
      return DataActionResult(
        count: result.imported,
        stored: result.stored,
        messages: preview.messages,
      );
    } on ChatBackupException catch (error) {
      return DataActionResult(failure: error.failure.name, index: error.index);
    } on ChatDataControlsException catch (error) {
      return DataActionResult(failure: error.failure.name);
    } on Object {
      return const DataActionResult(failure: 'failed');
    }
  }

  Future<DataActionResult> archiveAll() =>
      _bulk(ChatBulkChange.archive, (service) => service.archiveAll());

  Future<DataActionResult> unarchiveAll() =>
      _bulk(ChatBulkChange.unarchive, (service) => service.unarchiveAll());

  Future<DataActionResult> unshareAll() =>
      _bulk(ChatBulkChange.unshare, (service) => service.unshareAll());

  Future<DataActionResult> deleteAll(
    DataDeleteAll request, {
    Object? caller,
  }) async {
    final shown = _shown[caller ?? _anyCaller];
    if (shown == null ||
        !chatDataControlsOwnerIsCurrent(_container, shown.owner)) {
      return DataActionResult(
        failure: ChatDataControlsFailure.localWorkChanged.name,
      );
    }
    return _bulk(
      ChatBulkChange.delete,
      (service) => service.deleteAll(
        discardUnsyncedWork: request.discardUnsent,
        knownLocalOnlyChatIds: shown.localOnly,
      ),
    );
  }

  Future<DataActionResult> _bulk(
    ChatBulkChange change,
    Future<ChatBulkOutcome> Function(ChatDataControlsService service) run,
  ) async {
    final owner = _requireOwner();
    try {
      final outcome = await run(
        chatDataControlsServiceForOwner(_container, owner),
      );
      applyChatBulkOutcome(_container, owner, change, outcome);
      return DataActionResult(count: outcome.changed);
    } on ChatDataControlsException catch (error) {
      return DataActionResult(failure: error.failure.name);
    } on Object {
      return const DataActionResult(failure: 'failed');
    }
  }

  /// Live Updates › Retry: asks the realtime socket to connect now, as the
  /// phone's button does (core's `ensureConnected`, which the socket's own
  /// reconnect schedule keeps calling too), then answers its health. A
  /// failed try is not an error: the health says it is still down.
  Future<ConnectionHealth> reconnect() async {
    final service = _container.read(socketServiceProvider);
    if (service != null) {
      try {
        await service.ensureConnected(timeout: _reconnectWait);
      } on Object catch (_) {
        // The health below says how it went.
      }
    }
    return connection();
  }

  static const Duration _reconnectWait = Duration(seconds: 6);

  ConnectionHealth connection() {
    final service = _container.read(socketServiceProvider);
    final transports = _container.read(socketTransportOptionsProvider);
    if (service == null) {
      return ConnectionHealth(
        allowPolling: transports.allowPolling,
        allowWebsocket: transports.allowWebsocketOnly,
      );
    }
    final health = service.currentHealth;
    return ConnectionHealth(
      available: true,
      connected: health.isConnected,
      transport: switch (health.transport) {
        'websocket' || 'polling' => health.transport,
        _ => 'unknown',
      },
      latencyMs: health.hasLatencyInfo ? health.latencyMs : null,
      quality: health.quality,
      lastHeartbeatMs: health.lastHeartbeat?.millisecondsSinceEpoch,
      reconnects: health.reconnectCount,
      allowPolling: transports.allowPolling,
      allowWebsocket: transports.allowWebsocketOnly,
    );
  }
}

typedef _Shown = ({ChatDataControlsOwner owner, Set<String> localOnly});

/// A library backup written beside its destination and moved into place by
/// [deliver], once the export has passed every check, so a cut-off or
/// stopped export never leaves a file that looks complete, and never
/// replaces the one that was there.
final class BackupFileSink implements ChatBackupSink {
  BackupFileSink(this._target)
    : _partial = File('${_target.path}.partial-${pid}_${_seq++}');

  static int _seq = 0;
  final File _target;
  final File _partial;
  IOSink? _out;

  @override
  Future<void> write(String text) async {
    (_out ??= _partial.openWrite()).write(text);
  }

  /// Finishes writing. Core checks once more after this; the file is
  /// handed over only by [deliver].
  @override
  Future<void> commit() async {
    final out = _out ??= _partial.openWrite();
    await out.flush();
    await out.close();
    _out = null;
  }

  @override
  Future<void> abort() async {
    final out = _out;
    _out = null;
    if (out != null) {
      try {
        await out.close();
      } on Object {
        // Already closed.
      }
    }
    if (_partial.existsSync()) await _partial.delete();
  }

  /// Moves the committed backup into place.
  Future<void> deliver() async {
    await _partial.rename(_target.path);
  }
}
