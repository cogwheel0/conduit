import 'dart:async';

import 'package:conduit_core/database/account_storage_isolation.dart';
import 'package:conduit_core/database/database_provider.dart'
    show
        appDatabaseProvider,
        databaseManagerProvider,
        directLocalDatabaseManagerProvider;
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart'
    show
        effectiveDirectConnectionProfilesFutureProvider,
        openWebUiDirectCompletionSocketRelayProvider;
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart'
    show hermesConfigProvider;
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart'
    show libreChatDatabaseManagerProvider, libreChatHttpClientProvider;
import 'package:conduit_core/features/librechat/providers/librechat_sync_providers.dart'
    show libreChatSyncEngineProvider;
import 'package:conduit_core/navigation/route_redirect.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/persistence/hive_boxes.dart';
import 'package:conduit_core/ports/ports.dart';
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
import 'package:conduit_core/services/api_service.dart' show ApiService;
import 'package:conduit_core/services/connectivity_service.dart'
    show isOnlineProvider;
import 'package:conduit_core/services/settings_service.dart'
    show AppSettingsHostDefaults, appSettingsHostDefaultsProvider;
import 'package:conduit_core/sync/request_completion_runner_provider.dart';
import 'package:conduit_core/features/chat/read_aloud/text_to_speech_controller.dart'
    show readAloudLiveDeviceSpeechProvider;
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:mcp_dart/mcp_dart.dart' as mcp;
import 'package:conduit_core/features/chat/read_aloud/text_to_speech_controller.dart'
    show textToSpeechServiceProvider;
import 'package:conduit_core/features/chat/voice_mode/voice_mode_ports.dart'
    show voiceModeSpeechProvider;
import 'package:riverpod/misc.dart' show Override;
import 'package:riverpod/riverpod.dart';

import 'hermes_dashboard_cookies.dart';
import 'hermes_service.dart' show hermesAwaitsSignIn;
import 'apple_models_service.dart' show AppleModelsBridge;
import 'location_bridge.dart';
import 'calls_service.dart' show CallPorts;
import 'ports/handoff.dart';
import 'ports/open_url.dart';
import 'ports/ui_requests.dart';
import 'settled.dart';
import 'window_ports.dart';

/// What a host supplies to run the core: its stores and its platform's
/// ports. Each port left null keeps the core's own default.
///
/// [PreferencesStore] is not here: it is process-wide, and the host has
/// installed its loader before [CoreRuntime.start].
final class CoreHostBindings {
  const CoreHostBindings({
    required this.secureStore,
    required this.hiveBoxes,
    required this.databaseOpener,
    required this.worker,
    required this.connectivity,
    this.reportNetwork,
    this.lifecycle,
    this.flushScheduler,
    this.postFrameScheduler,
    this.overrides = const <Override>[],
    this.close,
  });

  final SecureKeyValueStore secureStore;
  final HiveBoxes hiveBoxes;
  final DatabaseOpenerPort databaseOpener;
  final WorkerPort worker;
  final ConnectivityPort connectivity;

  /// Takes a window's view of the network, which arrives as an event where
  /// [connectivity] can only poll.
  final void Function(bool online)? reportNetwork;

  /// Null: always resumed.
  final AppLifecyclePort? lifecycle;

  /// Null: work is aligned with microtasks, not frames.
  final FlushScheduler? flushScheduler;
  final PostFrameScheduler? postFrameScheduler;

  /// Anything else the host binds.
  final List<Override> overrides;

  /// Releases the stores, once the container is gone.
  final Future<void> Function()? close;
}

/// What a host decides about the core's behaviour.
final class CoreHostPolicy {
  const CoreHostPolicy({
    required this.settingsDefaults,
    required this.readAloudLiveDeviceSpeech,
  });

  /// The settings a new install starts with where hosts differ.
  final AppSettingsHostDefaults settingsDefaults;

  /// Read aloud speaks live through the device's voices, reporting each
  /// word, rather than as rendered clips.
  final bool readAloudLiveDeviceSpeech;
}

/// Hosts `conduit_core` for the protocol's services.
///
/// This is the counterpart of the `ProviderScope` in the mobile app's
/// `main.dart`: the core declares its host ports without values, and each
/// host binds its own ([CoreHostBindings]). Everything a window can ask for
/// eventually resolves through this container.
///
/// Deliberately one container for the whole process, not one per RPC session.
/// Two windows share a signed-in account, a database and a sync engine; a
/// container per window would give each its own copy of all three and let
/// them disagree.
final class CoreRuntime {
  CoreRuntime._({
    required this.container,
    required this.window,
    required CoreHostBindings host,
  }) : _host = host;

  final ProviderContainer container;
  final CoreHostBindings _host;

  /// The ports the windows answer, bound into [container].
  final WindowPorts window;

  DaemonOpenUrlPort get openUrl => window.openUrl;
  DaemonUiRequestPort get uiRequests => window.uiRequests;
  DaemonHandoffPort get handoff => window.handoff;
  CallPorts get calls => window.calls;
  AppleModelsBridge get apple => window.apple;
  WindowLocationBridge get location => window.location;

