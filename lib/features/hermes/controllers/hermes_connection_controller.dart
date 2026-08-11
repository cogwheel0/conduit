import 'package:flutter/widgets.dart';

import '../../../core/utils/debug_logger.dart';
import '../../../shared/models/connection_attempt.dart';
import '../models/hermes_config.dart';

enum HermesConnectionOperation { idle, testing, saving, finishing, saved }

extension HermesConnectionOperationState on HermesConnectionOperation {
  bool get isBusy =>
      this == HermesConnectionOperation.testing ||
      this == HermesConnectionOperation.saving ||
      this == HermesConnectionOperation.finishing;
}

enum HermesConnectionValidationIssue {
  invalidUrl,
  credentialsReentryRequired,
  persistenceFailed,
}

enum HermesConnectionOutcome {
  ignored,
  validationFailed,
  unreachable,
  persistenceFailed,
  activationFailed,
  success,
}

@immutable
final class HermesConnectionResult {
  const HermesConnectionResult(this.outcome, [this.error]);

  final HermesConnectionOutcome outcome;
  final Object? error;
}

@immutable
final class HermesConnectionMessages {
  const HermesConnectionMessages({
    required this.connecting,
    required this.connected,
    required this.unreachable,
    required this.persistenceFailed,
    required this.activationFailed,
  });

  final String connecting;
  final String connected;
  final String unreachable;
  final String persistenceFailed;
  final String activationFailed;
}

@immutable
final class HermesConnectionDraft {
  const HermesConnectionDraft({
    required this.config,
    required this.apiKeyChanged,
    required this.sessionKeyChanged,
  });

  final HermesConfig config;
  final bool apiKeyChanged;
  final bool sessionKeyChanged;
}

enum HermesConnectionCommitStage { persistence, activation, rollback }

final class HermesConnectionCommitException implements Exception {
  const HermesConnectionCommitException({
    required this.stage,
    required this.error,
    this.rollbackError,
  });

  final HermesConnectionCommitStage stage;
  final Object error;
  final Object? rollbackError;
}

final class HermesConnectionCommitCancelled implements Exception {
  const HermesConnectionCommitCancelled();
}

abstract interface class HermesConnectionGateway {
  Future<bool> probe(HermesConfig draft);

  Future<void> persist(HermesConnectionDraft draft);

  Future<void> commitOnboarding(
    HermesConnectionDraft draft, {
    required bool Function() isCurrent,
  });
}

/// Owns the Hermes connection draft, validation, and ordered workflow.
final class HermesConnectionController extends ChangeNotifier {
  HermesConnectionController({
    required HermesConfig initialConfig,
    required HermesConnectionGateway gateway,
  }) : _gateway = gateway,
       url = TextEditingController(text: initialConfig.baseUrl);

  final HermesConnectionGateway _gateway;

  final TextEditingController url;
  final TextEditingController apiKey = TextEditingController();
  final TextEditingController sessionKey = TextEditingController();

  HermesConnectionOperation operation = HermesConnectionOperation.idle;
  ConnectionAttemptState attempt = const ConnectionAttemptState.idle();
  HermesConnectionValidationIssue? validationIssue;
  bool apiKeyDirty = false;
  bool sessionKeyDirty = false;
  bool showMemoryKey = false;
  bool _isDisposed = false;
  int _onboardingEpoch = 0;

  bool draftIsUsable(HermesConfig saved) => _validate(saved) == null;

  HermesConnectionDraft buildDraft(HermesConfig saved) {
    final trimmedUrl = url.text.trim();
    final originChanged = _originChanged(saved, trimmedUrl);
    final trimmedApiKey = apiKey.text.trim();
    final trimmedSessionKey = sessionKey.text.trim();
    return HermesConnectionDraft(
      config: HermesConfig(
        enabled: true,
        baseUrl: trimmedUrl,
        apiKey: originChanged || apiKeyDirty
            ? (trimmedApiKey.isEmpty ? null : trimmedApiKey)
            : saved.apiKey,
        sessionKey: originChanged
            ? (sessionKeyDirty && trimmedSessionKey.isNotEmpty
                  ? trimmedSessionKey
                  : null)
            : sessionKeyDirty
            ? (trimmedSessionKey.isEmpty ? null : trimmedSessionKey)
            : saved.sessionKey,
      ),
      apiKeyChanged: originChanged || apiKeyDirty,
      sessionKeyChanged: originChanged || sessionKeyDirty,
    );
  }

  void markUrlChanged() => _markDraftChanged();

  void markApiKeyChanged() {
    apiKeyDirty = true;
    _markDraftChanged();
  }

  void markSessionKeyChanged() {
    sessionKeyDirty = true;
    _markDraftChanged();
  }

  void setShowMemoryKey(bool value) {
    if (showMemoryKey == value) return;
    showMemoryKey = value;
    _notifyListeners();
  }

  Future<bool> testConnection({
    required HermesConfig saved,
    required HermesConnectionMessages messages,
  }) async {
    if (operation.isBusy) return false;
    final draft = _validatedDraft(saved);
    if (draft == null) return false;
    operation = HermesConnectionOperation.testing;
    attempt = ConnectionAttemptState.connecting(messages.connecting);
    _notifyListeners();

    bool reachable;
    try {
      reachable = await _gateway.probe(draft.config);
    } catch (_) {
      reachable = false;
    }
    operation = HermesConnectionOperation.idle;
    attempt = reachable
        ? ConnectionAttemptState.connected(messages.connected)
        : ConnectionAttemptState.failed(messages.unreachable);
    _notifyListeners();
    return reachable;
  }

