import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import '../../../shared/models/connection_attempt.dart';
import '../models/direct_connection_profile.dart';
import '../models/openwebui_direct_connection.dart';
import 'direct_custom_headers_controller.dart';

export 'direct_custom_headers_controller.dart'
    show DirectHeaderValidationError, DirectHeaderValidationIssue;

enum DirectAuthenticationMode { bearer, apiKeyHeader, none, unsupported }

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

enum DirectDraftValidationIssue {
  nameRequired,
  invalidUrl,
  invalidOpenRouterUrl,
  credentialsReentryRequired,
  apiKeyRequired,
  unsupportedAuthentication,
}

const String kOpenRouterProviderPreset = 'openrouter';

Map<String, String> parseDirectCustomHeaders(String source) {
  final trimmed = source.trim();
  if (trimmed.isEmpty) return const {};
  final decoded = jsonDecode(trimmed);
  if (decoded is! Map) throw const FormatException('Enter a JSON object.');
  final result = <String, String>{};
  for (final entry in decoded.entries) {
    if (entry.key is! String || entry.value is! String) {
      throw const FormatException('Header names and values must be text.');
    }
    result[(entry.key as String).trim()] = entry.value as String;
  }
  return result;
}

List<String> parseDirectManualModelIds(String source) {
  final seen = <String>{};
  return [
    for (final line in source.split(RegExp(r'[\r\n,]+')))
      if (line.trim().isNotEmpty && seen.add(line.trim())) line.trim(),
  ];
}

List<String> parseDirectModelTags(String source) =>
    parseDirectManualModelIds(source);

