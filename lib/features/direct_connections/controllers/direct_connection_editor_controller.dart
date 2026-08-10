import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import '../models/direct_connection_profile.dart';

enum DirectAuthenticationMode { bearer, apiKeyHeader, none, unsupported }

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

/// Owns the editable field resources for a direct-connection draft.
class DirectConnectionEditorController {
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

  void hydrate(DirectConnectionProfile? profile) {
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
  }

  DirectDraftBuildResult buildDraft(DirectDraftBuildRequest request) {
    final name = request.isOpenWebUi
        ? (request.saved?.name ?? request.openWebUiFallbackName)
        : this.name.text.trim();
    final normalizedBaseUrl = normalizeDirectBaseUrl(baseUrl.text);
    String? nameError;
    String? urlError;
    String? apiKeyError;

    if (!request.isOpenWebUi && name.isEmpty) {
      nameError = request.nameRequiredMessage;
    }
    if (DirectConnectionProfile.originOf(normalizedBaseUrl) == null) {
      urlError = request.invalidUrlMessage;
    } else if (request.isOpenRouter &&
        !isOpenRouterApiBaseUrl(normalizedBaseUrl)) {
      urlError = request.invalidOpenRouterUrlMessage;
    } else if (!request.originBoundSecretsReviewed) {
      urlError = request.credentialsReentryMessage;
    }

    final existingApiKey = request.saved?.apiKey?.trim() ?? '';
    final enteredApiKey = apiKey.text.trim();
    final effectiveApiKey = switch (request.authentication) {
      DirectAuthenticationMode.none => null,
      DirectAuthenticationMode.bearer ||
      DirectAuthenticationMode.apiKeyHeader =>
        request.apiKeyDirty || request.originChanged
            ? enteredApiKey
            : existingApiKey,
      DirectAuthenticationMode.unsupported => null,
    };
    if (requiresDirectApiKey(
          authentication: request.authentication,
          isOpenWebUi: request.isOpenWebUi,
          isNew: request.isNew,
          savedOpenWebUiAuthType: request.savedOpenWebUiAuthType,
          apiKeyDirty: request.apiKeyDirty,
          originChanged: request.originChanged,
        ) &&
        (effectiveApiKey ?? '').isEmpty) {
      apiKeyError = request.apiKeyRequiredMessage;
    }

    final errors = DirectDraftErrors(
      name: nameError,
      url: urlError,
      apiKey: apiKeyError,
      form: request.authentication == DirectAuthenticationMode.unsupported
          ? request.unsupportedAuthenticationMessage
          : null,
    );
    if (errors.hasAny) return DirectDraftBuildResult(errors: errors);

    final saved = request.saved;
    final profile = DirectConnectionProfile(
      id: saved?.id ?? const Uuid().v4(),
      name: name,
      adapterKey: request.adapterKey,
      baseUrl: normalizedBaseUrl,
      openAiApiMode: request.openAiApiMode,
      apiKeyAuthMode:
          request.authentication == DirectAuthenticationMode.apiKeyHeader
          ? DirectApiKeyAuthMode.apiKeyHeader
          : DirectApiKeyAuthMode.bearer,
      apiVersion: apiVersion.text.trim().isEmpty
          ? null
          : apiVersion.text.trim(),
      modelIdPrefix: modelIdPrefix.text.trim().isEmpty
          ? null
          : modelIdPrefix.text.trim(),
      tags: parseDirectModelTags(tags.text),
      enabled: request.enabled,
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
      secretsConfirmedForNewOrigin: request.originBoundSecretsReviewed,
    );
    final profileError = safeProfile.validateOrNull();
    return profileError == null
        ? DirectDraftBuildResult(profile: safeProfile, errors: errors)
        : DirectDraftBuildResult(errors: DirectDraftErrors(form: profileError));
  }

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
  }
}

class DirectDraftBuildRequest {
  const DirectDraftBuildRequest({
    required this.saved,
    required this.isOpenWebUi,
    required this.isNew,
    required this.savedOpenWebUiAuthType,
    required this.adapterKey,
    required this.openAiApiMode,
    required this.authentication,
    required this.enabled,
    required this.apiKeyDirty,
    required this.originChanged,
    required this.originBoundSecretsReviewed,
    required this.isOpenRouter,
    required this.openWebUiFallbackName,
    required this.nameRequiredMessage,
    required this.invalidUrlMessage,
    required this.invalidOpenRouterUrlMessage,
    required this.credentialsReentryMessage,
    required this.apiKeyRequiredMessage,
    required this.unsupportedAuthenticationMessage,
  });

  final DirectConnectionProfile? saved;
  final bool isOpenWebUi;
  final bool isNew;
  final String? savedOpenWebUiAuthType;
  final String adapterKey;
  final DirectOpenAiApiMode openAiApiMode;
  final DirectAuthenticationMode authentication;
  final bool enabled;
  final bool apiKeyDirty;
  final bool originChanged;
  final bool originBoundSecretsReviewed;
  final bool isOpenRouter;
  final String openWebUiFallbackName;
  final String nameRequiredMessage;
  final String invalidUrlMessage;
  final String invalidOpenRouterUrlMessage;
  final String credentialsReentryMessage;
  final String apiKeyRequiredMessage;
  final String unsupportedAuthenticationMessage;
}

class DirectDraftErrors {
  const DirectDraftErrors({this.name, this.url, this.apiKey, this.form});

  final String? name;
  final String? url;
  final String? apiKey;
  final String? form;

  bool get hasAny =>
      name != null || url != null || apiKey != null || form != null;
}

class DirectDraftBuildResult {
  const DirectDraftBuildResult({this.profile, required this.errors});

  final DirectConnectionProfile? profile;
  final DirectDraftErrors errors;
}