  /// Always open here: [start] keeps them in the host's secure store.
  DaemonHermesDashboardCookies get dashboardCookies =>
      window.dashboardCookies!;

  /// Takes a window's view of the network, which arrives as an event where
  /// the port can only poll.
  void reportNetwork({required bool online}) =>
      _host.reportNetwork?.call(online);

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

  /// Brings the core up over [host]'s stores: the container, then what
  /// keeps the session running ([holdCoreSession]).
  ///
  /// Ordering is not incidental. `PreferencesStore` exposes synchronous
  /// getters that 227 call sites depend on, so its backing store has to be
  /// fully loaded before any provider is read -- and the Hive boxes have to
  /// be open before [hiveBoxesProvider] is overridden with them.
  static Future<CoreRuntime> start({
    required CoreHostBindings host,
    required CoreHostPolicy policy,
    // For diagnosing provider behaviour from outside -- a rebuild loop, a
    // future that never settles -- without editing the core to add logging.
    List<ProviderObserver> observers = const <ProviderObserver>[],
  }) async {
    // The core owns two database files on purpose: the server's and the
    // direct-local one.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    // The MCP client narrates every connection on stderr. Its warnings and
    // errors belong in the host's log; the rest is noise.
    mcp.setMcpLogHandler((name, level, message) {
      if (level.index < mcp.LogLevel.warn.index) return;
      DebugLogger.warning(
        'mcp-client',
        scope: 'daemon/mcp',
        data: <String, Object?>{'logger': name, 'message': message},
      );
    });
    await PreferencesStore.ensureInitialized();
    final window = await WindowPorts.open(
      dashboardCookieStore: host.secureStore,
    );

    late final ProviderContainer container;
    container = ProviderContainer(
      observers: observers,
      retry: daemonProviderRetry,
      overrides: <Override>[
        databaseOpenerProvider.overrideWithValue(host.databaseOpener),
        workerPortProvider.overrideWithValue(host.worker),
        connectivityPortProvider.overrideWithValue(host.connectivity),
        if (host.lifecycle case final lifecycle?)
          appLifecycleProvider.overrideWithValue(lifecycle),
        if (host.flushScheduler case final scheduler?)
          flushSchedulerProvider.overrideWithValue(scheduler),
        if (host.postFrameScheduler case final scheduler?)
          postFrameSchedulerProvider.overrideWithValue(scheduler),
        // The outbox runs a queued Open WebUI completion through the chat
        // library, as on mobile: live into the chat scope that has the chat
        // open, headless otherwise. The core leaves this seam to its host
        // so `core/sync` never imports `features/chat`; unbound, a queued
        // turn has nothing to run it.
        requestCompletionRunnerProvider.overrideWith(
          (ref) => ref.watch(chatRequestCompletionRunnerProvider),
        ),
        secureStorageProvider.overrideWithValue(host.secureStore),
        hiveBoxesProvider.overrideWithValue(host.hiveBoxes),
        // Mobile routes the post-certification catch-up through its sync
        // triggers, which also watch lifecycle and connectivity. This host
        // runs no triggers, so it asks the engine directly.
        hostPostCertificationSyncProvider.overrideWithValue(
          () => unawaited(_pullAfterCertification(container)),
        ),
        appSettingsHostDefaultsProvider.overrideWithValue(
          policy.settingsDefaults,
        ),
        readAloudLiveDeviceSpeechProvider.overrideWithValue(
          policy.readAloudLiveDeviceSpeech,
        ),
        // A voice call speaks through the read-aloud engine, as the
        // phone's does.
        voiceModeSpeechProvider.overrideWith(
          (ref) => ref.watch(textToSpeechServiceProvider),
        ),
        ...window.overrides(),
        // `clipboardPortProvider` keeps the core's default: the clipboard
        // belongs to the window's process, so it crosses as RPC.
        ...host.overrides,
      ],
    );
    holdCoreSession(container);
    return CoreRuntime._(container: container, window: window, host: host);
  }

  /// Shutdown's first step, before any service is disposed: both sync
  /// engines start no new work, and the Open WebUI and LibreChat clients are
  /// cut, so a request still out, or one a service makes as it goes, fails at
  /// once instead of holding shutdown on the server. [dispose] waits for what
  /// the engines were running.
  void beginShutdown() {
    if (_syncIdle != null) return;
    _syncIdle = Future.wait<void>([
      _closeOpenWebUiSync(),
      _closeLibreChatSync(),
    ]);
    _cutOpenWebUiRequests();
    _cutLibreChatRequests();
  }

  Future<void>? _syncIdle;

  Future<void>? _disposing;

  Future<void> dispose() => _disposing ??= _dispose();

  Future<void> _dispose() async {
    // Sync work still out (a list refresh, an outbox drain nobody waits on)
    // writes the account database until it ends. Once the clients are cut,
    // what it writes needs no server, and it lands before this returns.
    // Then the databases close: the container's disposal only starts closing
    // Direct's and LibreChat's, and never closes Open WebUI's, so a write
    // still out would end with the process (or a test's directory).
    beginShutdown();
    final databases = [
      container.read(databaseManagerProvider),
      container.read(directLocalDatabaseManagerProvider),
      container.read(libreChatDatabaseManagerProvider),
    ];
    container.dispose();
    await _syncIdle;
    await Future.wait([for (final manager in databases) manager.closeActive()]);
    await _host.close?.call();
  }

