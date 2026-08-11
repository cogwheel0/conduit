import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/backend_mode_providers.dart';
import '../../../core/utils/debug_logger.dart';
import '../models/direct_connection_profile.dart';
import '../models/direct_remote_model.dart';
import '../models/openwebui_direct_connection.dart';
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

abstract base class _RiverpodEditorTarget
    implements DirectConnectionEditorTarget {
  _RiverpodEditorTarget(this.ref, this.mode);

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
  _RiverpodLocalEditorTarget(super.ref, super.mode)
    : assert(mode.source == DirectConnectionEditorSource.local);

  DirectConnectionProfile? _previousProfile;

  @override
  void hydrate(
    DirectConnectionProfile? profile, {
    OpenWebUiDirectConnectionRecord? openWebUiRecord,
  }) {
    _previousProfile = profile;
  }

  @override
  Future<void> save(DirectEditorSaveIntent intent) async {
    final previous = mode.isNew ? null : _previousProfile;
    if (!mode.isNew && previous == null) {
      throw const DirectEditorTargetUnavailable();
    }
    try {
      await ref
          .read(directConnectionProfilesProvider.notifier)
          .upsert(
            intent.draft,
            expectedPrevious: previous,
            secretsConfirmedForNewOrigin: intent.secretsConfirmedForNewOrigin,
          );
    } on DirectConnectionProfileConflictException catch (error, stackTrace) {
      Error.throwWithStackTrace(DirectEditorSaveConflict(error), stackTrace);
    }
  }

  @override
  Future<void> delete(DirectConnectionProfile savedProfile) => ref
      .read(directConnectionProfilesProvider.notifier)
      .remove(savedProfile.id);
}

final class _RiverpodOpenWebUiEditorTarget extends _RiverpodEditorTarget {
  _RiverpodOpenWebUiEditorTarget(super.ref, super.mode)
    : assert(mode.source == DirectConnectionEditorSource.openWebUi);

  OpenWebUiDirectConnectionRecord? _previousRecord;

  @override
  void hydrate(
    DirectConnectionProfile? profile, {
    OpenWebUiDirectConnectionRecord? openWebUiRecord,
  }) {
    _previousRecord = openWebUiRecord;
  }

  @override
  Future<void> save(DirectEditorSaveIntent intent) async {
    try {
      if (mode.isNew) {
        await ref
            .read(openWebUiDirectConnectionsProvider.notifier)
            .add(intent.draft, authType: _authType(intent.authentication));
        return;
      }
      final previous = _previousRecord;
      if (previous == null) throw const DirectEditorTargetUnavailable();
      await ref
          .read(openWebUiDirectConnectionsProvider.notifier)
          .updateConnection(
            previous,
            intent.draft,
            authType: _authType(intent.authentication),
          );
    } on OpenWebUiDirectConnectionConflictException catch (error, stackTrace) {
      Error.throwWithStackTrace(DirectEditorSaveConflict(error), stackTrace);
    }
  }

  @override
  Future<void> delete(DirectConnectionProfile savedProfile) async {
    final previous = _previousRecord;
    if (previous == null) throw const DirectEditorTargetUnavailable();
    try {
      await ref
          .read(openWebUiDirectConnectionsProvider.notifier)
          .delete(previous);
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

  String? _authType(DirectAuthenticationMode authentication) =>
      switch (authentication) {
        DirectAuthenticationMode.bearer => 'bearer',
        DirectAuthenticationMode.none => 'none',
        DirectAuthenticationMode.apiKeyHeader ||
        DirectAuthenticationMode.unsupported => null,
      };
}
