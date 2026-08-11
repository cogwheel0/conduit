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
) => _RiverpodEditorTarget(ref, mode);

/// Executes source-specific editor commands against Riverpod controllers.
final class _RiverpodEditorTarget implements DirectConnectionEditorTarget {
  const _RiverpodEditorTarget(this.ref, this.mode);

  final WidgetRef ref;

  @override
  final DirectConnectionEditorMode mode;

  @override
  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile) =>
      ref.read(directConnectionProfilesProvider.notifier).probe(profile);

  @override
  Future<void> save(DirectEditorSaveCommand command) async {
    try {
      switch (command) {
        case DirectEditorCreateLocalCommand(
          :final draft,
          :final secretsConfirmedForNewOrigin,
        ):
          await _saveLocal(
            draft,
            previous: null,
            secretsConfirmed: secretsConfirmedForNewOrigin,
          );
        case DirectEditorUpdateLocalCommand(
          :final draft,
          :final previousProfile,
          :final secretsConfirmedForNewOrigin,
        ):
          await _saveLocal(
            draft,
            previous: previousProfile,
            secretsConfirmed: secretsConfirmedForNewOrigin,
          );
        case DirectEditorCreateOpenWebUiCommand(
          :final draft,
          :final authentication,
        ):
          await ref
              .read(openWebUiDirectConnectionsProvider.notifier)
              .add(draft, authType: _authType(authentication));
        case DirectEditorUpdateOpenWebUiCommand(
          :final draft,
          :final previousRecord,
          :final authentication,
        ):
          await ref
              .read(openWebUiDirectConnectionsProvider.notifier)
              .updateConnection(
                previousRecord,
                draft,
                authType: _authType(authentication),
              );
      }
    } on DirectConnectionProfileConflictException catch (error, stackTrace) {
      Error.throwWithStackTrace(DirectEditorSaveConflict(error), stackTrace);
    } on OpenWebUiDirectConnectionConflictException catch (error, stackTrace) {
      Error.throwWithStackTrace(DirectEditorSaveConflict(error), stackTrace);
    }
  }

  Future<void> _saveLocal(
    DirectConnectionProfile draft, {
    required DirectConnectionProfile? previous,
    required bool secretsConfirmed,
  }) => ref
      .read(directConnectionProfilesProvider.notifier)
      .upsert(
        draft,
        expectedPrevious: previous,
        secretsConfirmedForNewOrigin: secretsConfirmed,
      );

  String? _authType(DirectAuthenticationMode authentication) =>
      switch (authentication) {
        DirectAuthenticationMode.bearer => 'bearer',
        DirectAuthenticationMode.none => 'none',
        DirectAuthenticationMode.apiKeyHeader ||
        DirectAuthenticationMode.unsupported => null,
      };

  @override
  Future<void> delete(DirectEditorDeleteCommand command) async {
    try {
      switch (command) {
        case DirectEditorDeleteLocalCommand(:final profileId):
          await ref
              .read(directConnectionProfilesProvider.notifier)
              .remove(profileId);
        case DirectEditorDeleteOpenWebUiCommand(:final record):
          await ref
              .read(openWebUiDirectConnectionsProvider.notifier)
              .delete(record);
      }
    } on OpenWebUiDirectConnectionCommitUncertainException catch (
      error,
      stackTrace
    ) {
      Error.throwWithStackTrace(
        DirectEditorDeletionCommitUncertain(error),
        stackTrace,
      );
    }
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
}
