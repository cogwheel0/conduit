import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:riverpod/riverpod.dart';
import 'package:meta/meta.dart';

import '../persistence/persistence_keys.dart';
import '../persistence/preferences_store.dart';

typedef OpenWebUiAccountOwnerMarker = ({
  String tokenFingerprint,
  String userId,
});

abstract interface class OpenWebUiAccountOwnerMarkerStore {
  OpenWebUiAccountOwnerMarker? read(String serverId);

  Future<void> write(String serverId, OpenWebUiAccountOwnerMarker marker);

  Future<void> remove(String serverId);
}

final class PreferencesOpenWebUiAccountOwnerMarkerStore
    implements OpenWebUiAccountOwnerMarkerStore {
  const PreferencesOpenWebUiAccountOwnerMarkerStore();

  String _key(String serverId) {
    final serverFingerprint = sha256.convert(utf8.encode(serverId)).toString();
    return '${PreferenceKeys.openWebUiAccountOwnerPrefix}:$serverFingerprint';
  }

  @override
  OpenWebUiAccountOwnerMarker? read(String serverId) {
    if (!PreferencesStore.isReady) return null;
    final encoded = PreferencesStore.getString(_key(serverId));
    if (encoded == null || encoded.isEmpty) return null;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map || decoded['version'] != 1) return null;
      final tokenFingerprint = decoded['tokenFingerprint'];
      final userId = decoded['userId'];
      if (tokenFingerprint is! String ||
          tokenFingerprint.isEmpty ||
          userId is! String ||
          userId.isEmpty) {
        return null;
      }
      return (tokenFingerprint: tokenFingerprint, userId: userId);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(
    String serverId,
    OpenWebUiAccountOwnerMarker marker,
  ) async {
    if (!PreferencesStore.isReady) {
      throw StateError('Preferences are unavailable for account ownership');
    }
    await PreferencesStore.put(
      _key(serverId),
      jsonEncode(<String, Object>{
        'version': 1,
        'tokenFingerprint': marker.tokenFingerprint,
        'userId': marker.userId,
      }),
    );
  }

  @override
  Future<void> remove(String serverId) async {
    if (!PreferencesStore.isReady) {
      throw StateError('Preferences are unavailable for account ownership');
    }
    await PreferencesStore.remove(_key(serverId));
  }
}

@visibleForTesting
String openWebUiAccountTokenFingerprint(String token) =>
    sha256.convert(utf8.encode(token)).toString();

OpenWebUiAccountOwnerMarker? openWebUiAccountOwnerMarker({
  required String token,
  required String? userId,
}) {
  final normalizedUserId = userId?.trim();
  if (token.isEmpty || normalizedUserId == null || normalizedUserId.isEmpty) {
    return null;
  }
  return (
    tokenFingerprint: openWebUiAccountTokenFingerprint(token),
    userId: normalizedUserId,
  );
}

bool openWebUiAccountOwnerMarkerMatches({
  required OpenWebUiAccountOwnerMarker? marker,
  required String token,
  required String? userId,
}) {
  final expected = openWebUiAccountOwnerMarker(token: token, userId: userId);
  return expected != null && marker == expected;
}

bool openWebUiAccountOwnerMarkerMatchesToken({
  required OpenWebUiAccountOwnerMarker? marker,
  required String token,
}) =>
    marker != null &&
    marker.tokenFingerprint == openWebUiAccountTokenFingerprint(token);

final openWebUiAccountOwnerMarkerStoreProvider =
    Provider<OpenWebUiAccountOwnerMarkerStore>(
      (ref) => const PreferencesOpenWebUiAccountOwnerMarkerStore(),
    );

/// Token/user pairs the server itself has accepted during this process.
///
/// An owner marker pins an account's database to a user *and* a token, so a
/// new token for the same user -- a silent re-login after the old one
/// expired, or a sign-in that lands in an existing account -- no longer
/// matches it. Purging the database there would throw away that user's
/// offline history and queued sends for nothing. This ledger is the proof
/// that lets those cases through: a pair is recorded only after a request to
/// the server succeeded with that token and returned that user, never from a
/// cached user, and it lives only in memory.
final class OpenWebUiValidatedIdentityLedger {
  static const int _capacity = 16;
  final List<String> _entries = <String>[];

  void record({required String token, required String userId}) {
    final key = _key(token, userId);
    if (key == null) return;
    _entries
      ..remove(key)
      ..add(key);
    if (_entries.length > _capacity) _entries.removeAt(0);
  }

  bool vouchesFor({required String token, required String? userId}) {
    final key = _key(token, userId);
    return key != null && _entries.contains(key);
  }

  void clear() => _entries.clear();

  static String? _key(String token, String? userId) {
    final normalized = userId?.trim();
    if (token.isEmpty || normalized == null || normalized.isEmpty) return null;
    return '${openWebUiAccountTokenFingerprint(token)}:$normalized';
  }
}

final openWebUiValidatedIdentityLedgerProvider =
    Provider<OpenWebUiValidatedIdentityLedger>(
      (ref) => OpenWebUiValidatedIdentityLedger(),
    );

/// Whether [marker] may be carried over to [token]: it names the same user,
/// and the server has accepted [token] for that user in this process.
bool openWebUiAccountOwnerMarkerCarriesOver({
  required OpenWebUiAccountOwnerMarker? marker,
  required String token,
  required String? userId,
  required OpenWebUiValidatedIdentityLedger ledger,
}) {
  final normalized = userId?.trim();
  return marker != null &&
      normalized != null &&
      marker.userId == normalized &&
      ledger.vouchesFor(token: token, userId: normalized);
}

final openWebUiCachedAccountOwnerMismatchProvider =
    NotifierProvider<OpenWebUiCachedAccountOwnerMismatch, bool>(
      OpenWebUiCachedAccountOwnerMismatch.new,
    );

class OpenWebUiCachedAccountOwnerMismatch extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}
