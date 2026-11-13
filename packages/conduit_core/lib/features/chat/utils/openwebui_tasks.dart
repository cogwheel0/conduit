import 'package:meta/meta.dart';

/// The conversation metadata key Open WebUI's task checklist is kept under
/// (`chat.tasks` on the server, `chat:message:tasks` live).
const String kOpenWebUiTasksMetadataKey = 'openwebui_tasks';

/// One item of Open WebUI's task checklist.
@immutable
final class OpenWebUiTask {
  const OpenWebUiTask({
    required this.id,
    required this.content,
    required this.status,
  });

  final String id;
  final String content;

  /// `pending`, `in_progress`, `completed` or `cancelled` as the server
  /// wrote it; anything else reads as pending.
  final String status;

  bool get completed => status == 'completed';

  @override
  bool operator ==(Object other) =>
      other is OpenWebUiTask &&
      other.id == id &&
      other.content == content &&
      other.status == status;

  @override
  int get hashCode => Object.hash(id, content, status);
}

/// The checklist a conversation's [metadata] holds, in order: the entries
/// with text, as the mobile app lists them. Empty when it has none.
List<OpenWebUiTask> openWebUiTasksOf(Map<String, dynamic>? metadata) {
  final raw = metadata?[kOpenWebUiTasksMetadataKey];
  if (raw is! List) return const <OpenWebUiTask>[];
  return List<OpenWebUiTask>.unmodifiable([
    for (final task in raw.whereType<Map>())
      if (task['content'] case final String content)
        OpenWebUiTask(
          id: task['id']?.toString() ?? '',
          content: content,
          status: task['status']?.toString() ?? 'pending',
        ),
  ]);
}
