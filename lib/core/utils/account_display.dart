import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/providers/app_providers.dart';

import 'native_sheet_utils.dart' show NativeProfileRootSavedAccount;

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

/// A saved server's name, or the host of its first route when it has none.
String serverDisplayName(OpenWebUiServer server) {
  final name = server.name.trim();
  if (name.isNotEmpty) return name;
  final url = server.endpoints.first.url;
  final host = Uri.tryParse(url)?.host;
  return host == null || host.isEmpty ? url : host;
}

/// The other saved accounts, as rows of the native Settings root; null while
/// [accounts] are unknown (not read yet, or failed to read).
List<NativeProfileRootSavedAccount>? otherSavedAccountsForNativeSheet(
  List<OpenWebUiAccountEntry>? accounts,
  AppLocalizations l10n,
) => accounts == null
    ? null
    : [
        for (final entry in accounts)
          if (!entry.isActive)
            NativeProfileRootSavedAccount(
              id: entry.id,
              displayName: accountDisplayName(entry, l10n),
              detail: accountDetailLine(entry, l10n),
            ),
      ];
