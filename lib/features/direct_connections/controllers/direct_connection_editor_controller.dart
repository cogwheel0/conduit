import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import '../models/direct_connection_profile.dart';
import '../models/openwebui_direct_connection.dart';

enum DirectAuthenticationMode { bearer, apiKeyHeader, none, unsupported }

enum DirectDraftValidationIssue {
  nameRequired,
  invalidUrl,
  invalidOpenRouterUrl,
  credentialsReentryRequired,
  apiKeyRequired,
  unsupportedAuthentication,
}

enum DirectHeaderValidationIssue {
  nameRequired,
  invalidName,
  reservedName,
  duplicateName,
  invalidValue,
}

final class DirectHeaderValidationError {
  const DirectHeaderValidationError(this.issue, {this.headerName});

  final DirectHeaderValidationIssue issue;
  final String? headerName;
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
    this.onDraftChanged,
  });

  final bool isOpenWebUi;
  final bool isNew;
  final VoidCallback? onDraftChanged;

  final name = TextEditingController();
  final baseUrl = TextEditingController();
  final apiKey = TextEditingController();
  final apiVersion = TextEditingController();
  final modelIdPrefix = TextEditingController();
  final tags = TextEditingController();
  final headerName = TextEditingController();
  final headerValue = TextEditingController();
  final models = TextEditingController();
  final headerValueFocusNode = FocusNode();
  final Map<String, String> customHeaders = {};

  DirectConnectionProfile? savedProfile;
  OpenWebUiDirectConnectionRecord? savedOpenWebUiRecord;
  String adapterKey = kOpenAiCompatibleAdapterKey;
  String providerPreset = kOpenAiCompatibleAdapterKey;
  DirectOpenAiApiMode openAiApiMode = DirectOpenAiApiMode.chatCompletions;
  DirectAuthenticationMode authentication = DirectAuthenticationMode.bearer;
  bool enabled = true;
  bool apiKeyDirty = false;
  bool headersDirty = false;
  bool showApiKey = false;
  bool showAdvancedSettings = false;
  bool originSecretsConfirmed = false;
  DirectDraftErrors errors = const DirectDraftErrors();
  DirectHeaderValidationError? headerError;

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
    final headersReviewed = saved.customHeaders.isEmpty || headersDirty;
    return apiKeyReviewed && headersReviewed;
  }

  bool get canAddCustomHeader => headerName.text.trim().isNotEmpty;

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
    savedProfile = profile;
    savedOpenWebUiRecord = openWebUiRecord;
    if (profile == null) {
      name.text = 'My provider';
      baseUrl.text = 'https://api.openai.com/v1';
      return;
    }
    name.text = profile.name;
    baseUrl.text = profile.baseUrl;
    customHeaders
      ..clear()
      ..addAll(profile.customHeaders);
    models.text = profile.manualModelIds.join('\n');
    apiVersion.text = profile.apiVersion ?? '';
    modelIdPrefix.text = profile.modelIdPrefix ?? '';
    tags.text = profile.tags.join(', ');
    adapterKey = profile.adapterKey;
    providerPreset = profile.isOpenRouter
        ? kOpenRouterProviderPreset
        : profile.adapterKey;
    openAiApiMode = profile.openAiApiMode;
    authentication = openWebUiRecord == null
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
    enabled = profile.enabled;
  }

  void refreshOpenWebUiRecord(OpenWebUiDirectConnectionRecord? record) {
    final savedRecord = savedOpenWebUiRecord;
    if (record == null ||
        savedRecord == null ||
        savedRecord.profile.id != record.profile.id ||
        savedRecord.contentRevision != record.contentRevision) {
      return;
    }
    savedOpenWebUiRecord = record;
    savedProfile = record.profile;
  }

  void setEnabled(bool value) {
    if (enabled == value) return;
    enabled = value;
    _draftChanged();
  }

  void selectProviderPreset(
    String value, {
    required String ollamaDefaultName,
    required String openRouterDefaultName,
  }) {
    if (providerPreset == value) return;
    providerPreset = value;
    adapterKey = value == kOllamaAdapterKey
        ? kOllamaAdapterKey
        : kOpenAiCompatibleAdapterKey;
    authentication = DirectAuthenticationMode.bearer;
    openAiApiMode = DirectOpenAiApiMode.chatCompletions;
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
    originSecretsConfirmed = false;
    _draftChanged();
  }

  void setAuthentication(DirectAuthenticationMode value) {
    if (authentication == value ||
        value == DirectAuthenticationMode.unsupported) {
      return;
    }
    authentication = value;
    apiKeyDirty = true;
    originSecretsConfirmed = false;
    errors = errors.copyWith(clearApiKey: true, clearForm: true);
    _draftChanged();
  }

  void setOpenAiApiMode(DirectOpenAiApiMode value) {
    if (openAiApiMode == value) return;
    openAiApiMode = value;
    _draftChanged();
  }

  void setShowApiKey(bool value) {
    if (showApiKey == value) return;
    showApiKey = value;
    notifyListeners();
  }

  void setShowAdvancedSettings(bool value) {
    if (showAdvancedSettings == value) return;
    showAdvancedSettings = value;
    notifyListeners();
  }

  void markGeneralChanged() {
    errors = const DirectDraftErrors();
    headerError = null;
    _draftChanged();
  }

  void markBaseUrlChanged() {
    originSecretsConfirmed = false;
    markGeneralChanged();
  }

  void markApiKeyChanged() {
    apiKeyDirty = true;
    originSecretsConfirmed = false;
    errors = errors.copyWith(clearApiKey: true, clearForm: true);
    _draftChanged();
  }

  void markHeaderInputChanged() {
    headerError = null;
    errors = errors.copyWith(clearForm: true);
    _draftChanged();
  }

  void markOriginSecretsConfirmed() {
    originSecretsConfirmed = true;
    notifyListeners();
  }

  bool commitPendingCustomHeader() {
    final hasName = headerName.text.trim().isNotEmpty;
    final hasValue = headerValue.text.isNotEmpty;
    if (!hasName && !hasValue) return true;
    if (!hasName) {
      showAdvancedSettings = true;
      headerError = const DirectHeaderValidationError(
        DirectHeaderValidationIssue.nameRequired,
      );
      notifyListeners();
      return false;
    }
    return addCustomHeader();
  }

  bool addCustomHeader() {
    if (!canAddCustomHeader) return false;
    final normalizedName = headerName.text.trim();
    final error =
        _validateHeaderName(normalizedName) ??
        _validateHeaderValue(headerValue.text);
    if (error != null) {
      showAdvancedSettings = true;
      headerError = error;
      notifyListeners();
      return false;
    }
    customHeaders[normalizedName] = headerValue.text;
    headerName.clear();
    headerValue.clear();
    _markHeadersChanged();
    return true;
  }

  void removeCustomHeader(String name) {
    if (customHeaders.remove(name) == null) return;
    _markHeadersChanged();
  }

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

    errors = DirectDraftErrors(
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
      errors = DirectDraftErrors(profile: profileError);
      if (validateFields) notifyListeners();
      return DirectDraftBuildResult(errors: errors);
    }
    return DirectDraftBuildResult(profile: safeProfile, errors: errors);
  }

  DirectHeaderValidationError? _validateHeaderName(String name) {
    if (!DirectConnectionProfile.isValidCustomHeaderName(name)) {
      return const DirectHeaderValidationError(
        DirectHeaderValidationIssue.invalidName,
      );
    }
    if (DirectConnectionProfile.reservedHeaderNames.contains(
      name.toLowerCase(),
    )) {
      return DirectHeaderValidationError(
        DirectHeaderValidationIssue.reservedName,
        headerName: name,
      );
    }
    final duplicate = customHeaders.keys.any(
      (existing) => existing.toLowerCase() == name.toLowerCase(),
    );
    if (duplicate) {
      return DirectHeaderValidationError(
        DirectHeaderValidationIssue.duplicateName,
        headerName: name,
      );
    }
    return null;
  }

  DirectHeaderValidationError? _validateHeaderValue(String value) {
    if (!DirectConnectionProfile.isValidCustomHeaderValue(value)) {
      return const DirectHeaderValidationError(
        DirectHeaderValidationIssue.invalidValue,
      );
    }
    return null;
  }

  void _markHeadersChanged() {
    headersDirty = true;
    originSecretsConfirmed = false;
    headerError = null;
    errors = errors.copyWith(clearForm: true);
    _draftChanged();
  }

  void _draftChanged() {
    onDraftChanged?.call();
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
    headerName.dispose();
    headerValue.dispose();
    models.dispose();
    headerValueFocusNode.dispose();
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
