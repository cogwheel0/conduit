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

/// [url] as a list shows it: scheme, host, port and path only, so a key or
/// token written into the query or user info is not put on screen.
///
/// A URL that does not parse with a host, such as `user:token@host/path`, is
/// cut by hand the same way: the user info before the host and everything
/// from the query or fragment on are left out.
String personalConnectionPublicEndpoint(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.host.isEmpty) return _withoutCredentials(url.trim());
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
  ).toString();
}

/// [text] without what follows a `?` or `#`, and without anything up to the
/// last `@` before the path, after a `scheme://` when there is one.
String _withoutCredentials(String text) {
  var rest = text;
  final end = rest.indexOf(RegExp('[?#]'));
  if (end >= 0) rest = rest.substring(0, end);
  final schemeEnd = rest.indexOf('://');
  final prefix = schemeEnd >= 0 ? rest.substring(0, schemeEnd + 3) : '';
  rest = rest.substring(prefix.length);
  final slash = rest.indexOf('/');
  final authority = slash >= 0 ? rest.substring(0, slash) : rest;
  final at = authority.lastIndexOf('@');
  if (at >= 0) rest = rest.substring(at + 1);
  return '$prefix$rest';
}
