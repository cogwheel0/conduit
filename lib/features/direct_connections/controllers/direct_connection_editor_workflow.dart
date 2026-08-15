import 'package:flutter/foundation.dart';

import '../../../shared/models/connection_attempt.dart';
import '../models/direct_connection_profile.dart';
import '../models/direct_remote_model.dart';
import 'direct_connection_editor_draft.dart';
import 'direct_connection_editor_form.dart';

enum DirectEditorOperation { idle, saving, testing, deleting }

extension DirectEditorOperationState on DirectEditorOperation {
  bool get isBusy => this != DirectEditorOperation.idle;
}

@immutable
final class DirectEditorOwner {
  const DirectEditorOwner({
    required this.serverId,
    required this.accountId,
    required this.authEpoch,
  });

  final String serverId;
  final String accountId;
  final Object authEpoch;

  bool matches({
    required String serverId,
    required String accountId,
    required Object authEpoch,
  }) =>
      this.serverId == serverId &&
      this.accountId == accountId &&
      identical(this.authEpoch, authEpoch);

  bool matchesOwner(DirectEditorOwner other) => matches(
    serverId: other.serverId,
    accountId: other.accountId,
    authEpoch: other.authEpoch,
  );
}

enum DirectEditorResourceAvailability { ready, missing, unavailable }

/// One source-neutral load snapshot for the editor route.
@immutable
final class DirectEditorResource {
  const DirectEditorResource({
    required this.availability,
    this.profile,
    this.authentication,
    this.owner,
  }) : assert(profile == null || authentication != null);

  final DirectEditorResourceAvailability availability;
  final DirectConnectionProfile? profile;
  final DirectAuthenticationMode? authentication;
  final DirectEditorOwner? owner;
}

sealed class DirectEditorLoadState {
  const DirectEditorLoadState();
}

final class DirectEditorLoadLoading extends DirectEditorLoadState {
  const DirectEditorLoadLoading();
}

final class DirectEditorLoadFailure extends DirectEditorLoadState {
  const DirectEditorLoadFailure(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}

final class DirectEditorLoadData extends DirectEditorLoadState {
  const DirectEditorLoadData(this.resource);

  final DirectEditorResource resource;
}

abstract interface class DirectEditorResourceSubscription {
  void close();
}

typedef DirectEditorResourceListener = void Function(DirectEditorLoadState);

@immutable
final class DirectConnectionEditorState {
  const DirectConnectionEditorState({
    this.operation = DirectEditorOperation.idle,
    this.attempt = const ConnectionAttemptState.idle(),
    this.operationError,
    this.hydrated = false,
    this.owner,
  });

  final DirectEditorOperation operation;
  final ConnectionAttemptState attempt;
  final String? operationError;
  final bool hydrated;
  final DirectEditorOwner? owner;

  bool get isBusy => operation.isBusy;

  DirectConnectionEditorState copyWith({
    DirectEditorOperation? operation,
    ConnectionAttemptState? attempt,
    String? operationError,
    bool clearOperationError = false,
    bool? hydrated,
    DirectEditorOwner? owner,
  }) => DirectConnectionEditorState(
    operation: operation ?? this.operation,
    attempt: attempt ?? this.attempt,
    operationError: clearOperationError
        ? null
        : operationError ?? this.operationError,
    hydrated: hydrated ?? this.hydrated,
    owner: owner ?? this.owner,
  );
}

@immutable
final class DirectEditorSaveIntent {
  const DirectEditorSaveIntent({
    required this.draft,
    required this.authentication,
    required this.secretsConfirmedForNewOrigin,
  });

  final DirectConnectionProfile draft;
  final DirectAuthenticationMode authentication;
  final bool secretsConfirmedForNewOrigin;
}

@immutable
final class DirectEditorDeleteIntent {
  const DirectEditorDeleteIntent({required this.profile, required this.owner});

