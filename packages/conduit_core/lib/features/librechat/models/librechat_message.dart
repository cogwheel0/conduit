import 'dart:convert';

import 'package:meta/meta.dart';

/// The parent id LibreChat gives the first message of a conversation.
const String kLibreChatRootParentId = '00000000-0000-0000-0000-000000000000';

/// [text] as a person reads it. LibreChat ends some error texts with the
/// model provider's own error as JSON (`The model provider could not
/// complete this request.` then `{"type":"upstream_model_error",
/// "status":400,"message":"..."}`): that part shows as just its message.
String libreChatReadableError(String text) {
  final start = text.indexOf('{');
  if (start < 0) return text;
  final Object? details;
  try {
    details = jsonDecode(text.substring(start));
  } on FormatException {
    return text;
  }
  final message = details is Map ? details['message'] : null;
  if (message is! String || message.trim().isEmpty) return text;
  final lead = text.substring(0, start).trim();
  return lead.isEmpty ? message.trim() : '$lead\n${message.trim()}';
}

/// A message as LibreChat stores and sends it (`TMessage`).
///
/// The raw map stays the source of truth; the getters read what Conduit uses.
/// An assistant reply's [content] is the ordered list of parts it was built
/// from (text, reasoning, tool calls, images, ...); [text] is its plain-text
/// aggregate, and the only body older messages have.
@immutable
final class LibreChatMessage {
  const LibreChatMessage(this.raw);

  final Map<String, dynamic> raw;

  static LibreChatMessage? fromJson(Object? json) {
    if (json is! Map) return null;
    final map = Map<String, dynamic>.from(json);
    final id = map['messageId'];
    if (id is! String || id.isEmpty) return null;
    return LibreChatMessage(map);
  }

  String get messageId => raw['messageId'] as String;

  /// The parent message, or null for the first message.
  String? get parentMessageId {
    final parent = raw['parentMessageId'];
    if (parent is! String || parent.isEmpty) return null;
    return parent == kLibreChatRootParentId ? null : parent;
  }

  String? get conversationId => _string('conversationId');

  bool get isCreatedByUser => raw['isCreatedByUser'] == true;

  String get text => _string('text') ?? '';

  /// The reply's parts, or empty when the message only has [text].
  List<Map<String, dynamic>> get content {
    final value = raw['content'];
    if (value is! List) return const <Map<String, dynamic>>[];
    return [
      for (final part in value)
        if (part is Map) Map<String, dynamic>.from(part),
    ];
  }

  String? get sender => _string('sender');
  String? get model => _string('model');
  String? get endpoint => _string('endpoint');
  bool get isError => raw['error'] == true;
  bool get isUnfinished => raw['unfinished'] == true;
  String? get finishReason => _string('finish_reason');

  /// Files the user attached (`TFile` maps).
  List<Map<String, dynamic>> get files => _maps('files');

  /// What tools produced: images, web search results, code output files.
  List<Map<String, dynamic>> get attachments => _maps('attachments');

  DateTime? get createdAt => _date('createdAt');
  DateTime? get updatedAt => _date('updatedAt');

  String? _string(String key) {
    final value = raw[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  List<Map<String, dynamic>> _maps(String key) {
    final value = raw[key];
    if (value is! List) return const <Map<String, dynamic>>[];
    return [
      for (final item in value)
        if (item is Map) Map<String, dynamic>.from(item),
    ];
  }

  DateTime? _date(String key) {
    final value = raw[key];
    return value is String ? DateTime.tryParse(value)?.toUtc() : null;
  }
}

/// A conversation as LibreChat lists it (`TConversation`).
@immutable
final class LibreChatConversation {
  const LibreChatConversation(this.raw);

  final Map<String, dynamic> raw;

  static LibreChatConversation? fromJson(Object? json) {
    if (json is! Map) return null;
    final map = Map<String, dynamic>.from(json);
    final id = map['conversationId'];
    if (id is! String || id.isEmpty) return null;
    return LibreChatConversation(map);
  }

  String get conversationId => raw['conversationId'] as String;

  String get title {
    final value = raw['title'];
    return value is String && value.trim().isNotEmpty ? value : 'New Chat';
  }

  String? get endpoint => _string('endpoint');
  String? get endpointType => _string('endpointType');
  String? get model => _string('model');
  String? get agentId => _string('agent_id');
  String? get spec => _string('spec');
  String? get iconUrl => _string('iconURL');
  bool get isArchived => raw['isArchived'] == true;
  bool get pinned => raw['pinned'] == true;

  DateTime? get createdAt => _date('createdAt');
  DateTime? get updatedAt => _date('updatedAt');

  String? _string(String key) {
    final value = raw[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  DateTime? _date(String key) {
    final value = raw[key];
    return value is String ? DateTime.tryParse(value)?.toUtc() : null;
  }
}

/// One page of `GET /api/convos`.
@immutable
final class LibreChatConversationPage {
  const LibreChatConversationPage(this.conversations, this.nextCursor);

  final List<LibreChatConversation> conversations;

  /// Where the next page starts, or null on the last page.
  final String? nextCursor;
}
