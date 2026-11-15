@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show openWebUiChatSettingsAccessProvider;
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/models/direct_remote_model.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart'
    show directModelRegistryProvider;
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart'
    show hermesFastTierSelectionProvider;
import 'package:conduit_core/models/model.dart' as core;
import 'package:conduit_core/models/openwebui_chat_settings.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/server_user_settings.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _cached = core.Model(id: 'cached-model', name: 'Cached model');

/// The core's model list with the server out of reach: the cached list
/// first, then the refresh behind it fails, and the list stays beside the
/// error.
final class _Unreachable extends Models {
  @override
  Future<List<core.Model>> build() async => const [_cached];

  /// What the refresh behind the cached list leaves.
  void refreshFailed() => state = AsyncError<List<core.Model>>(
    const SocketException('No route to host'),
    StackTrace.current,
  );
}

/// A server offering two models.
final class _Listed extends Models {
  @override
  Future<List<core.Model>> build() async => const [
    core.Model(id: 'first-model', name: 'First model'),
    core.Model(id: 'preferred-model', name: 'Preferred'),
  ];
}

/// Two Hermes models that both offer the Fast tier.
final class _Fast extends Models {
  @override
  Future<List<core.Model>> build() async => const [
    core.Model(id: 'fast-a', name: 'Fast A', metadata: {'hermesFast': true}),
    core.Model(id: 'fast-b', name: 'Fast B', metadata: {'hermesFast': true}),
  ];
}

/// The account's settings on its server, loaded once [loaded] completes.
final class _Personal extends PersonalizationSettings {
  _Personal(this.loaded);

  final Future<void> loaded;
  final toggled = <String>[];

  @override
  Future<ServerUserSettings> build() async {
    await loaded;
    return const ServerUserSettings();
  }

  @override
  Future<ServerUserSettings> togglePinnedModel(String modelId) async {
    toggled.add(modelId);
    return const ServerUserSettings();
  }
}

/// A server offering exactly [models].
final class _These extends Models {
  _These(this.models);

  final List<core.Model> models;

  @override
  Future<List<core.Model>> build() async => models;
}

/// A server offering two models once [listed] completes.
final class _Held extends Models {
  _Held(this.listed);

  final Future<void> listed;

  @override
  Future<List<core.Model>> build() async {
    await listed;
    return const [
      core.Model(id: 'first-model', name: 'First model'),
      core.Model(id: 'preferred-model', name: 'Preferred'),
    ];
  }
}

/// Account A's one model while [first] is the session, held until [listed];
/// any other session's is B's.
final class _PerAccount extends Models {
  _PerAccount(this.first, this.listed);

  final Object first;
  final Future<void> listed;

  @override
  Future<List<core.Model>> build() async {
    if (!identical(ref.watch(openWebUiAuthSessionEpochProvider), first)) {
      return const [core.Model(id: 'b-model', name: 'B model')];
    }
    await listed;
    return const [core.Model(id: 'a-model', name: 'A model')];
  }
}

/// Signed out, or never signed in: there is no list to fall back on.
final class _Failing extends Models {
  @override
  Future<List<core.Model>> build() async =>
      throw const SocketException('No route to host');
}

