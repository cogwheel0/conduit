import 'package:uuid/uuid.dart';

import '../../../core/models/chat_message.dart';

/// Maps a Hermes session's raw message history (`GET /api/sessions/{id}/messages`)
/// into Conduit [ChatMessage]s for display in the chat view.
///
/// Tolerant of the shape variations across Hermes versions: content may be a
/// plain string or an array of typed parts (`text` / `input_text` /
/// `output_text`), and system/tool rows are skipped from the visible transcript.
List<ChatMessage> hermesMessagesToChatMessages(
  List<Map<String, dynamic>> raw, {
  String? modelId,
}) {
  const uuid = Uuid();
  final messages = <ChatMessage>[];

  for (var i = 0; i < raw.length; i++) {
    final item = raw[i];
    final role = (item['role'] ?? item['author'] ?? '')
        .toString()
        .toLowerCase();
    if (role != 'user' && role != 'assistant') continue;

    final content = _extractText(item['content'] ?? item['text']).trim();
    if (content.isEmpty) continue;
    final responseId = role == 'assistant'
        ? (item['run_id'] ?? item['response_id'] ?? item['responseId'])
              ?.toString()
              .trim()
        : null;

    messages.add(
      ChatMessage(
        id: (item['id'] ?? uuid.v4()).toString(),
        role: role,
        content: content,
        timestamp:
            _parseTime(item['created_at'] ?? item['timestamp']) ??
            DateTime.fromMillisecondsSinceEpoch(i * 1000),
        model: role == 'assistant' ? modelId : null,
        metadata: responseId == null || responseId.isEmpty
            ? null
            : {'hermesRunId': responseId},
      ),
    );
  }

  return messages;
}

String _extractText(dynamic content) {
  if (content == null) return '';
  if (content is String) return content;
  if (content is List) {
    final buffer = StringBuffer();
    for (final part in content) {
      if (part is String) {
        buffer.write(part);
      } else if (part is Map) {
        final type = part['type']?.toString();
        if (type == null ||
            type == 'text' ||
            type == 'input_text' ||
            type == 'output_text') {
          final text = part['text'] ?? part['content'];
          if (text != null) buffer.write(text.toString());
        }
      }
    }
    return buffer.toString();
  }
  if (content is Map) {
    final text = content['text'] ?? content['content'];
    return text?.toString() ?? '';
  }
  return content.toString();
}

DateTime? _parseTime(dynamic value) {
  if (value == null) return null;
  if (value is num) {
    final ms = value < 100000000000 ? (value * 1000).round() : value.round();
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }
  final str = value.toString();
  final asNum = num.tryParse(str);
  if (asNum != null) return _parseTime(asNum);
  return DateTime.tryParse(str);
}
