import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/services/secure_credential_storage.dart';
import '../../core/utils/debug_logger.dart';
import 'chatgpt_runtime_client.dart';
import 'native_generated/api/contract.dart';
import 'native_generated/api/runtime.dart' as native;
import 'native_generated/frb_generated.dart';

final class SecureChatGptAuthSnapshotStore implements ChatGptAuthSnapshotStore {
  SecureChatGptAuthSnapshotStore(this._storage);

  final SecureCredentialStorage _storage;

  @override
  Future<void> delete() => _storage.deleteChatGptAccountSnapshot();

  @override
  Future<Uint8List?> read() async {
    final snapshot = await _storage.getChatGptAccountSnapshot();
    return snapshot == null ? null : Uint8List.fromList(snapshot);
  }

  @override
  Future<void> write(Uint8List snapshot) =>
      _storage.saveChatGptAccountSnapshot(snapshot);
}

final class ChatGptNativeBootstrap {
  static Future<void>? _initializing;

  static Future<void> ensureLoaded() {
    final current = _initializing;
    if (current != null) return current;
    late final Future<void> guarded;
    guarded = RustLib.init().onError((Object error, StackTrace stackTrace) {
      if (identical(_initializing, guarded)) _initializing = null;
      Error.throwWithStackTrace(error, stackTrace);
    });
    _initializing = guarded;
    return guarded;
  }
}

final class FrbChatGptRuntimeClient implements ChatGptRuntimeClient {
  FrbChatGptRuntimeClient({required ChatGptAuthSnapshotStore snapshotStore})
    : _snapshotStore = snapshotStore;

  final ChatGptAuthSnapshotStore _snapshotStore;
  final StreamController<RuntimeEvent> _events =
      StreamController<RuntimeEvent>.broadcast(sync: true);
  StreamSubscription<RuntimeEvent>? _nativeSubscription;
  Future<void> _nativeEventQueue = Future<void>.value();
  Future<void>? _initializing;
  Future<void>? _shuttingDown;
  BigInt? _clientEpoch;
  bool _disposed = false;

  @override
  Stream<RuntimeEvent> get events => _events.stream;

  @override
  Future<void> initialize() {
    if (_disposed) {
      return Future<void>.error(
        StateError('The ChatGPT runtime client has been disposed.'),
      );
    }
    final shuttingDown = _shuttingDown;
    if (shuttingDown != null) {
      return shuttingDown.then((_) => initialize());
    }
    final current = _initializing;
    if (current != null) return current;
    late final Future<void> guarded;
    guarded = _initialize().onError((Object error, StackTrace stackTrace) {
      if (identical(_initializing, guarded)) _initializing = null;
      Error.throwWithStackTrace(error, stackTrace);
    });
    _initializing = guarded;
    return guarded;
  }

  Future<void> _initialize() async {
    await ChatGptNativeBootstrap.ensureLoaded();
    final protocol = await native.bridgeProtocolVersion();
    if (protocol != 2) {
      throw const BridgeError(
        kind: BridgeErrorKind.protocolMismatch,
        message: 'Native ChatGPT protocol version is unsupported.',
      );
    }
    final support = await getApplicationSupportDirectory();
    final epoch = BigInt.from(DateTime.now().microsecondsSinceEpoch);
    final snapshot = await _snapshotStore.read();
    await native.initializeRuntime(
      clientEpoch: epoch,
      dataDirectory: p.join(support.path, 'chatgpt-account'),
      authSnapshot: snapshot,
    );
    _clientEpoch = epoch;
    await _nativeSubscription?.cancel();
    _nativeSubscription = native
        .runtimeEvents(clientEpoch: epoch)
        .listen(
          _enqueueNativeEvent,
          onError: (Object error, StackTrace stackTrace) {
            DebugLogger.error(
              'event-stream-failed',
              scope: 'native/chatgpt',
              data: {'errorType': error.runtimeType.toString()},
            );
            if (!_events.isClosed) _events.addError(error, stackTrace);
          },
          onDone: () {
            if (_clientEpoch != epoch) return;
            _nativeSubscription = null;
            _initializing = null;
            _clientEpoch = null;
            DebugLogger.warning('event-stream-closed', scope: 'native/chatgpt');
            if (!_events.isClosed) {
              _events.addError(
                StateError('The native ChatGPT event stream closed.'),
              );
            }
          },
        );
    DebugLogger.info(
      'runtime-ready',
      scope: 'native/chatgpt',
      data: {'protocol': protocol},
    );
  }

