import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/features/chat/providers/chat_handoff_providers.dart'
    show chatHandoffCoordinatorProvider;
import 'package:conduit_core/database/account_storage_isolation.dart';
import 'package:conduit_core/database/database_provider.dart'
    show appDatabaseProvider;
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart'
    show
        effectiveDirectConnectionProfilesFutureProvider,
        openWebUiDirectCompletionSocketRelayProvider;
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart'
    show
        hermesConfigProvider,
        hermesModelSwitchPromptProvider,
        hostHermesDashboardBridgeFactoryProvider,
        hostHermesDashboardSignOutProvider;
import 'package:conduit_core/navigation/route_redirect.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/persistence/hive_boxes.dart';
import 'package:conduit_core/persistence/persistence_providers.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show activeServerProvider, apiServiceProvider, socketServiceManagerProvider;
import 'package:conduit_core/features/chat/services/request_completion_runner.dart'
    show chatRequestCompletionRunnerProvider;
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/providers/host_ports.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart'
    show openWebUiDuplicateAccountReconcilerProvider;
import 'package:conduit_core/providers/storage_providers.dart';
import 'package:conduit_core/services/connectivity_service.dart'
    show isOnlineProvider;
import 'package:conduit_core/services/settings_service.dart'
    show AppSettingsHostDefaults, appSettingsHostDefaultsProvider;
import 'package:conduit_core/sync/request_completion_runner_provider.dart';
import 'package:conduit_core/features/chat/read_aloud/text_to_speech_controller.dart'
    show readAloudLiveDeviceSpeechProvider;
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:hive_ce/hive.dart';
import 'package:mcp_dart/mcp_dart.dart' as mcp;
import 'package:path/path.dart' as p;
import 'package:conduit_core/features/chat/read_aloud/text_to_speech_controller.dart'
    show textToSpeechServiceProvider;
import 'package:conduit_core/features/chat/realtime_call/realtime_call_availability.dart'
    show realtimePcmAudioFactoryProvider, realtimeWebRtcMediaFactoryProvider;
import 'package:conduit_core/features/chat/voice_mode/voice_mode_ports.dart'
    show voiceModeInputProvider, voiceModeSpeechProvider;
import 'package:riverpod/misc.dart' show Override;
import 'package:riverpod/riverpod.dart';

import 'bootstrap.dart';
import 'daemon_paths.dart';
import 'hermes_dashboard_cookies.dart';
import 'hermes_service.dart' show hermesAwaitsSignIn;
import 'log.dart';
import 'apple_models_service.dart' show AppleModelsBridge, appleModelsOverrides;
import 'location_bridge.dart';
import 'calls_service.dart' show CallPorts;
import 'ports/handoff.dart';
import 'ports/connectivity.dart';
import 'ports/database_opener.dart';
import 'ports/key_value_store.dart';
import 'ports/open_url.dart';
import 'ports/ui_requests.dart';
import 'ports/secure_store.dart';
import 'ports/worker.dart';
import 'settled.dart';

/// Hosts `conduit_core` inside the daemon.
///
/// This is the desktop counterpart of the `ProviderScope` in the mobile
/// app's `main.dart`: the core declares its host ports without values, and
/// each host binds its own. Everything the renderer can ask for eventually
/// resolves through this container, which is what makes "the daemon owns all
/// state" true rather than aspirational.
///
/// Deliberately one container for the whole process, not one per RPC session.
/// Two windows share a signed-in account, a database and a sync engine; a
/// container per window would give each its own copy of all three and let
/// them disagree.
final class CoreRuntime {
  CoreRuntime._({
    required this.container,
    required this.directories,
    required DaemonConnectivity connectivity,
    required this.openUrl,
    required this.uiRequests,
    required this.handoff,
    required this.calls,
    required this.apple,
    required this.dashboardCookies,
    required this.location,
    required List<Box<dynamic>> boxes,
  }) : _connectivity = connectivity,
       _boxes = boxes;

  final ProviderContainer container;
  final DaemonDirectories directories;
  final DaemonConnectivity _connectivity;

  /// How the core opens a page in the system browser; the server attaches
  /// its event bus once there is one.
  final DaemonOpenUrlPort openUrl;

