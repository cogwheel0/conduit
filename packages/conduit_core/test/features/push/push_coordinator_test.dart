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
import 'package:conduit_core/persistence/account_scoped_preferences.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
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

    test('the active account is retried once its session is up', () async {
      h = await _Harness.start(targets: [_owui]);
      h.factory.openErrors[_owui.scope] = const PushBackendException(
        PushFailure(PushFailureReason.serverRejected),
        signInNeeded: true,
      );
      await h.coordinator.setEnabled(true);
      check(h.status(_owui.scope)).equals(PushStatus.signInNeeded);

      h.factory.openErrors.clear();
      h.container.read(_sessionProvider.notifier).set('acct-1');
      await h.until(() => h.status(_owui.scope) == PushStatus.on);
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

    test('the settings know whether push can work before it is on', () async {
      h = await _Harness.start(targets: [_owui], relay: false);
      await h.until(() => h.state.transportsChecked);
      check(h.state.available).isFalse();
      h.dispose();

      h = await _Harness.start(targets: [_owui]);
      await h.until(() => h.state.transportsChecked);
      check(h.state.available).isTrue();
      h.dispose();

      // UnifiedPush needs no relay.
      h = await _Harness.start(
        targets: [_owui],
        relay: false,
        unifiedPush: true,
      );
      await h.until(() => h.state.transportsChecked);
      check(h.state.available).isTrue();
    });

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

    test('a check after launch never prompts', () async {
      h = await _Harness.start(targets: [_owui]);
      await h.coordinator.setEnabled(true);
      check(h.platform.prompts).equals(1);
      final platform = h.platform;
      h.dispose();

      // Notifications were switched off in system settings meanwhile.
      platform.permission = false;
      h = await _Harness.start(
        targets: [_owui],
        keepPreferences: true,
        platform: platform,
      );
      await h.coordinator.retry(_owui.scope);
      check(platform.prompts).equals(2);
      platform.prompts = 0;
      h.platform.emit(
        PushTokenEvent(
          PushDeviceToken(
            transport: PushTransport.apns,
            token: 'dd' * 32,
            app: 'app.test',
            env: 'dev',
          ),
        ),
      );
      await h.until(
        () => h.status(_owui.scope) == PushStatus.permissionDenied,
      );
      await pumpEventQueue();
      check(platform.prompts).equals(0);
      check(h.state.permissionDenied).isTrue();
    });

    test('sending a test asks for a missing permission', () async {
      h = await _Harness.start(targets: [_owui]);
      await h.coordinator.setEnabled(true);
      h.platform
        ..prompts = 0
        ..permissionStatus = () => h.platform.prompts > 0;
      check(await h.coordinator.sendTest(_owui.scope)).isTrue();
      check(h.platform.prompts).equals(1);
      check(await h.coordinator.sendTest(_owui.scope)).isTrue();
      check(h.platform.prompts).equals(1);
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
      await h.coordinator.setEnabled(true);
      check(h.relay.registrations).length.equals(1);
      check(h.server(_owui).tests).equals(1);
      check(h.server(_owui).subscribes).equals(1);
    });

    test('a retry registers a new endpoint and tests it', () async {
      h = await _Harness.start(targets: [_owui]);
      await h.coordinator.setEnabled(true);
      final before = h.record(_owui.scope).endpoint;
      // The relay forgot the endpoint, while the token and key still match.
      await h.coordinator.retry(_owui.scope);
      check(h.relay.registrations).length.equals(2);
      check(h.record(_owui.scope).endpoint).not((it) => it.equals(before));
      check(h.server(_owui).subscriptions.values.single.endpoint)
          .equals(h.record(_owui.scope).endpoint!);
      check(h.server(_owui).tests).equals(2);
      check(h.status(_owui.scope)).equals(PushStatus.on);
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
      // Removed from the server it was on, not asked of the new one.
      check(h.server(_hermes).unsubscribes).deepEquals([oldSid]);
      check(h.server(_hermes).subscriptions).isEmpty();
      check(h.server(moved).unsubscribes).isEmpty();
      check(h.server(moved).subscriptions.keys)
          .deepEquals([h.record(_hermes.scope).sid!]);
      check(h.platform.subscriptions.keys).not((it) => it.contains(oldSid));
      check(h.settingsStore.tombstones()).isEmpty();
    });

    test('a profile change unsubscribes from the old profile', () async {
      const desk = HermesPushTarget(
        connectionId: 'conn-d',
        label: 'Desk',
        baseUrl: 'https://desk.test',
        mode: HermesBackendMode.desktopGateway,
        desktopProfile: 'work',
        credentialsRevision: 'rev-1',
      );
      h = await _Harness.start(targets: [desk]);
      await h.coordinator.setEnabled(true);
      final oldSid = h.record(desk.scope).sid!;

      const moved = HermesPushTarget(
        connectionId: 'conn-d',
        label: 'Desk',
        baseUrl: 'https://desk.test',
        mode: HermesBackendMode.desktopGateway,
        desktopProfile: 'home',
        credentialsRevision: 'rev-2',
      );
      h.setTargets([moved]);
      await h.until(
        () =>
            h.record(desk.scope).sid != oldSid &&
            h.status(desk.scope) == PushStatus.on,
      );
      check(h.server(desk).unsubscribes).deepEquals([oldSid]);
      check(h.server(moved).unsubscribes).isEmpty();
    });

    test(
      'without the old settings, the old sid is tombstoned for its server',
      () async {
        h = await _Harness.start(targets: [_hermes]);
        await h.coordinator.setEnabled(true);
        final oldSid = h.record(_hermes.scope).sid!;
        // The settings from before the edit are not known in this process.
        h.factory.retained.clear();

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
        check(h.server(moved).unsubscribes).isEmpty();
        final tombstone = h.settingsStore.tombstones().single;
        check(tombstone.sid).equals(oldSid);
        check(tombstone.server).isNotNull();

        // A later full pass never sends it to the new server.
        await h.coordinator.resetKeys();
        check(h.server(moved).unsubscribes)
            .not((it) => it.contains(oldSid));
      },
    );

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
      // Off FCM: Firebase stops starting at launch.
      check(h.log).contains('release fcm');
      check(h.log).contains(
        'registerUp ${h.record(_owui.scope).sid} org.unifiedpush.distributor.ntfy',
      );
      check(h.state.androidTransport).equals(PushAndroidTransport.unifiedPush);
      check(await h.coordinator.distributors())
          .deepEquals(['org.unifiedpush.distributor.ntfy']);
    });

    test('a token that changed while the app was closed is caught', () async {
      h = await _Harness.start(targets: [_owui, _owui2]);
      await h.coordinator.setEnabled(true);
      final platform = h.platform;
      h.dispose();

      platform.token = 'cc' * 32;
      h = await _Harness.start(
        targets: [_owui, _owui2],
        keepPreferences: true,
        platform: platform,
      );
      await h.until(
        () => h.relay.registrations.length == 2 && h.allOn(),
      );
      check(
        h.relay.registrations.map((r) => r['token']).toSet(),
      ).deepEquals({'cc' * 32});
    });

    test('a restart within a day checks only what is not on', () async {
      h = await _Harness.start(targets: [_owui, _owui2]);
      h.server(_owui2).probe = const PushProbe(
        PushProbeOutcome.needsAdminSetup,
      );
      await h.coordinator.setEnabled(true);
      h.dispose();

      final platform = h.platform;
      h = await _Harness.start(
        targets: [_owui, _owui2],
        keepPreferences: true,
        platform: platform,
      );
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

      // APNs is let go only after every subscription is gone.
      check(h.log.last).equals('release apns');
      check(
        h.log.lastIndexOf('release apns'),
      ).isGreaterThan(h.log.lastIndexOf('cancelScope ${_hermes.scope}'));

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

    test('deleting a Hermes connection removes its subscription first', () async {
      h = await _Harness.start(targets: [_owui, _hermes]);
      await h.coordinator.setEnabled(true);
      final sid = h.record(_hermes.scope).sid!;
      h.log.clear();

      await h.container
          .read(pushSignOutHookProvider)
          .beforeHermesConnectionRemoved('conn-1');

      check(h.log).deepEquals([
        'unsubscribe ${_hermes.scope} $sid',
        'delete $sid',
        'cancelScope ${_hermes.scope}',
      ]);
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

    test('push off at start lets go of APNs too', () async {
      h = await _Harness.start(targets: [_owui]);
      await h.until(() => h.log.contains('release apns'));
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

  group('notification settings', () {
    test("an account's own notifications switch off is a disabled scope", () async {
      h = await _Harness.start(targets: [_owui, _owui2, _hermes]);
      final key1 = accountScopedPreferenceKey(
        PreferenceKeys.notificationsEnabled,
        'acct-1',
      );
      final key2 = accountScopedPreferenceKey(
        PreferenceKeys.notificationsEnabled,
        'acct-2',
      );
      await PreferencesStore.put(key2, false);
      await h.coordinator.setEnabled(true);
      await pumpEventQueue();

      final config = h.platform.config!;
      check(config.enabled).isTrue();
      check(config.disabledScopes).deepEquals([_owui2.scope]);
      check(h.target(_owui2.scope).notificationsOff).isTrue();
      check(h.target(_owui.scope).notificationsOff).isFalse();
      check(h.target(_hermes.scope).notificationsOff).isFalse();
      // Turning push on turned on the switch nobody had set, and kept the
      // one that was turned off.
      check(PreferencesStore.getBool(key1)).equals(true);
      check(PreferencesStore.getBool(key2)).equals(false);
      // Its pushes are still set up and verified.
      check(h.status(_owui2.scope)).equals(PushStatus.on);
    });

    test('turning push on writes each switch it turns on to its server', () async {
      final active = accountScopedPreferenceKey(
        PreferenceKeys.notificationsEnabled,
        'acct-1',
      );
      await PreferencesStore.put(PreferenceKeys.activeServerId, 'acct-1');
      await PreferencesStore.put(active, false);
      // acct-2 never stored one; acct-3 turned its own off.
      const owui3 = OpenWebUiPushTarget(accountId: 'acct-3', label: 'c');
      await PreferencesStore.put(
        accountScopedPreferenceKey(
          PreferenceKeys.notificationsEnabled,
          'acct-3',
        ),
        false,
      );
      h = await _Harness.start(
        targets: [_owui, _owui2, owui3],
        keepPreferences: true,
      );
      await h.coordinator.setEnabled(true);
      await h.until(() => h.factory.notificationWrites.length == 2);
      check(h.factory.notificationWrites.toSet())
          .deepEquals({'acct-1 true', 'acct-2 true'});
      check(PreferencesStore.getBool(active)).equals(true);
      // The device-level switch, which Hermes follows, is on too.
      check(PreferencesStore.getBool(PreferenceKeys.notificationsEnabled))
          .equals(true);
    });

    test('a server that refuses the switch does not stop push', () async {
      h = await _Harness.start(targets: [_owui]);
      h.factory.notificationWriteError = StateError('offline');
      await h.coordinator.setEnabled(true);
      check(h.status(_owui.scope)).equals(PushStatus.on);
    });

    test('a Hermes connection follows the device-level switch', () async {
      h = await _Harness.start(targets: [_owui, _hermes]);
      await PreferencesStore.put(PreferenceKeys.activeServerId, 'acct-1');
      await h.coordinator.setEnabled(true);
      await pumpEventQueue();
      check(h.target(_hermes.scope).notificationsOff).isFalse();

      // Switched off, as the Notifications page does with no account.
      await PreferencesStore.put(PreferenceKeys.notificationsEnabled, false);
      h.settings.set(h.settings.state.copyWith(notificationSound: false));
      await h.until(() => h.target(_hermes.scope).notificationsOff);
      check(h.platform.config!.disabledScopes).deepEquals([_hermes.scope]);
      check(
        notificationsEnabledForScope(_hermes.scope, activeValue: true),
      ).isFalse();
      check(
        notificationsEnabledForScope('direct', activeValue: true),
      ).isFalse();
      // The active account keeps its own.
      check(
        notificationsEnabledForScope(_owui.scope, activeValue: true),
      ).isTrue();
    });

    test('a device-level switch never set follows the active one', () {
      PreferencesStore.debugOverride(InMemoryKeyValueStore());
      check(
        notificationsEnabledForScope('hermes:x', activeValue: true),
      ).isTrue();
      check(
        notificationsEnabledForScope('hermes:x', activeValue: false),
      ).isFalse();
    });

    test('the scheduled tasks toggle stops cron pushes', () async {
      h = await _Harness.start(targets: [_hermes]);
      await h.coordinator.setEnabled(true);
      h.settings.set(
        h.settings.state.copyWith(notificationScheduledEnabled: false),
      );
      await h.until(
        () =>
            h.server(_hermes).subscriptions.values.single.events.length == 2,
      );
      check(
        h.server(_hermes).subscriptions.values.single.events,
      ).deepEquals(['reply', 'reply_failed']);
      await pumpEventQueue();
      check(h.platform.config!.enabledKinds).not((it) => it.contains('cron'));
    });
  });

  group('races', () {
    Future<String> waitForSubscribe(_Server server) async {
      await h.until(
        () => h.log.any((line) => line.startsWith('subscribe-waiting')),
      );
      return h.log
          .lastWhere((line) => line.startsWith('subscribe-waiting'))
          .split(' ')
          .last;
    }

    test('a removal during a setup removes what the setup still writes', () async {
      h = await _Harness.start(targets: [_owui]);
      final gate = Completer<void>();
      h.server(_owui).subscribeGate = gate;
      final setup = h.coordinator.setEnabled(true);
      final sid = await waitForSubscribe(h.server(_owui));

      // The setup is still talking to the server when push goes off.
      await h.coordinator.setEnabled(false);
      check(h.settingsStore.tombstones().map((t) => t.sid)).contains(sid);
      check(h.record(_owui.scope).sid).isNull();

      // Its subscribe lands after the removal's own unsubscribe...
      gate.complete();
      await setup;
      // ...and is removed once the setup has stopped, with its tombstone.
      await h.until(
        () =>
            h.server(_owui).subscriptions.isEmpty &&
            h.settingsStore.tombstones().isEmpty,
      );
      check(h.server(_owui).unsubscribes.where((s) => s == sid)).length
          .equals(2);
      // The cancelled setup wrote nothing back.
      check(h.record(_owui.scope))
        ..has((r) => r.sid, 'sid').isNull()
        ..has((r) => r.subscribedAt, 'subscribedAt').isNull()
        ..has((r) => r.endpoint, 'endpoint').isNull();
      check(h.status(_owui.scope)).equals(PushStatus.off);
    });

    test('turning push off and on during a setup sets it up again', () async {
      h = await _Harness.start(targets: [_owui]);
      final gate = Completer<void>();
      h.server(_owui).subscribeGate = gate;
      final first = h.coordinator.setEnabled(true);
      final firstSid = await waitForSubscribe(h.server(_owui));
      await h.coordinator.setEnabled(false);
      final again = h.coordinator.setEnabled(true);
      h.server(_owui).subscribeGate = null;
      gate.complete();
      await first;
      await again;

      check(h.status(_owui.scope)).equals(PushStatus.on);
      final sid = h.record(_owui.scope).sid!;
      check(sid).not((it) => it.equals(firstSid));
      await h.until(
        () => h.server(_owui).subscriptions.keys.toList().join() == sid,
      );
    });

    test('turning push on while it is being removed sets it up again', () async {
      h = await _Harness.start(targets: [_owui]);
      await h.coordinator.setEnabled(true);
      final oldSid = h.record(_owui.scope).sid!;
      final gate = Completer<void>();
      h.server(_owui).unsubscribeGate = gate;
      final off = h.coordinator.setEnabled(false);
      await h.until(() => h.log.contains('unsubscribe-waiting $oldSid'));
      // Back on before the removal has deleted the keys it would reuse.
      final on = h.coordinator.setEnabled(true);
      await pumpEventQueue();
      h.server(_owui).unsubscribeGate = null;
      gate.complete();
      await off;
      await on;

      check(h.status(_owui.scope)).equals(PushStatus.on);
      final sid = h.record(_owui.scope).sid;
      check(sid).isNotNull().not((it) => it.equals(oldSid));
      check(h.platform.subscriptions.keys).deepEquals([sid!]);
      check(h.server(_owui).subscriptions.keys).deepEquals([sid]);
    });

    test('turning push on while it is being removed keeps APNs', () async {
      h = await _Harness.start(targets: [_owui]);
      await h.coordinator.setEnabled(true);
      final sid = h.record(_owui.scope).sid!;
      final gate = Completer<void>();
      h.server(_owui).unsubscribeGate = gate;
      final off = h.coordinator.setEnabled(false);
      await h.until(() => h.log.contains('unsubscribe-waiting $sid'));
      final released = h.log.where((l) => l.startsWith('release ')).length;
      final on = h.coordinator.setEnabled(true);
      await pumpEventQueue();
      h.server(_owui).unsubscribeGate = null;
      gate.complete();
      await off;
      await on;

      check(h.log.where((l) => l.startsWith('release ')).length)
          .equals(released);
      check(h.status(_owui.scope)).equals(PushStatus.on);
    });

    test('turning push on waits for APNs being let go of', () async {
      h = await _Harness.start(targets: [_owui]);
      await h.coordinator.setEnabled(true);
      final gate = Completer<void>();
      h.platform.releaseGate = gate;
      final off = h.coordinator.setEnabled(false);
      await h.until(() => h.log.contains('release-waiting apns'));
      final on = h.coordinator.setEnabled(true);
      await pumpEventQueue();
      // Nothing is set up while APNs could still be let go of.
      check(h.log.last).equals('release-waiting apns');

      h.platform.releaseGate = null;
      gate.complete();
      await off;
      await on;
      check(h.log.lastIndexOf('release apns'))
          .isLessThan(h.log.lastIndexOf('create ${_owui.scope}'));
      check(h.status(_owui.scope)).equals(PushStatus.on);
    });

    test('resetting keys during a pass sets everything up again', () async {
      h = await _Harness.start(targets: [_owui]);
      final gate = Completer<void>();
      h.server(_owui).subscribeGate = gate;
      final first = h.coordinator.setEnabled(true);
      final firstSid = await waitForSubscribe(h.server(_owui));
      final reset = h.coordinator.resetKeys();
      await h.until(() => h.record(_owui.scope).sid == null);
      h.server(_owui).subscribeGate = null;
      gate.complete();
      await first;
      await reset;

      check(h.status(_owui.scope)).equals(PushStatus.on);
      check(h.record(_owui.scope).sid).isNotNull().not(
        (it) => it.equals(firstSid),
      );
    });

    test('a sign-out cancels a setup instead of waiting for it', () async {
      h = await _Harness.start(
        targets: [_owui],
        timings: const PushTimings(
          testTimeout: Duration(milliseconds: 300),
          testPollInterval: Duration(milliseconds: 10),
          unsubscribeTimeout: Duration(milliseconds: 200),
          signOutTimeout: Duration(milliseconds: 400),
          // Longer than a sign-out may take.
          releaseWait: Duration(seconds: 5),
        ),
      );
      final gate = Completer<void>();
      h.server(_owui).subscribeGate = gate;
      final setup = h.coordinator.setEnabled(true);
      final sid = await waitForSubscribe(h.server(_owui));

      final started = DateTime.now();
      await h.container
          .read(pushSignOutHookProvider)
          .beforeOpenWebUiSignOut('acct-1');
      check(DateTime.now().difference(started))
          .isLessThan(const Duration(seconds: 1));
      // The unsubscribe got the sign-out's time.
      check(h.server(_owui).unsubscribes).contains(sid);
      check(h.platform.subscriptions.keys).not((it) => it.contains(sid));
      final tombstone = h.settingsStore.tombstones().single;
      check(tombstone.sid).equals(sid);
      check(tombstone.scope).equals(_owui.scope);

      // The session is revoked now: the second unsubscribe fails, and the
      // tombstone stays with the account's scope after it is gone.
      h.factory.openErrors[_owui.scope] = const PushBackendException(
        PushFailure(PushFailureReason.serverRejected),
        signInNeeded: true,
      );
      gate.complete();
      await setup;
      h.setTargets(const []);
      await h.until(() => !h.state.targets.containsKey(_owui.scope));
      await pumpEventQueue();
      check(h.settingsStore.tombstones().map((t) => (t.sid, t.scope)))
          .deepEquals([(sid, _owui.scope)]);
    });

    test('an origin chosen during a setup is kept and sent', () async {
      h = await _Harness.start(targets: [_owui]);
      final gate = Completer<void>();
      h.server(_owui).subscribeGate = gate;
      final setup = h.coordinator.setEnabled(true);
      await waitForSubscribe(h.server(_owui));

      final origin = h.coordinator.setOrigin(_owui.scope, PushOrigin.any);
      await h.until(() => h.record(_owui.scope).origin == PushOrigin.any);
      h.server(_owui).subscribeGate = null;
      gate.complete();
      await setup;
      await origin;

      check(h.record(_owui.scope).origin).equals(PushOrigin.any);
      check(h.target(_owui.scope).origin).equals(PushOrigin.any);
      check(h.server(_owui).subscriptions.values.single.origin)
          .equals(PushOrigin.any);
    });

    test('a kind turned off during a setup reaches the server', () async {
      h = await _Harness.start(targets: [_owui]);
      final gate = Completer<void>();
      h.server(_owui).subscribeGate = gate;
      final setup = h.coordinator.setEnabled(true);
      // The setup has picked its events and is waiting on the server.
      await waitForSubscribe(h.server(_owui));

      h.settings.set(
        h.settings.state.copyWith(notificationChannelEnabled: false),
      );
      await pumpEventQueue();
      h.server(_owui).subscribeGate = null;
      gate.complete();
      await setup;

      // Saved once the server has the new list.
      await h.until(
        () =>
            h.record(_owui.scope).events?.contains('channel') == false &&
            h.status(_owui.scope) == PushStatus.on,
      );
      check(h.server(_owui).subscriptions.values.single.events)
          .deepEquals(['reply', 'reply_failed']);
    });

    test('an endpoint reported gone during a setup is not saved back', () async {
      h = await _Harness.start(targets: [_owui], unifiedPush: true);
      final gate = Completer<void>();
      h.server(_owui).subscribeGate = gate;
      final setup = h.coordinator.setEnabled(true);
      final sid = await waitForSubscribe(h.server(_owui));
      check(h.record(_owui.scope).endpoint).equals('https://up.test/$sid/1');

      h.platform.emit(PushUnregisteredEvent(sid));
      await h.until(() => h.record(_owui.scope).endpoint == null);
      h.server(_owui).subscribeGate = null;
      gate.complete();
      await setup;
      await h.until(
        () =>
            h.record(_owui.scope).endpoint == 'https://up.test/$sid/2' &&
            h.status(_owui.scope) == PushStatus.on,
      );
      check(h.server(_owui).subscriptions[sid]?.endpoint)
          .equals('https://up.test/$sid/2');
    });

    test('a tombstone added while others are retried is kept', () async {
      h = await _Harness.start(targets: [_owui, _owui2]);
      await h.coordinator.setEnabled(true);
      await const PushSettingsStore().saveTombstones([
        PushTombstone(sid: 'old-sid', scope: _owui.scope, at: DateTime.now()),
      ]);
      final gate = Completer<void>();
      h.server(_owui).unsubscribeGate = gate;
      // A full pass retries the tombstone and waits on the server.
      final pass = h.coordinator.setEnabled(true);
      await h.until(() => h.log.contains('probe ${_owui2.scope}'));
      await pumpEventQueue();

      await h.until(() => h.log.contains('unsubscribe-waiting old-sid'));
      // Meanwhile another account's subscription cannot be removed.
      h.factory.openErrors[_owui2.scope] = const PushBackendException(
        PushFailure(PushFailureReason.serverUnreachable),
      );
      final sid2 = h.record(_owui2.scope).sid!;
      await h.coordinator.setTargetOptedOut(_owui2.scope, true);
      check(h.settingsStore.tombstones().map((t) => t.sid)).contains(sid2);

      gate.complete();
      await pass;
      check(h.settingsStore.tombstones().map((t) => t.sid))
          .deepEquals([sid2]);
    });
  });

  group('choices', () {
    test('an opt-out survives Hermes being turned off and on', () async {
      h = await _Harness.start(targets: [_owui, _hermes]);
      await h.coordinator.setEnabled(true);
      await h.coordinator.setTargetOptedOut(_hermes.scope, true);

      h.setTargets([_owui]);
      await h.until(() => !h.state.targets.containsKey(_hermes.scope));
      h.setTargets([_owui, _hermes]);
      await h.until(() => h.state.targets.containsKey(_hermes.scope));
      await pumpEventQueue();

      check(h.target(_hermes.scope).optedOut).isTrue();
      check(h.status(_hermes.scope)).equals(PushStatus.off);
      check(h.server(_hermes).subscriptions).isEmpty();
      check(h.record(_hermes.scope).optedOut).isTrue();
    });

    test('an opt-out survives a restart with the connection list empty', () async {
      h = await _Harness.start(targets: [_hermes]);
      await h.coordinator.setEnabled(true);
      await h.coordinator.setTargetOptedOut(_hermes.scope, true);
      final platform = h.platform;
      h.dispose();

      // An interrupted sign-out left no connections.
      h = await _Harness.start(
        targets: const [],
        keepPreferences: true,
        platform: platform,
      );
      await pumpEventQueue();
      h.setTargets([_hermes]);
      await h.until(() => h.state.targets.containsKey(_hermes.scope));
      check(h.target(_hermes.scope).optedOut).isTrue();
    });

    test('deleting a connection takes its choices with it', () async {
      h = await _Harness.start(targets: [_hermes]);
      await h.coordinator.setEnabled(true);
      await h.coordinator.setTargetOptedOut(_hermes.scope, true);
      await h.container
          .read(pushSignOutHookProvider)
          .beforeHermesConnectionRemoved('conn-1');
      h.setTargets(const []);
      await h.until(() => !h.state.targets.containsKey(_hermes.scope));
      await pumpEventQueue();
      check(h.settingsStore.records().containsKey(_hermes.scope)).isFalse();
    });
  });

  group('a restored backup', () {
    test("forgets the other device's subscriptions and gets its own id", () async {
      h = await _Harness.start(targets: [_owui]);
      await h.coordinator.setEnabled(true);
      await h.coordinator.setOrigin(_owui.scope, PushOrigin.any);
      final otherSid = h.record(_owui.scope).sid!;
      final otherDid = h.server(_owui).subscriptions.values.single.did;
      h.dispose();

      // The preferences came over; the keys, which never leave a device,
      // did not.
      h = await _Harness.start(
        targets: [_owui],
        keepPreferences: true,
        // Its own sids, unlike the other device's.
        platform: _Platform([]).._next = 50,
      );
      await h.until(() => h.status(_owui.scope) == PushStatus.on);
      final mine = h.server(_owui).subscriptions.values.single;
      check(mine.sid).not((it) => it.equals(otherSid));
      check(mine.did).not((it) => it.equals(otherDid));
      // The choice came over too.
      check(mine.origin).equals(PushOrigin.any);
      // Nothing of the other device's was removed or tombstoned.
      check(h.server(_owui).unsubscribes).isEmpty();
      check(h.settingsStore.tombstones()).isEmpty();
    });
  });

  group('push state for other screens', () {
    test('follows a coordinator that starts after it was read', () async {
      h = await _Harness.start(targets: [_owui], startCoordinator: false);
      final seen = <PushState?>[];
      h.container.listen<PushState?>(
        pushStateIfUsedProvider,
        (_, next) => seen.add(next),
        fireImmediately: true,
      );
      check(seen).deepEquals([null]);

      h.container.read(pushCoordinatorProvider);
      await h.until(() => seen.lastOrNull != null);
      await h.coordinator.setEnabled(true);
      await h.until(() => seen.last?.enabled == true);
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
      h.factory.jobs.stored['job-1'] = 'telegram';
      check(
        await h.coordinator.setHermesJobNotify(
          connectionId: 'conn-1',
          jobId: 'job-1',
          notify: true,
        ),
      ).equals('telegram,conduit');
      check(h.factory.jobs.updates).deepEquals({'job-1': 'telegram,conduit'});
      check(
        await h.coordinator.setHermesJobNotify(
          connectionId: 'conn-1',
          jobId: 'job-1',
          notify: false,
        ),
      ).equals('telegram');
      check(PushCoordinator.hermesJobNotifies('telegram,conduit')).isTrue();
    });

    test("notify me reads the job fresh and keeps targets added since", () async {
      h = await _Harness.start(targets: [_hermes]);
      // Another client added Slack after this app listed the job.
      h.factory.jobs.stored['job-1'] = 'telegram,slack';
      await h.coordinator.setHermesJobNotify(
        connectionId: 'conn-1',
        jobId: 'job-1',
        notify: true,
      );
      check(h.factory.jobs.updates)
          .deepEquals({'job-1': 'telegram,slack,conduit'});
    });

    test('notify me never rewrites delivery targets it cannot read', () async {
      h = await _Harness.start(targets: [_hermes]);
      for (final deliver in <Object>['x' * 300, ['telegram', 'slack'], 7]) {
        h.factory.jobs.stored['job-1'] = deliver;
        await check(
          h.coordinator.setHermesJobNotify(
            connectionId: 'conn-1',
            jobId: 'job-1',
            notify: true,
          ),
        ).throws<HermesJobDeliveryUnknown>();
      }
      check(h.factory.jobs.updates).isEmpty();
    });

    test('notify me already in place writes nothing', () async {
      h = await _Harness.start(targets: [_hermes]);
      h.factory.jobs.stored['job-1'] = 'local,conduit';
      check(
        await h.coordinator.setHermesJobNotify(
          connectionId: 'conn-1',
          jobId: 'job-1',
          notify: true,
        ),
      ).equals('local,conduit');
      h.factory.jobs.stored['job-2'] = null;
      check(
        await h.coordinator.setHermesJobNotify(
          connectionId: 'conn-1',
          jobId: 'job-2',
          notify: true,
        ),
      ).equals('local,conduit');
      check(h.factory.jobs.updates).deepEquals({'job-2': 'local,conduit'});
    });
  });
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

final _sessionProvider = NotifierProvider<_Session, String?>(_Session.new);

final class _Session extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? accountId) => state = accountId;
}

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
    bool startCoordinator = true,
    _Platform? platform,
    PushTimings timings = timings,
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
      factory.addServer(target);
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
        pushActiveOpenWebUiSessionProvider.overrideWith(
          (ref) => ref.watch(_sessionProvider),
        ),
      ],
    );
    final harness = _Harness._(container, log, fake, factory, relayAdapter);
    factory.current = (scope) =>
        container.read(_targetsProvider).where((t) => t.scope == scope).firstOrNull;
    last = harness;
    if (!startCoordinator) return harness;
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
  _Server server(PushTarget target) => factory.servers[_serverKey(target)]!;

  bool allOn() => state.targets.values.every((t) => t.status == PushStatus.on);

  void setTargets(List<PushTarget> targets) {
    for (final target in targets) {
      factory.addServer(target);
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

  int prompts = 0;

  /// What a non-prompting check answers; null means the platform can't tell.
  bool? Function()? permissionStatus;

  @override
  Future<bool> requestPermission() async {
    prompts++;
    return permission;
  }

  @override
  Future<bool?> hasPermission() async =>
      permissionStatus == null ? permission : permissionStatus!();

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

  /// Holds [releaseTransport] until completed.
  Completer<void>? releaseGate;

  @override
  Future<void> releaseTransport(PushTransport transport) async {
    final gate = releaseGate;
    if (gate != null) {
      log.add('release-waiting ${transport.name}');
      await gate.future;
    }
    log.add('release ${transport.name}');
  }

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

  /// While set, a subscribe waits for it before it lands on the server.
  Completer<void>? subscribeGate;

  /// While set, an unsubscribe waits for it.
  Completer<void>? unsubscribeGate;
  final unsubscribes = <String>[];
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
    final gate = server.subscribeGate;
    if (gate != null) {
      log.add('subscribe-waiting ${server.scope} ${subscription.sid}');
      await gate.future;
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
    final gate = server.unsubscribeGate;
    if (gate != null) {
      log.add('unsubscribe-waiting $sid');
      await gate.future;
    }
    log.add('unsubscribe ${server.scope} $sid');
    server.unsubscribes.add(sid);
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

/// Which fake server a target reaches: an Open WebUI account has one, a
/// Hermes connection one per server identity (address, mode, profile, key).
String _serverKey(PushTarget target) => switch (target) {
  OpenWebUiPushTarget() => target.scope,
  HermesPushTarget() => '${target.scope}|${target.serverIdentity}',
};

/// Resolves backends the way the app's factory does: a Hermes target reaches
/// the server its connection's settings name now, and an older target only
/// through settings retained while they were current.
final class _Factory implements PushBackendFactory {
  _Factory(this.log, this.platform, {required this.realHermes});

  final List<String> log;
  final _Platform platform;
  final bool realHermes;
  final servers = <String, _Server>{};
  final openErrors = <String, PushBackendException>{};
  final gateway = _Gateway();
  final jobs = _Jobs();

  /// The target as the app lists it now, standing for the connection's
  /// saved settings.
  PushTarget? Function(String scope) current = (_) => null;
  final retained = <String>{};
  final notificationWrites = <String>[];
  Object? notificationWriteError;

  void addServer(PushTarget target) =>
      servers.putIfAbsent(_serverKey(target), () => _Server(target.scope));

  @override
  Future<PushBackend> open(PushTarget target) async {
    final error = openErrors[target.scope];
    if (error != null) throw error;
    if (target is HermesPushTarget) {
      final now = current(target.scope);
      final key = _serverKey(target);
      if (now != null && _serverKey(now) == key) {
        retained.add(key);
      } else if (!retained.contains(key)) {
        throw const PushBackendException(
          PushFailure(
            PushFailureReason.serverRejected,
            detail: 'connection_changed',
          ),
        );
      }
    }
    if (realHermes && target is HermesPushTarget) {
      gateway.platform = platform;
      return HermesApiPushBackend(
        root: 'https://hermes.test',
        dio: Dio()..httpClientAdapter = gateway,
      );
    }
    return _Backend(servers[_serverKey(target)]!, log, platform);
  }

  @override
  Future<void> retain(PushTarget target) async {
    final now = current(target.scope);
    if (now != null && _serverKey(now) == _serverKey(target)) {
      retained.add(_serverKey(target));
    }
  }

  @override
  Future<HermesBackendService> openHermesService(String connectionId) async =>
      jobs;

  @override
  Future<void> setOpenWebUiNotificationsEnabled(
    String accountId, {
    required bool enabled,
  }) async {
    final error = notificationWriteError;
    if (error != null) throw error;
    notificationWrites.add('$accountId $enabled');
  }
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

  /// Each job's `deliver` as the server has it, by job id.
  final stored = <String, Object?>{};

  @override
  Future<List<Map<String, dynamic>>> listJobs() async => [
    for (final entry in stored.entries)
      {
        'id': entry.key,
        'prompt': 'p',
        'schedule': '0 9 * * *',
        'deliver': ?entry.value,
      },
  ];

  @override
  Future<void> updateJob(
    String id, {
    String? name,
    String? prompt,
    String? schedule,
    bool? enabled,
    String? deliver,
  }) async {
    updates[id] = deliver;
    stored[id] = deliver;
  }

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
