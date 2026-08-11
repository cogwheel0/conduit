import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/providers/backend_mode_providers.dart';
import '../../../core/utils/debug_logger.dart';
import '../models/direct_connection_profile.dart';
import '../models/direct_remote_model.dart';
import '../models/openwebui_direct_connection.dart';
import '../providers/direct_connection_providers.dart';
import 'direct_connection_editor_draft.dart';
import 'direct_connection_editor_workflow.dart';

DirectConnectionEditorGateway riverpodDirectConnectionEditorGateway(
  WidgetRef ref,
  DirectConnectionEditorMode mode,
) => switch (mode.source) {
  DirectConnectionEditorSource.local => _RiverpodLocalEditorGateway(ref, mode),
  DirectConnectionEditorSource.openWebUi => _RiverpodOpenWebUiEditorGateway(
    ref,
    mode,
  ),
};

abstract base class _RiverpodEditorGateway
    implements DirectConnectionEditorGateway {
  _RiverpodEditorGateway(this.ref, this.mode);

  final WidgetRef ref;

  @override
  final DirectConnectionEditorMode mode;

  @override
  DirectConnectionEditorPolicy get policy => mode.policy;

  DirectEditorLoadState mapResource<T>(
    AsyncValue<T> state,
    DirectEditorResource Function(T data) map,
  ) => state.when(
    loading: () => const DirectEditorLoadLoading(),
    error: DirectEditorLoadFailure.new,
    data: (data) => DirectEditorLoadData(map(data)),
  );

  DirectEditorResourceSubscription subscribeTo<T>(
    ProviderListenable<AsyncValue<T>> provider,
    DirectEditorResource Function(T data) map,
    DirectEditorResourceListener listener, {
    required bool fireImmediately,
  }) => _RiverpodEditorResourceSubscription(
    ref.listenManual(
      provider,
      (_, next) => listener(mapResource(next, map)),
      fireImmediately: fireImmediately,
    ),
  );

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

final class _RiverpodEditorResourceSubscription<T>
    implements DirectEditorResourceSubscription {
  const _RiverpodEditorResourceSubscription(this.subscription);

  final ProviderSubscription<T> subscription;

  @override
  void close() => subscription.close();
}

final class _RiverpodLocalEditorGateway extends _RiverpodEditorGateway {
  _RiverpodLocalEditorGateway(super.ref, super.mode)
    : assert(mode.source == DirectConnectionEditorSource.local);

  DirectConnectionProfile? _previousProfile;

  DirectEditorResource _resourceFor(List<DirectConnectionProfile> profiles) {
    DirectConnectionProfile? profile;
    if (!mode.isNew) {
      for (final candidate in profiles) {
        if (candidate.id == mode.profileId) {
          profile = candidate;
          break;
        }
      }
    }
    return DirectEditorResource(
      availability: !mode.isNew && profile == null
          ? DirectEditorResourceAvailability.missing
          : DirectEditorResourceAvailability.ready,
      profile: profile,
      authentication: profile == null ? null : _localAuthentication(profile),
    );
  }

  @override
  DirectEditorLoadState get resourceState =>
      mapResource(ref.read(directConnectionProfilesProvider), _resourceFor);

  @override
  DirectEditorResourceSubscription subscribe(
    DirectEditorResourceListener listener, {
    bool fireImmediately = false,
  }) => subscribeTo(
    directConnectionProfilesProvider,
    _resourceFor,
    listener,
    fireImmediately: fireImmediately,
  );

  @override
  Future<void> reload() =>
      ref.read(directConnectionProfilesProvider.notifier).reload();

  @override
  void hydrate(DirectEditorResource resource) {
    _previousProfile = resource.profile;
  }

  @override
  bool refreshBaseline(DirectEditorResource resource) => false;

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

final class _RiverpodOpenWebUiEditorGateway extends _RiverpodEditorGateway {
  _RiverpodOpenWebUiEditorGateway(super.ref, super.mode)
    : assert(mode.source == DirectConnectionEditorSource.openWebUi);

  OpenWebUiDirectConnectionRecord? _previousRecord;
  OpenWebUiDirectConnectionRecord? _latestRecord;

  DirectEditorResource _resourceFor(
    OpenWebUiDirectConnectionsSnapshot? snapshot,
  ) {
    if (snapshot == null) {
      _latestRecord = null;
      return const DirectEditorResource(
        availability: DirectEditorResourceAvailability.unavailable,
      );
    }
    final record = mode.isNew
        ? null
        : snapshot.recordByProfileId(mode.profileId!);
    _latestRecord = record;
    return DirectEditorResource(
      availability: !mode.isNew && record == null
          ? DirectEditorResourceAvailability.missing
          : DirectEditorResourceAvailability.ready,
      profile: record?.profile,
      authentication: record == null
          ? null
          : _openWebUiAuthentication(record.authType),
      owner: DirectEditorOwner(
        serverId: snapshot.serverId,
        accountId: snapshot.accountId,
        authEpoch: ref.read(openWebUiAuthSessionEpochProvider),
      ),
    );
  }

  @override
  DirectEditorLoadState get resourceState =>
      mapResource(ref.read(openWebUiDirectConnectionsProvider), _resourceFor);

  @override
  DirectEditorResourceSubscription subscribe(
    DirectEditorResourceListener listener, {
    bool fireImmediately = false,
  }) => subscribeTo(
    openWebUiDirectConnectionsProvider,
    _resourceFor,
    listener,
    fireImmediately: fireImmediately,
  );

  @override
  Future<void> reload() =>
      ref.read(openWebUiDirectConnectionsProvider.notifier).reload();

  @override
  void hydrate(DirectEditorResource resource) {
    final latest = _latestRecord;
    _previousRecord = latest?.profile.id == resource.profile?.id
        ? latest
        : null;
  }

  @override
  bool refreshBaseline(DirectEditorResource resource) {
    final previous = _previousRecord;
    final latest = _latestRecord;
    if (previous == null ||
        latest == null ||
        latest.profile.id != resource.profile?.id ||
        previous.profile.id != latest.profile.id ||
        previous.contentRevision != latest.contentRevision) {
      return false;
    }
    _previousRecord = latest;
    return true;
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

DirectAuthenticationMode _localAuthentication(
  DirectConnectionProfile profile,
) => profile.isOpenRouter
    ? DirectAuthenticationMode.bearer
    : (profile.apiKey ?? '').isEmpty
    ? DirectAuthenticationMode.none
    : switch (profile.apiKeyAuthMode) {
        DirectApiKeyAuthMode.bearer => DirectAuthenticationMode.bearer,
        DirectApiKeyAuthMode.apiKeyHeader =>
          DirectAuthenticationMode.apiKeyHeader,
      };

DirectAuthenticationMode _openWebUiAuthentication(String authType) =>
    switch (authType) {
      'bearer' => DirectAuthenticationMode.bearer,
      'none' => DirectAuthenticationMode.none,
      _ => DirectAuthenticationMode.unsupported,
    };
