import 'dart:convert';

import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/services/hermes_identifier.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';

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
  });

  /// The saved connection (or, before saved connections, the endpoint).
  final String scope;
  final String sessionId;
  final String title;
  final HermesSetAsideKind kind;

  HermesSessionSummary toSummary() => HermesSessionSummary(
    id: sessionId,
    title: title,
    hidden: kind == HermesSetAsideKind.hidden,
    archived: kind == HermesSetAsideKind.archived,
  );

  String toStorage() => jsonEncode(<String, Object?>{
    'scope': scope,
    'session_id': sessionId,
    'title': title,
    'kind': kind.name,
  });

  static HermesSetAsideSession? fromStorage(String source) {
    if (source.length > 4096) return null;
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
      );
    } catch (_) {
      return null;
    }
  }
}

/// Persisted [HermesSetAsideSession]s, newest last.
abstract final class HermesSetAsideSessionStore {
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

  /// Records [record], replacing what was kept for its session.
  static Future<void> remember(HermesSetAsideSession record) =>
      _serialize(() async {
        final records = _read()
          ..removeWhere(
            (candidate) =>
                candidate.scope == record.scope &&
                candidate.sessionId == record.sessionId,
          )
          ..add(record);
        await _write(records);
      });

  static Future<void> forget({
    required String scope,
    required String sessionId,
  }) => _remove(
    (record) => record.scope == scope && record.sessionId == sessionId,
  );

  static Future<void> clearScope(String scope) =>
      _remove((record) => record.scope == scope);

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

  static Future<void> _write(List<HermesSetAsideSession> records) {
    final bounded = records.length <= maxRecords
        ? records
        : records.sublist(records.length - maxRecords);
    return PreferencesStore.put(
      PreferenceKeys.hermesSetAsideSessions,
      bounded.map((record) => record.toStorage()).toList(growable: false),
    );
  }

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