  final DirectConnectionProfile profile;
  final DirectEditorOwner? owner;
}

sealed class DirectEditorPersistenceException implements Exception {
  const DirectEditorPersistenceException(this.cause);

  final Object cause;
}

final class DirectEditorSaveConflict extends DirectEditorPersistenceException {
  const DirectEditorSaveConflict(super.cause);
}

final class DirectEditorDeletionCommitUncertain
    extends DirectEditorPersistenceException {
  const DirectEditorDeletionCommitUncertain(super.cause);
}

final class DirectEditorTargetUnavailable implements Exception {
  const DirectEditorTargetUnavailable();
}

/// Canonical loading, source-policy, and persistence contract for one editor.
abstract interface class DirectConnectionEditorGateway {
  DirectConnectionEditorMode get mode;

  DirectConnectionEditorPolicy get policy;

  DirectEditorLoadState get resourceState;

  DirectEditorResourceSubscription subscribe(
    DirectEditorResourceListener listener, {
    bool fireImmediately,
  });

  Future<void> reload();

  void hydrate(DirectEditorResource resource);

  /// Advances a source-owned persistence baseline when [resource] represents
  /// the same logical content under a new storage revision.
  bool refreshBaseline(DirectEditorResource resource);

  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile);

  Future<void> save(DirectEditorSaveIntent intent);

  bool ownerIsCurrent(DirectEditorOwner? owner);

  Future<void> delete(DirectEditorDeleteIntent intent);
}

enum DirectEditorActionOutcome {
  succeeded,
  cancelled,
  invalidDraft,
  unreachable,
  conflict,
  unavailable,
  failed,
}

@immutable
final class DirectEditorActionResult {
  const DirectEditorActionResult(this.outcome, {this.profile, this.error});

  final DirectEditorActionOutcome outcome;
  final DirectConnectionProfile? profile;
  final Object? error;

  bool get succeeded => outcome == DirectEditorActionOutcome.succeeded;
}

@immutable
final class DirectEditorMessages {
  const DirectEditorMessages({
    required this.openWebUiFallbackName,
    required this.connecting,
    required this.reachFailed,
    required this.saveConflict,
    required this.saveFailed,
    required this.unavailable,
    required this.probeMessage,
  });

  final String openWebUiFallbackName;
  final String connecting;
  final String reachFailed;
  final String saveConflict;
  final String saveFailed;
  final String unavailable;
  final String Function(DirectConnectionProbe probe) probeMessage;
}

typedef DirectCredentialTransferConfirmation =
    Future<bool> Function(DirectConnectionProfile draft);
typedef DirectDeleteConfirmation =
    Future<bool> Function(DirectConnectionProfile savedProfile);

/// Owns persistence and the save/test/delete operation state machine.
final class DirectConnectionEditorWorkflow extends ChangeNotifier {
  DirectConnectionEditorWorkflow({
    required DirectConnectionEditorGateway gateway,
  }) : _gateway = gateway,
       form = DirectConnectionEditorForm(mode: gateway.mode),
       _resourceState = gateway.resourceState {
    form.addListener(_handleFormChanged);
    _resourceSubscription = gateway.subscribe(
      _handleResourceState,
      fireImmediately: true,
    );
  }

  final DirectConnectionEditorGateway _gateway;
  final DirectConnectionEditorForm form;
  late final DirectEditorResourceSubscription _resourceSubscription;

  DirectConnectionEditorState _state = const DirectConnectionEditorState();
  DirectEditorLoadState _resourceState;
  bool _disposed = false;
  int _observedDraftRevision = 0;

  DirectConnectionEditorState get state => _state;
  DirectEditorLoadState get resourceState => _resourceState;
  DirectConnectionEditorMode get mode => _gateway.mode;
  DirectConnectionEditorPolicy get policy => _gateway.policy;

  Future<void> reload() => _gateway.reload();

