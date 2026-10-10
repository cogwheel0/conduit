import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:synchronized/synchronized.dart';

import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_job.dart';
import 'package:conduit_core/features/notifications/models/notification_scope.dart';
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
import 'package:conduit_core/ports/app_lifecycle.dart';
import 'package:conduit_core/ports/push_platform_port.dart';
import 'package:conduit_core/providers/host_ports.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';

part 'push_coordinator.g.dart';

/// Sets up and keeps up end-to-end-encrypted push for every Open WebUI
/// account and Hermes connection.
///
/// Each target goes through the same pipeline: a key pair on the platform
/// (`createSubscription(scope)`), a transport endpoint (the relay for APNs and
/// FCM, a distributor for UnifiedPush), a probe of the server's push support,
/// the subscription on the server, and a test push that must decrypt on this
/// device before the target counts as [PushStatus.on].
///
/// Runs on: the master toggle, app start and resume (everything at most once
/// a day, anything not on right away), token and relay key changes, accounts
/// and connections coming and going, notification kind toggles, and the
/// platform dropping or replacing a UnifiedPush endpoint.
///
/// Integration points for the notification router (not wired here yet):
/// [platformEvents] carries foreground pushes and taps, and [takeLaunchTap]
/// the push that launched the app. A foreground push was already claimed by
/// the iOS extension, so the router must not gate it with
/// `claimNotification`; only socket-driven local notifications claim.
@Riverpod(keepAlive: true)
class PushCoordinator extends _$PushCoordinator {
  final Map<String, _ScopeRunner> _runners = {};
  final Map<String, _PendingTest> _pendingTests = {};
  Map<String, PushSubscriptionRecord> _records = {};
  List<PushTarget>? _targets;

  /// The previous version of a target whose server changed, so its old
  /// subscription can be removed.
  final Map<String, PushTarget> _replacedTargets = {};
  Future<_Environment>? _environment;
  DateTime? _environmentAt;

  /// APNs or FCM being let go of, which turning push on waits for.
  Future<void>? _transportRelease;

  /// Bumped by every removal: a pass that ran while one happened may have
  /// had setups cancelled, so it does not cover a request waiting on it.
  int _releases = 0;

  /// Scopes whose user choices go with them: a connection the user deleted,
  /// rather than one that only left the list for a while.
  final Set<String> _choicesToDrop = {};

  /// Serializes the tombstone list's read-modify-writes.
  final Lock _tombstoneLock = Lock();
  bool? _permissionGranted;
  PushRelayInfo? _relayInfo;
  DateTime? _relayInfoAt;
  bool? _hasTransports;
  PushDisplayConfig? _lastConfig;
  bool _configScheduled = false;
  _Pass? _pass;
  StreamSubscription<PushPlatformEvent>? _events;
  StreamSubscription<AppLifecyclePhase>? _lifecycle;

  // Host bindings, read once: work still finishing after a dispose must not
  // touch the ref.
  late final PushPlatformPort _platform;
  late final PushSettingsStore _settings;
  late final PushTimings _timings;
  late final DateTime Function() _clock;
  late final PushBackendFactory _factory;
  late final PushRelayClient? _relay;
  DateTime _now() => _clock();

  @override
  PushState build() {
    // Listen, never watch: a rebuild would drop every in-flight setup.
    _platform = ref.read(pushPlatformPortProvider);
    _settings = ref.read(pushSettingsStoreProvider);
    _timings = ref.read(pushTimingsProvider);
    _clock = ref.read(pushClockProvider);
    _factory = ref.read(pushBackendFactoryProvider);
    _relay = ref.read(pushRelayClientProvider);
    final settings = _settings;
    _records = settings.records();
    ref.listen<AsyncValue<List<PushTarget>>>(pushTargetsProvider, (_, next) {
      if (next.isLoading || !next.hasValue) return;
      final targets = next.requireValue;
      scheduleMicrotask(() => _onTargets(targets));
    }, fireImmediately: true);
    ref.listen<AppSettings>(appSettingsProvider, (previous, next) {
      if (previous != null &&
          (previous.notificationChatEnabled != next.notificationChatEnabled ||
              previous.notificationChannelEnabled !=
                  next.notificationChannelEnabled ||
              previous.notificationScheduledEnabled !=
                  next.notificationScheduledEnabled)) {
        _onEventsChanged();
      }
      _scheduleDisplayConfig();
    });
    ref.listen<Map<String, String>>(
      pushLocalizedStringsProvider,
      (_, _) => _scheduleDisplayConfig(),
    );
    ref.listen<String?>(pushActiveOpenWebUiSessionProvider, (previous, next) {
      if (next == null || next == previous || !state.enabled) return;
      final target = _target(PushTarget.openWebUiScope(next));
      if (target != null &&
          state.targets[target.scope]?.status == PushStatus.signInNeeded) {
        unawaited(_reconcile(target));
      }
    });
    _lifecycle = ref.read(appLifecycleProvider).changes.listen((phase) {
      if (phase == AppLifecyclePhase.resumed) unawaited(_onResume());
    });
    _events = _platform.events.listen(
      _onPlatformEvent,
      onError: (Object error) => _log('push-platform-event-error', error),
    );
    // Not from build itself: a provider must not change another while it
    // builds.
    scheduleMicrotask(() {
      if (ref.mounted) {
        ref.read(pushCoordinatorStartedProvider.notifier).markStarted();
      }
    });
    ref.onDispose(() {
      unawaited(_events?.cancel());
      unawaited(_lifecycle?.cancel());
      for (final pending in _pendingTests.values) {
        pending.complete(false);
      }
      _pendingTests.clear();
    });
    return PushState(
      enabled: settings.enabled,
      relayConfigured: _relay != null,
      androidTransport: settings.androidTransport,
      distributor: settings.distributor,
    );
  }

  // ---------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------

  /// Foreground pushes, taps, tokens and test receipts from the platform.
  Stream<PushPlatformEvent> platformEvents() => _platform.events;

  /// The push notification that launched the app, once.
  Future<PushTap?> takeLaunchTap() => _platform.takeLaunchTap();

  /// The master toggle. Turning it on also turns notifications on, asks for
  /// permission and sets up every target; off removes every subscription
  /// from its server and deletes its keys.
  Future<void> setEnabled(bool enabled) async {
    await _settings.setEnabled(enabled);
    if (!ref.mounted) return;
    if (enabled) {
      _update((s) => s.copyWith(enabled: true, permissionDenied: false));
      // An off still letting go of APNs or FCM finishes first, so it cannot
      // undo the token the setup below registers.
      final releasing = _transportRelease;
      if (releasing != null) await releasing;
      await _enableAccountNotifications();
      await _requestPermission();
      _publishTargets();
      _scheduleDisplayConfig();
      // Fresh: a pass still running from before was cut short by turning
      // push off, and must not stand in for this one.
      await _reconcileAll(full: true, fresh: true);
    } else {
      _update((s) => s.copyWith(enabled: false));
      _scheduleDisplayConfig();
      await Future.wait([
        for (final scope in _knownScopes())
          _release(scope, target: _target(scope)),
      ]);
      // Turned back on meanwhile: its setup needs APNs or FCM.
      if (ref.mounted && state.enabled) return;
      _publishTargets();
      await _releaseRelayTransports();
    }
  }

  /// Opts one target out of (or back into) push on this device.
  Future<void> setTargetOptedOut(String scope, bool optedOut) async {
    await _saveRecord(
      scope,
      _record(scope).copyWith(optedOut: optedOut),
      choices: true,
    );
    _setTarget(scope, (t) => t.copyWith(optedOut: optedOut));
    _scheduleDisplayConfig();
    final target = _target(scope);
    if (optedOut) {
      await _release(scope, target: target);
    } else if (target != null && state.enabled) {
      await _reconcile(target);
    }
  }

  /// Which Open WebUI replies notify: chats started from Conduit, or all.
  Future<void> setOrigin(String scope, PushOrigin origin) async {
    final record = _record(scope);
    if (record.origin == origin) return;
    // A setup running now saves its record with this choice too, and the
    // resubscribe below queues behind it with the new origin.
    await _saveRecord(scope, record.copyWith(origin: origin), choices: true);
    _setTarget(scope, (t) => t.copyWith(origin: origin));
    final target = _target(scope);
    if (target is OpenWebUiPushTarget &&
        state.enabled &&
        record.sid != null &&
        !record.optedOut) {
      await _reconcile(target, resubscribe: true);
    }
  }

  /// Installs, enables or updates the Conduit Push function on an Open WebUI
  /// server, then verifies push. Only for an admin, and only after the user
  /// confirmed installing open-source code on their server. Answers whether
  /// push is on afterwards; a failure is in the target's state.
  Future<bool> installOpenWebUiFunction(String scope) async {
    final target = _target(scope);
    if (target is! OpenWebUiPushTarget) return false;
    if (!await _install(target)) return false;
    await _reconcile(target, forceTest: true);
    return _isOn(scope);
  }

