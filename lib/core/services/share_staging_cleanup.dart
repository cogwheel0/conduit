import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../utils/debug_logger.dart';

const shareStagingDirectoryName = 'conduit-shared-intents';
const _shareReceiverChannelName = 'conduit/share_receiver_text';
const _shareReceiverChannel = MethodChannel(_shareReceiverChannelName);
const _ownedTemporaryStagingDirectories = {
  shareStagingDirectoryName,
  'conduit-native-paste',
  'conduit-app-intents',
};
final _uuidPrefixedFileName = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}-',
);
final _convertedUploadDirectoryName = RegExp(r'^conduit_img_[A-Za-z0-9_-]+$');
const _convertedUploadFileName = 'converted.jpg';
const _uuid = Uuid();
Directory? _cachedNativeShareStagingRoot;

typedef StagingFileDelete = Future<void> Function(File file);
typedef StagingDirectoryDelete = Future<void> Function(Directory directory);
typedef StagingFileDeletePreAdmission = Future<void> Function(File file);
typedef StagingFileDeleteAdmission = bool Function(File file);
typedef TerminalAttachmentCleanup = Future<bool> Function(String filePath);
typedef NativeShareStagingRootResolver = Future<Directory?> Function();
typedef IncomingSharedFileStageResult = ({File file, bool copied});

/// Opaque, one-use authority to unlink one exact plugin-emitted source.
final class IncomingSharedSourceDeletionLease {
  IncomingSharedSourceDeletionLease._({
    required this.sourcePath,
    required this.trustedRoot,
    required this.resolvedSourcePath,
    required this.snapshot,
  });

  final String sourcePath;
  final Directory trustedRoot;
  final String resolvedSourcePath;
  final FileStat snapshot;
  bool _consumed = false;
}

enum ShareStagingFileCleanupResult { notOwned, removed, failed }

/// Whether a path is definitely owned by Conduit's staging pipeline.
///
/// [indeterminate] is deliberately distinct from [notOwned]. In particular,
/// an iOS App Group lookup can fail while the referenced file is still owned;
/// terminal queue rows must survive that uncertainty so cleanup can retry.
enum ShareStagingPathOwnership { notOwned, owned, indeterminate }

typedef _ShareStagingPathResolution = ({
  ShareStagingPathOwnership ownership,
  String? path,
});

/// Whether [filePath] is an app-owned, regular staging file directly inside
/// one of Conduit's exact temporary staging roots.
///
/// This deliberately resolves symbolic links. A UUID-looking name or a
/// matching directory component elsewhere on disk is not proof of ownership.
Future<bool> isShareStagingPath(
  String filePath, {
  Iterable<Directory> additionalTrustedRoots = const <Directory>[],
  NativeShareStagingRootResolver? nativeStagingRootResolver,
}) async {
  return await _resolveOwnedStagingFile(
        filePath,
        additionalTrustedRoots: additionalTrustedRoots,
        nativeStagingRootResolver: nativeStagingRootResolver,
      ) !=
      null;
}

Future<ShareStagingPathOwnership> classifyShareStagingPath(
  String filePath, {
  Iterable<Directory> additionalTrustedRoots = const <Directory>[],
  NativeShareStagingRootResolver? nativeStagingRootResolver,
}) async {
  final resolution = await _resolveOwnedStagingFileWithStatus(
    filePath,
    additionalTrustedRoots: additionalTrustedRoots,
    nativeStagingRootResolver: nativeStagingRootResolver,
  );
  return resolution.ownership;
}

Future<bool> isAppIntentStagingPath(String filePath) async {
  return await resolveAppIntentStagingFile(filePath) != null;
}

Future<File?> resolveAppIntentStagingFile(String filePath) async {
  final resolved = await _resolveOwnedStagingFile(
    filePath,
    allowedDirectoryNames: const {'conduit-app-intents'},
  );
  return resolved == null ? null : File(resolved);
}

Future<File> stageIncomingSharedFile(
  String filePath, {
  Iterable<Directory> additionalTrustedRoots = const <Directory>[],
  NativeShareStagingRootResolver? nativeStagingRootResolver,
}) async {
  final result = await stageIncomingSharedFileWithResult(
    filePath,
    additionalTrustedRoots: additionalTrustedRoots,
    nativeStagingRootResolver: nativeStagingRootResolver,
  );
  return result.file;
}

