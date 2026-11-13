import 'package:conduit_core/features/workspace/models/workspace_export_files.dart';

/// The file a single chat exports to: its title, then a stamp
/// (`<title>-<epoch ms>.<extension>`), or `chat-…` for an untitled one.
String chatExportFileName(String title, DateTime now, String extension) {
  final stem = title.trim().isEmpty ? 'chat' : title.trim();
  return WorkspaceExportFiles.withExtension(
    '$stem-${now.millisecondsSinceEpoch}',
    extension,
  );
}