  /// Installs and enables the Hermes plugin through the Hermes dashboard (a
  /// `desktopGateway` connection), restarts a running gateway, and waits up
  /// to two minutes for Hermes to load it. Only where the last check offered
  /// it ([PushTargetState.canInstallHermesPlugin]: a pinned plugin commit and
  /// the dashboard's own profile); other connections answer false, and their
  /// state carries the command to run instead.
  Future<bool> installHermesPlugin(String scope) async {
    final target = _target(scope);
    if (target is! HermesPushTarget ||
        target.mode != HermesBackendMode.desktopGateway ||
        state.targets[scope]?.canInstallHermesPlugin != true) {
      return false;
    }
    if (!await _install(target)) return false;
    _setTarget(scope, (t) => t.copyWith(status: PushStatus.restartHermes));
    final runner = _runner(scope);
    final generation = runner.generation;
    final deadline = _now().add(_timings.restartPollTimeout);
    while (_now().isBefore(deadline)) {
      await Future<void>.delayed(_timings.restartPollInterval);
      if (!ref.mounted || runner.generation != generation) return false;
      final PushProbe probe;
      try {
        probe = await _withBackend(target, (backend) => backend.probe());
      } on PushBackendException {
        continue;
      }
      if (probe.isReady) {
        await _reconcile(target, forceTest: true);
        return _isOn(scope);
      }
      if (probe.outcome != PushProbeOutcome.restartHermes &&
          probe.outcome != PushProbeOutcome.needsHermesPlugin) {
        _finish(target, probe.status, failure: probe.failure, probe: probe);
        return false;
      }
    }
    return false;
  }

  /// Sends a test push and waits for it. Answers whether it arrived. Asks
  /// for notification permission first when it is missing.
  Future<bool> sendTest(String scope) async {
    final target = _target(scope);
    if (target == null || !state.enabled) return false;
    await _askPermissionIfMissing();
    await _reconcile(target, forceTest: true);
    return _isOn(scope);
  }

  /// Runs one target's setup again with a newly registered endpoint, asking
  /// for permission again if it is missing. A dead endpoint that still
  /// looks current (same token, same relay key) is recovered this way.
  Future<void> retry(String scope) async {
    final target = _target(scope);
    if (target == null || !state.enabled) return;
    await _askPermissionIfMissing();
    _environment = null;
    await _reconcile(target, resubscribe: true, freshEndpoint: true);
  }

  /// Deletes every key pair and subscription, then sets push up again with
  /// new keys.
  Future<void> resetKeys() async {
    await Future.wait([
      for (final scope in _knownScopes())
        _release(scope, target: _target(scope)),
    ]);
    try {
      for (final keys in await _platform.listSubscriptions()) {
        await _deleteNative(keys.sid, keys.transport);
      }
    } catch (error) {
      _log('push-reset-list-failed', error);
    }
    _environment = null;
    if (state.enabled) await _reconcileAll(full: true, fresh: true);
  }

  /// Chooses the Android delivery service: FCM, UnifiedPush through
  /// [distributor] (or the first installed one), or automatic (null).
  Future<void> setAndroidTransport(
    PushAndroidTransport? transport, {
    String? distributor,
  }) async {
    await _settings.setAndroidTransport(transport, distributor: distributor);
    _update(
      (s) => s.copyWith(
        androidTransport: transport,
        clearAndroidTransport: transport == null,
        distributor: distributor,
        clearDistributor: distributor == null,
      ),
    );
    _environment = null;
    if (!state.enabled) return;
    await _reconcileAll(full: false, everyTarget: true);
    // Moved off FCM: Firebase stops starting at launch.
    if (state.effectiveTransport != PushTransport.fcm &&
        !_records.values.any((r) => r.transport == PushTransport.fcm)) {
      await _releaseTransports(const [PushTransport.fcm]);
    }
  }

  /// Installed UnifiedPush distributors (package names). Android only.
  Future<List<String>> distributors() async {
    try {
      return await _platform.unifiedPushDistributors();
    } catch (error) {
      _log('push-distributors-failed', error);
      return const [];
    }
  }

  /// Tells the Hermes plugin that Conduit started a reply in [sessionId], so
  /// it pushes when the reply finishes. Only for API server connections with
  /// push on; the dashboard's own sessions push without it.
  void watchHermesSession(String connectionId, String sessionId) {
    if (!state.enabled) return;
    final scope = PushTarget.hermesScope(connectionId);
    final target = _target(scope);
    if (target is! HermesPushTarget ||
        target.mode != HermesBackendMode.responsesApi ||
        !_isOn(scope) ||
        _record(scope).optedOut) {
      return;
    }
    unawaited(
      _withBackend(target, (backend) async {
        if (backend is HermesPushBackend) await backend.watch(sessionId);
      }).catchError((Object error) => _log('push-hermes-watch-failed', error)),
    );
  }

  /// Whether a Hermes cron job with [deliver] pushes to Conduit.
  static bool hermesJobNotifies(String? deliver) =>
      hermesDeliverIncludesConduit(deliver);

  /// Turns a Hermes cron job's "Notify me" on or off by adding `conduit` to
  /// its `deliver` targets or removing it. Answers the new `deliver`.
  ///
  /// The job is read fresh from the server first, so targets added since the
  /// app last listed it are kept. One whose `deliver` this app cannot read
  /// is refused with [HermesJobDeliveryUnknown] rather than overwritten.
  Future<String> setHermesJobNotify({
    required String connectionId,
    required String jobId,
    required bool notify,
  }) async {
    final service = await _factory.openHermesService(connectionId);
    try {
      HermesJob? job;
      for (final raw in await service.listJobs()) {
        final parsed = HermesJob.fromJson(raw);
        if (parsed?.id == jobId) {
          job = parsed;
          break;
        }
      }
      if (job == null) throw StateError('The scheduled job no longer exists.');
      if (!job.deliveryKnown) throw const HermesJobDeliveryUnknown();
      final current = job.deliveryTarget;
      final next = hermesDeliverWithConduit(current, notify: notify);
      if (hermesDeliverIncludesConduit(current) != notify) {
        await service.updateJob(jobId, deliver: next);
      }
      return next;
    } finally {
      service.close();
    }
  }

  /// Removes these accounts' subscriptions from their servers while their
  /// sessions still work, then deletes their keys. The sign-out hook calls
  /// this before revoking the sessions.
  ///
  /// A setup still running for one is cancelled rather than waited for, so
  /// the sign-out's time goes to unsubscribing; what it may still write on
  /// the server is removed again once it stops, and tombstoned under the
  /// account's scope until then.
  Future<void> releaseOpenWebUiAccounts(Iterable<String> accountIds) =>
      Future.wait([
        for (final accountId in accountIds)
          _release(
            PushTarget.openWebUiScope(accountId),
            target:
                _target(PushTarget.openWebUiScope(accountId)) ??
                OpenWebUiPushTarget(accountId: accountId, label: accountId),
            status: PushStatus.signInNeeded,
            waitForSetup: false,
          ),
      ]);

  /// Removes a Hermes connection's subscription from its server while its
  /// address and secrets still work, then deletes its keys. Called before
  /// the connection is deleted, which takes the user's choices for it too.
  Future<void> releaseHermesConnection(String connectionId) {
    final scope = PushTarget.hermesScope(connectionId);
    _choicesToDrop.add(scope);
    return _release(scope, target: _target(scope), waitForSetup: false);
  }

  /// Removes everything before the app's data is cleared: every server
  /// subscription that can still be reached, every key, every record.
  Future<void> releaseAll() async {
    _update((s) => s.copyWith(enabled: false));
    await Future.wait([
      for (final scope in _knownScopes())
        _release(
          scope,
          target: _target(scope),
          forget: true,
          waitForSetup: false,
        ),
    ]);
    _records = {};
    await _settings.saveRecords(const {});
    await _settings.setEnabled(false);
    await _settings.saveTombstones(const []);
    await _settings.setLastFullReconcile(null);
    _scheduleDisplayConfig();
    await _releaseRelayTransports();
  }

  // ---------------------------------------------------------------------
  // Triggers
  // ---------------------------------------------------------------------

  void _onTargets(List<PushTarget> next) {
    if (!ref.mounted) return;
    final firstLoad = _targets == null;
    final previous = {for (final t in _targets ?? const []) t.scope: t};
    _targets = next;
    final current = {for (final t in next) t.scope: t};
    _publishTargets();
    _scheduleDisplayConfig();

    for (final entry in previous.entries) {
      if (!current.containsKey(entry.key)) {
        // Its subscription goes; the user's choices for it stay, in case it
        // comes back (Hermes turned off and on, a list emptied by an
        // interrupted sign-out).
        unawaited(_release(entry.key, target: entry.value, forget: true));
      }
    }
    // Before an edit can move a connection to another server: how to reach
    // the one its subscription is on.
    if (state.enabled) {
      for (final target in next) {
        if (target is HermesPushTarget &&
            _record(target.scope).sid != null &&
            previous[target.scope]?.serverIdentity != target.serverIdentity) {
          unawaited(_factory.retain(target));
        }
      }
    }
    if (firstLoad) {
      unawaited(_startup());
      return;
    }
    if (!state.enabled) return;
    final added = <OpenWebUiPushTarget>[];
    for (final target in next) {
      final before = previous[target.scope];
      if (before == null) {
        if (target is OpenWebUiPushTarget) added.add(target);
        unawaited(_reconcile(target));
      } else if (before is OpenWebUiPushTarget &&
          target is OpenWebUiPushTarget &&
          before.hasSession != target.hasSession) {
        if (target.hasSession) {
          unawaited(_reconcile(target));
        } else {
          unawaited(
            _release(
              target.scope,
              target: target,
              status: PushStatus.signInNeeded,
            ),
          );
        }
      } else if (before.serverIdentity != target.serverIdentity) {
        _replacedTargets[target.scope] = before;
        unawaited(_reconcile(target));
      }
    }
    if (added.isNotEmpty) unawaited(_enableAddedAccountNotifications(added));
  }

