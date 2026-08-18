import 'package:flutter/widgets.dart';

import '../../../core/utils/debug_logger.dart';
import '../../../shared/models/connection_attempt.dart';
import '../models/hermes_connection_contract.dart';
import '../models/hermes_config.dart';

export '../models/hermes_connection_contract.dart';

enum HermesConnectionOperation { idle, testing, saving, finishing }

extension HermesConnectionOperationState on HermesConnectionOperation {
  bool get isBusy =>
      this == HermesConnectionOperation.testing ||
      this == HermesConnectionOperation.saving ||
      this == HermesConnectionOperation.finishing;
}

enum HermesConnectionValidationIssue { invalidUrl, credentialsReentryRequired }

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
    required this.saved,
    required this.unreachable,
    required this.persistenceFailed,
    required this.activationFailed,
  });

  final String connecting;
  final String connected;
  final String saved;
  final String unreachable;
  final String persistenceFailed;
  final String activationFailed;
}

@immutable
final class _HermesConnectionState {
  const _HermesConnectionState({
    this.operation = HermesConnectionOperation.idle,
    this.attempt = const ConnectionAttemptState.idle(),
    this.validationIssue,
    this.apiKeyDirty = false,
    this.sessionKeyDirty = false,
    this.desktopCredentialsDirty = false,
    this.accessHeadersDirty = false,
    this.showMemoryKey = false,
  });

  static const Object _unchanged = Object();

  final HermesConnectionOperation operation;
  final ConnectionAttemptState attempt;
  final HermesConnectionValidationIssue? validationIssue;
  final bool apiKeyDirty;
  final bool sessionKeyDirty;
  final bool desktopCredentialsDirty;
  final bool accessHeadersDirty;
  final bool showMemoryKey;

  _HermesConnectionState copyWith({
    HermesConnectionOperation? operation,
    ConnectionAttemptState? attempt,
    Object? validationIssue = _unchanged,
    bool? apiKeyDirty,
    bool? sessionKeyDirty,
    bool? desktopCredentialsDirty,
    bool? accessHeadersDirty,
    bool? showMemoryKey,
  }) => _HermesConnectionState(
    operation: operation ?? this.operation,
    attempt: attempt ?? this.attempt,
    validationIssue: identical(validationIssue, _unchanged)
        ? this.validationIssue
        : validationIssue as HermesConnectionValidationIssue?,
    apiKeyDirty: apiKeyDirty ?? this.apiKeyDirty,
    sessionKeyDirty: sessionKeyDirty ?? this.sessionKeyDirty,
    desktopCredentialsDirty:
        desktopCredentialsDirty ?? this.desktopCredentialsDirty,
    accessHeadersDirty: accessHeadersDirty ?? this.accessHeadersDirty,
    showMemoryKey: showMemoryKey ?? this.showMemoryKey,
  );
}

/// Owns the Hermes connection draft, validation, and ordered workflow.
final class HermesConnectionController extends ChangeNotifier {
  HermesConnectionController({
    required HermesConfig initialConfig,
    required HermesConnectionGateway gateway,
  }) : _gateway = gateway,
       url = TextEditingController(text: initialConfig.baseUrl),
       _mode = initialConfig.mode,
       _desktopAuthKind = initialConfig.desktopAuthKind,
       _desktopProfile = initialConfig.desktopProfile,
       _allowSelfSignedCertificates = initialConfig.allowSelfSignedCertificates,
       _initialAccessHeaders = Map.of(initialConfig.accessHeaders),
       _accessHeaders = Map.of(initialConfig.accessHeaders);

  final HermesConnectionGateway _gateway;

  final TextEditingController url;
  final TextEditingController apiKey = TextEditingController();
  final TextEditingController sessionKey = TextEditingController();
  final TextEditingController desktopLegacyToken = TextEditingController();
  HermesBackendMode _mode;
  HermesDesktopAuthKind _desktopAuthKind;
  String _desktopProfile;
  bool _allowSelfSignedCertificates;
  Map<String, String> _initialAccessHeaders;
  Map<String, String> _accessHeaders;

  _HermesConnectionState _state = const _HermesConnectionState();
  bool _isDisposed = false;
  int _operationEpoch = 0;

