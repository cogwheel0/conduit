import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/providers/app_providers.dart';

/// What the account list calls [entry]: its user's name, else their email,
/// else the server it is on.
String accountDisplayName(OpenWebUiAccountEntry entry, AppLocalizations l10n) {
  final name = entry.summary.name?.trim();
  if (name != null && name.isNotEmpty) return name;
  final email = entry.summary.email?.trim();
  if (email != null && email.isNotEmpty) return email;
  final server = serverDisplayName(entry.server);
  return server.isNotEmpty ? server : l10n.userFallbackName;
}

/// The line under an account: who it is and where, or that it needs a
/// sign-in.
String accountDetailLine(OpenWebUiAccountEntry entry, AppLocalizations l10n) {
  final email = entry.summary.email?.trim();
  return [
    if (!entry.hasSession)
      l10n.accountsSignedOut
    else if (email != null &&
        email.isNotEmpty &&
        email != accountDisplayName(entry, l10n))
      email,
    serverDisplayName(entry.server),
  ].join(' · ');
}

/// The line under an account listed beneath its server: that it needs a
/// sign-in, else its email when the name above is not already that; null
/// when there is nothing to add.
String? accountSubtitle(OpenWebUiAccountEntry entry, AppLocalizations l10n) {
  if (!entry.hasSession) return l10n.accountsSignedOut;
  final email = entry.summary.email?.trim();
  if (email == null || email.isEmpty) return null;
  return email == accountDisplayName(entry, l10n) ? null : email;
}

/// A saved server's name, or the host of its first route when it has none.
String serverDisplayName(OpenWebUiServer server) {
  final name = server.name.trim();
  if (name.isNotEmpty) return name;
  final url = server.endpoints.first.url;
  final host = Uri.tryParse(url)?.host;
  return host == null || host.isEmpty ? url : host;
}

/// What kind of provider a Direct profile reaches.
String directProviderName(
  DirectConnectionProfile profile,
  AppLocalizations l10n,
) {
  if (profile.adapterKey == kOllamaAdapterKey) return l10n.ollama;
  if (profile.isOpenRouter) return l10n.openRouterProviderName;
  return l10n.openAICompatible;
}

/// Whom Settings' account card is for.
enum AccountCardKind { openWebUi, hermes, direct }

/// What Settings' account card says: whom it is for -- the Open WebUI
/// account signed in, named [signedInName], else the Hermes connection in
/// use, else Direct -- then where that is, and how many other accounts and
/// connections there are to switch to.
///
/// [hermesInUseId] is null while Hermes is off.
({AccountCardKind kind, String title, String? subtitle}) accountCardSummary(
  AppLocalizations l10n, {
  required String? signedInName,
  required List<OpenWebUiAccountEntry> accounts,
  required List<HermesConnectionProfile> hermesConnections,
  required String? hermesInUseId,
}) {
  final hermes = hermesConnections
      .where((connection) => connection.id == hermesInUseId)
      .firstOrNull;
  final AccountCardKind kind;
  final String title;
  final String? place;
  if (signedInName != null) {
    kind = AccountCardKind.openWebUi;
    title = signedInName;
    final active = accounts.where((entry) => entry.isActive).firstOrNull;
    place = active == null ? null : serverDisplayName(active.server);
  } else if (hermes != null) {
    kind = AccountCardKind.hermes;
    title = hermes.name;
    place = l10n.hermesAgentSettingsTitle;
  } else {
    kind = AccountCardKind.direct;
    title = l10n.directConnectionsTitle;
    place = null;
  }
  final others =
      accounts
          .where(
            (entry) => kind != AccountCardKind.openWebUi || !entry.isActive,
          )
          .length +
      hermesConnections
          .where(
            (connection) =>
                kind != AccountCardKind.hermes || connection.id != hermes!.id,
          )
          .length;
  final subtitle = [?place, if (others > 0) '+$others'].join(' ');
  return (
    kind: kind,
    title: title,
    subtitle: subtitle.isEmpty ? null : subtitle,
  );
}
