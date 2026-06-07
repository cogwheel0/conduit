import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../utils/debug_logger.dart';

const shareStagingDirectoryName = 'conduit-shared-intents';
const _shareStagingDirectories = {
  'shared-incoming',
  'shared-intents',
  shareStagingDirectoryName,
};
final _uuidPrefixedFileName = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}-',
);
const _uuid = Uuid();

bool isShareStagingPath(String filePath) {
  final normalized = path.normalize(filePath);
  final parts = path.split(normalized);
  final baseName = path.basename(normalized);

  if (parts.any(_shareStagingDirectories.contains) &&
      _uuidPrefixedFileName.hasMatch(baseName)) {
    return true;
  }

  return false;
}

Future<File> stageIncomingSharedFile(String filePath) async {
  final normalized = path.normalize(filePath);
  if (isShareStagingPath(normalized)) {
    return File(normalized);
  }

  final source = File(normalized);
  final stagingDirectory = Directory(
    path.join(Directory.systemTemp.path, shareStagingDirectoryName),
  );
  await stagingDirectory.create(recursive: true);

  final destination = File(
    path.join(
      stagingDirectory.path,
      '${_uuid.v4()}-${_safeStagingFileName(path.basename(normalized))}',
    ),
  );
  await source.copy(destination.path);
  await _deletePluginCacheRootFileIfSafe(normalized);
  return destination;
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

Future<void> deleteIgnoredShareSidecarFile(String filePath) async {
  if (isShareStagingPath(filePath)) {
    await deleteShareStagingFile(filePath);
    return;
  }

  await _deletePluginCacheRootFileIfSafe(filePath);
}

String _safeStagingFileName(String fileName) {
  final trimmed = fileName.trim();
  final safeName = trimmed.isEmpty ? 'shared-file' : trimmed;
  return safeName.replaceAll(RegExp(r'[/\\:?%*|"<>]|[\x00-\x1F]'), '-');
}

Future<void> _deletePluginCacheRootFileIfSafe(String filePath) async {
  final normalized = path.normalize(filePath);
  final tempPath = path.normalize(Directory.systemTemp.path);
  if (!path.equals(path.dirname(normalized), tempPath)) {
    return;
  }

  try {
    final type = await FileSystemEntity.type(normalized, followLinks: false);
    if (type == FileSystemEntityType.file) {
      await File(normalized).delete();
    }
  } catch (error) {
    DebugLogger.log(
      'ShareReceiver: failed to delete plugin cache file: $error',
      scope: 'share',
      data: {'path': filePath},
    );
  }
}
