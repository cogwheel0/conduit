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
    return base.toLowerCase().endsWith('.$extension')
        ? base
        : '$base.$extension';
  }

  /// Replaces every run of characters that are not letters or digits (in any
  /// script) or `. _ -` with one underscore, so a resource name cannot escape
  /// the staging directory or upset a share target, while a name such as
  /// `résumé` or `模型` stays recognisable. A blank name becomes `export`.
  static String sanitize(String filename) {
    final trimmed = filename.trim();
    final base = trimmed.isEmpty ? 'export' : trimmed;
    return base.replaceAll(RegExp(r'[^\p{L}\p{N}._-]+', unicode: true), '_');
  }

  /// [data] as pretty-printed UTF-8 JSON.
  static List<int> jsonBytes(Object? data) =>
      utf8.encode(const JsonEncoder.withIndent('  ').convert(data));

  /// Writes [bytes] under the sanitized [filename] in a new directory inside
  /// [directory], so two exports with the same name never share a path: a
  /// share sheet still reading the first file cannot be handed the second's
  /// bytes.
  static Future<File> stage({
    required Directory directory,
    required String filename,
    required List<int> bytes,
  }) async {
    final safeName = sanitize(filename);
    final staging = await directory.createTemp('export_');
    final file = File('${staging.path}/$safeName');
    await file.writeAsBytes(bytes, flush: true);
    DebugLogger.log(
      'workspace export prepared',
      scope: 'workspace/export',
      data: {'file': safeName, 'bytes': bytes.length},
    );
    return file;
  }
}