  void _handleResourceState(DirectEditorLoadState next) {
    if (_disposed) return;
    _resourceState = next;
    if (next case DirectEditorLoadData(:final resource)) {
      observeResource(resource);
    }
    notifyListeners();
  }

  void _handleFormChanged() {
    if (_disposed) return;
    final revision = form.draftRevision;
    if (_observedDraftRevision != revision) {
      _observedDraftRevision = revision;
      _state = state.copyWith(
        attempt: const ConnectionAttemptState.idle(),
        clearOperationError: true,
      );
    }
    notifyListeners();
  }

  /// Reconciles one gateway snapshot with the route's captured owner and form.
  /// Returns false when the snapshot belongs to a replacement account/server.
  bool observeResource(DirectEditorResource resource) {
    final incomingOwner = resource.owner;
    if (policy.requiresOwnerValidation) {
      if (incomingOwner == null) return false;
      final capturedOwner = state.owner;
      if (capturedOwner == null) {
        captureOwner(
          serverId: incomingOwner.serverId,
          accountId: incomingOwner.accountId,
          authEpoch: incomingOwner.authEpoch,
        );
      } else if (!capturedOwner.matchesOwner(incomingOwner)) {
        return false;
      }
    }
    if (resource.availability != DirectEditorResourceAvailability.ready) {
      return true;
    }
    if (state.hydrated) {
      if (_gateway.refreshBaseline(resource)) {
        form.refreshBaseline(
          resource.profile,
          authentication: resource.authentication,
        );
      }
      return true;
    }
    _hydrateResource(resource);
    return true;
  }

  @visibleForTesting
  void hydrate(
    DirectConnectionProfile? profile, {
    DirectAuthenticationMode? authentication,
  }) {
    _hydrateResource(
      DirectEditorResource(
        availability: DirectEditorResourceAvailability.ready,
        profile: profile,
        authentication:
            authentication ??
            (profile == null ? null : directAuthenticationForProfile(profile)),
      ),
    );
  }

  void _hydrateResource(DirectEditorResource resource) {
    if (state.hydrated) return;
    _gateway.hydrate(resource);
    form.hydrate(resource.profile, authentication: resource.authentication);
    _observedDraftRevision = form.draftRevision;
    _publish(state.copyWith(hydrated: true));
  }

  void captureOwner({
    required String serverId,
    required String accountId,
    required Object authEpoch,
  }) {
    if (state.owner != null) return;
    _publish(
      state.copyWith(
        owner: DirectEditorOwner(
          serverId: serverId,
          accountId: accountId,
          authEpoch: authEpoch,
        ),
      ),
    );
  }

  bool ownerMatches({
    required String serverId,
    required String accountId,
    required Object authEpoch,
  }) =>
      state.owner?.matches(
        serverId: serverId,
        accountId: accountId,
        authEpoch: authEpoch,
      ) ??
      false;

  bool resourceOwnerMatches(DirectEditorResource resource) {
    if (!policy.requiresOwnerValidation) return true;
    final owner = resource.owner;
    return owner != null &&
        state.owner?.matchesOwner(owner) == true &&
        _gateway.ownerIsCurrent(state.owner);
  }

