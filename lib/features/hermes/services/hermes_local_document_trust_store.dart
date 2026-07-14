import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/persistence/persistence_keys.dart';
import '../../../core/persistence/preferences_store.dart';

/// Metadata key binding a server-side session id to one endpoint/principal
/// epoch. Session ids without a matching binding are never reused.
const String kHermesConnectionIdentityMetadataKey =
    'conduit.hermesConnectionIdentity';

/// Persists bounded, content-free provenance for Hermes document prompts.
///
/// Hermes's session-history endpoint returns message content but deliberately
/// omits client metadata. Keeping digests of both the server-assigned message
/// id, exact prompt text, and each locally prepared document envelope lets the
/// history mapper distinguish attachments Conduit actually sent from
/// user-authored text that merely looks like one, without retaining extracted
/// document contents in preferences.
final class HermesLocalDocumentTrustStore {
  HermesLocalDocumentTrustStore._();

  static const int maxRecords = 512;
  static const int maxRecordsPerSession = 64;
  static Future<void>? _mutationQueue;
  static final Map<String, int> _blockedSessionScopes = <String, int>{};
  static final Map<String, int> _deletionBlockEpochs = <String, int>{};
  static int _nextBlockEpoch = 0;

  /// Returns a non-secret identity for one configured Hermes principal.
  /// [principalId] is a random preference epoch rotated on connection edits;
  /// it must never be derived from credentials.
  static String connectionIdentity({
    required String endpointIdentity,
    required String principalId,
  }) => sha256
      .convert(utf8.encode(jsonEncode(<String>[endpointIdentity, principalId])))
      .toString();

  static String messageDigest(String promptText) =>
      sha256.convert(utf8.encode(promptText)).toString();

  static String documentTrustKey({
    required String messageId,
    required String promptText,
    required String documentEnvelope,
    required int startOffset,
  }) {
    final messageIdDigest = sha256.convert(utf8.encode(messageId)).toString();
    final documentDigest = messageDigest(documentEnvelope);
    final offsetDigest = messageDigest(startOffset.toString());
    return '$messageIdDigest:${messageDigest(promptText)}:'
        '$offsetDigest:$documentDigest';
  }

  static Set<String> trustedDocumentKeys({
    required String connectionIdentity,
    required String sessionId,
  }) {
    if (!PreferencesStore.isReady) return const <String>{};
    final prefix = _scopePrefix(connectionIdentity, sessionId);
    if (prefix == null) return const <String>{};
    if (_blockedSessionScopes.containsKey(prefix)) return const <String>{};

    return <String>{
      for (final record
          in PreferencesStore.getStringList(
                PreferenceKeys.hermesLocalDocumentTrust,
              ) ??
              const <String>[])
        if (record.startsWith(prefix) &&
            _isDocumentTrustKey(record.substring(prefix.length)))
          record.substring(prefix.length),
    };
  }

  static Future<void> remember({
    required String connectionIdentity,
    required String sessionId,
    required String messageId,
    required String promptText,
    required Iterable<String> documentEnvelopes,
  }) async {
    if (!PreferencesStore.isReady ||
        !promptText.contains('<<<BEGIN_HERMES_UNTRUSTED_REFERENCE_')) {
      return;
    }
    final prefix = _scopePrefix(connectionIdentity, sessionId);
    if (prefix == null) return;
    if (_blockedSessionScopes.containsKey(prefix)) return;

    if (messageId.trim().isEmpty) return;
    final envelopes = documentEnvelopes.toList(growable: false);
    if (envelopes.isEmpty) return;
    final renderedSuffix = envelopes.join('\n\n');
    if (!promptText.endsWith(renderedSuffix)) return;
    var startOffset = promptText.length - renderedSuffix.length;
    final newRecords = <String>{};
    for (final envelope in envelopes) {
      if (!envelope.contains('<<<BEGIN_HERMES_UNTRUSTED_REFERENCE_')) return;
      newRecords.add(
        '$prefix${documentTrustKey(messageId: messageId, promptText: promptText, documentEnvelope: envelope, startOffset: startOffset)}',
      );
      startOffset += envelope.length + 2;
    }
    if (newRecords.isEmpty) return;
    await _serializeMutation(() async {
      if (!PreferencesStore.isReady ||
          _blockedSessionScopes.containsKey(prefix)) {
        return;
      }
      final records = <String>[
        for (final existing
            in PreferencesStore.getStringList(
                  PreferenceKeys.hermesLocalDocumentTrust,
                ) ??
                const <String>[])
          if (_isWellFormedRecord(existing) && !newRecords.contains(existing))
            existing,
        ...newRecords,
      ];
      final sessionBounded = _boundRecordsPerSession(records);
      final bounded = sessionBounded.length <= maxRecords
          ? sessionBounded
          : sessionBounded.sublist(sessionBounded.length - maxRecords);
      await PreferencesStore.putChecked(
        PreferenceKeys.hermesLocalDocumentTrust,
        bounded,
      );
    });
  }

