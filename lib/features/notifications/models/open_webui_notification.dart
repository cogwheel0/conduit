import 'dart:convert';

enum OpenWebUINotificationKind { chat, channel }

class OpenWebUINotification {
  const OpenWebUINotification({
    required this.kind,
    required this.id,
    required this.title,
    required this.body,
    required this.payload,
  });

  final OpenWebUINotificationKind kind;
  final String id;
  final String title;
  final String body;
  final String payload;
}

class OpenWebUINotificationPayload {
  const OpenWebUINotificationPayload({required this.kind, required this.id});

  final OpenWebUINotificationKind kind;
  final String id;
}

OpenWebUINotification? parseChatCompletionNotification(
  Map<String, dynamic> event, {
  String fallbackTitle = 'New Chat',
  bool allowTemporary = false,
}) {
  final chatId = _stringFrom(event['chat_id'] ?? event['chatId']);
  if (chatId == null || chatId.isEmpty) {
    return null;
  }
  if (!allowTemporary && chatId.startsWith('local:')) {
    return null;
  }

  final eventData = _mapFrom(event['data']);
  if (eventData == null || eventData['type'] != 'chat:completion') {
    return null;
  }

  final data = _mapFrom(eventData['data']);
  if (data == null || data['done'] != true) {
    return null;
  }

  final body = sanitizeNotificationText(
    _stringFrom(data['content'] ?? data['message'] ?? data['text']),
  );
  if (body.isEmpty) {
    return null;
  }

  final displayTitle = sanitizeNotificationText(
    _stringFrom(data['title']),
    fallback: fallbackTitle,
    maxLength: 80,
  );
  return OpenWebUINotification(
    kind: OpenWebUINotificationKind.chat,
    id: chatId,
    title: '$displayTitle - Open WebUI',
    body: body,
    payload: encodeOpenWebUINotificationPayload(
      OpenWebUINotificationPayload(
        kind: OpenWebUINotificationKind.chat,
        id: chatId,
      ),
    ),
  );
}

OpenWebUINotification? parseChannelMessageNotification(
  Map<String, dynamic> event, {
  String? currentUserId,
}) {
  final channelId = _stringFrom(
    event['channel_id'] ?? event['channelId'] ?? event['conversation_id'],
  );
  if (channelId == null || channelId.isEmpty) {
    return null;
  }

  final eventUser = _mapFrom(event['user']);
  final eventUserId = _stringFrom(eventUser?['id']);
  if (eventUserId != null &&
      currentUserId != null &&
      eventUserId == currentUserId) {
    return null;
  }

  final eventData = _mapFrom(event['data']);
  if (eventData == null || eventData['type'] != 'message') {
    return null;
  }

  final data = _mapFrom(eventData['data']);
  if (data == null) {
    return null;
  }

  final messageUser = _mapFrom(data['user']);
  final senderId = _stringFrom(messageUser?['id']) ?? eventUserId;
  if (senderId != null && currentUserId != null && senderId == currentUserId) {
    return null;
  }

  final body = sanitizeNotificationText(
    _stringFrom(data['content'] ?? data['message'] ?? data['text']),
  );
  if (body.isEmpty) {
    return null;
  }

  final senderName = sanitizeNotificationText(
    _stringFrom(messageUser?['name'] ?? eventUser?['name']),
    fallback: 'New message',
    maxLength: 80,
  );
  final channel = _mapFrom(event['channel']);
  final channelType = _stringFrom(channel?['type']);
  final channelName = sanitizeNotificationText(
    _stringFrom(channel?['name']),
    maxLength: 48,
  );
  final displayTitle = channelType == 'dm' || channelName.isEmpty
      ? senderName
      : '$senderName (#$channelName)';

  return OpenWebUINotification(
    kind: OpenWebUINotificationKind.channel,
    id: channelId,
    title: '$displayTitle - Open WebUI',
    body: body,
    payload: encodeOpenWebUINotificationPayload(
      OpenWebUINotificationPayload(
        kind: OpenWebUINotificationKind.channel,
        id: channelId,
      ),
    ),
  );
}

String encodeOpenWebUINotificationPayload(
  OpenWebUINotificationPayload payload,
) {
  return jsonEncode({
    'source': 'openwebui',
    'kind': payload.kind.name,
    'id': payload.id,
  });
}

OpenWebUINotificationPayload? decodeOpenWebUINotificationPayload(
  String? payload,
) {
  if (payload == null || payload.isEmpty) {
    return null;
  }
  try {
    final decoded = jsonDecode(payload);
    if (decoded is! Map || decoded['source'] != 'openwebui') {
      return null;
    }
    final kindName = decoded['kind']?.toString();
    final id = decoded['id']?.toString().trim();
    if (id == null || id.isEmpty) {
      return null;
    }
    final kind = switch (kindName) {
      'chat' => OpenWebUINotificationKind.chat,
      'channel' => OpenWebUINotificationKind.channel,
      _ => null,
    };
    if (kind == null) {
      return null;
    }
    return OpenWebUINotificationPayload(kind: kind, id: id);
  } catch (_) {
    return null;
  }
}

String sanitizeNotificationText(
  String? raw, {
  String fallback = '',
  int maxLength = 180,
}) {
  var text = raw?.trim() ?? '';
  if (text.isEmpty) {
    return fallback;
  }

  text = text
      .replaceAll(RegExp(r'```[\s\S]*?```'), ' ')
      .replaceAllMapped(
        RegExp(r'!\[([^\]]*)\]\([^)]+\)'),
        (match) => match.group(1) ?? '',
      )
      .replaceAllMapped(
        RegExp(r'\[([^\]]+)\]\([^)]+\)'),
        (match) => match.group(1) ?? '',
      )
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll(RegExp(r'[#>*_`~]+'), ' ')
      .replaceAll(RegExp(r'[\u0000-\u001f\u007f]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  if (text.isEmpty) {
    return fallback;
  }
  if (text.length <= maxLength) {
    return text;
  }
  return '${text.substring(0, maxLength - 3).trimRight()}...';
}

Map<String, dynamic>? _mapFrom(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  return null;
}

String? _stringFrom(Object? value) {
  if (value == null) {
    return null;
  }
  final string = value.toString().trim();
  return string.isEmpty ? null : string;
}
