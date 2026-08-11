import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/direct_connection_profile.dart';

enum DirectAuthenticationMode { bearer, apiKeyHeader, none, unsupported }

enum DirectConnectionEditorSource { local, openWebUi }

/// Explicit behavior policy for the backing source of an editor resource.
///
/// Authentication and ownership rules live together here so adding a source
/// cannot accidentally inherit credential behavior from an unrelated UI flag.
sealed class DirectConnectionEditorPolicy {
  const DirectConnectionEditorPolicy();

  const factory DirectConnectionEditorPolicy.local() =
      LocalDirectConnectionEditorPolicy;
  const factory DirectConnectionEditorPolicy.openWebUi() =
      OpenWebUiDirectConnectionEditorPolicy;

  bool get editsProvider;
  bool get editsName;
  bool get allowsApiKeyHeader;
  bool get allowsManagedAnonymousAuth;
  bool get requiresOwnerValidation;
  bool get showsManagedSource;

  bool preservesExistingKeylessBearer({
    required bool isNew,
    required String? savedAuthType,
    required bool apiKeyDirty,
    required bool originChanged,
  });
}

final class LocalDirectConnectionEditorPolicy
    extends DirectConnectionEditorPolicy {
  const LocalDirectConnectionEditorPolicy();

  @override
  bool get editsProvider => true;
  @override
  bool get editsName => true;
  @override
  bool get allowsApiKeyHeader => true;
  @override
  bool get allowsManagedAnonymousAuth => false;
  @override
  bool get requiresOwnerValidation => false;
  @override
  bool get showsManagedSource => false;

  @override
  bool preservesExistingKeylessBearer({
    required bool isNew,
    required String? savedAuthType,
    required bool apiKeyDirty,
    required bool originChanged,
  }) => false;
}

final class OpenWebUiDirectConnectionEditorPolicy
    extends DirectConnectionEditorPolicy {
  const OpenWebUiDirectConnectionEditorPolicy();

  @override
  bool get editsProvider => false;
  @override
  bool get editsName => false;
  @override
  bool get allowsApiKeyHeader => false;
  @override
  bool get allowsManagedAnonymousAuth => true;
  @override
  bool get requiresOwnerValidation => true;
  @override
  bool get showsManagedSource => true;

  @override
  bool preservesExistingKeylessBearer({
    required bool isNew,
    required String? savedAuthType,
    required bool apiKeyDirty,
    required bool originChanged,
  }) => !isNew && savedAuthType == 'bearer' && !apiKeyDirty && !originChanged;
}

@immutable
final class DirectConnectionEditorMode {
  const DirectConnectionEditorMode.create({
    this.source = DirectConnectionEditorSource.local,
  }) : profileId = null;

  const DirectConnectionEditorMode.edit({
    required String profileId,
    this.source = DirectConnectionEditorSource.local,
  }) : assert(profileId != ''),
       assert(profileId != 'new'),
       profileId = profileId;

  factory DirectConnectionEditorMode.fromRoute({
    required String profileId,
    required DirectConnectionEditorSource source,
  }) => profileId == 'new'
      ? DirectConnectionEditorMode.create(source: source)
      : DirectConnectionEditorMode.edit(profileId: profileId, source: source);

  final DirectConnectionEditorSource source;
  final String? profileId;

