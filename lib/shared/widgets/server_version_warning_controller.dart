import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/persistence/persistence_keys.dart';
import '../../core/persistence/preferences_store.dart';
import '../../core/utils/debug_logger.dart';

/// Builds the dismissal token for the unsupported-server warning.
///
/// The token is scoped to the active server *and* its reported version, so a
/// dismissed warning reappears only for a different server or after that
/// server upgrades to another unsupported version.
String serverVersionWarningToken({
  required String serverId,
  required String? version,
}) => '$serverId|${version?.trim() ?? ''}';

/// Upper bound on remembered dismissals. Oldest entries drop first, so the
/// preference cannot grow without limit across many servers and upgrades.
const int kMaxServerVersionWarningDismissals = 32;

/// The persisted `<serverId>|<version>` tokens the user dismissed.
final serverVersionWarningDismissedProvider =
    NotifierProvider<ServerVersionWarningController, Set<String>>(
      ServerVersionWarningController.new,
    );

class ServerVersionWarningController extends Notifier<Set<String>> {
  @override
  Set<String> build() => decodeServerVersionWarningDismissals(
    PreferencesStore.getString(PreferenceKeys.serverVersionWarningDismissed),
  );

  /// Remembers [token] alongside every earlier dismissal, so acknowledging
  /// the warning on one server never re-surfaces it on another.
  Future<void> dismiss(String token) async {
    if (state.contains(token)) return;
    final next = <String>{...state, token};
    while (next.length > kMaxServerVersionWarningDismissals) {
      next.remove(next.first);
    }
    state = next;
    try {
      await PreferencesStore.put(
        PreferenceKeys.serverVersionWarningDismissed,
        jsonEncode(next.toList(growable: false)),
      );
    } catch (error) {
      DebugLogger.warning(
        'Failed to persist server version warning dismissal',
        scope: 'ui/server-version-warning',
        data: {'error': error.toString()},
      );
    }
  }
}

/// Parses the stored dismissal list. A bare token (the first shipped format)
/// is accepted as a single entry; anything unparseable yields no dismissals.
Set<String> decodeServerVersionWarningDismissals(String? raw) {
  if (raw == null || raw.isEmpty) return const <String>{};
  if (!raw.startsWith('[')) return {raw};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const <String>{};
    return {
      for (final entry in decoded)
        if (entry is String && entry.isNotEmpty) entry,
    };
  } on FormatException {
    return const <String>{};
  }
}
