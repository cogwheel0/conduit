import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../../core/models/conversation.dart';
import '../../../core/persistence/persistence_keys.dart';
import '../../../core/persistence/preferences_store.dart';

/// Runtime-only proof that a native Hermes conversation shell was minted by
/// this process.
///
/// `Conversation.metadata` can originate from OpenWebUI and is therefore not
/// an ownership signal. An [Expando] cannot be reconstructed by serialized
/// metadata, while still allowing locally created immutable conversation
/// copies to inherit the mark at explicit, trusted copy sites.
final Expando<bool> _nativeHermesConversations = Expando<bool>(
  'native-hermes-conversation',
);

Conversation markNativeHermesConversation(Conversation conversation) {
  _nativeHermesConversations[conversation] = true;
  return conversation;
}

bool isNativeHermesConversation(Conversation? conversation) =>
    conversation != null && _nativeHermesConversations[conversation] == true;

/// Propagates native provenance across one app-owned immutable update.
///
/// Callers must invoke this only while copying an already trusted native
/// shell. It deliberately does not infer trust from ids or metadata because a
/// server can serialize both.
Conversation inheritNativeHermesConversationProvenance(
  Conversation source,
  Conversation target,
) {
  if (isNativeHermesConversation(source)) {
    _nativeHermesConversations[target] = true;
  }
  return target;
}

/// Bounded, content-free proof for reusing a Hermes session embedded in an
/// OpenWebUI-owned conversation.
///
/// The OpenWebUI conversation and message payloads are server-controlled, so
/// their serialized Hermes fields are only candidates. Reuse additionally
/// requires this separately stored digest of the certified storage/account,
/// exact conversation, exact assistant message, session, and Hermes
/// connection principal.
final class HermesMixedSessionBindingTrustStore {
  HermesMixedSessionBindingTrustStore._();

  static const int maxRecords = 512;
  static const int maxRecordsPerConversation = 32;
  static final Set<String> _runtimeRecords = <String>{};
  static final Set<String> _blockedScopes = <String>{};
  static Future<void> _durableMutationQueue = Future<void>.value();
  static final Expando<int> _runtimeObjectIds = Expando<int>(
    'hermes-mixed-session-owner',
  );
  static int _nextRuntimeObjectId = 0;

  /// A restart-stable identity for one certified OpenWebUI database owner.
  /// [tokenFingerprint] is already a one-way account-owner marker and is
  /// hashed again with the logical server and user ids before storage.
  static String durableStorageAccountIdentity({
    required String serverId,
    required String userId,
    required String tokenFingerprint,
  }) => _identity('d1', <String>[serverId, userId, tokenFingerprint]);

  /// Collision-free process-local fallback for unmanaged test databases.
  /// Production OpenWebUI databases always use
  /// [durableStorageAccountIdentity].
  static String runtimeStorageAccountIdentity({
    required Object database,
    required Object authSessionEpoch,
  }) => _identity('r1', <String>[
    _runtimeObjectId(database).toString(),
    _runtimeObjectId(authSessionEpoch).toString(),
  ]);

  static bool trusts({
    required String storageAccountIdentity,
    required String conversationId,
    required String assistantMessageId,
    required String sessionId,
    required String connectionIdentity,
    String? responseId,
    String? runId,
    String? transportMode,
  }) {
    final record = _record(
      storageAccountIdentity: storageAccountIdentity,
      conversationId: conversationId,
      assistantMessageId: assistantMessageId,
      sessionId: sessionId,
      connectionIdentity: connectionIdentity,
      responseId: responseId,
      runId: runId,
      transportMode: transportMode,
    );
    if (record == null) return false;
    if (_blockedScopes.any(record.startsWith)) return false;
    if (record.startsWith('r1:')) return _runtimeRecords.contains(record);
    if (!PreferencesStore.isReady) return false;
    return (PreferencesStore.getStringList(
              PreferenceKeys.hermesMixedSessionBindingTrust,
            ) ??
            const <String>[])
        .contains(record);
  }

  static Future<void> remember({
    required String storageAccountIdentity,
    required String conversationId,
    required String assistantMessageId,
    required String sessionId,
    required String connectionIdentity,
    String? responseId,
    String? runId,
    String? transportMode,
  }) async {
    final record = _record(
      storageAccountIdentity: storageAccountIdentity,
      conversationId: conversationId,
      assistantMessageId: assistantMessageId,
      sessionId: sessionId,
      connectionIdentity: connectionIdentity,
      responseId: responseId,
      runId: runId,
      transportMode: transportMode,
    );
    if (record == null) return;
    if (_blockedScopes.any(record.startsWith)) return;
    if (record.startsWith('r1:')) {
      _runtimeRecords
        ..remove(record)
        ..add(record);
      _boundRuntimeRecords();
      return;
    }
    if (!PreferencesStore.isReady) return;

    await _serializeDurableMutation(() async {
      if (_blockedScopes.any(record.startsWith)) return;
      final records = <String>[
        for (final existing
            in PreferencesStore.getStringList(
                  PreferenceKeys.hermesMixedSessionBindingTrust,
                ) ??
                const <String>[])
          if (_isWellFormedRecord(existing) && existing != record) existing,
        record,
      ];
      final perConversationBounded = _boundRecordsPerConversation(records);
      final bounded = perConversationBounded.length <= maxRecords
          ? perConversationBounded
          : perConversationBounded.sublist(
              perConversationBounded.length - maxRecords,
            );
      await PreferencesStore.putChecked(
        PreferenceKeys.hermesMixedSessionBindingTrust,
        bounded,
      );
    });
  }

