import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A [HermesConfigController] stand-in that yields a fixed config without
/// touching shared preferences or secure storage (the real `build()` loads
/// secrets asynchronously, which is unavailable in a plain unit test).
class _FakeHermesConfigController extends HermesConfigController {
  _FakeHermesConfigController(this._config);

  final HermesConfig _config;

  @override
  HermesConfig build() => _config;
}

const _usableHermes = HermesConfig(
  enabled: true,
  baseUrl: 'https://hermes.example/v1',
  apiKey: 'secret-key',
);

const _disabledHermes = HermesConfig(enabled: false);

// Enabled but missing the API key → not usable.
const _incompleteHermes = HermesConfig(
  enabled: true,
  baseUrl: 'https://hermes.example/v1',
);

const _server = ServerConfig(
  id: 'srv-1',
  name: 'Example',
  url: 'https://owui.example',
);

void main() {
  /// Builds a container wired for [hermesOnlyModeProvider] with all three of its
  /// inputs overridden.
  Future<ProviderContainer> makeContainer({
    required HermesConfig hermesConfig,
    required ServerConfig? activeServer,
    bool reviewerMode = false,
  }) async {
    final container = ProviderContainer(
      overrides: [
        reviewerModeProvider.overrideWithValue(reviewerMode),
        hermesConfigProvider.overrideWith(
          () => _FakeHermesConfigController(hermesConfig),
        ),
        activeServerProvider.overrideWith((ref) async => activeServer),
      ],
    );
    addTearDown(container.dispose);
    // Settle the active-server future so the derived provider reads AsyncData.
    await container.read(activeServerProvider.future);
    return container;
  }

  group('hermesOnlyModeProvider', () {
    test('true when Hermes is usable and there is no OWUI server', () async {
      final container = await makeContainer(
        hermesConfig: _usableHermes,
        activeServer: null,
      );
      check(container.read(hermesOnlyModeProvider)).isTrue();
    });

    test('false when an OWUI server is active', () async {
      final container = await makeContainer(
        hermesConfig: _usableHermes,
        activeServer: _server,
      );
      check(container.read(hermesOnlyModeProvider)).isFalse();
    });

    test('false when Hermes is disabled', () async {
      final container = await makeContainer(
        hermesConfig: _disabledHermes,
        activeServer: null,
      );
      check(container.read(hermesOnlyModeProvider)).isFalse();
    });

    test('false when Hermes is enabled but not usable (no key)', () async {
      final container = await makeContainer(
        hermesConfig: _incompleteHermes,
        activeServer: null,
      );
      check(container.read(hermesOnlyModeProvider)).isFalse();
    });

    test('reviewer mode takes precedence over Hermes-only', () async {
      final container = await makeContainer(
        hermesConfig: _usableHermes,
        activeServer: null,
        reviewerMode: true,
      );
      check(container.read(hermesOnlyModeProvider)).isFalse();
    });

    test('false while the active OWUI server is still loading', () {
      final pendingServer = Completer<ServerConfig?>();
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          hermesConfigProvider.overrideWith(
            () => _FakeHermesConfigController(_usableHermes),
          ),
          activeServerProvider.overrideWith((ref) => pendingServer.future),
        ],
      );
      addTearDown(() {
        pendingServer.complete(null);
        container.dispose();
      });

      check(container.read(activeServerProvider).isLoading).isTrue();
      check(container.read(hermesOnlyModeProvider)).isFalse();
    });

    test('false when loading the active OWUI server fails', () async {
      final container = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWithValue(false),
          hermesConfigProvider.overrideWith(
            () => _FakeHermesConfigController(_usableHermes),
          ),
          activeServerProvider.overrideWith(
            (ref) => Future<ServerConfig?>.error(StateError('storage failed')),
          ),
        ],
      );
      addTearDown(container.dispose);

      await expectLater(
        container.read(activeServerProvider.future),
        throwsStateError,
      );
      check(container.read(activeServerProvider).hasError).isTrue();
      check(container.read(hermesOnlyModeProvider)).isFalse();
    });
  });
}