  Future<void> _startup() async {
    await _recoverFromRestore();
    if (!ref.mounted) return;
    final targets = _targets ?? const [];
    final live = {for (final t in targets) t.scope};
    // Accounts and connections removed while the app was not running. A
    // record with no subscription only keeps the user's choices.
    for (final entry in _records.entries.toList()) {
      if (!live.contains(entry.key) && entry.value.hasSubscription) {
        unawaited(_release(entry.key, forget: true));
      }
    }
    await _refreshTransports();
    _scheduleDisplayConfig();
    if (!state.enabled) {
      await _sweepNative();
      // Push may have been turned off by a version that could not stop
      // APNs or FCM.
      if (_hasTransports == true) await _releaseRelayTransports();
      return;
    }
    await _reconcileAll(full: _fullReconcileDue());
  }

  Future<void> _onResume() async {
    // A UnifiedPush distributor may have been installed meanwhile.
    if (!state.enabled) {
      await _refreshTransports();
      return;
    }
    if (_targets == null) return;
    await _reconcileAll(full: _fullReconcileDue(), throttle: true);
  }

  /// Which transports this device offers, for the settings to say whether
  /// push can work before it is turned on.
  Future<void> _refreshTransports() async {
    List<PushTransport> transports;
    try {
      transports = await _platform.availableTransports();
    } catch (_) {
      transports = const [];
    }
    _hasTransports = transports.isNotEmpty;
    _update(
      (s) => s.copyWith(
        availableTransports: transports,
        transportsChecked: true,
      ),
    );
  }

  /// A device restored from another device's backup has that device's push
  /// preferences (its device id, its subscription records) but not its keys,
  /// which never leave the device they were made on. Those subscriptions are
  /// the other device's: they are forgotten here without being removed from
  /// any server, and this device gets an id of its own, so servers do not
  /// evict one device's entry for the other's.
  Future<void> _recoverFromRestore() async {
    if (!_records.values.any((record) => record.hasSubscription)) return;
    final List<PushSubscriptionKeys> native;
    try {
      native = await _platform.listSubscriptions();
    } catch (_) {
      return;
    }
    if (native.isNotEmpty || !ref.mounted) return;
    DebugLogger.warning('push-restored-from-backup', scope: 'push');
    _records = {
      for (final entry in _records.entries)
        if (entry.value.hasChoices)
          entry.key: entry.value.withoutSubscription(),
    };
    await _settings.saveRecords(_records);
    await _tombstoneLock.synchronized(() => _settings.saveTombstones(const []));
    await _settings.resetDeviceId();
    await _settings.setLastFullReconcile(null);
    _publishTargets();
  }

  bool _fullReconcileDue() {
    final last = _settings.lastFullReconcile;
    return last == null ||
        _now().difference(last) >= _timings.fullReconcileInterval;
  }

  void _onEventsChanged() {
    if (!state.enabled) return;
    for (final target in _targets ?? const <PushTarget>[]) {
      // A setup running now may have picked its events already; the pass
      // queued behind it uploads the new ones.
      if (_isOn(target.scope) || _runner(target.scope).lock.locked) {
        unawaited(_reconcile(target));
      }
    }
  }

  void _onPlatformEvent(PushPlatformEvent event) {
    switch (event) {
      case PushTokenEvent(:final token):
        _onToken(token);
      case PushTestReceivedEvent(:final sid, :final nonce):
        _confirmTest(sid, nonce);
      case PushForegroundEvent(:final message):
        // A test push decrypted in the foreground verifies too. Routing
        // other foreground pushes to the notification router is a later
        // integration step.
        _confirmTestPayload(message.sid, message.payloadJson);
      case PushTapEvent():
        // Integration point: the notification tap router opens taps.
        break;
      case PushUnregisteredEvent(:final sid):
        unawaited(_onEndpointGone(sid));
      case PushUnifiedPushEndpointEvent(:final sid, :final endpoint):
        unawaited(_onUnifiedPushEndpoint(sid, endpoint));
    }
  }

  void _onToken(PushDeviceToken token) {
    _environment = null;
    if (!state.enabled) return;
    final fingerprint = _fingerprint(token.token);
    for (final target in _targets ?? const <PushTarget>[]) {
      final record = _record(target.scope);
      if (record.transport == token.transport &&
          record.tokenFingerprint != fingerprint) {
        unawaited(_reconcile(target));
      }
    }
  }

  /// The platform dropped [sid]'s endpoint. This wins over a setup running
  /// for it: that setup stops at its next step instead of saving the old
  /// endpoint back, and the setup queued here registers a new one.
  Future<void> _onEndpointGone(String sid) async {
    final scope = _scopeOfSid(sid);
    if (scope == null) return;
    _runner(scope).endpointEpoch++;
    await _saveRecord(
      scope,
      _record(scope).copyWith(clearEndpoint: true, clearVerifiedAt: true),
    );
    final target = _target(scope);
    if (target != null && state.enabled) await _reconcile(target);
  }

  Future<void> _onUnifiedPushEndpoint(String sid, String endpoint) async {
    final scope = _scopeOfSid(sid);
    if (scope == null) return;
    final record = _record(scope);
    if (record.endpoint == endpoint) return;
    _runner(scope).endpointEpoch++;
    try {
      await _platform.setEndpoint(sid, endpoint, PushTransport.unifiedPush);
    } catch (error) {
      _log('push-set-endpoint-failed', error);
    }
    await _saveRecord(
      scope,
      _withEndpoint(
        record,
        endpoint: endpoint,
        transport: PushTransport.unifiedPush,
        fingerprint: record.tokenFingerprint,
        kid: null,
      ),
    );
    final target = _target(scope);
    if (target != null && state.enabled) await _reconcile(target);
  }

  // ---------------------------------------------------------------------
  // Reconciling
  // ---------------------------------------------------------------------

  /// Runs a pass over the targets. A pass already running covers this
  /// request once it ends, unless this one must reach every target with
  /// what changed since it started, wants a full pass it is not, is [fresh]
  /// (the user turned push on or reset its keys), or a removal ran during it
  /// and may have cancelled some of its setups.
  Future<void> _reconcileAll({
    required bool full,
    bool everyTarget = false,
    bool throttle = false,
    bool fresh = false,
  }) async {
    final running = _pass;
    if (running != null) {
      await running.done;
      final covered =
          !fresh &&
          !everyTarget &&
          (!full || running.full) &&
          running.releases == _releases;
      if (covered) return;
    }
    final pass = _Pass(full: full, releases: _releases);
    _pass = pass;
    try {
      await _runPass(full: full, everyTarget: everyTarget, throttle: throttle);
    } finally {
      pass.complete();
      if (identical(_pass, pass)) _pass = null;
    }
  }

  Future<void> _runPass({
    required bool full,
    required bool everyTarget,
    required bool throttle,
  }) async {
    if (!ref.mounted || !state.enabled || _targets == null) return;
    if (full) {
      _environment = null;
      _relayInfo = null;
    }
    final now = _now();
    final targets = _targets ?? const <PushTarget>[];
    // An endpoint made for an older token, relay key or distributor is dead
    // (one distributor at a time: a new one drops the others' registrations),
    // and the platform does not always say so: catch those here too.
    final environment = full || everyTarget ? null : await _env();
    if (!ref.mounted) return;
    bool stale(PushTarget target) {
      if (environment == null || environment.status != null) return false;
      final record = _record(target.scope);
      return record.endpoint != null && !_endpointCurrent(record, environment);
    }

    await Future.wait([
      for (final target in targets)
        if (full ||
            everyTarget ||
            stale(target) ||
            (!_isOn(target.scope) &&
                (!throttle || _mayRetry(target.scope, now))))
          _reconcile(target),
    ]);
    if (!ref.mounted || !full) return;
    await _processTombstones();
    await _sweepNative();
    await _settings.setLastFullReconcile(_now());
  }

  bool _mayRetry(String scope, DateTime now) {
    final last = _runner(scope).lastAttempt;
    return last == null || now.difference(last) >= _timings.resumeRetryInterval;
  }

  Future<void> _reconcile(
    PushTarget target, {
    bool forceTest = false,
    bool resubscribe = false,
    bool freshEndpoint = false,
  }) async {
    final runner = _runner(target.scope);
    final generation = runner.generation;
    // A removal under way ends first: until it has, it may still delete the
    // keys and clear the record this setup would reuse. One that starts
    // later cancels this setup instead.
    final removal = runner.removal;
    if (removal != null) await removal;
    return runner.lock.synchronized(() async {
      if (!ref.mounted || runner.generation != generation) return;
      runner.lastAttempt = _now();
      try {
        await _pipeline(
          target,
          runner,
          generation,
          runner.endpointEpoch,
          forceTest: forceTest,
          resubscribe: resubscribe,
          freshEndpoint: freshEndpoint,
        );
      } on _Aborted {
        return;
      } on _Stop catch (stop) {
        if (!ref.mounted || runner.generation != generation) return;
        _finish(
          target,
          stop.status,
          failure: stop.failure,
          probe: stop.probe,
          diagnostics: stop.diagnostics,
        );
      } catch (error, stackTrace) {
        DebugLogger.error(
          'push-reconcile-failed',
          scope: 'push',
          error: error,
          stackTrace: stackTrace,
        );
        if (!ref.mounted || runner.generation != generation) return;
        _finish(
          target,
          PushStatus.failed,
          failure: PushFailure(
            PushFailureReason.unknown,
            detail: error.runtimeType.toString(),
          ),
        );
      }
    });
  }

