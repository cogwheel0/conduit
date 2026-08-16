import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/auth/webview_cookie_helper.dart';
import '../../../core/persistence/persistence_keys.dart';
import '../../../core/persistence/preferences_store.dart';

@visibleForTesting
Set<String> hermesDashboardCookieIdentityDelta({
  required Set<String> current,
  required Set<String> baseline,
  Set<String> retainedNames = const {},
}) => {
  for (final identity in current)
    if (!baseline.contains(identity) ||
        retainedNames.contains(
          identity
              .split('\u0000')
              .first
              .replaceFirst(RegExp(r'^__(?:Host|Secure)-'), ''),
        ))
      identity,
};

final class HermesDashboardCookieStore {
  const HermesDashboardCookieStore._();

  static final Map<String, int> _generations = {};

  static int begin(String origin) {
    final uri = Uri.tryParse(origin);
    if (uri == null || uri.host.isEmpty) return 0;
    final key = _originKey(uri);
    return _generations[key] = (_generations[key] ?? 0) + 1;
  }

  static Future<Set<String>> snapshot(String origin) =>
      WebViewCookieHelper.cookieIdentitiesForOrigin(origin);

  static Future<void> register(
    String origin, {
    required int generation,
    Set<String> baseline = const {},
    Set<String> retainedNames = const {},
  }) => WebViewCookieHelper.runSerializedDataOperation(() async {
    final uri = Uri.tryParse(origin);
    if (uri == null || uri.host.isEmpty) return;
    final key = _originKey(uri);
    if (_generations[key] != generation) return;
    final identities = hermesDashboardCookieIdentityDelta(
      current: await snapshot(origin),
      baseline: baseline,
      retainedNames: retainedNames,
    );
    final registry = _registry();
    final merged = {...?registry[key], ...identities}.toList();
    registry[key] = merged.length <= 64
        ? merged
        : merged.sublist(merged.length - 64);
    await _write(registry);
  });

  static Future<bool> clear(String origin) async {
    final uri = Uri.tryParse(origin);
    if (uri == null || uri.host.isEmpty) return true;
    final key = _originKey(uri);
    _generations[key] = (_generations[key] ?? 0) + 1;
    return WebViewCookieHelper.runSerializedDataOperation(() async {
      final registry = _registry();
      final success =
          await WebViewCookieHelper.deleteCookieIdentitiesForOriginUnlocked(
            origin,
            registry[key]?.toSet() ?? const {},
          );
      if (success && registry.remove(key) != null) await _write(registry);
      return success;
    });
  }

  static String _originKey(Uri uri) {
    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    return '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}:$port';
  }

  static Map<String, List<String>> _registry() {
    try {
      final source = PreferencesStore.getString(
        PreferenceKeys.hermesDashboardCookieIdentities,
      );
      final decoded = source == null ? null : jsonDecode(source);
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is List)
            entry.key as String: (entry.value as List)
                .whereType<String>()
                .take(64)
                .toList(growable: false),
      };
    } catch (_) {
      return {};
    }
  }

  static Future<void> _write(Map<String, List<String>> registry) =>
      PreferencesStore.putChecked(
        PreferenceKeys.hermesDashboardCookieIdentities,
        registry.isEmpty ? null : jsonEncode(registry),
      );
}