/// Stages an incoming file and reports whether this call created a new copy.
///
/// Transactional callers can defer [deletePluginSourceAfterCopy] until after
/// publishing ownership of every staged attachment. That keeps the original
/// retryable if a later file in the same payload fails to stage.
Future<IncomingSharedFileStageResult> stageIncomingSharedFileWithResult(
  String filePath, {
  Iterable<Directory> additionalTrustedRoots = const <Directory>[],
  NativeShareStagingRootResolver? nativeStagingRootResolver,
  bool deletePluginSourceAfterCopy = true,
}) async {
  final normalized = path.normalize(filePath);
  final resolution = await _resolveOwnedStagingFileWithStatus(
    normalized,
    additionalTrustedRoots: additionalTrustedRoots,
    nativeStagingRootResolver: nativeStagingRootResolver,
  );
  switch (resolution.ownership) {
    case ShareStagingPathOwnership.owned:
      return (file: File(resolution.path!), copied: false);
    case ShareStagingPathOwnership.indeterminate:
      throw const FileSystemException(
        'Share staging ownership could not be determined',
      );
    case ShareStagingPathOwnership.notOwned:
      break;
  }

  final source = File(normalized);
  final stagingDirectory = await _ensureOwnedTemporaryStagingDirectory(
    shareStagingDirectoryName,
  );

  final destination = File(
    path.join(
      stagingDirectory.path,
      '${_uuid.v4()}-${_safeStagingFileName(path.basename(normalized))}',
    ),
  );
  try {
    await source.copy(destination.path);
  } catch (error, stackTrace) {
    // `File.copy` may leave a partial destination. Transactional callers do
    // not receive the path when it throws, so clean it up here.
    try {
      if (await destination.exists()) {
        await destination.delete();
      }
    } catch (cleanupError) {
      DebugLogger.warning(
        'partial-share-stage-cleanup-failed',
        scope: 'share/cleanup',
        data: {'errorType': cleanupError.runtimeType.toString()},
      );
    }
    Error.throwWithStackTrace(error, stackTrace);
  }
  if (deletePluginSourceAfterCopy) {
    await _deletePluginCacheRootFileIfSafe(normalized);
  }
  return (file: destination, copied: true);
}

/// Issues a one-use deletion lease after resolving a regular direct child of a
/// root that the caller has already established as plugin-owned.
Future<IncomingSharedSourceDeletionLease?>
createIncomingSharedSourceDeletionLease(
  String pluginEmittedSourcePath, {
  required Directory trustedPluginRoot,
}) async {
  final normalized = path.normalize(path.absolute(pluginEmittedSourcePath));
  final resolved = await _resolveRegularFileDirectlyUnderRoot(
    normalized,
    trustedPluginRoot,
  );
  if (resolved == null) return null;
  final snapshot = await File(resolved).stat();
  if (snapshot.type != FileSystemEntityType.file) return null;
  return IncomingSharedSourceDeletionLease._(
    sourcePath: normalized,
    trustedRoot: trustedPluginRoot,
    resolvedSourcePath: resolved,
    snapshot: snapshot,
  );
}

