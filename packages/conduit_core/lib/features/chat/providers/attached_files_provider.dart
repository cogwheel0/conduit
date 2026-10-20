/// The composer's attachment tray: what the user picked, and how far each
/// upload has got.
///
/// Picking files is a platform capability and stays in the app
/// (`file_attachment_service.dart`); the state it feeds, which the send
/// pipeline reads, lives here.
library;

import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as path;
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/models/file_info.dart';

/// Standard web image formats that LLMs can process directly.
const Set<String> _standardImageFormats = {
  '.jpg',
  '.jpeg',
  '.png',
  '.gif',
  '.webp',
};

/// Formats that should always be converted to JPEG for compatibility.
const Set<String> alwaysConvertImageFormats = {
  '.heic',
  '.heif',
  '.dng',
  '.raw',
  '.cr2',
  '.nef',
  '.arw',
  '.orf',
  '.rw2',
  '.bmp',
};

/// All supported image formats (both standard and those requiring conversion).
const Set<String> allSupportedImageFormats = {
  ..._standardImageFormats,
  ...alwaysConvertImageFormats,
};

/// Represents a locally selected attachment with a user-facing display name.
class LocalAttachment {
  LocalAttachment({required this.file, required this.displayName});

  final File file;
  final String displayName;

  int get sizeInBytes => file.lengthSync();

  String get extension {
    final fromName = path.extension(displayName);
    if (fromName.isNotEmpty) {
      return fromName.toLowerCase();
    }
    return path.extension(file.path).toLowerCase();
  }

  bool get isImage => allSupportedImageFormats.contains(extension);
}

// File upload state
class FileUploadState {
  final File file;
  final String fileName;
  final int fileSize;
  final double progress;
  final FileUploadStatus status;
  final String? fileId;
  final String? error;
  final bool? isImage;

  /// For images: stores the base64 data URL (e.g., "data:image/png;base64,...")
  /// This matches web client behavior where images are not uploaded to server.
  final String? base64DataUrl;

  FileUploadState({
    required this.file,
    required this.fileName,
    required this.fileSize,
    required this.progress,
    required this.status,
    this.fileId,
    this.error,
    this.isImage,
    this.base64DataUrl,
  });

  /// Whether this attachment references a previously uploaded server file.
  bool get isRemote => file.path.startsWith('remote://');
}

enum FileUploadStatus { pending, uploading, completed, failed }

// State notifier for managing attached files
class AttachedFilesNotifier extends Notifier<List<FileUploadState>> {
  @override
  List<FileUploadState> build() => [];

  void addFiles(List<LocalAttachment> attachments) {
    final newStates = attachments
        .map(
          (attachment) => FileUploadState(
            file: attachment.file,
            fileName: attachment.displayName,
            fileSize: attachment.sizeInBytes,
            progress: 0.0,
            status: FileUploadStatus.pending,
            isImage: attachment.isImage,
          ),
        )
        .toList();

    state = [...state, ...newStates];
  }

  void addRemoteFile(FileInfo file) {
    if (state.any((entry) => entry.fileId == file.id)) {
      return;
    }

    state = [
      ...state,
      FileUploadState(
        file: File('remote://${file.id}'),
        fileName: file.displayName,
        fileSize: file.size,
        progress: 1.0,
        status: FileUploadStatus.completed,
        fileId: file.id,
        isImage: false,
      ),
    ];
  }

  /// Removes the exact [states], leaving a newer state at the same path alone.
  void releaseIdentical(Iterable<FileUploadState> states) {
    final released = states.toList(growable: false);
    if (released.isEmpty) return;
    state = [
      for (final entry in state)
        if (!released.any((candidate) => identical(candidate, entry))) entry,
    ];
  }

  void updateFileState(String filePath, FileUploadState newState) {
    state = [
      for (final fileState in state)
        if (fileState.file.path == filePath) newState else fileState,
    ];
  }

  void removeFile(String filePath) {
    state = state
        .where((fileState) => fileState.file.path != filePath)
        .toList();
  }

  /// Removes only the exact attachment owner captured by an async boundary.
  /// A newer session may reuse the same pathname with a different state object;
  /// path-only removal would incorrectly retire that replacement.
  bool removeFileIfIdentical(FileUploadState attachment) {
    final hasOwner = state.any((entry) => identical(entry, attachment));
    if (!hasOwner) return false;
    state = state.where((entry) => !identical(entry, attachment)).toList();
    return true;
  }

  void clearAll() {
    state = [];
  }
}

final attachedFilesProvider =
    NotifierProvider<AttachedFilesNotifier, List<FileUploadState>>(
      AttachedFilesNotifier.new,
    );

/// A file held by a draft queued behind a running response.
///
/// [id] names the capture and stays the same as the upload reports progress,
/// which only replaces [upload]. [queueId] is the queue (one conversation of one
/// account on one server) that captured it. A file is resolved, sent and
/// released by that queue alone, even when another queue holds a file at the
/// same pathname.
@immutable
final class QueuedDraftAttachment {
  const QueuedDraftAttachment({
    required this.id,
    required this.queueId,
    required this.upload,
  });

  final String id;
  final String queueId;
  final FileUploadState upload;

  QueuedDraftAttachment _withUpload(FileUploadState next) =>
      QueuedDraftAttachment(id: id, queueId: queueId, upload: next);
}

bool _isUnfinished(FileUploadState upload) =>
    upload.status == FileUploadStatus.pending ||
    upload.status == FileUploadStatus.uploading;

/// Files of queued drafts. Their uploads keep running after they leave the
/// composer tray, so the upload states are the same objects the upload
/// controller reports into.
class QueuedDraftAttachmentsNotifier
    extends Notifier<List<QueuedDraftAttachment>> {
  @override
  List<QueuedDraftAttachment> build() => const <QueuedDraftAttachment>[];

  /// Takes over the composer's files as they are. Their identity is preserved
  /// so an upload that is still running keeps the state it reports into.
  void adopt(List<QueuedDraftAttachment> held) {
    if (held.isEmpty) return;
    state = [...state, ...held];
  }

  /// Applies progress from the upload that captured [current]: that exact state
  /// is replaced. Files of the same queue at the same pathname that are still
  /// waiting joined this upload and follow it. A file held by any other queue
  /// never does, whatever its pathname.
  bool replaceUpload(FileUploadState current, FileUploadState next) {
    final owner = state
        .where((entry) => identical(entry.upload, current))
        .firstOrNull;
    if (owner == null) return false;
    state = [
      for (final entry in state)
        if (identical(entry.upload, current) ||
            (entry.queueId == owner.queueId &&
                entry.upload.file.path == current.file.path &&
                _isUnfinished(entry.upload)))
          entry._withUpload(next)
        else
          entry,
    ];
    return true;
  }

  /// Drops the files that hold exactly [upload].
  void removeUpload(FileUploadState upload) {
    final kept = [
      for (final entry in state)
        if (!identical(entry.upload, upload)) entry,
    ];
    if (kept.length != state.length) state = kept;
  }

  /// Releases the files [ids] of [queueId]. Another queue's files, and a later
  /// draft's file at the same pathname, are left alone.
  void release(String queueId, Iterable<String> ids) {
    final gone = ids.toSet();
    if (gone.isEmpty) return;
    final kept = [
      for (final entry in state)
        if (entry.queueId != queueId || !gone.contains(entry.id)) entry,
    ];
    if (kept.length != state.length) state = kept;
  }
}

final queuedDraftAttachmentsProvider =
    NotifierProvider<
      QueuedDraftAttachmentsNotifier,
      List<QueuedDraftAttachment>
    >(QueuedDraftAttachmentsNotifier.new);
