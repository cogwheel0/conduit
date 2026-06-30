import 'package:conduit/core/models/backend_config.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins [backendConfigProvider] to a fixed config for the test.
class _FixedBackendConfigNotifier extends BackendConfigNotifier {
  _FixedBackendConfigNotifier(this._config);

  final BackendConfig? _config;

  @override
  Future<BackendConfig?> build() async => _config;
}

ServerConfig _server(String id) =>
    ServerConfig(id: id, name: id, url: 'https://$id.example');

Future<ProviderContainer> _container({
  ServerConfig? activeServer,
  BackendConfig? config,
}) async {
  final container = ProviderContainer(
    overrides: [
      activeServerProvider.overrideWith((ref) async => activeServer),
      backendConfigProvider.overrideWith(
        () => _FixedBackendConfigNotifier(config),
      ),
    ],
  );
  // Resolve the async dependencies so the synchronous gate provider can read
  // their data values.
  await container.read(activeServerProvider.future);
  await container.read(backendConfigProvider.future);
  return container;
}

void main() {
  group('serverIncompatibleProvider', () {
    test('gates when the active server\'s config is unsupported', () async {
      final container = await _container(
        activeServer: _server('A'),
        config: const BackendConfig(version: '0.11.0', serverId: 'A'),
      );
      addTearDown(container.dispose);

      expect(container.read(serverIncompatibleProvider), isTrue);
    });

    test('does not gate when the active server is supported', () async {
      final container = await _container(
        activeServer: _server('A'),
        config: const BackendConfig(version: '0.10.1', serverId: 'A'),
      );
      addTearDown(container.dispose);

      expect(container.read(serverIncompatibleProvider), isFalse);
    });

    test(
      'fails open when the cached config belongs to a different server',
      () async {
        // The crux fix: after switching from unsupported server A to supported
        // server B, the still-cached A config must not gate B.
        final container = await _container(
          activeServer: _server('B'),
          config: const BackendConfig(version: '0.11.0', serverId: 'A'),
        );
        addTearDown(container.dispose);

        expect(container.read(serverIncompatibleProvider), isFalse);
      },
    );

    test('fails open for an untagged (legacy) cached config', () async {
      // A cache written by a pre-tagging app version has a null serverId and
      // can't be attributed to a server. The gate fails open and relies on the
      // immediate refresh to produce a freshly-tagged config, rather than risk
      // trapping a supported server on a stale unsupported cache.
      final container = await _container(
        activeServer: _server('A'),
        config: const BackendConfig(version: '0.11.0'),
      );
      addTearDown(container.dispose);

      expect(container.read(serverIncompatibleProvider), isFalse);
    });

    test('fails open when there is no active server', () async {
      final container = await _container(
        activeServer: null,
        config: const BackendConfig(version: '0.11.0', serverId: 'A'),
      );
      addTearDown(container.dispose);

      expect(container.read(serverIncompatibleProvider), isFalse);
    });

    test('fails open when the backend config is unknown', () async {
      final container = await _container(activeServer: _server('A'));
      addTearDown(container.dispose);

      expect(container.read(serverIncompatibleProvider), isFalse);
    });
  });
}
