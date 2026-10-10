import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/auth/auth_state_manager.dart'
    show savedCredentialAuthApiFactoryProvider;
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/push/models/push_target.dart';
import 'package:conduit_core/features/push/providers/push_providers.dart';
import 'package:conduit_core/features/push/services/push_backend.dart';
import 'package:conduit_core/features/push/services/push_backend_factory.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show apiServiceProvider;
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// The saved connection's settings, as the Hermes controller hands them out.
final class _Configs extends HermesConfigController {
  HermesConfig saved = _home;

  @override
  HermesConfig build() => const HermesConfig();

  @override
  Future<HermesConfig> savedConnectionConfig(String connectionId) async {
    if (connectionId != 'conn-1') throw StateError('no such connection');
    return saved;
  }
}

const _home = HermesConfig(
  enabled: true,
  connectionId: 'conn-1',
  baseUrl: 'https://home.test',
  apiKey: 'old-key-0123456789',
);

const _moved = HermesConfig(
  enabled: true,
  connectionId: 'conn-1',
  baseUrl: 'https://moved.test',
  apiKey: 'new-key-0123456789',
);

HermesConnectionProfile _profile(String baseUrl, String principal) =>
    HermesConnectionProfile(
      id: 'conn-1',
      name: 'Home',
      documentTrustPrincipalId: principal,
      baseUrl: baseUrl,
    );

HermesPushTarget _target(String baseUrl, String principal) => HermesPushTarget(
  connectionId: 'conn-1',
  label: 'Home',
  baseUrl: baseUrl,
  mode: HermesBackendMode.responsesApi,
  credentialsRevision: principal,
);

void main() {
  late ProviderContainer container;
  late _Configs configs;
  late List<HermesConnectionProfile> profiles;

  setUp(() {
    configs = _Configs();
    profiles = [_profile(_home.baseUrl, 'p-1')];
    container = ProviderContainer(
      overrides: [
        hermesConfigProvider.overrideWith(() => configs),
        hermesConnectionsProvider.overrideWith((ref) => profiles),
      ],
    );
    container.read(hermesConfigProvider);
  });

  tearDown(() => container.dispose());

  AppPushBackendFactory factory() =>
      container.read(pushBackendFactoryProvider) as AppPushBackendFactory;

  Future<void> edit() async {
    configs.saved = _moved;
    profiles = [_profile(_moved.baseUrl, 'p-2')];
    container.invalidate(hermesConnectionsProvider);
  }

  test('a target reaches the server it names', () async {
    final config = await factory().hermesConfigFor(
      _target(_home.baseUrl, 'p-1'),
    );
    check(config.baseUrl).equals(_home.baseUrl);
  });

  test('after an edit, the old target reaches its old server', () async {
    final old = _target(_home.baseUrl, 'p-1');
    await factory().retain(old);
    await edit();

    final config = await factory().hermesConfigFor(old);
    check(config.baseUrl).equals(_home.baseUrl);
    check(config.apiKey).equals(_home.apiKey);
    // The new target reaches the new server.
    final now = await factory().hermesConfigFor(_target(_moved.baseUrl, 'p-2'));
    check(now.baseUrl).equals(_moved.baseUrl);
  });

  test('without the old settings, the old target is refused', () async {
    await edit();
    PushBackendException? refused;
    try {
      await factory().hermesConfigFor(_target(_home.baseUrl, 'p-1'));
    } on PushBackendException catch (error) {
      refused = error;
    }
    check(refused?.failure.detail).equals('connection_changed');
  });

  // An edit under way, or one rolled back, leaves the saved address blank.
  void clearAddress() {
    configs.saved = _home.copyWith(baseUrl: '');
    profiles = [_profile('', 'p-1')];
    container.invalidate(hermesConnectionsProvider);
  }

  test('with its address cleared, a target reaches its server still', () async {
    final old = _target(_home.baseUrl, 'p-1');
    await factory().retain(old);
    clearAddress();

    final config = await factory().hermesConfigFor(old);
    check(config.baseUrl).equals(_home.baseUrl);
  });

  test('a cleared address with nothing kept is an invalid one', () async {
    clearAddress();
    PushBackendException? refused;
    try {
      await factory().hermesConfigFor(_target(_home.baseUrl, 'p-1'));
    } on PushBackendException catch (error) {
      refused = error;
    }
    check(refused?.failure.detail).equals('invalid_url');
  });

  test("the active account's switch queues on its live client", () async {
    final server = _SettingsServer();
    final live = _liveClient(server);
    var throwaway = 0;
    final app = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWithValue(live),
        savedCredentialAuthApiFactoryProvider.overrideWithValue(
          ({required serverConfig, required workerManager}) {
            throwaway++;
            throw StateError('the live client should be used');
          },
        ),
      ],
    );
    addTearDown(app.dispose);

    // A settings write the app made first, still reading the document.
    final gate = Completer<void>();
    server.gate = gate;
    final sound = live.updateUserNotificationSettings(notificationSound: false);
    final push = app
        .read(pushBackendFactoryProvider)
        .setOpenWebUiNotificationsEnabled('acct-1', enabled: true);
    await pumpEventQueue();
    gate.complete();
    await sound;
    await push;

    check(throwaway).equals(0);
    check(server.settings).deepEquals({
      'notificationSound': false,
      'notificationEnabled': true,
    });
  });

  test('a switch its server already holds is kept when asked', () async {
    final server = _SettingsServer()..settings = {'notificationEnabled': false};
    final app = ProviderContainer(
      overrides: [apiServiceProvider.overrideWithValue(_liveClient(server))],
    );
    addTearDown(app.dispose);
    final factory = app.read(pushBackendFactoryProvider);

    await factory.setOpenWebUiNotificationsEnabled(
      'acct-1',
      enabled: true,
      onlyIfUnset: true,
    );
    check(server.settings).deepEquals({'notificationEnabled': false});

    server.settings = {'notificationSound': false};
    await factory.setOpenWebUiNotificationsEnabled(
      'acct-1',
      enabled: true,
      onlyIfUnset: true,
    );
    check(server.settings).deepEquals({
      'notificationSound': false,
      'notificationEnabled': true,
    });
  });
}

/// The live client of acct-1, the active account, talking to [server].
ApiService _liveClient(_SettingsServer server) => ApiService(
  serverConfig: const ServerConfig(
    id: 'acct-1',
    name: 'Home',
    url: 'https://owui.test',
    isActive: true,
  ),
  workerManager: WorkerManager(),
  authToken: 'live-token-0123456789',
)..dio.httpClientAdapter = server;

/// Open WebUI's user settings document, replaced by every update.
final class _SettingsServer implements HttpClientAdapter {
  Map<String, dynamic> settings = {};

  /// Holds the next request until completed.
  Completer<void>? gate;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final held = gate;
    if (held != null) {
      gate = null;
      await held.future;
    }
    if (options.method == 'POST') {
      settings = Map<String, dynamic>.from(options.data as Map);
    }
    return ResponseBody.fromString(
      jsonEncode(settings),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