  Future<void> _pipeline(
    PushTarget target,
    _ScopeRunner runner,
    int generation,
    int endpointEpoch, {
    required bool forceTest,
    required bool resubscribe,
    required bool freshEndpoint,
  }) async {
    // Stops this setup once the target was removed, or its endpoint was
    // reported gone or replaced: what it holds is stale then, and saving it
    // would undo that. The removal, or the setup queued with the news, takes
    // over.
    void checkpoint() {
      if (!ref.mounted ||
          runner.generation != generation ||
          runner.endpointEpoch != endpointEpoch) {
        throw const _Aborted();
      }
    }

    final scope = target.scope;
    var record = _record(scope);
    if (!state.enabled || record.optedOut) {
      _finish(target, PushStatus.off);
      return;
    }
    if (target is OpenWebUiPushTarget && !target.hasSession) {
      throw const _Stop(PushStatus.signInNeeded);
    }
    final environment = await _env();
    checkpoint();
    final blocked = environment.status;
    if (blocked != null) throw _Stop(blocked, failure: environment.failure);
    final transport = environment.transport!;

    // A different server (or key, or mode) needs a new subscription.
    final fingerprint = target.serverIdentity == null
        ? null
        : _fingerprint(target.serverIdentity!);
    if (record.sid != null &&
        fingerprint != null &&
        record.serverFingerprint != null &&
        record.serverFingerprint != fingerprint) {
      // Only through the target as it was: the connection's settings now
      // reach the new server, where the old subscription is not.
      await _retire(scope, record, target: _replacedTargets.remove(scope));
      checkpoint();
      record = _record(scope).withoutSubscription();
      await _saveRecord(scope, record);
    }

    _setTarget(
      scope,
      (t) => t.copyWith(
        status: PushStatus.settingUp,
        transport: transport,
        clearFailure: true,
      ),
    );

    final keys = await _keysFor(scope, record);
    checkpoint();
    if (keys.sid != record.sid) {
      record = PushSubscriptionRecord(
        sid: keys.sid,
        optedOut: record.optedOut,
        origin: record.origin,
        serverFingerprint: fingerprint,
      );
      await _saveRecord(scope, record);
    } else if (record.serverFingerprint != fingerprint) {
      record = record.copyWith(serverFingerprint: fingerprint);
    }

    record = await _ensureEndpoint(
      keys,
      record,
      environment,
      fresh: freshEndpoint,
    );
    checkpoint();
    await _saveRecord(scope, record);

    final PushBackend backend;
    try {
      backend = await _factory.open(target);
    } on PushBackendException catch (error) {
      throw _Stop(
        error.signInNeeded ? PushStatus.signInNeeded : PushStatus.failed,
        failure: error.signInNeeded ? null : error.failure,
      );
    }
    try {
      checkpoint();
      var probe = await backend.probe();
      checkpoint();
      if (!probe.isReady) {
        throw _Stop(probe.status, failure: probe.failure, probe: probe);
      }
      final events = _eventsFor(target);
      final needTest = forceTest || record.verifiedAt == null;
      final needSubscribe =
          needTest ||
          resubscribe ||
          record.subscribedAt == null ||
          !const ListEquality<String>().equals(record.events, events) ||
          _now().difference(record.subscribedAt!) >=
              _timings.fullReconcileInterval;
      if (needSubscribe) {
        final device = ref.read(pushDeviceDescriptionProvider);
        final subscription = PushServerSubscription(
          sid: keys.sid,
          did: await _settings.deviceId(),
          endpoint: record.endpoint!,
          p256dh: keys.p256dh,
          auth: keys.auth,
          events: events,
          label: device.label,
          platform: device.platform,
          // The latest choice: one made before this setup saved a sid
          // queued no resubscribe of its own.
          origin: _record(scope).origin,
        );
        try {
          if (needTest) {
            record = await _subscribeAndTest(
              target,
              backend,
              subscription,
              record,
              checkpoint,
            );
          } else {
            await backend.subscribe(subscription);
            checkpoint();
            record = record.copyWith(
              subscribedAt: _now(),
              events: events,
              clearLastError: true,
            );
            await _saveRecord(scope, record);
          }
        } on PushBackendException catch (error) {
          final detail = error.failure.detail;
          if (!error.signInNeeded &&
              (detail == 'function_missing' || detail == 'function_inactive')) {
            // Removed or switched off since the probe: say what it is now.
            probe = await backend.probe();
            checkpoint();
            if (!probe.isReady) {
              throw _Stop(probe.status, failure: probe.failure, probe: probe);
            }
          }
          rethrow;
        }
      }
      checkpoint();
      _finish(
        target,
        probe.updateAvailable ? PushStatus.updateAvailable : PushStatus.on,
        probe: probe,
      );
    } on PushBackendException catch (error) {
      throw _Stop(
        error.signInNeeded ? PushStatus.signInNeeded : PushStatus.failed,
        failure: error.signInNeeded ? null : error.failure,
      );
    } finally {
      backend.close();
    }
  }

  Future<PushSubscriptionRecord> _subscribeAndTest(
    PushTarget target,
    PushBackend backend,
    PushServerSubscription subscription,
    PushSubscriptionRecord record,
    void Function() checkpoint,
  ) async {
    final scope = target.scope;
    final nonce = randomPushToken();
    final pending = _expectTest(subscription.sid, nonce);
    _setTarget(scope, (t) => t.copyWith(status: PushStatus.verifying));
    try {
      final dispatch = await backend.subscribe(subscription, testNonce: nonce);
      checkpoint();
      record = record.copyWith(
        subscribedAt: _now(),
        events: subscription.events,
        clearVerifiedAt: true,
      );
      await _saveRecord(scope, record);
      final sent = dispatch?.diagnostics;
      if (dispatch != null && dispatch.failedAtServer) {
        throw _Stop(
          PushStatus.failed,
          failure: PushFailure(
            PushFailureReason.deliveryFailed,
            detail: sent?.error ?? sent?.code?.toString(),
          ),
          diagnostics: sent,
        );
      }
      final arrived = await _waitForTest(pending);
      checkpoint();
      if (!arrived) {
        var diagnostics = sent;
        try {
          diagnostics = await backend.diagnose(subscription.sid) ?? sent;
        } catch (error) {
          _log('push-diagnose-failed', error);
        }
        // The server's status can be from an earlier attempt; only one that
        // names this nonce, or carries no nonce at all, explains this one.
        final relevant =
            diagnostics != null &&
                (diagnostics.nonce == null || diagnostics.nonce == nonce)
            ? diagnostics
            : null;
        throw _Stop(
          PushStatus.failed,
          failure: PushFailure(
            relevant?.error == null
                ? PushFailureReason.testTimeout
                : PushFailureReason.deliveryFailed,
            detail: relevant?.error,
          ),
          diagnostics: relevant,
        );
      }
      record = record.copyWith(verifiedAt: _now(), clearLastError: true);
      await _saveRecord(scope, record);
      _setTarget(
        scope,
        (t) =>
            t.copyWith(verifiedAt: record.verifiedAt, clearDiagnostics: true),
      );
      return record;
    } finally {
      pending.complete(false);
      if (identical(_pendingTests[subscription.sid], pending)) {
        _pendingTests.remove(subscription.sid);
      }
    }
  }

  Future<PushSubscriptionKeys> _keysFor(
    String scope,
    PushSubscriptionRecord record,
  ) async {
    final List<PushSubscriptionKeys> native;
    try {
      native = await _platform.listSubscriptions();
    } catch (error) {
      throw _Stop(
        PushStatus.failed,
        failure: PushFailure(
          PushFailureReason.platformError,
          detail: _errorCode(error),
        ),
      );
    }
    final mine = native.where((keys) => keys.scope == scope).toList();
    var keys = record.sid == null
        ? mine.firstOrNull
        : mine.firstWhereOrNull((keys) => keys.sid == record.sid);
    if (keys == null) {
      try {
        keys = await _platform.createSubscription(scope);
      } catch (error) {
        throw _Stop(
          PushStatus.failed,
          failure: PushFailure(
            PushFailureReason.platformError,
            detail: _errorCode(error),
          ),
        );
      }
    }
    for (final extra in mine) {
      if (extra.sid == keys.sid) continue;
      await _addTombstone(
        extra.sid,
        scope,
        server: extra.sid == record.sid ? record.serverFingerprint : null,
      );
      await _deleteNative(extra.sid, extra.transport);
    }
    return keys;
  }

  /// [record] with an endpoint that works for [environment]: the one it has
  /// when that is still current, else a newly registered one. [fresh]
  /// registers a new one regardless, for a retry: an endpoint can be dead
  /// while everything it was made from still matches.
  Future<PushSubscriptionRecord> _ensureEndpoint(
    PushSubscriptionKeys keys,
    PushSubscriptionRecord record,
    _Environment environment, {
    bool fresh = false,
  }) async {
    final transport = environment.transport!;
    final fingerprint = _endpointFingerprint(environment);
    if (!fresh && _endpointCurrent(record, environment)) {
      if (keys.endpoint != record.endpoint) {
        await _platformCall(
          () => _platform.setEndpoint(keys.sid, record.endpoint!, transport),
        );
      }
      return record;
    }
    if (record.transport == PushTransport.unifiedPush &&
        record.endpoint != null) {
      try {
        await _platform.unregisterUnifiedPush(keys.sid);
      } catch (error) {
        _log('push-unregister-unifiedpush-failed', error);
      }
    }
    final String endpoint;
    int? kid;
    if (transport == PushTransport.unifiedPush) {
      String? registered;
      try {
        registered = await _platform.registerUnifiedPush(
          keys.sid,
          environment.distributor!,
        );
      } catch (error) {
        throw _Stop(
          PushStatus.failed,
          failure: PushFailure(
            PushFailureReason.distributorFailed,
            detail: _errorCode(error),
          ),
        );
      }
      if (registered == null || registered.isEmpty) {
        throw const _Stop(
          PushStatus.failed,
          failure: PushFailure(PushFailureReason.distributorFailed),
        );
      }
      endpoint = registered;
    } else {
      final relay = _relay!;
      final token = environment.token!;
      try {
        final registration = await relay.register(
          provider: transport.relayProvider!,
          token: token.token,
          app: token.app,
          env: token.env,
          sid: keys.sid,
        );
        endpoint = registration.endpoint;
        kid = registration.kid;
      } on PushRelayException catch (error) {
        throw _relayStop(error);
      }
    }
    await _platformCall(
      () => _platform.setEndpoint(keys.sid, endpoint, transport),
    );
    return _withEndpoint(
      record,
      endpoint: endpoint,
      transport: transport,
      fingerprint: fingerprint,
      kid: kid,
    );
  }

