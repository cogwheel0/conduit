import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/controllers/hermes_connection_controller.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/services/hermes_api_service.dart';
import 'package:conduit/features/hermes/services/hermes_connection_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _messages = HermesConnectionMessages(
  connecting: 'Connecting',
  connected: 'Connected',
  saved: 'Saved',
  unreachable: 'Could not connect',
  persistenceFailed: 'Could not save',
  activationFailed: 'Could not activate',
);

void main() {
  test('plaintext HTTP is accepted for any Hermes host', () {
    check(HermesConfig.connectionOrigin('http://api.example.com:8642'))
        .equals('http://api.example.com:8642');
    check(HermesConfig.connectionOrigin('http://192.168.1.10:8642'))
        .equals('http://192.168.1.10:8642');
    check(HermesConfig.connectionOrigin('https://api.example.com:8642'))
        .equals('https://api.example.com:8642');
    check(HermesConfig.connectionOrigin('ftp://api.example.com')).isNull();
    check(
      const HermesConfig(
        enabled: true,
        baseUrl: 'http://api.example.com:8642',
        apiKey: 'persisted-secret',
      ).isUsable,
    ).isTrue();
  });

  test('custom access headers reach the server in Responses mode', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final received = Completer<HttpHeaders>();
    server.listen((request) async {
      if (!received.isCompleted) received.complete(request.headers);
      request.response.headers.contentType = ContentType.json;
      request.response.write('{}');
      await request.response.close();
    });

    final service = HermesApiService(
      config: HermesConfig(
        enabled: true,
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        apiKey: 'secret-key',
        desktopCredentials: HermesDesktopCredentials(
          accessHeaders: const {'CF-Access-Client-Id': 'client-id'},
        ),
      ),
    );
    addTearDown(service.close);
    await service.getCapabilities();

    final headers = await received.future;
    check(headers.value('cf-access-client-id')).equals('client-id');
    check(headers.value(HttpHeaders.authorizationHeader))
        .equals('Bearer secret-key');
  });

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
    'connection test verifies authenticated capabilities and toolsets',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requests = <String>[];
      server.listen((request) async {
        requests.add(request.uri.path);
        check(request.headers.value(HttpHeaders.authorizationHeader))
            .equals('Bearer secret-key');
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          request.uri.path == '/v1/toolsets' ? '[]' : '{}',
        );
        await request.response.close();
      });

      final connected = await testHermesDraftConnection(
        HermesConfig(
          enabled: false,
          baseUrl: 'http://127.0.0.1:${server.port}/v1',
          apiKey: 'secret-key',
        ),
      );

      check(connected).isTrue();
      check(requests).deepEquals(<String>['/v1/capabilities', '/v1/toolsets']);
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
    controller.setMode(HermesBackendMode.desktopGateway);
    controller.setDesktopProfile('work');

    final draft = controller.buildDraft(saved);

    check(saved.baseUrl).equals('https://one.example/v1');
    check(saved.apiKey).equals('old-key');
    check(saved.sessionKey).equals('old-memory');
    check(draft.config.enabled).isTrue();
    check(draft.config.baseUrl).equals('https://two.example/v1');
    check(draft.config.apiKey).equals('new-key');
    check(draft.config.sessionKey).isNull();
    check(draft.config.desktopProfile).equals('work');
    check(draft.apiKeyChanged).isTrue();
    check(draft.sessionKeyChanged).isTrue();
  });

  test('origin change does not carry access headers to the new server', () {
    final saved = HermesConfig(
      enabled: true,
      baseUrl: 'https://one.example',
      mode: HermesBackendMode.desktopGateway,
      desktopCredentials: HermesDesktopCredentials(
        accessHeaders: {'CF-Access-Client-Secret': 'old-origin-secret'},
      ),
    );
    final controller = HermesConnectionController(
      initialConfig: saved,
      gateway: _FakeHermesConnectionGateway(),
    );
    addTearDown(controller.dispose);
    controller.url.text = 'https://two.example';
    controller.markUrlChanged();

    check(controller.buildDraft(saved).config.accessHeaders).isEmpty();

    controller.setAccessHeaders({'X-New-Origin': 'new-origin-secret'});
    check(controller.buildDraft(saved).config.accessHeaders)
        .deepEquals({'X-New-Origin': 'new-origin-secret'});

    controller.setAccessHeaders({
      'CF-Access-Client-Secret': 'old-origin-secret',
      'X-New-Origin': 'new-origin-secret',
    });
    check(controller.buildDraft(saved).config.accessHeaders)
        .deepEquals({'X-New-Origin': 'new-origin-secret'});

    controller.setAccessHeaders({
      'cf-access-client-secret': 'old-origin-secret',
      'X-New-Origin': 'new-origin-secret',
    });
    check(controller.buildDraft(saved).config.accessHeaders)
        .deepEquals({'X-New-Origin': 'new-origin-secret'});

    controller.setAccessHeaders({
      'X-Renamed': 'old-origin-secret',
      'X-New-Origin': 'new-origin-secret',
    });
    check(controller.buildDraft(saved).config.accessHeaders)
        .deepEquals({'X-New-Origin': 'new-origin-secret'});
  });

  test('saved headers become the baseline for a later origin change', () async {
    final gateway = _FakeHermesConnectionGateway();
    var saved = HermesConfig(
      enabled: true,
      baseUrl: 'https://one.example',
      mode: HermesBackendMode.desktopGateway,
    );
    final controller = HermesConnectionController(
      initialConfig: saved,
      gateway: gateway,
    );
    addTearDown(controller.dispose);
    controller.setAccessHeaders({'X-One': 'one-secret'});
    check(await controller.save(saved, messages: _messages)).isTrue();
    saved = gateway.persistedDraft!.config;

    controller.url.text = 'https://two.example';
    controller.markUrlChanged();
    controller.setAccessHeaders({'X-One': 'one-secret', 'X-Two': 'two-secret'});

    check(controller.buildDraft(saved).config.accessHeaders)
        .deepEquals({'X-Two': 'two-secret'});
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
      check(identical(gateway.probedDraft, gateway.persistedDraft!.config))
          .isTrue();
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
      check(controller.validationIssue).isNull();
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
    'editing the draft invalidates an in-flight connection result',
    () async {
      final probe = Completer<bool>();
      final controller = _configuredController(
        _FakeHermesConnectionGateway(onProbe: (_) => probe.future),
      );
      addTearDown(controller.dispose);

      final result = controller.testConnection(
        saved: const HermesConfig(),
        messages: _messages,
      );
      await Future<void>.delayed(Duration.zero);
      check(controller.operation).equals(HermesConnectionOperation.testing);

      controller.url.text = 'https://replacement.example/v1';
      controller.markUrlChanged();
      probe.complete(true);

      check(await result).isTrue();
      check(controller.operation).equals(HermesConnectionOperation.idle);
      check(controller.attempt.isVisible).isFalse();
    },
  );

  test('successful save clears a stale connection-test result', () async {
    final controller = _configuredController(
      _FakeHermesConnectionGateway(probeResult: false),
    );
    addTearDown(controller.dispose);

    check(
      await controller.testConnection(
        saved: const HermesConfig(),
        messages: _messages,
      ),
    ).isFalse();
    check(controller.attempt.isVisible).isTrue();

    check(await controller.save(const HermesConfig(), messages: _messages))
        .isTrue();

    check(controller.operation).equals(HermesConnectionOperation.idle);
    check(controller.attempt.message).equals('Saved');
  });

  test(
    'external sign-in failure is presented by the connection controller',
    () {
      final controller = _configuredController(_FakeHermesConnectionGateway());
      addTearDown(controller.dispose);

      controller.reportFailure('Sign-in failed');

      check(controller.operation).equals(HermesConnectionOperation.idle);
      check(controller.attempt.message).equals('Sign-in failed');
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

  test('cancelled onboarding still surfaces a rollback failure', () async {
    final commitStarted = Completer<void>();
    final releaseCommit = Completer<void>();
    final rollbackError = StateError('rollback failed');
    final gateway = _FakeHermesConnectionGateway(
      onCommit: (_, _) async {
        commitStarted.complete();
        await releaseCommit.future;
        throw HermesConnectionCommitException(
          stage: HermesConnectionCommitStage.rollback,
          error: const HermesConnectionCommitCancelled(),
          rollbackError: rollbackError,
        );
      },
    );
    final controller = _configuredController(gateway);
    addTearDown(controller.dispose);

    final result = controller.finishOnboarding(
      saved: const HermesConfig(),
      messages: _messages,
    );
    await commitStarted.future;
    controller.cancelPendingOnboarding();
    releaseCommit.complete();

    final failure = await result;
    check(failure.outcome).equals(HermesConnectionOutcome.activationFailed);
    check(failure.error).identicalTo(rollbackError);
    check(controller.operation).equals(HermesConnectionOperation.idle);
  });

  test(
    'a committed save can finish after the controller is disposed',
    () async {
      final persist = Completer<void>();
      final gateway = _FakeHermesConnectionGateway(
        onPersist: (_) => persist.future,
      );
      final controller = _configuredController(gateway);

      final result = controller.save(const HermesConfig(), messages: _messages);
      await Future<void>.delayed(Duration.zero);
      controller.dispose();
      persist.complete();

      check(await result).isTrue();
      check(gateway.calls).deepEquals(['persist']);
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

  for (final failedStep in <String>{
    'deactivate',
    'restore-connection',
    'restore-enabled',
    'restore-backend',
  }) {
    test(
      'onboarding rollback continues safely when $failedStep fails',
      () async {
        final calls = <String>[];
        var enableCall = 0;
        final injectedError = StateError('$failedStep failed');
        final expectedStep = switch (failedStep) {
          'deactivate' => HermesConnectionRollbackStep.deactivate,
          'restore-connection' =>
            HermesConnectionRollbackStep.restoreConnection,
          'restore-enabled' => HermesConnectionRollbackStep.restoreEnabled,
          'restore-backend' => HermesConnectionRollbackStep.restoreBackend,
          _ => throw StateError('unexpected test step'),
        };

        await check(
          runHermesOnboardingRollback(
            previousEnabled: true,
            setEnabled: (enabled) async {
              enableCall++;
              final step = enableCall == 1 ? 'deactivate' : 'restore-enabled';
              calls.add('$step:$enabled');
              if (failedStep == step) throw injectedError;
            },
            restoreConnection: () async {
              calls.add('restore-connection');
              if (failedStep == 'restore-connection') {
                throw injectedError;
              }
            },
            restoreBackend: () async {
              calls.add('restore-backend');
              if (failedStep == 'restore-backend') {
                throw injectedError;
              }
            },
          ),
        ).throws<HermesConnectionRollbackException>((failure) {
          failure.has((value) => value.failures, 'failures').length.equals(1);
          failure
              .has((value) => value.failures.single.step, 'step')
              .equals(expectedStep);
          failure
              .has((value) => value.failures.single.errorType, 'errorType')
              .equals(injectedError.runtimeType.toString());
        });

        check(calls).deepEquals(
          failedStep == 'restore-connection'
              ? ['deactivate:false', 'restore-connection', 'restore-backend']
              : [
                  'deactivate:false',
                  'restore-connection',
                  'restore-enabled:true',
                  'restore-backend',
                ],
        );
      },
    );
  }
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
    this.onCommit,
  });

  final bool probeResult;
  final Future<bool> Function(HermesConfig draft)? onProbe;
  final Future<void> Function(HermesConnectionDraft draft)? onPersist;
  final Future<void> Function()? onActivate;
  final Future<void> Function(
    HermesConnectionDraft draft,
    bool Function() isCurrent,
  )?
  onCommit;
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
    if (onCommit case final callback?) {
      await callback(draft, isCurrent);
      return;
    }
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
