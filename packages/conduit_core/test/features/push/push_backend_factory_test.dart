import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/push/models/push_target.dart';
import 'package:conduit_core/features/push/providers/push_providers.dart';
import 'package:conduit_core/features/push/services/push_backend.dart';
import 'package:conduit_core/features/push/services/push_backend_factory.dart';
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
}