  bool get isNew => profileId == null;
  bool get isOpenWebUi => source == DirectConnectionEditorSource.openWebUi;
  DirectConnectionEditorPolicy get policy => switch (source) {
    DirectConnectionEditorSource.local =>
      const DirectConnectionEditorPolicy.local(),
    DirectConnectionEditorSource.openWebUi =>
      const DirectConnectionEditorPolicy.openWebUi(),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DirectConnectionEditorMode &&
          source == other.source &&
          profileId == other.profileId;

  @override
  int get hashCode => Object.hash(source, profileId);
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
  required DirectConnectionEditorMode mode,
  required String? savedOpenWebUiAuthType,
  required bool apiKeyDirty,
  required bool originChanged,
}) {
  if (authentication != DirectAuthenticationMode.bearer &&
      authentication != DirectAuthenticationMode.apiKeyHeader) {
    return false;
  }
  final preservesExistingKeylessBearer = mode.policy
      .preservesExistingKeylessBearer(
        isNew: mode.isNew,
        savedAuthType: savedOpenWebUiAuthType,
        apiKeyDirty: apiKeyDirty,
        originChanged: originChanged,
      );
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

/// Immutable snapshot consumed by the pure direct-profile validator.
@immutable
final class DirectConnectionDraft {
  const DirectConnectionDraft({
    required this.mode,
    required this.savedProfile,
    required this.savedOpenWebUiAuthType,
    required this.adapterKey,
    required this.providerPreset,
    required this.openAiApiMode,
    required this.authentication,
    required this.enabled,
    required this.apiKeyDirty,
    required this.originBoundSecretsReviewed,
    required this.name,
    required this.baseUrl,
    required this.apiKey,
    required this.apiVersion,
    required this.modelIdPrefix,
    required this.tags,
    required this.models,
    required this.customHeaders,
  });

  final DirectConnectionEditorMode mode;
  final DirectConnectionProfile? savedProfile;
  final String? savedOpenWebUiAuthType;
  final String adapterKey;
  final String providerPreset;
  final DirectOpenAiApiMode openAiApiMode;
  final DirectAuthenticationMode authentication;
  final bool enabled;
  final bool apiKeyDirty;
  final bool originBoundSecretsReviewed;
  final String name;
  final String baseUrl;
  final String apiKey;
  final String apiVersion;
  final String modelIdPrefix;
  final String tags;
  final String models;
  final Map<String, String> customHeaders;

  bool get isOpenRouter => providerPreset == kOpenRouterProviderPreset;

  bool get originChanged {
    final saved = savedProfile;
    if (saved == null) return false;
    return DirectConnectionProfile.originOf(saved.baseUrl) !=
        DirectConnectionProfile.originOf(baseUrl);
  }

  DirectDraftBuildResult build({required String openWebUiFallbackName}) {
    final draftName = !mode.policy.editsName
        ? (savedProfile?.name ?? openWebUiFallbackName)
        : name.trim();
    final normalizedBaseUrl = normalizeDirectBaseUrl(baseUrl);
    DirectDraftValidationIssue? nameIssue;
    DirectDraftValidationIssue? urlIssue;
    DirectDraftValidationIssue? apiKeyIssue;

    if (mode.policy.editsName && draftName.isEmpty) {
      nameIssue = DirectDraftValidationIssue.nameRequired;
    }
    if (DirectConnectionProfile.originOf(normalizedBaseUrl) == null) {
      urlIssue = DirectDraftValidationIssue.invalidUrl;
    } else if (isOpenRouter && !isOpenRouterApiBaseUrl(normalizedBaseUrl)) {
      urlIssue = DirectDraftValidationIssue.invalidOpenRouterUrl;
    } else if (!originBoundSecretsReviewed) {
      urlIssue = DirectDraftValidationIssue.credentialsReentryRequired;
    }

    final enteredApiKey = apiKey.trim();
    final effectiveApiKey = switch (authentication) {
      DirectAuthenticationMode.none => null,
      DirectAuthenticationMode.bearer ||
      DirectAuthenticationMode.apiKeyHeader =>
        apiKeyDirty || originChanged
            ? enteredApiKey
            : savedProfile?.apiKey?.trim() ?? '',
      DirectAuthenticationMode.unsupported => null,
    };
    final apiKeyRequired = requiresDirectApiKey(
      authentication: authentication,
      mode: mode,
      savedOpenWebUiAuthType: savedOpenWebUiAuthType,
      apiKeyDirty: apiKeyDirty,
      originChanged: originChanged,
    );
    if (apiKeyRequired && (effectiveApiKey ?? '').isEmpty) {
      apiKeyIssue = DirectDraftValidationIssue.apiKeyRequired;
    }

    var errors = DirectDraftErrors(
      name: nameIssue,
      url: urlIssue,
      apiKey: apiKeyIssue,
      form: authentication == DirectAuthenticationMode.unsupported
          ? DirectDraftValidationIssue.unsupportedAuthentication
          : null,
    );
    if (errors.hasAny) return DirectDraftBuildResult(errors: errors);

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
      apiVersion: apiVersion.trim().isEmpty ? null : apiVersion.trim(),
      modelIdPrefix: modelIdPrefix.trim().isEmpty ? null : modelIdPrefix.trim(),
      tags: parseDirectModelTags(tags),
      enabled: enabled,
      apiKey: effectiveApiKey,
      customHeaders: Map<String, String>.from(customHeaders),
      manualModelIds: parseDirectManualModelIds(models),
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
      return DirectDraftBuildResult(errors: errors);
    }
    return DirectDraftBuildResult(profile: safeProfile, errors: errors);
  }
}