void main() {
  test('an unreachable server leaves the cached models on offer', () async {
    final container = ProviderContainer(
      overrides: [modelsProvider.overrideWith(_Unreachable.new)],
    );
    addTearDown(container.dispose);
    container.listen(modelsProvider, (_, _) {});
    await container.read(modelsProvider.future);
    (container.read(modelsProvider.notifier) as _Unreachable).refreshFailed();
    expect(container.read(modelsProvider).hasError, isTrue);

    final list = await ModelsService(container).list();

    expect(list.models.map((model) => model.id), [_cached.id]);
  });

  test('with nothing chosen, the account default is the selection', () async {
    const first = core.Model(id: 'first-model', name: 'First model');
    const preferred = core.Model(id: 'preferred-model', name: 'Preferred');
    final container = ProviderContainer(
      overrides: [
        modelsProvider.overrideWith(_Listed.new),
        // The user's settings name a model that the server lists last.
        defaultModelProvider.overrideWith((ref) async => preferred),
      ],
    );
    addTearDown(container.dispose);

    final list = await ModelsService(container).list();

    expect(list.models.first.id, first.id);
    expect(list.selectedId, preferred.id);
    expect((await currentModel(container))?.id, preferred.id);

    // A model picked in the window wins over the default.
    final picked = await ModelsService(container).select(first.id);
    expect(picked.selectedId, first.id);
  });

  test('a default that cannot resolve leaves nothing chosen', () async {
    final container = ProviderContainer(
      overrides: [
        modelsProvider.overrideWith(_Listed.new),
        defaultModelProvider.overrideWith(
          (ref) async => throw StateError('settings unavailable'),
        ),
      ],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);

    final list = await ModelsService(container).list();

    expect(list.models, hasLength(2));
    expect(list.selectedId, isNull);
  });

  Matcher refused(String code) =>
      throwsA(isA<RpcError>().having((e) => e.code, 'code', code));

  test('a reasoning pick asked under one account is not made under the next',
      () async {
    var account = Object();
    final listed = Completer<void>();
    final container = ProviderContainer(
      overrides: [
        modelsProvider.overrideWith(() => _Held(listed.future)),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => account),
      ],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);
    final picking = ModelsService(container).setReasoningEffort(
      const SetReasoningEffort(modelId: 'first-model', effort: 'high'),
    );
    // Another account signs in while the model is looked up.
    account = Object();
    container.invalidate(openWebUiAuthSessionEpochProvider);
    listed.complete();
    await expectLater(picking, refused(ConduitErrorCodes.sessionExpired));
  });

  test('a pick for a chat that cannot be read is refused', () async {
    final container = ProviderContainer(
      overrides: [
        modelsProvider.overrideWith(_Listed.new),
        loadConversationProvider.overrideWith(
          (ref, id) async => throw StateError('no chat $id here'),
        ),
      ],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);

    await expectLater(
      ModelsService(container).setReasoningEffort(
        const SetReasoningEffort(
          modelId: 'first-model',
          effort: 'high',
          chatId: 'gone',
        ),
      ),
      refused(ConduitErrorCodes.notFound),
    );
  });

  // `turns.send` with a new chat's settings, as `chatSettings.save` would
  // write them: only what the account may change.
  test("a new chat's settings keep to the account's rights", () async {
    final container = ProviderContainer(
      overrides: [
        modelsProvider.overrideWith(_Listed.new),
        openWebUiChatSettingsAccessProvider.overrideWith(
          (ref) async => const OpenWebUiChatSettingsAccess(
            canEditSystemPrompt: false,
            canEditParameters: true,
          ),
        ),
      ],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);
    final turns = TurnsService(container, EventBus());
    addTearDown(turns.dispose);
    await expectLater(
      turns.send(
        const SendTurn(
          model: 'first-model',
          text: 'Hello',
          chatParams: <String, dynamic>{'system': 'Answer in riddles.'},
        ),
      ),
      refused(ConduitErrorCodes.unauthorized),
    );
  });

  // A server's own connection is still the server's chat: its settings
  // keep to the account's rights as any Open WebUI chat's do.
  test("a new chat on a server connection's model keeps to the rights",
      () async {
    final registry = DirectModelRegistry();
    final served = registry
        .replaceProfileModels(
          DirectConnectionProfile(
            id: 'server-connection',
            name: 'Server connection',
            adapterKey: kOpenAiCompatibleAdapterKey,
            baseUrl: 'https://models.invalid/v1',
          ),
          [DirectRemoteModel(id: 'served-model')],
          source: DirectModelSource.openWebUi,
          openWebUiUrlIndex: 0,
        )
        .single;
    final container = ProviderContainer(
      overrides: [
        directModelRegistryProvider.overrideWithValue(registry),
        modelsProvider.overrideWith(() => _These(<core.Model>[served])),
        openWebUiChatSettingsAccessProvider.overrideWith(
          (ref) async => const OpenWebUiChatSettingsAccess(
            canEditSystemPrompt: false,
            canEditParameters: true,
          ),
        ),
      ],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);
    final turns = TurnsService(container, EventBus());
    addTearDown(turns.dispose);
    await expectLater(
      turns.send(
        SendTurn(
          model: served.id,
          text: 'Hello',
          chatParams: const <String, dynamic>{'system': 'Answer in riddles.'},
        ),
      ),
      refused(ConduitErrorCodes.unauthorized),
    );
  });

  test("a new chat's settings checked for one account are never sent under "
      'the next', () async {
    var account = Object();
    final rights = Completer<OpenWebUiChatSettingsAccess>();
    final asked = Completer<void>();
    final container = ProviderContainer(
      overrides: [
        modelsProvider.overrideWith(_Listed.new),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => account),
        openWebUiChatSettingsAccessProvider.overrideWith((ref) {
          if (!asked.isCompleted) asked.complete();
          return rights.future;
        }),
      ],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);
    container.read(openWebUiAuthSessionEpochProvider);
    final turns = TurnsService(container, EventBus());
    addTearDown(turns.dispose);
    final sending = turns.send(
      const SendTurn(
        model: 'first-model',
        text: 'Hello',
        chatParams: <String, dynamic>{'system': 'Answer in riddles.'},
      ),
    );
    // Another account signs in while the rights are read.
    await asked.future;
    account = Object();
    container.invalidate(openWebUiAuthSessionEpochProvider);
    container.read(openWebUiAuthSessionEpochProvider);
    rights.complete(
      const OpenWebUiChatSettingsAccess(
        canEditSystemPrompt: true,
        canEditParameters: true,
      ),
    );
    await expectLater(sending, refused(ConduitErrorCodes.sessionExpired));
  });

  test("a list started under one account never offers its models to the "
      'next', () async {
    final first = Object();
    var account = first;
    final listed = Completer<void>();
    final loaded = Completer<void>();
    final container = ProviderContainer(
      overrides: [
        modelsProvider.overrideWith(() => _PerAccount(first, listed.future)),
        apiServiceProvider.overrideWithValue(
          ApiService(
            serverConfig: const ServerConfig(
              id: 'server',
              name: 'Home server',
              url: 'https://home.invalid',
            ),
            workerManager: WorkerManager(),
          ),
        ),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => account),
        personalizationSettingsProvider.overrideWith(
          () => _Personal(loaded.future),
        ),
        effectivePinnedModelIdsProvider.overrideWithValue(const <String>[]),
      ],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);
    container.listen(personalizationSettingsProvider, (_, _) {});
    final listing = ModelsService(container).list();
    listed.complete();
    // A's models are in; another account signs in while the account's
    // settings load.
    await container.read(modelsProvider.future);
    account = Object();
    container.invalidate(openWebUiAuthSessionEpochProvider);
    loaded.complete();
    final list = await listing;
    expect(list.models.map((m) => m.id), <String>['b-model']);
  });

  test('a pin asked for under one account is not made under the next',
      () async {
    var account = Object();
    final loaded = Completer<void>();
    final settings = _Personal(loaded.future);
    final container = ProviderContainer(
      overrides: [
        modelsProvider.overrideWith(_Listed.new),
        apiServiceProvider.overrideWithValue(
          ApiService(
            serverConfig: const ServerConfig(
              id: 'server',
              name: 'Home server',
              url: 'https://home.invalid',
            ),
            workerManager: WorkerManager(),
          ),
        ),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => account),
        personalizationSettingsProvider.overrideWith(() => settings),
        effectivePinnedModelIdsProvider.overrideWithValue(const <String>[]),
        canTogglePinnedModelsProvider.overrideWithValue(true),
      ],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);
    container.listen(personalizationSettingsProvider, (_, _) {});
    final pinning = ModelsService(
      container,
    ).setPinned(const SetModelPinned(id: 'first-model', pinned: true));
    // Another account signs in while the account's settings load.
    account = Object();
    container.invalidate(openWebUiAuthSessionEpochProvider);
    loaded.complete();
    await expectLater(pinning, refused(ConduitErrorCodes.sessionExpired));
    expect(settings.toggled, isEmpty);
  });

  test("another model's Fast tier request changes nothing", () async {
    final container = ProviderContainer(
      overrides: [modelsProvider.overrideWith(_Fast.new)],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);
    final models = ModelsService(container);
    await models.select('fast-a');

    await expectLater(
      models.setFastTier(const SetFastTier(modelId: 'fast-b', on: true)),
      refused(ConduitErrorCodes.invalidParams),
    );
    await expectLater(
      models.setFastTier(const SetFastTier(modelId: 'unknown', on: true)),
      refused(ConduitErrorCodes.invalidParams),
    );
    expect(container.read(hermesFastTierSelectionProvider), isFalse);
  });

  test('with no list at all, the failure is the answer', () async {
    final container = ProviderContainer(
      overrides: [modelsProvider.overrideWith(_Failing.new)],
      retry: (_, _) => null,
    );
    addTearDown(container.dispose);

    await expectLater(
      ModelsService(container).list(),
      throwsA(isA<SocketException>()),
    );
  });
}
