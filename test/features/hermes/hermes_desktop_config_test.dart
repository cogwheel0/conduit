import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/services/hermes_desktop_connection_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('config hash is independent of access-header insertion order', () {
    final left = HermesConfig(
      desktopCredentials: HermesDesktopCredentials(
        accessHeaders: {'X-A': '1', 'X-B': '2'},
      ),
    );
    final right = HermesConfig(
      desktopCredentials: HermesDesktopCredentials(
        accessHeaders: {'X-B': '2', 'X-A': '1'},
      ),
    );

    check(left).equals(right);
    check(left.hashCode).equals(right.hashCode);
  });

  test('Desktop auth recommendation follows the advertised gateway flow', () {
    check(
      hermesRecommendedDesktopAuth(const {
        'auth_required': true,
        'auth_flows': ['native_pkce'],
      }, hasAccessHeaders: false),
    ).equals(HermesDesktopAuthKind.nativePkce);
    check(
      hermesRecommendedDesktopAuth(const {
        'auth_required': true,
        'auth_flows': ['native_pkce'],
      }, hasAccessHeaders: true),
    ).equals(HermesDesktopAuthKind.dashboardCookie);
    check(
      hermesRecommendedDesktopAuth(const {
        'auth_required': false,
      }, hasAccessHeaders: false),
    ).equals(HermesDesktopAuthKind.legacyToken);
  });

  test('native token rotation preserves transport-bearing credentials', () {
    final before = HermesConfig(
      enabled: true,
      baseUrl: 'https://hermes.example',
      mode: HermesBackendMode.desktopGateway,
      desktopCredentials: HermesDesktopCredentials(
        nativeTokens: HermesDesktopTokenSet(
          accessToken: 'old-access',
          refreshToken: 'old-refresh',
          expiresAt: DateTime.utc(2026),
        ),
        accessHeaders: const {'X-Access': 'outer'},
      ),
    );
    final after = before.copyWith(
      desktopCredentials: HermesDesktopCredentials(
        nativeTokens: HermesDesktopTokenSet(
          accessToken: 'new-access',
          refreshToken: 'new-refresh',
          expiresAt: DateTime.utc(2027),
        ),
        accessHeaders: const {'X-Access': 'outer'},
      ),
    );

    check(after.baseUrl).equals(before.baseUrl);
    check(after.desktopCredentials!.accessHeaders)
        .deepEquals(before.desktopCredentials!.accessHeaders);
    check(after.desktopCredentials!.nativeTokens!.accessToken)
        .equals('new-access');
    check(after.desktopCredentials!.nativeTokens!.refreshToken)
        .equals('new-refresh');
    check(after.desktopCredentials!.nativeTokens!.expiresAt)
        .equals(DateTime.utc(2027));
  });

  test('existing Hermes config remains on Responses API', () {
    const config = HermesConfig(
      enabled: true,
      baseUrl: 'https://hermes.example/v1',
      apiKey: 'key',
    );

    check(config.mode).equals(HermesBackendMode.responsesApi);
    check(config.desktopProfile).equals('default');
    check(config.isUsable).isTrue();
  });

  test('Desktop profile IDs follow Hermes profile rules', () {
    check(HermesConfig.isValidDesktopProfile('default')).isTrue();
    check(HermesConfig.isValidDesktopProfile('work_2')).isTrue();
    check(HermesConfig.isValidDesktopProfile('../work')).isFalse();
    check(
      const HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes.example',
        mode: HermesBackendMode.desktopGateway,
        desktopProfile: '../work',
      ).isUsable,
    ).isFalse();
  });

  test('Desktop config is usable without a Responses API key', () {
    const config = HermesConfig(
      enabled: true,
      baseUrl: 'https://hermes.example',
      mode: HermesBackendMode.desktopGateway,
    );

    check(config.isUsable).isTrue();
  });

  test('access header validation is bounded and reserves auth headers', () {
    check(HermesConfig.validateAccessHeaders({'Authorization': 'secret'}) ?? '')
        .contains('reserved');
    check(
      HermesConfig.validateAccessHeaders({'sec-websocket-ticket': 'secret'}) ??
          '',
    ).contains('reserved');
    check(
      HermesConfig.validateAccessHeaders({
        for (var index = 0; index < 11; index++) 'X-Access-$index': 'value',
      }),
    ).equals('At most 10 headers are allowed.');
    check(
      HermesConfig.validateAccessHeaders({'X-Access': 'safe\nInjected: yes'}) ??
          '',
    ).contains('invalid');
    check(HermesConfig.validateAccessHeaders({' X-Access': 'secret'}) ?? '')
        .contains('invalid');
  });

  test('Desktop credential document round-trips all origin-bound secrets', () {
    final expiry = DateTime.utc(2030, 1, 2, 3, 4, 5);
    final credentials = HermesDesktopCredentials(
      legacyToken: 'legacy',
      nativeTokens: HermesDesktopTokenSet(
        accessToken: 'access',
        refreshToken: 'refresh',
        expiresAt: expiry,
      ),
      accessHeaders: const {'X-Access': 'outer'},
    );

    final restored = HermesDesktopCredentials.fromJson(credentials.toJson());
    check(restored.legacyToken).equals('legacy');
    check(restored.nativeTokens?.accessToken).equals('access');
    check(restored.nativeTokens?.refreshToken).equals('refresh');
    check(restored.nativeTokens?.expiresAt).equals(expiry);
    check(restored.accessHeaders).deepEquals({'X-Access': 'outer'});
    expect(
      () => restored.accessHeaders['X-Other'] = 'nope',
      throwsUnsupportedError,
    );
  });
}