  void _enqueueNativeEvent(RuntimeEvent event) {
    final work = _nativeEventQueue.then<void>((_) => _handleNativeEvent(event));
    _nativeEventQueue = work.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        DebugLogger.error(
          'event-handling-failed',
          scope: 'native/chatgpt',
          data: {'errorType': error.runtimeType.toString()},
        );
        if (!_events.isClosed) _events.addError(error, stackTrace);
      },
    );
  }

  Future<void> _handleNativeEvent(RuntimeEvent event) async {
    if (event.clientEpoch != _clientEpoch) return;
    if (event.kind == RuntimeEventKind.authMutationRequired) {
      await _persistAuthMutation(event);
      return;
    }
    if (event.kind == RuntimeEventKind.diagnostic) {
      DebugLogger.info(
        'runtime-diagnostic',
        scope: 'native/chatgpt',
        data: {'hasDetails': event.text?.isNotEmpty == true},
      );
    }
    _events.add(event);
  }

  Future<void> _persistAuthMutation(RuntimeEvent event) async {
    String? mutationId;
    var acknowledged = false;
    try {
      final metadata = jsonDecode(event.jsonData ?? '{}');
      if (metadata is! Map<String, dynamic>) {
        throw const FormatException('Invalid auth mutation metadata.');
      }
      mutationId = metadata['mutationId'] as String?;
      final delete = metadata['delete'] == true;
      if (mutationId == null || mutationId.isEmpty) {
        throw const FormatException('Missing auth mutation id.');
      }
      if (delete) {
        await _snapshotStore.delete();
      } else {
        final snapshot = event.binaryData;
        if (snapshot == null || snapshot.isEmpty) {
          throw const FormatException('Missing auth mutation snapshot.');
        }
        await _snapshotStore.write(snapshot);
      }
      acknowledged = true;
      DebugLogger.auth(
        delete ? 'snapshot-deleted' : 'snapshot-updated',
        scope: 'auth/chatgpt',
      );
    } catch (error) {
      DebugLogger.error(
        'snapshot-mutation-failed',
        scope: 'auth/chatgpt',
        data: {'errorType': error.runtimeType.toString()},
      );
    } finally {
      if (mutationId != null) {
        try {
          await native.ackAuthMutation(
            mutationId: mutationId,
            persisted: acknowledged,
          );
        } catch (error, stackTrace) {
          DebugLogger.error(
            'snapshot-acknowledgement-failed',
            scope: 'auth/chatgpt',
            data: {'errorType': error.runtimeType.toString()},
          );
          Error.throwWithStackTrace(error, stackTrace);
        }
      }
    }
  }

  Future<T> _ready<T>(Future<T> Function() operation) async {
    await initialize();
    return operation();
  }

  @override
  Future<AuthStateInfo> authState() => _ready(native.authState);

  @override
  Future<DeviceCodeChallenge> beginDeviceCodeLogin() =>
      _ready(native.beginDeviceCodeLogin);

  @override
  Future<void> cancelDeviceCodeLogin() => _ready(native.cancelDeviceCodeLogin);

  @override
  Future<List<ModelInfo>> listModels() => _ready(native.listModels);

  @override
  Future<ThreadInfo> startThread(
    String modelId, {
    required bool enableWebSearch,
    required bool enableImageGeneration,
  }) => _ready(
    () => native.startThread(
      modelId: modelId,
      enableWebSearch: enableWebSearch,
      enableImageGeneration: enableImageGeneration,
    ),
  );

  @override
  Future<ThreadInfo> resumeThread(String threadId) =>
      _ready(() => native.resumeThread(threadId: threadId));

  @override
  Future<ThreadInfo> forkThread(String threadId, {String? turnId}) =>
      _ready(() => native.forkThread(threadId: threadId, turnId: turnId));

  @override
  Future<RunInfo> startTurn(TurnRequest request) =>
      _ready(() => native.startTurn(request: request));

  @override
  Future<void> interruptTurn(String runId) =>
      _ready(() => native.interruptTurn(runId: runId));

  @override
  Future<void> disconnectAccount() => _ready(native.disconnectAccount);

  @override
  Future<void> shutdown() {
    final current = _shuttingDown;
    if (current != null) return current;
    late final Future<void> guarded;
    guarded = _shutdown().whenComplete(() {
      if (identical(_shuttingDown, guarded)) _shuttingDown = null;
    });
    _shuttingDown = guarded;
    return guarded;
  }

  Future<void> _shutdown() async {
    final initializing = _initializing;
    if (initializing != null) {
      try {
        await initializing;
      } catch (_) {
        // Initialization already reported its own failure. Cleanup still runs.
      }
    }
    await _nativeSubscription?.cancel();
    _nativeSubscription = null;
    await _nativeEventQueue;
    if (_clientEpoch != null) await native.shutdownRuntime();
    _clientEpoch = null;
    _initializing = null;
  }

  Future<void> dispose() async {
    _disposed = true;
    await shutdown();
    if (!_events.isClosed) await _events.close();
  }
}
