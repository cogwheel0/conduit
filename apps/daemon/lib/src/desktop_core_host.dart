import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/persistence/hive_boxes.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/services/settings_service.dart'
    show AppSettingsHostDefaults;
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as p;

import 'bootstrap.dart';
import 'core_runtime.dart';
import 'daemon_paths.dart';
import 'ports/connectivity.dart';
import 'ports/database_opener.dart';
import 'ports/key_value_store.dart';
import 'ports/secure_store.dart';
import 'ports/worker.dart';

/// What the desktop decides about the core.
const CoreHostPolicy desktopCorePolicy = CoreHostPolicy(
  // A Mac always has a hardware keyboard: Enter sends until the user turns
  // Send with Enter off (mobile's default stays off). A Mac app asks for
  // notification permission the first time one would show, so
  // notifications start on (the phone asks when they are turned on, so its
  // default stays off).
  settingsDefaults: AppSettingsHostDefaults(
    sendOnEnter: true,
    notificationsEnabled: true,
  ),
  // The Mac's voices read aloud live, reporting each word, and the reading
  // moves from sentence to sentence (the phone renders clips).
  readAloudLiveDeviceSpeech: true,
  // This build has no entitlement for it.
  offerPrivateCloudCompute: false,
);

/// The desktop's stores, under the user data directory the app chose: a
/// secure store keyed by the bootstrap's master key, `preferences.json`,
/// Hive, the account databases, and connectivity that polls the network
/// interfaces and takes the window's reports.
///
/// The lifecycle and the schedulers keep the core's defaults: a headless
/// sidecar has no lifecycle of its own, and `resumed` is the truth since it
/// only runs while the desktop app does; there is no frame to align work
/// with, so microtasks are the correct degenerate case.
Future<CoreHostBindings> openDesktopCoreHost({
  required BootstrapConfig config,
  required DaemonDirectories directories,
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
  return CoreHostBindings(
    secureStore: secureStore,
    hiveBoxes: boxes.value,
    databaseOpener: DaemonDatabaseOpener(directories),
    worker: const DaemonWorkerPort(),
    connectivity: connectivity,
    reportNetwork: connectivity.report,
    close: () async {
      await connectivity.dispose();
      for (final box in boxes.all) {
        await box.close();
      }
    },
  );
}

Future<({HiveBoxes value, List<Box<dynamic>> all})> _openHiveBoxes() async {
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
