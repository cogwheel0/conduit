import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import '../../../core/utils/debug_logger.dart';
import 'file_attachment_service.dart';
import 'ios_native_paste_service.dart';

typedef PastedAttachmentUploader =
    Future<void> Function(LocalAttachment attachment, int fileSize);
typedef PastedAttachmentRollback =
    Future<void> Function(LocalAttachment attachment);

const int maxPastedImageBytes = 20 * 1024 * 1024;
const int _maxNativePasteBatchBytes = 60 * 1024 * 1024;
const int _maxNativePasteItemCount = 4;
const String _nativePasteStagingDirectoryName = 'conduit-native-paste';
const String _nativePasteMarkerPrefix = '.conduit-native-paste-v2-';

final class PreparedNativePasteAttachments {
  const PreparedNativePasteAttachments._({
    required this.deliveryId,
    required this.attachments,
    required this.itemPaths,
    required this.stagingDirectoryPath,
    required this.pendingMarkerPath,
    required this.dartOwnedMarkerPath,
    required this.reclaimingMarkerPath,
  });

  final String deliveryId;
  final List<LocalAttachment> attachments;
  final List<String> itemPaths;
  final String stagingDirectoryPath;
  final String pendingMarkerPath;
  final String dartOwnedMarkerPath;
  final String reclaimingMarkerPath;
}

/// Atomically transfers a pasted payload into composer ownership, validates
/// every staged file, then starts the independent uploads concurrently.
///
/// [addFiles] deliberately runs before the first `await`: native iOS uses that
/// synchronous mutation as its ownership boundary. A later validation failure
/// rolls the complete payload back so composer state and staged-file ownership
/// cannot diverge.
Future<void> acceptPastedAttachments({
  required List<LocalAttachment> attachments,
  required void Function(List<LocalAttachment>) addFiles,
  required PastedAttachmentUploader upload,
  required PastedAttachmentRollback rollback,
  required String logScope,
}) {
  if (attachments.isEmpty) return Future<void>.value();
  // Keep this function non-async through the ownership mutation. A synchronous
  // notifier failure must escape to the native dispatch lease instead of being
  // converted into an asynchronously completed error after the lease commits.
  addFiles(attachments);
  return _prepareAcceptedPastedAttachments(
    attachments: attachments,
    upload: upload,
    rollback: rollback,
    logScope: logScope,
  );
}

Future<void> _prepareAcceptedPastedAttachments({
  required List<LocalAttachment> attachments,
  required PastedAttachmentUploader upload,
  required PastedAttachmentRollback rollback,
  required String logScope,
}) async {
  final fileSizes = <LocalAttachment, int>{};
  try {
    for (final attachment in attachments) {
      final fileSize = await attachment.file.length();
      if (attachment.isImage && fileSize > maxPastedImageBytes) {
        throw FileSystemException(
          'Pasted image exceeds the 20 MB upload limit.',
          attachment.file.path,
        );
      }
      fileSizes[attachment] = fileSize;
    }
  } catch (error, stackTrace) {
    DebugLogger.error(
      'Pasted attachment preparation failed',
      scope: logScope,
      error: error,
      stackTrace: stackTrace,
    );
    for (final attachment in attachments) {
      try {
        await rollback(attachment);
      } catch (rollbackError, rollbackStackTrace) {
        DebugLogger.error(
          'Pasted attachment rollback failed',
          scope: logScope,
          error: rollbackError,
          stackTrace: rollbackStackTrace,
          data: {'fileName': attachment.displayName},
        );
      }
    }
    rethrow;
  }

  for (final attachment in attachments) {
    unawaited(
      Future<void>.sync(
        () => upload(attachment, fileSizes[attachment]!),
      ).catchError((Object error, StackTrace stackTrace) {
        DebugLogger.error(
          'Pasted attachment upload failed',
          scope: logScope,
          error: error,
          stackTrace: stackTrace,
          data: {'fileName': attachment.displayName},
        );
      }),
    );
  }
}