/// Deletes only through an unconsumed, exact-source plugin ownership lease.
/// Passing a path (the legacy generic call shape) deliberately remains a no-op.
Future<bool> deleteIncomingSharedSourceIfSafe(
  Object sourceAuthority, {
  StagingFileDelete? deleteFile,
}) async {
  if (sourceAuthority is! IncomingSharedSourceDeletionLease ||
      sourceAuthority._consumed) {
    return false;
  }
  sourceAuthority._consumed = true;
  final sourcePath = sourceAuthority.sourcePath;
  try {
    final type = await FileSystemEntity.type(sourcePath, followLinks: false);
    if (type == FileSystemEntityType.notFound) return true;
    if (type != FileSystemEntityType.file) return false;
    final resolved = await _resolveRegularFileDirectlyUnderRoot(
      sourcePath,
      sourceAuthority.trustedRoot,
    );
    if (resolved == null ||
        !path.equals(resolved, sourceAuthority.resolvedSourcePath)) {
      return false;
    }

    final current = await File(sourcePath).stat();
    if (!_sameIncomingSourceSnapshot(current, sourceAuthority.snapshot)) {
      return false;
    }
    final file = File(sourcePath);
    if (deleteFile != null) {
      await deleteFile(file);
    } else {
      // No await between this final non-link/snapshot admission and unlink.
      final finalType = FileSystemEntity.typeSync(
        sourcePath,
        followLinks: false,
      );
      final finalStat = file.statSync();
      if (finalType != FileSystemEntityType.file ||
          !_sameIncomingSourceSnapshot(finalStat, sourceAuthority.snapshot)) {
        return false;
      }
      file.deleteSync();
    }
  } catch (_) {
    // Recheck for platform APIs that throw after completing the unlink.
  }
  try {
    return await FileSystemEntity.type(sourcePath, followLinks: false) ==
        FileSystemEntityType.notFound;
  } on FileSystemException {
    return false;
  }
}

bool _sameIncomingSourceSnapshot(FileStat first, FileStat second) {
  return first.type == second.type &&
      first.size == second.size &&
      first.mode == second.mode &&
      first.modified == second.modified &&
      first.changed == second.changed;
}

Future<void> deleteShareStagingFile(
  String filePath, {
  Iterable<Directory> additionalTrustedRoots = const <Directory>[],
  NativeShareStagingRootResolver? nativeStagingRootResolver,
  StagingFileDeletePreAdmission? beforeDeleteAdmission,
  StagingFileDeleteAdmission? canDelete,
}) async {
  await deleteShareStagingFileWithResult(
    filePath,
    additionalTrustedRoots: additionalTrustedRoots,
    nativeStagingRootResolver: nativeStagingRootResolver,
    beforeDeleteAdmission: beforeDeleteAdmission,
    canDelete: canDelete,
  );
}

/// Deletes an owned staging file and reports whether its durable reference can
/// safely be discarded.
///
/// Deletion errors are followed by an on-disk recheck: a platform API may throw
/// after completing the unlink, while a file that remains must keep its queue
/// row so cleanup can be retried on a later launch.
Future<ShareStagingFileCleanupResult> deleteShareStagingFileWithResult(
  String filePath, {
  Iterable<Directory> additionalTrustedRoots = const <Directory>[],
  StagingFileDelete? deleteFile,
  NativeShareStagingRootResolver? nativeStagingRootResolver,
  StagingFileDeletePreAdmission? beforeDeleteAdmission,
  StagingFileDeleteAdmission? canDelete,
}) async {
  final resolution = await _resolveOwnedStagingFileWithStatus(
    filePath,
    additionalTrustedRoots: additionalTrustedRoots,
    nativeStagingRootResolver: nativeStagingRootResolver,
  );
  switch (resolution.ownership) {
    case ShareStagingPathOwnership.notOwned:
      return ShareStagingFileCleanupResult.notOwned;
    case ShareStagingPathOwnership.indeterminate:
      DebugLogger.warning(
        'staging-file-ownership-resolution-incomplete',
        scope: 'share/cleanup',
      );
      return ShareStagingFileCleanupResult.failed;
    case ShareStagingPathOwnership.owned:
      break;
  }
  final ownedPath = resolution.path!;

  Object? deleteError;
  try {
    final type = await FileSystemEntity.type(ownedPath, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return ShareStagingFileCleanupResult.removed;
    }
    if (type != FileSystemEntityType.file) {
      return ShareStagingFileCleanupResult.failed;
    }

    final ownedFile = File(ownedPath);
    if (beforeDeleteAdmission != null) {
      await beforeDeleteAdmission(ownedFile);
    }
    if (canDelete != null && !canDelete(ownedFile)) {
      // A newer generation now owns this exact pathname. The retired caller's
      // durable reference is safe to discard even though the replacement file
      // deliberately remains on disk.
      return ShareStagingFileCleanupResult.removed;
    }
    if (deleteFile != null) {
      await deleteFile(ownedFile);
    } else {
      // No await is permitted between the final generation admission above
      // and the pathname unlink: an async dispatch could otherwise run after
      // a replacement generation re-stages different bytes at the same path.
      ownedFile.deleteSync();
    }
  } catch (error) {
    deleteError = error;
  }

  final FileSystemEntityType remainingType;
  try {
    remainingType = await FileSystemEntity.type(ownedPath, followLinks: false);
  } on FileSystemException catch (error) {
    DebugLogger.warning(
      'staged-file-delete-recheck-failed',
      scope: 'share/cleanup',
      data: {'errorType': error.runtimeType.toString()},
    );
    return ShareStagingFileCleanupResult.failed;
  }
  if (remainingType == FileSystemEntityType.notFound) {
    return ShareStagingFileCleanupResult.removed;
  }

  DebugLogger.warning(
    'staged-file-delete-incomplete',
    scope: 'share/cleanup',
    data: {
      if (deleteError != null) 'errorType': deleteError.runtimeType.toString(),
    },
  );
  return ShareStagingFileCleanupResult.failed;
}

