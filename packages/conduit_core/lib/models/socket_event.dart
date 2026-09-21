import 'package:meta/meta.dart';

/// Identifies which socket channel emitted a conversation delta.
enum ConversationDeltaSource { chat, channel }

/// Describes the parameters needed to bind a socket-backed stream.
@immutable
class ConversationDeltaRequest {
  const ConversationDeltaRequest._(
    this.source, {
    this.conversationId,
    this.sessionId,
    this.requireFocus = true,
  });

  const ConversationDeltaRequest.chat({
    String? conversationId,
    String? sessionId,
    bool requireFocus = true,
  }) : this._(
         ConversationDeltaSource.chat,
         conversationId: conversationId,
         sessionId: sessionId,
         requireFocus: requireFocus,
       );

  const ConversationDeltaRequest.channel({
    String? conversationId,
    String? sessionId,
    bool requireFocus = true,
  }) : this._(
         ConversationDeltaSource.channel,
         conversationId: conversationId,
         sessionId: sessionId,
         requireFocus: requireFocus,
       );

  final ConversationDeltaSource source;
  final String? conversationId;
  final String? sessionId;
  final bool requireFocus;

  @override
  int get hashCode =>
      Object.hash(source, conversationId, sessionId, requireFocus);

  @override
  bool operator ==(Object other) {
    return other is ConversationDeltaRequest &&
        other.source == source &&
        other.conversationId == conversationId &&
        other.sessionId == sessionId &&
        other.requireFocus == requireFocus;
  }

  @override
  String toString() {
    return 'ConversationDeltaRequest(source: $source, conversationId: '
        '$conversationId, sessionId: $sessionId, requireFocus: '
        '$requireFocus)';
  }
}

/// Carries a socket event payload along with metadata.
@immutable
class ConversationDelta {
  const ConversationDelta({
    required this.source,
    required this.raw,
    this.type,
    this.payload,
    this.ack,
  });

  factory ConversationDelta.fromSocketEvent(
    ConversationDeltaSource source,
    Map<String, dynamic> event,
    void Function(dynamic response)? ack,
  ) {
    final data = event['data'];
    String? type;
    Map<String, dynamic>? payload;
    if (data is Map<String, dynamic>) {
      type = data['type']?.toString();
      final dynamic inner = data['data'];
      if (inner is Map<String, dynamic>) {
        payload = inner;
      }
    }

    return ConversationDelta(
      source: source,
      raw: event,
      type: type,
      payload: payload,
      ack: ack,
    );
  }

  final ConversationDeltaSource source;
  final Map<String, dynamic> raw;
  final String? type;
  final Map<String, dynamic>? payload;
  final void Function(dynamic response)? ack;
}
