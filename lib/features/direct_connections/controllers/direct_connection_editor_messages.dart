import 'package:conduit_core/features/direct_connections/controllers/direct_connection_editor_draft.dart';
import 'package:conduit_core/features/direct_connections/models/direct_remote_model.dart';

import '../../../l10n/app_localizations.dart';
import 'direct_connection_editor_workflow.dart';
import 'direct_custom_headers_controller.dart';

/// What a Direct editor says while it saves and tests, in [l10n]'s words.
/// Onboarding's editor and Settings's own say the same.
DirectEditorMessages directEditorMessages(AppLocalizations l10n) =>
    DirectEditorMessages(
      openWebUiFallbackName: l10n.openWebUiDirectConnectionFallbackName,
      connecting: l10n.connecting,
      reachFailed: l10n.directConnectionReachFailed,
      saveConflict: l10n.directConnectionSaveConflict,
      saveFailed: l10n.directConnectionSaveFailed,
      unavailable: l10n.openWebUiDirectConnectionsUnavailable,
      probeMessage: (probe) => directProbeMessage(probe, l10n),
    );

/// How a test of a provider went.
String directProbeMessage(DirectConnectionProbe probe, AppLocalizations l10n) {
  if (!probe.reachable) {
    return probe.message?.trim().isNotEmpty == true
        ? probe.message!.trim()
        : l10n.directConnectionReachFailed;
  }
  final modelCount = probe.modelCount;
  if (modelCount == null) return l10n.directConnectionProbeConnected;
  return l10n.directConnectionProbeConnectedModels(modelCount);
}

String? directDraftValidationMessage(
  AppLocalizations l10n,
  DirectDraftValidationIssue? issue,
) => switch (issue) {
  DirectDraftValidationIssue.nameRequired => l10n.directConnectionNameRequired,
  DirectDraftValidationIssue.invalidUrl => l10n.directConnectionUrlInvalid,
  DirectDraftValidationIssue.invalidOpenRouterUrl =>
    l10n.directOpenRouterUrlInvalid,
  DirectDraftValidationIssue.credentialsReentryRequired =>
    l10n.directConnectionCredentialsReentryRequired,
  DirectDraftValidationIssue.apiKeyRequired =>
    l10n.directConnectionApiKeyRequired,
  DirectDraftValidationIssue.unsupportedAuthentication =>
    l10n.openWebUiDirectConnectionUnsupportedAuth,
  null => null,
};

String? directHeaderValidationMessage(
  AppLocalizations l10n,
  DirectHeaderValidationError? error,
) => switch (error?.issue) {
  DirectHeaderValidationIssue.nameRequired =>
    l10n.directConnectionHeaderNameRequired,
  DirectHeaderValidationIssue.invalidName => l10n.headerNameInvalidChars,
  DirectHeaderValidationIssue.reservedName => l10n.headerNameReserved(
    error!.headerName!,
  ),
  DirectHeaderValidationIssue.duplicateName => l10n.headerAlreadyExists(
    error!.headerName!,
  ),
  DirectHeaderValidationIssue.invalidValue => l10n.headerValueInvalidChars,
  null => null,
};