/// Service for handling clipboard image paste operations.
///
/// This service converts pasted image data into [LocalAttachment] objects that
/// integrate with the existing file attachment flow.
///
/// Image bytes are provided by Flutter's content insertion APIs or by the
/// app-owned native iOS paste bridge.
class ClipboardAttachmentService {
  ClipboardAttachmentService({Future<Directory> Function()? temporaryDirectory})
    : _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  static const int _maxImageBytes = maxPastedImageBytes;
  static int _fileSequence = 0;
  final Future<Directory> Function() _temporaryDirectory;

  /// Supported MIME types for image paste operations.
  static const Set<String> supportedImageMimeTypes = {
    'image/png',
    'image/jpeg',
    'image/jpg',
    'image/gif',
    'image/webp',
    'image/bmp',
    'image/tiff',
    'image/heic',
    'image/heif',
  };

  /// Validates an entire marker-backed native paste delivery without taking
  /// ownership. Native iOS remains the owner until [claimNativePasteSync]
  /// wins the pending-marker rename inside the dispatch lease.
  Future<PreparedNativePasteAttachments?> prepareNativePasteAttachments({
    required String deliveryId,
    required List<IosNativeImagePasteItem> items,
  }) async {
    if (!isValidIosNativePasteDeliveryId(deliveryId) ||
        items.isEmpty ||
        items.length > _maxNativePasteItemCount) {
      return null;
    }

    try {
      final temporaryDirectory = await _temporaryDirectory();
      final stagingDirectory = Directory(
        path.join(temporaryDirectory.path, _nativePasteStagingDirectoryName),
      );
      if (!_isDirectoryWithoutLinks(stagingDirectory.path)) return null;

      final resolvedTemporaryPath = path.normalize(
        temporaryDirectory.resolveSymbolicLinksSync(),
      );
      final resolvedStagingPath = path.normalize(
        stagingDirectory.resolveSymbolicLinksSync(),
      );
      if (!path.equals(
            path.dirname(resolvedStagingPath),
            resolvedTemporaryPath,
          ) ||
          path.basename(resolvedStagingPath) !=
              _nativePasteStagingDirectoryName) {
        return null;
      }

      String markerPath(String state) => path.join(
        resolvedStagingPath,
        '$_nativePasteMarkerPrefix$deliveryId.$state',
      );
      final pendingMarkerPath = markerPath('pending');
      final dartOwnedMarkerPath = markerPath('dart-owned');
      final reclaimingMarkerPath = markerPath('reclaiming');
      if (!_isDirectRegularFile(pendingMarkerPath, resolvedStagingPath) ||
          _entityType(dartOwnedMarkerPath) != FileSystemEntityType.notFound ||
          _entityType(reclaimingMarkerPath) != FileSystemEntityType.notFound) {
        return null;
      }

      final attachments = <LocalAttachment>[];
      final itemPaths = <String>[];
      final uniquePaths = <String>{};
      var aggregateBytes = 0;
      for (final item in items) {
        final normalizedItemPath = path.normalize(item.filePath);
        if (!path.isAbsolute(normalizedItemPath) ||
            !path.equals(
              path.dirname(normalizedItemPath),
              path.normalize(stagingDirectory.path),
            ) ||
            !_isStrictNativePasteItemName(
              path.basename(normalizedItemPath),
              deliveryId: deliveryId,
              mimeType: item.mimeType,
            ) ||
            !_isDirectRegularFile(
              normalizedItemPath,
              path.normalize(stagingDirectory.path),
            )) {
          return null;
        }

        final resolvedItemPath = path.normalize(
          File(normalizedItemPath).resolveSymbolicLinksSync(),
        );
        if (!path.equals(path.dirname(resolvedItemPath), resolvedStagingPath) ||
            !uniquePaths.add(resolvedItemPath) ||
            !_isDirectRegularFile(resolvedItemPath, resolvedStagingPath)) {
          return null;
        }
        final byteCount = File(resolvedItemPath).lengthSync();
        if (byteCount <= 0 || byteCount > _maxImageBytes) return null;
        aggregateBytes += byteCount;
        if (aggregateBytes > _maxNativePasteBatchBytes) return null;

        itemPaths.add(resolvedItemPath);
        attachments.add(
          LocalAttachment(
            file: File(resolvedItemPath),
            displayName: path.basename(resolvedItemPath),
          ),
        );
      }
      if (!_hasExactNativePasteBatchSync(
        deliveryId: deliveryId,
        stagingDirectoryPath: resolvedStagingPath,
        expectedItemPaths: itemPaths,
      )) {
        return null;
      }

      return PreparedNativePasteAttachments._(
        deliveryId: deliveryId,
        attachments: List<LocalAttachment>.unmodifiable(attachments),
        itemPaths: List<String>.unmodifiable(itemPaths),
        stagingDirectoryPath: resolvedStagingPath,
        pendingMarkerPath: pendingMarkerPath,
        dartOwnedMarkerPath: dartOwnedMarkerPath,
        reclaimingMarkerPath: reclaimingMarkerPath,
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'Failed to validate native paste delivery',
        scope: 'clipboard/native-paste',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  /// Atomically claims a previously validated delivery, then immediately runs
  /// the synchronous composer mutation. This method must execute inside
  /// `IosNativePasteDispatchLease.tryCommit` with no `await` on either side.
  void claimNativePasteSync(
    PreparedNativePasteAttachments prepared,
    void Function(List<LocalAttachment> attachments) addFiles,
  ) {
    _validatePreparedNativePasteSync(prepared);
    File(prepared.pendingMarkerPath).renameSync(prepared.dartOwnedMarkerPath);
    try {
      addFiles(prepared.attachments);
    } catch (_) {
      // Roll back only if the Dart-owned marker is still ours. Native may have
      // already finalized it after the acknowledgement deadline; that failure
      // is intentionally fail-closed and leaves the bytes Dart-owned.
      try {
        if (_isDirectRegularFile(
              prepared.dartOwnedMarkerPath,
              prepared.stagingDirectoryPath,
            ) &&
            _entityType(prepared.pendingMarkerPath) ==
                FileSystemEntityType.notFound &&
            _entityType(prepared.reclaimingMarkerPath) ==
                FileSystemEntityType.notFound) {
          File(
            prepared.dartOwnedMarkerPath,
          ).renameSync(prepared.pendingMarkerPath);
        }
      } catch (_) {}
      rethrow;
    }
  }

  void _validatePreparedNativePasteSync(
    PreparedNativePasteAttachments prepared,
  ) {
    if (!isValidIosNativePasteDeliveryId(prepared.deliveryId) ||
        !_isDirectoryWithoutLinks(prepared.stagingDirectoryPath) ||
        !_isDirectRegularFile(
          prepared.pendingMarkerPath,
          prepared.stagingDirectoryPath,
        ) ||
        _entityType(prepared.dartOwnedMarkerPath) !=
            FileSystemEntityType.notFound ||
        _entityType(prepared.reclaimingMarkerPath) !=
            FileSystemEntityType.notFound ||
        prepared.itemPaths.isEmpty ||
        prepared.itemPaths.length > _maxNativePasteItemCount ||
        !_hasExactNativePasteBatchSync(
          deliveryId: prepared.deliveryId,
          stagingDirectoryPath: prepared.stagingDirectoryPath,
          expectedItemPaths: prepared.itemPaths,
        )) {
      throw FileSystemException(
        'Native paste delivery is no longer claimable.',
        prepared.pendingMarkerPath,
      );
    }
    var aggregateBytes = 0;
    for (final itemPath in prepared.itemPaths) {
      if (!_isDirectRegularFile(itemPath, prepared.stagingDirectoryPath) ||
          !_isStrictNativePasteItemName(
            path.basename(itemPath),
            deliveryId: prepared.deliveryId,
          )) {
        throw FileSystemException(
          'Native paste item changed before ownership transfer.',
          itemPath,
        );
      }
      final byteCount = File(itemPath).lengthSync();
      if (byteCount <= 0 || byteCount > _maxImageBytes) {
        throw FileSystemException(
          'Native paste item size changed before ownership transfer.',
          itemPath,
        );
      }
      aggregateBytes += byteCount;
      if (aggregateBytes > _maxNativePasteBatchBytes) {
        throw FileSystemException(
          'Native paste delivery grew before ownership transfer.',
          itemPath,
        );
      }
    }
  }

  bool _hasExactNativePasteBatchSync({
    required String deliveryId,
    required String stagingDirectoryPath,
    required List<String> expectedItemPaths,
  }) {
    final expected = expectedItemPaths.map(path.normalize).toSet();
    final observed = <String>{};
    try {
      for (final entity in Directory(
        stagingDirectoryPath,
      ).listSync(followLinks: false)) {
        final entityPath = path.normalize(entity.path);
        final fileName = path.basename(entityPath);
        if (!_isStrictNativePasteItemName(fileName, deliveryId: deliveryId)) {
          continue;
        }
        if (!path.equals(path.dirname(entityPath), stagingDirectoryPath) ||
            _entityType(entityPath) != FileSystemEntityType.file ||
            !observed.add(entityPath)) {
          return false;
        }
      }
    } catch (_) {
      return false;
    }
    return observed.length == expected.length && expected.containsAll(observed);
  }

  bool _isStrictNativePasteItemName(
    String fileName, {
    required String deliveryId,
    String? mimeType,
  }) {
    final prefix = '$deliveryId-';
    if (!fileName.startsWith(prefix)) return false;
    final expectedExtension = mimeType == null
        ? null
        : _extensionForMimeType(mimeType);
    if (mimeType != null && expectedExtension == null) return false;
    final allowedExtensions = mimeType == null
        ? const <String>{
            '.bmp',
            '.gif',
            '.heic',
            '.heif',
            '.jpg',
            '.png',
            '.tiff',
            '.webp',
          }
        : <String>{expectedExtension!};
    for (final extension in allowedExtensions) {
      final suffix = '-paste$extension';
      if (!fileName.endsWith(suffix)) continue;
      final itemId = fileName.substring(
        prefix.length,
        fileName.length - suffix.length,
      );
      return isValidIosNativePasteDeliveryId(itemId);
    }
    return false;
  }

  FileSystemEntityType? _entityType(String entityPath) {
    try {
      return FileSystemEntity.typeSync(entityPath, followLinks: false);
    } catch (_) {
      // An unreadable or otherwise indeterminate entry is not proof that the
      // competing marker is absent. Ownership validation must fail closed.
      return null;
    }
  }

  bool _isDirectoryWithoutLinks(String directoryPath) =>
      _entityType(directoryPath) == FileSystemEntityType.directory;

  bool _isDirectRegularFile(String filePath, String directoryPath) =>
      path.equals(path.dirname(path.normalize(filePath)), directoryPath) &&
      _entityType(filePath) == FileSystemEntityType.file;

  /// Creates a [LocalAttachment] from pasted image data.
  ///
  /// The image data is saved to a temporary file with an appropriate extension
  /// based on the MIME type. Returns null if the operation fails.
  Future<LocalAttachment?> createAttachmentFromImageData({
    required Uint8List imageData,
    required String mimeType,
    String? suggestedFileName,
  }) async {
    File? stagedFile;
    try {
      // Determine file extension from MIME type
      final extension = _extensionForMimeType(mimeType);
      if (extension == null) {
        DebugLogger.log(
          'Unsupported pasted image MIME type',
          scope: 'clipboard/attachments',
          data: {'mimeType': mimeType},
        );
        return null;
      }
      if (imageData.isEmpty || imageData.length > _maxImageBytes) {
        return null;
      }

      // Generate filename, ensuring proper extension
      String fileName;
      if (suggestedFileName != null && suggestedFileName.isNotEmpty) {
        // If suggested filename doesn't have the correct extension, add it
        final suggestedLower = suggestedFileName.toLowerCase();
        final hasImageExt = supportedImageMimeTypes.any((mime) {
          final ext = _extensionForMimeType(mime);
          return ext != null && suggestedLower.endsWith(ext);
        });
        fileName = hasImageExt
            ? suggestedFileName
            : '$suggestedFileName$extension';
      } else {
        fileName = _generateFileName(extension);
      }

      // Always add a unique suffix and use exclusive creation. A native paste
      // can contain multiple same-format images in the same clock tick; using
      // only a seconds-resolution timestamp silently overwrote earlier items.
      final tempDir = await _temporaryDirectory();
      final stem = path
          .basenameWithoutExtension(fileName)
          .replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
      final sequence = _fileSequence++;
      final uniqueName =
          '${stem}_${DateTime.now().microsecondsSinceEpoch}_$sequence$extension';
      final filePath = path.join(tempDir.path, uniqueName);

      stagedFile = File(filePath);
      await stagedFile.create(exclusive: true);
      await stagedFile.writeAsBytes(imageData, flush: true);

      return LocalAttachment(file: stagedFile, displayName: uniqueName);
    } catch (error, stackTrace) {
      try {
        if (stagedFile != null && await stagedFile.exists()) {
          await stagedFile.delete();
        }
      } catch (_) {}
      DebugLogger.error(
        'Failed to stage pasted image data',
        scope: 'clipboard/attachments',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  /// Validates an image already staged by the app-owned iOS paste bridge.
  ///
  /// Native paste files use unique paths and stay file-backed, avoiding a
  /// second large byte-array copy through the platform channel and Dart heap.
  Future<LocalAttachment?> createAttachmentFromStagedFile({
    required String filePath,
    required String mimeType,
  }) async {
    try {
      final temporaryDirectory = await _temporaryDirectory();
      final stagingDirectory = Directory(
        path.join(temporaryDirectory.path, 'conduit-native-paste'),
      );
      final file = File(filePath);
      if (!await file.exists()) return null;
      if (!await stagingDirectory.exists()) return null;
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return null;
      }
      if (await FileSystemEntity.type(
            stagingDirectory.path,
            followLinks: false,
          ) !=
          FileSystemEntityType.directory) {
        return null;
      }

      // The bridge owns exactly this staging directory. Resolve both sides so
      // a symlink placed inside it cannot make validation (or oversized-file
      // cleanup below) touch an arbitrary caller-supplied path.
      final resolvedFilePath = path.normalize(
        await file.resolveSymbolicLinks(),
      );
      final resolvedStagingPath = path.normalize(
        await stagingDirectory.resolveSymbolicLinks(),
      );
      final resolvedTemporaryPath = path.normalize(
        await temporaryDirectory.resolveSymbolicLinks(),
      );
      if (!path.equals(
            path.dirname(resolvedStagingPath),
            resolvedTemporaryPath,
          ) ||
          path.basename(resolvedStagingPath) != 'conduit-native-paste') {
        return null;
      }
      if (!path.equals(path.dirname(resolvedFilePath), resolvedStagingPath)) {
        return null;
      }
      final stagedFile = File(resolvedFilePath);
      // Resolve ownership before MIME validation so malformed native payloads
      // cannot strand files in the app-owned staging directory. Never delete
      // an unsupported caller path outside that exact directory.
      if (!isSupportedImageType(mimeType)) {
        try {
          await stagedFile.delete();
        } catch (_) {}
        return null;
      }
      final length = await stagedFile.length();
      if (length <= 0 || length > _maxImageBytes) {
        try {
          await stagedFile.delete();
        } catch (_) {}
        return null;
      }
      return LocalAttachment(
        file: stagedFile,
        displayName: path.basename(stagedFile.path),
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'Failed to validate native pasted image',
        scope: 'clipboard/attachments',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  /// Checks if a MIME type is a supported image type.
  bool isSupportedImageType(String mimeType) {
    return supportedImageMimeTypes.contains(mimeType.toLowerCase());
  }

  /// Returns the file extension for a given MIME type, or null if unsupported.
  String? _extensionForMimeType(String mimeType) {
    switch (mimeType.toLowerCase()) {
      case 'image/png':
        return '.png';
      case 'image/jpeg':
      case 'image/jpg':
        return '.jpg';
      case 'image/gif':
        return '.gif';
      case 'image/webp':
        return '.webp';
      case 'image/bmp':
        return '.bmp';
      case 'image/tiff':
        return '.tiff';
      case 'image/heic':
        return '.heic';
      case 'image/heif':
        return '.heif';
      default:
        return null;
    }
  }

  /// Generates a timestamped filename for pasted images.
  String _generateFileName(String extension) {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    final timestamp =
        '${now.year}${two(now.month)}${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    return 'pasted_$timestamp$extension';
  }
}