  /// How the core asks the user something mid-turn; the server attaches its
  /// broker once there is one.
  final DaemonUiRequestPort uiRequests;

  /// How a server's `chat:handoff` is put to the user; the server attaches
  /// its handoff service once there is one.
  final DaemonHandoffPort handoff;

  /// A voice call's microphone and realtime audio: the window, through the
  /// calls service, which attaches once there is one.
  final CallPorts calls;

  /// The window's Foundation Models engine, as the core's Apple host: the
  /// Apple service binds it to the event bus once there is one.
  final AppleModelsBridge apple;

  /// The Hermes dashboard sessions the window's sign-in handed over, and
  /// the core's cookie store ([DaemonHermesDashboardCookies]).
  final DaemonHermesDashboardCookies dashboardCookies;
  /// The window's location services, as the core's location port: the
  /// server binds it to the event bus once there is one.
  final WindowLocationBridge location;

  /// Takes a window's view of the network, which arrives as an event where
  /// the port can only poll.
  void reportNetwork({required bool online}) => _connectivity.report(online);
  final List<Box<dynamic>> _boxes;

  /// Whether the user still has to choose a backend: no Open WebUI account,
  /// and no Direct or Hermes setup to fall back on.
  ///
  /// Asked of the core's own routing policy, as the mobile router asks it
  /// on a cold start at the chat, so the two apps send the same people to
  /// onboarding. The policy reads loading state as "wait", so the stored
  /// server, the Direct profiles and the Hermes secrets are let settle
  /// first, within [budget]; past it the answer is false, which only costs
  /// the window a round trip.
  Future<bool> needsOnboarding({
    Duration budget = const Duration(seconds: 2),
  }) async {
    try {
      await Future.wait<Object?>(<Future<Object?>>[
        readSettled(container, activeServerProvider.future),
        readSettled(
          container,
          effectiveDirectConnectionProfilesFutureProvider.future,
        ),
        container.read(hermesConfigProvider.notifier).waitForSecretsHydration(),
      ]).timeout(budget);
    } on Object catch (error) {
      // Decided on what has settled; anything still loading reads as "not
      // onboarding".
      DebugLogger.warning(
        'onboarding-inputs-unsettled',
        scope: 'daemon/runtime',
        data: <String, Object?>{'errorType': error.runtimeType.toString()},
      );
    }
    final destination = resolveRouteRedirect(Routes.chat, container.read);
    DebugLogger.log(
      'onboarding-check',
      scope: 'daemon/runtime',
      data: <String, Object?>{'destination': destination},
    );
    if (destination == Routes.backendChooser) return true;
    // A backend chosen but not finished: the phone sends the user to finish
    // it on its own page (the Hermes settings, the Direct connections), the
    // desktop finishes it in onboarding.
    if (destination == Routes.hermesSettings ||
        (destination != null &&
            Uri.parse(destination).path == Routes.directConnections)) {
      return true;
    }
    // So is a chosen Hermes gateway that still has to sign in: the core
    // counts it set up, but it cannot answer yet (see [hermesAwaitsSignIn]).
    return destination == null &&
        container.read(activeServerProvider).value == null &&
        container.read(preferredBackendProvider) == PreferredBackend.hermes &&
        hermesAwaitsSignIn(container.read(hermesConfigProvider));
  }

  /// Sends what the outbox holds, for at most [budget], and returns how
  /// many operations are still waiting.
  ///
  /// What is left is not lost: the outbox is on disk and drains on the next
  /// launch. The count tells the caller whether that will be needed.
  Future<int> flushOutbox({
    Duration budget = const Duration(seconds: 3),
  }) async {
    final database = container.read(appDatabaseProvider);
    if (database == null) return 0;
    try {
      await container
          .read(syncEngineProvider.notifier)
          .drainOutbox()
          .timeout(budget);
    } on TimeoutException {
      // Whatever has not gone yet is counted below.
    } on Object catch (error) {
      DebugLogger.error(
        'shutdown-drain-failed',
        scope: 'daemon/runtime',
        error: error,
      );
    }
    return database.outboxDao.watchPendingCount().first;
  }