  /// Rebinds source trust to the fresh server message ids assigned by a fork.
  ///
  /// [messageIdMap] must come from a fail-closed source/target history
  /// comparison. Only records whose source message digest has an exact mapping
  /// are copied; existing target records are purged first.
  static Future<void> rebindForkedSession({
    required String connectionIdentity,
    required String sourceSessionId,
    required String targetSessionId,
    required Map<String, String> messageIdMap,
  }) async {
    final sourcePrefix = _scopePrefix(connectionIdentity, sourceSessionId);
    final targetPrefix = _scopePrefix(connectionIdentity, targetSessionId);
    if (sourcePrefix == null || targetPrefix == null) return;
    final blockEpoch = _blockScope(targetPrefix);
    final stableMessageIdMap = Map<String, String>.of(messageIdMap);
    await _serializeMutation(() async {
      _requirePreferencesReady();

      final sourceIdDigests = <String, String>{};
      final targetIds = <String>{};
      for (final entry in stableMessageIdMap.entries) {
        final sourceId = entry.key.trim();
        final targetId = entry.value.trim();
        if (sourceId.isEmpty || targetId.isEmpty || !targetIds.add(targetId)) {
          await _purgeScope(targetPrefix);
          _completeScopeRevocation(targetPrefix, blockEpoch);
          return;
        }
        final sourceDigest = messageDigest(sourceId);
        if (sourceIdDigests.containsKey(sourceDigest)) {
          await _purgeScope(targetPrefix);
          _completeScopeRevocation(targetPrefix, blockEpoch);
          return;
        }
        sourceIdDigests[sourceDigest] = messageDigest(targetId);
      }

      final records = <String>[
        for (final existing
            in PreferencesStore.getStringList(
                  PreferenceKeys.hermesLocalDocumentTrust,
                ) ??
                const <String>[])
          if (_isWellFormedRecord(existing)) existing,
      ];
      final retained = <String>[
        for (final existing in records)
          if (!existing.startsWith(targetPrefix)) existing,
      ];
      final cloned = <String>[];
      for (final existing in records) {
        if (!existing.startsWith(sourcePrefix)) continue;
        final key = existing.substring(sourcePrefix.length);
        final parts = key.split(':');
        if (parts.length != 4) continue;
        final targetMessageDigest = sourceIdDigests[parts.first];
        if (targetMessageDigest == null) continue;
        cloned.add(
          '$targetPrefix$targetMessageDigest:${parts.sublist(1).join(':')}',
        );
      }
      // Forking is a convenience copy, not a new trust event. Never evict the
      // source or unrelated sessions to make room for it; copy only the newest
      // records that fit in the remaining global budget.
      final available = maxRecords - retained.length;
      if (available <= 0) {
        await _writeRecords(retained);
        _completeScopeRevocation(targetPrefix, blockEpoch);
        return;
      }
      final cloneLimit = available < maxRecordsPerSession
          ? available
          : maxRecordsPerSession;
      final selectedClones = cloned.length <= cloneLimit
          ? cloned
          : cloned.sublist(cloned.length - cloneLimit);
      await _writeRecords(<String>[...retained, ...selectedClones]);
      _completeScopeRevocation(targetPrefix, blockEpoch);
    });
  }

  static Future<void> forgetSession({
    required String connectionIdentity,
    required String sessionId,
  }) async {
    final prefix = _scopePrefix(connectionIdentity, sessionId);
    if (prefix == null) return;
    _blockScope(prefix);
    _deletionBlockEpochs.remove(prefix);
    await _serializeMutation(() async {
      _requirePreferencesReady();
      await _purgeScope(prefix);
    });
  }

  static void beginSessionDeletion({
    required String connectionIdentity,
    required String sessionId,
  }) {
    final prefix = _scopePrefix(connectionIdentity, sessionId);
    if (prefix != null) {
      _deletionBlockEpochs[prefix] = _blockScope(prefix);
    }
  }

