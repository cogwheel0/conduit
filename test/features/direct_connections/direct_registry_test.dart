import 'dart:async';

import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/features/direct_connections/models/direct_completion.dart';
import 'package:conduit/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit/features/direct_connections/services/direct_provider_adapter.dart';
import 'package:conduit/features/direct_connections/services/direct_run_registry.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('stable model ids round-trip arbitrary provider ids', () {
    final encoded = DirectModelId.encode('profile-one', 'org/model:版本');
    final decoded = DirectModelId.decode(encoded);

    expect(encoded, startsWith('direct:profile-one:'));
    expect(decoded?.profileId, 'profile-one');
    expect(decoded?.remoteModelId, 'org/model:版本');
  });

  test('remote models compare structurally, including capabilities', () {
    final first = DirectRemoteModel(
      id: 'model',
      name: 'Model',
      description: 'Example',
      isMultimodal: true,
      capabilities: const {
        'families': ['clip'],
        'limits': {'context': 4096},
      },
    );
    final second = DirectRemoteModel(
      id: 'model',
      name: 'Model',
      description: 'Example',
      isMultimodal: true,
      capabilities: const {
        'families': ['clip'],
        'limits': {'context': 4096},
      },
    );

    expect(second, first);
    expect(second.hashCode, first.hashCode);
    expect(
      DirectRemoteModel(id: 'model', capabilities: const {'vision': false}),
      isNot(first),
    );
  });

  test('remote model capabilities are recursively copied and frozen', () {
    final source = <String, dynamic>{
      'families': <String>['clip'],
      'limits': <String, dynamic>{'context': 4096},
    };
    final model = DirectRemoteModel(id: 'model', capabilities: source);
    final initialHash = model.hashCode;

    (source['families'] as List<String>).add('mutated');
    (source['limits'] as Map<String, dynamic>)['context'] = 1;

    expect(model.capabilities['families'], ['clip']);
    expect((model.capabilities['limits'] as Map)['context'], 4096);
    expect(model.hashCode, initialHash);
    expect(
      () => (model.capabilities['families'] as List).add('blocked'),
      throwsUnsupportedError,
    );
    expect(
      () => (model.capabilities['limits'] as Map)['context'] = 2,
      throwsUnsupportedError,
    );
  });

  test('only locally minted and currently registered models resolve', () {
    final registry = DirectModelRegistry();
    final profile = DirectConnectionProfile(
      id: 'profile-one',
      name: 'Example',
      adapterKey: kOllamaAdapterKey,
      baseUrl: 'http://localhost:11434',
    );
    final models = registry.replaceProfileModels(profile, [
      DirectRemoteModel(id: 'llava:latest', isMultimodal: true),
    ]);
    final minted = models.single;
    final forged = Model(
      id: minted.id,
      name: minted.name,
      metadata: const {'backend': 'direct'},
    );

    expect(registry.resolve(minted)?.remoteModelId, 'llava:latest');
    expect(registry.resolve(forged), isNull);
    expect(registry.resolveRegisteredId(minted.id), isNotNull);

    registry.removeProfile(profile.id);
    expect(registry.resolve(minted), isNull);
    expect(registry.resolveRegisteredId(minted.id), isNull);
  });

  test('stale model cannot resolve through a recreated equal binding', () {
    final registry = DirectModelRegistry();
    final profile = DirectConnectionProfile(
      id: 'profile-one',
      name: 'Example',
      adapterKey: kOllamaAdapterKey,
      baseUrl: 'http://localhost:11434',
    );
    final stale = registry.replaceProfileModels(profile, [
      DirectRemoteModel(id: 'model'),
    ]).single;

    registry.removeProfile(profile.id);
    final current = registry.replaceProfileModels(profile, [
      DirectRemoteModel(id: 'model'),
    ]).single;

    expect(stale.id, current.id);
    expect(registry.resolve(stale), isNull);
    expect(registry.resolve(current)?.remoteModelId, 'model');
  });

  test('binding revision changes only when registry contents mutate', () {
    final registry = DirectModelRegistry();
    final profile = DirectConnectionProfile(
      id: 'profile-one',
      name: 'Example',
      adapterKey: kOllamaAdapterKey,
      baseUrl: 'http://localhost:11434',
    );

    expect(registry.revision, 0);
    registry.removeProfile('missing');
    registry.clear();
    expect(registry.revision, 0);

    registry.replaceProfileModels(profile, [DirectRemoteModel(id: 'model')]);
    final registeredRevision = registry.revision;
    expect(registeredRevision, greaterThan(0));

    registry.removeProfile(profile.id);
    expect(registry.revision, greaterThan(registeredRevision));
    final removedRevision = registry.revision;

    registry.removeProfile(profile.id);
    registry.clear();
    expect(registry.revision, removedRevision);
  });

  test(
    'profile prefixes and tags decorate models without changing routing',
    () {
      final registry = DirectModelRegistry();
      final profile = DirectConnectionProfile(
        id: 'lm-studio',
        name: 'LM Studio',
        adapterKey: kOpenAiCompatibleAdapterKey,
        baseUrl: 'http://localhost:1234/v1',
        modelIdPrefix: 'studio',
        tags: const ['local', 'private'],
      );

      final model = registry.replaceProfileModels(profile, [
        DirectRemoteModel(id: 'qwen', name: 'Qwen'),
      ]).single;

      expect(model.name, 'studio.Qwen');
      expect(model.modelTags, ['local', 'private']);
      expect(model.metadata?['remoteModelDisplayId'], 'studio.qwen');
      expect(registry.resolve(model)?.remoteModelId, 'qwen');
    },
  );

  test('Open WebUI provenance and URL index are trusted binding state', () {
    final registry = DirectModelRegistry();
    final profile = DirectConnectionProfile(
      id: 'owui-profile',
      name: 'Open WebUI connection',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://provider.example/v1',
      modelIdPrefix: 'remote',
    );

    final model = registry
        .replaceProfileModels(
          profile,
          [DirectRemoteModel(id: 'model-a')],
          source: DirectModelSource.openWebUi,
          openWebUiUrlIndex: 3,
        )
        .single;
    final binding = registry.resolve(model);

    expect(binding?.source, DirectModelSource.openWebUi);
    expect(binding?.openWebUiUrlIndex, 3);
    expect(binding?.openWebUiModelId, 'remote.model-a');
    expect(binding?.remoteModelId, 'model-a');
    expect(model.metadata?['remoteModelDisplayId'], 'remote.model-a');
    expect(model.metadata?['openWebUiDirectConnection'], isTrue);
    expect(model.metadata?['urlIdx'], 3);
    expect(
      () => registry.replaceProfileModels(profile, [
        DirectRemoteModel(id: 'model-b'),
      ], source: DirectModelSource.openWebUi),
      throwsArgumentError,
    );
    expect(
      () => registry.replaceProfileModels(
        profile,
        [DirectRemoteModel(id: 'model-b')],
        source: DirectModelSource.openWebUi,
        openWebUiUrlIndex: -1,
      ),
      throwsArgumentError,
    );
  });

  test('Open WebUI wire ids resolve to the last current trusted model', () {
    final registry = DirectModelRegistry();
    DirectConnectionProfile profile(String id) => DirectConnectionProfile(
      id: id,
      name: id,
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://$id.example/v1',
      modelIdPrefix: 'shared',
    );

    final first = registry
        .replaceProfileModels(
          profile('first'),
          [DirectRemoteModel(id: 'model')],
          source: DirectModelSource.openWebUi,
          openWebUiUrlIndex: 0,
        )
        .single;
    final second = registry
        .replaceProfileModels(
          profile('second'),
          [DirectRemoteModel(id: 'model')],
          source: DirectModelSource.openWebUi,
          openWebUiUrlIndex: 1,
        )
        .single;
    final forged = Model(id: second.id, name: second.name);

    expect(registry.hasOpenWebUiWireModel('shared.model'), isTrue);
    expect(
      registry.resolveOpenWebUiWireModel([
        first,
        second,
        forged,
      ], 'shared.model'),
      same(second),
    );
    expect(
      registry
          .resolveOpenWebUiWireBinding(
            profileId: 'second',
            urlIndex: 1,
            wireModelId: 'shared.model',
          )
          ?.remoteModelId,
      'model',
    );
    expect(
      registry.resolveOpenWebUiWireBinding(
        profileId: 'second',
        urlIndex: 0,
        wireModelId: 'shared.model',
      ),
      isNull,
    );

    registry.removeProfile('second');
    expect(
      registry.resolveOpenWebUiWireModel([
        first,
        forged,
        second,
      ], 'shared.model'),
      same(first),
    );
  });

  test(
    'display reconciliation preserves server-owned direct-like identities',
    () {
      final registry = DirectModelRegistry();
      final remote = [
        const Model(id: 'normal', name: 'Normal'),
        const Model(id: 'direct:server:value', name: 'Direct-like id'),
        const Model(
          id: 'backend-metadata',
          name: 'Backend metadata',
          metadata: {'backend': 'direct'},
        ),
        const Model(
          id: 'direct-metadata',
          name: 'Direct metadata',
          metadata: {'direct': true},
        ),
        const Model(
          id: 'provider-metadata',
          name: 'Provider metadata',
          metadata: {'directProvider': 'server-owned'},
        ),
      ];

      final reconciled = reconcileDirectModelsForDisplay(
        remoteModels: remote,
        directModels: const [],
        registry: registry,
      );

      expect(reconciled, remote);
      expect(remote.where(hasReservedDirectIdentity), isEmpty);
    },
  );

  test('display reconciliation appends each locally minted model once', () {
    final registry = DirectModelRegistry();
    final profile = DirectConnectionProfile(
      id: 'profile-one',
      name: 'Example',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://example.test/v1',
    );
    final minted = registry.replaceProfileModels(profile, [
      DirectRemoteModel(id: 'local-model'),
    ]).single;
    const server = Model(id: 'server-model', name: 'Server model');
    final collidingServerModel = Model(
      id: minted.id,
      name: 'Server model claiming the live direct id',
      metadata: const {'backend': 'direct'},
    );

    final reconciled = reconcileDirectModelsForDisplay(
      remoteModels: [server, collidingServerModel, minted],
      directModels: [minted],
      registry: registry,
    );

    expect(reconciled, [server, minted]);
    expect(hasReservedDirectIdentity(minted), isTrue);
    expect(reconciled.map((model) => model.id).toSet(), hasLength(2));
  });

  test('display reconciliation removes stale locally minted models', () {
    final registry = DirectModelRegistry();
    final profile = DirectConnectionProfile(
      id: 'profile-one',
      name: 'Example',
      adapterKey: kOpenAiCompatibleAdapterKey,
      baseUrl: 'https://example.test/v1',
    );
    final stale = registry.replaceProfileModels(profile, [
      DirectRemoteModel(id: 'stale-model'),
    ]).single;

    expect(
      reconcileDirectModelsForDisplay(
        remoteModels: const [],
        directModels: [stale],
        registry: registry,
      ),
      [stale],
    );

    registry.removeProfile(profile.id);
    final reconciled = reconcileDirectModelsForDisplay(
      remoteModels: const [],
      directModels: [stale],
      registry: registry,
    );

    expect(reconciled, isEmpty);
  });

  test('adapter registry is string-keyed and rejects duplicates', () {
    final first = _Adapter('custom-provider');
    final registry = DirectProviderAdapterRegistry([first]);

    expect(registry.require('custom-provider'), same(first));
    expect(registry.lookup('  custom-provider  '), same(first));
    expect(
      () => registry.register(_Adapter('custom-provider')),
      throwsStateError,
    );
    expect(registry.unregister(' custom-provider '), isTrue);
    expect(registry.lookup('custom-provider'), isNull);
  });

  test('a stop during preflight cancels the run before registration', () async {
    final registry = DirectRunRegistry();
    final key = _runKey('assistant-one');
    final reservation = registry.reserve(key, 'profile-one');

    final stop = registry.cancel(key);
    expect(stop, isNotNull);
    await stop;
    expect(registry.isCancelled(reservation), isTrue);

    final token = CancelToken();
    final run = _run('run-one', token);
    expect(registry.register(reservation, run), isFalse);
    await Future<void>.delayed(Duration.zero);

    expect(token.isCancelled, isTrue);
    expect(registry.runFor(key), isNull);
    expect(
      registry.cancel(key),
      isNull,
      reason: 'the rejected reservation must no longer remain pending',
    );
  });

  test(
    'failed registration contains a rejected detached cleanup future',
    () async {
      final registry = DirectRunRegistry();
      final key = _runKey('assistant-one');
      final reservation = registry.reserve(key, 'profile-one');
      await registry.cancel(key);

      final cleanup = Completer<void>();
      final token = CancelToken();
      final run = _runWithDone('rejected-run', token, cleanup.future);
      expect(registry.register(reservation, run), isFalse);
      expect(token.isCancelled, isTrue);

      cleanup.completeError(StateError('hostile cleanup failure'));
      await Future<void>.delayed(Duration.zero);

      expect(registry.runFor(key), isNull);
    },
  );

  test('replacement contains a rejected detached cleanup future', () async {
    final registry = DirectRunRegistry();
    final key = _runKey('assistant-one');
    final cleanup = Completer<void>();
    final token = CancelToken();
    final first = registry.reserve(key, 'profile-one');
    expect(
      registry.register(
        first,
        _runWithDone('replaced-run', token, cleanup.future),
      ),
      isTrue,
    );

    final replacement = registry.reserve(key, 'profile-one');
    expect(token.isCancelled, isTrue);
    cleanup.completeError(StateError('hostile cleanup failure'));
    await Future<void>.delayed(Duration.zero);

    expect(registry.isLatest(first), isFalse);
    expect(registry.isLatest(replacement), isTrue);
  });

  test(
    'profile cancellation trusts reservation ownership over run metadata',
    () async {
      final registry = DirectRunRegistry();
      final key = _runKey('assistant-one');
      final reservation = registry.reserve(key, 'profile-one');
      final token = CancelToken();
      final run = _runWithDone(
        'mislabeled-run',
        token,
        Future<void>.value(),
        profileId: 'untrusted-other-profile',
      );
      expect(registry.register(reservation, run), isTrue);
      final otherKey = _runKey('assistant-two');
      final otherReservation = registry.reserve(otherKey, 'profile-two');
      final otherToken = CancelToken();
      final mislabeledOtherRun = _runWithDone(
        'mislabeled-other-run',
        otherToken,
        Future<void>.value(),
        profileId: 'profile-one',
      );
      expect(registry.register(otherReservation, mislabeledOtherRun), isTrue);

      final cancellations = registry.cancelProfile('profile-one');
      expect(cancellations, hasLength(1));
      await Future.wait(cancellations);

      expect(token.isCancelled, isTrue);
      expect(registry.runFor(key), isNull);
      expect(registry.owns(reservation, run), isFalse);
      expect(otherToken.isCancelled, isFalse);
      expect(registry.runFor(otherKey), same(mislabeledOtherRun));
      expect(registry.owns(otherReservation, mislabeledOtherRun), isTrue);
    },
  );

  test(
    'a stale reservation cannot release or publish over its replacement',
    () async {
      final registry = DirectRunRegistry();
      final key = _runKey('assistant-one');
      final stale = registry.reserve(key, 'profile-one');
      final current = registry.reserve(key, 'profile-one');

      registry.releaseReservation(stale);
      expect(registry.isCancelled(stale), isTrue);
      expect(registry.isCancelled(current), isFalse);

      final staleCancelToken = CancelToken();
      final staleRun = _run('stale-run', staleCancelToken);
      expect(registry.register(stale, staleRun), isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(staleCancelToken.isCancelled, isTrue);
      expect(registry.isCancelled(current), isFalse);

      final currentRun = _run('current-run', CancelToken());
      expect(registry.register(current, currentRun), isTrue);
      expect(registry.runFor(key), same(currentRun));
      expect(registry.isLatest(current), isTrue);
      expect(registry.owns(current, currentRun), isTrue);

      await registry.cancel(key);
      expect(registry.owns(current, currentRun), isFalse);
      expect(registry.isLatest(current), isTrue);

      final replacement = registry.reserve(key, 'profile-one');
      expect(registry.isLatest(current), isFalse);
      expect(registry.isLatest(replacement), isTrue);
    },
  );

  test(
    'colliding assistant ids in different conversations stay independent',
    () {
      final registry = DirectRunRegistry();
      final keyA = _runKey('same-assistant', owner: 'chat-a');
      final keyB = _runKey('same-assistant', owner: 'chat-b');
      final reservationA = registry.reserve(keyA, 'profile-one');
      final runA = _run('run-a', CancelToken());
      expect(registry.register(reservationA, runA), isTrue);

      final reservationB = registry.reserve(keyB, 'profile-one');
      final runB = _run('run-b', CancelToken());
      expect(registry.register(reservationB, runB), isTrue);

      expect(registry.runFor(keyA), same(runA));
      expect(registry.runFor(keyB), same(runB));
      expect(registry.owns(reservationA, runA), isTrue);
      expect(registry.owns(reservationB, runB), isTrue);
    },
  );

  test(
    'final output remains database-scoped until its durable write commits',
    () {
      final registry = DirectRunRegistry();
      final key = _runKey('assistant-one', owner: 'chat-x');
      final reservation = registry.reserve(key, 'profile-one');
      const databaseA = 'openwebui:server-a';
      const databaseB = 'openwebui:server-b';
      final output = ChatMessage(
        id: 'assistant-one',
        role: 'assistant',
        content: 'Final answer',
        timestamp: DateTime.utc(2026, 7, 13),
      );

      registry.bindPersistenceIdentity(reservation, databaseA);
      registry.markOutputFinalized(reservation, output);

      expect(registry.isOutputFinalized(reservation), isTrue);
      expect(registry.isDurablyPersisted(reservation), isFalse);
      expect(registry.hasLiveIntent(key), isFalse);
      final retained = registry.retainedFinalizedOutput(key, databaseA);
      expect(retained?.message, output);
      expect(registry.retainedFinalizedOutput(key, databaseB), isNull);

      registry.releaseReservation(reservation);
      expect(registry.retainedFinalizedOutput(key, databaseA), same(retained));
      expect(registry.beginRetainedPersistenceRetry(retained!), isTrue);
      expect(registry.beginRetainedPersistenceRetry(retained), isFalse);
      registry.finishRetainedPersistenceRetry(retained, persisted: false);
      expect(registry.beginRetainedPersistenceRetry(retained), isTrue);
      registry.finishRetainedPersistenceRetry(retained, persisted: true);
      expect(registry.retainedFinalizedOutput(key, databaseA), isNull);
    },
  );

  test('retained final configuration rejects non-positive budgets', () {
    expect(
      () => DirectRunRegistry(maxRetainedFinalizedOutputs: 0),
      throwsArgumentError,
    );
    expect(
      () => DirectRunRegistry(maxRetainedFinalizedOutputBytes: 0),
      throwsArgumentError,
    );
  });

  test(
    'unique failed finals evict oldest-first and settle its waiter as terminal',
    () async {
      final registry = DirectRunRegistry(
        maxRetainedFinalizedOutputs: 2,
        maxRetainedFinalizedOutputBytes: 1024 * 1024,
      );
      final epochA = Object();
      final epochB = Object();
      final epochC = Object();
      final first = _markRetainedFinal(
        registry,
        assistantId: 'assistant-a',
        persistenceOwnerId: 'server-a',
        authSessionEpoch: epochA,
        content: 'first failed final',
      );
      final second = _markRetainedFinal(
        registry,
        assistantId: 'assistant-b',
        persistenceOwnerId: 'server-b',
        authSessionEpoch: epochB,
        content: 'second failed final',
      );
      final third = _markRetainedFinal(
        registry,
        assistantId: 'assistant-c',
        persistenceOwnerId: 'server-c',
        authSessionEpoch: epochC,
        content: 'third failed final',
      );

      await first.output.primaryPersistenceSettled.timeout(
        const Duration(seconds: 1),
      );
      registry.releaseReservation(first.reservation);

      expect(
        registry.retainedFinalizedOutput(
          first.key,
          'server-a',
          authSessionEpoch: epochA,
        ),
        isNull,
      );
      expect(registry.retainedFinalizedOutputIsCurrent(first.output), isFalse);
      expect(registry.beginRetainedPersistenceRetry(first.output), isFalse);
      expect(
        registry.retainedFinalizedOutput(
          second.key,
          'server-b',
          authSessionEpoch: epochB,
        ),
        same(second.output),
      );
      expect(
        registry.retainedFinalizedOutput(
          third.key,
          'server-c',
          authSessionEpoch: epochC,
        ),
        same(third.output),
      );
    },
  );

  test(
    'aggregate retained bytes deterministically evict the oldest final',
    () async {
      final registry = DirectRunRegistry(
        maxRetainedFinalizedOutputs: 10,
        maxRetainedFinalizedOutputBytes: 4096,
      );
      final first = _markRetainedFinal(
        registry,
        assistantId: 'large-a',
        persistenceOwnerId: 'database-a',
        content: List<String>.filled(1000, 'a').join(),
      );
      expect(
        registry.retainedFinalizedOutput(first.key, 'database-a'),
        same(first.output),
      );

      final second = _markRetainedFinal(
        registry,
        assistantId: 'large-b',
        persistenceOwnerId: 'database-b',
        content: List<String>.filled(1000, 'b').join(),
      );

      await first.output.primaryPersistenceSettled.timeout(
        const Duration(seconds: 1),
      );
      expect(registry.retainedFinalizedOutput(first.key, 'database-a'), isNull);
      expect(
        registry.retainedFinalizedOutput(second.key, 'database-b'),
        same(second.output),
      );
      expect(registry.beginRetainedPersistenceRetry(first.output), isFalse);
    },
  );

  test(
    'one oversized final is never retained or made retry eligible',
    () async {
      final registry = DirectRunRegistry(
        maxRetainedFinalizedOutputs: 10,
        maxRetainedFinalizedOutputBytes: 1024,
      );
      final oversized = _markRetainedFinal(
        registry,
        assistantId: 'oversized',
        persistenceOwnerId: 'database-a',
        content: List<String>.filled(5000, 'x').join(),
      );

      await oversized.output.primaryPersistenceSettled.timeout(
        const Duration(seconds: 1),
      );
      registry.releaseReservation(oversized.reservation);

      expect(
        registry.retainedFinalizedOutput(oversized.key, 'database-a'),
        isNull,
      );
      expect(
        registry.retainedFinalizedOutputIsCurrent(oversized.output),
        isFalse,
      );
      expect(registry.beginRetainedPersistenceRetry(oversized.output), isFalse);
      expect(registry.isOutputFinalized(oversized.reservation), isFalse);
    },
  );

  test('a replacement clears retained output only in its own database', () {
    final registry = DirectRunRegistry();
    final keyA = _runKey(
      'assistant-one',
      owner: 'conduit-direct-store://openWebUi/server-a/chat-x',
    );
    final keyB = _runKey(
      'assistant-one',
      owner: 'conduit-direct-store://openWebUi/server-b/chat-x',
    );
    const databaseA = 'openwebui:server-a';
    const databaseB = 'openwebui:server-b';
    final output = ChatMessage(
      id: 'assistant-one',
      role: 'assistant',
      content: 'Final answer',
      timestamp: DateTime.utc(2026, 7, 13),
    );

    final runA = registry.reserve(keyA, 'profile-one');
    registry.bindPersistenceIdentity(runA, databaseA);
    registry.markOutputFinalized(runA, output);
    registry.releaseReservation(runA);

    final runB = registry.reserve(keyB, 'profile-one');
    registry.bindPersistenceIdentity(runB, databaseB);
    registry.markOutputFinalized(runB, output.copyWith(content: 'Server B'));
    registry.releaseReservation(runB);

    final replacementA = registry.reserve(keyA, 'profile-one');
    registry.bindPersistenceIdentity(replacementA, databaseA);

    expect(registry.retainedFinalizedOutput(keyA, databaseA), isNull);
    expect(
      registry.retainedFinalizedOutput(keyB, databaseB)?.message.content,
      'Server B',
    );
  });

  test('retained OpenWebUI output is isolated by authentication epoch', () {
    final registry = DirectRunRegistry();
    final key = _runKey(
      'assistant-one',
      owner: 'conduit-direct-store://openWebUi/server-a/chat-x',
    );
    const persistenceOwner = 'server-a';
    final epochA = Object();
    final epochB = Object();
    final output = ChatMessage(
      id: 'assistant-one',
      role: 'assistant',
      content: 'User A final',
      timestamp: DateTime.utc(2026, 7, 13),
    );
    final reservation = registry.reserve(key, 'profile-one');
    registry.bindPersistenceIdentity(
      reservation,
      persistenceOwner,
      authSessionEpoch: epochA,
    );
    registry.markOutputFinalized(reservation, output);
    registry.releaseReservation(reservation);

    expect(
      registry
          .retainedFinalizedOutput(
            key,
            persistenceOwner,
            authSessionEpoch: epochA,
          )
          ?.message,
      output,
    );
    expect(
      registry.retainedFinalizedOutput(
        key,
        persistenceOwner,
        authSessionEpoch: epochB,
      ),
      isNull,
    );
  });

  test('new generation invalidates an already claimed retained retry', () {
    final registry = DirectRunRegistry();
    final key = _runKey('assistant-one', owner: 'server-a/chat-x');
    const persistenceOwner = 'server-a';
    final output = ChatMessage(
      id: 'assistant-one',
      role: 'assistant',
      content: 'Old final',
      timestamp: DateTime.utc(2026, 7, 13),
    );
    final old = registry.reserve(key, 'profile-one');
    registry.bindPersistenceIdentity(old, persistenceOwner);
    registry.markOutputFinalized(old, output);
    registry.releaseReservation(old);
    final retained = registry.retainedFinalizedOutput(key, persistenceOwner)!;
    expect(registry.beginRetainedPersistenceRetry(retained), isTrue);

    final replacement = registry.reserve(key, 'profile-one');

    expect(registry.retainedFinalizedOutput(key, persistenceOwner), isNull);
    expect(registry.retainedFinalizedOutputIsCurrent(retained), isFalse);
    registry.finishRetainedPersistenceRetry(retained, persisted: true);
    expect(registry.isLatest(replacement), isTrue);
  });

  test(
    'rebind moves stop and replacement ownership to the remapped chat',
    () async {
      final registry = DirectRunRegistry();
      final local = _runKey('assistant-one', owner: 'local:chat');
      final server = _runKey('assistant-one', owner: 'server-chat');
      final reservation = registry.reserve(local, 'profile-one');
      final token = CancelToken();
      final run = _run('run-one', token);
      expect(registry.register(reservation, run), isTrue);

      expect(registry.rebindIfVacant(reservation, server), isTrue);
      expect(registry.runFor(local), isNull);
      expect(registry.runFor(server), same(run));

      await registry.cancel(server);
      expect(token.isCancelled, isTrue);
      expect(registry.owns(reservation, run), isFalse);

      final replacement = registry.reserve(server, 'profile-one');
      expect(registry.isLatest(reservation), isFalse);
      expect(registry.isLatest(replacement), isTrue);
    },
  );

  test(
    'rebind collision preserves destination and revokes the moving run',
    () async {
      final registry = DirectRunRegistry();
      final source = _runKey('assistant-one', owner: 'local:chat');
      final destination = _runKey('assistant-one', owner: 'durable:chat');
      final moving = registry.reserve(source, 'profile-one');
      final movingToken = CancelToken();
      final movingRun = _run('moving-run', movingToken);
      expect(registry.register(moving, movingRun), isTrue);

      final existing = registry.reserve(destination, 'profile-two');
      final existingToken = CancelToken();
      final existingRun = _run('existing-run', existingToken);
      expect(registry.register(existing, existingRun), isTrue);

      expect(registry.rebindIfVacant(moving, destination), isFalse);
      await registry.cancellationSignal(moving);

      expect(movingToken.isCancelled, isTrue);
      expect(registry.runFor(source), isNull);
      expect(registry.isLatest(moving), isFalse);
      expect(registry.runFor(destination), same(existingRun));
      expect(registry.owns(existing, existingRun), isTrue);
      expect(existingToken.isCancelled, isFalse);

      registry.releaseReservation(moving);
      expect(registry.runFor(destination), same(existingRun));
      expect(registry.owns(existing, existingRun), isTrue);
    },
  );

  test(
    'retained destination also blocks rebind without being displaced',
    () async {
      final registry = DirectRunRegistry();
      final destination = _runKey('assistant-one', owner: 'durable:chat');
      const persistenceOwner = 'database-one';
      final existing = registry.reserve(destination, 'profile-one');
      registry.bindPersistenceIdentity(existing, persistenceOwner);
      final retained = registry.markOutputFinalized(
        existing,
        ChatMessage(
          id: 'assistant-one',
          role: 'assistant',
          content: 'Existing durable-chat final',
          timestamp: DateTime.utc(2026, 7, 13),
        ),
      )!;
      registry.releaseReservation(existing);

      final source = _runKey('assistant-one', owner: 'local:chat');
      final moving = registry.reserve(source, 'profile-two');
      final movingToken = CancelToken();
      final movingRun = _run('moving-run', movingToken);
      expect(registry.register(moving, movingRun), isTrue);

      expect(registry.rebindIfVacant(moving, destination), isFalse);
      await registry.cancellationSignal(moving);

      expect(movingToken.isCancelled, isTrue);
      expect(registry.runFor(source), isNull);
      expect(
        registry.retainedFinalizedOutput(destination, persistenceOwner),
        same(retained),
      );
    },
  );

  test(
    'successful rebind keeps retained final retry settlement addressable',
    () async {
      final registry = DirectRunRegistry();
      final source = _runKey('assistant-one', owner: 'local:chat');
      final destination = _runKey('assistant-one', owner: 'durable:chat');
      const persistenceOwner = 'database-one';
      final reservation = registry.reserve(source, 'profile-one');
      registry.bindPersistenceIdentity(reservation, persistenceOwner);
      final retained = registry.markOutputFinalized(
        reservation,
        ChatMessage(
          id: 'assistant-one',
          role: 'assistant',
          content: 'Final after remap',
          timestamp: DateTime.utc(2026, 7, 13),
        ),
      )!;

      expect(registry.rebindIfVacant(reservation, destination), isTrue);
      expect(
        registry.retainedFinalizedOutput(source, persistenceOwner),
        isNull,
      );
      expect(
        registry.retainedFinalizedOutput(destination, persistenceOwner),
        same(retained),
      );
      expect(registry.retainedFinalizedOutputIsCurrent(retained), isTrue);

      registry.releaseReservation(reservation);
      await retained.primaryPersistenceSettled;
      expect(registry.beginRetainedPersistenceRetry(retained), isTrue);
      registry.finishRetainedPersistenceRetry(retained, persisted: false);
      expect(registry.beginRetainedPersistenceRetry(retained), isTrue);
      registry.finishRetainedPersistenceRetry(retained, persisted: true);

      expect(
        registry.retainedFinalizedOutput(destination, persistenceOwner),
        isNull,
      );
      expect(registry.retainedFinalizedOutputIsCurrent(retained), isFalse);
      expect(registry.beginRetainedPersistenceRetry(retained), isFalse);
    },
  );

  test('durable settlement evicts a retained final after rebind', () async {
    final registry = DirectRunRegistry();
    final source = _runKey('assistant-one', owner: 'local:chat');
    final destination = _runKey('assistant-one', owner: 'durable:chat');
    const persistenceOwner = 'database-one';
    final reservation = registry.reserve(source, 'profile-one');
    registry.bindPersistenceIdentity(reservation, persistenceOwner);
    final retained = registry.markOutputFinalized(
      reservation,
      ChatMessage(
        id: 'assistant-one',
        role: 'assistant',
        content: 'Persisted after remap',
        timestamp: DateTime.utc(2026, 7, 13),
      ),
    )!;

    expect(registry.rebindIfVacant(reservation, destination), isTrue);
    registry.markDurablyPersisted(reservation);
    await retained.primaryPersistenceSettled;

    expect(registry.isDurablyPersisted(reservation), isTrue);
    expect(
      registry.retainedFinalizedOutput(destination, persistenceOwner),
      isNull,
    );
    expect(registry.retainedFinalizedOutputIsCurrent(retained), isFalse);
    expect(registry.beginRetainedPersistenceRetry(retained), isFalse);
  });

  test(
    'collision discards and terminally settles a moving retained final',
    () async {
      final registry = DirectRunRegistry();
      final source = _runKey('assistant-one', owner: 'local:chat');
      final destination = _runKey('assistant-one', owner: 'durable:chat');
      const persistenceOwner = 'database-one';
      final moving = registry.reserve(source, 'profile-one');
      registry.bindPersistenceIdentity(moving, persistenceOwner);
      final retained = registry.markOutputFinalized(
        moving,
        ChatMessage(
          id: 'assistant-one',
          role: 'assistant',
          content: 'Conflicting final',
          timestamp: DateTime.utc(2026, 7, 13),
        ),
      )!;
      final destinationOwner = registry.reserve(destination, 'profile-two');

      expect(registry.rebindIfVacant(moving, destination), isFalse);
      await retained.primaryPersistenceSettled;

      expect(registry.isLatest(moving), isFalse);
      expect(registry.isLatest(destinationOwner), isTrue);
      final destinationToken = CancelToken();
      final destinationRun = _run('destination-run', destinationToken);
      expect(registry.register(destinationOwner, destinationRun), isTrue);
      expect(registry.owns(destinationOwner, destinationRun), isTrue);
      expect(destinationToken.isCancelled, isFalse);
      expect(
        registry.retainedFinalizedOutput(source, persistenceOwner),
        isNull,
      );
      expect(registry.retainedFinalizedOutputIsCurrent(retained), isFalse);
      expect(registry.beginRetainedPersistenceRetry(retained), isFalse);
    },
  );
}

