import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/models/server_user_settings.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/settings_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _serverConfig = ServerConfig(
  id: 'test-server',
  name: 'Test Server',
  url: 'https://example.com',
  isActive: true,
);

const _secondServerConfig = ServerConfig(
  id: 'second-server',
  name: 'Second Server',
  url: 'https://second.example.com',
  isActive: true,
);

void main() {
  group('PersonalizationSettings pinned models', () {
    test('no-API toggle preserves existing local pins', () async {
      final container = _container(
        api: null,
        appSettings: const AppSettings(pinnedModels: ['local-a']),
        activeServer: null,
      );
      addTearDown(container.dispose);

      final initial = await container.read(
        personalizationSettingsProvider.future,
      );
      check(initial.pinnedModelIds).deepEquals(['local-a']);

      await container
          .read(personalizationSettingsProvider.notifier)
          .togglePinnedModel('local-b');

      check(
        container
            .read(personalizationSettingsProvider)
            .requireValue
            .pinnedModelIds,
      ).deepEquals(['local-a', 'local-b']);
      check(
        container.read(appSettingsProvider).pinnedModels,
      ).deepEquals(['local-a', 'local-b']);
    });

    test('stale server response cannot overwrite latest pin intent', () async {
      final api = _PinnedModelsApiService();
      addTearDown(api.dispose);
      final container = _container(
        api: api,
        appSettings: const AppSettings(),
        activeServer: _serverConfig,
      );
      addTearDown(container.dispose);

      await container.read(personalizationSettingsProvider.future);
      final notifier = container.read(personalizationSettingsProvider.notifier);

      final firstWrite = notifier.setPinnedModels(['first']);
      await api.waitForRequestCount(1);

      final secondWrite = notifier.setPinnedModels(['second']);
      await api.waitForRequestCount(2);

      api.completeRequest(1, ['second']);
      await secondWrite;

      api.completeRequest(0, ['first']);
      await firstWrite;

      check(
        container
            .read(personalizationSettingsProvider)
            .requireValue
            .pinnedModelIds,
      ).deepEquals(['second']);
      check(
        container.read(appSettingsProvider).pinnedModels,
      ).deepEquals(['second']);
    });

    test(
      'stale settings read cannot overwrite optimistic pin intent',
      () async {
        final api = _PinnedModelsApiService(delaySettingsReads: true);
        addTearDown(api.dispose);
        final container = _container(
          api: api,
          appSettings: const AppSettings(),
          activeServer: _serverConfig,
        );
        addTearDown(container.dispose);

        final initialRead = container.read(
          personalizationSettingsProvider.future,
        );
        await api.waitForSettingsReadCount(1);

        final pinWrite = container
            .read(personalizationSettingsProvider.notifier)
            .setPinnedModels(['new-pin']);
        await api.waitForRequestCount(1);

        api.completeSettingsRead(0, ['old-pin']);
        final loaded = await initialRead;

        check(loaded.pinnedModelIds).deepEquals(['new-pin']);
        check(
          container
              .read(personalizationSettingsProvider)
              .requireValue
              .pinnedModelIds,
        ).deepEquals(['new-pin']);
        check(
          container.read(appSettingsProvider).pinnedModels,
        ).deepEquals(['new-pin']);

        api.completeRequest(0, ['new-pin']);
        await pinWrite;
      },
    );

    test(
      'server toggle while loading does not post pins from previous server',
      () async {
        final firstApi = _PinnedModelsApiService(
          delaySettingsReads: true,
          serverConfig: _serverConfig,
        );
        final secondApi = _PinnedModelsApiService(
          delaySettingsReads: true,
          serverConfig: _secondServerConfig,
        );
        addTearDown(firstApi.dispose);
        addTearDown(secondApi.dispose);
        final activeServer =
            NotifierProvider<_ActiveServerNotifier, ServerConfig?>(
              () => _ActiveServerNotifier(_serverConfig),
            );
        final container = _container(
          api: null,
          apiOverride: (ref) {
            final server = ref.watch(activeServer);
            return switch (server?.id) {
              'test-server' => firstApi,
              'second-server' => secondApi,
              _ => null,
            };
          },
          appSettings: const AppSettings(pinnedModels: ['previous-pin']),
          activeServer: _serverConfig,
          activeServerOverride: activeServer,
        );
        addTearDown(container.dispose);

        final initialRead = container.read(
          personalizationSettingsProvider.future,
        );
        await firstApi.waitForSettingsReadCount(1);
        firstApi.completeSettingsRead(0, ['previous-pin']);
        await initialRead;

        container.read(activeServer.notifier).set(_secondServerConfig);
        final switchedRead = container.read(
          personalizationSettingsProvider.future,
        );
        await secondApi.waitForSettingsReadCount(1);

        check(container.read(canTogglePinnedModelsProvider)).isFalse();
        check(
          container.read(effectivePinnedModelIdsProvider),
        ).deepEquals(['previous-pin']);

        final pinResult = await container
            .read(personalizationSettingsProvider.notifier)
            .togglePinnedModel('second-pin');
        await _flushMicrotasks();

        check(pinResult.pinnedModelIds).isEmpty();
        check(secondApi.requestCount).equals(0);
        check(
          container.read(appSettingsProvider).pinnedModels,
        ).deepEquals(['previous-pin']);

        secondApi.completeSettingsRead(0, ['server-b-pin']);
        final loaded = await switchedRead;

        check(loaded.pinnedModelIds).deepEquals(['server-b-pin']);
        check(
          container
              .read(personalizationSettingsProvider)
              .requireValue
              .pinnedModelIds,
        ).deepEquals(['server-b-pin']);
        await _flushMicrotasks();
        check(
          container.read(appSettingsProvider).pinnedModels,
        ).deepEquals(['server-b-pin']);
        check(container.read(canTogglePinnedModelsProvider)).isTrue();
      },
    );

    test(
      'API loading with local pinned cache disables toggle writes',
      () async {
        final api = _PinnedModelsApiService(
          delaySettingsReads: true,
          serverConfig: _serverConfig,
        );
        addTearDown(api.dispose);
        final container = _container(
          api: api,
          appSettings: const AppSettings(pinnedModels: ['cached-pin']),
          activeServer: _serverConfig,
        );
        addTearDown(container.dispose);

        final initialRead = container.read(
          personalizationSettingsProvider.future,
        );
        await api.waitForSettingsReadCount(1);

        check(
          container.read(effectivePinnedModelIdsProvider),
        ).deepEquals(['cached-pin']);
        check(container.read(canTogglePinnedModelsProvider)).isFalse();

        final unpinResult = await container
            .read(personalizationSettingsProvider.notifier)
            .togglePinnedModel('cached-pin');
        await _flushMicrotasks();

        check(unpinResult.pinnedModelIds).isEmpty();
        check(api.requestCount).equals(0);
        check(
          container.read(appSettingsProvider).pinnedModels,
        ).deepEquals(['cached-pin']);

        api.completeSettingsRead(0, ['server-pin']);
        final loaded = await initialRead;

        check(loaded.pinnedModelIds).deepEquals(['server-pin']);
        await _flushMicrotasks();
        check(
          container.read(appSettingsProvider).pinnedModels,
        ).deepEquals(['server-pin']);
        check(container.read(canTogglePinnedModelsProvider)).isTrue();
      },
    );

    test(
      'write response after server switch does not overwrite active server pins',
      () async {
        final firstApi = _PinnedModelsApiService(serverConfig: _serverConfig);
        final secondApi = _PinnedModelsApiService(
          delaySettingsReads: true,
          serverConfig: _secondServerConfig,
        );
        addTearDown(firstApi.dispose);
        addTearDown(secondApi.dispose);
        final activeServer =
            NotifierProvider<_ActiveServerNotifier, ServerConfig?>(
              () => _ActiveServerNotifier(_serverConfig),
            );
        final container = _container(
          api: null,
          apiOverride: (ref) {
            final server = ref.watch(activeServer);
            return switch (server?.id) {
              'test-server' => firstApi,
              'second-server' => secondApi,
              _ => null,
            };
          },
          appSettings: const AppSettings(),
          activeServer: _serverConfig,
          activeServerOverride: activeServer,
        );
        addTearDown(container.dispose);

        await container.read(personalizationSettingsProvider.future);

        final writeOnFirstServer = container
            .read(personalizationSettingsProvider.notifier)
            .setPinnedModels(['server-a-pin']);
        await firstApi.waitForRequestCount(1);
        check(firstApi.requestModelIds(0)).deepEquals(['server-a-pin']);

        container.read(activeServer.notifier).set(_secondServerConfig);
        final switchedRead = container.read(
          personalizationSettingsProvider.future,
        );
        await secondApi.waitForSettingsReadCount(1);
        secondApi.completeSettingsRead(0, ['server-b-pin']);
        final loaded = await switchedRead;

        check(loaded.pinnedModelIds).deepEquals(['server-b-pin']);
        await _flushMicrotasks();
        check(
          container.read(appSettingsProvider).pinnedModels,
        ).deepEquals(['server-b-pin']);

        firstApi.completeRequest(0, ['server-a-pin']);
        final staleWriteResult = await writeOnFirstServer;

        check(staleWriteResult.pinnedModelIds).deepEquals(['server-b-pin']);
        check(
          container
              .read(personalizationSettingsProvider)
              .requireValue
              .pinnedModelIds,
        ).deepEquals(['server-b-pin']);
        await _flushMicrotasks();
        check(
          container.read(appSettingsProvider).pinnedModels,
        ).deepEquals(['server-b-pin']);
      },
    );

    test(
      'settings read after server switch does not overwrite active server pins',
      () async {
        final firstApi = _PinnedModelsApiService(
          delaySettingsReads: true,
          serverConfig: _serverConfig,
        );
        final secondApi = _PinnedModelsApiService(
          delaySettingsReads: true,
          serverConfig: _secondServerConfig,
        );
        addTearDown(firstApi.dispose);
        addTearDown(secondApi.dispose);
        final activeServer =
            NotifierProvider<_ActiveServerNotifier, ServerConfig?>(
              () => _ActiveServerNotifier(_serverConfig),
            );
        final container = _container(
          api: null,
          apiOverride: (ref) {
            final server = ref.watch(activeServer);
            return switch (server?.id) {
              'test-server' => firstApi,
              'second-server' => secondApi,
              _ => null,
            };
          },
          appSettings: const AppSettings(),
          activeServer: _serverConfig,
          activeServerOverride: activeServer,
        );
        addTearDown(container.dispose);

        final readOnFirstServer = container.read(
          personalizationSettingsProvider.future,
        );
        await firstApi.waitForSettingsReadCount(1);

        container.read(activeServer.notifier).set(_secondServerConfig);
        final switchedRead = container.read(
          personalizationSettingsProvider.future,
        );
        await secondApi.waitForSettingsReadCount(1);

        secondApi.completeSettingsRead(0, ['server-b-pin']);
        final loaded = await switchedRead;

        check(loaded.pinnedModelIds).deepEquals(['server-b-pin']);
        await _flushMicrotasks();
        check(
          container.read(appSettingsProvider).pinnedModels,
        ).deepEquals(['server-b-pin']);

        firstApi.completeSettingsRead(0, ['server-a-pin']);
        final staleReadResult = await readOnFirstServer;

        check(staleReadResult.pinnedModelIds).deepEquals(['server-b-pin']);
        check(
          container
              .read(personalizationSettingsProvider)
              .requireValue
              .pinnedModelIds,
        ).deepEquals(['server-b-pin']);
        await _flushMicrotasks();
        check(
          container.read(appSettingsProvider).pinnedModels,
        ).deepEquals(['server-b-pin']);
      },
    );
  });
}

