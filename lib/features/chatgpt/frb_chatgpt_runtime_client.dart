import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../core/services/secure_credential_storage.dart';
import '../../core/utils/debug_logger.dart';
import 'chatgpt_runtime_client.dart';
import 'native_generated/api/contract.dart';
import 'native_generated/api/runtime.dart' as native;
import 'native_generated/frb_generated.dart';

const _eventStreamReadyReason = 'eventStreamReady';
const _eventStreamReadyTimeout = Duration(seconds: 10);

Map<String, Object> debugSanitizedChatGptDiagnosticData(String? source) {
  if (source == null || source.isEmpty) return const {};
  try {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic>) return const {};
    const allowed = {
      'reason',
      'operation',
      'class',
      'status',
      'code',
      'type',
      'param',
      'detail',
    };
    final result = <String, Object>{};
    for (final key in allowed) {
      final value = decoded[key];
      if (value is num || value is bool) {
        result[key] = value as Object;
      } else if (value is String && value.length <= 128) {
        result[key] = value;
      }
    }
    return result;
  } catch (_) {
    return const {};
  }
}

bool _isEventStreamReady(RuntimeEvent event) {
  if (event.kind != RuntimeEventKind.diagnostic) return false;
  return debugSanitizedChatGptDiagnosticData(event.jsonData)['reason'] ==
      _eventStreamReadyReason;
}

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
  FrbChatGptRuntimeClient({
    required ChatGptAuthSnapshotStore snapshotStore,
    Future<void> Function()? ensureNativeLoaded,
    Future<int> Function()? bridgeProtocolVersion,
    Future<void> Function({
      required BigInt clientEpoch,
      Uint8List? authSnapshot,
    })?
    initializeRuntime,
    Stream<RuntimeEvent> Function({required BigInt clientEpoch})? runtimeEvents,
    Future<void> Function()? shutdownRuntime,
  }) : _snapshotStore = snapshotStore,
       _ensureNativeLoaded =
           ensureNativeLoaded ?? ChatGptNativeBootstrap.ensureLoaded,
       _bridgeProtocolVersion =
           bridgeProtocolVersion ?? native.bridgeProtocolVersion,
       _initializeRuntime = initializeRuntime ?? native.initializeRuntime,
       _runtimeEvents = runtimeEvents ?? native.runtimeEvents,
       _shutdownRuntime = shutdownRuntime ?? native.shutdownRuntime;

  final ChatGptAuthSnapshotStore _snapshotStore;
  final Future<void> Function() _ensureNativeLoaded;
  final Future<int> Function() _bridgeProtocolVersion;
  final Future<void> Function({
    required BigInt clientEpoch,
    Uint8List? authSnapshot,
  })
  _initializeRuntime;
  final Stream<RuntimeEvent> Function({required BigInt clientEpoch})
  _runtimeEvents;
  final Future<void> Function() _shutdownRuntime;
  final StreamController<RuntimeEvent> _events =
      StreamController<RuntimeEvent>.broadcast(sync: true);
  StreamSubscription<RuntimeEvent>? _nativeSubscription;
  Object? _nativeSubscriptionToken;
  Completer<void>? _eventStreamReady;
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
    await _ensureNativeLoaded();
    final protocol = await _bridgeProtocolVersion();
    if (protocol != 3) {
      throw const BridgeError(
        kind: BridgeErrorKind.protocolMismatch,
        message: 'Native ChatGPT protocol version is unsupported.',
      );
    }
    final epoch = BigInt.from(DateTime.now().microsecondsSinceEpoch);
    final snapshot = await _snapshotStore.read();
    await _initializeRuntime(clientEpoch: epoch, authSnapshot: snapshot);
    _clientEpoch = epoch;
    final previousSubscription = _nativeSubscription;
    _nativeSubscription = null;
    _nativeSubscriptionToken = null;
    await previousSubscription?.cancel();
    final eventStreamReady = Completer<void>();
    _eventStreamReady = eventStreamReady;
    final subscriptionToken = Object();
    _nativeSubscriptionToken = subscriptionToken;
    final nativeSubscription = _runtimeEvents(clientEpoch: epoch).listen(
      (event) {
        if (_clientEpoch != epoch ||
            !identical(_nativeSubscriptionToken, subscriptionToken)) {
          return;
        }
        if (_isEventStreamReady(event)) {
          if (!eventStreamReady.isCompleted) eventStreamReady.complete();
          return;
        }
        _enqueueNativeEvent(event);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (_clientEpoch != epoch ||
            !identical(_nativeSubscriptionToken, subscriptionToken)) {
          return;
        }
        if (!eventStreamReady.isCompleted) {
          eventStreamReady.completeError(error, stackTrace);
        }
        DebugLogger.error(
          'event-stream-failed',
          scope: 'native/chatgpt',
          data: {'errorType': error.runtimeType.toString()},
        );
        if (!_events.isClosed) _events.addError(error, stackTrace);
      },
      onDone: () {
        if (_clientEpoch != epoch ||
            !identical(_nativeSubscriptionToken, subscriptionToken)) {
          return;
        }
        if (!eventStreamReady.isCompleted) {
          eventStreamReady.completeError(
            StateError('The native ChatGPT event stream closed before ready.'),
          );
          return;
        }
        _nativeSubscriptionToken = null;
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
    if (identical(_nativeSubscriptionToken, subscriptionToken)) {
      _nativeSubscription = nativeSubscription;
    } else {
      await nativeSubscription.cancel();
    }
    try {
      await eventStreamReady.future.timeout(
        _eventStreamReadyTimeout,
        onTimeout: () => throw const BridgeError(
          kind: BridgeErrorKind.internal,
          message: 'The native ChatGPT event stream did not become ready.',
        ),
      );
      if (_clientEpoch != epoch ||
          !identical(_nativeSubscriptionToken, subscriptionToken)) {
        throw const BridgeError(
          kind: BridgeErrorKind.internal,
          message: 'The native ChatGPT event stream closed during startup.',
        );
      }
    } catch (_) {
      if (_clientEpoch == epoch &&
          identical(_nativeSubscriptionToken, subscriptionToken)) {
        _nativeSubscriptionToken = null;
        final failedSubscription = _nativeSubscription;
        _nativeSubscription = null;
        await failedSubscription?.cancel();
      }
      rethrow;
    } finally {
      if (identical(_eventStreamReady, eventStreamReady)) {
        _eventStreamReady = null;
      }
    }
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
        data: debugSanitizedChatGptDiagnosticData(event.jsonData),
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
    final eventStreamReady = _eventStreamReady;
    if (eventStreamReady != null && !eventStreamReady.isCompleted) {
      eventStreamReady.completeError(
        const BridgeError(
          kind: BridgeErrorKind.cancellation,
          message: 'ChatGPT runtime initialization was cancelled.',
        ),
        StackTrace.current,
      );
    }
    final initializing = _initializing;
    if (initializing != null) {
      try {
        await initializing;
      } catch (_) {
        // Initialization already reported its own failure. Cleanup still runs.
      }
    }
    _nativeSubscriptionToken = null;
    final nativeSubscription = _nativeSubscription;
    _nativeSubscription = null;
    await nativeSubscription?.cancel();
    await _nativeEventQueue;
    if (_clientEpoch != null) await _shutdownRuntime();
    _clientEpoch = null;
    _initializing = null;
  }

  Future<void> dispose() async {
    _disposed = true;
    await shutdown();
    if (!_events.isClosed) await _events.close();
  }
}
