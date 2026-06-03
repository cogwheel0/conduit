import 'dart:io';

import 'package:path/path.dart' as path;

import '../utils/debug_logger.dart';

const _shareStagingDirectories = {'shared-incoming', 'shared-intents'};
final _uuidPrefixedFileName = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}-',
);

bool isShareStagingPath(String filePath) {
  final normalized = path.normalize(filePath);
  final parts = path.split(normalized);
  return parts.any(_shareStagingDirectories.contains) &&
      _uuidPrefixedFileName.hasMatch(path.basename(normalized));
}

Future<void> deleteShareStagingFile(String filePath) async {
  if (!isShareStagingPath(filePath)) return;

  try {
    final type = await FileSystemEntity.type(filePath, followLinks: false);
    if (type != FileSystemEntityType.file) return;

    await File(filePath).delete();
  } catch (error) {
    DebugLogger.log(
      'ShareReceiver: failed to delete staged file: $error',
      scope: 'share',
      data: {'path': filePath},
    );
  }
}