  Future<bool> save(HermesConfig saved) async {
    if (operation.isBusy) return false;
    final draft = _validatedDraft(saved);
    if (draft == null) return false;
    operation = HermesConnectionOperation.saving;
    _notifyListeners();

    try {
      await _gateway.persist(draft);
      if (_isDisposed) return true;
      _acceptPersistedDraft();
      operation = HermesConnectionOperation.saved;
      _notifyListeners();
      return true;
    } catch (_) {
      operation = HermesConnectionOperation.idle;
      validationIssue = HermesConnectionValidationIssue.persistenceFailed;
      _notifyListeners();
      return false;
    }
  }

  Future<HermesConnectionResult> finishOnboarding({
    required HermesConfig saved,
    required HermesConnectionMessages messages,
  }) async {
    if (operation.isBusy) {
      return const HermesConnectionResult(HermesConnectionOutcome.ignored);
    }
    final draft = _validatedDraft(saved);
    if (draft == null) {
      return const HermesConnectionResult(
        HermesConnectionOutcome.validationFailed,
      );
    }

    operation = HermesConnectionOperation.finishing;
    final onboardingEpoch = ++_onboardingEpoch;
    attempt = ConnectionAttemptState.connecting(messages.connecting);
    _notifyListeners();

    try {
      if (!await _gateway.probe(draft.config)) {
        operation = HermesConnectionOperation.idle;
        attempt = ConnectionAttemptState.failed(messages.unreachable);
        _notifyListeners();
        return const HermesConnectionResult(
          HermesConnectionOutcome.unreachable,
        );
      }
      if (!_ownsOnboarding(onboardingEpoch)) {
        return const HermesConnectionResult(HermesConnectionOutcome.ignored);
      }
    } catch (error) {
      if (!_ownsOnboarding(onboardingEpoch)) {
        return const HermesConnectionResult(HermesConnectionOutcome.ignored);
      }
      operation = HermesConnectionOperation.idle;
      attempt = ConnectionAttemptState.failed(messages.unreachable);
      _notifyListeners();
      return HermesConnectionResult(HermesConnectionOutcome.unreachable, error);
    }

    attempt = ConnectionAttemptState.connected(messages.connected);
    _notifyListeners();

    try {
      await _gateway.commitOnboarding(
        draft,
        isCurrent: () => _ownsOnboarding(onboardingEpoch),
      );
      if (!_ownsOnboarding(onboardingEpoch)) {
        return const HermesConnectionResult(HermesConnectionOutcome.ignored);
      }
      _acceptPersistedDraft();
    } on HermesConnectionCommitCancelled {
      return const HermesConnectionResult(HermesConnectionOutcome.ignored);
    } on HermesConnectionCommitException catch (failure) {
      operation = HermesConnectionOperation.idle;
      if (failure.stage == HermesConnectionCommitStage.persistence) {
        validationIssue = HermesConnectionValidationIssue.persistenceFailed;
        attempt = ConnectionAttemptState.failed(messages.persistenceFailed);
        _notifyListeners();
        return HermesConnectionResult(
          HermesConnectionOutcome.persistenceFailed,
          failure.error,
        );
      }
      DebugLogger.error(
        'onboarding-failed',
        scope: 'hermes/onboarding',
        data: {
          'stage': failure.stage.name,
          'errorType': failure.error.runtimeType.toString(),
          if (failure.rollbackError != null)
            'rollbackErrorType': failure.rollbackError.runtimeType.toString(),
        },
      );
      attempt = ConnectionAttemptState.failed(messages.activationFailed);
      _notifyListeners();
      return HermesConnectionResult(
        HermesConnectionOutcome.activationFailed,
        failure.error,
      );
    }

    operation = HermesConnectionOperation.saved;
    _notifyListeners();
    return const HermesConnectionResult(HermesConnectionOutcome.success);
  }

  HermesConnectionDraft? _validatedDraft(HermesConfig saved) {
    validationIssue = _validate(saved);
    if (validationIssue != null) {
      _notifyListeners();
      return null;
    }
    return buildDraft(saved);
  }

  HermesConnectionValidationIssue? _validate(HermesConfig saved) {
    final trimmedUrl = url.text.trim();
    if (HermesConfig.connectionOrigin(trimmedUrl) == null) {
      return HermesConnectionValidationIssue.invalidUrl;
    }
    final draft = buildDraft(saved).config;
    if (draft.apiKey?.trim().isEmpty ?? true) {
      return HermesConnectionValidationIssue.credentialsReentryRequired;
    }
    return null;
  }

  bool _originChanged(HermesConfig saved, String nextUrl) =>
      HermesConfig.connectionOrigin(saved.baseUrl) !=
      HermesConfig.connectionOrigin(nextUrl);

  bool _ownsOnboarding(int epoch) => !_isDisposed && epoch == _onboardingEpoch;

  void cancelPendingOperation() {
    _onboardingEpoch++;
    if (operation != HermesConnectionOperation.finishing) return;
    operation = HermesConnectionOperation.idle;
    attempt = const ConnectionAttemptState.idle();
    _notifyListeners();
  }

  void _acceptPersistedDraft() {
    apiKey.clear();
    sessionKey.clear();
    apiKeyDirty = false;
    sessionKeyDirty = false;
    validationIssue = null;
  }

  void _markDraftChanged() {
    validationIssue = null;
    operation = HermesConnectionOperation.idle;
    attempt = const ConnectionAttemptState.idle();
    _notifyListeners();
  }

  void _notifyListeners() {
    if (!_isDisposed) notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _onboardingEpoch++;
    url.dispose();
    apiKey.dispose();
    sessionKey.dispose();
    super.dispose();
  }
}