DirectRunKey _runKey(String assistantMessageId, {String owner = 'chat-one'}) =>
    (ownerConversationId: owner, assistantMessageId: assistantMessageId);

({
  DirectRunKey key,
  DirectRunReservation reservation,
  DirectFinalizedOutput output,
})
_markRetainedFinal(
  DirectRunRegistry registry, {
  required String assistantId,
  required String persistenceOwnerId,
  required String content,
  Object? authSessionEpoch,
}) {
  final key = _runKey(assistantId, owner: 'owner-$assistantId');
  final reservation = registry.reserve(key, 'profile-one');
  registry.bindPersistenceIdentity(
    reservation,
    persistenceOwnerId,
    authSessionEpoch: authSessionEpoch,
  );
  final output = registry.markOutputFinalized(
    reservation,
    ChatMessage(
      id: assistantId,
      role: 'assistant',
      content: content,
      timestamp: DateTime.utc(2026, 7, 13),
    ),
  )!;
  return (key: key, reservation: reservation, output: output);
}

DirectCompletionRun _run(String id, CancelToken cancelToken) =>
    _runWithDone(id, cancelToken, Future<void>.value());

DirectCompletionRun _runWithDone(
  String id,
  CancelToken cancelToken,
  Future<void> done, {
  String profileId = 'profile-one',
}) => DirectCompletionRun(
  id: id,
  profileId: profileId,
  remoteModelId: 'model-one',
  events: const Stream<DirectStreamEvent>.empty(),
  cancelToken: cancelToken,
  done: done,
);

final class _Adapter implements DirectProviderAdapter {
  const _Adapter(this.key);

  @override
  final String key;

  @override
  Future<List<DirectRemoteModel>> listModels(
    DirectConnectionProfile profile,
  ) async => const [];

  @override
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) async =>
      const DirectConnectionProbe(reachable: true);

  @override
  DirectCompletionRun startCompletion(
    DirectConnectionProfile profile,
    DirectCompletionRequest request,
  ) => throw UnimplementedError();
}