  /// Stops the Open WebUI engine's new work; completes once its running work
  /// has ended.
  Future<void> _closeOpenWebUiSync() {
    // Reading it when it is not there would start an engine.
    if (!container.read(syncEngineProvider.exists)) {
      return Future<void>.value();
    }
    try {
      return container.read(syncEngineProvider.notifier).close();
    } on Object catch (error) {
      DebugLogger.error(
        'openwebui-sync-close-failed',
        scope: 'daemon/runtime',
        error: error,
      );
      return Future<void>.value();
    }
  }

  /// Fails the Open WebUI requests still out at once, on the current client
  /// and on any a rebuild retired that a sync still holds: the container's own
  /// dispose lets them run to completion, as a rebuild needs.
  void _cutOpenWebUiRequests() {
    ApiService.closeRetiredNow();
    if (!container.read(apiServiceProvider.exists)) return;
    try {
      container.read(apiServiceProvider)?.closeNow();
    } on Object catch (error) {
      DebugLogger.error(
        'openwebui-client-close-failed',
        scope: 'daemon/runtime',
        error: error,
      );
    }
  }

  /// Fails the LibreChat requests still out at once, as the container's own
  /// dispose would, but before the services go.
  void _cutLibreChatRequests() {
    if (!container.read(libreChatHttpClientProvider.exists)) return;
    try {
      container.read(libreChatHttpClientProvider)?.close();
    } on Object catch (error) {
      DebugLogger.error(
        'librechat-client-close-failed',
        scope: 'daemon/runtime',
        error: error,
      );
    }
  }

  /// Stops the LibreChat engine's new work; completes once its running work
  /// has ended.
  Future<void> _closeLibreChatSync() {
    // Reading it when it is not there would start an engine.
    if (!container.read(libreChatSyncEngineProvider.exists)) {
      return Future<void>.value();
    }
    try {
      return container.read(libreChatSyncEngineProvider)?.close() ??
          Future<void>.value();
    } on Object catch (error) {
      DebugLogger.error(
        'librechat-sync-close-failed',
        scope: 'daemon/runtime',
        error: error,
      );
      return Future<void>.value();
    }
  }

  static Future<void> _pullAfterCertification(
    ProviderContainer container,
  ) async {
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
}

/// What keeps a signed-in session running with no widget tree to hold it:
/// the account's storage, its socket, Open WebUI's direct-connection relay,
/// the duplicate-account reconciler, the API client and the database, and
/// the outbox drain when the connection comes back. Mobile's widgets and
/// sync triggers do these; a host without them calls this once, on its
/// root container.
void holdCoreSession(ProviderContainer container) {
  // Until this notifier certifies the signed-in account against the
  // on-disk owner marker, `appDatabaseProvider` yields null -- and with no
  // database there is no conversation list, no offline history and no sync,
  // because every one of those reads it. Nothing else here would ever
  // construct it.
  container.read(openWebUiAccountStorageIsolationProvider);

  // The Socket.IO connection, held open for the host's lifetime.
  //
  // The manager is lazy and nothing else here reads it. Without it, turns
  // go out as plain HTTP streams, which is enough for text but not for
  // anything the server starts: a tool asking for approval, a function
  // asking the user a question, a title arriving after the answer. All of
  // those are socket event calls. A listener rather than a `read`, because
  // the manager rebuilds on every sign-in and server switch, and a read
  // would keep only the first.
  container.listen(socketServiceManagerProvider, (_, _) {});

  // Open WebUI's own direct connections: when a chat uses one, the server
  // asks the client, over the socket, to make the request. The core's
  // relay answers; mobile keeps it for the whole session, and so does this.
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
  // The session's API client, held for as long as the host runs, as
  // mobile's UI holds it. Several core paths check "is this still the
  // session I started with" by the client's identity; unheld, the provider
  // was rebuilt between two reads and every such check failed -- creating a
  // note came back as "the session changed".
  container.listen<Object?>(apiServiceProvider, (_, _) {});
  // The same for the account's database, which the same checks compare:
  // read cold, the first answer and the next could differ.
  container.listen<Object?>(appDatabaseProvider, (_, _) {});
  // The connection coming back sends what the outbox holds: a message sent
  // while the server was out of reach, and the chat's changes before it. On
  // mobile `syncTriggers` does this; this host does not run those triggers
  // (they also pull on a timer and on app lifecycle), so it takes this one
  // alone. Nothing else drains the outbox then: an op that failed as the
  // connection went would wait for the next send.
  container.listen<bool>(isOnlineProvider, (previous, next) {
    if (previous == false && next) unawaited(_drainAfterReconnect(container));
  });
}

Future<void> _drainAfterReconnect(ProviderContainer container) async {
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