  /// Revokes every binding for one exact conversation before its remote delete.
  /// The checked write intentionally happens first: losing safe continuity is
  /// preferable to deleting the chat while leaving replayable local proof.
  static Future<void> forgetConversation({
    required String storageAccountIdentity,
    required String conversationId,
  }) async {
    final prefix = _conversationScope(storageAccountIdentity, conversationId);
    if (prefix == null) return;
    _blockedScopes.add(prefix);
    _runtimeRecords.removeWhere((record) => record.startsWith(prefix));
    if (storageAccountIdentity.startsWith('r1:')) {
      return;
    }
    await _serializeDurableMutation(
      () => _removeDurableRecords((record) => record.startsWith(prefix)),
    );
  }

  /// Revokes an account's bindings before its certified database owner marker
  /// is removed.
  static Future<void> forgetStorageAccount(
    String storageAccountIdentity,
  ) async {
    final identityParts = storageAccountIdentity.split(':');
    if (identityParts.length != 2 ||
        (identityParts.first != 'd1' && identityParts.first != 'r1') ||
        !_isSha256Digest(identityParts.last)) {
      return;
    }
    final prefix = '$storageAccountIdentity:';
    _blockedScopes.add(prefix);
    _runtimeRecords.removeWhere((record) => record.startsWith(prefix));
    if (storageAccountIdentity.startsWith('r1:')) {
      return;
    }
    await _serializeDurableMutation(
      () => _removeDurableRecords((record) => record.startsWith(prefix)),
    );
  }

  @visibleForTesting
  static void debugResetRuntimeState() {
    _runtimeRecords.clear();
    _blockedScopes.clear();
  }

  static String _identity(String kind, List<String> components) =>
      '$kind:${_digest(jsonEncode(components))}';

  static int _runtimeObjectId(Object object) =>
      _runtimeObjectIds[object] ??= ++_nextRuntimeObjectId;

  static String? _record({
    required String storageAccountIdentity,
    required String conversationId,
    required String assistantMessageId,
    required String sessionId,
    required String connectionIdentity,
    required String? responseId,
    required String? runId,
    required String? transportMode,
  }) {
    final identityParts = storageAccountIdentity.split(':');
    if (identityParts.length != 2 ||
        (identityParts.first != 'd1' && identityParts.first != 'r1') ||
        !_isSha256Digest(identityParts.last)) {
      return null;
    }
    final values = <String>[
      conversationId,
      assistantMessageId,
      sessionId,
      connectionIdentity,
    ];
    if (values.any((value) => value.trim().isEmpty || value.length > 4096)) {
      return null;
    }
    if (<String?>[responseId, runId, transportMode].any(
      (value) => value != null && (value.trim().isEmpty || value.length > 4096),
    )) {
      return null;
    }
    return <String>[
      ...identityParts,
      for (final value in values) _digest(value),
      _optionalDigest(responseId),
      _optionalDigest(runId),
      _optionalDigest(transportMode),
    ].join(':');
  }

  static String? _conversationScope(
    String storageAccountIdentity,
    String conversationId,
  ) {
    final identityParts = storageAccountIdentity.split(':');
    if (identityParts.length != 2 ||
        (identityParts.first != 'd1' && identityParts.first != 'r1') ||
        !_isSha256Digest(identityParts.last) ||
        conversationId.trim().isEmpty ||
        conversationId.length > 4096) {
      return null;
    }
    return '$storageAccountIdentity:${_digest(conversationId)}:';
  }

  static Future<void> _removeDurableRecords(
    bool Function(String record) remove,
  ) async {
    if (!PreferencesStore.isReady) {
      throw StateError(
        'Preferences are unavailable for Hermes trust revocation',
      );
    }
    final retained = <String>[
      for (final record
          in PreferencesStore.getStringList(
                PreferenceKeys.hermesMixedSessionBindingTrust,
              ) ??
              const <String>[])
        if (_isWellFormedRecord(record) && !remove(record)) record,
    ];
    await PreferencesStore.putChecked(
      PreferenceKeys.hermesMixedSessionBindingTrust,
      retained.isEmpty ? null : retained,
    );
  }

  static Future<void> _serializeDurableMutation(
    Future<void> Function() mutation,
  ) {
    final operation = _durableMutationQueue.then((_) => mutation());
    _durableMutationQueue = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  static String _digest(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  static String _optionalDigest(String? value) =>
      _digest(jsonEncode(<Object?>[value == null, value]));

  static bool _isWellFormedRecord(String value) {
    final parts = value.split(':');
    return parts.length == 9 &&
        (parts.first == 'd1' || parts.first == 'r1') &&
        parts.skip(1).every(_isSha256Digest);
  }

  static bool _isSha256Digest(String value) =>
      value.length == 64 && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

  static List<String> _boundRecordsPerConversation(List<String> records) {
    final retainedReversed = <String>[];
    final countsByScope = <String, int>{};
    for (final record in records.reversed) {
      final parts = record.split(':');
      if (parts.length != 9) continue;
      final scope = parts.take(3).join(':');
      final count = countsByScope[scope] ?? 0;
      if (count >= maxRecordsPerConversation) continue;
      countsByScope[scope] = count + 1;
      retainedReversed.add(record);
    }
    return retainedReversed.reversed.toList(growable: false);
  }

  static void _boundRuntimeRecords() {
    final bounded = _boundRecordsPerConversation(
      _runtimeRecords.toList(growable: false),
    );
    final retained = bounded.length <= maxRecords
        ? bounded
        : bounded.sublist(bounded.length - maxRecords);
    _runtimeRecords
      ..clear()
      ..addAll(retained);
  }
}