  /// What an endpoint for [environment] was made from: the device token, or
  /// the UnifiedPush distributor. Only its SHA-256 is kept.
  static String _endpointFingerprint(_Environment environment) =>
      environment.transport == PushTransport.unifiedPush
      ? _fingerprint('unifiedPush:${environment.distributor}')
      : _fingerprint(environment.token!.token);

  /// Whether [record]'s endpoint still works for [environment]: same
  /// transport, same token or distributor, and a relay key that is not older
  /// than the relay's active one.
  static bool _endpointCurrent(
    PushSubscriptionRecord record,
    _Environment environment,
  ) {
    final transport = environment.transport!;
    final activeKid = environment.relayInfo?.activeKid;
    return record.endpoint != null &&
        record.transport == transport &&
        record.tokenFingerprint == _endpointFingerprint(environment) &&
        (transport == PushTransport.unifiedPush ||
            activeKid == null ||
            (record.kid ?? 0) >= activeKid);
  }

  static _Stop _relayStop(PushRelayException error) => switch (error.kind) {
    PushRelayErrorKind.appNotAllowed ||
    PushRelayErrorKind.providerUnconfigured => _Stop(
      PushStatus.relayUnavailable,
      failure: PushFailure(
        PushFailureReason.relayError,
        detail: error.kind.name,
      ),
    ),
    PushRelayErrorKind.rateLimited => _Stop(
      PushStatus.failed,
      failure: PushFailure(
        PushFailureReason.relayRateLimited,
        detail: error.retryAfter?.inSeconds.toString(),
      ),
    ),
    PushRelayErrorKind.network => const _Stop(
      PushStatus.failed,
      failure: PushFailure(PushFailureReason.relayError, detail: 'network'),
    ),
    _ => _Stop(
      PushStatus.failed,
      failure: PushFailure(
        PushFailureReason.relayError,
        detail: error.statusCode?.toString() ?? error.kind.name,
      ),
    ),
  };

  Future<_Environment> _env() {
    final cached = _environment;
    final at = _environmentAt;
    if (cached != null &&
        at != null &&
        _now().difference(at) < const Duration(minutes: 10)) {
      return cached;
    }
    final next = _resolveEnvironment();
    _environment = next;
    _environmentAt = _now();
    // A failure is not cached: the next target asks again.
    unawaited(
      next.then(
        (environment) {
          if (environment.status != null && identical(_environment, next)) {
            _environment = null;
          }
        },
        onError: (Object _) {
          if (identical(_environment, next)) _environment = null;
        },
      ),
    );
    return next;
  }

  Future<_Environment> _resolveEnvironment() async {
    List<PushTransport> transports;
    try {
      transports = await _platform.availableTransports();
    } catch (error) {
      _log('push-transports-failed', error);
      transports = const [];
    }
    _hasTransports = transports.isNotEmpty;
    final relay = _relay;
    _update(
      (s) => s.copyWith(
        availableTransports: transports,
        transportsChecked: true,
      ),
    );
    if (transports.isEmpty) {
      return _blockedEnvironment(
        relay == null ? PushStatus.relayUnavailable : PushStatus.failed,
        const PushFailure(PushFailureReason.noTransport),
      );
    }
    // Automatic passes never prompt: only the user turning push on, retrying
    // or sending a test does.
    if (!await _checkPermission()) {
      return _blockedEnvironment(PushStatus.permissionDenied, null);
    }

    PushTransport? transport;
    String? distributor;
    PushStatus? blocked;
    if (transports.contains(PushTransport.apns)) {
      transport = relay == null ? null : PushTransport.apns;
      if (transport == null) blocked = PushStatus.relayUnavailable;
    } else {
      final fcmUsable = transports.contains(PushTransport.fcm) && relay != null;
      final installed = transports.contains(PushTransport.unifiedPush)
          ? await distributors()
          : const <String>[];
      final saved = _settings.distributor;
      distributor = installed.contains(saved) ? saved : installed.firstOrNull;
      switch (_settings.androidTransport) {
        case PushAndroidTransport.fcm:
          transport = fcmUsable ? PushTransport.fcm : null;
          if (transport == null) {
            blocked = relay == null
                ? PushStatus.relayUnavailable
                : PushStatus.failed;
          }
        case PushAndroidTransport.unifiedPush:
          transport = distributor != null ? PushTransport.unifiedPush : null;
          if (transport == null) blocked = PushStatus.failed;
        case null:
          transport = fcmUsable
              ? PushTransport.fcm
              : distributor != null
              ? PushTransport.unifiedPush
              : null;
          if (transport == null) {
            blocked = relay == null && transports.contains(PushTransport.fcm)
                ? PushStatus.relayUnavailable
                : PushStatus.failed;
          }
      }
    }
    _update(
      (s) => s.copyWith(
        effectiveTransport: transport,
        clearEffectiveTransport: transport == null,
      ),
    );
    if (blocked != null) {
      return _blockedEnvironment(
        blocked,
        const PushFailure(PushFailureReason.noTransport),
      );
    }
    if (transport == PushTransport.unifiedPush) {
      return _Environment(transport: transport, distributor: distributor);
    }

    final PushDeviceToken? token;
    try {
      token = await _platform.currentToken(transport!);
    } catch (error) {
      return _blockedEnvironment(
        PushStatus.failed,
        PushFailure(PushFailureReason.noToken, detail: _errorCode(error)),
      );
    }
    if (token == null) {
      return _blockedEnvironment(
        PushStatus.failed,
        const PushFailure(PushFailureReason.noToken),
      );
    }
    final info = await _freshRelayInfo(relay!);
    if (info != null && !info.providers.contains(transport.relayProvider)) {
      return _blockedEnvironment(
        PushStatus.relayUnavailable,
        const PushFailure(
          PushFailureReason.relayError,
          detail: 'provider_unconfigured',
        ),
      );
    }
    return _Environment(transport: transport, token: token, relayInfo: info);
  }

  _Environment _blockedEnvironment(PushStatus status, PushFailure? failure) {
    if (status == PushStatus.permissionDenied) {
      _update((s) => s.copyWith(permissionDenied: true));
    }
    return _Environment(status: status, failure: failure);
  }

  /// The relay's info, at most [PushTimings.relayInfoMaxAge] old. Null when
  /// it cannot be fetched: the endpoint's key id is then not checked.
  Future<PushRelayInfo?> _freshRelayInfo(PushRelayClient relay) async {
    final cached = _relayInfo;
    final at = _relayInfoAt;
    if (cached != null &&
        at != null &&
        _now().difference(at) < _timings.relayInfoMaxAge) {
      return cached;
    }
    try {
      final info = await relay.info();
      _relayInfo = info;
      _relayInfoAt = _now();
      return info;
    } on PushRelayException catch (error) {
      _log('push-relay-info-failed', error);
      return null;
    }
  }

  /// Shows the system prompt. Only for a user action.
  Future<void> _requestPermission() async {
    try {
      _permissionGranted = await _platform.requestPermission();
    } catch (error) {
      _log('push-permission-request-failed', error);
      _permissionGranted = null;
      return;
    }
    _update((s) => s.copyWith(permissionDenied: _permissionGranted == false));
  }

  /// Prompts only when notifications are not allowed already.
  Future<void> _askPermissionIfMissing() async {
    if (await _checkPermission()) return;
    await _requestPermission();
    // A denial is shown by the setup that follows.
    _environment = null;
  }

  /// Whether notifications are allowed, without prompting. A platform that
  /// cannot tell falls back to the answer of this process's last prompt.
  Future<bool> _checkPermission() async {
    bool? granted;
    try {
      granted = await _platform.hasPermission();
    } catch (error) {
      _log('push-permission-check-failed', error);
    }
    granted ??= _permissionGranted;
    final allowed = granted ?? false;
    _permissionGranted = allowed;
    _update((s) => s.copyWith(permissionDenied: !allowed));
    return allowed;
  }

  Future<bool> _install(PushTarget target) async {
    _setTarget(
      target.scope,
      (t) => t.copyWith(status: PushStatus.settingUp, clearFailure: true),
    );
    try {
      await _withBackend(target, (backend) => backend.install());
      return true;
    } on PushBackendException catch (error) {
      _finish(
        target,
        error.signInNeeded ? PushStatus.signInNeeded : PushStatus.failed,
        failure: error.failure,
      );
      return false;
    } catch (error) {
      _finish(
        target,
        PushStatus.failed,
        failure: PushFailure(
          PushFailureReason.installFailed,
          detail: error.runtimeType.toString(),
        ),
      );
      return false;
    }
  }

  // ---------------------------------------------------------------------
  // Test pushes
  // ---------------------------------------------------------------------

  _PendingTest _expectTest(String sid, String nonce) {
    _pendingTests[sid]?.complete(false);
    return _pendingTests[sid] = _PendingTest(sid, nonce);
  }

