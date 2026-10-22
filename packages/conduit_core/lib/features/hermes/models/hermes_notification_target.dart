import 'dart:convert';

/// A content-free notification destination scoped to one connection principal.
/// Never interpret a session id against a different server or signed-in user.
class HermesNotificationTarget {
  const HermesNotificationTarget({
    required this.sessionId,
    required this.connectionIdentity,
  });

  final String sessionId;
  final String connectionIdentity;
  static const prefix = 'conduit-hermes-notification:';

  String encode() =>
      '$prefix${base64Url.encode(utf8.encode(jsonEncode({'session': sessionId, 'connection': connectionIdentity})))}';

  static HermesNotificationTarget? decode(String sourceId) {
    if (!sourceId.startsWith(prefix) || sourceId.length > 4096) return null;
    try {
      final value = jsonDecode(
        utf8.decode(base64Url.decode(sourceId.substring(prefix.length))),
      );
      if (value is! Map ||
          value['session'] is! String ||
          value['connection'] is! String ||
          (value['session'] as String).isEmpty ||
          (value['connection'] as String).isEmpty) {
        return null;
      }
      return HermesNotificationTarget(
        sessionId: value['session'],
        connectionIdentity: value['connection'],
      );
    } catch (_) {
      return null;
    }
  }
}
