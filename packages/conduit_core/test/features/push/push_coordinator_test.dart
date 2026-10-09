import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/push/models/push_status.dart';
import 'package:conduit_core/features/push/models/push_subscription_record.dart';
import 'package:conduit_core/features/push/models/push_target.dart';
import 'package:conduit_core/features/push/providers/push_providers.dart';
import 'package:conduit_core/features/push/services/hermes_push_backend.dart';
import 'package:conduit_core/features/push/services/push_backend.dart';
import 'package:conduit_core/features/push/services/push_backend_factory.dart';
import 'package:conduit_core/features/push/services/push_relay_client.dart';
import 'package:conduit_core/features/push/services/push_settings_store.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/ports/push_platform_port.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _owui = OpenWebUiPushTarget(
  accountId: 'acct-1',
  label: 'ada@example.com',
);
const _owui2 = OpenWebUiPushTarget(
  accountId: 'acct-2',
  label: 'bob@example.com',
);
const _hermes = HermesPushTarget(
  connectionId: 'conn-1',
  label: 'Home Hermes',
  baseUrl: 'https://hermes.test',
  mode: HermesBackendMode.responsesApi,
  credentialsRevision: 'rev-1',
);

void main() {
  late _Harness h;

  setUp(() {
    PreferencesStore.debugOverride(InMemoryKeyValueStore());
  });

  tearDown(() async {
    _Harness.last?.dispose();
    _Harness.last = null;
    PreferencesStore.debugReset();
  });

  group('setting up', () {
    test('turning push on sets up every target and verifies it', () async {
      h = await _Harness.start(targets: [_owui, _hermes]);
      await h.coordinator.setEnabled(true);

      check(h.status(_owui.scope)).equals(PushStatus.on);
      check(h.status(_hermes.scope)).equals(PushStatus.on);
      check(h.state.enabled).isTrue();
      check(h.platform.subscriptions).length.equals(2);
      // Relay registration with the token, then the server got the endpoint.
      check(h.relay.registrations).length.equals(2);
      final owuiSub = h.server(_owui).subscriptions.values.single;
      check(owuiSub.endpoint).startsWith('https://relay.test/v1/push/');
      check(owuiSub.events).deepEquals(['reply', 'reply_failed', 'channel']);
      check(owuiSub.origin).equals(PushOrigin.conduit);
      check(h.server(_hermes).subscriptions.values.single.events)
          .deepEquals(['reply', 'reply_failed', 'cron']);
      check(h.record(_owui.scope).verifiedAt).isNotNull();
      // Push on turns notifications on.
      check(h.settings.state.notificationsEnabled).isTrue();
    });

    test('a test nonce found by polling also verifies', () async {
      h = await _Harness.start(targets: [_owui]);
      h.server(_owui).delivery = _Delivery.poll;
      await h.coordinator.setEnabled(true);
      check(h.status(_owui.scope)).equals(PushStatus.on);
    });

    test('a foreground test push also verifies', () async {
      h = await _Harness.start(targets: [_owui]);
      h.server(_owui).delivery = _Delivery.foreground;
      await h.coordinator.setEnabled(true);
      check(h.status(_owui.scope)).equals(PushStatus.on);
    });

    test('a test that never arrives fails with the server diagnosis', () async {
      h = await _Harness.start(targets: [_owui]);
      h.server(_owui)
        ..delivery = _Delivery.never
        ..diagnostics = const PushServerDiagnostics(error: 'blocked');
      await h.coordinator.setEnabled(true);

      final target = h.target(_owui.scope);
      check(target.status).equals(PushStatus.failed);
      check(target.failure).equals(
        const PushFailure(PushFailureReason.deliveryFailed, detail: 'blocked'),
      );
      check(target.diagnostics?.error).equals('blocked');
      await pumpEventQueue();
      check(h.record(_owui.scope).lastError?.detail).equals('blocked');
    });

    test('a test without a diagnosis times out', () async {
      h = await _Harness.start(targets: [_owui]);
      h.server(_owui).delivery = _Delivery.never;
      await h.coordinator.setEnabled(true);
      check(h.target(_owui.scope).failure?.reason)
          .equals(PushFailureReason.testTimeout);
    });

    test('a test the server could not send fails at once', () async {
      h = await _Harness.start(targets: [_hermes]);
      h.server(_hermes)
        ..delivery = _Delivery.never
        ..dispatch = (nonce) => PushTestDispatch(
          diagnostics: PushServerDiagnostics(
            code: 410,
            error: 'gone',
            nonce: nonce,
          ),
        );
      final started = DateTime.now();
      await h.coordinator.setEnabled(true);
      check(h.target(_hermes.scope).failure).equals(
        const PushFailure(PushFailureReason.deliveryFailed, detail: 'gone'),
      );
      check(DateTime.now().difference(started))
          .isLessThan(_Harness.timings.testTimeout);
    });
  });

  group('statuses', () {
    Future<PushTargetState> probed(PushProbe probe) async {
      h = await _Harness.start(targets: [_owui]);
      h.server(_owui).probe = probe;
      await h.coordinator.setEnabled(true);
      return h.target(_owui.scope);
    }

    for (final (outcome, status) in [
      (PushProbeOutcome.needsAdminSetup, PushStatus.needsAdminSetup),
      (PushProbeOutcome.canInstall, PushStatus.canInstall),
      (PushProbeOutcome.pluginsDisabled, PushStatus.pluginsDisabled),
      (PushProbeOutcome.serverTooOld, PushStatus.serverTooOld),
      (PushProbeOutcome.restartHermes, PushStatus.restartHermes),
      (PushProbeOutcome.signInNeeded, PushStatus.signInNeeded),
    ]) {
      test('${outcome.name} shows as ${status.name}', () async {
        final target = await probed(PushProbe(outcome));
        check(target.status).equals(status);
        check(h.server(_owui).subscriptions).isEmpty();
      });
    }

    test('a missing Hermes plugin carries its install command', () async {
      final target = await probed(
        const PushProbe(
          PushProbeOutcome.needsHermesPlugin,
          hermesInstallCommand: 'hermes plugins install x --enable',
        ),
      );
      check(target.status).equals(PushStatus.needsHermesPlugin);
      check(target.hermesInstallCommand)
          .equals('hermes plugins install x --enable');
    });

    test('a failed probe shows its reason', () async {
      final target = await probed(
        const PushProbe(
          PushProbeOutcome.failed,
          failure: PushFailure(PushFailureReason.serverUnreachable),
        ),
      );
      check(target.status).equals(PushStatus.failed);
      check(target.failure?.reason).equals(PushFailureReason.serverUnreachable);
    });

    test(
      'an outdated function still verifies, then offers the update',
      () async {
        final target = await probed(
          const PushProbe.ready(updateAvailable: true, pluginVersion: '1.0.0'),
        );
        check(target.status).equals(PushStatus.updateAvailable);
        check(target.isVerified).isTrue();
      },
    );

    test('a session that is gone needs sign-in', () async {
      h = await _Harness.start(targets: [_owui]);
      h.factory.openErrors[_owui.scope] = const PushBackendException(
        PushFailure(PushFailureReason.serverRejected),
        signInNeeded: true,
      );
      await h.coordinator.setEnabled(true);
      check(h.status(_owui.scope)).equals(PushStatus.signInNeeded);
    });

    test(
      'a signed-out account needs sign-in without asking its server',
      () async {
        h = await _Harness.start(
          targets: [
            const OpenWebUiPushTarget(
              accountId: 'acct-1',
              label: 'x',
              hasSession: false,
            ),
          ],
        );
        await h.coordinator.setEnabled(true);
        check(h.status(_owui.scope)).equals(PushStatus.signInNeeded);
        check(h.log).not((it) => it.contains('probe ${_owui.scope}'));
      },
    );

    test('a build without a relay cannot use APNs', () async {
      h = await _Harness.start(targets: [_owui], relay: false);
      await h.coordinator.setEnabled(true);
      check(h.status(_owui.scope)).equals(PushStatus.relayUnavailable);
      check(h.state.relayConfigured).isFalse();
      check(h.platform.subscriptions).isEmpty();
    });

    test('a relay that refuses this app is unavailable', () async {
      h = await _Harness.start(targets: [_owui]);
      h.relay.registerStatus = 403;
      await h.coordinator.setEnabled(true);
      check(h.status(_owui.scope)).equals(PushStatus.relayUnavailable);
    });

    test('denied permission', () async {
      h = await _Harness.start(targets: [_owui]);
      h.platform.permission = false;
      await h.coordinator.setEnabled(true);
      check(h.status(_owui.scope)).equals(PushStatus.permissionDenied);
      check(h.state.permissionDenied).isTrue();

      h.platform.permission = true;
      await h.coordinator.retry(_owui.scope);
      check(h.status(_owui.scope)).equals(PushStatus.on);
      check(h.state.permissionDenied).isFalse();
    });

    test('no token', () async {
      h = await _Harness.start(targets: [_owui]);
      h.platform.tokenError = _PlatformError('apns_timeout');
      await h.coordinator.setEnabled(true);
      check(h.target(_owui.scope).failure).equals(
        const PushFailure(PushFailureReason.noToken, detail: 'apns_timeout'),
      );
    });

    test('a function removed since the probe says so', () async {
      h = await _Harness.start(targets: [_owui]);
      h.server(_owui)
        ..subscribeError = const PushBackendException(
          PushFailure(
            PushFailureReason.serverRejected,
            detail: 'function_missing',
          ),
        )
        ..probeAfterSubscribeError = const PushProbe(
          PushProbeOutcome.needsAdminSetup,
        );
      await h.coordinator.setEnabled(true);
      check(h.status(_owui.scope)).equals(PushStatus.needsAdminSetup);
    });
  });

  group('installing', () {
    test('an admin installs the function, then push is verified', () async {
      h = await _Harness.start(targets: [_owui]);
      h.server(_owui)
        ..probe = const PushProbe(PushProbeOutcome.canInstall)
        ..probeAfterInstall = const PushProbe.ready();
      await h.coordinator.setEnabled(true);
      check(h.status(_owui.scope)).equals(PushStatus.canInstall);

      check(await h.coordinator.installOpenWebUiFunction(_owui.scope)).isTrue();
      check(h.server(_owui).installs).equals(1);
      check(h.status(_owui.scope)).equals(PushStatus.on);
    });

    test('a failed install shows the server message', () async {
      h = await _Harness.start(targets: [_owui]);
      h.server(_owui)
        ..probe = const PushProbe(PushProbeOutcome.canInstall)
        ..installError = const PushBackendException(
          PushFailure(PushFailureReason.installFailed, detail: 'not_admin'),
        );
      await h.coordinator.setEnabled(true);
      check(await h.coordinator.installOpenWebUiFunction(_owui.scope))
          .isFalse();
      check(h.target(_owui.scope).failure).equals(
        const PushFailure(PushFailureReason.installFailed, detail: 'not_admin'),
      );
    });

    test('the Hermes plugin installs, then waits for the restart', () async {
      const desktop = HermesPushTarget(
        connectionId: 'conn-d',
        label: 'Desktop',
        baseUrl: 'https://desk.test',
        mode: HermesBackendMode.desktopGateway,
      );
      h = await _Harness.start(targets: [desktop]);
      h.server(desktop)
        ..probe = const PushProbe(
          PushProbeOutcome.needsHermesPlugin,
          canInstallHermesPlugin: true,
        )
        ..probeAfterInstall = const PushProbe(PushProbeOutcome.restartHermes)
        ..readyAfterProbes = 2;
      await h.coordinator.setEnabled(true);
      check(h.status(desktop.scope)).equals(PushStatus.needsHermesPlugin);

      check(await h.coordinator.installHermesPlugin(desktop.scope)).isTrue();
      check(h.status(desktop.scope)).equals(PushStatus.on);
    });

    test('an API server connection cannot install in one tap', () async {
      h = await _Harness.start(targets: [_hermes]);
      await h.coordinator.setEnabled(true);
      check(await h.coordinator.installHermesPlugin(_hermes.scope)).isFalse();
      check(h.server(_hermes).installs).equals(0);
    });
  });

  group('keeping up', () {
    test('a new token registers every sid again', () async {
      h = await _Harness.start(targets: [_owui, _hermes]);
      await h.coordinator.setEnabled(true);
      check(h.relay.registrations).length.equals(2);
      final before = h.record(_owui.scope).endpoint;

      h.platform.token = 'bb' * 32;
      h.platform.emit(
        PushTokenEvent(
          PushDeviceToken(
            transport: PushTransport.apns,
            token: 'bb' * 32,
            app: 'app.test',
            env: 'dev',
          ),
        ),
      );
      await h.until(() => h.relay.registrations.length == 4 && h.allOn());

      check(h.relay.registrations.skip(2).map((r) => r['token']).toSet())
          .deepEquals({'bb' * 32});
      check(h.record(_owui.scope).endpoint).not((it) => it.equals(before));
      // The new endpoint was tested again.
      check(h.server(_owui).tests).equals(2);
    });

    test('a newer relay key registers again on the next check', () async {
      h = await _Harness.start(targets: [_owui]);
      await h.coordinator.setEnabled(true);
      check(h.record(_owui.scope).kid).equals(1);

      h.relay.activeKid = 2;
      await h.coordinator.setEnabled(true);
      check(h.relay.registrations).length.equals(2);
      check(h.record(_owui.scope).kid).equals(2);
      check(PushRelayClient.kidOfEndpoint(h.record(_owui.scope).endpoint!))
          .equals(2);
    });

    test('an unchanged target is not registered or tested again', () async {
      h = await _Harness.start(targets: [_owui]);
      await h.coordinator.setEnabled(true);
      await h.coordinator.retry(_owui.scope);
      check(h.relay.registrations).length.equals(1);
      check(h.server(_owui).tests).equals(1);
      check(h.server(_owui).subscribes).equals(2);
    });

    test('kind toggles upload new events without a new test', () async {
      h = await _Harness.start(targets: [_owui, _hermes]);
      await h.coordinator.setEnabled(true);

      h.settings.set(
        h.settings.state.copyWith(
          notificationChatEnabled: false,
          notificationChannelEnabled: false,
        ),
      );
      await h.until(
        () =>
            h.server(_owui).subscriptions.values.single.events.isEmpty &&
            h.server(_hermes).subscriptions.values.single.events.length == 1,
      );
      check(h.server(_hermes).subscriptions.values.single.events)
          .deepEquals(['cron']);
      check(h.server(_owui).tests).equals(1);
      check(h.record(_owui.scope).events).isNotNull().isEmpty();
    });

    test('the origin choice reaches the server', () async {
      h = await _Harness.start(targets: [_owui]);
      await h.coordinator.setEnabled(true);
      await h.coordinator.setOrigin(_owui.scope, PushOrigin.any);

      check(h.server(_owui).subscriptions.values.single.origin)
          .equals(PushOrigin.any);
      check(h.target(_owui.scope).origin).equals(PushOrigin.any);
      check(h.record(_owui.scope).origin).equals(PushOrigin.any);
    });

    test('a new account is set up, a removed one cleaned up', () async {
      h = await _Harness.start(targets: [_owui]);
      await h.coordinator.setEnabled(true);
      final sid = h.record(_owui.scope).sid!;

      h.setTargets([_owui2]);
      await h.until(
        () =>
            h.state.targets[_owui2.scope]?.status == PushStatus.on &&
            !h.state.targets.containsKey(_owui.scope) &&
            h.log.contains('cancelScope ${_owui.scope}'),
      );
      check(h.server(_owui).subscriptions).isEmpty();
      check(h.platform.subscriptions.keys).not((it) => it.contains(sid));
      check(h.settingsStore.records().containsKey(_owui.scope)).isFalse();
    });

    test('a Hermes address change replaces the subscription', () async {
      h = await _Harness.start(targets: [_hermes]);
      await h.coordinator.setEnabled(true);
      final oldSid = h.record(_hermes.scope).sid!;

      const moved = HermesPushTarget(
        connectionId: 'conn-1',
        label: 'Home Hermes',
        baseUrl: 'https://hermes-new.test',
        mode: HermesBackendMode.responsesApi,
        credentialsRevision: 'rev-2',
      );
      h.setTargets([moved]);
      await h.until(
        () =>
            h.record(_hermes.scope).sid != oldSid &&
            h.status(_hermes.scope) == PushStatus.on,
      );
      check(h.log).contains('unsubscribe ${_hermes.scope} $oldSid');
      check(h.platform.subscriptions.keys).not((it) => it.contains(oldSid));
      check(h.server(_hermes).subscriptions.keys)
          .deepEquals([h.record(_hermes.scope).sid!]);
    });

    test('an unregistered UnifiedPush sid registers again', () async {
      h = await _Harness.start(targets: [_owui], unifiedPush: true);
      await h.coordinator.setEnabled(true);
      check(h.state.effectiveTransport).equals(PushTransport.unifiedPush);
      final sid = h.record(_owui.scope).sid!;
      check(h.record(_owui.scope).endpoint).equals('https://up.test/$sid/1');

      h.platform.emit(PushUnregisteredEvent(sid));
      await h.until(
        () =>
            h.record(_owui.scope).endpoint == 'https://up.test/$sid/2' &&
            h.status(_owui.scope) == PushStatus.on,
      );
      check(h.relay.registrations).isEmpty();
    });

    test(
      'a new UnifiedPush endpoint goes to the server and is tested',
      () async {
        h = await _Harness.start(targets: [_owui], unifiedPush: true);
        await h.coordinator.setEnabled(true);
        final sid = h.record(_owui.scope).sid!;

        h.platform.emit(
          PushUnifiedPushEndpointEvent(sid, 'https://up.test/moved'),
        );
        await h.until(
          () =>
              h.server(_owui).subscriptions[sid]?.endpoint ==
                  'https://up.test/moved' &&
              h.server(_owui).tests == 2 &&
              h.status(_owui.scope) == PushStatus.on,
        );
      },
    );

    test('Android prefers FCM and switches to UnifiedPush on request', () async {
      h = await _Harness.start(targets: [_owui], fcm: true, unifiedPush: true);
      await h.coordinator.setEnabled(true);
      check(h.record(_owui.scope).transport).equals(PushTransport.fcm);

      await h.coordinator.setAndroidTransport(
        PushAndroidTransport.unifiedPush,
        distributor: 'org.unifiedpush.distributor.ntfy',
      );
      check(h.record(_owui.scope).transport).equals(PushTransport.unifiedPush);
      check(h.status(_owui.scope)).equals(PushStatus.on);
      check(h.log).contains(
        'registerUp ${h.record(_owui.scope).sid} org.unifiedpush.distributor.ntfy',
      );
      check(h.state.androidTransport).equals(PushAndroidTransport.unifiedPush);
      check(await h.coordinator.distributors())
          .deepEquals(['org.unifiedpush.distributor.ntfy']);
    });

    test('a restart within a day checks only what is not on', () async {
      h = await _Harness.start(targets: [_owui, _owui2]);
      h.server(_owui2).probe = const PushProbe(
        PushProbeOutcome.needsAdminSetup,
      );
      await h.coordinator.setEnabled(true);
      h.dispose();

      h = await _Harness.start(targets: [_owui, _owui2], keepPreferences: true);
      await h.until(() => h.log.contains('probe ${_owui2.scope}'));
      await pumpEventQueue();
      check(h.log).not((it) => it.contains('probe ${_owui.scope}'));
      check(h.status(_owui.scope)).equals(PushStatus.on);
    });
  });

  group('removing', () {
    test(
      'signing out unsubscribes, then deletes keys, then notifications',
      () async {
        h = await _Harness.start(targets: [_owui]);
        await h.coordinator.setEnabled(true);
        final sid = h.record(_owui.scope).sid!;
        h.log.clear();

        await h.container
            .read(pushSignOutHookProvider)
            .beforeOpenWebUiSignOut('acct-1');

        check(h.log).deepEquals([
          'unsubscribe ${_owui.scope} $sid',
          'delete $sid',
          'cancelScope ${_owui.scope}',
        ]);
        check(h.status(_owui.scope)).equals(PushStatus.signInNeeded);
        check(h.record(_owui.scope).sid).isNull();
        check(h.settingsStore.tombstones()).isEmpty();
      },
    );

    test('a server that does not answer cannot hold up a sign-out', () async {
      h = await _Harness.start(targets: [_owui]);
      await h.coordinator.setEnabled(true);
      final sid = h.record(_owui.scope).sid!;
      h.server(_owui).unsubscribeHangs = true;

      final started = DateTime.now();
      await h.container
          .read(pushSignOutHookProvider)
          .beforeOpenWebUiSignOut('acct-1');
      check(DateTime.now().difference(started))
          .isLessThan(const Duration(seconds: 2));
      // The keys are gone anyway; the server copy is retried later.
      check(h.platform.subscriptions.keys).not((it) => it.contains(sid));
      check(h.settingsStore.tombstones().map((t) => t.sid)).deepEquals([sid]);
    });

    test('turning push off removes everything', () async {
      h = await _Harness.start(targets: [_owui, _hermes]);
      await h.coordinator.setEnabled(true);
      await h.coordinator.setEnabled(false);

      check(h.platform.subscriptions).isEmpty();
      check(h.server(_owui).subscriptions).isEmpty();
      check(h.server(_hermes).subscriptions).isEmpty();
      check(h.status(_owui.scope)).equals(PushStatus.off);
      check(h.status(_hermes.scope)).equals(PushStatus.off);
      check(h.settingsStore.enabled).isFalse();
      await pumpEventQueue();
      check(h.platform.config?.enabled).equals(false);
    });

    test('opting one target out keeps the others', () async {
      h = await _Harness.start(targets: [_owui, _hermes]);
      await h.coordinator.setEnabled(true);
      await h.coordinator.setTargetOptedOut(_owui.scope, true);

      check(h.status(_owui.scope)).equals(PushStatus.off);
      check(h.target(_owui.scope).optedOut).isTrue();
      check(h.server(_owui).subscriptions).isEmpty();
      check(h.status(_hermes.scope)).equals(PushStatus.on);
      await pumpEventQueue();
      check(h.platform.config!.disabledScopes).deepEquals([_owui.scope]);

      await h.coordinator.setTargetOptedOut(_owui.scope, false);
      check(h.status(_owui.scope)).equals(PushStatus.on);
    });

    test('a full sign-out releases every target', () async {
      h = await _Harness.start(targets: [_owui, _hermes]);
      await h.coordinator.setEnabled(true);
      await h.container.read(pushSignOutHookProvider).beforeFullSignOut();

      check(h.platform.subscriptions).isEmpty();
      check(h.server(_owui).subscriptions).isEmpty();
      check(h.server(_hermes).subscriptions).isEmpty();
      check(h.state.enabled).isFalse();
      check(h.settingsStore.records()).isEmpty();
    });

    test('resetting keys sets everything up with new ones', () async {
      h = await _Harness.start(targets: [_owui]);
      await h.coordinator.setEnabled(true);
      final sid = h.record(_owui.scope).sid!;
      await h.coordinator.resetKeys();

      final fresh = h.record(_owui.scope).sid!;
      check(fresh).not((it) => it.equals(sid));
      check(h.server(_owui).subscriptions.keys).deepEquals([fresh]);
      check(h.status(_owui.scope)).equals(PushStatus.on);
    });

    test('push off at start deletes keys nothing uses', () async {
      h = await _Harness.start(targets: [_owui]);
      await h.platform.createSubscription(
        _owui.scope,
        age: const Duration(hours: 1),
      );
      h.dispose();
      final platform = h.platform;

      h = await _Harness.start(
        targets: [_owui],
        keepPreferences: true,
        platform: platform,
      );
      await h.until(() => platform.subscriptions.isEmpty);
    });
  });

  group('display config', () {
    test('mirrors settings, labels and strings', () async {
      h = await _Harness.start(targets: [_owui, _hermes]);
      await h.coordinator.setEnabled(true);
      await pumpEventQueue();

      final config = h.platform.config!;
      check(config.enabled).isTrue();
      check(config.sound).isTrue();
      check(config.enabledKinds)
          .deepEquals(['reply', 'reply_failed', 'channel', 'cron', 'test']);
      check(config.scopeLabels).deepEquals({
        _owui.scope: 'ada@example.com',
        _hermes.scope: 'Home Hermes',
      });
      check(config.showScopeLabel).isTrue();
      check(config.strings['cronTitle']).equals('Scheduled task');
    });

    test('one target shows no label', () async {
      h = await _Harness.start(targets: [_owui]);
      await h.coordinator.setEnabled(true);
      await pumpEventQueue();
      check(h.platform.config!.showScopeLabel).isFalse();
    });
  });

  group('Hermes', () {
    test('a started reply is watched on an API server connection', () async {
      h = await _Harness.start(targets: [_hermes], realHermes: true);
      await h.coordinator.setEnabled(true);
      check(h.status(_hermes.scope)).equals(PushStatus.on);

      h.container.read(pushHermesSessionWatchProvider)('conn-1', 'session-7');
      await h.until(() => h.gateway.ops.contains('watch'));
      check(h.gateway.bodies.last)
          .deepEquals({'op': 'watch', 'session_id': 'session-7', 'ttl': 21600});
    });

    test('nothing is watched while push is off', () async {
      h = await _Harness.start(targets: [_hermes], realHermes: true);
      h.container.read(pushHermesSessionWatchProvider)('conn-1', 'session-7');
      await pumpEventQueue();
      check(h.gateway.ops).isEmpty();
    });

    test('notify me adds conduit to a job and removes it', () async {
      h = await _Harness.start(targets: [_hermes]);
      check(
        await h.coordinator.setHermesJobNotify(
          connectionId: 'conn-1',
          jobId: 'job-1',
          deliver: 'telegram',
          notify: true,
        ),
      ).equals('telegram,conduit');
      check(h.factory.jobs.updates).deepEquals({'job-1': 'telegram,conduit'});
      check(
        await h.coordinator.setHermesJobNotify(
          connectionId: 'conn-1',
          jobId: 'job-1',
          deliver: 'telegram,conduit',
          notify: false,
        ),
      ).equals('telegram');
      check(PushCoordinator.hermesJobNotifies('telegram,conduit')).isTrue();
    });
  });
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

final _targetsProvider = NotifierProvider<_TargetList, List<PushTarget>>(
  _TargetList.new,
);

final class _TargetList extends Notifier<List<PushTarget>> {
  static List<PushTarget> initial = const [];

  @override
  List<PushTarget> build() => initial;

  void set(List<PushTarget> targets) => state = targets;
}

final class _Settings extends AppSettingsNotifier {
  @override
  AppSettings build() => const AppSettings(notificationsEnabled: false);

  void set(AppSettings settings) => state = settings;
}

final class _Harness {
  _Harness._(this.container, this.log, this.platform, this.factory, this.relay);

  static const timings = PushTimings(
    testTimeout: Duration(milliseconds: 300),
    testPollInterval: Duration(milliseconds: 10),
    unsubscribeTimeout: Duration(milliseconds: 200),
    signOutTimeout: Duration(milliseconds: 400),
    releaseWait: Duration(milliseconds: 50),
    restartPollInterval: Duration(milliseconds: 10),
    restartPollTimeout: Duration(milliseconds: 500),
  );

  /// The harness the current test started last, disposed after it.
  static _Harness? last;

  final ProviderContainer container;
  final List<String> log;
  final _Platform platform;
  final _Factory factory;
  final _Relay relay;
  _Gateway get gateway => factory.gateway;

  static Future<_Harness> start({
    required List<PushTarget> targets,
    bool relay = true,
    bool fcm = false,
    bool unifiedPush = false,
    bool realHermes = false,
    bool keepPreferences = false,
    _Platform? platform,
  }) async {
    if (!keepPreferences) {
      PreferencesStore.debugOverride(InMemoryKeyValueStore());
    }
    final log = <String>[];
    final fake = platform ?? _Platform(log);
    fake.log = log;
    if (fcm || unifiedPush) {
      fake.transports = [
        if (fcm) PushTransport.fcm,
        if (unifiedPush) PushTransport.unifiedPush,
      ];
      if (unifiedPush) fake.distributors = ['org.unifiedpush.distributor.ntfy'];
    }
    final factory = _Factory(log, fake, realHermes: realHermes);
    for (final target in targets) {
      factory.servers.putIfAbsent(target.scope, () => _Server(target.scope));
    }
    final relayAdapter = _Relay();
    _TargetList.initial = targets;
    final container = ProviderContainer(
      overrides: [
        pushPlatformPortProvider.overrideWithValue(fake),
        pushRelayClientProvider.overrideWithValue(
          relay
              ? PushRelayClient(
                  baseUrl: 'https://relay.test',
                  dio: Dio()..httpClientAdapter = relayAdapter,
                )
              : null,
        ),
        pushBackendFactoryProvider.overrideWithValue(factory),
        pushTargetsProvider.overrideWith(
          (ref) async => ref.watch(_targetsProvider),
        ),
        pushTimingsProvider.overrideWithValue(timings),
        pushDeviceDescriptionProvider.overrideWithValue(
          const PushDeviceDescription(label: 'iOS', platform: 'ios'),
        ),
        appSettingsProvider.overrideWith(_Settings.new),
      ],
    );
    final harness = _Harness._(container, log, fake, factory, relayAdapter);
    last = harness;
    container.listen(pushCoordinatorProvider, (_, _) {});
    await container.read(pushTargetsProvider.future);
    await pumpEventQueue();
    await harness.until(() => harness.state.targets.length == targets.length);
    return harness;
  }

  PushCoordinator get coordinator =>
      container.read(pushCoordinatorProvider.notifier);
  PushState get state => container.read(pushCoordinatorProvider);
  _Settings get settings =>
      container.read(appSettingsProvider.notifier) as _Settings;
  PushSettingsStore get settingsStore => const PushSettingsStore();

  PushTargetState target(String scope) => state.targets[scope]!;
  PushStatus status(String scope) => target(scope).status;
  PushSubscriptionRecord record(String scope) =>
      settingsStore.records()[scope] ?? const PushSubscriptionRecord();
  _Server server(PushTarget target) => factory.servers[target.scope]!;

  bool allOn() => state.targets.values.every((t) => t.status == PushStatus.on);

  void setTargets(List<PushTarget> targets) {
    for (final target in targets) {
      factory.servers.putIfAbsent(target.scope, () => _Server(target.scope));
    }
    container.read(_targetsProvider.notifier).set(targets);
  }

  Future<void> until(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('condition not met; log: $log');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    container.dispose();
  }
}

final class _PlatformError implements Exception {
  _PlatformError(this.code);
  final String code;
}

final class _Platform implements PushPlatformPort {
  _Platform(this.log);

  List<String> log;
  List<PushTransport> transports = [PushTransport.apns];
  bool permission = true;
  String token = 'aa' * 32;
  Object? tokenError;
  final subscriptions = <String, PushSubscriptionKeys>{};
  final nonces = <String, List<String>>{};
  List<String> distributors = const [];
  final _upCounts = <String, int>{};
  PushDisplayConfig? config;
  int _next = 0;
  final _events = StreamController<PushPlatformEvent>.broadcast();

  void emit(PushPlatformEvent event) => _events.add(event);

  @override
  Future<List<PushTransport>> availableTransports() async => transports;

  @override
  Future<bool> requestPermission() async => permission;

  @override
  Future<PushDeviceToken?> currentToken(PushTransport transport) async {
    final error = tokenError;
    if (error != null) throw error;
    return PushDeviceToken(
      transport: transport,
      token: token,
      app: 'app.test',
      env: 'dev',
    );
  }

  @override
  Future<PushSubscriptionKeys> createSubscription(
    String scope, {
    Duration age = Duration.zero,
  }) async {
    final sid = 'sid${_next++}'.padRight(22, '_');
    log.add('create $scope');
    return subscriptions[sid] = PushSubscriptionKeys(
      sid: sid,
      scope: scope,
      p256dh: 'P256-$sid',
      auth: 'AUTH-$sid',
      createdAt: DateTime.now().subtract(age),
    );
  }

  @override
  Future<List<PushSubscriptionKeys>> listSubscriptions() async =>
      subscriptions.values.toList();

  @override
  Future<void> setEndpoint(
    String sid,
    String endpoint,
    PushTransport transport,
  ) async {
    final keys = subscriptions[sid];
    if (keys == null) return;
    subscriptions[sid] = PushSubscriptionKeys(
      sid: sid,
      scope: keys.scope,
      p256dh: keys.p256dh,
      auth: keys.auth,
      createdAt: keys.createdAt,
      endpoint: endpoint,
      transport: transport,
    );
  }

  @override
  Future<void> deleteSubscription(String sid) async {
    log.add('delete $sid');
    subscriptions.remove(sid);
  }

  @override
  Future<void> setConfig(PushDisplayConfig config) async =>
      this.config = config;

  @override
  Future<bool> claimNotification(
    String dedupKey, {
    String? localNotificationId,
  }) async => true;

  @override
  Future<void> cancelScope(String scope) async => log.add('cancelScope $scope');

  @override
  Future<PushTap?> takeLaunchTap() async => null;

  @override
  Future<List<String>> takeVerifiedNonces(String sid) async =>
      nonces.remove(sid) ?? const [];

  @override
  Future<List<String>> unifiedPushDistributors() async => distributors;

  @override
  Future<String?> registerUnifiedPush(String sid, String distributor) async {
    log.add('registerUp $sid $distributor');
    final count = (_upCounts[sid] ?? 0) + 1;
    _upCounts[sid] = count;
    return 'https://up.test/$sid/$count';
  }

  @override
  Future<void> unregisterUnifiedPush(String sid) async =>
      log.add('unregisterUp $sid');

  @override
  Stream<PushPlatformEvent> get events => _events.stream;
}

enum _Delivery { event, poll, foreground, never }

final class _Server {
  _Server(this.scope);

  final String scope;
  PushProbe probe = const PushProbe.ready();
  PushProbe? probeAfterInstall;
  PushProbe? probeAfterSubscribeError;

  /// Answers ready after this many more probes.
  int? readyAfterProbes;
  final subscriptions = <String, PushServerSubscription>{};
  _Delivery delivery = _Delivery.event;
  PushTestDispatch? Function(String nonce)? dispatch;
  PushServerDiagnostics? diagnostics;
  PushBackendException? subscribeError;
  PushBackendException? installError;
  bool unsubscribeHangs = false;
  int installs = 0;
  int tests = 0;
  int subscribes = 0;
}

final class _Backend implements PushBackend {
  _Backend(this.server, this.log, this.platform);

  final _Server server;
  final List<String> log;
  final _Platform platform;

  @override
  Future<PushProbe> probe() async {
    log.add('probe ${server.scope}');
    final remaining = server.readyAfterProbes;
    if (remaining != null) {
      if (remaining <= 0) {
        server.readyAfterProbes = null;
        server.probe = const PushProbe.ready();
      } else {
        server.readyAfterProbes = remaining - 1;
      }
    }
    return server.probe;
  }

  @override
  Future<void> install() async {
    server.installs++;
    final error = server.installError;
    if (error != null) throw error;
    final next = server.probeAfterInstall;
    if (next != null) server.probe = next;
  }

  @override
  Future<PushTestDispatch?> subscribe(
    PushServerSubscription subscription, {
    String? testNonce,
  }) async {
    final error = server.subscribeError;
    if (error != null) {
      final next = server.probeAfterSubscribeError;
      if (next != null) server.probe = next;
      throw error;
    }
    server.subscribes++;
    log.add('subscribe ${server.scope} ${subscription.sid}');
    server.subscriptions[subscription.sid] = subscription;
    if (testNonce == null) return null;
    server.tests++;
    _deliver(subscription.sid, testNonce);
    return server.dispatch?.call(testNonce) ?? const PushTestDispatch();
  }

  void _deliver(String sid, String nonce) {
    switch (server.delivery) {
      case _Delivery.event:
        Timer.run(() => platform.emit(PushTestReceivedEvent(sid, nonce)));
      case _Delivery.poll:
        platform.nonces[sid] = [nonce];
      case _Delivery.foreground:
        Timer.run(
          () => platform.emit(
            PushForegroundEvent(
              PushMessage(
                sid: sid,
                scope: server.scope,
                payloadJson: jsonEncode({'v': 1, 'k': 'test', 'n': nonce}),
              ),
            ),
          ),
        );
      case _Delivery.never:
        break;
    }
  }

  @override
  Future<void> unsubscribe(String sid) async {
    if (server.unsubscribeHangs) await Completer<void>().future;
    log.add('unsubscribe ${server.scope} $sid');
    server.subscriptions.remove(sid);
  }

  @override
  Future<PushTestDispatch> requestTest(
    PushServerSubscription subscription,
    String nonce,
  ) async =>
      await subscribe(subscription, testNonce: nonce) ??
      const PushTestDispatch();

  @override
  Future<PushServerDiagnostics?> diagnose(String sid) async =>
      server.diagnostics;

  @override
  void close() {}
}

final class _Factory implements PushBackendFactory {
  _Factory(this.log, this.platform, {required this.realHermes});

  final List<String> log;
  final _Platform platform;
  final bool realHermes;
  final servers = <String, _Server>{};
  final openErrors = <String, PushBackendException>{};
  final gateway = _Gateway();
  final jobs = _Jobs();

  @override
  Future<PushBackend> open(PushTarget target) async {
    final error = openErrors[target.scope];
    if (error != null) throw error;
    if (realHermes && target is HermesPushTarget) {
      gateway.platform = platform;
      return HermesApiPushBackend(
        root: 'https://hermes.test',
        dio: Dio()..httpClientAdapter = gateway,
      );
    }
    return _Backend(servers[target.scope]!, log, platform);
  }

  @override
  Future<HermesBackendService> openHermesService(String connectionId) async =>
      jobs;
}

/// The Hermes gateway's push route, answering ops like the plugin.
final class _Gateway implements HttpClientAdapter {
  _Platform? platform;
  final bodies = <Map<String, dynamic>>[];

  List<String> get ops => [for (final body in bodies) body['op'] as String];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = jsonDecode(options.data as String) as Map<String, dynamic>;
    bodies.add(body);
    final result = switch (body['op']) {
      'hello' => {'ok': true, 'plugin': 'conduit', 'version': '1.0.0'},
      'test' => {'ok': true, 'push_status': 201},
      _ => {'ok': true},
    };
    if (body['op'] == 'test') {
      final sid = body['sid'] as String;
      final nonce = body['nonce'] as String;
      Timer.run(() => platform?.emit(PushTestReceivedEvent(sid, nonce)));
    }
    return ResponseBody.fromString(
      jsonEncode(result),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

final class _Jobs implements HermesBackendService {
  final updates = <String, String?>{};

  @override
  Future<void> updateJob(
    String id, {
    String? name,
    String? prompt,
    String? schedule,
    bool? enabled,
    String? deliver,
  }) async => updates[id] = deliver;

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The relay: hands out endpoints sealed with its active key id.
final class _Relay implements HttpClientAdapter {
  int activeKid = 1;
  int registerStatus = 200;
  final registrations = <Map<String, dynamic>>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/v1/info') {
      return _json({
        'proto': 1,
        'active_kid': activeKid,
        'max_body': 2134,
        'providers': ['apns', 'fcm'],
      });
    }
    if (registerStatus != 200) {
      return _json({'error': 'app_not_allowed'}, registerStatus);
    }
    final body = jsonDecode(options.data as String) as Map<String, dynamic>;
    registrations.add(body);
    final sealed = base64Url
        .encode([1, activeKid, registrations.length, ...List.filled(40, 7)])
        .replaceAll('=', '');
    return _json({
      'endpoint': 'https://relay.test/v1/push/$sealed',
      'kid': activeKid,
    });
  }

  ResponseBody _json(Object body, [int status = 200]) =>
      ResponseBody.fromString(
        jsonEncode(body),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}
