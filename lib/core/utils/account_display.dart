import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/features/librechat/models/librechat_account.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/models/server_config.dart';
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
///
/// Connecting names a server after the host it reached. Once no route has
/// that host -- its address was edited or removed -- the name is that of an
/// address the server no longer has, and counts as none. A name that is no
/// host was not given by connecting, and stays.
String serverDisplayName(OpenWebUiServer server) {
  final hosts = [
    for (final endpoint in server.endpoints) _hostOf(endpoint.url),
  ];
  final name = server.name.trim();
  if (name.isNotEmpty && (hosts.contains(name) || !_isHost(name))) {
    return name;
  }
  return hosts.first.isEmpty ? server.endpoints.first.url : hosts.first;
}

String _hostOf(String url) => Uri.tryParse(url)?.host ?? '';

/// Whether [server] goes by nothing friendlier than an address (an IP or a
/// host name), so a list draws a server symbol for it rather than initials
/// made of digits or letters of a domain.
bool serverIsKnownOnlyByAddress(OpenWebUiServer server) =>
    _isHost(serverDisplayName(server)) ||
    serverDisplayName(server) == server.endpoints.first.url;

/// Whether [name] is a host, as a URL's is written: lower case, an IPv6
/// address without its brackets.
bool _isHost(String name) =>
    _hostOf('http://${name.contains(':') ? '[$name]' : name}') == name;

/// What to call the server a saved account's [config] reaches: what the
/// account list calls the server [accounts] file that account under.
///
/// [config] keeps the name the server was saved under when an address is
/// edited, since renaming it would rebuild the connection. Until the account
/// is listed, the route [config] is on stands for all of the server's.
String configServerDisplayName(
  ServerConfig config,
  List<OpenWebUiAccountEntry>? accounts,
) {
  final saved = accounts
      ?.where((entry) => entry.id == config.id)
      .firstOrNull
      ?.server;
  return serverDisplayName(
    saved ??
        OpenWebUiServer(
          id: config.id,
          name: config.name,
          endpoints: [OpenWebUiEndpoint(id: config.id, url: config.url)],
        ),
  );
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
enum AccountCardKind { openWebUi, hermes, direct, libreChat }

/// What Settings' account card says: whom it is for -- the LibreChat
/// account in charge of the Chats tab ([libreChatPrimary]), else the Open
/// WebUI account signed in, named [signedInName], else the Hermes
/// connection in use, else Direct -- then who or where that is, and how many
/// other accounts and connections there are to switch to.
///
/// An account is told by its email ([signedInEmail] for Open WebUI), as a
/// mail or cloud account is in Settings; the server it is on, which may be
/// no more than an address, stands in only when there is no email.
///
/// A card that opens its own profile rather than the list of accounts leaves
/// the others out ([countsOthers] false): a row of its own leads to them.
///
/// [hermesInUseId] is null while Hermes is off.
({AccountCardKind kind, String title, String? subtitle}) accountCardSummary(
  AppLocalizations l10n, {
  required String? signedInName,
  String? signedInEmail,
  required List<OpenWebUiAccountEntry> accounts,
  required List<HermesConnectionProfile> hermesConnections,
  required String? hermesInUseId,
  bool countsOthers = true,
  LibreChatAccount? libreChatPrimary,
  List<LibreChatAccount> libreChatAccounts = const [],
}) {
  final hermes = hermesConnections
      .where((connection) => connection.id == hermesInUseId)
      .firstOrNull;
  final AccountCardKind kind;
  final String title;
  final String? place;
  if (libreChatPrimary != null) {
    kind = AccountCardKind.libreChat;
    title = libreChatPrimary.displayName;
    final email = libreChatPrimary.email?.trim();
    place = email != null && email.isNotEmpty && email != title
        ? email
        : libreChatPrimary.serverTitle ?? libreChatPrimary.host;
  } else if (signedInName != null) {
    kind = AccountCardKind.openWebUi;
    title = signedInName;
    final active = accounts.where((entry) => entry.isActive).firstOrNull;
    final email = (signedInEmail ?? active?.summary.email)?.trim();
    place = email != null && email.isNotEmpty && email != signedInName
        ? email
        : active == null
        ? null
        : serverDisplayName(active.server);
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
          .length +
      libreChatAccounts
          .where((account) => account.id != libreChatPrimary?.id)
          .length;
  final subtitle = [
    ?place,
    if (countsOthers && others > 0) '+$others',
  ].join(' ');
  return (
    kind: kind,
    title: title,
    subtitle: subtitle.isEmpty ? null : subtitle,
  );
}
