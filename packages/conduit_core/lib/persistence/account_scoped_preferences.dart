/// Preferences that belong to one Open WebUI account.
///
/// Settings that name a server's data -- a default model id, pinned models,
/// a server voice -- mean nothing on another account, so they are stored
/// under a per-account key. Look-and-feel settings stay device-wide. With no
/// Open WebUI account (Direct or Hermes only) the device-wide key is used, so
/// those setups keep working exactly as before.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

import 'package:conduit_core/utils/debug_logger.dart';

import 'persistence_keys.dart';
import 'preferences_store.dart';

const String _accountScopeSeparator = '@acct:';

String _encodedAccountId(String accountId) =>
    base64Url.encode(utf8.encode(accountId)).replaceAll('=', '');

/// [baseKey] for [accountId], or [baseKey] itself when there is no account.
String accountScopedPreferenceKey(String baseKey, String? accountId) {
  if (accountId == null || accountId.isEmpty) return baseKey;
  return '$baseKey$_accountScopeSeparator${_encodedAccountId(accountId)}';
}

/// The settings stored per account.
const Set<String> accountScopedPreferenceKeys = <String>{
  PreferenceKeys.defaultModel,
  PreferenceKeys.pinnedModels,
  PreferenceKeys.quickPills,
  PreferenceKeys.openRouterImageGenerationModel,
  PreferenceKeys.ttsServerVoiceId,
  PreferenceKeys.ttsServerVoiceName,
  // These three mirror the server's own user settings.
  PreferenceKeys.notificationsEnabled,
  PreferenceKeys.notificationSound,
  PreferenceKeys.notificationSoundAlways,
  PreferenceKeys.sidebarActiveTab,
  PreferenceKeys.temporaryChatByDefault,
};

/// The Open WebUI account whose preferences apply: the stored active
/// account, read at the moment of the call. A read or write therefore lands
/// under the account that was active when it started, even if a switch
/// completes while it is still in flight.
String? currentPreferenceAccountId() {
  final accountId = PreferencesStore.getString(PreferenceKeys.activeServerId);
  return accountId == null || accountId.isEmpty ? null : accountId;
}

/// The key [baseKey] is read from right now: the active account's own when
/// it is a scoped setting, falling back to the device-wide value until that
/// account's one-time copy has run.
String scopedPreferenceReadKey(String baseKey) {
  if (!accountScopedPreferenceKeys.contains(baseKey)) return baseKey;
  final accountId = currentPreferenceAccountId();
  if (accountId == null) return baseKey;
  final scoped = accountScopedPreferenceKey(baseKey, accountId);
  if (PreferencesStore.containsKey(scoped)) return scoped;
  final migrated =
      PreferencesStore.getBool(PreferenceKeys.accountScopedSettingsMigrated) ==
      true;
  return migrated ? scoped : baseKey;
}

/// The key [baseKey] is written to right now.
String scopedPreferenceWriteKey(String baseKey) {
  if (!accountScopedPreferenceKeys.contains(baseKey)) return baseKey;
  return accountScopedPreferenceKey(baseKey, currentPreferenceAccountId());
}

/// The account the device-wide settings are being copied into, claimed
/// before the copy's first write. Another account certified while those
/// writes are under way would otherwise start a second copy, and both would
/// inherit them. A copy that fails keeps the claim, so that account alone
/// tries again; one that finishes leaves it to the flag.
String? _deviceSettingsCopyClaim;

/// The copy under way, shared by every call made for its account meanwhile.
Future<void>? _deviceSettingsCopyRunning;

/// Held as the claim once the account the device settings were being copied
/// to is removed without the copy marked done: no account takes them over.
const _deviceSettingsGone = '';

/// Forgets the copy's claim, which lives as long as the process does.
@visibleForTesting
void debugResetDeviceSettingsCopy() {
  _deviceSettingsCopyClaim = null;
  _deviceSettingsCopyRunning = null;
}

/// Copies the device-wide values of [accountScopedPreferenceKeys] into
/// [accountId], once, the first time an account is active after per-account
/// settings arrived. The device-wide values stay as the fallback used when
/// no Open WebUI account is active.
Future<void> migrateDeviceSettingsIntoAccount(String accountId) {
  if (!PreferencesStore.isReady ||
      PreferencesStore.getBool(PreferenceKeys.accountScopedSettingsMigrated) ==
          true) {
    return Future<void>.value();
  }
  final claim = _deviceSettingsCopyClaim;
  if (claim != null && claim != accountId) return Future<void>.value();
  // The copy already under way for this account is the one to wait for:
  // two would each take the other finishing for the account's removal.
  final running = _deviceSettingsCopyRunning;
  if (running != null) return running;
  _deviceSettingsCopyClaim = accountId;
  final copy = _copyDeviceSettings(accountId);
  _deviceSettingsCopyRunning = copy;
  return copy.whenComplete(() {
    if (identical(_deviceSettingsCopyRunning, copy)) {
      _deviceSettingsCopyRunning = null;
    }
  });
}

