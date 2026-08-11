import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/backend_mode_providers.dart';
import '../../../core/utils/debug_logger.dart';
import '../models/direct_connection_profile.dart';
import '../models/direct_remote_model.dart';
import '../providers/direct_connection_providers.dart';
import 'direct_connection_editor_draft.dart';
import 'direct_connection_editor_workflow.dart';

DirectConnectionEditorTarget riverpodDirectConnectionEditorTarget(
  WidgetRef ref,
  DirectConnectionEditorMode mode,
) => switch (mode.source) {
  DirectConnectionEditorSource.local => _RiverpodLocalEditorTarget(ref, mode),
  DirectConnectionEditorSource.openWebUi => _RiverpodOpenWebUiEditorTarget(
    ref,
    mode,
  ),
};

/// Shared Riverpod-backed I/O used by both concrete editor targets.
abstract base class _RiverpodEditorTarget
    implements DirectConnectionEditorTarget {
  const _RiverpodEditorTarget(this.ref, this.mode);

  final WidgetRef ref;

  @override
  final DirectConnectionEditorMode mode;

  @override
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) =>
      ref.read(directConnectionProfilesProvider.notifier).probe(profile);

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
}

final class _RiverpodLocalEditorTarget extends _RiverpodEditorTarget {
  const _RiverpodLocalEditorTarget(super.ref, super.mode);

  @override
  Future<void> save(DirectEditorSaveRequest request) => ref
      .read(directConnectionProfilesProvider.notifier)
      .upsert(
        request.draft,
        expectedPrevious: request.previousProfile,
        secretsConfirmedForNewOrigin: request.secretsConfirmedForNewOrigin,
      );

  @override
  Future<void> delete(DirectEditorDeleteRequest request) => ref
      .read(directConnectionProfilesProvider.notifier)
      .remove(request.profile.id);

  @override
  bool isConflict(Object error) =>
      error is DirectConnectionProfileConflictException;

  @override
  bool deletionMayHaveCommitted(Object error) => false;
}

final class _RiverpodOpenWebUiEditorTarget extends _RiverpodEditorTarget {
  const _RiverpodOpenWebUiEditorTarget(super.ref, super.mode);

  @override
  Future<void> save(DirectEditorSaveRequest request) async {
    final controller = ref.read(openWebUiDirectConnectionsProvider.notifier);
    final authType = switch (request.authentication) {
      DirectAuthenticationMode.bearer => 'bearer',
      DirectAuthenticationMode.none => 'none',
      DirectAuthenticationMode.apiKeyHeader ||
      DirectAuthenticationMode.unsupported => null,
    };
    if (mode.isNew) {
      await controller.add(request.draft, authType: authType);
      return;
    }
    final record = request.previousOpenWebUiRecord;
    if (record == null) {
      throw StateError('Open WebUI direct connection not found.');
    }
    await controller.updateConnection(
      record,
      request.draft,
      authType: authType,
    );
  }

  @override
  Future<void> delete(DirectEditorDeleteRequest request) {
    final record = request.openWebUiRecord;
    if (record == null) {
      throw StateError('Open WebUI direct connection not found.');
    }
    return ref.read(openWebUiDirectConnectionsProvider.notifier).delete(record);
  }

  @override
  bool isConflict(Object error) =>
      error is OpenWebUiDirectConnectionConflictException;

  @override
  bool deletionMayHaveCommitted(Object error) =>
      error is OpenWebUiDirectConnectionCommitUncertainException;
}