String normalizeDirectBaseUrl(String source) {
  var value = source.trim();
  while (value.endsWith('/') && Uri.tryParse(value)?.path != '/') {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

bool requiresDirectApiKey({
  required DirectAuthenticationMode authentication,
  required bool isOpenWebUi,
  required bool isNew,
  required String? savedOpenWebUiAuthType,
  required bool apiKeyDirty,
  required bool originChanged,
}) {
  if (authentication != DirectAuthenticationMode.bearer &&
      authentication != DirectAuthenticationMode.apiKeyHeader) {
    return false;
  }
  final preservesExistingKeylessBearer =
      isOpenWebUi &&
      !isNew &&
      savedOpenWebUiAuthType == 'bearer' &&
      !apiKeyDirty &&
      !originChanged;
  return !preservesExistingKeylessBearer;
}

DirectConnectionProfile secureDirectDraftForEditedOrigin({
  required DirectConnectionProfile? previous,
  required DirectConnectionProfile draft,
  required bool secretsConfirmedForNewOrigin,
}) {
  if (previous == null) return draft;
  return DirectConnectionProfile.secureUpdate(
    previous: previous,
    next: draft,
    secretsConfirmedForNewOrigin: secretsConfirmedForNewOrigin,
  );
}

bool requiresDirectOriginCredentialConfirmation({
  required DirectConnectionProfile? previous,
  required DirectConnectionProfile draft,
}) {
  if (previous == null || previous.origin == draft.origin) return false;
  final previousHasCredentials =
      (previous.apiKey?.isNotEmpty ?? false) ||
      previous.customHeaders.isNotEmpty;
  final draftHasCredentials =
      (draft.apiKey?.isNotEmpty ?? false) || draft.customHeaders.isNotEmpty;
  return previousHasCredentials && draftHasCredentials;
}

/// Owns all mutable state and validation for a direct-connection draft.
final class DirectConnectionEditorController extends ChangeNotifier {
  DirectConnectionEditorController({
    required this.isOpenWebUi,
    required this.isNew,
  }) {
    headers = DirectCustomHeadersController(onHeadersChanged: _headersChanged);
  }

  final bool isOpenWebUi;
  final bool isNew;

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

  bool beginOperation(DirectEditorOperation operation) {
    if (state.isBusy || operation == DirectEditorOperation.idle) return false;
    _publish(state.copyWith(operation: operation));
    return true;
  }

  void finishOperation({
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

  void setAttempt(ConnectionAttemptState attempt) {
    _publish(state.copyWith(attempt: attempt));
  }

  void setOperationError(String error) {
    _publish(state.copyWith(operationError: error));
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

  void markGeneralChanged() {
    _errors = const DirectDraftErrors();
    headers.clearError();
    _draftChanged();
  }

  void markBaseUrlChanged() {
    _originSecretsConfirmed = false;
    markGeneralChanged();
  }

  void markApiKeyChanged() {
    _apiKeyDirty = true;
    _originSecretsConfirmed = false;
    _errors = errors.copyWith(clearApiKey: true, clearForm: true);
    _draftChanged();
  }

  void markHeaderInputChanged() {
    _errors = errors.copyWith(clearForm: true);
    headers.markInputChanged();
    _draftChanged();
  }

  void markOriginSecretsConfirmed() {
    _originSecretsConfirmed = true;
    notifyListeners();
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
    final draftName = isOpenWebUi
        ? (savedProfile?.name ?? openWebUiFallbackName)
        : name.text.trim();
    final normalizedBaseUrl = normalizeDirectBaseUrl(baseUrl.text);
    DirectDraftValidationIssue? nameIssue;
    DirectDraftValidationIssue? urlIssue;
    DirectDraftValidationIssue? apiKeyIssue;

    if (!isOpenWebUi && draftName.isEmpty) {
      nameIssue = DirectDraftValidationIssue.nameRequired;
    }
    if (DirectConnectionProfile.originOf(normalizedBaseUrl) == null) {
      urlIssue = DirectDraftValidationIssue.invalidUrl;
    } else if (isOpenRouter && !isOpenRouterApiBaseUrl(normalizedBaseUrl)) {
      urlIssue = DirectDraftValidationIssue.invalidOpenRouterUrl;
    } else if (!originBoundSecretsReviewed) {
      urlIssue = DirectDraftValidationIssue.credentialsReentryRequired;
    }

    final existingApiKey = savedProfile?.apiKey?.trim() ?? '';
    final enteredApiKey = apiKey.text.trim();
    final effectiveApiKey = switch (authentication) {
      DirectAuthenticationMode.none => null,
      DirectAuthenticationMode.bearer ||
      DirectAuthenticationMode.apiKeyHeader =>
        apiKeyDirty || originChanged ? enteredApiKey : existingApiKey,
      DirectAuthenticationMode.unsupported => null,
    };
    if (apiKeyRequired && (effectiveApiKey ?? '').isEmpty) {
      apiKeyIssue = DirectDraftValidationIssue.apiKeyRequired;
    }

    _errors = DirectDraftErrors(
      name: nameIssue,
      url: urlIssue,
      apiKey: apiKeyIssue,
      form: authentication == DirectAuthenticationMode.unsupported
          ? DirectDraftValidationIssue.unsupportedAuthentication
          : null,
    );
    if (errors.hasAny) {
      if (validateFields) notifyListeners();
      return DirectDraftBuildResult(errors: errors);
    }

    final saved = savedProfile;
    final profile = DirectConnectionProfile(
      id: saved?.id ?? const Uuid().v4(),
      name: draftName,
      adapterKey: adapterKey,
      baseUrl: normalizedBaseUrl,
      openAiApiMode: openAiApiMode,
      apiKeyAuthMode: authentication == DirectAuthenticationMode.apiKeyHeader
          ? DirectApiKeyAuthMode.apiKeyHeader
          : DirectApiKeyAuthMode.bearer,
      apiVersion: apiVersion.text.trim().isEmpty
          ? null
          : apiVersion.text.trim(),
      modelIdPrefix: modelIdPrefix.text.trim().isEmpty
          ? null
          : modelIdPrefix.text.trim(),
      tags: parseDirectModelTags(tags.text),
      enabled: enabled,
      apiKey: effectiveApiKey,
      customHeaders: Map<String, String>.from(customHeaders),
      manualModelIds: parseDirectManualModelIds(models.text),
      ollamaKeepAliveByModel:
          saved?.ollamaKeepAliveByModel ?? const <String, String>{},
      ollamaThinkingByModel:
          saved?.ollamaThinkingByModel ?? const <String, String>{},
      allowSelfSignedCertificates: saved?.allowSelfSignedCertificates ?? false,
      mtlsCertificateChainPem: saved?.mtlsCertificateChainPem,
      mtlsCertificateLabel: saved?.mtlsCertificateLabel,
      mtlsPrivateKeyPem: saved?.mtlsPrivateKeyPem,
      mtlsPrivateKeyLabel: saved?.mtlsPrivateKeyLabel,
      mtlsPrivateKeyPassword: saved?.mtlsPrivateKeyPassword,
    );
    final safeProfile = secureDirectDraftForEditedOrigin(
      previous: saved,
      draft: profile,
      secretsConfirmedForNewOrigin: originBoundSecretsReviewed,
    );
    final profileError = safeProfile.validateOrNull();
    if (profileError != null) {
      _errors = DirectDraftErrors(profile: profileError);
      if (validateFields) notifyListeners();
      return DirectDraftBuildResult(errors: errors);
    }
    return DirectDraftBuildResult(profile: safeProfile, errors: errors);
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

final class DirectDraftErrors {
  const DirectDraftErrors({
    this.name,
    this.url,
    this.apiKey,
    this.form,
    this.profile,
  });

  final DirectDraftValidationIssue? name;
  final DirectDraftValidationIssue? url;
  final DirectDraftValidationIssue? apiKey;
  final DirectDraftValidationIssue? form;
  final String? profile;

  bool get hasAny =>
      name != null ||
      url != null ||
      apiKey != null ||
      form != null ||
      profile != null;

  DirectDraftErrors copyWith({
    bool clearApiKey = false,
    bool clearForm = false,
  }) => DirectDraftErrors(
    name: name,
    url: url,
    apiKey: clearApiKey ? null : apiKey,
    form: clearForm ? null : form,
    profile: clearForm ? null : profile,
  );
}

final class DirectDraftBuildResult {
  const DirectDraftBuildResult({this.profile, required this.errors});

  final DirectConnectionProfile? profile;
  final DirectDraftErrors errors;
}