  HermesConnectionOperation get operation => _state.operation;
  ConnectionAttemptState get attempt => _state.attempt;
  HermesConnectionValidationIssue? get validationIssue =>
      _state.validationIssue;
  bool get apiKeyDirty => _state.apiKeyDirty;
  bool get sessionKeyDirty => _state.sessionKeyDirty;
  bool get desktopCredentialsDirty => _state.desktopCredentialsDirty;
  bool get accessHeadersDirty => _state.accessHeadersDirty;
  bool get showMemoryKey => _state.showMemoryKey;
  HermesBackendMode get mode => _mode;
  HermesDesktopAuthKind get desktopAuthKind => _desktopAuthKind;
  String get desktopProfile => _desktopProfile;
  bool get allowSelfSignedCertificates => _allowSelfSignedCertificates;
  Map<String, String> get accessHeaders => Map.unmodifiable(_accessHeaders);

  void reportFailure(String message) {
    _publish(
      _state.copyWith(
        operation: HermesConnectionOperation.idle,
        attempt: ConnectionAttemptState.failed(message),
      ),
    );
  }

  bool draftIsUsable(HermesConfig saved) => _validate(saved) == null;

  HermesConnectionDraft buildDraft(HermesConfig saved) {
    final trimmedUrl = url.text.trim();
    final originChanged = _originChanged(saved, trimmedUrl);
    final trimmedApiKey = apiKey.text.trim();
    final trimmedSessionKey = sessionKey.text.trim();
    final trimmedLegacyToken = desktopLegacyToken.text.trim();
    final previousDesktop = saved.desktopCredentials;
    final initialHeadersByName = {
      for (final entry in _initialAccessHeaders.entries)
        entry.key.toLowerCase(): entry.value,
    };
    final initialHeaderValues = _initialAccessHeaders.values.toSet();
    final newOriginHeaders = <String, String>{
      for (final entry in _accessHeaders.entries)
        if (initialHeadersByName[entry.key.toLowerCase()] != entry.value &&
            !initialHeaderValues.contains(entry.value))
          entry.key: entry.value,
    };
    final nextDesktop = originChanged
        ? HermesDesktopCredentials(
            legacyToken: trimmedLegacyToken.isEmpty ? null : trimmedLegacyToken,
            accessHeaders: accessHeadersDirty ? newOriginHeaders : const {},
          )
        : desktopCredentialsDirty
        ? HermesDesktopCredentials(
            legacyToken: trimmedLegacyToken.isEmpty
                ? previousDesktop?.legacyToken
                : trimmedLegacyToken,
            nativeTokens: previousDesktop?.nativeTokens,
            accessHeaders: _accessHeaders,
          )
        : previousDesktop;
    return HermesConnectionDraft(
      config: HermesConfig(
        enabled: true,
        baseUrl: trimmedUrl,
        mode: _mode,
        desktopAuthKind: _desktopAuthKind,
        desktopProfile: _desktopProfile,
        allowSelfSignedCertificates: _allowSelfSignedCertificates,
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
        desktopCredentials: nextDesktop,
      ),
      apiKeyChanged: originChanged || apiKeyDirty,
      sessionKeyChanged: originChanged || sessionKeyDirty,
      desktopCredentialsChanged: originChanged || desktopCredentialsDirty,
    );
  }

  void markUrlChanged() => _markDraftChanged();

  void markApiKeyChanged() => _markDraftChanged(apiKeyDirty: true);

  void markSessionKeyChanged() => _markDraftChanged(sessionKeyDirty: true);

  void markDesktopLegacyTokenChanged() =>
      _markDraftChanged(desktopCredentialsDirty: true);

  void setMode(HermesBackendMode value) {
    if (_mode == value) return;
    _mode = value;
    _markDraftChanged();
  }

  void setDesktopAuthKind(HermesDesktopAuthKind value) {
    if (_desktopAuthKind == value) return;
    _desktopAuthKind = value;
    _markDraftChanged();
  }

  void setDesktopProfile(String value) {
    final normalized = value.trim();
    if (!HermesConfig.isValidDesktopProfile(normalized) ||
        _desktopProfile == normalized) {
      return;
    }
    _desktopProfile = normalized;
    _markDraftChanged();
  }

  void setAllowSelfSignedCertificates(bool value) {
    if (_allowSelfSignedCertificates == value) return;
    _allowSelfSignedCertificates = value;
    _markDraftChanged();
  }

  String? setAccessHeaders(Map<String, String> value) {
    final error = HermesConfig.validateAccessHeaders(value);
    if (error != null) return error;
    _accessHeaders = Map.of(value);
    _markDraftChanged(desktopCredentialsDirty: true, accessHeadersDirty: true);
    return null;
  }

