/// What the account list shows about accounts the app is not using.
///
/// Only the active account has its user loaded, from its own database. The
/// others are listed from this small, non-secret record kept in preferences:
/// who the account is (name, email, avatar) and when it was last used. It is
/// written when an account is certified and when the app switches to it, and
/// never holds anything that authenticates.
library;

import 'dart:convert';

import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/utils/debug_logger.dart';

final class OpenWebUiAccountSummary {
  const OpenWebUiAccountSummary({
    this.name,
    this.email,
    this.profileImage,
    this.lastUsedAt,
  });

  final String? name;
  final String? email;

  /// The avatar as the server reported it: usually a server-relative path,
  /// resolved against whichever endpoint the account is using.
  final String? profileImage;
  final DateTime? lastUsedAt;

  OpenWebUiAccountSummary copyWith({
    String? name,
    String? email,
    String? profileImage,
    DateTime? lastUsedAt,
  }) => OpenWebUiAccountSummary(
    name: name ?? this.name,
    email: email ?? this.email,
    profileImage: profileImage ?? this.profileImage,
    lastUsedAt: lastUsedAt ?? this.lastUsedAt,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    if (name != null) 'name': name,
    if (email != null) 'email': email,
    if (profileImage != null) 'profileImage': profileImage,
    if (lastUsedAt != null) 'lastUsedAt': lastUsedAt!.toIso8601String(),
  };

  factory OpenWebUiAccountSummary.fromJson(Map<String, Object?> json) {
    String? text(Object? value) =>
        value is String && value.isNotEmpty ? value : null;
    final lastUsed = text(json['lastUsedAt']);
    return OpenWebUiAccountSummary(
      name: text(json['name']),
      email: text(json['email']),
      profileImage: text(json['profileImage']),
      lastUsedAt: lastUsed == null ? null : DateTime.tryParse(lastUsed),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OpenWebUiAccountSummary &&
      other.name == name &&
      other.email == email &&
      other.profileImage == profileImage &&
      other.lastUsedAt == lastUsedAt;

  @override
  int get hashCode => Object.hash(name, email, profileImage, lastUsedAt);
}

final openWebUiAccountSummariesProvider =
    NotifierProvider<
      OpenWebUiAccountSummaries,
      Map<String, OpenWebUiAccountSummary>
    >(OpenWebUiAccountSummaries.new);

class OpenWebUiAccountSummaries
    extends Notifier<Map<String, OpenWebUiAccountSummary>> {
  @override
  Map<String, OpenWebUiAccountSummary> build() => _read();

  /// Records who [accountId] turned out to be.
  Future<void> recordUser(String accountId, User user) {
    final name = user.name?.trim();
    final previous = state[accountId] ?? const OpenWebUiAccountSummary();
    return _write(accountId, (_) {
      return OpenWebUiAccountSummary(
        name: name == null || name.isEmpty ? user.username : name,
        email: user.email.isEmpty ? previous.email : user.email,
        profileImage: user.profileImage ?? previous.profileImage,
        lastUsedAt: previous.lastUsedAt,
      );
    });
  }

  /// Marks [accountId] as the one just switched to.
  Future<void> touch(String accountId, {DateTime? at}) => _write(
    accountId,
    (previous) => (previous ?? const OpenWebUiAccountSummary()).copyWith(
      lastUsedAt: at ?? DateTime.now(),
    ),
  );

  Future<void> forget(String accountId) async {
    if (!state.containsKey(accountId)) return;
    final next = Map.of(state)..remove(accountId);
    state = Map.unmodifiable(next);
    await _persist(next);
  }

  /// Reloads from preferences, after something outside this notifier (a full
  /// sign-out, an account's data being cleared) changed them.
  void reload() => state = _read();

  Future<void> _write(
    String accountId,
    OpenWebUiAccountSummary Function(OpenWebUiAccountSummary? previous) update,
  ) async {
    final next = Map.of(state)..[accountId] = update(state[accountId]);
    state = Map.unmodifiable(next);
    await _persist(next);
  }

  Future<void> _persist(Map<String, OpenWebUiAccountSummary> summaries) async {
    if (!PreferencesStore.isReady) return;
    try {
      await PreferencesStore.put(
        PreferenceKeys.openWebUiAccountSummaries,
        jsonEncode({
          for (final entry in summaries.entries)
            entry.key: entry.value.toJson(),
        }),
      );
    } catch (error) {
      DebugLogger.warning(
        'account-summaries-write-failed',
        scope: 'auth/accounts',
        data: {'errorType': error.runtimeType.toString()},
      );
    }
  }

  static Map<String, OpenWebUiAccountSummary> _read() {
    if (!PreferencesStore.isReady) return const {};
    final raw = PreferencesStore.getString(
      PreferenceKeys.openWebUiAccountSummaries,
    );
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      return Map.unmodifiable({
        for (final entry in decoded.entries)
          if (entry.value is Map)
            entry.key.toString(): OpenWebUiAccountSummary.fromJson(
              (entry.value as Map).map(
                (key, value) => MapEntry(key.toString(), value),
              ),
            ),
      });
    } catch (_) {
      return const {};
    }
  }
}