/// Cleans a terminal attachment path owned by Conduit's upload pipeline.
///
/// Besides the UUID staging roots, image conversion creates a dedicated
/// `conduit_img_*/converted.jpg` directory. Restored terminal queue rows can
/// point directly at that conversion file, so the directory must be removed
/// before the durable row is pruned. Unrelated paths are never deleted and are
/// safe for the queue to forget.
Future<bool> cleanupTerminalAttachmentFile(
  String filePath, {
  Iterable<Directory> additionalTrustedRoots = const <Directory>[],
  StagingFileDelete? deleteFile,
  StagingDirectoryDelete? deleteDirectory,
  NativeShareStagingRootResolver? nativeStagingRootResolver,
  StagingFileDeletePreAdmission? beforeDeleteAdmission,
  StagingFileDeleteAdmission? canDelete,
}) async {
  final stagingResult = await deleteShareStagingFileWithResult(
    filePath,
    additionalTrustedRoots: additionalTrustedRoots,
    deleteFile: deleteFile,
    nativeStagingRootResolver: nativeStagingRootResolver,
    beforeDeleteAdmission: beforeDeleteAdmission,
    canDelete: canDelete,
  );
  switch (stagingResult) {
    case ShareStagingFileCleanupResult.removed:
      return true;
    case ShareStagingFileCleanupResult.failed:
      return false;
    case ShareStagingFileCleanupResult.notOwned:
      return _deleteConvertedUploadDirectory(
        filePath,
        deleteFile: deleteFile,
        deleteDirectory: deleteDirectory,
        beforeDeleteAdmission: beforeDeleteAdmission,
        canDelete: canDelete,
      );
  }
}

/// Resolves an upload-conversion artifact only when it is the exact regular
/// `converted.jpg` file inside a resolved, direct `conduit_img_*` child of the
/// system temporary directory. Links and lookalike directory trees are
/// rejected.
Future<File?> resolveConvertedUploadFile(String filePath) async {
  final normalized = path.normalize(path.absolute(filePath));
  if (path.basename(normalized) != _convertedUploadFileName) return null;

  final parentPath = path.dirname(normalized);
  if (!_convertedUploadDirectoryName.hasMatch(path.basename(parentPath))) {
    return null;
  }
  final systemTempPath = path.normalize(
    path.absolute(Directory.systemTemp.path),
  );
  if (!path.equals(path.dirname(parentPath), systemTempPath)) return null;

  final resolved = await _resolveRegularFileDirectlyUnderRoot(
    normalized,
    Directory(parentPath),
    requireRootDirectlyUnderSystemTemp: true,
  );
  if (resolved == null || path.basename(resolved) != _convertedUploadFileName) {
    return null;
  }
  return File(resolved);
}

