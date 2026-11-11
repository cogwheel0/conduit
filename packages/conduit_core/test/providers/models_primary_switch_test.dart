import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/librechat/models/librechat_model.dart';
import 'package:conduit_core/features/librechat/providers/librechat_model_providers.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _openWebUiModel = Model(id: 'owui-model', name: 'Server model');

/// The Open WebUI list the device holds: what the models show once Open
/// WebUI is the primary account again.
final class _Storage implements OptimizedStorageService {
  @override
  Future<List<Model>> getLocalModels() async => const [_openWebUiModel];

  @override
  Future<void> saveLocalModels(List<Model> models) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

final class _Preferred extends PreferredBackendController {
  @override
  PreferredBackend build() => PreferredBackend.libreChat;

  void use(PreferredBackend backend) => state = backend;
}

final class _Hermes extends HermesConfigController {
  @override
  HermesConfig build() => const HermesConfig();
}

final class _Discovery extends DirectModelDiscoveryController {
  @override
  Future<DirectModelDiscoveryState> build() async =>
      DirectModelDiscoveryState();

  @override
  Future<void> refresh() async {}
}

/// The models as listed while LibreChat's catalog loads: another backend's
/// (Open WebUI's stands in), then LibreChat's beside it.
final class _ListedWhileLoading extends Models {
  @override
  Future<List<Model>> build() async => [
    _openWebUiModel,
    ...?ref.watch(libreChatModelCatalogProvider).value,
  ];
}

void main() {
  test('a send with no model picked waits for LibreChat\'s while it is '
      'primary', () async {
    final libreChatModel = libreChatCatalog(
      startupConfig: const <String, dynamic>{},
      endpoints: const <String, dynamic>{
        'Sample': <String, dynamic>{'order': 0},
      },
      models: const <String, List<String>>{
        'Sample': <String>['sample-model'],
      },
    ).single;
    final catalog = Completer<List<Model>>();
    final container = ProviderContainer(
      overrides: [
        preferredBackendProvider.overrideWith(_Preferred.new),
        libreChatModelCatalogProvider.overrideWith((ref) => catalog.future),
        modelsProvider.overrideWith(_ListedWhileLoading.new),
      ],
    );
    addTearDown(container.dispose);
    container.listen(modelsProvider, (_, _) {});
    // Usable meanwhile, but not LibreChat's.
    check(
      (await container.read(modelsProvider.future)).map((model) => model.id),
    ).deepEquals([_openWebUiModel.id]);

    final picking = modelForUnpickedSend(container.read);
    catalog.complete([libreChatModel]);
    check((await picking)?.id).equals(libreChatModel.id);
  });

  test('a LibreChat catalog that arrives after Open WebUI became primary '
      'leaves the Open WebUI models in place', () async {
    final libreChatModel = libreChatCatalog(
      startupConfig: const <String, dynamic>{},
      endpoints: const <String, dynamic>{
        'Sample': <String, dynamic>{'order': 0},
      },
      models: const <String, List<String>>{
        'Sample': <String>['sample-model'],
      },
    ).single;
    // The first catalog is there at once; the refresh's waits on the test.
    final late = Completer<List<Model>>();
    var catalogBuilds = 0;
    final container = ProviderContainer(
      overrides: [
        reviewerModeProvider.overrideWithValue(false),
        preferredBackendProvider.overrideWith(_Preferred.new),
        // Open WebUI is parked, signed out, while LibreChat is primary.
        isAuthenticatedProvider2.overrideWith(
          (ref) =>
              ref.watch(primaryAccountKindProvider) ==
              PrimaryAccountKind.openWebUi,
        ),
        isAuthLoadingProvider2.overrideWithValue(false),
        authStatusProvider.overrideWith(
          (ref) =>
              ref.watch(primaryAccountKindProvider) ==
                  PrimaryAccountKind.openWebUi
              ? AuthStatus.authenticated
              : AuthStatus.unauthenticated,
        ),
        activeServerProvider.overrideWith((ref) async => null),
        apiServiceProvider.overrideWithValue(null),
        optimizedStorageServiceProvider.overrideWithValue(_Storage()),
        hermesConfigProvider.overrideWith(_Hermes.new),
        directModelDiscoveryProvider.overrideWith(_Discovery.new),
        libreChatModelCatalogProvider.overrideWith(
          (ref) => ++catalogBuilds == 1
              ? Future.value([libreChatModel])
              : late.future,
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(modelsProvider, (_, _) {});

    check(
      (await container.read(modelsProvider.future)).map((model) => model.id),
    ).deepEquals([libreChatModel.id]);

    final refresh = container.read(modelsProvider.notifier).refresh();
    await Future<void>.delayed(Duration.zero);
    check(catalogBuilds).equals(2);
    (container.read(preferredBackendProvider.notifier) as _Preferred).use(
      PreferredBackend.owui,
    );
    check(
      (await container.read(modelsProvider.future)).map((model) => model.id),
    ).deepEquals([_openWebUiModel.id]);

    late.complete([libreChatModel]);
    await refresh;
    check(
      container.read(modelsProvider).value?.map((model) => model.id),
    ).isNotNull().deepEquals([_openWebUiModel.id]);
  });

  test('a LibreChat catalog refresh that fails keeps the models and the '
      'chosen one', () async {
    final libreChatModels = libreChatCatalog(
      startupConfig: const <String, dynamic>{},
      endpoints: const <String, dynamic>{
        'Sample': <String, dynamic>{'order': 0},
      },
      models: const <String, List<String>>{
        'Sample': <String>['first-model', 'second-model'],
      },
    );
    var catalogBuilds = 0;
    final container = ProviderContainer(
      overrides: [
        reviewerModeProvider.overrideWithValue(false),
        preferredBackendProvider.overrideWith(_Preferred.new),
        isAuthenticatedProvider2.overrideWithValue(false),
        isAuthLoadingProvider2.overrideWithValue(false),
        authStatusProvider.overrideWithValue(AuthStatus.unauthenticated),
        activeServerProvider.overrideWith((ref) async => null),
        apiServiceProvider.overrideWithValue(null),
        optimizedStorageServiceProvider.overrideWithValue(_Storage()),
        hermesConfigProvider.overrideWith(_Hermes.new),
        directModelDiscoveryProvider.overrideWith(_Discovery.new),
        libreChatModelCatalogProvider.overrideWith(
          (ref) => ++catalogBuilds == 1
              ? Future.value(libreChatModels)
              : Future<List<Model>>.error(StateError('offline')),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(modelsProvider, (_, _) {});
    container.listen(selectedModelProvider, (_, _) {});

    check(await container.read(modelsProvider.future)).length.equals(2);
    final chosen = libreChatModels.last;
    container.read(selectedModelProvider.notifier).set(chosen);
    container.read(isManualModelSelectionProvider.notifier).set(true);

    await container.read(modelsProvider.notifier).refresh();
    await container.read(modelsProvider.future);
    await Future<void>.delayed(Duration.zero);

    check(catalogBuilds).equals(2);
    check(
      container.read(modelsProvider).value?.map((model) => model.id),
    ).isNotNull().deepEquals(libreChatModels.map((model) => model.id));
    check(container.read(selectedModelProvider)).identicalTo(chosen);
    check(container.read(isManualModelSelectionProvider)).isTrue();
    // A send with no model picked takes one of those kept.
    check(
      (await modelForUnpickedSend(container.read))?.id,
    ).equals(libreChatModels.first.id);
  });

  test('a LibreChat catalog refresh keeps the open chat\'s model over the '
      'default', () async {
    final libreChatModels = libreChatCatalog(
      startupConfig: const <String, dynamic>{},
      endpoints: const <String, dynamic>{
        'Sample': <String, dynamic>{'order': 0},
      },
      models: const <String, List<String>>{
        'Sample': <String>['first-model', 'second-model'],
      },
    );
    final container = ProviderContainer(
      overrides: [
        reviewerModeProvider.overrideWithValue(false),
        preferredBackendProvider.overrideWith(_Preferred.new),
        isAuthenticatedProvider2.overrideWithValue(false),
        isAuthLoadingProvider2.overrideWithValue(false),
        authStatusProvider.overrideWithValue(AuthStatus.unauthenticated),
        activeServerProvider.overrideWith((ref) async => null),
        apiServiceProvider.overrideWithValue(null),
        optimizedStorageServiceProvider.overrideWithValue(_Storage()),
        hermesConfigProvider.overrideWith(_Hermes.new),
        directModelDiscoveryProvider.overrideWith(_Discovery.new),
        appSettingsProvider.overrideWithValue(
          AppSettings(defaultModel: libreChatModels.first.id),
        ),
        libreChatModelCatalogProvider.overrideWith(
          (ref) => Future.value(libreChatModels),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(modelsProvider, (_, _) {});
    container.listen(selectedModelProvider, (_, _) {});
    await container.read(modelsProvider.future);

    // A saved chat is open on the other model, which was not picked by hand.
    final chatModel = libreChatModels.last;
    container
        .read(activeConversationProvider.notifier)
        .set(
          Conversation(
            id: 'saved',
            title: 'Saved',
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
            model: chatModel.id,
          ),
        );
    container.read(selectedModelProvider.notifier).set(chatModel);

    await container.read(modelsProvider.notifier).refresh();
    await container.read(modelsProvider.future);
    await Future<void>.delayed(Duration.zero);

    check(container.read(selectedModelProvider)?.id).equals(chatModel.id);
  });

  test('a slow LibreChat catalog does not hold back the models usable now',
      () async {
    final libreChatModels = libreChatCatalog(
      startupConfig: const <String, dynamic>{},
      endpoints: const <String, dynamic>{
        'Sample': <String, dynamic>{'order': 0},
      },
      models: const <String, List<String>>{
        'Sample': <String>['sample-model'],
      },
    );
    final loading = Completer<List<Model>>();
    final container = ProviderContainer(
      overrides: [
        reviewerModeProvider.overrideWithValue(false),
        preferredBackendProvider.overrideWith(_Preferred.new),
        isAuthenticatedProvider2.overrideWithValue(false),
        isAuthLoadingProvider2.overrideWithValue(false),
        authStatusProvider.overrideWithValue(AuthStatus.unauthenticated),
        activeServerProvider.overrideWith((ref) async => null),
        apiServiceProvider.overrideWithValue(null),
        optimizedStorageServiceProvider.overrideWithValue(_Storage()),
        hermesConfigProvider.overrideWith(_Hermes.new),
        directModelDiscoveryProvider.overrideWith(_Discovery.new),
        libreChatModelCatalogProvider.overrideWith((ref) => loading.future),
      ],
    );
    addTearDown(container.dispose);
    container.listen(modelsProvider, (_, _) {});

    // The server has not answered: the list is there all the same.
    final first = await container
        .read(modelsProvider.future)
        .timeout(const Duration(seconds: 2));
    check(first.where(isLibreChatModel)).isEmpty();

    loading.complete(libreChatModels);
    await pumpEventQueue();
    check(
      container.read(modelsProvider).value?.where(isLibreChatModel).length,
    ).equals(1);
  });

  test('a saved LibreChat chat opened while the catalog loads keeps its '
      'model', () async {
    final libreChatModels = libreChatCatalog(
      startupConfig: const <String, dynamic>{},
      endpoints: const <String, dynamic>{
        'Sample': <String, dynamic>{'order': 0},
      },
      models: const <String, List<String>>{
        'Sample': <String>['first-model', 'second-model'],
      },
    );
    final loading = Completer<List<Model>>();
    final container = ProviderContainer(
      overrides: [
        reviewerModeProvider.overrideWithValue(false),
        preferredBackendProvider.overrideWith(_Preferred.new),
        isAuthenticatedProvider2.overrideWithValue(false),
        isAuthLoadingProvider2.overrideWithValue(false),
        authStatusProvider.overrideWithValue(AuthStatus.unauthenticated),
        activeServerProvider.overrideWith((ref) async => null),
        apiServiceProvider.overrideWithValue(null),
        optimizedStorageServiceProvider.overrideWithValue(_Storage()),
        hermesConfigProvider.overrideWith(_Hermes.new),
        directModelDiscoveryProvider.overrideWith(_Discovery.new),
        appSettingsProvider.overrideWithValue(
          AppSettings(defaultModel: libreChatModels.first.id),
        ),
        libreChatModelCatalogProvider.overrideWith((ref) => loading.future),
      ],
    );
    addTearDown(container.dispose);
    container.listen(modelsProvider, (_, _) {});
    container.listen(selectedModelProvider, (_, _) {});
    check(container.read(selectedModelProvider)).isNull();

    // Opened before the catalog is there, on the other model.
    final chatModel = libreChatModels.last;
    container
        .read(activeConversationProvider.notifier)
        .set(
          withChatStorageProvenance(
            Conversation(
              id: 'saved',
              title: 'Saved',
              createdAt: DateTime.utc(2026),
              updatedAt: DateTime.utc(2026),
              model: chatModel.id,
            ),
            ChatStorageKind.libreChat,
          ),
        );

    loading.complete(libreChatModels);
    await container.read(modelsProvider.future);
    // The list is built again with the catalog, then the choice follows.
    await pumpEventQueue();

    check(container.read(selectedModelProvider)?.id).equals(chatModel.id);
  });

  test('a LibreChat catalog refresh moves an open chat onto its own model',
      () async {
    final libreChatModels = libreChatCatalog(
      startupConfig: const <String, dynamic>{},
      endpoints: const <String, dynamic>{
        'Sample': <String, dynamic>{'order': 0},
      },
      models: const <String, List<String>>{
        'Sample': <String>['first-model', 'second-model'],
      },
    );
    final container = ProviderContainer(
      overrides: [
        reviewerModeProvider.overrideWithValue(false),
        preferredBackendProvider.overrideWith(_Preferred.new),
        isAuthenticatedProvider2.overrideWithValue(false),
        isAuthLoadingProvider2.overrideWithValue(false),
        authStatusProvider.overrideWithValue(AuthStatus.unauthenticated),
        activeServerProvider.overrideWith((ref) async => null),
        apiServiceProvider.overrideWithValue(null),
        optimizedStorageServiceProvider.overrideWithValue(_Storage()),
        hermesConfigProvider.overrideWith(_Hermes.new),
        directModelDiscoveryProvider.overrideWith(_Discovery.new),
        appSettingsProvider.overrideWithValue(
          AppSettings(defaultModel: libreChatModels.first.id),
        ),
        libreChatModelCatalogProvider.overrideWith(
          (ref) => Future.value(libreChatModels),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(modelsProvider, (_, _) {});
    container.listen(selectedModelProvider, (_, _) {});
    await container.read(modelsProvider.future);
    await Future<void>.delayed(Duration.zero);
    check(
      container.read(selectedModelProvider)?.id,
    ).equals(libreChatModels.first.id);

    // A saved chat on the other model opens; its own restore of that model
    // is cut short, as when the selection changes under it.
    final chatModel = libreChatModels.last;
    container
        .read(activeConversationProvider.notifier)
        .set(
          withChatStorageProvenance(
            Conversation(
              id: 'saved',
              title: 'Saved',
              createdAt: DateTime.utc(2026),
              updatedAt: DateTime.utc(2026),
              model: chatModel.id,
            ),
            ChatStorageKind.libreChat,
          ),
        );

    await container.read(modelsProvider.notifier).refresh();
    await container.read(modelsProvider.future);
    await Future<void>.delayed(Duration.zero);

    check(container.read(selectedModelProvider)?.id).equals(chatModel.id);
  });

  test('while Open WebUI is primary the LibreChat catalog is never asked',
      () async {
    var catalogBuilds = 0;
    final container = ProviderContainer(
      overrides: [
        reviewerModeProvider.overrideWithValue(false),
        preferredBackendProvider.overrideWith(_Preferred.new),
        isAuthenticatedProvider2.overrideWithValue(true),
        isAuthLoadingProvider2.overrideWithValue(false),
        authStatusProvider.overrideWithValue(AuthStatus.authenticated),
        activeServerProvider.overrideWith((ref) async => null),
        apiServiceProvider.overrideWithValue(null),
        optimizedStorageServiceProvider.overrideWithValue(_Storage()),
        hermesConfigProvider.overrideWith(_Hermes.new),
        directModelDiscoveryProvider.overrideWith(_Discovery.new),
        libreChatModelCatalogProvider.overrideWith((ref) {
          catalogBuilds++;
          return Future.value(const <Model>[]);
        }),
      ],
    );
    addTearDown(container.dispose);
    (container.read(preferredBackendProvider.notifier) as _Preferred).use(
      PreferredBackend.owui,
    );
    container.listen(modelsProvider, (_, _) {});

    check(
      (await container.read(modelsProvider.future)).map((model) => model.id),
    ).deepEquals([_openWebUiModel.id]);
    check(catalogBuilds).equals(0);
  });

  test('with LibreChat in charge a chosen Hermes model survives a refresh',
      () async {
    final libreChatModels = libreChatCatalog(
      startupConfig: const <String, dynamic>{},
      endpoints: const <String, dynamic>{
        'Sample': <String, dynamic>{'order': 0},
      },
      models: const <String, List<String>>{
        'Sample': <String>['first-model'],
      },
    );
    final container = ProviderContainer(
      overrides: [
        reviewerModeProvider.overrideWithValue(false),
        preferredBackendProvider.overrideWith(_Preferred.new),
        isAuthenticatedProvider2.overrideWithValue(false),
        isAuthLoadingProvider2.overrideWithValue(false),
        authStatusProvider.overrideWithValue(AuthStatus.unauthenticated),
        activeServerProvider.overrideWith((ref) async => null),
        apiServiceProvider.overrideWithValue(null),
        optimizedStorageServiceProvider.overrideWithValue(_Storage()),
        hermesConfigProvider.overrideWith(_UsableHermes.new),
        directModelDiscoveryProvider.overrideWith(_Discovery.new),
        libreChatModelCatalogProvider.overrideWith(
          (ref) => Future.value(libreChatModels),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(modelsProvider, (_, _) {});
    container.listen(selectedModelProvider, (_, _) {});
    await container.read(modelsProvider.future);

    final hermes = hermesSyntheticModel(name: 'Agent');
    container.read(selectedModelProvider.notifier).set(hermes);
    container.read(isManualModelSelectionProvider.notifier).set(true);

    await container.read(modelsProvider.notifier).refresh();
    await container.read(modelsProvider.future);
    await Future<void>.delayed(Duration.zero);

    check(container.read(selectedModelProvider)?.id).equals(hermes.id);
    check(container.read(isManualModelSelectionProvider)).isTrue();
  });
}

final class _UsableHermes extends HermesConfigController {
  @override
  HermesConfig build() => const HermesConfig(
    enabled: true,
    baseUrl: 'https://hermes.example.com',
    apiKey: 'test-key',
  );
}
