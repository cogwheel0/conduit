import 'package:conduit_core/features/integrations/personal_connection_client.dart';
import 'package:conduit_core/features/integrations/personal_connection_drafts.dart';
import 'package:conduit_core/features/integrations/personal_connection_edits.dart';
import 'package:conduit_core/features/integrations/providers/personal_connections_providers.dart';

import '../../../l10n/app_localizations.dart';

/// Text for a failed save, chosen by what actually went wrong so the user
/// knows whether anything changed.
String personalConnectionSaveError(AppLocalizations l10n, Object error) {
  return switch (error) {
    PersonalConnectionEditException(:final failure) => switch (failure) {
      PersonalConnectionEditFailure.notFound =>
        l10n.personalConnectionsNotFound,
      PersonalConnectionEditFailure.duplicate =>
        l10n.personalConnectionsDuplicate,
      PersonalConnectionEditFailure.invalid =>
        l10n.personalConnectionsSaveFailed,
    },
    PersonalConnectionsWriteRejected() => l10n.personalConnectionsSaveRejected,
    PersonalConnectionsOwnerChanged() => l10n.personalConnectionsOwnerChanged,
    _ => l10n.personalConnectionsSaveFailed,
  };
}

String personalConnectionsBlockText(
  AppLocalizations l10n,
  PersonalConnectionsBlock block,
) => switch (block) {
  PersonalConnectionsBlock.noAccount => l10n.personalConnectionsNoAccount,
  PersonalConnectionsBlock.serverDisabled =>
    l10n.personalConnectionsUnavailableServer,
  PersonalConnectionsBlock.noPermission =>
    l10n.personalConnectionsUnavailablePermission,
};

String personalConnectionIssueText(
  AppLocalizations l10n,
  PersonalConnectionDraftIssue issue,
) => switch (issue) {
  PersonalConnectionDraftIssue.urlRequired =>
    l10n.personalConnectionsUrlRequired,
  PersonalConnectionDraftIssue.urlInvalid => l10n.personalConnectionsUrlInvalid,
  PersonalConnectionDraftIssue.pathRequired =>
    l10n.personalConnectionsPathRequired,
  PersonalConnectionDraftIssue.specInvalid =>
    l10n.personalConnectionsSpecInvalid,
};

String personalConnectionProbeText(
  AppLocalizations l10n,
  PersonalConnectionProbeException error,
) => switch (error.failure) {
  PersonalConnectionProbeFailure.invalidTarget =>
    l10n.personalConnectionsTestInvalidTarget,
  PersonalConnectionProbeFailure.unsupportedAuth =>
    l10n.personalConnectionsTestUnsupportedAuth,
  PersonalConnectionProbeFailure.unauthorized =>
    l10n.personalConnectionsTestUnauthorized,
  PersonalConnectionProbeFailure.unreachable =>
    l10n.personalConnectionsTestUnreachable,
  PersonalConnectionProbeFailure.invalidSpec =>
    l10n.personalConnectionsTestInvalidSpec,
};

/// The names in a selection-cleared notice. A selection that never had a
/// readable name shows as a generic tool server.
String personalSelectionNoticeText(AppLocalizations l10n, List<String> names) =>
    names.map((name) => name.isEmpty ? l10n.toolServer : name).join(', ');
