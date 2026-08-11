import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../shared/models/connection_attempt.dart';
import '../models/direct_connection_profile.dart';
import '../models/direct_remote_model.dart';
import '../models/openwebui_direct_connection.dart';
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
}

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
final class DirectEditorSaveRequest {
  const DirectEditorSaveRequest({
    required this.draft,
    required this.previousProfile,
    required this.previousOpenWebUiRecord,
    required this.authentication,
    required this.secretsConfirmedForNewOrigin,
  });

  final DirectConnectionProfile draft;
  final DirectConnectionProfile? previousProfile;
  final OpenWebUiDirectConnectionRecord? previousOpenWebUiRecord;
  final DirectAuthenticationMode authentication;
  final bool secretsConfirmedForNewOrigin;
}

@immutable
final class DirectEditorDeleteRequest {
  const DirectEditorDeleteRequest({
    required this.profile,
    required this.openWebUiRecord,
  });

  final DirectConnectionProfile profile;
  final OpenWebUiDirectConnectionRecord? openWebUiRecord;
}

/// Canonical persistence contract for one concrete editor target.
abstract interface class DirectConnectionEditorTarget {
  DirectConnectionEditorMode get mode;

  Future<DirectConnectionProbe> probe(DirectConnectionProfile profile);

  Future<void> save(DirectEditorSaveRequest request);

  /// Clears a direct preference only when [profileId] is the last usable one.
  Future<bool> clearDirectPreferenceIfLastUsable(String profileId);

  Future<void> restoreDirectPreference();

  Future<void> delete(DirectEditorDeleteRequest request);

  bool isConflict(Object error);

  bool deletionMayHaveCommitted(Object error);
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

typedef DirectEditorOwnerCheck = bool Function();
typedef DirectCredentialTransferConfirmation =
    Future<bool> Function(DirectConnectionProfile draft);
typedef DirectDeleteConfirmation =
    Future<bool> Function(DirectConnectionProfile savedProfile);

/// Owns persistence and the save/test/delete operation state machine.
final class DirectConnectionEditorWorkflow extends ChangeNotifier {
  DirectConnectionEditorWorkflow({required this.target})
    : form = DirectConnectionEditorForm(mode: target.mode) {
    form.addDraftListener(_handleDraftChanged);
    form.addListener(_handleFormChanged);
  }

  final DirectConnectionEditorTarget target;
  final DirectConnectionEditorForm form;

  DirectConnectionEditorState _state = const DirectConnectionEditorState();
  bool _disposed = false;
  bool _deferredNotificationScheduled = false;

  DirectConnectionEditorState get state => _state;
  DirectConnectionEditorMode get mode => target.mode;

  void _handleDraftChanged() {
    _state = state.copyWith(
      attempt: const ConnectionAttemptState.idle(),
      clearOperationError: true,
    );
  }

  void _handleFormChanged() {
    if (!_disposed) notifyListeners();
  }

  void markHydrated() {
    if (state.hydrated) return;
    _recordDuringBuild(state.copyWith(hydrated: true));
  }