ProviderContainer _container({
  required _PinnedModelsApiService? api,
  ApiService? Function(Ref ref)? apiOverride,
  required AppSettings appSettings,
  required ServerConfig? activeServer,
  NotifierProvider<_ActiveServerNotifier, ServerConfig?>? activeServerOverride,
}) {
  return ProviderContainer(
    overrides: [
      if (apiOverride == null)
        apiServiceProvider.overrideWithValue(api)
      else
        apiServiceProvider.overrideWith(apiOverride),
      appSettingsProvider.overrideWith(
        () => _TestAppSettingsNotifier(appSettings),
      ),
      activeServerProvider.overrideWith((ref) {
        final override = activeServerOverride;
        if (override != null) {
          return ref.watch(override);
        }
        return activeServer;
      }),
    ],
  );
}

class _TestAppSettingsNotifier extends AppSettingsNotifier {
  _TestAppSettingsNotifier(this._initial);

  final AppSettings _initial;

  @override
  AppSettings build() => _initial;

  @override
  Future<void> setPinnedModels(List<String> modelIds) async {
    state = state.copyWith(
      pinnedModels: SettingsService.sanitizePinnedModels(modelIds),
    );
  }
}

class _ActiveServerNotifier extends Notifier<ServerConfig?> {
  _ActiveServerNotifier(this._initial);

