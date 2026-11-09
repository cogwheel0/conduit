import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/features/hermes/services/hermes_identifier.dart';
import 'package:conduit_core/features/hermes/services/hermes_message_mapper.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// Earlier messages of the Hermes chats that REST copies continue, saved on
/// this device.
///
/// Hermes' API server keeps only the turns sent to a session, never the
/// conversation history replayed with them, and cannot seed a new session
/// with messages. A copy of another app's chat is therefore a new session
/// whose earlier messages exist only here. They are shown before the
/// session's own messages whenever it opens, so every REST turn replays them.
///
/// Records live in the always-available local database, scoped to one
/// connection identity (endpoint and principal), and are bounded in size and
/// number: the least recently opened copies go first. A full sign-out deletes
/// that database.
final class HermesCopiedHistoryStore {
  HermesCopiedHistoryStore(this._database, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// Copies whose earlier messages are kept, across all connections.
  static const int maxCopies = 32;

  /// UTF-8 bytes of JSON that one copy's earlier messages may take. The
  /// oldest messages are dropped first to fit.
  static const int maxCopyBytes = 1024 * 1024;

  /// Earlier messages one copy may keep.
  static const int maxCopyMessages = 1000;

  static const String _keyPrefix = 'hermes.copiedHistory.v1:';

  final AppDatabase _database;
  final DateTime Function() _clock;

  // Released once drained so a completed chain does not keep its creating
  // zone alive.
  Future<void>? _writes;

  // Key prefixes of the connection identities [forgetConnection] dropped,
  // one per deleted or re-addressed connection until the app restarts. A
  // save begun for one before then (an open still in flight) keeps nothing:
  // no connection can reach it again.
  final Set<String> _forgottenConnections = <String>{};

  /// Saves [messages] as the earlier messages of copy [sessionId], replacing
  /// any it had, and returns what was kept: the newest messages that fit.
  /// Nothing is stored for a connection identity that has been forgotten.
  Future<List<Map<String, dynamic>>> save({
    required String connectionIdentity,
    required String sessionId,
    required List<Map<String, dynamic>> messages,
  }) async {
    final key = _key(connectionIdentity, sessionId);
    if (key == null) return List.unmodifiable(messages);
    final connectionPrefix = _connectionPrefix(connectionIdentity.trim());
    final bounded = _bound(messages);
    await _serialize(() async {
      final dao = _database.appCacheDao;
      if (_forgottenConnections.contains(connectionPrefix)) return;
      if (bounded.messages.isEmpty) {
        await dao.deleteKey(key);
        return;
      }
      await dao.setValue(
        key,
        bounded.json,
        updatedAt: _clock().millisecondsSinceEpoch,
      );
      final keys = await dao.keysWithPrefix(_keyPrefix);
      if (keys.length > maxCopies) {
        await dao.deleteKeys(keys.sublist(maxCopies));
      }
    });
    if (bounded.messages.length < messages.length) {
      DebugLogger.info(
        'copied-history-trimmed',
        scope: 'hermes/sessions',
        data: {
          'kept': bounded.messages.length,
          'dropped': messages.length - bounded.messages.length,
        },
      );
    }
    return bounded.messages;
  }

  /// The earlier messages saved for copy [sessionId], or null when it has
  /// none. Marks the copy as recently opened.
  Future<List<Map<String, dynamic>>?> load({
    required String connectionIdentity,
    required String sessionId,
  }) async {
    final key = _key(connectionIdentity, sessionId);
    if (key == null) return null;
    final dao = _database.appCacheDao;
    final value = await dao.getValue(key);
    if (value == null) return null;
    final messages = value.length > maxCopyBytes ? null : _decode(value);
    if (messages == null) {
      await _serialize(() => dao.deleteKey(key));
      return null;
    }
    await _serialize(
      () => dao.touch(key, updatedAt: _clock().millisecondsSinceEpoch),
    );
    return messages;
  }

  /// Drops the earlier messages saved for copy [sessionId].
  Future<void> forgetSession({
    required String connectionIdentity,
    required String sessionId,
  }) async {
    final key = _key(connectionIdentity, sessionId);
    if (key == null) return;
    await _serialize(() => _database.appCacheDao.deleteKey(key));
  }

  /// Drops every copy's earlier messages for [connectionIdentity] once no
  /// saved connection has it: the connection was deleted, or edited to
  /// another endpoint or principal. Unreachable, they would still count
  /// toward [maxCopies] and push out copies a connection can still open.
  ///
  /// A save still in flight for this identity stores nothing afterwards.
  /// That relies on identities never being reused: deleted connections'
  /// ids are not, and an endpoint or principal change mints a new trust
  /// principal (see `HermesConfigController.saveConnection`), so editing a
  /// connection back to an earlier endpoint still gives a new identity.
  Future<void> forgetConnection(String connectionIdentity) async {
    final connection = connectionIdentity.trim();
    if (connection.isEmpty) return;
    final prefix = _connectionPrefix(connection);
    _forgottenConnections.add(prefix);
    await _serialize(() => _database.appCacheDao.deleteKeysWithPrefix(prefix));
  }

  static String? _key(String connectionIdentity, String sessionId) {
    final connection = connectionIdentity.trim();
    final session = validateHermesOpaqueIdentifier(sessionId);
    if (connection.isEmpty || session == null) return null;
    return '${_connectionPrefix(connection)}${_digest(session)}';
  }

  static String _connectionPrefix(String connection) =>
      '$_keyPrefix${_digest(connection)}:';

  static String _digest(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  /// The newest run of [messages] within [maxCopyMessages] and
  /// [maxCopyBytes], with its JSON.
  static ({List<Map<String, dynamic>> messages, String json}) _bound(
    List<Map<String, dynamic>> messages,
  ) {
    final kept = <Map<String, dynamic>>[];
    final encoded = <String>[];
    // Brackets plus one comma between each pair.
    var bytes = 1;
    for (var index = messages.length - 1; index >= 0; index--) {
      if (kept.length == maxCopyMessages) break;
      final String json;
      try {
        json = jsonEncode(messages[index]);
      } catch (_) {
        break;
      }
      final size = utf8.encode(json).length + 1;
      if (bytes + size > maxCopyBytes) break;
      bytes += size;
      kept.add(messages[index]);
      encoded.add(json);
    }
    return (
      messages: List.unmodifiable(kept.reversed),
      json: '[${encoded.reversed.join(',')}]',
    );
  }

  static List<Map<String, dynamic>>? _decode(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is! List || decoded.length > maxCopyMessages) return null;
      final messages = <Map<String, dynamic>>[];
      for (final entry in decoded) {
        if (entry is! Map) return null;
        messages.add(Map<String, dynamic>.from(entry));
      }
      return List.unmodifiable(messages);
    } catch (_) {
      return null;
    }
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final result = (_writes ?? Future<void>.value()).then((_) => operation());
    late final Future<void> tail;
    tail = result.catchError((_) {}).whenComplete(() {
      if (identical(_writes, tail)) _writes = null;
    });
    _writes = tail;
    return result;
  }
}