  void setShowMemoryKey(bool value) {
    if (showMemoryKey == value) return;
    _publish(_state.copyWith(showMemoryKey: value));
  }

  Future<bool> testConnection({
    required HermesConfig saved,
    required HermesConnectionMessages messages,
  }) async {
    if (operation.isBusy) return false;
    final draft = _validatedDraft(saved);
    if (draft == null) return false;
    final operationEpoch = _beginOperation(
      HermesConnectionOperation.testing,
      attempt: ConnectionAttemptState.connecting(messages.connecting),
    );
    if (operationEpoch == null) return false;

    bool reachable;
    try {
      reachable = await _gateway.probe(draft.config);
    } catch (_) {
      reachable = false;
    }
    _publishIfOwned(
      operationEpoch,
      _state.copyWith(
        operation: HermesConnectionOperation.idle,
        attempt: reachable
            ? ConnectionAttemptState.connected(messages.connected)
            : ConnectionAttemptState.failed(messages.unreachable),
      ),
    );
    return reachable;
  }

  Future<bool> save(
    HermesConfig saved, {
    required HermesConnectionMessages messages,
  }) async {
    if (operation.isBusy) return false;
    final draft = _validatedDraft(saved);
    if (draft == null) return false;
    final operationEpoch = _beginOperation(HermesConnectionOperation.saving);
    if (operationEpoch == null) return false;

    try {
      await _gateway.persist(draft);
      if (!_ownsOperation(operationEpoch)) return true;
      _acceptPersistedDraft(
        operationEpoch,
        persistedConfig: draft.config,
        attempt: ConnectionAttemptState.connected(messages.saved),
      );
      return true;
    } catch (_) {
      _publishIfOwned(
        operationEpoch,
        _state.copyWith(
          operation: HermesConnectionOperation.idle,
          attempt: ConnectionAttemptState.failed(messages.persistenceFailed),
        ),
      );
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

    final operationEpoch = _beginOperation(
      HermesConnectionOperation.finishing,
      attempt: ConnectionAttemptState.connecting(messages.connecting),
    );
    if (operationEpoch == null) {
      return const HermesConnectionResult(HermesConnectionOutcome.ignored);
    }

    try {
      final reachable = await _gateway.probe(draft.config);
      if (!_ownsOperation(operationEpoch)) {
        return const HermesConnectionResult(HermesConnectionOutcome.ignored);
      }
      if (!reachable) {
        _publish(
          _state.copyWith(
            operation: HermesConnectionOperation.idle,
            attempt: ConnectionAttemptState.failed(messages.unreachable),
          ),
        );
        return const HermesConnectionResult(
          HermesConnectionOutcome.unreachable,
        );
      }
    } catch (error) {
      if (!_ownsOperation(operationEpoch)) {
        return const HermesConnectionResult(HermesConnectionOutcome.ignored);
      }
      _publish(
        _state.copyWith(
          operation: HermesConnectionOperation.idle,
          attempt: ConnectionAttemptState.failed(messages.unreachable),
        ),
      );
      return HermesConnectionResult(HermesConnectionOutcome.unreachable, error);
    }

    _publish(
      _state.copyWith(
        attempt: ConnectionAttemptState.connected(messages.connected),
      ),
    );

    try {
      await _gateway.commitOnboarding(
        draft,
        isCurrent: () => _ownsOperation(operationEpoch),
      );
      if (!_ownsOperation(operationEpoch)) {
        return const HermesConnectionResult(HermesConnectionOutcome.ignored);
      }
    } on HermesConnectionCommitCancelled {
      return const HermesConnectionResult(HermesConnectionOutcome.ignored);
    } on HermesConnectionCommitException catch (failure) {
      final rollbackFailed =
          failure.stage == HermesConnectionCommitStage.rollback;
      if (rollbackFailed) _logCommitFailure(failure);
      if (!_ownsOperation(operationEpoch)) {
        return rollbackFailed
            ? HermesConnectionResult(
                HermesConnectionOutcome.activationFailed,
                failure.rollbackError ?? failure.error,
              )
            : const HermesConnectionResult(HermesConnectionOutcome.ignored);
      }
      if (failure.stage == HermesConnectionCommitStage.persistence) {
        _publish(
          _state.copyWith(
            operation: HermesConnectionOperation.idle,
            attempt: ConnectionAttemptState.failed(messages.persistenceFailed),
          ),
        );
        return HermesConnectionResult(
          HermesConnectionOutcome.persistenceFailed,
          failure.error,
        );
      }
      if (!rollbackFailed) _logCommitFailure(failure);
      _publish(
        _state.copyWith(
          operation: HermesConnectionOperation.idle,
          attempt: ConnectionAttemptState.failed(messages.activationFailed),
        ),
      );
      return HermesConnectionResult(
        HermesConnectionOutcome.activationFailed,
        failure.rollbackError ?? failure.error,
      );
    }

    _acceptPersistedDraft(operationEpoch, persistedConfig: draft.config);
    return const HermesConnectionResult(HermesConnectionOutcome.success);
  }

  void _logCommitFailure(HermesConnectionCommitException failure) {
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
  }

  HermesConnectionDraft? _validatedDraft(HermesConfig saved) {
    final issue = _validate(saved);
    if (issue != null) {
      _publish(_state.copyWith(validationIssue: issue));
      return null;
    }
    _state = _state.copyWith(validationIssue: null);
    return buildDraft(saved);
  }

  HermesConnectionValidationIssue? _validate(HermesConfig saved) {
    final trimmedUrl = url.text.trim();
    if (HermesConfig.connectionOrigin(trimmedUrl) == null) {
      return HermesConnectionValidationIssue.invalidUrl;
    }
    final draft = buildDraft(saved).config;
    if (draft.mode == HermesBackendMode.responsesApi &&
        (draft.apiKey?.trim().isEmpty ?? true)) {
      return HermesConnectionValidationIssue.credentialsReentryRequired;
    }
    return null;
  }

  bool _originChanged(HermesConfig saved, String nextUrl) =>
      HermesConfig.connectionOrigin(saved.baseUrl) !=
      HermesConfig.connectionOrigin(nextUrl);

  int? _beginOperation(
    HermesConnectionOperation operation, {
    ConnectionAttemptState? attempt,
  }) {
    if (_state.operation.isBusy || _isDisposed) return null;
    final epoch = ++_operationEpoch;
    _publish(
      _state.copyWith(
        operation: operation,
        attempt: attempt ?? const ConnectionAttemptState.idle(),
        validationIssue: null,
      ),
    );
    return epoch;
  }

  bool _ownsOperation(int epoch) => !_isDisposed && epoch == _operationEpoch;

  bool _publishIfOwned(int epoch, _HermesConnectionState next) {
    if (!_ownsOperation(epoch)) return false;
    _publish(next);
    return true;
  }

  void cancelPendingOnboarding() {
    if (operation != HermesConnectionOperation.finishing) return;
    _operationEpoch++;
    _publish(
      _state.copyWith(
        operation: HermesConnectionOperation.idle,
        attempt: const ConnectionAttemptState.idle(),
      ),
    );
  }

  void _acceptPersistedDraft(
    int operationEpoch, {
    required HermesConfig persistedConfig,
    ConnectionAttemptState? attempt,
  }) {
    if (!_ownsOperation(operationEpoch)) return;
    _accessHeaders = Map.of(persistedConfig.accessHeaders);
    _initialAccessHeaders = Map.of(persistedConfig.accessHeaders);
    apiKey.clear();
    sessionKey.clear();
    desktopLegacyToken.clear();
    _publish(
      _state.copyWith(
        operation: HermesConnectionOperation.idle,
        attempt: attempt,
        validationIssue: null,
        apiKeyDirty: false,
        sessionKeyDirty: false,
        desktopCredentialsDirty: false,
        accessHeadersDirty: false,
      ),
    );
  }

  void _markDraftChanged({
    bool? apiKeyDirty,
    bool? sessionKeyDirty,
    bool? desktopCredentialsDirty,
    bool? accessHeadersDirty,
  }) {
    if (_state.operation.isBusy) _operationEpoch++;
    _publish(
      _state.copyWith(
        validationIssue: null,
        operation: HermesConnectionOperation.idle,
        attempt: const ConnectionAttemptState.idle(),
        apiKeyDirty: apiKeyDirty,
        sessionKeyDirty: sessionKeyDirty,
        desktopCredentialsDirty: desktopCredentialsDirty,
        accessHeadersDirty: accessHeadersDirty,
      ),
    );
  }

  void _publish(_HermesConnectionState next) {
    if (_isDisposed) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _operationEpoch++;
    url.dispose();
    apiKey.dispose();
    sessionKey.dispose();
    desktopLegacyToken.dispose();
    super.dispose();
  }
}
