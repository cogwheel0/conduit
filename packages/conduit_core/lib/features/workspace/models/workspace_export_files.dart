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

  /// Replaces every run of characters that are not letters or digits (in any
  /// script) or `. _ -` with one underscore, so a resource name cannot escape
  /// the staging directory or upset a share target, while a name such as
  /// `résumé` or `模型` stays recognisable. A blank name, or one that is only dots,
  /// becomes `export`.
  static String sanitize(String filename) {
    final trimmed = filename.trim();
    final base = trimmed.isEmpty ? 'export' : trimmed;
    final safe = base.replaceAll(
      RegExp(r'[^\p{L}\p{N}._-]+', unicode: true),
      '_',
    );
    // `.` and `..` name a directory, not a file, so staging them would fail.
    return safe == '.' || safe == '..' ? 'export' : safe;
  }

  /// [data] as pretty-printed UTF-8 JSON.
  static List<int> jsonBytes(Object? data) =>
      utf8.encode(const JsonEncoder.withIndent('  ').convert(data));

  /// How long a staged export is kept. A share target (Android's chooser, a
  /// mail app) can read the file after the share call returns, so nothing is
  /// deleted right after sharing; the next export removes older ones.
  static const Duration staleAfter = Duration(hours: 1);

  /// Writes [bytes] under the sanitized [filename] in a new directory inside
  /// [directory], so two exports with the same name never share a path: a
  /// share sheet still reading the first file cannot be handed the second's
  /// bytes. Staged exports older than [keepFor] are removed first.
  static Future<File> stage({
    required Directory directory,
    required String filename,
    required List<int> bytes,
    Duration keepFor = staleAfter,
  }) async {
    final safeName = sanitize(filename);
    await _removeStale(directory, keepFor);
    final staging = await directory.createTemp(_stagingPrefix);
    final file = File('${staging.path}/$safeName');
    await file.writeAsBytes(bytes, flush: true);
    DebugLogger.log(
      'workspace export prepared',
      scope: 'workspace/export',
      data: {'file': safeName, 'bytes': bytes.length},
    );
    return file;
  }

  static const String _stagingPrefix = 'export_';

  /// Deletes the staged export directories in [directory] last written more
  /// than [keepFor] ago. Best effort: a failure leaves them for next time.
  static Future<void> _removeStale(
    Directory directory,
    Duration keepFor,
  ) async {
    try {
      final cutoff = DateTime.now().subtract(keepFor);
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final name = entity.uri.pathSegments.lastWhere(
          (segment) => segment.isNotEmpty,
          orElse: () => '',
        );
        if (!name.startsWith(_stagingPrefix)) continue;
        if ((await entity.stat()).modified.isBefore(cutoff)) {
          await entity.delete(recursive: true);
        }
      }
    } catch (_) {}
  }
}
