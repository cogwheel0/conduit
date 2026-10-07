import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _server = ServerConfig(
  id: 'account',
  name: 'Home',
  url: 'https://owui.example',
);

const _serverDefault = Model(id: 'server-default', name: 'Server default');

final class _Storage implements OptimizedStorageService {
  @override
  Future<Model?> getLocalDefaultModel() async => null;

  @override
  Future<void> saveLocalDefaultModel(Model? model) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

/// The server's default arrives when the test says, the first time.
final class _DefaultModelApi extends ApiService {
  _DefaultModelApi(WorkerManager workerManager, this.firstAnswer)
    : super(serverConfig: _server, workerManager: workerManager);

  final Future<String?> firstAnswer;
  final asked = Completer<void>();
  var calls = 0;

  @override
  Future<String?> getDefaultModel() {
    calls++;
    if (!asked.isCompleted) asked.complete();
    return calls == 1 ? firstAnswer : Future.value(_serverDefault.id);
  }

  @override
  Future<List<Model>> getModels({
    bool includeHidden = false,
    ApiAuthSnapshot? authSnapshot,
  }) async => const [_serverDefault];
}

final class _Models extends Models {
  @override
  Future<List<Model>> build() async => const [_serverDefault];
}

final class _Preferred extends PreferredBackendController {
  @override
  PreferredBackend build() => PreferredBackend.owui;
}

final class _Hermes extends HermesConfigController {
  @override
  HermesConfig build() => const HermesConfig();
}

/// A newly signed-in account's default model is looked up while its database
/// is still being certified. The certification makes that lookup another
/// owner's, so its answer is dropped -- and the account must not be left
/// without its default because of it.
void main() {
  test(
    'a default looked up while the account settled is looked up again',
    () async {
      final workerManager = WorkerManager();
      final answer = Completer<String?>();
      final api = _DefaultModelApi(workerManager, answer.future);
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          preferredBackendProvider.overrideWith(_Preferred.new),
          isAuthenticatedProvider2.overrideWithValue(true),
          isAuthLoadingProvider2.overrideWithValue(false),
          authStatusProvider.overrideWithValue(AuthStatus.authenticated),
          authTokenProvider3.overrideWithValue('token'),
          activeServerProvider.overrideWith((ref) async => _server),
          apiServiceProvider.overrideWithValue(api),
          appSettingsProvider.overrideWithValue(
            const AppSettings(defaultModel: ''),
          ),
          optimizedStorageServiceProvider.overrideWithValue(_Storage()),
          modelsProvider.overrideWith(_Models.new),
          hermesConfigProvider.overrideWith(_Hermes.new),
        ],
      );
      addTearDown(() {
        container.dispose();
        api.dispose();
        workerManager.dispose();
      });
      await container.read(activeServerProvider.future);

      final pending = container.read(defaultModelProvider.future);
      await api.asked.future.timeout(const Duration(seconds: 5));
      container
          .read(openWebUiCertifiedDatabaseServerProvider.notifier)
          .set(_server.id);
      answer.complete(_serverDefault.id);

      final resolved = await pending.timeout(const Duration(seconds: 5));

      check(resolved)
          .isNotNull()
          .has((model) => model.id, 'id')
          .equals(_serverDefault.id);
      check(container.read(selectedModelProvider))
          .isNotNull()
          .has((model) => model.id, 'id')
          .equals(_serverDefault.id);
      check(api.calls).equals(2);
    },
  );
}