  /// How many outbox operations are waiting to be sent; 0 with no account
  /// database open.
  Future<int> pendingOutboxCount() async {
    final database = container.read(appDatabaseProvider);
    if (database == null) return 0;
    return database.outboxDao.watchPendingCount().first;
  }

  /// Brings the core up: storage first, then the container.
  ///
  /// Ordering is not incidental. `PreferencesStore` exposes synchronous
  /// getters that 227 call sites depend on, so its backing store has to be
  /// fully loaded before any provider is read -- and the Hive boxes have to
  /// be open before [hiveBoxesProvider] is overridden with them.
  static Future<CoreRuntime> start({
    required BootstrapConfig config,
    required DaemonDirectories directories,
    required DaemonLog log,
    // For diagnosing provider behaviour from outside -- a rebuild loop, a
    // future that never settles -- without editing the core to add logging.
    List<ProviderObserver> observers = const <ProviderObserver>[],
  }) async {
    // The daemon, like the mobile app, owns two database files on purpose:
    // the server's and the direct-local one.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    // The MCP client narrates every connection on stderr. Its warnings and
    // errors belong in the daemon's log; the rest is noise.
    mcp.setMcpLogHandler((name, level, message) {
      if (level.index < mcp.LogLevel.warn.index) return;
      DebugLogger.warning(
        'mcp-client',
        scope: 'daemon/mcp',
        data: <String, Object?>{'logger': name, 'message': message},
      );
    });
    final secureStore = await DaemonSecureStore.open(
      file: File(p.join(directories.paths.userData, 'secure_store.bin')),
      masterKey: base64.decode(config.masterKey),
    );

    final preferences = await DaemonKeyValueStore.open(
      File(p.join(directories.paths.userData, 'preferences.json')),
    );
    PreferencesStore.installLoader(() async => preferences);
    await PreferencesStore.ensureInitialized();

    Hive.init(p.join(directories.paths.userData, 'hive'));
    final boxes = await _openHiveBoxes();

    final connectivity = DaemonConnectivity();
    connectivity.start();
    final openUrl = DaemonOpenUrlPort();
    final uiRequests = DaemonUiRequestPort();
    final handoff = DaemonHandoffPort();
    final calls = CallPorts();
    final apple = AppleModelsBridge();
    final dashboardCookies = await DaemonHermesDashboardCookies.open(
      secureStore,
    );
    final location = WindowLocationBridge();

    final container = ProviderContainer(
      observers: observers,
      retry: daemonProviderRetry,
      overrides: <Override>[
        databaseOpenerProvider.overrideWithValue(
          DaemonDatabaseOpener(directories),
        ),
        workerPortProvider.overrideWithValue(const DaemonWorkerPort()),
        connectivityPortProvider.overrideWithValue(connectivity),
        openExternalUrlProvider.overrideWithValue(openUrl),
        uiRequestPortProvider.overrideWithValue(uiRequests),
        // Hermes holding a switch to another model asks the windows, as a
        // phone asks its screen (`hermesModelSwitch`).
        hermesModelSwitchPromptProvider.overrideWithValue(
          uiRequests.confirmHermesModelSwitch,
        ),
        // A server's `chat:handoff` is asked of the windows, which open the
        // new chat themselves; a phone's coordinator asks its screen.
        chatHandoffCoordinatorProvider.overrideWith(handoff.coordinator),
        // The outbox runs a queued Open WebUI completion through the chat
        // library, as on mobile: live into the chat scope that has the chat
        // open, headless otherwise. The core leaves this seam to its host
        // so `core/sync` never imports `features/chat`; unbound, a queued
        // turn has nothing to run it.
        requestCompletionRunnerProvider.overrideWith(
          (ref) => ref.watch(chatRequestCompletionRunnerProvider),
        ),
        secureStorageProvider.overrideWithValue(secureStore),
        hiveBoxesProvider.overrideWithValue(boxes.value),
        // Mobile routes the post-certification catch-up through its sync
        // triggers, which also watch lifecycle and connectivity. The sidecar
        // has neither, so it asks the engine directly.
        hostPostCertificationSyncProvider.overrideWithValue(
          () => unawaited(_pullAfterCertification()),
        ),
        // A Mac always has a hardware keyboard: Enter sends until the user
        // turns Send with Enter off (mobile's default stays off). A Mac app
        // asks for notification permission the first time one would show,
        // so notifications start on (the phone asks when they are turned
        // on, so its default stays off).
        appSettingsHostDefaultsProvider.overrideWithValue(
          const AppSettingsHostDefaults(
            sendOnEnter: true,
            notificationsEnabled: true,
          ),
        ),
        // The Mac's voices read aloud live, reporting each word, and the
        // reading moves from sentence to sentence (the phone renders clips).
        readAloudLiveDeviceSpeechProvider.overrideWithValue(true),
        // A voice call listens through the window (dictation's engines),
        // speaks through the read-aloud engine as the phone's does, and for
        // a realtime voice runs the window's echo-cancelled audio, or its
        // WebRTC peer for Hermes GPT-Live.
        voiceModeInputProvider.overrideWithValue(calls.input),
        voiceModeSpeechProvider.overrideWith(
          (ref) => ref.watch(textToSpeechServiceProvider),
        ),
        realtimePcmAudioFactoryProvider.overrideWithValue(
          calls.newRealtimeAudio,
        ),
        realtimeWebRtcMediaFactoryProvider.overrideWithValue(
          calls.newWebRtcMedia,
        ),
        // Apple's on-device model runs in the window (Foundation Models is a
        // Swift API); the core's Apple adapter reaches it through this host,
        // as the phone's reaches its Swift bridge. Private Cloud Compute is
        // never offered: this build has no entitlement for it.
        ...appleModelsOverrides(apple),
        // A Desktop Gateway's dashboard sign-in runs in the window's browser
        // window, which hands the cookies over; the daemon then holds them
        // as a phone's WebView does, and sends the dashboard's requests with
        // them (the phone sends them from a hidden WebView page). Its store
        // holds only those: Open WebUI's sign-in windows keep nothing.
        cookieJarProvider.overrideWithValue(dashboardCookies),
        hostHermesDashboardBridgeFactoryProvider.overrideWith(
          (ref) =>
              ({
                required Uri root,
                required Map<String, String> accessHeaders,
              }) => dashboardCookies.bridge(
                root: root,
                accessHeaders: accessHeaders,
                httpClient: hermesDashboardHttpClientFor(
                  root,
                  ref.read(hermesConfigProvider),
                ),
              ),
        ),
        hostHermesDashboardSignOutProvider.overrideWith(
          (ref) =>
              ({
                required Uri root,
                required Map<String, String> accessHeaders,
              }) => dashboardCookies.signOut(
                root: root,
                accessHeaders: accessHeaders,
                httpClient: hermesDashboardHttpClientFor(
                  root,
                  ref.read(hermesConfigProvider),
                ),
              ),
        ),
        // `{{USER_LOCATION}}` from the window's location services, asked
        // only for a request or a prompt template that names it, and only
        // while the account's location setting is on (the phone asks for
        // every request while it is on).
        ...windowLocationOverrides(location),
        // The remaining ports keep the core's own defaults, and each is a
        // deliberate choice rather than an omission:
        //
        // * `appLifecycleProvider` -- a headless sidecar has no lifecycle of
        //   its own. `resumed` is the truth, since the daemon only runs
        //   while the desktop app does.
        // * `flushScheduler` / `postFrameScheduler` -- both exist to align
        //   work with a Flutter frame. There is no frame here; the microtask
        //   defaults are the correct degenerate case.
        // * `clipboardPortProvider` -- the clipboard belongs to the
        //   renderer's process, not this one, so it crosses as RPC.
      ],
    );

    // Kept alive deliberately. Until this notifier certifies the signed-in
    // account against the on-disk owner marker, `appDatabaseProvider` yields
    // null -- and with no database there is no conversation list, no offline
    // history and no sync, because every one of those reads it. Nothing else
    // in the sidecar would ever construct it.
    container.read(openWebUiAccountStorageIsolationProvider);

    // The Socket.IO connection, held open for the daemon's lifetime.
    //
    // The manager is lazy and nothing else in the sidecar reads it, so until
    // now the daemon had no socket at all. Turns went out as plain HTTP
    // streams, which is enough for text. It is not enough for anything the
    // server starts: a tool asking for approval, a function asking the user
    // a question, a title arriving after the answer. All of those are
    // socket event calls, and with no socket they had nowhere to arrive.
    // A listener rather than a `read`, because the manager rebuilds on every
    // sign-in and server switch, and a read would keep only the first.
    container.listen(socketServiceManagerProvider, (_, _) {});

    _containerForSync = container;
    // Open WebUI's own direct connections: when a chat uses one, the server
    // asks the client, over the socket, to make the request. The core's
    // relay answers; mobile keeps it for the whole session, and so does the
    // daemon.
    container.listen<void>(
      openWebUiDirectCompletionSocketRelayProvider,
      (_, _) {},
    );
    // Folds a sign-in into the account the same user already has on that
    // server, so adding an account as someone already saved there does not
    // leave two accounts for one person. The core asks its host to keep it
    // mounted for the life of the app, as mobile does.
    container.listen<void>(
      openWebUiDuplicateAccountReconcilerProvider,
      (_, _) {},
    );
    // The session's API client, held for as long as the daemon runs, as
    // mobile's UI holds it. Several core paths check "is this still the
    // session I started with" by the client's identity; unheld, the
    // provider was rebuilt between two reads and every such check failed --
    // creating a note came back as "the session changed".
    container.listen<Object?>(apiServiceProvider, (_, _) {});
    // The same for the account's database, which the same checks compare:
    // read cold, the first answer and the next could differ.
    container.listen<Object?>(appDatabaseProvider, (_, _) {});
    // The connection coming back sends what the outbox holds: a message
    // sent while the server was out of reach, and the chat's changes before
    // it. On mobile `syncTriggers` does this; the daemon does not run those
    // triggers (they also pull on a timer and on app lifecycle), so it
    // takes this one alone. Nothing else drains the outbox then: an op that
    // failed as the connection went would wait for the next send.
    container.listen<bool>(isOnlineProvider, (previous, next) {
      if (previous == false && next) unawaited(_drainAfterReconnect());
    });
    log.info('core runtime ready');
    return CoreRuntime._(
      container: container,
      directories: directories,
      connectivity: connectivity,
      openUrl: openUrl,
      uiRequests: uiRequests,
      handoff: handoff,
      calls: calls,
      apple: apple,
      dashboardCookies: dashboardCookies,
      location: location,
      boxes: boxes.all,
    );
  }

