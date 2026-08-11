import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/backend_mode_providers.dart';
import '../../../core/utils/debug_logger.dart';
import '../models/direct_connection_profile.dart';
import '../models/direct_remote_model.dart';
import '../models/openwebui_direct_connection.dart';
import '../providers/direct_connection_providers.dart';
import 'direct_connection_editor_workflow.dart';

/// Riverpod-backed I/O boundary for the direct editor state machine.
final class RiverpodDirectConnectionEditorGateway
    implements DirectConnectionEditorGateway {
  const RiverpodDirectConnectionEditorGateway(this.ref);

  final WidgetRef ref;

  @override
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) =>
      ref.read(directConnectionProfilesProvider.notifier).probe(profile);

  @override
  Future<void> saveLocal({
    required DirectConnectionProfile draft,
    required DirectConnectionProfile? expectedPrevious,
    required bool secretsConfirmedForNewOrigin,
  }) => ref
      .read(directConnectionProfilesProvider.notifier)
      .upsert(
        draft,
        expectedPrevious: expectedPrevious,
        secretsConfirmedForNewOrigin: secretsConfirmedForNewOrigin,
      );

  @override
  Future<void> saveOpenWebUi({
    required DirectConnectionProfile draft,
    required OpenWebUiDirectConnectionRecord? previous,
    required bool isNew,
    required String? authType,
  }) async {
    final controller = ref.read(openWebUiDirectConnectionsProvider.notifier);
    if (isNew) {
      await controller.add(draft, authType: authType);
      return;
    }
    final record = previous;
    if (record == null) {
      throw StateError('Open WebUI direct connection not found.');
    }
    await controller.updateConnection(record, draft, authType: authType);
  }

  @override
  Future<bool> clearDirectPreferenceIfLastUsable(String profileId) async {
    final profiles = await ref.read(
      effectiveDirectConnectionProfilesFutureProvider.future,
    );
    final hasAnotherUsable = profiles.any(
      (profile) => profile.id != profileId && profile.isUsable,
    );
    if (hasAnotherUsable ||
        ref.read(preferredBackendProvider) != PreferredBackend.direct) {
      return false;
    }
    try {
      await ref
          .read(preferredBackendProvider.notifier)
          .set(PreferredBackend.unset);
      return true;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'Failed to clear the direct backend before profile deletion',
        scope: 'direct/editor',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  @override
  Future<void> restoreDirectPreference() async {
    try {
      await ref
          .read(preferredBackendProvider.notifier)
          .set(PreferredBackend.direct);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'Failed to restore the direct backend after profile deletion failed',
        scope: 'direct/editor',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  Future<void> deleteLocal(String profileId) =>
      ref.read(directConnectionProfilesProvider.notifier).remove(profileId);

  @override
  Future<void> deleteOpenWebUi(OpenWebUiDirectConnectionRecord record) =>
      ref.read(openWebUiDirectConnectionsProvider.notifier).delete(record);
}