/// A copy's [saved] earlier messages followed by the [server]'s own.
///
/// When the server's messages already start with the saved ones (a Hermes
/// that stores replayed history), they are returned alone. A saved message
/// whose id the server also uses loses the id, so the chat never shows two
/// messages with one id.
List<Map<String, dynamic>> mergeHermesCopiedHistory(
  List<Map<String, dynamic>> saved,
  List<Map<String, dynamic>> server,
) {
  if (saved.isEmpty) return server;
  if (_startsWithMessages(server, saved)) return server;
  final serverIds = <Object?>{
    for (final message in server)
      if (message['id'] != null) message['id'],
  };
  return [
    for (final message in saved)
      if (serverIds.contains(message['id']))
        (Map<String, dynamic>.of(message)..remove('id'))
      else
        message,
    ...server,
  ];
}

bool _startsWithMessages(
  List<Map<String, dynamic>> messages,
  List<Map<String, dynamic>> prefix,
) {
  if (messages.length < prefix.length) return false;
  for (var index = 0; index < prefix.length; index++) {
    final a = messages[index];
    final b = prefix[index];
    if (a['role'] != b['role'] ||
        !hermesMessageContentMatches(
          a['content'] ?? a['text'],
          b['content'] ?? b['text'],
        )) {
      return false;
    }
  }
  return true;
}