Future<bool> _deleteConvertedUploadDirectory(
  String filePath, {
  StagingFileDelete? deleteFile,
  StagingDirectoryDelete? deleteDirectory,
  StagingFileDeletePreAdmission? beforeDeleteAdmission,
  StagingFileDeleteAdmission? canDelete,
}) async {
  final normalized = path.normalize(path.absolute(filePath));
  if (path.basename(normalized) != _convertedUploadFileName) return true;

  final parentPath = path.dirname(normalized);
  if (!_convertedUploadDirectoryName.hasMatch(path.basename(parentPath))) {
    return true;
  }
  final systemTempPath = path.normalize(
    path.absolute(Directory.systemTemp.path),
  );
  if (!path.equals(path.dirname(parentPath), systemTempPath)) return true;

  try {
    final resolvedSystemTemp = path.normalize(
      await Directory.systemTemp.resolveSymbolicLinks(),
    );
    final parentType = await FileSystemEntity.type(
      parentPath,
      followLinks: false,
    );
    if (parentType == FileSystemEntityType.notFound) return true;
    if (parentType != FileSystemEntityType.directory) return false;

    final parent = Directory(parentPath);
    final resolvedParent = path.normalize(await parent.resolveSymbolicLinks());
    if (!path.equals(path.dirname(resolvedParent), resolvedSystemTemp) ||
        !_convertedUploadDirectoryName.hasMatch(
          path.basename(resolvedParent),
        )) {
      return false;
    }

    final candidate = File(normalized);
    final candidateType = await FileSystemEntity.type(
      normalized,
      followLinks: false,
    );
    if (candidateType != FileSystemEntityType.notFound &&
        candidateType != FileSystemEntityType.file) {
      return false;
    }
    if (candidateType == FileSystemEntityType.file) {
      final resolvedCandidate = path.normalize(
        await candidate.resolveSymbolicLinks(),
      );
      if (!path.equals(path.dirname(resolvedCandidate), resolvedParent)) {
        return false;
      }
      if (beforeDeleteAdmission != null) {
        await beforeDeleteAdmission(candidate);
      }
      if (canDelete != null && !canDelete(candidate)) return true;
      try {
        if (deleteFile != null) {
          await deleteFile(candidate);
        } else {
          candidate.deleteSync();
        }
      } catch (_) {
        // Recheck below: some platform implementations throw after unlinking.
      }
      if (await FileSystemEntity.type(normalized, followLinks: false) !=
          FileSystemEntityType.notFound) {
        return false;
      }
    }

    try {
      if (beforeDeleteAdmission != null) {
        await beforeDeleteAdmission(candidate);
      }
      if (canDelete != null && !canDelete(candidate)) return true;
      if (deleteDirectory != null) {
        await deleteDirectory(parent);
      } else {
        parent.deleteSync();
      }
    } catch (_) {
      // Recheck below for the same throw-after-delete behavior.
    }
    final removed =
        await FileSystemEntity.type(parentPath, followLinks: false) ==
        FileSystemEntityType.notFound;
    if (!removed) {
      DebugLogger.warning(
        'converted-upload-directory-delete-incomplete',
        scope: 'share/cleanup',
      );
    }
    return removed;
  } on FileSystemException catch (error) {
    DebugLogger.warning(
      'converted-upload-cleanup-failed',
      scope: 'share/cleanup',
      data: {'errorType': error.runtimeType.toString()},
    );
    return false;
  }
}

Future<void> deleteIgnoredShareSidecarFile(
  String filePath, {
  Iterable<Directory> additionalTrustedRoots = const <Directory>[],
  NativeShareStagingRootResolver? nativeStagingRootResolver,
}) async {
  final stagingResult = await deleteShareStagingFileWithResult(
    filePath,
    additionalTrustedRoots: additionalTrustedRoots,
    nativeStagingRootResolver: nativeStagingRootResolver,
  );
  switch (stagingResult) {
    case ShareStagingFileCleanupResult.removed:
    case ShareStagingFileCleanupResult.failed:
      return;
    case ShareStagingFileCleanupResult.notOwned:
      break;
  }

  // Unknown sidecars may be caller-owned. Retain them unless the exact Conduit
  // staging check above proved ownership.
}

String _safeStagingFileName(String fileName) {
  final trimmed = fileName.trim();
  final safeName = trimmed.isEmpty ? 'shared-file' : trimmed;
  return safeName.replaceAll(RegExp(r'[/\\:?%*|"<>]|[\x00-\x1F]'), '-');
}

