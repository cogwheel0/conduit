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

/// The persisted `<serverId>|<version>` token the user dismissed, or null.
final serverVersionWarningDismissedProvider =
    NotifierProvider<ServerVersionWarningController, String?>(
      ServerVersionWarningController.new,
    );

class ServerVersionWarningController extends Notifier<String?> {
  @override
  String? build() =>
      PreferencesStore.getString(PreferenceKeys.serverVersionWarningDismissed);

  Future<void> dismiss(String token) async {
    state = token;
    try {
      await PreferencesStore.put(
        PreferenceKeys.serverVersionWarningDismissed,
        token,
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
