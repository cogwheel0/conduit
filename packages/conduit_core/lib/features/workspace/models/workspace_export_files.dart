import 'dart:convert';
import 'dart:io';

import '../../../utils/debug_logger.dart';

/// File naming and staging for workspace exports (models, prompts, tools,
/// skills, knowledge). The app shares the staged file through the share
/// sheet; nothing here publishes anywhere.
abstract final class WorkspaceExportFiles {
  /// Appends `.extension` unless [filename] already ends with it (case
  /// insensitive). A blank name becomes `export`.
  static String withExtension(String filename, String extension) {
    final trimmed = filename.trim();
    final base = trimmed.isEmpty ? 'export' : trimmed;
    return base.toLowerCase().endsWith('.${extension.toLowerCase()}')
        ? base
        : '$base.$extension';
  }

  /// The longest staged file name, in UTF-8 bytes: under the 255-byte limit
  /// of a file name component on common mobile file systems, which an
  /// overlong resource name (or a short one in a script of three-byte
  /// characters) could otherwise pass.
  static const int maxNameBytes = 200;

  /// Replaces every run of characters that are not letters or digits (in any
  /// script) or `. _ -` with one underscore, so a resource name cannot escape
  /// the staging directory or upset a share target, while a name such as
  /// `résumé` or `模型` stays recognisable. A blank name, or one that is only
  /// dots, becomes `export`; a name over [maxNameBytes] bytes is cut, keeping
  /// a short extension.
  static String sanitize(String filename) {
    final trimmed = filename.trim();
    final base = trimmed.isEmpty ? 'export' : trimmed;
    final safe = base.replaceAll(
      RegExp(r'[^\p{L}\p{N}._-]+', unicode: true),
      '_',
    );
    // `.` and `..` name a directory, not a file, so staging them would fail.
    if (safe == '.' || safe == '..') return 'export';
    if (utf8.encode(safe).length <= maxNameBytes) return safe;
    final dot = safe.lastIndexOf('.');
    final extension = dot > 0 && utf8.encode(safe.substring(dot)).length <= 16
        ? safe.substring(dot)
        : '';
    final room = maxNameBytes - utf8.encode(extension).length;
    final stem = StringBuffer();
    var used = 0;
    for (final rune
        in (extension.isEmpty ? safe : safe.substring(0, dot)).runes) {
      final width = utf8.encode(String.fromCharCode(rune)).length;
      if (used + width > room) break;
      stem.writeCharCode(rune);
      used += width;
    }
    return '$stem$extension';
  }

  /// [data] as pretty-printed UTF-8 JSON.
  static List<int> jsonBytes(Object? data) =>
      utf8.encode(const JsonEncoder.withIndent('  ').convert(data));

  /// How long a staged export is kept. A share target (Android's chooser, a
  /// mail app) can read the file after the share call returns, so nothing is
  /// deleted right after sharing; the next export removes older ones.
  static const Duration staleAfter = Duration(hours: 24);

  /// The directory inside the caller's temporary directory that holds staged
  /// exports, so cleaning it up can never touch anything else.
  static const String stagingRoot = 'workspace_exports';

  /// Writes [bytes] under the sanitized [filename] in a new directory of its
  /// own below `[directory]/workspace_exports`, so two exports with the same
  /// name never share a path: a share sheet still reading the first file
  /// cannot be handed the second's bytes. Staged exports older than [keepFor]
  /// are removed first.
  static Future<File> stage({
    required Directory directory,
    required String filename,
    required List<int> bytes,
    Duration keepFor = staleAfter,
  }) async {
    final safeName = sanitize(filename);
    final root = await Directory('${directory.path}/$stagingRoot')
        .create(recursive: true);
    await _removeStale(root, keepFor);
    final staging = await root.createTemp('export_');
    final file = File('${staging.path}/$safeName');
    await file.writeAsBytes(bytes, flush: true);
    DebugLogger.log(
      'workspace export prepared',
      scope: 'workspace/export',
      data: {'file': safeName, 'bytes': bytes.length},
    );
    return file;
  }

  /// Deletes the staged export directories in [root] last written more than
  /// [keepFor] ago. Best effort and per entry: one that cannot be removed is
  /// left for next time and does not stop the others.
  static Future<void> _removeStale(Directory root, Duration keepFor) async {
    final cutoff = DateTime.now().subtract(keepFor);
    final List<FileSystemEntity> entries;
    try {
      entries = await root.list(followLinks: false).toList();
    } catch (_) {
      return;
    }
    for (final entity in entries) {
      if (entity is! Directory) continue;
      try {
        if ((await entity.stat()).modified.isBefore(cutoff)) {
          await entity.delete(recursive: true);
        }
      } catch (_) {}
    }
  }
}
