import 'dart:convert';

import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/services/hermes_identifier.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';

/// The longest stored [HermesSetAsideSession] read back.
const int kMaxHermesSetAsideRecordCharacters = 4096;

/// Why a chat is out of the Hermes session list.
enum HermesSetAsideKind { hidden, archived }

/// A Hermes chat this device hid or archived where no list can show it
/// again: Hermes lists no hidden chats, and the API server no archived ones.
final class HermesSetAsideSession {
  const HermesSetAsideSession({
    required this.scope,
    required this.sessionId,
    required this.title,
    required this.kind,
    this.archived = false,
  });

  /// The saved connection (or, before saved connections, the endpoint).
  final String scope;
  final String sessionId;
  final String title;
  final HermesSetAsideKind kind;

  /// A hidden chat that is archived too: shown again, it goes back to the
  /// archive, also when its flags cannot be read.
  final bool archived;

  HermesSessionSummary toSummary() => HermesSessionSummary(
    id: sessionId,
    title: title,
    hidden: kind == HermesSetAsideKind.hidden,
    archived: kind == HermesSetAsideKind.archived || archived,
  );

  String toStorage() => jsonEncode(<String, Object?>{
    'scope': scope,
    'session_id': sessionId,
    'title': title,
    'kind': kind.name,
    if (archived) 'archived': true,
  });

  static HermesSetAsideSession? fromStorage(String source) {
    if (source.length > kMaxHermesSetAsideRecordCharacters) return null;
    try {
      final value = jsonDecode(source);
      if (value is! Map) return null;
      final scope = value['scope'];
      final sessionId = validateHermesOpaqueIdentifier(value['session_id']);
      final title = validateHermesBoundedString(
        value['title'],
        maxCharacters: kMaxHermesSessionTitleCharacters,
        allowEmpty: true,
      );
      final kind = HermesSetAsideKind.values
          .where((kind) => kind.name == value['kind'])
          .firstOrNull;
      if (scope is! String ||
          scope.isEmpty ||
          sessionId == null ||
          title == null ||
          kind == null) {
        return null;
      }
      return HermesSetAsideSession(
        scope: scope,
        sessionId: sessionId,
        title: title,
        kind: kind,
        archived: value['archived'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Thrown when [HermesSetAsideSessionStore] has no room for another chat.
/// Nothing is dropped to make room: a record is the only way back to its
/// chat.
final class HermesSetAsideStoreFullException implements Exception {
  const HermesSetAsideStoreFullException();

  @override
  String toString() =>
      'Too many hidden or archived Hermes chats are kept on this device.';
}

/// Persisted [HermesSetAsideSession]s, newest last.
abstract final class HermesSetAsideSessionStore {
  /// Records kept across all connections. A new one beyond this is refused.
  static const int maxRecords = 200;

  static Future<void>? _writes;

  static List<HermesSetAsideSession> forScope(
    String scope, {
    HermesSetAsideKind? kind,
  }) => [
    for (final record in _read())
      if (record.scope == scope && (kind == null || record.kind == kind))
        record,
  ];

  /// What is kept for [sessionId] in [scope], if anything.
  static HermesSetAsideSession? find({
    required String scope,
    required String sessionId,
  }) => _read()
      .where(
        (record) => record.scope == scope && record.sessionId == sessionId,
      )
      .lastOrNull;

  /// Records [record], replacing what was kept for its session. Throws
  /// [HermesSetAsideStoreFullException] when it would be one too many, an
  /// [ArgumentError] for a record too long to read back, and whatever the
  /// preferences write throws.
  static Future<void> remember(HermesSetAsideSession record) =>
      _serialize(() async {
        // Saved, it would be dropped on read: the chat would have no way
        // back.
        if (record.toStorage().length > kMaxHermesSetAsideRecordCharacters) {
          throw ArgumentError.value(
            record.sessionId,
            'record',
            'too long to keep',
          );
        }
        final records = _read();
        final before = records.length;
        records.removeWhere(
          (candidate) =>
              candidate.scope == record.scope &&
              candidate.sessionId == record.sessionId,
        );
        if (records.length == before && records.length >= maxRecords) {
          throw const HermesSetAsideStoreFullException();
        }
        records.add(record);
        await _write(records);
      });

  static Future<void> forget({
    required String scope,
    required String sessionId,
  }) => _remove(
    (record) => record.scope == scope && record.sessionId == sessionId,
  );

  /// Forgets [record] only while it is still what is kept for its chat: a
  /// lookup that read it must not drop a newer record, such as a hidden one
  /// that replaced an archived one meanwhile.
  static Future<void> forgetRecord(HermesSetAsideSession record) => _remove(
    (kept) =>
        kept.scope == record.scope &&
        kept.sessionId == record.sessionId &&
        kept.toStorage() == record.toStorage(),
  );

  /// Replaces [record] with [replacement] only while [record] is still what
  /// is kept for its chat.
  static Future<void> replaceRecord(
    HermesSetAsideSession record,
    HermesSetAsideSession replacement,
  ) => _serialize(() async {
    final records = _read();
    final index = records.indexWhere(
      (kept) =>
          kept.scope == record.scope &&
          kept.sessionId == record.sessionId &&
          kept.toStorage() == record.toStorage(),
    );
    // One too long to read back would lose the chat: the record it would
    // replace stays.
    if (index < 0 ||
        replacement.toStorage().length > kMaxHermesSetAsideRecordCharacters) {
      return;
    }
    records[index] = replacement;
    await _write(records);
  });

  static final Set<String> _changing = {};

  /// Marks [sessionId]'s flags as being changed in [scope] while [change]
  /// runs: a lookup then leaves its record alone, since the server's flags
  /// it reads may be from before the change.
  static Future<T> whileChanging<T>({
    required String scope,
    required String sessionId,
    required Future<T> Function() change,
  }) async {
    final key = jsonEncode([scope, sessionId]);
    _changing.add(key);
    try {
      return await change();
    } finally {
      _changing.remove(key);
    }
  }

  /// Whether [sessionId]'s flags are being changed in [scope].
  static bool isChanging({required String scope, required String sessionId}) =>
      _changing.contains(jsonEncode([scope, sessionId]));

  /// Drops every record whose scope passes [test], e.g. those of a saved
  /// connection that was deleted.
  static Future<void> clearScopes(bool Function(String scope) test) =>
      _remove((record) => test(record.scope));

  static Future<void> _remove(
    bool Function(HermesSetAsideSession record) predicate,
  ) => _serialize(() async {
    final records = _read();
    final before = records.length;
    records.removeWhere(predicate);
    if (records.length != before) await _write(records);
  });

  static List<HermesSetAsideSession> _read() {
    if (!PreferencesStore.isReady) return <HermesSetAsideSession>[];
    return <HermesSetAsideSession>[
      for (final source
          in PreferencesStore.getStringList(
                PreferenceKeys.hermesSetAsideSessions,
              ) ??
              const <String>[])
        ?HermesSetAsideSession.fromStorage(source),
    ];
  }

  /// Checked: a record is only as good as its write, and the caller changes
  /// the server only once it is saved.
  static Future<void> _write(List<HermesSetAsideSession> records) =>
      PreferencesStore.putChecked(
        PreferenceKeys.hermesSetAsideSessions,
        records.map((record) => record.toStorage()).toList(growable: false),
      );

  static Future<void> _serialize(Future<void> Function() operation) {
    final result = (_writes ?? Future<void>.value()).then((_) => operation());
    late final Future<void> tail;
    tail = result.catchError((_) {}).whenComplete(() {
      if (identical(_writes, tail)) _writes = null;
    });
    _writes = tail;
    return result;
  }
}
