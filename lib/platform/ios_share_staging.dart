import 'dart:io';

import 'package:conduit_core/conduit_core.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

/// The iOS [ShareStagingPort].
///
/// Asks the share-receiver channel where the extension's container is. The
/// validation is deliberately kept here with the channel: a path that comes
/// from outside the app is checked for shape and existence before anything
/// treats it as a directory to adopt files from.
class IosShareStaging implements ShareStagingPort {
  IosShareStaging({required this.stagingDirectoryName});

  static const MethodChannel _channel = MethodChannel(
    'conduit/share_receiver_text',
  );

  /// The directory name the native side is expected to hand back.
  final String stagingDirectoryName;

  Directory? _cached;

  @override
  Future<Directory?> nativeStagingRoot() async {
    if (!Platform.isIOS) return null;
    final cached = _cached;
    if (cached != null) return cached;

    final rawPath = await _channel.invokeMethod<String>(
      'shareStagingDirectoryPath',
    );
    if (rawPath == null || rawPath.trim().isEmpty) {
      throw const FileSystemException('Native share staging root unavailable');
    }
    final normalized = path.normalize(path.absolute(rawPath));
    if (path.basename(normalized) != stagingDirectoryName) {
      throw const FileSystemException('Native share staging root is invalid');
    }
    final root = Directory(normalized);
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FileSystemException(
        'Native share staging root is not usable',
      );
    }
    _cached = root;
    return root;
  }
}