  final ServerConfig? _initial;

  @override
  ServerConfig? build() => _initial;

  void set(ServerConfig? server) {
    state = server;
  }
}

class _PinnedModelsApiService extends ApiService {
  _PinnedModelsApiService._(
    this._workerManager, {
    required this.delaySettingsReads,
    required super.serverConfig,
  }) : super(workerManager: _workerManager);

  factory _PinnedModelsApiService({
    bool delaySettingsReads = false,
    ServerConfig serverConfig = _serverConfig,
  }) => _PinnedModelsApiService._(
    WorkerManager(maxConcurrentTasks: 1),
    delaySettingsReads: delaySettingsReads,
    serverConfig: serverConfig,
  );

  final WorkerManager _workerManager;
  final bool delaySettingsReads;
  final List<_SettingsReadRequest> _settingsReadRequests = [];
  final List<void Function()> _settingsReadWaiters = [];
  final List<_PinnedModelsRequest> _requests = [];
  final List<void Function()> _requestWaiters = [];

  void dispose() {
    _workerManager.dispose();
  }

  @override
  Future<ServerUserSettings> getServerUserSettingsModel() {
    if (!delaySettingsReads) {
      return Future.value(const ServerUserSettings());
    }
    final request = _SettingsReadRequest();
    _settingsReadRequests.add(request);
    for (final notify in _settingsReadWaiters.toList(growable: false)) {
      notify();
    }
    return request.completer.future;
  }

