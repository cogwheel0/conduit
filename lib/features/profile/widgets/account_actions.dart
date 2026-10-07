import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';
import 'package:flutter/widgets.dart';

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
/// a reply that is still being written, and opens its sign-in when it needs
/// one.
Future<void> switchToSavedAccount(
  BuildContext context,
  WidgetRef ref,
  String accountId,
) async {
  final l10n = AppLocalizations.of(context)!;
  // The page this began on may not outlast the switch.
  final router = GoRouter.of(context);
  final controller = ref.read(openWebUiAccountsControllerProvider);
  try {
    var result = await controller.switchTo(accountId);
    if (result == OpenWebUiAccountChangeResult.blockedByActiveReply) {
      if (!context.mounted) return;
      if (!await _confirmSwitchStopsReply(context)) return;
      result = await controller.switchTo(accountId, force: true);
    }
    if (result == OpenWebUiAccountChangeResult.needsSignIn) {
      _openSignIn(router);
    }
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

/// Whether the active account may be left for one being signed in to: at
/// once when no reply is being written, else once the user agrees to stop
/// it, which this then does.
///
/// Signing in to an added account makes it the active one before the
/// accounts controller is involved, so this asks what [switchToSavedAccount]
/// asks when the controller reports a reply in the way.
Future<bool> confirmLeavingActiveAccount(
  BuildContext context,
  WidgetRef ref,
) async {
  if (!ref.read(accountChangeReplyGuardProvider)()) return true;
  if (!await _confirmSwitchStopsReply(context) || !context.mounted) {
    return false;
  }
  try {
    ref.read(accountChangeStopRepliesProvider)();
  } catch (error, stackTrace) {
    DebugLogger.error(
      'account-change-stop-replies-failed',
      scope: 'auth/accounts',
      error: error,
      stackTrace: stackTrace,
    );
  }
  return true;
}

/// Opens sign-in for the active account, which a switch or a sign-out left
/// signed out. An Open WebUI-first install gets there by redirect, but next
/// to a usable Hermes or Direct backend the router lets the user stay where
/// they were, with the account they chose unusable. Sign-in becomes the
/// router's location, so the router moves on to chat once it succeeds.
void _openSignIn(GoRouter router) => router.go(Routes.authentication);

Future<bool> _confirmSwitchStopsReply(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  return ThemedDialogs.confirm(
    context,
    title: l10n.accountsReplyInProgressTitle,
    message: l10n.accountsSwitchStopsReply,
    confirmText: l10n.accountsSwitchAnyway,
    isDestructive: true,
  );
}

/// Signs out of [entry] after confirming, and again when that would stop a
/// reply that is still being written. When the account that takes over
/// needs a sign-in, opens it.
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
  // The row this began on goes with the account it showed.
  final router = GoRouter.of(context);
  final container = ProviderScope.containerOf(context, listen: false);
  final controller = ref.read(openWebUiAccountsControllerProvider);
  try {
    var result = await controller.signOut(entry.id);
    if (result == OpenWebUiAccountChangeResult.blockedByActiveReply) {
      if (!context.mounted) return;
      final stopReply = await ThemedDialogs.confirm(
        context,
        title: l10n.accountsReplyInProgressTitle,
        message: l10n.accountsSignOutStopsReply,
        confirmText: l10n.accountsSignOutAnyway,
        isDestructive: true,
      );
      if (!stopReply) return;
      result = await controller.signOut(entry.id, force: true);
    }
    // With no account left there is nothing to sign in to: the app carries
    // on with Hermes or Direct, or the router goes back to choosing one.
    if (result == OpenWebUiAccountChangeResult.needsSignIn &&
        await container.read(activeServerProvider.future) != null) {
      _openSignIn(router);
    }
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

/// Opens the connection page to add an account on the saved server
/// [serverId], or on a new one.
///
/// The router keeps a signed-in user away from sign-in pages unless an
/// account is being added, and it decides that as the page opens, so the
/// addition begins here; the page ends it when it goes. The page becomes
/// the router's location rather than being pushed: the router redirects
/// from its location, so over chat a finished sign-in would stay on screen,
/// and the new account's first, signed-out attempt would replace the stack.
void openAddAccount(BuildContext context, WidgetRef ref, {String? serverId}) {
  ref
      .read(accountAdditionOriginProvider.notifier)
      .begin(ref.read(settledActiveAccountIdProvider));
  context.goNamed(RouteNames.addServer, extra: serverId);
}

/// Drops the added account whose sign-in never finished, which makes the
/// account it was added from active again, and returns to chat.
Future<void> abandonAddedAccount(BuildContext context, WidgetRef ref) async {
  try {
    await ref.read(openWebUiAccountsControllerProvider).abandonPendingSignIn();
  } catch (error, stackTrace) {
    DebugLogger.error(
      'abandon-added-account-failed',
      scope: 'auth/accounts',
      error: error,
      stackTrace: stackTrace,
    );
  }
  if (context.mounted) context.go(Routes.chat);
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
    openAddAccount(context, ref);
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
  openAddAccount(context, ref, serverId: choice.isEmpty ? null : choice);
}
