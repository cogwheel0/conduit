import 'dart:io';

/// Where the core may write.
///
/// The Flutter app asks `path_provider`; another host can hand the core a data
/// directory and lay out subdirectories beneath it. Neither answer belongs
/// in a cache manager or a log rotator.
abstract interface class PathsPort {
  /// Durable, user-private storage. Backed up on mobile; the database and the
  /// secure store live here.
  Future<Directory> applicationSupport();

  /// Disposable storage. The OS may delete it at any time, so nothing here
  /// may be the only copy of anything.
  Future<Directory> cache();

  /// Rotating diagnostics, zipped by "Export diagnostics".
  Future<Directory> logs();

  /// Scratch space for in-flight uploads and exports.
  Future<Directory> staging();
}
