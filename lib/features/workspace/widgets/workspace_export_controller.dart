import 'dart:io';
import 'dart:ui' show Rect;

import 'package:conduit_core/features/workspace/models/workspace_export_files.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

typedef WorkspaceShareFn = Future<ShareResult> Function(ShareParams params);

/// Shares workspace exports (models/prompts/tools/skills/knowledge) through the
/// OS share sheet via `share_plus`. Deliberately offers no openwebui.com
/// publishing path — exports stay local to the device's share targets.
///
/// Naming and staging are conduit_core's [WorkspaceExportFiles].
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
    return shareBytes(
      filename: WorkspaceExportFiles.withExtension(filename, 'json'),
      bytes: WorkspaceExportFiles.jsonBytes(data),
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
    final file = await WorkspaceExportFiles.stage(
      directory: await _tempDirectory(),
      filename: filename,
      bytes: bytes,
    );
    return _share(
      ShareParams(
        files: [
          XFile(
            file.path,
            name: WorkspaceExportFiles.sanitize(filename),
            mimeType: mimeType,
          ),
        ],
        subject: subject,
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
  }
}
