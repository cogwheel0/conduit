import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:conduit/core/utils/debug_logger.dart';

typedef WorkspaceShareFn = Future<ShareResult> Function(ShareParams params);

/// Shares workspace exports (models/prompts/tools/skills/knowledge) through the
/// OS share sheet via `share_plus`. Deliberately offers no openwebui.com
/// publishing path — exports stay local to the device's share targets.
///
/// [share] and [tempDirectory] are injectable for testing.
class WorkspaceExportController {
  WorkspaceExportController({
    WorkspaceShareFn? share,
    Future<Directory> Function()? tempDirectory,
  }) : _share = share ?? SharePlus.instance.share,
       _tempDirectory = tempDirectory ?? getTemporaryDirectory;

  final WorkspaceShareFn _share;
  final Future<Directory> Function() _tempDirectory;

  /// Serializes [data] to pretty JSON and shares it as a `.json` file.
  Future<ShareResult> shareJson({
    required String filename,
    required Object? data,
    String? subject,
    Rect? sharePositionOrigin,
  }) {
    final encoded = const JsonEncoder.withIndent('  ').convert(data);
    return shareBytes(
      filename: _ensureExtension(filename, 'json'),
      bytes: utf8.encode(encoded),
      mimeType: 'application/json',
      subject: subject,
      sharePositionOrigin: sharePositionOrigin,
    );
  }

  /// Writes [bytes] to a temporary file and shares it.
  Future<ShareResult> shareBytes({
    required String filename,
    required List<int> bytes,
    String? mimeType,
    String? subject,
    Rect? sharePositionOrigin,
  }) async {
    final dir = await _tempDirectory();
    final safeName = _sanitizeFilename(filename);
    final file = File('${dir.path}/$safeName');
    await file.writeAsBytes(bytes, flush: true);
    DebugLogger.log(
      'workspace export prepared',
      scope: 'workspace/export',
      data: {'file': safeName, 'bytes': bytes.length},
    );
    return _share(
      ShareParams(
        files: [XFile(file.path, name: safeName, mimeType: mimeType)],
        subject: subject,
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
  }

  static String _ensureExtension(String filename, String extension) {
    final trimmed = filename.trim();
    final base = trimmed.isEmpty ? 'export' : trimmed;
    return base.toLowerCase().endsWith('.$extension')
        ? base
        : '$base.$extension';
  }

  static String _sanitizeFilename(String filename) {
    final trimmed = filename.trim();
    final base = trimmed.isEmpty ? 'export' : trimmed;
    return base.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
  }
}