  void captureOwner({
    required String serverId,
    required String accountId,
    required Object authEpoch,
  }) {
    if (state.owner != null) return;
    _recordDuringBuild(
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

  Future<DirectEditorActionResult> save({
    required DirectEditorMessages messages,
    required DirectCredentialTransferConfirmation confirmCredentialTransfer,
    required DirectEditorOwnerCheck ownerIsCurrent,
    DirectConnectionProfile? testedDraft,
  }) async {
    if (state.isBusy) {
      return const DirectEditorActionResult(
        DirectEditorActionOutcome.cancelled,
      );
    }
    if (!ownerIsCurrent()) return _unavailable(messages);
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
    if (!_canContinue(ownerIsCurrent)) return _unavailable(messages);

    try {
      await target.save(
        DirectEditorSaveRequest(
          draft: draft,
          previousProfile: form.savedProfile,
          previousOpenWebUiRecord: form.savedOpenWebUiRecord,
          authentication: form.authentication,
          secretsConfirmedForNewOrigin:
              !form.originChanged ||
              !form.savedHasOriginBoundSecrets ||
              form.originSecretsConfirmed,
        ),
      );
      if (!_canContinue(ownerIsCurrent)) return _unavailable(messages);
      _finishOperation(clearError: true);
      return DirectEditorActionResult(
        DirectEditorActionOutcome.succeeded,
        profile: draft,
      );
    } catch (error) {
      if (!_canContinue(ownerIsCurrent)) return _unavailable(messages);
      if (target.isConflict(error)) return _conflict(messages, error);
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
    required DirectEditorOwnerCheck ownerIsCurrent,
  }) async {
    if (state.isBusy) {
      return const DirectEditorActionResult(
        DirectEditorActionOutcome.cancelled,
      );
    }
    if (!ownerIsCurrent()) return _unavailable(messages);
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
    if (!_canContinue(ownerIsCurrent)) return _unavailable(messages);
    _setAttempt(ConnectionAttemptState.connecting(messages.connecting));
    try {
      final probe = await target.probe(draft);
      if (!_canContinue(ownerIsCurrent)) return _unavailable(messages);
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
      if (!_canContinue(ownerIsCurrent)) return _unavailable(messages);
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
    required DirectEditorOwnerCheck ownerIsCurrent,
  }) async {
    final tested = await testConnection(
      messages: messages,
      confirmCredentialTransfer: confirmCredentialTransfer,
      ownerIsCurrent: ownerIsCurrent,
    );
    if (!tested.succeeded || tested.profile == null) return tested;
    return save(
      messages: messages,
      confirmCredentialTransfer: confirmCredentialTransfer,
      ownerIsCurrent: ownerIsCurrent,
      testedDraft: tested.profile,
    );
  }

  Future<DirectEditorActionResult> delete({
    required DirectEditorMessages messages,
    required DirectDeleteConfirmation confirmDelete,
    required DirectEditorOwnerCheck ownerIsCurrent,
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
    if (!ownerIsCurrent()) return _unavailable(messages);
    if (!_beginOperation(DirectEditorOperation.deleting)) {
      return const DirectEditorActionResult(
        DirectEditorActionOutcome.cancelled,
      );
    }
    final confirmed = await confirmDelete(saved);
    if (!_canContinue(ownerIsCurrent)) return _unavailable(messages);
    if (!confirmed) {
      _finishOperation();
      return const DirectEditorActionResult(
        DirectEditorActionOutcome.cancelled,
      );
    }

    var clearedDirectPreference = false;
    try {
      clearedDirectPreference = await target.clearDirectPreferenceIfLastUsable(
        saved.id,
      );
      if (!_canContinue(ownerIsCurrent)) {
        if (clearedDirectPreference) await target.restoreDirectPreference();
        return _unavailable(messages);
      }
      await target.delete(
        DirectEditorDeleteRequest(
          profile: saved,
          openWebUiRecord: form.savedOpenWebUiRecord,
        ),
      );
      if (!_canContinue(ownerIsCurrent)) return _unavailable(messages);
      _finishOperation(clearError: true);
      return const DirectEditorActionResult(
        DirectEditorActionOutcome.succeeded,
      );
    } catch (error) {
      final deletionMayHaveCommitted = target.deletionMayHaveCommitted(error);
      if (clearedDirectPreference && !deletionMayHaveCommitted) {
        await target.restoreDirectPreference();
      }
      if (!_canContinue(ownerIsCurrent)) return _unavailable(messages);
      _finishOperation();
      return DirectEditorActionResult(
        DirectEditorActionOutcome.failed,
        error: error,
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

  bool _canContinue(DirectEditorOwnerCheck ownerIsCurrent) =>
      !_disposed && ownerIsCurrent();

  void _recordDuringBuild(DirectConnectionEditorState next) {
    _state = next;
    if (_deferredNotificationScheduled) return;
    _deferredNotificationScheduled = true;
    scheduleMicrotask(() {
      _deferredNotificationScheduled = false;
      if (!_disposed) notifyListeners();
    });
  }

  void _publish(DirectConnectionEditorState next) {
    if (identical(next, _state)) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    form.removeDraftListener(_handleDraftChanged);
    form.removeListener(_handleFormChanged);
    form.dispose();
    super.dispose();
  }
}
