import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/controllers/hermes_connection_controller.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/services/hermes_api_service.dart';
import 'package:conduit/features/hermes/services/hermes_connection_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _messages = HermesConnectionMessages(
  connecting: 'Connecting',
  connected: 'Connected',
  unreachable: 'Could not connect',
  persistenceFailed: 'Could not save',
  activationFailed: 'Could not activate',
);

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

  test('connection controller builds an origin-safe immutable draft', () {
    const saved = HermesConfig(
      enabled: true,
      baseUrl: 'https://one.example/v1',
      apiKey: 'old-key',
      sessionKey: 'old-memory',
    );
    final controller = HermesConnectionController(
      initialConfig: saved,
      gateway: _FakeHermesConnectionGateway(),
    );
    addTearDown(controller.dispose);
    controller.url.text = ' https://two.example/v1 ';
    controller.apiKey.text = 'new-key';
    controller.markApiKeyChanged();

    final draft = controller.buildDraft(saved);

    check(saved.baseUrl).equals('https://one.example/v1');
    check(saved.apiKey).equals('old-key');
    check(saved.sessionKey).equals('old-memory');
    check(draft.config.enabled).isTrue();
    check(draft.config.baseUrl).equals('https://two.example/v1');
    check(draft.config.apiKey).equals('new-key');
    check(draft.config.sessionKey).isNull();
    check(draft.apiKeyChanged).isTrue();
    check(draft.sessionKeyChanged).isTrue();
  });

  test('activation failure is one typed onboarding result', () async {
    final gateway = _FakeHermesConnectionGateway(
      onActivate: () async => throw StateError('secure storage unavailable'),
    );
    final controller = _configuredController(gateway);
    addTearDown(controller.dispose);

    final result = await controller.finishOnboarding(
      saved: const HermesConfig(),
      messages: _messages,
    );

    check(result.outcome).equals(HermesConnectionOutcome.activationFailed);
    check(result.error).isA<StateError>();
    check(gateway.calls).deepEquals(['probe', 'persist', 'activate']);
    check(controller.attempt.message).equals('Could not activate');
  });

  test(
    'failed onboarding probe performs no persistence or activation',
    () async {
      final gateway = _FakeHermesConnectionGateway(probeResult: false);
      final controller = _configuredController(gateway);
      addTearDown(controller.dispose);

      final result = await controller.finishOnboarding(
        saved: const HermesConfig(),
        messages: _messages,
      );

      check(result.outcome).equals(HermesConnectionOutcome.unreachable);
      check(gateway.calls).deepEquals(['probe']);
    },
  );

  test(
    'successful onboarding preserves probe-to-activation ordering',
    () async {
      final gateway = _FakeHermesConnectionGateway();
      final controller = _configuredController(gateway);
      addTearDown(controller.dispose);

      final result = await controller.finishOnboarding(
        saved: const HermesConfig(),
        messages: _messages,
      );

      check(result.outcome).equals(HermesConnectionOutcome.success);
      check(gateway.calls).deepEquals(['probe', 'persist', 'activate']);
      check(gateway.probedDraft).isNotNull();
      check(gateway.persistedDraft).isNotNull();
      check(
        identical(gateway.probedDraft, gateway.persistedDraft!.config),
      ).isTrue();
    },
  );

  test(
    'persistence failure prevents activation and retains credentials',
    () async {
      final gateway = _FakeHermesConnectionGateway(
        onPersist: (_) async => throw StateError('write failed'),
      );
      final controller = _configuredController(gateway);
      addTearDown(controller.dispose);

      final result = await controller.finishOnboarding(
        saved: const HermesConfig(),
        messages: _messages,
      );

      check(result.outcome).equals(HermesConnectionOutcome.persistenceFailed);
      check(gateway.calls).deepEquals(['probe', 'persist']);
      check(controller.apiKey.text).equals('secret-key');
      check(controller.attempt.message).equals('Could not save');
    },
  );

  test(
    'an in-flight probe can finish after the controller is disposed',
    () async {
      final probe = Completer<bool>();
      final gateway = _FakeHermesConnectionGateway(
        onProbe: (_) => probe.future,
      );
      final controller = _configuredController(gateway);

      final result = controller.testConnection(
        saved: const HermesConfig(),
        messages: _messages,
      );
      await Future<void>.delayed(Duration.zero);
      controller.dispose();
      probe.complete(true);

      check(await result).isTrue();
    },
  );

  test(
    'disposed onboarding cannot persist or activate after a late probe',
    () async {
      final probe = Completer<bool>();
      final gateway = _FakeHermesConnectionGateway(
        onProbe: (_) => probe.future,
      );
      final controller = _configuredController(gateway);

      final result = controller.finishOnboarding(
        saved: const HermesConfig(),
        messages: _messages,
      );
      await Future<void>.delayed(Duration.zero);
      controller.dispose();
      probe.complete(true);

      check((await result).outcome).equals(HermesConnectionOutcome.ignored);
      check(gateway.calls).deepEquals(['probe']);
    },
  );

  test('onboarding commit compensates a partial activation', () async {
    final calls = <String>[];

    await check(
      runHermesOnboardingCommit(
        isCurrent: () => true,
        persist: () async => calls.add('persist'),
        enable: () async => calls.add('enable'),
        ensureSessionKey: () async {
          calls.add('session-key');
          throw StateError('secure storage unavailable');
        },
        selectBackend: () async => calls.add('select-backend'),
        rollback: () async => calls.add('rollback'),
      ),
    ).throws<HermesConnectionCommitException>((failure) {
      failure
          .has((value) => value.stage, 'stage')
          .equals(HermesConnectionCommitStage.activation);
      failure.has((value) => value.error, 'error').isA<StateError>();
    });

    check(calls).deepEquals(['persist', 'enable', 'session-key', 'rollback']);
  });
}

HermesConnectionController _configuredController(
  HermesConnectionGateway gateway,
) {
  final controller = HermesConnectionController(
    initialConfig: const HermesConfig(),
    gateway: gateway,
  );
  controller.url.text = 'https://hermes.example/v1';
  controller.apiKey.text = 'secret-key';
  controller.markApiKeyChanged();
  return controller;
}

final class _FakeHermesConnectionGateway implements HermesConnectionGateway {
  _FakeHermesConnectionGateway({
    this.probeResult = true,
    this.onProbe,
    this.onPersist,
    this.onActivate,
  });

  final bool probeResult;
  final Future<bool> Function(HermesConfig draft)? onProbe;
  final Future<void> Function(HermesConnectionDraft draft)? onPersist;
  final Future<void> Function()? onActivate;
  final List<String> calls = [];
  HermesConfig? probedDraft;
  HermesConnectionDraft? persistedDraft;

  @override
  Future<bool> probe(HermesConfig draft) async {
    calls.add('probe');
    probedDraft = draft;
    if (onProbe case final callback?) return callback(draft);
    return probeResult;
  }

  @override
  Future<void> persist(HermesConnectionDraft draft) async {
    calls.add('persist');
    persistedDraft = draft;
    await onPersist?.call(draft);
  }

  @override
  Future<void> commitOnboarding(
    HermesConnectionDraft draft, {
    required bool Function() isCurrent,
  }) async {
    try {
      await runHermesOnboardingCommit(
        isCurrent: isCurrent,
        persist: () async {
          await persist(draft);
        },
        enable: () async {},
        ensureSessionKey: () async => 'session-key',
        selectBackend: () async {
          calls.add('activate');
          await onActivate?.call();
        },
        rollback: () async {},
      );
    } on HermesConnectionCommitException {
      rethrow;
    }
  }
}
