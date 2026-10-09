import 'dart:convert';

import '../models/app_notification.dart';
import '../models/notification_scope.dart';

/// Maps a decrypted `cp/1` push payload (docs/push/PROTOCOL.md §2) received
/// for the subscription of [scope] to the [AppNotification] it describes.
///
/// Returns null for anything that isn't a valid `cp/1` payload: another
/// version, an unknown kind or source, a missing dedup key, a source that
/// doesn't match [scope] (an Open WebUI payload on a Hermes subscription, say),
/// or a reply, channel message or scheduled task without the id it points at.
/// Unknown keys are ignored. Never throws.
///
/// The app-wide dedup key is `<scope>|<dk>`, the same key the app's own
/// socket, Hermes and Direct notifications build, so one event never notifies
/// twice.
AppNotification? appNotificationFromCp1(
  Object? payload, {
  required String scope,
}) {
  if (payload is! Map) return null;
  final parsedScope = NotificationScope.tryParse(scope);
  if (parsedScope == null) return null;

  final version = payload['v'];
  if (version is! int || version != 1) return null;

  final source = payload['src'];
  final fromOpenWebUi = switch (source) {
    'owui' => true,
    'hermes' => false,
    _ => null,
  };
  if (fromOpenWebUi == null) return null;
  if (fromOpenWebUi
      ? parsedScope is! OpenWebUiNotificationScope
      : parsedScope is! HermesNotificationScope) {
    return null;
  }

  final dedupKey = payload['dk'];
  if (dedupKey is! String || dedupKey.isEmpty) return null;

  final rawIds = payload['ids'];
  if (rawIds != null && rawIds is! Map) return null;
  String? id(String key) {
    final value = rawIds is Map ? rawIds[key] : null;
    return value is String && value.isNotEmpty ? value : null;
  }

  for (final key in _textKeys) {
    final value = payload[key];
    if (value != null && value is! String) return null;
  }
  final title = payload['t'] as String?;
  final body = payload['b'] as String?;
  final author = payload['a'] as String?;
  final group = payload['g'] as String?;
  final nonce = payload['n'] as String?;

  final NotificationKind kind;
  final String? sourceId;
  switch (payload['k']) {
    case 'reply':
      kind = NotificationKind.chatCompletion;
      sourceId = fromOpenWebUi ? id('chat') : id('session');
    case 'reply_failed':
      kind = NotificationKind.replyFailed;
      sourceId = fromOpenWebUi ? id('chat') : id('session');
    case 'channel':
      if (!fromOpenWebUi) return null;
      kind = NotificationKind.channelMessage;
      sourceId = id('channel');
    case 'cron':
      if (fromOpenWebUi) return null;
      kind = NotificationKind.scheduledTask;
      sourceId = id('job');
    case 'test':
      kind = NotificationKind.pushTest;
      sourceId = nonce ?? '';
    default:
      return null;
  }
  if (sourceId == null) return null;

  return AppNotification(
    kind: kind,
    scope: parsedScope.value,
    title: kind == NotificationKind.channelMessage
        ? _channelTitle(author ?? '', title ?? '')
        : title ?? '',
    body: body ?? '',
    sourceId: sourceId,
    dedupKey: parsedScope.dedupKey(dedupKey),
    group: group == null || group.isEmpty ? null : group,
  );
}

/// [appNotificationFromCp1] for the decrypted UTF-8 JSON text of a payload.
/// Returns null when [plaintext] isn't JSON.
AppNotification? appNotificationFromCp1Json(
  String plaintext, {
  required String scope,
}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(plaintext);
  } on FormatException {
    return null;
  }
  return appNotificationFromCp1(decoded, scope: scope);
}

/// The optional text keys: title, preview, author, group and test nonce.
const List<String> _textKeys = ['t', 'b', 'a', 'g', 'n'];

/// The channel headline the socket path builds too: the author, then the
/// channel (`#name`) in brackets when the payload names one.
String _channelTitle(String author, String channel) {
  if (author.isEmpty) return channel;
  if (channel.isEmpty) return author;
  return '$author ($channel)';
}
