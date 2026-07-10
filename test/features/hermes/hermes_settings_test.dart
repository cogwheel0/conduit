import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/views/hermes_settings_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'connection test probes a valid draft while Hermes is disabled',
    () async {
      const disabledDraft = HermesConfig(
        enabled: false,
        baseUrl: 'https://hermes.example/v1',
        apiKey: 'secret-key',
      );
      HermesConfig? received;

      final result = await testHermesDraftConnection(
        disabledDraft,
        probe: (config) async {
          received = config;
          return true;
        },
      );

      check(result).isTrue();
      check(disabledDraft.enabled).isFalse();
      check(received).isNotNull();
      check(received!.enabled).isTrue();
      check(received!.isUsable).isTrue();
    },
  );

  test(
    'onboarding surfaces session-key failure and stops completion',
    () async {
      final calls = <String>[];

      final result = await completeHermesOnboarding(
        enable: () async => calls.add('enable'),
        ensureSessionKey: () async {
          calls.add('session-key');
          throw StateError('secure storage unavailable');
        },
        selectHermes: () async => calls.add('select-hermes'),
      );

      check(result.success).isFalse();
      check(result.error).isA<StateError>();
      check(calls).deepEquals(['enable', 'session-key']);
    },
  );

  test('onboarding selects Hermes only after every step succeeds', () async {
    final calls = <String>[];

    final result = await completeHermesOnboarding(
      enable: () async => calls.add('enable'),
      ensureSessionKey: () async => calls.add('session-key'),
      selectHermes: () async => calls.add('select-hermes'),
    );

    check(result.success).isTrue();
    check(result.error).isNull();
    check(calls).deepEquals(['enable', 'session-key', 'select-hermes']);
  });
}
