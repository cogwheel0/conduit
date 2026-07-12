import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/services/hermes_api_service.dart';
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

  test('connection draft does not mutate the saved configuration', () {
    const saved = HermesConfig(
      enabled: true,
      baseUrl: 'https://one.example/v1',
      apiKey: 'old-key',
      sessionKey: 'old-memory',
    );

    final draft = buildHermesConnectionDraft(
      saved: saved,
      baseUrl: ' https://two.example/v1 ',
      apiKeyChanged: true,
      apiKey: 'new-key',
      sessionKeyChanged: false,
      sessionKey: '',
    );

    check(saved.baseUrl).equals('https://one.example/v1');
    check(saved.apiKey).equals('old-key');
    check(saved.sessionKey).equals('old-memory');
    check(draft.enabled).isTrue();
    check(draft.baseUrl).equals('https://two.example/v1');
    check(draft.apiKey).equals('new-key');
    check(draft.sessionKey).isNull();
  });

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
