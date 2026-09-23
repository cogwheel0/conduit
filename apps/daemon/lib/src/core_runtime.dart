import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/database/account_storage_isolation.dart';
import 'package:conduit_core/database/database_provider.dart'
    show appDatabaseProvider;
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart'
    show openWebUiDirectCompletionSocketRelayProvider;
import 'package:conduit_core/persistence/hive_boxes.dart';
import 'package:conduit_core/persistence/persistence_providers.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show apiServiceProvider, socketServiceManagerProvider;
import 'package:conduit_core/providers/host_ports.dart';
import 'package:conduit_core/providers/storage_providers.dart';
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:hive_ce/hive.dart';
import 'package:mcp_dart/mcp_dart.dart' as mcp;
import 'package:path/path.dart' as p;
import 'package:riverpod/misc.dart' show Override;
import 'package:riverpod/riverpod.dart';

import 'bootstrap.dart';
import 'daemon_paths.dart';
import 'log.dart';
import 'ports/connectivity.dart';
import 'ports/database_opener.dart';
import 'ports/key_value_store.dart';
import 'ports/open_url.dart';
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
    required List<Box<dynamic>> boxes,
  }) : _connectivity = connectivity,
       _boxes = boxes;

  final ProviderContainer container;
  final DaemonDirectories directories;
  final DaemonConnectivity _connectivity;

  /// How the core opens a page in the system browser; the server attaches
  /// its event bus once there is one.
  final DaemonOpenUrlPort openUrl;

  /// Takes a window's view of the network, which arrives as an event where
  /// the port can only poll.
  void reportNetwork({required bool online}) => _connectivity.report(online);
  final List<Box<dynamic>> _boxes;

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
        secureStorageProvider.overrideWithValue(secureStore),
        hiveBoxesProvider.overrideWithValue(boxes.value),
        // Mobile routes the post-certification catch-up through its sync
        // triggers, which also watch lifecycle and connectivity. The sidecar
        // has neither, so it asks the engine directly.
        hostPostCertificationSyncProvider.overrideWithValue(
          () => unawaited(_pullAfterCertification()),
        ),
        // The remaining ports keep the core's own defaults, and each is a
        // deliberate choice rather than an omission:
        //
        // * `appLifecycleProvider` -- a headless sidecar has no lifecycle of
        //   its own. Electron's window focus/blur arrives over RPC in a later
        //   work package; until then `resumed` is the truth, since the daemon
        //   only runs while Electron does.
        // * `flushScheduler` / `postFrameScheduler` -- both exist to align
        //   work with a Flutter frame. There is no frame here; the microtask
        //   defaults are the correct degenerate case.
        // * `clipboardPortProvider` -- the clipboard belongs to the
        //   renderer's process, not this one, so it crosses as RPC.
        // * `cookieJarProvider` -- filled in by WP-2.3, where Electron's auth
        //   windows are what actually hold cookies.
      ],
    );

    // Kept alive deliberately. Until this notifier certifies the signed-in
    // account against the on-disk owner marker, `appDatabaseProvider` yields
    // null -- and with no database there is no conversation list, no offline
    // history and no sync, because every one of those reads it. Nothing else
    // in the sidecar would ever construct it.
    container.read(openWebUiAccountStorageIsolationProvider);

    // The Socket.IO connection, held open for the daemon's lifetime (WP-3.6).
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
    // The session's API client, held for as long as the daemon runs, as
    // mobile's UI holds it. Several core paths check "is this still the
    // session I started with" by the client's identity; unheld, the
    // provider was rebuilt between two reads and every such check failed --
    // creating a note came back as "the session changed".
    container.listen<Object?>(apiServiceProvider, (_, _) {});
    // The same for the account's database, which the same checks compare:
    // read cold, the first answer and the next could differ.
    container.listen<Object?>(appDatabaseProvider, (_, _) {});
    log.info('core runtime ready');
    return CoreRuntime._(
      container: container,
      directories: directories,
      connectivity: connectivity,
      openUrl: openUrl,
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
