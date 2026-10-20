/// Which personal connections each in-flight chat request handed to the server.
///
/// Open WebUI answers a direct tool by asking the session that sent the chat
/// request to call the tool server (`execute:tool`). The callback names a chat,
/// an assistant message and a server, but nothing there proves this client
/// offered that server to that completion: a configured, enabled connection is
/// not authority by itself. The request builders record what they actually sent
/// here, at the point the request leaves, and a callback is only honoured for
/// the chat, message and session that sent it, and for the connections and
/// operations it advertised.
///
/// The store is bounded and belongs to one socket service, so it goes away with
/// the account or server that owned that service.
library;

import 'dart:collection';

import 'package:conduit_core/features/integrations/personal_tool_execution.dart';

class PersonalToolAdmissions {
  /// Requests kept at once; the oldest is dropped first.
  static const int maxRequests = 32;

  final LinkedHashMap<String, List<PersonalToolAdmission>> _requests =
      LinkedHashMap<String, List<PersonalToolAdmission>>();

  static String _key(String? chatId, String messageId, String sessionId) =>
      '$sessionId\u0000${chatId ?? ''}\u0000$messageId';

  /// Records the connections the request for [messageId] in [chatId] sent
  /// over socket session [sessionId]. A repeated request replaces its earlier
  /// record. Nothing is recorded for a request that sent no connection.
  void admit({
    required String? chatId,
    required String messageId,
    required String sessionId,
    required Iterable<PersonalToolAdmission> connections,
  }) {
    final key = _key(chatId, messageId, sessionId);
    _requests.remove(key);
    final list = List<PersonalToolAdmission>.unmodifiable(connections);
    if (list.isEmpty) return;
    _requests[key] = list;
    while (_requests.length > maxRequests) {
      _requests.remove(_requests.keys.first);
    }
  }

  /// The connections admitted for exactly this chat, message and session, or
  /// none.
  List<PersonalToolAdmission> admittedFor({
    required String? chatId,
    required String? messageId,
    required String sessionId,
  }) {
    if (messageId == null) return const <PersonalToolAdmission>[];
    return _requests[_key(chatId, messageId, sessionId)] ??
        const <PersonalToolAdmission>[];
  }

  /// Ends the admissions of a finished completion.
  void retire({
    required String? chatId,
    required String messageId,
    required String sessionId,
  }) => _requests.remove(_key(chatId, messageId, sessionId));

  void clear() => _requests.clear();
}