  Future<DirectEditorActionResult> save({
    required DirectEditorMessages messages,
    required DirectCredentialTransferConfirmation confirmCredentialTransfer,
    DirectConnectionProfile? testedDraft,
  }) async {
    if (state.isBusy) {
      return const DirectEditorActionResult(
        DirectEditorActionOutcome.cancelled,
      );
    }
    if (!_operationOwnerIsCurrent()) return _unavailable(messages);
    if (!_beginOperation(DirectEditorOperation.saving)) {
      return const DirectEditorActionResult(
        DirectEditorActionOutcome.cancelled,
      );
    }
    final draft =
        testedDraft ??
        form
            .buildDraft(
              validateFields: true,
              openWebUiFallbackName: messages.openWebUiFallbackName,
            )
            .profile;
    if (draft == null) {
      _finishOperation();
      return const DirectEditorActionResult(
        DirectEditorActionOutcome.invalidDraft,
      );
    }
    if (!await _confirmCredentialTransfer(draft, confirmCredentialTransfer)) {
      if (!_disposed) _finishOperation();
      return const DirectEditorActionResult(
        DirectEditorActionOutcome.cancelled,
      );
    }
    if (!_canContinue()) return _unavailable(messages);

    final intent = DirectEditorSaveIntent(
      draft: draft,
      authentication: form.authentication,
      secretsConfirmedForNewOrigin:
          !form.originChanged ||
          !form.savedHasOriginBoundSecrets ||
          form.originSecretsConfirmed,
    );

    try {
      await _gateway.save(intent);
      if (!_canContinue()) return _unavailable(messages);
      _finishOperation(clearError: true);
      return DirectEditorActionResult(
        DirectEditorActionOutcome.succeeded,
        profile: draft,
      );
    } on DirectEditorSaveConflict catch (error) {
      if (!_canContinue()) return _unavailable(messages);
      return _conflict(messages, error.cause);
    } on DirectEditorTargetUnavailable {
      return _unavailable(messages);
    } catch (error) {
      if (!_canContinue()) return _unavailable(messages);
      _finishOperation(error: messages.saveFailed);
      return DirectEditorActionResult(
        DirectEditorActionOutcome.failed,
        error: error,
      );
    }
  }

  Future<DirectEditorActionResult> testConnection({
    required DirectEditorMessages messages,
    required DirectCredentialTransferConfirmation confirmCredentialTransfer,
  }) async {
    if (state.isBusy) {
      return const DirectEditorActionResult(
        DirectEditorActionOutcome.cancelled,
      );
    }
    if (!_operationOwnerIsCurrent()) return _unavailable(messages);
    if (!_beginOperation(DirectEditorOperation.testing)) {
      return const DirectEditorActionResult(
        DirectEditorActionOutcome.cancelled,
      );
    }
    final draft = form
        .buildDraft(
          validateFields: true,
          openWebUiFallbackName: messages.openWebUiFallbackName,
        )
        .profile;
    if (draft == null) {
      _finishOperation();
      return const DirectEditorActionResult(
        DirectEditorActionOutcome.invalidDraft,
      );
    }
    if (!await _confirmCredentialTransfer(draft, confirmCredentialTransfer)) {
      if (!_disposed) _finishOperation();
      return const DirectEditorActionResult(
        DirectEditorActionOutcome.cancelled,
      );
    }
    if (!_canContinue()) return _unavailable(messages);
    _setAttempt(ConnectionAttemptState.connecting(messages.connecting));
    try {
      final probe = await _gateway.probe(draft);
      if (!_canContinue()) return _unavailable(messages);
      final message = messages.probeMessage(probe);
      _finishOperation(
        attempt: probe.reachable
            ? ConnectionAttemptState.connected(message)
            : ConnectionAttemptState.failed(message),
      );
      return DirectEditorActionResult(
        probe.reachable
            ? DirectEditorActionOutcome.succeeded
            : DirectEditorActionOutcome.unreachable,
        profile: probe.reachable ? draft : null,
      );
    } catch (error) {
      if (!_canContinue()) return _unavailable(messages);
      _finishOperation(
        attempt: ConnectionAttemptState.failed(messages.reachFailed),
      );
      return DirectEditorActionResult(
        DirectEditorActionOutcome.failed,
        error: error,
      );
    }
  }

  Future<DirectEditorActionResult> connectAndSave({
    required DirectEditorMessages messages,
    required DirectCredentialTransferConfirmation confirmCredentialTransfer,
  }) async {
    final tested = await testConnection(
      messages: messages,
      confirmCredentialTransfer: confirmCredentialTransfer,
    );
    if (!tested.succeeded || tested.profile == null) return tested;
    return save(
      messages: messages,
      confirmCredentialTransfer: confirmCredentialTransfer,
      testedDraft: tested.profile,
    );
  }