  Future<bool> _waitForTest(_PendingTest pending) async {
    var polling = false;
    final timer = Timer.periodic(_timings.testPollInterval, (_) async {
      if (polling || pending.isCompleted) return;
      polling = true;
      try {
        final nonces = await _platform.takeVerifiedNonces(pending.sid);
        if (nonces.contains(pending.nonce)) pending.complete(true);
      } catch (_) {
        // The next tick asks again.
      } finally {
        polling = false;
      }
    });
    try {
      return await pending.future.timeout(
        _timings.testTimeout,
        onTimeout: () => false,
      );
    } finally {
      timer.cancel();
    }
  }

  void _confirmTest(String sid, String nonce) {
    final pending = _pendingTests[sid];
    if (pending != null && pending.nonce == nonce) pending.complete(true);
  }

  void _confirmTestPayload(String sid, String payloadJson) {
    final pending = _pendingTests[sid];
    if (pending == null) return;
    try {
      final payload = jsonDecode(payloadJson);
      if (payload is Map && payload['k'] == 'test') {
        _confirmTest(sid, payload['n']?.toString() ?? '');
      }
    } on FormatException {
      return;
    }
  }

  // ---------------------------------------------------------------------
  // Removal
  // ---------------------------------------------------------------------

  /// Removes [scope]'s subscription: from its server first (bounded), then
  /// its keys and its delivered notifications. With [forget] the record goes
  /// too, except for the user's choices for the target, which stay unless the
  /// user deleted it ([releaseHermesConnection]); otherwise the record keeps
  /// them as well.
  ///
  /// A setup running for [scope] is cancelled at its next step. Unless
  /// [waitForSetup] is false (a sign-out, whose time is bounded), this waits
  /// up to [PushTimings.releaseWait] for it. When it is still running after
  /// that, its subscribe may still land on the server after the unsubscribe
  /// here: its sids are tombstoned whatever the server answers, and removed
  /// once more after the setup has stopped.
  ///
  /// A setup asked for while this runs waits for it to end, however it ends.
  Future<void> _release(
    String scope, {
    PushTarget? target,
    bool forget = false,
    PushStatus status = PushStatus.off,
    bool waitForSetup = true,
  }) {
    final runner = _runner(scope);
    final removal = _removeSubscription(
      scope,
      runner,
      target: target,
      forget: forget,
      status: status,
      waitForSetup: waitForSetup,
    );
    final earlier = runner.removal;
    final settled = removal.then<void>((_) {}, onError: (Object _) {});
    final pending = earlier == null
        ? settled
        : Future.wait([earlier, settled]).then<void>((_) {});
    runner.removal = pending;
    unawaited(
      pending.whenComplete(() {
        if (identical(runner.removal, pending)) runner.removal = null;
      }),
    );
    return removal;
  }

  Future<void> _removeSubscription(
    String scope,
    _ScopeRunner runner, {
    required PushTarget? target,
    required bool forget,
    required PushStatus status,
    required bool waitForSetup,
  }) async {
    runner.generation++;
    _releases++;
    final before = _record(scope);
    if (before.sid != null) _pendingTests[before.sid]?.complete(false);
    var setupRunning = false;
    if (runner.lock.locked) {
      if (waitForSetup) {
        try {
          await runner.lock.synchronized(() {}).timeout(_timings.releaseWait);
        } catch (_) {
          // A setup still talking to its server; it stops at its next step.
          setupRunning = true;
        }
      } else {
        setupRunning = true;
      }
    }
    final record = _record(scope);
    final sids = <String, ({PushTransport? transport, String? server})>{
      if (before.sid != null)
        before.sid!: (
          transport: before.transport,
          server: before.serverFingerprint,
        ),
      if (record.sid != null)
        record.sid!: (
          transport: record.transport,
          server: record.serverFingerprint,
        ),
    };
    try {
      for (final keys in await _platform.listSubscriptions()) {
        if (keys.scope == scope) {
          sids.putIfAbsent(
            keys.sid,
            () => (transport: keys.transport, server: null),
          );
        }
      }
    } catch (_) {
      // Without the platform's list, the recorded sid is all there is.
    }
    if (sids.isNotEmpty) {
      final removed = target == null
          ? const <String>{}
          : await _unsubscribe(target, sids.keys);
      for (final entry in sids.entries) {
        if (setupRunning || !removed.contains(entry.key)) {
          await _addTombstone(entry.key, scope, server: entry.value.server);
        }
        await _deleteNative(entry.key, entry.value.transport);
      }
      if (setupRunning && target != null) {
        _unsubscribeAfterSetup(runner, target, sids.keys.toList());
      }
    }
    try {
      await _platform.cancelScope(scope);
    } catch (error) {
      _log('push-cancel-scope-failed', error);
    }
    if (!ref.mounted) return;
    if (forget && !(_targets?.any((t) => t.scope == scope) ?? false)) {
      final keep = record.hasChoices && !_choicesToDrop.contains(scope);
      _choicesToDrop.remove(scope);
      if (keep) {
        _records[scope] = record.withoutSubscription();
      } else {
        _records.remove(scope);
      }
      await _settings.saveRecords(_records);
      _update((s) => s.copyWith(targets: Map.of(s.targets)..remove(scope)));
    } else {
      await _saveRecord(scope, record.withoutSubscription());
      _setTarget(
        scope,
        (t) => t.copyWith(
          status: record.optedOut ? PushStatus.off : status,
          clearFailure: true,
          clearDiagnostics: true,
          clearVerifiedAt: true,
          clearTransport: true,
        ),
      );
    }
    _scheduleDisplayConfig();
  }

  /// Removes [sids] from [target]'s server again once the setup holding
  /// [runner] has stopped, for a subscribe that may have landed after a
  /// removal's own unsubscribe. Clears the tombstones of those it removes.
  void _unsubscribeAfterSetup(
    _ScopeRunner runner,
    PushTarget target,
    List<String> sids,
  ) {
    unawaited(
      runner.lock
          .synchronized(() async {
            if (!ref.mounted) return;
            final removed = await _unsubscribe(target, sids);
            await _removeTombstones(removed);
          })
          .catchError((Object error) => _log('push-unsubscribe-again', error)),
    );
  }

  /// Removes [sids] from [target]'s server within
  /// [PushTimings.unsubscribeTimeout]. Answers the ones removed.
  Future<Set<String>> _unsubscribe(
    PushTarget target,
    Iterable<String> sids,
  ) async {
    final removed = <String>{};
    try {
      await _withBackend(target, (backend) async {
        for (final sid in sids) {
          await backend.unsubscribe(sid);
          removed.add(sid);
        }
      }).timeout(_timings.unsubscribeTimeout);
    } catch (error) {
      _log('push-unsubscribe-failed', error);
    }
    return removed;
  }

  /// The server copy of an old subscription, best effort, before a new one
  /// replaces it. [target] is the target as it was when the subscription was
  /// made; without it (the change happened while the app was not running)
  /// the subscription is only tombstoned for its own server, never removed
  /// through the target's new settings.
  Future<void> _retire(
    String scope,
    PushSubscriptionRecord record, {
    required PushTarget? target,
  }) async {
    final sid = record.sid;
    if (sid == null) return;
    final removed = target == null
        ? const <String>{}
        : await _unsubscribe(target, [sid]);
    if (!removed.contains(sid)) {
      await _addTombstone(sid, scope, server: record.serverFingerprint);
    }
    await _deleteNative(sid, record.transport);
    try {
      await _platform.cancelScope(scope);
    } catch (_) {}
  }

  /// Stops APNs and FCM once nothing uses them: no token, and on Android no
  /// Firebase at launch.
  Future<void> _releaseRelayTransports() =>
      _releaseTransports(const [PushTransport.apns, PushTransport.fcm]);

  Future<void> _releaseTransports(List<PushTransport> transports) async {
    final release = _releaseTransportsNow(transports);
    _transportRelease = release;
    try {
      await release;
    } finally {
      if (identical(_transportRelease, release)) _transportRelease = null;
    }
  }

  Future<void> _releaseTransportsNow(List<PushTransport> transports) async {
    List<PushTransport> available;
    try {
      available = await _platform.availableTransports();
    } catch (_) {
      return;
    }
    for (final transport in transports) {
      if (!available.contains(transport)) continue;
      try {
        await _platform.releaseTransport(transport);
      } catch (error) {
        _log('push-release-transport-failed', error);
      }
    }
    _environment = null;
  }

  Future<void> _deleteNative(String sid, PushTransport? transport) async {
    if (transport == PushTransport.unifiedPush) {
      try {
        await _platform.unregisterUnifiedPush(sid);
      } catch (error) {
        _log('push-unregister-unifiedpush-failed', error);
      }
    }
    try {
      await _platform.deleteSubscription(sid);
    } catch (error) {
      _log('push-delete-subscription-failed', error);
    }
  }

  Future<void> _addTombstone(
    String sid,
    String scope, {
    String? server,
  }) => _tombstoneLock.synchronized(() async {
    final tombstones = _settings.tombstones()
      ..removeWhere((t) => t.sid == sid)
      ..add(PushTombstone(sid: sid, scope: scope, at: _now(), server: server));
    await _settings.saveTombstones(tombstones);
  });

  Future<void> _removeTombstones(Set<String> sids) async {
    if (sids.isEmpty) return;
    await _tombstoneLock.synchronized(() async {
      final tombstones = _settings.tombstones();
      final kept = [
        for (final t in tombstones)
          if (!sids.contains(t.sid)) t,
      ];
      if (kept.length != tombstones.length) {
        await _settings.saveTombstones(kept);
      }
    });
  }