Future<void> _copyDeviceSettings(String accountId) async {
  // An account removed while this runs ends the copy. What was written for
  // it goes too: its own clear may have run before those writes landed.
  final written = <String>[];
  for (final key in accountScopedPreferenceKeys) {
    if (_deviceSettingsCopyClaim != accountId) break;
    final scoped = accountScopedPreferenceKey(key, accountId);
    if (PreferencesStore.containsKey(scoped)) continue;
    final value = PreferencesStore.getRaw(key);
    // Checked: a copy that did not land must not be marked done, or the
    // account would stop reading the device value it never received.
    if (value != null) {
      await PreferencesStore.putChecked(scoped, value);
      written.add(scoped);
    }
  }
  if (_deviceSettingsCopyClaim != accountId) {
    for (final key in written) {
      await PreferencesStore.remove(key);
    }
    return;
  }
  await PreferencesStore.putChecked(
    PreferenceKeys.accountScopedSettingsMigrated,
    true,
  );
  _deviceSettingsCopyClaim = null;
}

/// Finishes [accountId]'s one-time copy of the device settings before the
/// settings [clearing] are cleared, and fails when it cannot. A setting
/// cleared before the copy ran would read as the device value again, and
/// the copy would later bring it back; a clear that cannot stick says so.
/// Only a setting with a device value can come back that way.
Future<void> settleDeviceSettingsCopy(
  String? accountId, {
  required Iterable<String> clearing,
}) async {
  if (accountId == null || !PreferencesStore.isReady) return;
  bool copied() =>
      PreferencesStore.getBool(PreferenceKeys.accountScopedSettingsMigrated) ==
      true;
  if (copied() ||
      !clearing.any(
        (key) =>
            accountScopedPreferenceKeys.contains(key) &&
            PreferencesStore.getRaw(key) != null,
      )) {
    return;
  }
  final claim = _deviceSettingsCopyClaim;
  if (claim != null && claim != accountId) {
    // Another account's copy, when one is under way, decides it.
    await _deviceSettingsCopyRunning?.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
  } else {
    await migrateDeviceSettingsIntoAccount(accountId);
  }
  if (!copied()) {
    throw StateError('The device settings could not be copied to the account.');
  }
}

/// Deletes everything [accountId] keeps in preferences: its scoped settings,
/// its socket transport options, its cached feature flags and its summary.
///
/// Every removal is tried, and checked: one the store refuses would leave
/// that account's data on disk behind a sign-out that seemed to work. The
/// first failure is reported once the rest have run.
Future<void> clearOpenWebUiAccountPreferences(String accountId) async {
  if (!PreferencesStore.isReady) return;
  Object? firstError;
  StackTrace? firstStackTrace;
  Future<void> attempt(Future<void> Function() write) async {
    try {
      await write();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
  }

  if (_deviceSettingsCopyClaim == accountId) {
    // The device settings were being copied to this account, the first in
    // use after the upgrade, which they belonged to. They go with it rather
    // than pass to the next account, which starts from the defaults. Until
    // that is marked, no account takes them over in this run.
    _deviceSettingsCopyClaim = _deviceSettingsGone;
    await attempt(() async {
      await PreferencesStore.putChecked(
        PreferenceKeys.accountScopedSettingsMigrated,
        true,
      );
      _deviceSettingsCopyClaim = null;
    });
  }
  final suffix = '$_accountScopeSeparator${_encodedAccountId(accountId)}';
  for (final key in PreferencesStore.keys().toList(growable: false)) {
    if (key.endsWith(suffix)) {
      await attempt(() => PreferencesStore.putChecked(key, null));
    }
  }
  await attempt(
    () => PreferencesStore.putChecked(
      '${PreferenceKeys.transportOptionsPrefix}:'
      '${base64Url.encode(utf8.encode(accountId))}',
      null,
    ),
  );

  final rawFlags = PreferencesStore.getString(
    PreferenceKeys.serverFeatureAvailability,
  );
  if (rawFlags != null && rawFlags.isNotEmpty) {
    Map<String, Object?>? kept;
    var changed = false;
    try {
      final decoded = jsonDecode(rawFlags);
      if (decoded is Map) {
        final prefix = '$accountId::';
        kept = <String, Object?>{
          for (final entry in decoded.entries)
            if (!entry.key.toString().startsWith(prefix))
              entry.key.toString(): entry.value,
        };
        changed = kept.length != decoded.length;
      }
    } catch (error) {
      DebugLogger.warning(
        'account-feature-flags-clear-failed',
        scope: 'persistence/account-scope',
        data: {'errorType': error.runtimeType.toString()},
      );
    }
    if (changed) {
      await attempt(
        () => PreferencesStore.putChecked(
          PreferenceKeys.serverFeatureAvailability,
          jsonEncode(kept),
        ),
      );
    }
  }

  final rawSummaries = PreferencesStore.getString(
    PreferenceKeys.openWebUiAccountSummaries,
  );
  if (rawSummaries != null && rawSummaries.isNotEmpty) {
    Object? decoded;
    var unreadable = false;
    try {
      decoded = jsonDecode(rawSummaries);
    } catch (_) {
      unreadable = true;
    }
    final summaries = decoded is Map ? decoded : null;
    if (unreadable) {
      await attempt(
        () => PreferencesStore.putChecked(
          PreferenceKeys.openWebUiAccountSummaries,
          null,
        ),
      );
    } else if (summaries != null && summaries.containsKey(accountId)) {
      summaries.remove(accountId);
      await attempt(
        () => PreferencesStore.putChecked(
          PreferenceKeys.openWebUiAccountSummaries,
          jsonEncode(summaries),
        ),
      );
    }
  }
  if (firstError != null) {
    Error.throwWithStackTrace(firstError!, firstStackTrace!);
  }
}
