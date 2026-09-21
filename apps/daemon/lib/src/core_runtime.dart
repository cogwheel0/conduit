import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/persistence/hive_boxes.dart';
import 'package:conduit_core/persistence/persistence_providers.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/host_ports.dart';
import 'package:conduit_core/providers/storage_providers.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as p;
import 'package:riverpod/misc.dart' show Override;
import 'package:riverpod/riverpod.dart';

import 'bootstrap.dart';
import 'daemon_paths.dart';
import 'log.dart';
import 'ports/connectivity.dart';
import 'ports/database_opener.dart';
import 'ports/key_value_store.dart';
import 'ports/secure_store.dart';
import 'ports/worker.dart';

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
    required List<Box<dynamic>> boxes,
  }) : _connectivity = connectivity,
       _boxes = boxes;

  final ProviderContainer container;
  final DaemonDirectories directories;
  final DaemonConnectivity _connectivity;
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
  }) async {
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

    final container = ProviderContainer(
      overrides: <Override>[
        databaseOpenerProvider.overrideWithValue(
          DaemonDatabaseOpener(directories),
        ),
        workerPortProvider.overrideWithValue(const DaemonWorkerPort()),
        connectivityPortProvider.overrideWithValue(connectivity),
        secureStorageProvider.overrideWithValue(secureStore),
        hiveBoxesProvider.overrideWithValue(boxes.value),
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

    log.info('core runtime ready');
    return CoreRuntime._(
      container: container,
      directories: directories,
      connectivity: connectivity,
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