  static void cancelSessionDeletion({
    required String connectionIdentity,
    required String sessionId,
  }) {
    final prefix = _scopePrefix(connectionIdentity, sessionId);
    if (prefix == null) return;
    final deletionEpoch = _deletionBlockEpochs.remove(prefix);
    if (deletionEpoch != null &&
        _blockedSessionScopes[prefix] == deletionEpoch) {
      _blockedSessionScopes.remove(prefix);
    }
  }

  /// Durably clears stale provenance before allowing a newly created session
  /// that happens to reuse an old server id.
  static Future<void> prepareNewSession({
    required String connectionIdentity,
    required String sessionId,
  }) async {
    final prefix = _scopePrefix(connectionIdentity, sessionId);
    if (prefix == null) return;
    final blockEpoch = _blockScope(prefix);
    await _serializeMutation(() async {
      _requirePreferencesReady();
      await _purgeScope(prefix);
      _completeScopeRevocation(prefix, blockEpoch);
    });
  }

  static void debugResetRuntimeState() {
    _blockedSessionScopes.clear();
    _deletionBlockEpochs.clear();
    _nextBlockEpoch = 0;
    // Do not retain a queue tail captured by a previous widget test's
    // fake-async zone. Production also benefits from releasing completed
    // chains instead of keeping their originating zone alive indefinitely.
    _mutationQueue = null;
  }

  static Future<T> _serializeMutation<T>(Future<T> Function() mutation) {
    final previous = _mutationQueue;
    final result = previous == null
        ? Future<T>.sync(mutation)
        : previous.then<T>((_) => mutation());
    late final Future<void> tail;
    tail = result.then<void>((_) {}, onError: (_, _) {}).whenComplete(() {
      if (identical(_mutationQueue, tail)) _mutationQueue = null;
    });
    _mutationQueue = tail;
    return result;
  }

  static int _blockScope(String prefix) {
    final epoch = ++_nextBlockEpoch;
    _blockedSessionScopes[prefix] = epoch;
    return epoch;
  }

  static void _completeScopeRevocation(String prefix, int blockEpoch) {
    if (_blockedSessionScopes[prefix] != blockEpoch) return;
    _blockedSessionScopes.remove(prefix);
    final deletionEpoch = _deletionBlockEpochs[prefix];
    if (deletionEpoch != null && deletionEpoch <= blockEpoch) {
      _deletionBlockEpochs.remove(prefix);
    }
  }

  static void _requirePreferencesReady() {
    if (!PreferencesStore.isReady) {
      throw StateError('Hermes document trust storage is unavailable.');
    }
  }

  static String? _scopePrefix(String connectionIdentity, String sessionId) {
    final connection = connectionIdentity.trim();
    final session = sessionId.trim();
    if (connection.isEmpty || session.isEmpty) return null;
    final connectionDigest = sha256.convert(utf8.encode(connection)).toString();
    final sessionDigest = sha256.convert(utf8.encode(session)).toString();
    return '$connectionDigest:$sessionDigest:';
  }

  static bool _isWellFormedRecord(String value) {
    final parts = value.split(':');
    return parts.length == 6 && parts.every(_isSha256Digest);
  }

  static bool _isDocumentTrustKey(String value) {
    final parts = value.split(':');
    return parts.length == 4 && parts.every(_isSha256Digest);
  }

  static bool _isSha256Digest(String value) =>
      value.length == 64 && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

  static List<String> _boundRecordsPerSession(List<String> records) {
    final retainedReversed = <String>[];
    final countsByScope = <String, int>{};
    for (final record in records.reversed) {
      final secondSeparator = record.indexOf(':', record.indexOf(':') + 1);
      if (secondSeparator < 0) continue;
      final scope = record.substring(0, secondSeparator + 1);
      final count = countsByScope[scope] ?? 0;
      if (count >= maxRecordsPerSession) continue;
      countsByScope[scope] = count + 1;
      retainedReversed.add(record);
    }
    return retainedReversed.reversed.toList(growable: false);
  }

  static Future<void> _purgeScope(String prefix) async {
    final records = <String>[
      for (final existing
          in PreferencesStore.getStringList(
                PreferenceKeys.hermesLocalDocumentTrust,
              ) ??
              const <String>[])
        if (_isWellFormedRecord(existing) && !existing.startsWith(prefix))
          existing,
    ];
    await _writeRecords(records);
  }

  static Future<void> _writeRecords(List<String> records) =>
      PreferencesStore.putChecked(
        PreferenceKeys.hermesLocalDocumentTrust,
        records.isEmpty ? null : records,
      );
}
