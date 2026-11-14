/// A model's own system prompt as the server's model record keeps it
/// (`params.system`), which Settings › Chats › Prompt Overrides edits.
library;

/// The prompt in [model]'s record (`GET /api/v1/models/model`), or null when
/// it has none.
String? modelSystemPromptOf(Map<String, dynamic> model) {
  final params = model['params'];
  if (params is Map && params['system'] is String) {
    final value = (params['system'] as String).trim();
    if (value.isNotEmpty) return value;
  }
  return null;
}

/// Whether the signed-in account may change [model]'s record.
bool modelRecordWritable(Map<String, dynamic> model) =>
    model['write_access'] == true;