  @override
  Future<ServerUserSettings> updateUserPinnedModels(List<String> modelIds) {
    final request = _PinnedModelsRequest(modelIds);
    _requests.add(request);
    for (final notify in _requestWaiters.toList(growable: false)) {
      notify();
    }
    return request.completer.future;
  }

  Future<void> waitForRequestCount(int count) async {
    await _waitForCount(
      count: count,
      currentCount: () => _requests.length,
      waiters: _requestWaiters,
    );
  }

  Future<void> waitForSettingsReadCount(int count) async {
    await _waitForCount(
      count: count,
      currentCount: () => _settingsReadRequests.length,
      waiters: _settingsReadWaiters,
    );
  }

  int get requestCount => _requests.length;

  void completeRequest(int index, List<String> pinnedModelIds) {
    _requests[index].completer.complete(
      ServerUserSettings(pinnedModelIds: pinnedModelIds),
    );
  }

  List<String> requestModelIds(int index) {
    return _requests[index].modelIds;
  }

  void completeSettingsRead(int index, List<String> pinnedModelIds) {
    _settingsReadRequests[index].completer.complete(
      ServerUserSettings(pinnedModelIds: pinnedModelIds),
    );
  }
}

Future<void> _waitForCount({
  required int count,
  required int Function() currentCount,
  required List<void Function()> waiters,
}) async {
  while (currentCount() < count) {
    final completer = Completer<void>();
    void notify() {
      if (!completer.isCompleted) {
        completer.complete();
      }
    }

    waiters.add(notify);
    await completer.future;
    waiters.remove(notify);
  }
}

class _SettingsReadRequest {
  _SettingsReadRequest();

  final Completer<ServerUserSettings> completer =
      Completer<ServerUserSettings>();
}

class _PinnedModelsRequest {
  _PinnedModelsRequest(List<String> modelIds)
    : modelIds = List.unmodifiable(modelIds);

  final List<String> modelIds;
  final Completer<ServerUserSettings> completer =
      Completer<ServerUserSettings>();
}

Future<void> _flushMicrotasks() async {
  await Future<void>.delayed(Duration.zero);
}
