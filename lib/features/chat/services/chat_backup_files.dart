import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:conduit_core/features/chat/services/chat_backup.dart';
import 'package:conduit_core/features/workspace/models/workspace_export_files.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// A backup being written to a file the user has not been handed yet.
abstract interface class ChatBackupFile implements ChatBackupSink {
  String get name;
}

Future<int?> _unknownLength() async => null;

/// A file the user chose to import.
final class PickedChatFile {
  const PickedChatFile({
    required this.name,
    required this.read,
    this.length = _unknownLength,
  });

  final String name;

  /// The file's size in bytes when the picker reports it, so a file that is
  /// too large can be refused before it is read into memory.
  final Future<int?> Function() length;

  /// Reads the whole file.
  final Future<Uint8List> Function() read;
}

/// The platform's side of data controls: where a backup is written, how it
/// reaches the user (the system share sheet, which includes Save to Files), and
/// how an import file is chosen. Validation and everything about the chats
/// stays in the core; this only moves files.
abstract interface class ChatBackupFiles {
  /// Starts a backup file named [filename]; nothing is shared until
  /// [deliver].
  Future<ChatBackupFile> create(String filename);

  /// Hands a committed [file] to the share sheet.
  Future<void> deliver(ChatBackupFile file, {Rect? origin});

  /// Writes [text] to a new file and hands it to the share sheet.
  ///
  /// Staging the file is asynchronous, so [checkpoint] runs once it is written
  /// and immediately before the share sheet opens. It throws to refuse: the
  /// staged file is then deleted, never handed over, and the error propagates.
  Future<void> deliverText(
    String filename,
    String text, {
    required String mimeType,
    Rect? origin,
    void Function()? checkpoint,
  });

  /// Opens the system file picker for a `.json` file, or returns null when the
  /// user dismisses it.
  Future<PickedChatFile?> pickImportFile();
}

/// The file the user is handed for a library backup:
/// `chat-export-<epoch ms>.json`, as Open WebUI's own Data controls name it.
String libraryBackupFileName(DateTime now) =>
    'chat-export-${now.millisecondsSinceEpoch}.json';

/// The file a single chat exports to: its title, then a stamp.
String chatExportFileName(String title, DateTime now, String extension) {
  final stem = title.trim().isEmpty ? 'chat' : title.trim();
  return WorkspaceExportFiles.withExtension(
    '$stem-${now.millisecondsSinceEpoch}',
    extension,
  );
}

final chatBackupFilesProvider = Provider<ChatBackupFiles>(
  (ref) => PlatformChatBackupFiles(),
);

final class PlatformChatBackupFiles implements ChatBackupFiles {
  PlatformChatBackupFiles({
    Future<ShareResult> Function(ShareParams params)? share,
    Future<Directory> Function()? tempDirectory,
  }) : _share = share ?? SharePlus.instance.share,
       _tempDirectory = tempDirectory ?? getTemporaryDirectory;

  final Future<ShareResult> Function(ShareParams params) _share;
  final Future<Directory> Function() _tempDirectory;

  @override
  Future<ChatBackupFile> create(String filename) async {
    // Staging an empty file reserves a path of its own and removes old backups;
    // the backup is then streamed into it, so a large library never has to fit
    // in memory.
    final file = await WorkspaceExportFiles.stage(
      directory: await _tempDirectory(),
      filename: filename,
      bytes: const <int>[],
    );
    return _FileBackup(file);
  }

  @override
  Future<void> deliver(ChatBackupFile file, {Rect? origin}) async {
    final backup = file as _FileBackup;
    await _share(
      ShareParams(
        files: [
          XFile(
            backup.file.path,
            name: backup.name,
            mimeType: 'application/json',
          ),
        ],
        sharePositionOrigin: origin,
      ),
    );
  }

  @override
  Future<void> deliverText(
    String filename,
    String text, {
    required String mimeType,
    Rect? origin,
    void Function()? checkpoint,
  }) async {
    final staged = await WorkspaceExportFiles.stage(
      directory: await _tempDirectory(),
      filename: filename,
      bytes: utf8.encode(text),
    );
    try {
      checkpoint?.call();
    } catch (_) {
      await _discard(staged);
      rethrow;
    }
    await _share(
      ShareParams(
        files: [
          XFile(
            staged.path,
            name: WorkspaceExportFiles.sanitize(filename),
            mimeType: mimeType,
          ),
        ],
        sharePositionOrigin: origin,
      ),
    );
  }

  @override
  Future<PickedChatFile?> pickImportFile() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (picked == null) return null;
    final path = picked.path;
    return PickedChatFile(
      name: picked.name,
      length: picked.length,
      read: () async => path != null
          ? File(path).readAsBytes()
          : Uint8List.fromList(await picked.readAsBytes()),
    );
  }
}

/// How much is written before waiting for the disk, so a large library is not
/// buffered whole.
const int _flushEveryBytes = 256 * 1024;

final class _FileBackup implements ChatBackupFile {
  _FileBackup(this.file) : _out = file.openWrite();

  final File file;
  final IOSink _out;
  var _pending = 0;
  var _closed = false;

  @override
  String get name => file.uri.pathSegments.last;

  @override
  Future<void> write(String text) async {
    _out.write(text);
    _pending += text.length;
    if (_pending >= _flushEveryBytes) {
      _pending = 0;
      await _out.flush();
    }
  }

  @override
  Future<void> commit() async {
    if (_closed) return;
    _closed = true;
    await _out.close();
  }

  @override
  Future<void> abort() async {
    if (!_closed) {
      _closed = true;
      try {
        await _out.close();
      } catch (_) {
        // The file is being thrown away anyway.
      }
    }
    await _discard(file);
  }
}

/// Removes the staging directory of a file that was never handed over.
Future<void> _discard(File staged) async {
  try {
    await staged.parent.delete(recursive: true);
  } catch (_) {
    // The next export removes stale staging directories.
  }
}
