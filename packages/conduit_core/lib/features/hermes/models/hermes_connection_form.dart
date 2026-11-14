import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_contract.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';

/// Why a connection form cannot be tested or saved yet.
enum HermesConnectionValidationIssue { invalidUrl, credentialsReentryRequired }

/// What a Hermes connection editor holds: its fields as typed, and which of
/// its secrets were touched. The phone's editor and the desktop's send the
/// same thing, so a draft is built from it in one place
/// ([buildHermesConnectionDraft]).
///
/// A secret field left untouched keeps the saved secret, unless the server's
/// origin changed: secrets never follow a connection to another server.
final class HermesConnectionForm {
  const HermesConnectionForm({
    this.connectionId,
    this.name = '',
    this.nameDirty = false,
    this.nameSource,
    required this.url,
    this.mode = HermesBackendMode.responsesApi,
    this.desktopAuthKind = HermesDesktopAuthKind.legacyToken,
    this.desktopProfile = 'default',
    this.allowSelfSignedCertificates = false,
    this.plainHttpConsentOrigin,
    this.apiKey = '',
    this.apiKeyDirty = false,
    this.sessionKey = '',
    this.sessionKeyDirty = false,
    this.legacyToken = '',
    this.desktopCredentialsDirty = false,
    this.initialAccessHeaders = const {},
    this.accessHeaders = const {},
    this.accessHeadersDirty = false,
  });

  /// The saved connection being edited; null for a new one.
  final String? connectionId;
  final String name;

  /// The name was edited: it is saved (an empty one derives from the URL).
  /// Untouched, the saved name stays.
  final bool nameDirty;
  final HermesConnectionNameSource? nameSource;
  final String url;
  final HermesBackendMode mode;
  final HermesDesktopAuthKind desktopAuthKind;
  final String desktopProfile;
  final bool allowSelfSignedCertificates;

  /// The origin the user agreed, in this form, to send credentials to
  /// without encryption; null keeps the saved agreement.
  final String? plainHttpConsentOrigin;
  final String apiKey;
  final bool apiKeyDirty;
  final String sessionKey;
  final bool sessionKeyDirty;
  final String legacyToken;

  /// The Desktop Gateway's credentials (its legacy token, its access
  /// headers) were edited.
  final bool desktopCredentialsDirty;
  final Map<String, String> initialAccessHeaders;
  final Map<String, String> accessHeaders;
  final bool accessHeadersDirty;
}

bool _originChanged(HermesConfig saved, String nextUrl) =>
    HermesConfig.connectionOrigin(saved.baseUrl) !=
    HermesConfig.connectionOrigin(nextUrl);

/// The draft [form] makes of [saved], the connection as stored: what a test
/// probes and a save persists.
HermesConnectionDraft buildHermesConnectionDraft(
  HermesConfig saved,
  HermesConnectionForm form,
) {
  final trimmedUrl = form.url.trim();
  final originChanged = _originChanged(saved, trimmedUrl);
  final trimmedApiKey = form.apiKey.trim();
  final trimmedSessionKey = form.sessionKey.trim();
  final trimmedLegacyToken = form.legacyToken.trim();
  final previousDesktop = saved.desktopCredentials;
  final initialHeadersByName = {
    for (final entry in form.initialAccessHeaders.entries)
      entry.key.toLowerCase(): entry.value,
  };
  final initialHeaderValues = form.initialAccessHeaders.values.toSet();
  final newOriginHeaders = <String, String>{
    for (final entry in form.accessHeaders.entries)
      if (initialHeadersByName[entry.key.toLowerCase()] != entry.value &&
          !initialHeaderValues.contains(entry.value))
        entry.key: entry.value,
  };
  final nextDesktop = originChanged
      ? HermesDesktopCredentials(
          legacyToken: trimmedLegacyToken.isEmpty ? null : trimmedLegacyToken,
          accessHeaders: form.accessHeadersDirty
              ? newOriginHeaders
              : const {},
        )
      : form.desktopCredentialsDirty
      ? HermesDesktopCredentials(
          legacyToken: trimmedLegacyToken.isEmpty
              ? previousDesktop?.legacyToken
              : trimmedLegacyToken,
          nativeTokens: previousDesktop?.nativeTokens,
          accessHeaders: form.accessHeaders,
        )
      : previousDesktop;
  return HermesConnectionDraft(
    config: HermesConfig(
      enabled: true,
      connectionId: form.connectionId,
      // Null keeps the saved name; an empty one derives it from the URL.
      name: form.nameDirty ? form.name.trim() : null,
      baseUrl: trimmedUrl,
      mode: form.mode,
      desktopAuthKind: form.desktopAuthKind,
      desktopProfile: form.desktopProfile,
      allowSelfSignedCertificates: form.allowSelfSignedCertificates,
      plainHttpConsentOrigin:
          form.plainHttpConsentOrigin ?? saved.plainHttpConsentOrigin,
      apiKey: originChanged || form.apiKeyDirty
          ? (trimmedApiKey.isEmpty ? null : trimmedApiKey)
          : saved.apiKey,
      sessionKey: originChanged
          ? (form.sessionKeyDirty && trimmedSessionKey.isNotEmpty
                ? trimmedSessionKey
                : null)
          : form.sessionKeyDirty
          ? (trimmedSessionKey.isEmpty ? null : trimmedSessionKey)
          : saved.sessionKey,
      desktopCredentials: nextDesktop,
    ),
    apiKeyChanged: originChanged || form.apiKeyDirty,
    sessionKeyChanged: originChanged || form.sessionKeyDirty,
    desktopCredentialsChanged: originChanged || form.desktopCredentialsDirty,
    nameSource: form.nameDirty ? form.nameSource : null,
  );
}

/// Why [form] cannot be tested or saved against [saved], or null when it
/// can: a URL Hermes cannot use, or an API server with no key (a key left
/// behind on another server must be typed again).
HermesConnectionValidationIssue? validateHermesConnectionForm(
  HermesConfig saved,
  HermesConnectionForm form,
) {
  final trimmedUrl = form.url.trim();
  if (HermesConfig.connectionOrigin(trimmedUrl) == null ||
      trimmedUrl.length > kMaxHermesBaseUrlCharacters) {
    return HermesConnectionValidationIssue.invalidUrl;
  }
  final draft = buildHermesConnectionDraft(saved, form).config;
  if (draft.mode == HermesBackendMode.responsesApi &&
      (draft.apiKey?.trim().isEmpty ?? true)) {
    return HermesConnectionValidationIssue.credentialsReentryRequired;
  }
  return null;
}