  Future<DirectEditorActionResult> delete({
    required DirectEditorMessages messages,
    required DirectDeleteConfirmation confirmDelete,
  }) async {
    if (state.isBusy) {
      return const DirectEditorActionResult(
        DirectEditorActionOutcome.cancelled,
      );
    }
    final saved = form.savedProfile;
    if (saved == null) {
      return const DirectEditorActionResult(
        DirectEditorActionOutcome.invalidDraft,
      );
    }
    if (!_operationOwnerIsCurrent()) return _unavailable(messages);
    if (!_beginOperation(DirectEditorOperation.deleting)) {
      return const DirectEditorActionResult(
        DirectEditorActionOutcome.cancelled,
      );
    }
    final confirmed = await confirmDelete(saved);
    if (!_canContinue()) return _unavailable(messages);
    if (!confirmed) {
      _finishOperation();
      return const DirectEditorActionResult(
        DirectEditorActionOutcome.cancelled,
      );
    }
    try {
      await _gateway.delete(
        DirectEditorDeleteIntent(profile: saved, owner: state.owner),
      );
      if (!_canContinue()) return _unavailable(messages);
      _finishOperation(clearError: true);
      return const DirectEditorActionResult(
        DirectEditorActionOutcome.succeeded,
      );
    } on DirectEditorTargetUnavailable {
      return _unavailable(messages);
    } catch (error) {
      if (!_canContinue()) return _unavailable(messages);
      _finishOperation();
      return DirectEditorActionResult(
        DirectEditorActionOutcome.failed,
        error: error is DirectEditorPersistenceException ? error.cause : error,
      );
    }
  }

  bool _beginOperation(DirectEditorOperation operation) {
    if (state.isBusy || operation == DirectEditorOperation.idle) return false;
    _publish(state.copyWith(operation: operation));
    return true;
  }

  void _finishOperation({
    ConnectionAttemptState? attempt,
    String? error,
    bool clearError = false,
  }) {
    _publish(
      state.copyWith(
        operation: DirectEditorOperation.idle,
        attempt: attempt,
        operationError: error,
        clearOperationError: clearError,
      ),
    );
  }

  void _setAttempt(ConnectionAttemptState attempt) {
    _publish(state.copyWith(attempt: attempt));
  }

  Future<bool> _confirmCredentialTransfer(
    DirectConnectionProfile draft,
    DirectCredentialTransferConfirmation confirm,
  ) async {
    if (form.originSecretsConfirmed ||
        !requiresDirectOriginCredentialConfirmation(
          previous: form.savedProfile,
          draft: draft,
        )) {
      return true;
    }
    final confirmed = await confirm(draft);
    if (confirmed && !_disposed) form.confirmOriginSecrets();
    return confirmed;
  }

  DirectEditorActionResult _conflict(
    DirectEditorMessages messages,
    Object error,
  ) {
    _finishOperation(error: messages.saveConflict);
    return DirectEditorActionResult(
      DirectEditorActionOutcome.conflict,
      error: error,
    );
  }

  DirectEditorActionResult _unavailable(DirectEditorMessages messages) {
    if (!_disposed) _finishOperation(error: messages.unavailable);
    return const DirectEditorActionResult(
      DirectEditorActionOutcome.unavailable,
    );
  }

  bool _operationOwnerIsCurrent() {
    if (_disposed) return false;
    if (!policy.requiresOwnerValidation) return true;
    return state.owner != null && _gateway.ownerIsCurrent(state.owner);
  }

  bool _canContinue() => !_disposed && _operationOwnerIsCurrent();

  void _publish(DirectConnectionEditorState next) {
    if (identical(next, _state)) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _resourceSubscription.close();
    form.removeListener(_handleFormChanged);
    form.dispose();
    super.dispose();
  }
}