  Future<void> dispose() async {
    container.dispose();
    await _connectivity.dispose();
    for (final box in _boxes) {
      await box.close();
    }
  }

  /// Set once the container exists, so the override above can reach it.
  static ProviderContainer? _containerForSync;

  static Future<void> _pullAfterCertification() async {
    final container = _containerForSync;
    if (container == null) return;
    try {
      await container
          .read(syncEngineProvider.notifier)
          .requestPull(reason: 'account-certified');
    } on Object catch (error) {
      DebugLogger.error(
        'post-certification-pull-failed',
        scope: 'daemon/runtime',
        error: error,
      );
    }
  }

  static Future<void> _drainAfterReconnect() async {
    final container = _containerForSync;
    if (container == null) return;
    try {
      // Resets the pending ops' backoff, then drains.
      await container.read(syncEngineProvider.notifier).drainNow();
    } on Object catch (error) {
      DebugLogger.error(
        'reconnect-drain-failed',
        scope: 'daemon/runtime',
        error: error,
      );
    }
  }

  static Future<({HiveBoxes value, List<Box<dynamic>> all})>
  _openHiveBoxes() async {
    final preferences = await Hive.openBox<dynamic>(HiveBoxNames.preferences);
    final caches = await Hive.openBox<dynamic>(HiveBoxNames.caches);
    final attachmentQueue = await Hive.openBox<dynamic>(
      HiveBoxNames.attachmentQueue,
    );
    final metadata = await Hive.openBox<dynamic>(HiveBoxNames.metadata);
    return (
      value: HiveBoxes(
        preferences: preferences,
        caches: caches,
        attachmentQueue: attachmentQueue,
        metadata: metadata,
      ),
      all: <Box<dynamic>>[preferences, caches, attachmentQueue, metadata],
    );
  }
}
