/// Parses the Open WebUI `chat:message:follow_ups` socket envelope:
/// `{chat_id, message_id, data: {type, data: {follow_ups: [...]}}}`.
/// Returns null when the event is not a usable follow-ups push.
({String messageId, List<String> followUps})? parseFollowUpsSocketEvent(
  Map<String, dynamic> event,
) {
  final data = event['data'];
  if (data is! Map || data['type'] != 'chat:message:follow_ups') {
    return null;
  }
  final messageId = (event['message_id'] ?? data['message_id'])?.toString();
  if (messageId == null || messageId.isEmpty) {
    return null;
  }
  final inner = data['data'];
  final rawFollowUps = inner is Map
      ? (inner['follow_ups'] ?? inner['followUps'])
      : null;
  if (rawFollowUps is! List) {
    return null;
  }
  final followUps = <String>[
    for (final item in rawFollowUps)
      if (item != null && item.toString().trim().isNotEmpty)
        item.toString().trim(),
  ];
  if (followUps.isEmpty) {
    return null;
  }
  return (
    messageId: messageId,
    followUps: List<String>.unmodifiable(followUps),
  );
}