  /// Retries removing deleted subscriptions from servers that could not be
  /// reached at the time, for 30 days. A tombstone is only tried through a
  /// target on the server it names, while that target is on or opted out
  /// (its subscription may be the one left behind). Tombstones added while
  /// this runs stay: only those removed or expired here are dropped, from
  /// the list as it is when this finishes.
  Future<void> _processTombstones() async {
    final now = _now();
    final tombstones = _settings.tombstones();
    if (tombstones.isEmpty) return;
    final done = <String>{};
    final byScope = groupBy(tombstones, (PushTombstone t) => t.scope);
    for (final entry in byScope.entries) {
      final fresh = <PushTombstone>[];
      for (final tombstone in entry.value) {
        if (now.difference(tombstone.at) < const Duration(days: 30)) {
          fresh.add(tombstone);
        } else {
          done.add(tombstone.sid);
        }
      }
      final target = _target(entry.key);
      if (fresh.isEmpty ||
          target == null ||
          !(_isOn(entry.key) || _record(entry.key).optedOut)) {
        continue;
      }
      final serverIdentity = target.serverIdentity;
      final server = serverIdentity == null
          ? null
          : _fingerprint(serverIdentity);
      final reachable = [
        for (final t in fresh)
          if (t.server == null || t.server == server) t.sid,
      ];
      if (reachable.isEmpty) continue;
      done.addAll(await _unsubscribe(target, reachable));
    }
    await _removeTombstones(done);
  }

  /// Deletes platform keys nothing uses any more: all of them while push is
  /// off, and otherwise those of targets that are gone or opted out.
  Future<void> _sweepNative() async {
    final List<PushSubscriptionKeys> native;
    try {
      native = await _platform.listSubscriptions();
    } catch (_) {
      return;
    }
    final now = _now();
    final live = {for (final t in _targets ?? const <PushTarget>[]) t.scope};
    for (final keys in native) {
      if (_runner(keys.scope).lock.locked) continue;
      if (now.difference(keys.createdAt) < const Duration(minutes: 1)) continue;
      final record = _records[keys.scope];
      final keep =
          state.enabled &&
          live.contains(keys.scope) &&
          record != null &&
          record.sid == keys.sid &&
          !record.optedOut;
      if (keep) continue;
      await _addTombstone(
        keys.sid,
        keys.scope,
        server: record?.sid == keys.sid ? record?.serverFingerprint : null,
      );
      await _deleteNative(keys.sid, keys.transport);
    }
  }

  // ---------------------------------------------------------------------
  // Display config
  // ---------------------------------------------------------------------

  void _scheduleDisplayConfig() {
    if (_configScheduled) return;
    _configScheduled = true;
    scheduleMicrotask(() {
      _configScheduled = false;
      unawaited(_syncDisplayConfig());
    });
  }

  Future<void> _syncDisplayConfig() async {
    if (!ref.mounted) return;
    _markNotificationsOff();
    if (_hasTransports == false) return;
    final config = displayConfig();
    if (config == _lastConfig) return;
    _lastConfig = config;
    try {
      await _platform.setConfig(config);
    } catch (error) {
      _lastConfig = null;
      _log('push-set-config-failed', error);
    }
  }

  /// What the platform shows pushes with, from the master toggle, the
  /// notification settings, the opted-out targets and their labels.
  ///
  /// The notifications switch belongs to each Open WebUI account (it mirrors
  /// that account's server setting), so an account that has it off is a
  /// disabled scope rather than a reason to drop every push.
  PushDisplayConfig displayConfig() {
    final app = ref.read(appSettingsProvider);
    final targets = _targets ?? const <PushTarget>[];
    final on = state.targets.values
        .where(
          (t) =>
              t.status == PushStatus.on ||
              t.status == PushStatus.updateAvailable,
        )
        .length;
    return PushDisplayConfig(
      enabled: state.enabled && app.notificationSystem,
      sound: app.notificationSound,
      enabledKinds: [
        if (app.notificationChatEnabled) ...['reply', 'reply_failed'],
        if (app.notificationChannelEnabled) 'channel',
        if (app.notificationScheduledEnabled) 'cron',
        'test',
      ],
      disabledScopes: [
        for (final target in targets)
          if (_record(target.scope).optedOut || _notificationsOff(target))
            target.scope,
      ],
      scopeLabels: {for (final target in targets) target.scope: target.label},
      showScopeLabel: on > 1,
      strings: Map<String, String>.of(ref.read(pushLocalizedStringsProvider)),
    );
  }

  List<String> _eventsFor(PushTarget target) {
    final app = ref.read(appSettingsProvider);
    return [
      if (app.notificationChatEnabled) ...['reply', 'reply_failed'],
      if (target.kind == PushTargetKind.openWebUi &&
          app.notificationChannelEnabled)
        'channel',
      if (target.kind == PushTargetKind.hermes &&
          app.notificationScheduledEnabled)
        'cron',
    ];
  }

  /// Whether [target]'s notifications switch is off: an Open WebUI
  /// account's own, or the device-level one for a Hermes connection (see
  /// [notificationsEnabledForScope], which the notification router uses
  /// too).
  bool _notificationsOff(PushTarget target) => !notificationsEnabledForScope(
    target.scope,
    activeValue: ref.read(appSettingsProvider).notificationsEnabled,
  );

  void _markNotificationsOff() {
    for (final target in _targets ?? const <PushTarget>[]) {
      final off = _notificationsOff(target);
      if (state.targets[target.scope]?.notificationsOff != off) {
        _setTarget(target.scope, (t) => t.copyWith(notificationsOff: off));
      }
    }
  }

  /// Turns on the notifications switch of every Open WebUI account that never
  /// stored one, and of the active account; an inactive account that turned
  /// its switch off keeps it off. The device-level switch Hermes and Direct
  /// follow goes on too.
  ///
  /// An account's switch is a copy of its server's setting, which replaces
  /// the copy the next time the account loads, so each one turned on here is
  /// written to its server as well, as the Notifications page does: the
  /// active account's through its live client, every other through a client
  /// of its own. Those writes run in the background; one that fails is only
  /// logged.
  Future<void> _enableAccountNotifications() async {
    final turnedOn = <String>[];
    try {
      final app = ref.read(appSettingsProvider);
      final active = currentPreferenceAccountId();
      if (!app.notificationsEnabled) {
        await ref
            .read(appSettingsProvider.notifier)
            .setNotificationsEnabled(true);
        if (active != null) turnedOn.add(active);
      }
      if (PreferencesStore.getBool(PreferenceKeys.notificationsEnabled) !=
          true) {
        await PreferencesStore.put(PreferenceKeys.notificationsEnabled, true);
      }
      for (final target in _targets ?? const <PushTarget>[]) {
        if (target is! OpenWebUiPushTarget || target.accountId == active) {
          continue;
        }
        final key = accountScopedPreferenceKey(
          PreferenceKeys.notificationsEnabled,
          target.accountId,
        );
        if (PreferencesStore.getBool(key) == null) {
          await PreferencesStore.put(key, true);
          if (target.hasSession) turnedOn.add(target.accountId);
        }
      }
    } catch (error) {
      _log('push-notifications-enable-failed', error);
    }
    _writeNotificationsOn(turnedOn);
  }

  /// For Open WebUI accounts added while push is on, does what turning push
  /// on does: an account that never stored its notifications switch gets it
  /// on, and one that set it either way keeps it.
  ///
  /// It is stored for that account alone, as its server's copy is, so the
  /// device-level switch stays the user's last choice. On the server it is
  /// only written where the account has no value yet: one it holds is
  /// mirrored in when the account loads, and replaces this.
  Future<void> _enableAddedAccountNotifications(
    List<OpenWebUiPushTarget> accounts,
  ) async {
    final turnedOn = <String>[];
    try {
      for (final account in accounts) {
        final key = accountScopedPreferenceKey(
          PreferenceKeys.notificationsEnabled,
          account.accountId,
        );
        if (PreferencesStore.getBool(key) != null) continue;
        await ref
            .read(appSettingsProvider.notifier)
            .applyServerNotificationPrefs(
              accountId: account.accountId,
              enabled: true,
            );
        if (account.hasSession) turnedOn.add(account.accountId);
      }
    } catch (error) {
      _log('push-notifications-enable-failed', error);
    }
    _scheduleDisplayConfig();
    _writeNotificationsOn(turnedOn, onlyIfUnset: true);
  }

  /// Writes the switch of each of [accountIds], turned on here, to its
  /// server in the background. One that fails is only logged.
  void _writeNotificationsOn(
    List<String> accountIds, {
    bool onlyIfUnset = false,
  }) {
    for (final accountId in accountIds) {
      unawaited(
        _factory
            .setOpenWebUiNotificationsEnabled(
              accountId,
              enabled: true,
              onlyIfUnset: onlyIfUnset,
            )
            .catchError(
              (Object error) => _log('push-notifications-sync-failed', error),
            ),
      );
    }
  }

  // ---------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------

  void _update(PushState Function(PushState state) change) {
    if (!ref.mounted) return;
    state = change(state);
  }

  void _setTarget(
    String scope,
    PushTargetState Function(PushTargetState target) change,
  ) {
    if (!ref.mounted) return;
    final existing = state.targets[scope];
    if (existing == null) return;
    state = state.copyWith(
      targets: {...state.targets, scope: change(existing)},
    );
  }