Future<void> _deletePluginCacheRootFileIfSafe(String filePath) async {
  try {
    final removed = await deleteIncomingSharedSourceIfSafe(filePath);
    if (!removed) {
      DebugLogger.log(
        'ShareReceiver: plugin cache file cleanup deferred',
        scope: 'share/cleanup',
      );
    }
  } catch (error) {
    DebugLogger.log(
      'ShareReceiver: failed to delete plugin cache file',
      scope: 'share/cleanup',
      data: {'errorType': error.runtimeType.toString()},
    );
  }
}

Future<String?> _resolveOwnedStagingFile(
  String filePath, {
  Set<String> allowedDirectoryNames = _ownedTemporaryStagingDirectories,
  Iterable<Directory> additionalTrustedRoots = const <Directory>[],
  NativeShareStagingRootResolver? nativeStagingRootResolver,
}) async {
  final resolution = await _resolveOwnedStagingFileWithStatus(
    filePath,
    allowedDirectoryNames: allowedDirectoryNames,
    additionalTrustedRoots: additionalTrustedRoots,
    nativeStagingRootResolver: nativeStagingRootResolver,
  );
  return resolution.ownership == ShareStagingPathOwnership.owned
      ? resolution.path
      : null;
}

Future<_ShareStagingPathResolution> _resolveOwnedStagingFileWithStatus(
  String filePath, {
  Set<String> allowedDirectoryNames = _ownedTemporaryStagingDirectories,
  Iterable<Directory> additionalTrustedRoots = const <Directory>[],
  NativeShareStagingRootResolver? nativeStagingRootResolver,
}) async {
  final baseName = path.basename(path.normalize(filePath));
  if (!_uuidPrefixedFileName.hasMatch(baseName)) {
    return (ownership: ShareStagingPathOwnership.notOwned, path: null);
  }

  var resolutionIndeterminate = false;
  for (final directoryName in _ownedTemporaryStagingDirectories) {
    if (!allowedDirectoryNames.contains(directoryName)) continue;
    final root = Directory(path.join(Directory.systemTemp.path, directoryName));
    final resolution = await _resolveRegularFileDirectlyUnderRootWithStatus(
      filePath,
      root,
      requireRootDirectlyUnderSystemTemp: true,
    );
    if (resolution.ownership == ShareStagingPathOwnership.owned) {
      return resolution;
    }
    if (resolution.ownership == ShareStagingPathOwnership.indeterminate) {
      resolutionIndeterminate = true;
    }
  }

  var nativeResolutionFailed = false;
  if (allowedDirectoryNames.contains(shareStagingDirectoryName)) {
    try {
      final nativeRoot =
          await (nativeStagingRootResolver ?? _nativeShareStagingRoot)();
      if (nativeRoot != null) {
        final resolution = await _resolveRegularFileDirectlyUnderRootWithStatus(
          filePath,
          nativeRoot,
        );
        if (resolution.ownership == ShareStagingPathOwnership.owned) {
          return resolution;
        }
        if (resolution.ownership == ShareStagingPathOwnership.indeterminate) {
          resolutionIndeterminate = true;
        }
      }
    } catch (_) {
      nativeResolutionFailed = true;
    }
  }

  for (final root in additionalTrustedRoots) {
    final rootName = path.basename(path.normalize(root.path));
    if (!allowedDirectoryNames.contains(rootName)) continue;
    final resolution = await _resolveRegularFileDirectlyUnderRootWithStatus(
      filePath,
      root,
    );
    if (resolution.ownership == ShareStagingPathOwnership.owned) {
      return resolution;
    }
    if (resolution.ownership == ShareStagingPathOwnership.indeterminate) {
      resolutionIndeterminate = true;
    }
  }
  return (
    ownership: nativeResolutionFailed || resolutionIndeterminate
        ? ShareStagingPathOwnership.indeterminate
        : ShareStagingPathOwnership.notOwned,
    path: null,
  );
}

