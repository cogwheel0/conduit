import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

final openWebUiCachedAccountOwnerMismatchProvider =
    NotifierProvider<OpenWebUiCachedAccountOwnerMismatch, bool>(
      OpenWebUiCachedAccountOwnerMismatch.new,
    );

class OpenWebUiCachedAccountOwnerMismatch extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool value) => state = value;
}
