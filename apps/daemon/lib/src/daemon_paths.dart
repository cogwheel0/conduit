import 'dart:io';

import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:path/path.dart' as p;

/// Resolves and creates the directories the daemon owns beneath Electron's
/// `userData`.
///
/// Electron picks `userData` (it is OS-correct and respects portable builds),
/// so the daemon never guesses a location — it only lays out subdirectories
/// inside whatever it was handed.
class DaemonDirectories implements PathsPort {
  DaemonDirectories._(this.paths);

  final DaemonPaths paths;

  // PathsPort. The core asks for these by role; the daemon already
  // resolved them from Electron's userData at startup, so each is a lookup
  // rather than a probe.
  @override
  Future<Directory> applicationSupport() async => Directory(paths.userData);

  @override
  Future<Directory> cache() async => Directory(paths.cache);

  @override
  Future<Directory> logs() async => Directory(paths.logs);

  @override
  Future<Directory> staging() async => Directory(paths.staging);

  /// Creates every directory if missing and returns the resolved layout.
  static DaemonDirectories create(String userDataDir) {
    final root = p.normalize(p.absolute(userDataDir));
    final layout = DaemonPaths(
      userData: root,
      database: p.join(root, 'db'),
      cache: p.join(root, 'cache'),
      logs: p.join(root, 'logs'),
      staging: p.join(root, 'staging'),
    );
    for (final dir in <String>[
      layout.userData,
      layout.database,
      layout.cache,
      layout.logs,
      layout.staging,
    ]) {
      Directory(dir).createSync(recursive: true);
    }
    return DaemonDirectories._(layout);
  }
}
