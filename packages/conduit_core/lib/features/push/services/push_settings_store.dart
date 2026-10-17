import 'dart:convert';
import 'dart:math';

import 'package:conduit_core/features/push/models/push_status.dart';
import 'package:conduit_core/features/push/models/push_subscription_record.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';

/// Push's device-wide preferences.
///
/// None of these are account-scoped (`accountScopedPreferenceKeys` does not
/// list them): the master toggle covers every account and connection, and
/// each per-target record is keyed by its scope.
class PushSettingsStore {
  const PushSettingsStore();

  bool get enabled =>
      PreferencesStore.getBool(PreferenceKeys.pushEnabled) ?? false;

  Future<void> setEnabled(bool value) =>
      PreferencesStore.put(PreferenceKeys.pushEnabled, value);

  /// This install's random id, created on first use.
  Future<String> deviceId() async {
    final existing = PreferencesStore.getString(PreferenceKeys.pushDeviceId);
    if (existing != null && existing.isNotEmpty) return existing;
    final id = randomPushToken();
    await PreferencesStore.put(PreferenceKeys.pushDeviceId, id);
    return id;
  }

  /// Replaces this install's id with a new one, for a device whose
  /// preferences were restored from another device's backup: servers
  /// replace a device's entries by its id, so two devices with one id would
  /// evict each other.
  Future<String> resetDeviceId() async {
    final id = randomPushToken();
    await PreferencesStore.put(PreferenceKeys.pushDeviceId, id);
    return id;
  }

  PushAndroidTransport? get androidTransport => PushAndroidTransport.tryParse(
    PreferencesStore.getString(PreferenceKeys.pushAndroidTransport),
  );

  String? get distributor {
    final value = PreferencesStore.getString(
      PreferenceKeys.pushAndroidDistributor,
    );
    return value == null || value.isEmpty ? null : value;
  }

  Future<void> setAndroidTransport(
    PushAndroidTransport? transport, {
    String? distributor,
  }) => PreferencesStore.putAll({
    PreferenceKeys.pushAndroidTransport: transport?.name,
    PreferenceKeys.pushAndroidDistributor: distributor,
  });

  Map<String, PushSubscriptionRecord> records() {
    final decoded = _decode(
      PreferencesStore.getString(PreferenceKeys.pushTargets),
    );
    if (decoded is! Map) return {};
    return {
      for (final entry in decoded.entries)
        if (entry.key is String)
          entry.key as String: PushSubscriptionRecord.fromJson(entry.value),
    };
  }

  Future<void> saveRecords(Map<String, PushSubscriptionRecord> records) =>
      PreferencesStore.put(
        PreferenceKeys.pushTargets,
        records.isEmpty
            ? null
            : jsonEncode({
                for (final entry in records.entries)
                  entry.key: entry.value.toJson(),
              }),
      );

  List<PushTombstone> tombstones() {
    final decoded = _decode(
      PreferencesStore.getString(PreferenceKeys.pushTombstones),
    );
    if (decoded is! List) return [];
    return decoded
        .map(PushTombstone.fromJson)
        .whereType<PushTombstone>()
        .toList();
  }

  Future<void> saveTombstones(List<PushTombstone> tombstones) =>
      PreferencesStore.put(
        PreferenceKeys.pushTombstones,
        tombstones.isEmpty
            ? null
            : jsonEncode([
                for (final tombstone in tombstones) tombstone.toJson(),
              ]),
      );

  DateTime? get lastFullReconcile {
    final value = PreferencesStore.getInt(PreferenceKeys.pushLastFullReconcile);
    return value == null ? null : DateTime.fromMillisecondsSinceEpoch(value);
  }

  Future<void> setLastFullReconcile(DateTime? at) => PreferencesStore.put(
    PreferenceKeys.pushLastFullReconcile,
    at?.millisecondsSinceEpoch,
  );

  static Object? _decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }
}

/// 16 random bytes, base64url without padding: device ids and test nonces.
String randomPushToken([Random? random]) {
  final source = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => source.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}
