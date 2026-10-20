import 'dart:io';

/// Where the OS share extension leaves incoming files.
///
/// On iOS a share-sheet hand-off writes into a container the extension and
/// the app both see, and only the native side can say where that is. Every
/// other host either receives shared files somewhere the core already knows
/// about, or has no share sheet at all.
///
/// Narrow on purpose: this asks for a path, not for the staging logic.
/// Classifying, adopting and cleaning up what lands there is ordinary
/// `dart:io` work and stays in the core, where it is tested.
abstract interface class ShareStagingPort {
  /// The share extension's staging directory, or null when this host has
  /// none.
  ///
  /// Null means "no native share extension", which is a normal answer and
  /// not an error. A host that has one but cannot produce the path should
  /// throw instead, so a misconfigured container is not silently mistaken
  /// for a platform that never had one.
  Future<Directory?> nativeStagingRoot();

  /// The host's implementation, installed once at startup.
  static ShareStagingPort hostDefault = const NoNativeShareStaging();
}

/// Reports no native staging directory.
class NoNativeShareStaging implements ShareStagingPort {
  const NoNativeShareStaging();

  @override
  Future<Directory?> nativeStagingRoot() async => null;
}
