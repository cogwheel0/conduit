import '../models/app_notification.dart';

/// Pure translator from raw Open WebUI socket envelopes to [AppNotification]s.
///
/// This is the single owner of upstream event-envelope semantics: the nested
/// `data.type` / `data.data` unfolding, which event types are notifiable, the
/// terminal-frame rule for completions, and self-authored filtering. Keeping it
/// pure (no Riverpod, no IO, no clock) makes it exhaustively unit-testable
/// against captured payloads and isolates the brittle coupling to upstream's
/// schema in one place.
///
/// Every method returns `null` for anything non-notifiable — unknown types,
/// non-terminal frames, self-authored messages, malformed envelopes — and never
/// throws on unexpected shapes, so schema drift degrades to "no notification"
/// rather than a crash.
class NotificationEventClassifier {
  const NotificationEventClassifier();

  /// Classifies an event from the personal `events` socket stream.
  ///
  /// Notifiable: `chat:completion` with `done == true`. Mirrors upstream
  /// `+layout.svelte`, which alerts only on the terminal completion frame.
  AppNotification? classifyChatEvent(
    Map<String, dynamic> event, {
    required String currentUserId,
  }) {
    final envelope = _asMap(event['data']);
    if (envelope == null) return null;

    final type = envelope['type'];
    if (type != 'chat:completion') return null;

    final data = _asMap(envelope['data']);
    if (data == null) return null;

    // Only the terminal frame is user-facing; the middleware emits many
    // intermediate frames for the same response.
    if (data['done'] != true) return null;

    final chatId = _asNonEmptyString(event['chat_id']);
    if (chatId == null) return null;

    final content = _asString(data['content']);
    final title = _asString(data['title']);

    return AppNotification(
      kind: NotificationKind.chatCompletion,
      title: title,
      body: content,
      sourceId: chatId,
      // Completion frames carry no stable message id, so key on the chat plus
      // the content: a replayed identical terminal frame dedupes, while a later
      // distinct response in the same chat still notifies.
      dedupKey: 'chat:$chatId:${content.hashCode}',
    );
  }

  /// Classifies an event from the `events:channel` socket stream.
  ///
  /// Notifiable: `type == 'message'` authored by someone other than the current
  /// user. Replies, reactions, updates, deletes and channel lifecycle events are
  /// silent state refreshes upstream and yield `null` here.
  AppNotification? classifyChannelEvent(
    Map<String, dynamic> event, {
    required String currentUserId,
  }) {
    final envelope = _asMap(event['data']);
    if (envelope == null) return null;

    if (envelope['type'] != 'message') return null;

    final data = _asMap(envelope['data']);
    if (data == null) return null;

    // Require a valid author. Missing author metadata is malformed (and also
    // covers system/non-user messages we don't notify for). Never notify for
    // the user's own messages (upstream filters by author id).
    final author = _asMap(data['user']);
    final authorId = _asString(author?['id']);
    if (authorId.isEmpty || authorId == currentUserId) return null;

    final channelId = _asNonEmptyString(event['channel_id']);
    if (channelId == null) return null;

    final messageId = _asNonEmptyString(data['id']);
    final content = _asString(data['content']);

    return AppNotification(
      kind: NotificationKind.channelMessage,
      title: _channelTitle(event, author),
      body: content,
      sourceId: channelId,
      // Channel messages carry a stable id; fall back to content keying only if
      // the server omits it.
      dedupKey: messageId != null
          ? 'channel:$channelId:$messageId'
          : 'channel:$channelId:${content.hashCode}',
    );
  }

  /// Builds the headline: author name, suffixed with `(#channel)` for non-DM
  /// channels, matching upstream's `+layout.svelte` formatting.
  String _channelTitle(Map<String, dynamic> event, Map<String, dynamic>? author) {
    final authorName = _asString(author?['name']);
    final channel = _asMap(event['channel']);
    final channelType = _asString(channel?['type']);
    final channelName = _asString(channel?['name']);
    if (channelType != 'dm' && channelName.isNotEmpty) {
      return '$authorName (#$channelName)';
    }
    return authorName;
  }

  static Map<String, dynamic>? _asMap(Object? value) =>
      value is Map<String, dynamic> ? value : null;

  static String _asString(Object? value) => value is String ? value : '';

  static String? _asNonEmptyString(Object? value) =>
      value is String && value.isNotEmpty ? value : null;
}
