import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/adaptive_selection_sheet.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/user_avatar.dart';
import '../../../core/utils/account_display.dart';

export '../../../core/utils/account_display.dart';

/// The avatar of an account the app is not signed in to: the image saved the
/// last time it was active when that image travels with it (a data URL, as
/// Open WebUI stores uploaded pictures), else its initial.
class SavedAccountAvatar extends StatelessWidget {
  const SavedAccountAvatar({
    super.key,
    required this.entry,
    required this.size,
  });

  final OpenWebUiAccountEntry entry;
  final double size;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final image = entry.summary.profileImage;
    final characters = accountDisplayName(entry, l10n).characters;
    return UserAvatar(
      size: size,
      imageUrl: image != null && image.startsWith('data:image') ? image : null,
      fallbackText: characters.isEmpty ? 'U' : characters.first.toUpperCase(),
    );
  }
}

/// Makes [accountId] the active account, asking first when that would stop
/// a reply that is still being written.
Future<void> switchToSavedAccount(
  BuildContext context,
  WidgetRef ref,
  String accountId,
) async {
  final l10n = AppLocalizations.of(context)!;
  final controller = ref.read(openWebUiAccountsControllerProvider);
  try {
    final result = await controller.switchTo(accountId);
    if (result != OpenWebUiAccountChangeResult.blockedByActiveReply) return;
    if (!context.mounted) return;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.accountsReplyInProgressTitle,
      message: l10n.accountsSwitchStopsReply,
      confirmText: l10n.accountsSwitchAnyway,
      isDestructive: true,
    );
    if (!confirmed) return;
    await controller.switchTo(accountId, force: true);
  } catch (error, stackTrace) {
    DebugLogger.error(
      'account-switch-failed',
      scope: 'profile/accounts',
      error: error,
      stackTrace: stackTrace,
    );
    if (context.mounted) UiUtils.showMessage(context, l10n.errorMessage);
  }
}

/// Signs out of [entry] after confirming, and again when that would stop a
/// reply that is still being written.
Future<void> signOutOfSavedAccount(
  BuildContext context,
  WidgetRef ref,
  OpenWebUiAccountEntry entry,
) async {
  final l10n = AppLocalizations.of(context)!;
  final name = accountDisplayName(entry, l10n);
  final confirmed = await ThemedDialogs.confirm(
    context,
    title: l10n.accountsSignOutConfirmTitle(name),
    message: l10n.accountsSignOutConfirmMessage,
    confirmText: l10n.signOut,
    isDestructive: true,
  );
  if (!confirmed || !context.mounted) return;
  final controller = ref.read(openWebUiAccountsControllerProvider);
  try {
    final result = await controller.signOut(entry.id);
    if (result != OpenWebUiAccountChangeResult.blockedByActiveReply) return;
    if (!context.mounted) return;
    final stopReply = await ThemedDialogs.confirm(
      context,
      title: l10n.accountsReplyInProgressTitle,
      message: l10n.accountsSignOutStopsReply,
      confirmText: l10n.accountsSignOutAnyway,
      isDestructive: true,
    );
    if (!stopReply) return;
    await controller.signOut(entry.id, force: true);
  } catch (error, stackTrace) {
    DebugLogger.error(
      'account-sign-out-failed',
      scope: 'profile/accounts',
      error: error,
      stackTrace: stackTrace,
    );
    if (context.mounted) UiUtils.showMessage(context, l10n.errorMessage);
  }
}

/// Asks where to add an account -- a saved server or a new one -- and opens
/// the connection page for it.
Future<void> showAddAccountSheet(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  List<OpenWebUiServer> servers;
  try {
    final entries = await ref.read(openWebUiAccountsProvider.future);
    servers = {
      for (final entry in entries) entry.server.id: entry.server,
    }.values.toList(growable: false);
  } catch (_) {
    servers = const <OpenWebUiServer>[];
  }
  if (!context.mounted) return;
  if (servers.isEmpty) {
    await context.pushNamed(RouteNames.addServer);
    return;
  }

  final theme = context.conduitTheme;
  final choice = await showAdaptiveSelectionSheet<String>(
    context: context,
    builder: (sheetContext) => AdaptiveSelectionSheet(
      title: l10n.accountsAddAccountTitle,
      description: l10n.accountsAddAccountMessage,
      itemCount: servers.length + 1,
      itemBuilder: (itemContext, index) {
        if (index == servers.length) {
          return AdaptiveSelectionTile(
            key: const Key('add-account-new-server'),
            title: l10n.accountsNewServer,
            selected: false,
            leading: Icon(
              UiUtils.platformIcon(
                ios: CupertinoIcons.add_circled,
                android: Icons.add_circle_outline,
              ),
              color: theme.buttonPrimary,
            ),
            onTap: () => Navigator.of(sheetContext).pop(''),
          );
        }
        final server = servers[index];
        final host = Uri.tryParse(server.endpoints.first.url)?.host;
        final name = serverDisplayName(server);
        return AdaptiveSelectionTile(
          key: Key('add-account-server-${server.id}'),
          title: name,
          subtitle: host == null || host == name ? null : host,
          selected: false,
          leading: Icon(
            UiUtils.platformIcon(
              ios: CupertinoIcons.cloud,
              android: Icons.dns_outlined,
            ),
            color: theme.iconSecondary,
          ),
          onTap: () => Navigator.of(sheetContext).pop(server.id),
        );
      },
    ),
  );
  if (choice == null || !context.mounted) return;
  await context.pushNamed(
    RouteNames.addServer,
    extra: choice.isEmpty ? null : choice,
  );
}
