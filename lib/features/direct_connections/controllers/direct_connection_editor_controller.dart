import 'package:flutter/widgets.dart';

import '../../../shared/models/connection_attempt.dart';
import '../models/direct_connection_profile.dart';
import '../models/openwebui_direct_connection.dart';
import '../services/direct_connection_profile_store.dart';
import '../services/openwebui_direct_connection_store.dart';
import 'direct_custom_headers_controller.dart';
import 'direct_connection_editor_draft.dart';
import 'direct_connection_editor_workflow.dart';

export 'direct_custom_headers_controller.dart'
    show DirectHeaderValidationError, DirectHeaderValidationIssue;
export 'direct_connection_editor_draft.dart';
export 'direct_connection_editor_workflow.dart';

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

/// Owns the direct draft and the complete save/test/delete state machine.
final class DirectConnectionEditorController extends ChangeNotifier {
  DirectConnectionEditorController({
    required this.isOpenWebUi,
    required this.isNew,
    required this.gateway,
  }) {
    headers = DirectCustomHeadersController(
      onHeadersChanged: _headersChanged,
      onInputChanged: _headerInputChanged,
    );
    name.addListener(_generalTextChanged);
    baseUrl.addListener(_baseUrlTextChanged);
    apiKey.addListener(_apiKeyTextChanged);
    apiVersion.addListener(_generalTextChanged);
    modelIdPrefix.addListener(_generalTextChanged);
    tags.addListener(_generalTextChanged);
    models.addListener(_generalTextChanged);
  }

  final bool isOpenWebUi;
  final bool isNew;
  final DirectConnectionEditorGateway gateway;

  late final DirectCustomHeadersController headers;

  final name = TextEditingController();
  final baseUrl = TextEditingController();
  final apiKey = TextEditingController();
  final apiVersion = TextEditingController();
  final modelIdPrefix = TextEditingController();
  final tags = TextEditingController();
  final models = TextEditingController();
  TextEditingController get headerName => headers.name;
  TextEditingController get headerValue => headers.value;
  FocusNode get headerValueFocusNode => headers.valueFocusNode;
  Map<String, String> get customHeaders => headers.headers;

  DirectConnectionProfile? _savedProfile;
  OpenWebUiDirectConnectionRecord? _savedOpenWebUiRecord;
  String _adapterKey = kOpenAiCompatibleAdapterKey;
  String _providerPreset = kOpenAiCompatibleAdapterKey;
  DirectOpenAiApiMode _openAiApiMode = DirectOpenAiApiMode.chatCompletions;
  DirectAuthenticationMode _authentication = DirectAuthenticationMode.bearer;
  bool _enabled = true;
  bool _apiKeyDirty = false;
  bool _showApiKey = false;
  bool _showAdvancedSettings = false;
  bool _originSecretsConfirmed = false;
  bool _updatingTextFields = false;
  bool _disposed = false;
  DirectDraftErrors _errors = const DirectDraftErrors();
  DirectConnectionEditorState _state = const DirectConnectionEditorState();

  DirectConnectionEditorState get state => _state;

  DirectConnectionProfile? get savedProfile => _savedProfile;
  OpenWebUiDirectConnectionRecord? get savedOpenWebUiRecord =>
      _savedOpenWebUiRecord;
  String get adapterKey => _adapterKey;
  String get providerPreset => _providerPreset;
  DirectOpenAiApiMode get openAiApiMode => _openAiApiMode;
  DirectAuthenticationMode get authentication => _authentication;
  bool get enabled => _enabled;
  bool get apiKeyDirty => _apiKeyDirty;
  bool get showApiKey => _showApiKey;
  bool get showAdvancedSettings => _showAdvancedSettings;
  bool get originSecretsConfirmed => _originSecretsConfirmed;
  DirectDraftErrors get errors => _errors;
  DirectHeaderValidationError? get headerError => headers.error;

  bool get isOllama => adapterKey == kOllamaAdapterKey;
  bool get isOpenRouter => providerPreset == kOpenRouterProviderPreset;

  bool get originChanged {
    final saved = savedProfile;
    if (saved == null) return false;
    return DirectConnectionProfile.originOf(saved.baseUrl) !=
        DirectConnectionProfile.originOf(baseUrl.text);
  }

