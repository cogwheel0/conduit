import 'dart:async';
import 'dart:typed_data';

import 'package:conduit/features/chatgpt/chatgpt_runtime_client.dart';
import 'package:conduit/features/chatgpt/frb_chatgpt_runtime_client.dart';
import 'package:conduit/features/chatgpt/native_generated/api/contract.dart';
import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native diagnostics expose only bounded non-secret fields', () {
    final data = debugSanitizedChatGptDiagnosticData(
      '{'
      '"reason":"apiFailure",'
      '"operation":"responses",'
      '"status":400,'
      '"code":"invalid_tool_schema",'
      '"detail":"schema",'
      '"message":"provider secret",'
      '"authorization":"Bearer secret"'
      '}',
    );

    check(data).deepEquals(<String, Object>{
      'reason': 'apiFailure',
      'operation': 'responses',
      'status': 400,
      'code': 'invalid_tool_schema',
      'detail': 'schema',
    });
    check(data.toString()).not((value) => value.contains('secret'));
  });

  test('initialize waits until the native event subscriber is ready', () async {
    final nativeEvents = StreamController<RuntimeEvent>();
    late BigInt observedEpoch;
    final client = FrbChatGptRuntimeClient(
      snapshotStore: _MemorySnapshotStore(),
      ensureNativeLoaded: () async {},
      bridgeProtocolVersion: () async => 3,
      initializeRuntime: ({required clientEpoch, authSnapshot}) async {},
      runtimeEvents: ({required BigInt clientEpoch}) {
        observedEpoch = clientEpoch;
        return nativeEvents.stream;
      },
      shutdownRuntime: () async {},
    );
    addTearDown(() async {
      await client.dispose();
      await nativeEvents.close();
    });

    var initialized = false;
    final initialization = client.initialize().then((_) => initialized = true);
    for (var index = 0; index < 5; index += 1) {
      await Future<void>.delayed(Duration.zero);
    }

    check(initialized).isFalse();
    nativeEvents.add(
      RuntimeEvent(
        clientEpoch: observedEpoch,
        sequence: BigInt.one,
        kind: RuntimeEventKind.diagnostic,
        jsonData: '{"reason":"eventStreamReady"}',
      ),
    );
    await initialization.timeout(const Duration(seconds: 1));
    check(initialized).isTrue();
  });

  test('shutdown cancels a pending native event readiness wait', () async {
    final nativeEvents = StreamController<RuntimeEvent>();
    var shutdownCalls = 0;
    final client = FrbChatGptRuntimeClient(
      snapshotStore: _MemorySnapshotStore(),
      ensureNativeLoaded: () async {},
      bridgeProtocolVersion: () async => 3,
      initializeRuntime: ({required clientEpoch, authSnapshot}) async {},
      runtimeEvents: ({required BigInt clientEpoch}) => nativeEvents.stream,
      shutdownRuntime: () async => shutdownCalls += 1,
    );
    addTearDown(() async {
      await client.dispose();
      await nativeEvents.close();
    });

    final initialization = client.initialize();
    for (var index = 0; index < 5; index += 1) {
      await Future<void>.delayed(Duration.zero);
    }
    final initializationResult = expectLater(
      initialization,
      throwsA(
        isA<BridgeError>().having(
          (error) => error.kind,
          'kind',
          BridgeErrorKind.cancellation,
        ),
      ),
    );

    await client.shutdown().timeout(const Duration(seconds: 1));
    await initializationResult;
    check(shutdownCalls).equals(1);
  });

  test('a stream that closes before ready does not corrupt retry', () async {
    final nativeEvents = <StreamController<RuntimeEvent>>[
      StreamController<RuntimeEvent>(),
      StreamController<RuntimeEvent>(),
    ];
    final epochs = <BigInt>[];
    var streamIndex = 0;
    final client = FrbChatGptRuntimeClient(
      snapshotStore: _MemorySnapshotStore(),
      ensureNativeLoaded: () async {},
      bridgeProtocolVersion: () async => 3,
      initializeRuntime: ({required clientEpoch, authSnapshot}) async {},
      runtimeEvents: ({required BigInt clientEpoch}) {
        epochs.add(clientEpoch);
        return nativeEvents[streamIndex++].stream;
      },
      shutdownRuntime: () async {},
    );
    addTearDown(() async {
      await client.dispose();
      for (final controller in nativeEvents) {
        if (!controller.isClosed) await controller.close();
      }
    });

    final firstInitialization = client.initialize();
    for (var index = 0; index < 5; index += 1) {
      await Future<void>.delayed(Duration.zero);
    }
    final firstResult = expectLater(
      firstInitialization,
      throwsA(isA<StateError>()),
    );
    await nativeEvents.first.close();
    await firstResult;

    final retry = client.initialize();
    for (var index = 0; index < 5; index += 1) {
      await Future<void>.delayed(Duration.zero);
    }
    nativeEvents.last.add(
      RuntimeEvent(
        clientEpoch: epochs.last,
        sequence: BigInt.one,
        kind: RuntimeEventKind.diagnostic,
        jsonData: '{"reason":"eventStreamReady"}',
      ),
    );

    await retry.timeout(const Duration(seconds: 1));
    check(streamIndex).equals(2);
  });

  test('stream close drains events already delivered by native', () async {
    final nativeEvents = StreamController<RuntimeEvent>(sync: true);
    late BigInt observedEpoch;
    final client = FrbChatGptRuntimeClient(
      snapshotStore: _MemorySnapshotStore(),
      ensureNativeLoaded: () async {},
      bridgeProtocolVersion: () async => 3,
      initializeRuntime: ({required clientEpoch, authSnapshot}) async {},
      runtimeEvents: ({required BigInt clientEpoch}) {
        observedEpoch = clientEpoch;
        return nativeEvents.stream;
      },
      shutdownRuntime: () async {},
    );
    final received = <RuntimeEvent>[];
    final subscription = client.events.listen(
      received.add,
      onError: (Object _) {},
    );
    addTearDown(() async {
      await subscription.cancel();
      await client.dispose();
      if (!nativeEvents.isClosed) await nativeEvents.close();
    });

    final initialization = client.initialize();
    for (var index = 0; index < 5; index += 1) {
      await Future<void>.delayed(Duration.zero);
    }
    nativeEvents.add(
      RuntimeEvent(
        clientEpoch: observedEpoch,
        sequence: BigInt.one,
        kind: RuntimeEventKind.diagnostic,
        jsonData: '{"reason":"eventStreamReady"}',
      ),
    );
    await initialization.timeout(const Duration(seconds: 1));

    nativeEvents.add(
      RuntimeEvent(
        clientEpoch: observedEpoch,
        sequence: BigInt.two,
        kind: RuntimeEventKind.completed,
      ),
    );
    await nativeEvents.close();
    for (var index = 0; index < 5; index += 1) {
      await Future<void>.delayed(Duration.zero);
    }

    check(
      received.map((event) => event.kind),
    ).deepEquals([RuntimeEventKind.completed]);
  });
}

final class _MemorySnapshotStore implements ChatGptAuthSnapshotStore {
  Uint8List? snapshot;

  @override
  Future<void> delete() async => snapshot = null;

  @override
  Future<Uint8List?> read() async => snapshot;

  @override
  Future<void> write(Uint8List snapshot) async {
    this.snapshot = Uint8List.fromList(snapshot);
  }
}