  void _finish(
    PushTarget target,
    PushStatus status, {
    PushFailure? failure,
    PushProbe? probe,
    PushServerDiagnostics? diagnostics,
  }) {
    final scope = target.scope;
    final record = _record(scope);
    final lastError = status == PushStatus.failed ? failure : null;
    if (record.lastError != lastError) {
      unawaited(
        _saveRecord(
          scope,
          lastError == null
              ? record.copyWith(clearLastError: true)
              : record.copyWith(lastError: lastError),
        ),
      );
    }
    _setTarget(
      scope,
      (t) => PushTargetState(
        target: target,
        status: status,
        failure: failure,
        hermesInstallCommand: probe?.hermesInstallCommand,
        canInstallHermesPlugin: probe?.canInstallHermesPlugin ?? false,
        diagnostics:
            diagnostics ?? (status == PushStatus.failed ? t.diagnostics : null),
        origin: record.origin,
        optedOut: record.optedOut,
        notificationsOff: t.notificationsOff,
        verifiedAt: record.verifiedAt,
        transport: record.transport,
        serverVersion: probe?.serverVersion ?? t.serverVersion,
        pluginVersion: probe?.pluginVersion ?? t.pluginVersion,
        bundledVersion: probe?.bundledVersion ?? t.bundledVersion,
      ),
    );
    _scheduleDisplayConfig();
  }

  void _publishTargets() {
    if (!ref.mounted) return;
    final targets = _targets ?? const <PushTarget>[];
    state = state.copyWith(
      targets: {
        for (final target in targets)
          target.scope: _initialState(target, state.targets[target.scope]),
      },
    );
  }

  PushTargetState _initialState(PushTarget target, PushTargetState? existing) {
    final record = _record(target.scope);
    if (!state.enabled || record.optedOut) {
      return PushTargetState(
        target: target,
        origin: record.origin,
        optedOut: record.optedOut,
      );
    }
    if (existing != null && existing.status != PushStatus.off) {
      return existing.copyWith(
        target: target,
        origin: record.origin,
        optedOut: record.optedOut,
      );
    }
    final PushStatus status;
    if (target is OpenWebUiPushTarget && !target.hasSession) {
      status = PushStatus.signInNeeded;
    } else if (record.lastError != null) {
      status = PushStatus.failed;
    } else if (record.verifiedAt != null) {
      status = PushStatus.on;
    } else {
      status = PushStatus.settingUp;
    }
    return PushTargetState(
      target: target,
      status: status,
      failure: record.lastError,
      origin: record.origin,
      optedOut: record.optedOut,
      verifiedAt: record.verifiedAt,
      transport: record.transport,
    );
  }

  PushSubscriptionRecord _record(String scope) =>
      _records[scope] ?? const PushSubscriptionRecord();

  /// Stores [record] for [scope]. The user's choices (opted out, origin)
  /// come from the stored record unless [choices] says this sets them: a
  /// setup holds the record it read when it started, and must not put back
  /// a choice the user changed meanwhile.
  Future<void> _saveRecord(
    String scope,
    PushSubscriptionRecord record, {
    bool choices = false,
  }) async {
    final current = _records[scope];
    _records[scope] = choices || current == null
        ? record
        : record.withChoicesOf(current);
    await _settings.saveRecords(_records);
  }

  PushTarget? _target(String scope) =>
      _targets?.firstWhereOrNull((target) => target.scope == scope);

  Set<String> _knownScopes() => {
    ..._records.keys,
    for (final target in _targets ?? const <PushTarget>[]) target.scope,
  };

  String? _scopeOfSid(String sid) =>
      _records.entries.firstWhereOrNull((e) => e.value.sid == sid)?.key;

  bool _isOn(String scope) {
    final status = state.targets[scope]?.status;
    return status == PushStatus.on || status == PushStatus.updateAvailable;
  }

  _ScopeRunner _runner(String scope) =>
      _runners.putIfAbsent(scope, _ScopeRunner.new);

  Future<T> _withBackend<T>(
    PushTarget target,
    Future<T> Function(PushBackend backend) body,
  ) async {
    final backend = await _factory.open(target);
    try {
      return await body(backend);
    } finally {
      backend.close();
    }
  }

  Future<void> _platformCall(Future<void> Function() call) async {
    try {
      await call();
    } catch (error) {
      throw _Stop(
        PushStatus.failed,
        failure: PushFailure(
          PushFailureReason.platformError,
          detail: _errorCode(error),
        ),
      );
    }
  }

  static PushSubscriptionRecord _withEndpoint(
    PushSubscriptionRecord record, {
    required String endpoint,
    required PushTransport transport,
    required String? fingerprint,
    required int? kid,
  }) => PushSubscriptionRecord(
    sid: record.sid,
    endpoint: endpoint,
    transport: transport,
    tokenFingerprint: fingerprint,
    kid: kid,
    verifiedAt: endpoint == record.endpoint ? record.verifiedAt : null,
    optedOut: record.optedOut,
    origin: record.origin,
    lastError: record.lastError,
    serverFingerprint: record.serverFingerprint,
    events: record.events,
    subscribedAt: endpoint == record.endpoint ? record.subscribedAt : null,
  );

  static String _fingerprint(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  /// A platform error's code (`apns_timeout`, `channel-error`, …) without
  /// naming Flutter's exception type, which the core cannot import.
  static String _errorCode(Object error) {
    try {
      final code = (error as dynamic).code;
      if (code is String && code.isNotEmpty) return code;
    } catch (_) {
      // Not a platform exception.
    }
    return error.runtimeType.toString();
  }

  static void _log(String message, Object error) => DebugLogger.warning(
    message,
    scope: 'push',
    data: {'errorType': error.runtimeType.toString()},
  );
}

/// Whether notifications for [scope] are switched on. The notification
/// router and push both go by this.
///
/// An Open WebUI account has a switch of its own, a copy of its server
/// setting: [activeValue] (the app settings' value) for the active account,
/// its stored copy for any other.
///
/// Hermes and Direct belong to the device rather than to an account, so
/// they follow the device-level switch: the value stored without an
/// account. It is what the Notifications page shows and edits while no Open
/// WebUI account is active, and the page keeps it in step with the active
/// account's switch otherwise ([SettingsService.setNotificationsEnabled]),
/// so it is always the one the user set last. One never stored follows
/// [activeValue].
bool notificationsEnabledForScope(String scope, {required bool activeValue}) {
  switch (NotificationScope.tryParse(scope)) {
    case OpenWebUiNotificationScope(:final accountId):
      if (accountId == currentPreferenceAccountId()) return activeValue;
      return openWebUiAccountNotificationsEnabled(accountId);
    case HermesNotificationScope() || DirectNotificationScope():
      return PreferencesStore.getBool(PreferenceKeys.notificationsEnabled) ??
          activeValue;
    case null:
      return activeValue;
  }
}

/// An Open WebUI account's own notifications switch, read from its stored
/// copy of the server setting. One that never stored it follows the
/// device-wide value until the per-account copy has run, as the settings do.
bool openWebUiAccountNotificationsEnabled(String accountId) {
  final stored = PreferencesStore.getBool(
    accountScopedPreferenceKey(PreferenceKeys.notificationsEnabled, accountId),
  );
  if (stored != null) return stored;
  final migrated =
      PreferencesStore.getBool(PreferenceKeys.accountScopedSettingsMigrated) ==
      true;
  if (migrated) return false;
  return PreferencesStore.getBool(PreferenceKeys.notificationsEnabled) ?? false;
}

/// A Hermes job's delivery targets could not be read, so "Notify me" is
/// not changed for it: writing them back would drop the unread ones.
final class HermesJobDeliveryUnknown implements Exception {
  const HermesJobDeliveryUnknown();

  @override
  String toString() => 'HermesJobDeliveryUnknown';
}

final class _ScopeRunner {
  final Lock lock = Lock();

  /// Bumped by a removal: a setup started before it stops at its next step.
  int generation = 0;

  /// Bumped when the platform reports the endpoint gone or replaced: a
  /// setup started before it stops too, so it cannot save the old endpoint.
  int endpointEpoch = 0;
  DateTime? lastAttempt;

  /// The removals under way, settled whatever their outcome. A setup waits
  /// for them before it starts.
  Future<void>? removal;
}

/// One pass over the targets, for requests that arrive while it runs.
final class _Pass {
  _Pass({required this.full, required this.releases});

  final bool full;

  /// The coordinator's removal count when it started.
  final int releases;
  final Completer<void> _done = Completer<void>();

  Future<void> get done => _done.future;

  void complete() {
    if (!_done.isCompleted) _done.complete();
  }
}

final class _PendingTest {
  _PendingTest(this.sid, this.nonce);

  final String sid;
  final String nonce;
  final Completer<bool> _completer = Completer<bool>();

  Future<bool> get future => _completer.future;
  bool get isCompleted => _completer.isCompleted;

  void complete(bool arrived) {
    if (!_completer.isCompleted) _completer.complete(arrived);
  }
}

final class _Environment {
  const _Environment({
    this.transport,
    this.token,
    this.relayInfo,
    this.distributor,
    this.status,
    this.failure,
  });

  final PushTransport? transport;
  final PushDeviceToken? token;
  final PushRelayInfo? relayInfo;
  final String? distributor;

  /// Set when no target can get past the transport step.
  final PushStatus? status;
  final PushFailure? failure;
}

/// Ends one target's setup with [status].
final class _Stop implements Exception {
  const _Stop(this.status, {this.failure, this.probe, this.diagnostics});

  final PushStatus status;
  final PushFailure? failure;
  final PushProbe? probe;
  final PushServerDiagnostics? diagnostics;
}

/// The target was removed while its setup ran.
final class _Aborted implements Exception {
  const _Aborted();
}
