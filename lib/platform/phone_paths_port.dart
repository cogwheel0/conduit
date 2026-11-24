import 'dart:io';

import 'package:conduit_core/ports/paths_port.dart';
import 'package:path_provider/path_provider.dart';

/// The app's own directories, for the protocol services it hosts: the same
/// ones the app's screens use, so what they read and write is the same files.
///
/// Nothing here creates a directory.
final class PhonePathsPort implements PathsPort {
  const PhonePathsPort();

  @override
  Future<Directory> applicationSupport() => getApplicationSupportDirectory();

  /// Where the app's recorder leaves its files: a note's recording waiting to
  /// upload is found here (`createNoteAudioUploadStore`).
  @override
  Future<Directory> cache() => getTemporaryDirectory();

  @override
  Future<Directory> logs() async =>
      Directory('${(await getApplicationSupportDirectory()).path}/logs');

  @override
  Future<Directory> staging() async =>
      Directory('${(await getTemporaryDirectory()).path}/protocol-staging');
}
