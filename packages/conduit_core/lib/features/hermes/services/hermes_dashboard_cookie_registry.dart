/// Which WebView cookies Hermes' dashboard sign-in created, per dashboard
/// origin, so disconnecting Hermes removes those cookies and nothing else on a
/// shared host (an Open WebUI session, for one).
///
/// The registry is persisted (`PreferenceKeys.hermesDashboardCookieIdentities`).
/// Reading the WebView's cookie store and deleting cookies stays in the app's
/// `HermesDashboardCookieStore`, which drives the WebView.
library;

import 'dart:convert';

import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:meta/meta.dart';

/// The most identities kept per origin; the newest win.
const int kHermesDashboardCookieRegistryCap = 64;

/// The cookie identities a sign-in created: those in [current] that were not
/// in [baseline], plus any whose name (without a `__Host-` or `__Secure-`
/// prefix) is in [retainedNames], since an automatic sign-in refreshes those
/// in place. An identity is `name\u0000domain\u0000path` (the app's
/// `WebViewCookieHelper.cookieIdentityParts`).
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

/// The registry key for a dashboard origin (`scheme://host:port`, lower
/// case, default port filled in), or null when [origin] has no host.
String? hermesDashboardCookieOriginKey(String origin) {
  final uri = Uri.tryParse(origin);
  if (uri == null || uri.host.isEmpty) return null;
  final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
  return '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}:$port';
}

/// [existing] with [identities] added. Retained session cookies go last, so
/// the cap (which keeps the newest suffix) drops them last.
@visibleForTesting
List<String> mergeHermesDashboardCookieIdentities({
  required List<String> existing,
  required Set<String> identities,
  Set<String> retainedNames = const {},
  int cap = kHermesDashboardCookieRegistryCap,
}) {
  final retained = identities
      .where((identity) => retainedNames.any(identity.startsWith))
      .toSet();
  final merged = {
    ...existing,
    ...identities.where((identity) => !retained.contains(identity)),
    ...retained,
  }.toList();
  return merged.length <= cap ? merged : merged.sublist(merged.length - cap);
}

/// The persisted registry, and the sign-in generations that fence a stale
/// sign-in from recording cookies after the origin was cleared.
abstract final class HermesDashboardCookieRegistry {
  static final Map<String, int> _generations = {};

  /// Starts a sign-in (or a REST bridge) for [origin]; returns the generation
  /// its [record] calls must carry. 0 for an origin without a host.
  static int begin(String origin) {
    final key = hermesDashboardCookieOriginKey(origin);
    if (key == null) return 0;
    return _generations[key] = (_generations[key] ?? 0) + 1;
  }

  /// Whether [generation] is still [origin]'s latest sign-in.
  static bool isCurrent(String origin, int generation) {
    final key = hermesDashboardCookieOriginKey(origin);
    return key != null && _generations[key] == generation;
  }

  /// Supersedes every sign-in for [origin] (a clear is starting). False when
  /// [origin] has no host, so there is nothing to clear.
  static bool invalidate(String origin) {
    final key = hermesDashboardCookieOriginKey(origin);
    if (key == null) return false;
    _generations[key] = (_generations[key] ?? 0) + 1;
    return true;
  }

  /// The identities recorded for [origin].
  static Set<String> identitiesFor(String origin) {
    final key = hermesDashboardCookieOriginKey(origin);
    return key == null ? const {} : _read()[key]?.toSet() ?? const {};
  }

  /// Adds [identities] to [origin]'s record.
  static Future<void> record(
    String origin, {
    required Set<String> identities,
    Set<String> retainedNames = const {},
  }) async {
    final key = hermesDashboardCookieOriginKey(origin);
    if (key == null) return;
    final registry = _read();
    registry[key] = mergeHermesDashboardCookieIdentities(
      existing: registry[key] ?? const [],
      identities: identities,
      retainedNames: retainedNames,
    );
    await _write(registry);
  }

  /// Drops [origin]'s record, after its cookies were deleted.
  static Future<void> forget(String origin) async {
    final key = hermesDashboardCookieOriginKey(origin);
    if (key == null) return;
    final registry = _read();
    if (registry.remove(key) != null) await _write(registry);
  }

  /// Forgets the in-memory generations.
  @visibleForTesting
  static void debugReset() => _generations.clear();

  static Map<String, List<String>> _read() {
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
                .take(kHermesDashboardCookieRegistryCap)
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