Future<Directory?> _nativeShareStagingRoot() async {
  if (!Platform.isIOS) return null;
  final cached = _cachedNativeShareStagingRoot;
  if (cached != null) return cached;
  final rawPath = await _shareReceiverChannel.invokeMethod<String>(
    'shareStagingDirectoryPath',
  );
  if (rawPath == null || rawPath.trim().isEmpty) {
    throw const FileSystemException('Native share staging root unavailable');
  }
  final normalized = path.normalize(path.absolute(rawPath));
  if (path.basename(normalized) != shareStagingDirectoryName) {
    throw const FileSystemException('Native share staging root is invalid');
  }
  final root = Directory(normalized);
  if (await FileSystemEntity.type(root.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const FileSystemException('Native share staging root is not usable');
  }
  _cachedNativeShareStagingRoot = root;
  return root;
}

Future<String?> _resolveRegularFileDirectlyUnderRoot(
  String filePath,
  Directory root, {
  bool requireRootDirectlyUnderSystemTemp = false,
}) async {
  final resolution = await _resolveRegularFileDirectlyUnderRootWithStatus(
    filePath,
    root,
    requireRootDirectlyUnderSystemTemp: requireRootDirectlyUnderSystemTemp,
  );
  return resolution.ownership == ShareStagingPathOwnership.owned
      ? resolution.path
      : null;
}

Future<_ShareStagingPathResolution>
_resolveRegularFileDirectlyUnderRootWithStatus(
  String filePath,
  Directory root, {
  bool requireRootDirectlyUnderSystemTemp = false,
}) async {
  try {
    final normalized = path.normalize(path.absolute(filePath));
    final candidateType = await FileSystemEntity.type(
      normalized,
      followLinks: false,
    );
    // Reject a link even if its target happens to live under the allowed root.
    if (candidateType != FileSystemEntityType.file) {
      return (ownership: ShareStagingPathOwnership.notOwned, path: null);
    }

    final rootType = await FileSystemEntity.type(root.path, followLinks: false);
    if (rootType != FileSystemEntityType.directory) {
      return (ownership: ShareStagingPathOwnership.notOwned, path: null);
    }

    final resolvedRoot = path.normalize(await root.resolveSymbolicLinks());
    if (requireRootDirectlyUnderSystemTemp) {
      final resolvedSystemTemp = path.normalize(
        await Directory.systemTemp.resolveSymbolicLinks(),
      );
      if (!path.equals(path.dirname(resolvedRoot), resolvedSystemTemp)) {
        return (ownership: ShareStagingPathOwnership.notOwned, path: null);
      }
    }

    final resolvedCandidate = path.normalize(
      await File(normalized).resolveSymbolicLinks(),
    );
    if (!path.equals(path.dirname(resolvedCandidate), resolvedRoot)) {
      return (ownership: ShareStagingPathOwnership.notOwned, path: null);
    }
    return (
      ownership: ShareStagingPathOwnership.owned,
      path: resolvedCandidate,
    );
  } on FileSystemException {
    return (ownership: ShareStagingPathOwnership.indeterminate, path: null);
  }
}

Future<Directory> _ensureOwnedTemporaryStagingDirectory(
  String directoryName,
) async {
  final directory = Directory(
    path.join(Directory.systemTemp.path, directoryName),
  );
  final initialType = await FileSystemEntity.type(
    directory.path,
    followLinks: false,
  );
  if (initialType == FileSystemEntityType.link ||
      (initialType != FileSystemEntityType.notFound &&
          initialType != FileSystemEntityType.directory)) {
    throw const FileSystemException('Unsafe share staging directory');
  }
  if (initialType == FileSystemEntityType.notFound) {
    await directory.create();
  }

  final finalType = await FileSystemEntity.type(
    directory.path,
    followLinks: false,
  );
  if (finalType != FileSystemEntityType.directory) {
    throw const FileSystemException('Unsafe share staging directory');
  }

  final resolvedDirectory = path.normalize(
    await directory.resolveSymbolicLinks(),
  );
  final resolvedSystemTemp = path.normalize(
    await Directory.systemTemp.resolveSymbolicLinks(),
  );
  if (!path.equals(path.dirname(resolvedDirectory), resolvedSystemTemp) ||
      path.basename(resolvedDirectory) != directoryName) {
    throw const FileSystemException('Unsafe share staging directory');
  }
  return Directory(resolvedDirectory);
}