  bool get savedHasOriginBoundSecrets {
    final saved = savedProfile;
    return saved != null &&
        ((saved.apiKey?.isNotEmpty ?? false) || saved.customHeaders.isNotEmpty);
  }

  bool get originBoundSecretsReviewed {
    final saved = savedProfile;
    if (saved == null || !originChanged) return true;
    final apiKeyReviewed = !(saved.apiKey?.isNotEmpty ?? false) || apiKeyDirty;
    final headersReviewed = saved.customHeaders.isEmpty || headers.isDirty;
    return apiKeyReviewed && headersReviewed;
  }

  bool get canAddCustomHeader => headerName.text.trim().isNotEmpty;

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

  void captureOwner({
    required String serverId,
    required String accountId,
    required Object authEpoch,
  }) {
    if (state.owner != null) return;
    _state = state.copyWith(
      owner: DirectEditorOwner(
        serverId: serverId,
        accountId: accountId,
        authEpoch: authEpoch,
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

  void hydrateOnce(
    DirectConnectionProfile? profile, {
    OpenWebUiDirectConnectionRecord? openWebUiRecord,
  }) {
    if (state.hydrated) return;
    _state = state.copyWith(hydrated: true);
    hydrate(profile, openWebUiRecord: openWebUiRecord);
  }

  bool get apiKeyRequired => requiresDirectApiKey(
    authentication: authentication,
    isOpenWebUi: isOpenWebUi,
    isNew: isNew,
    savedOpenWebUiAuthType: savedOpenWebUiRecord?.authType,
    apiKeyDirty: apiKeyDirty,
    originChanged: originChanged,
  );

  void hydrate(
    DirectConnectionProfile? profile, {
    OpenWebUiDirectConnectionRecord? openWebUiRecord,
  }) {
    _updateTextFields(() {
      _savedProfile = profile;
      _savedOpenWebUiRecord = openWebUiRecord;
      if (profile == null) {
        name.text = 'My provider';
        baseUrl.text = 'https://api.openai.com/v1';
        return;
      }
      name.text = profile.name;
      baseUrl.text = profile.baseUrl;
      headers.hydrate(profile.customHeaders);
      models.text = profile.manualModelIds.join('\n');
      apiVersion.text = profile.apiVersion ?? '';
      modelIdPrefix.text = profile.modelIdPrefix ?? '';
      tags.text = profile.tags.join(', ');
      _adapterKey = profile.adapterKey;
      _providerPreset = profile.isOpenRouter
          ? kOpenRouterProviderPreset
          : profile.adapterKey;
      _openAiApiMode = profile.openAiApiMode;
      _authentication = openWebUiRecord == null
          ? profile.isOpenRouter
                ? DirectAuthenticationMode.bearer
                : (profile.apiKey ?? '').isEmpty
                ? DirectAuthenticationMode.none
                : switch (profile.apiKeyAuthMode) {
                    DirectApiKeyAuthMode.bearer =>
                      DirectAuthenticationMode.bearer,
                    DirectApiKeyAuthMode.apiKeyHeader =>
                      DirectAuthenticationMode.apiKeyHeader,
                  }
          : switch (openWebUiRecord.authType) {
              'bearer' => DirectAuthenticationMode.bearer,
              'none' => DirectAuthenticationMode.none,
              _ => DirectAuthenticationMode.unsupported,
            };
      _enabled = profile.enabled;
    });
  }

  void refreshOpenWebUiRecord(OpenWebUiDirectConnectionRecord? record) {
    final savedRecord = savedOpenWebUiRecord;
    if (record == null ||
        savedRecord == null ||
        savedRecord.profile.id != record.profile.id ||
        savedRecord.contentRevision != record.contentRevision) {
      return;
    }
    _savedOpenWebUiRecord = record;
    _savedProfile = record.profile;
  }

  void setEnabled(bool value) {
    if (enabled == value) return;
    _enabled = value;
    _draftChanged();
  }

  void selectProviderPreset(
    String value, {
    required String ollamaDefaultName,
    required String openRouterDefaultName,
  }) {
    if (providerPreset == value) return;
    _providerPreset = value;
    _adapterKey = value == kOllamaAdapterKey
        ? kOllamaAdapterKey
        : kOpenAiCompatibleAdapterKey;
    _authentication = DirectAuthenticationMode.bearer;
    _openAiApiMode = DirectOpenAiApiMode.chatCompletions;
    _updateTextFields(() {
      baseUrl.text = switch (value) {
        kOllamaAdapterKey => 'https://ollama.com',
        kOpenRouterProviderPreset => kOpenRouterApiBaseUrl,
        _ => 'https://api.openai.com/v1',
      };
      if (isNew &&
          (name.text == 'My provider' ||
              name.text == ollamaDefaultName ||
              name.text == openRouterDefaultName)) {
        name.text = switch (value) {
          kOllamaAdapterKey => ollamaDefaultName,
          kOpenRouterProviderPreset => openRouterDefaultName,
          _ => 'My provider',
        };
      }
    });
    _originSecretsConfirmed = false;
    _draftChanged();
  }

  void setAuthentication(DirectAuthenticationMode value) {
    if (authentication == value ||
        value == DirectAuthenticationMode.unsupported) {
      return;
    }
    _authentication = value;
    _apiKeyDirty = true;
    _originSecretsConfirmed = false;
    _errors = errors.copyWith(clearApiKey: true, clearForm: true);
    _draftChanged();
  }

  void setOpenAiApiMode(DirectOpenAiApiMode value) {
    if (openAiApiMode == value) return;
    _openAiApiMode = value;
    _draftChanged();
  }

  void setShowApiKey(bool value) {
    if (showApiKey == value) return;
    _showApiKey = value;
    notifyListeners();
  }

  void setShowAdvancedSettings(bool value) {
    if (showAdvancedSettings == value) return;
    _showAdvancedSettings = value;
    notifyListeners();
  }

  void _generalTextChanged() {
    if (_updatingTextFields) return;
    _errors = const DirectDraftErrors();
    headers.clearError();
    _draftChanged();
  }

  void _baseUrlTextChanged() {
    if (_updatingTextFields) return;
    _originSecretsConfirmed = false;
    _generalTextChanged();
  }

  void _apiKeyTextChanged() {
    if (_updatingTextFields) return;
    _apiKeyDirty = true;
    _originSecretsConfirmed = false;
    _errors = errors.copyWith(clearApiKey: true, clearForm: true);
    _draftChanged();
  }

  void _headerInputChanged() {
    _errors = errors.copyWith(clearForm: true);
    _draftChanged();
  }

  bool commitPendingCustomHeader() {
    final committed = headers.commitPending();
    if (!committed) {
      _revealAdvancedSettings();
    }
    return committed;
  }

  bool addCustomHeader() {
    final added = headers.add();
    if (!added && headers.error != null) _revealAdvancedSettings();
    return added;
  }

  void removeCustomHeader(String name) => headers.remove(name);

  DirectDraftBuildResult buildDraft({
    required bool validateFields,
    required String openWebUiFallbackName,
  }) {
    if (validateFields && !commitPendingCustomHeader()) {
      return DirectDraftBuildResult(errors: errors);
    }
    final draft = DirectConnectionDraft(
      isOpenWebUi: isOpenWebUi,
      isNew: isNew,
      savedProfile: savedProfile,
      savedOpenWebUiAuthType: savedOpenWebUiRecord?.authType,
      adapterKey: adapterKey,
      providerPreset: providerPreset,
      openAiApiMode: openAiApiMode,
      authentication: authentication,
      enabled: enabled,
      apiKeyDirty: apiKeyDirty,
      originBoundSecretsReviewed: originBoundSecretsReviewed,
      name: name.text,
      baseUrl: baseUrl.text,
      apiKey: apiKey.text,
      apiVersion: apiVersion.text,
      modelIdPrefix: modelIdPrefix.text,
      tags: tags.text,
      models: models.text,
      customHeaders: customHeaders,
    );
    final result = draft.build(openWebUiFallbackName: openWebUiFallbackName);
    _errors = result.errors;
    if (validateFields && errors.hasAny) notifyListeners();
    return result;
  }

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
        buildDraft(
          validateFields: true,
          openWebUiFallbackName: messages.openWebUiFallbackName,
        ).profile;
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
      if (isOpenWebUi) {
        await gateway.saveOpenWebUi(
          draft: draft,
          previous: savedOpenWebUiRecord,
          isNew: isNew,
          authType: switch (authentication) {
            DirectAuthenticationMode.bearer => 'bearer',
            DirectAuthenticationMode.none => 'none',
            DirectAuthenticationMode.apiKeyHeader ||
            DirectAuthenticationMode.unsupported => null,
          },
        );
      } else {
        await gateway.saveLocal(
          draft: draft,
          expectedPrevious: savedProfile,
          secretsConfirmedForNewOrigin:
              !originChanged ||
              !savedHasOriginBoundSecrets ||
              originSecretsConfirmed,
        );
      }
      if (!_canContinue(ownerIsCurrent)) return _unavailable(messages);
      _finishOperation(clearError: true);
      return DirectEditorActionResult(
        DirectEditorActionOutcome.succeeded,
        profile: draft,
      );
    } on DirectConnectionProfileConflictException catch (error) {
      return _conflict(messages, error);
    } on OpenWebUiDirectConnectionConflictException catch (error) {
      if (!_canContinue(ownerIsCurrent)) return _unavailable(messages);
      return _conflict(messages, error);
    } catch (error) {
      if (!_canContinue(ownerIsCurrent)) return _unavailable(messages);
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
    final draft = buildDraft(
      validateFields: true,
      openWebUiFallbackName: messages.openWebUiFallbackName,
    ).profile;
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
      final probe = await gateway.probe(draft);
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
    final saved = savedProfile;
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
      clearedDirectPreference = await gateway.clearDirectPreferenceIfLastUsable(
        saved.id,
      );
      if (!_canContinue(ownerIsCurrent)) {
        if (clearedDirectPreference) {
          await gateway.restoreDirectPreference();
        }
        return _unavailable(messages);
      }
      if (isOpenWebUi) {
        final record = savedOpenWebUiRecord;
        if (record == null) {
          throw StateError('Open WebUI direct connection not found.');
        }
        await gateway.deleteOpenWebUi(record);
      } else {
        await gateway.deleteLocal(saved.id);
      }
      if (!_canContinue(ownerIsCurrent)) return _unavailable(messages);
      _finishOperation(clearError: true);
      return const DirectEditorActionResult(
        DirectEditorActionOutcome.succeeded,
      );
    } catch (error) {
      final deletionMayHaveCommitted =
          isOpenWebUi &&
          error is OpenWebUiDirectConnectionCommitUncertainException;
      if (clearedDirectPreference && !deletionMayHaveCommitted) {
        await gateway.restoreDirectPreference();
      }
      if (!_canContinue(ownerIsCurrent)) return _unavailable(messages);
      _finishOperation();
      return DirectEditorActionResult(
        DirectEditorActionOutcome.failed,
        error: error,
      );
    }
  }

  Future<bool> _confirmCredentialTransfer(
    DirectConnectionProfile draft,
    DirectCredentialTransferConfirmation confirm,
  ) async {
    if (originSecretsConfirmed ||
        !requiresDirectOriginCredentialConfirmation(
          previous: savedProfile,
          draft: draft,
        )) {
      return true;
    }
    final confirmed = await confirm(draft);
    if (confirmed && !_disposed) {
      _originSecretsConfirmed = true;
      notifyListeners();
    }
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

  void _updateTextFields(VoidCallback update) {
    _updatingTextFields = true;
    try {
      update();
    } finally {
      _updatingTextFields = false;
    }
  }

  void _headersChanged() {
    _originSecretsConfirmed = false;
    _errors = errors.copyWith(clearForm: true);
    _draftChanged();
  }

  void _revealAdvancedSettings() {
    if (!showAdvancedSettings) _showAdvancedSettings = true;
    notifyListeners();
  }

  void _draftChanged({bool notify = true}) {
    _state = state.copyWith(
      attempt: const ConnectionAttemptState.idle(),
      clearOperationError: true,
    );
    if (notify) notifyListeners();
  }

  void _publish(DirectConnectionEditorState next) {
    if (identical(next, _state)) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    name.removeListener(_generalTextChanged);
    baseUrl.removeListener(_baseUrlTextChanged);
    apiKey.removeListener(_apiKeyTextChanged);
    apiVersion.removeListener(_generalTextChanged);
    modelIdPrefix.removeListener(_generalTextChanged);
    tags.removeListener(_generalTextChanged);
    models.removeListener(_generalTextChanged);
    name.dispose();
    baseUrl.dispose();
    apiKey.dispose();
    apiVersion.dispose();
    modelIdPrefix.dispose();
    tags.dispose();
    models.dispose();
    headers.dispose();
    super.dispose();
  }
}
