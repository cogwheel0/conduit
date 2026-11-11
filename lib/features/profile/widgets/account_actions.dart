import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/auth/token_validator.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/librechat/models/librechat_account.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:conduit_core/providers/primary_account_switcher.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:dio/dio.dart' show DioException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:go_router/go_router.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/widgets.dart';
import 'package:conduit_core/features/push/models/push_target.dart';

import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/sign_out_options_dialog.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/user_avatar.dart';
import '../../../shared/widgets/utility_components.dart';
import '../../../core/utils/account_display.dart';
import '../../auth/views/server_connection_page.dart'
    show ServerConnectionHandoff;
import '../../hermes/widgets/hermes_connection_switcher.dart';
import '../../push/widgets/push_attention_chip.dart';
import 'account_sheet.dart';

export '../../../core/utils/account_display.dart';
export 'account_sheet.dart' show AccountKind;

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

/// A saved Open WebUI account as a row under its server: its avatar, who it
/// is, and a check when it is the active one. Tapping switches to it; a long
/// press signs out of it. [showSignOut] adds a sign-out button as well, for
/// the server's own page.
class SavedAccountRow extends ConsumerWidget {
  const SavedAccountRow({
    super.key,
    required this.entry,
    this.showSignOut = false,
  });

  final OpenWebUiAccountEntry entry;
  final bool showSignOut;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final name = accountDisplayName(entry, l10n);
    void signOut() =>
        signOutOfSavedAccount(context, ref, entry, anchorContext: context);
    return Semantics(
      customSemanticsActions: {
        CustomSemanticsAction(label: l10n.accountsSignOutOf(name)): signOut,
      },
      child: GestureDetector(
        onLongPress: signOut,
        child: UtilityRow(
          title: name,
          subtitle: accountSubtitle(entry, l10n),
          leading: SavedAccountAvatar(entry: entry, size: IconSize.xl),
          selected: entry.isActive,
          preserveTrailingSemantics: true,
          // The active account signed out -- its session expired, next to a
          // usable Hermes or Direct backend that keeps this page open -- is
          // switched to as any other, which opens its sign-in.
          onTap: entry.isActive && entry.hasSession
              ? null
              : () => switchToSavedAccount(context, ref, entry.id),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PushAttentionChip(scope: PushTarget.openWebUiScope(entry.id)),
              if (entry.isActive)
                ActiveCheckmark(semanticLabel: l10n.accountsActive),
              if (showSignOut)
                AdaptiveButton.icon(
                  key: Key('accounts-sign-out-${entry.id}'),
                  semanticLabel: l10n.accountsSignOutOf(name),
                  icon: UiUtils.platformIcon(
                    ios: CupertinoIcons.square_arrow_left,
                    android: Icons.logout,
                  ),
                  iconColor: theme.error,
                  style: AdaptiveButtonStyle.plain,
                  // A row of a scrolling list: no native view per row.
                  useNative: false,
                  onPressed: signOut,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The check that marks the account or connection in use.
class ActiveCheckmark extends StatelessWidget {
  const ActiveCheckmark({super.key, required this.semanticLabel});

  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      child: Icon(
        UiUtils.platformIcon(
          ios: CupertinoIcons.checkmark_alt,
          android: Icons.check,
        ),
        color: context.conduitTheme.buttonPrimary,
        size: IconSize.medium,
      ),
    );
  }
}

/// Makes [connectionId] the Hermes connection in use, turning Hermes on
/// when it is off. It is switched to first: a switch that fails leaves
/// Hermes as it was, rather than on with the connection it was meant to
/// leave. Returns whether the connection is in use, with Hermes on.
Future<bool> useHermesConnection(
  BuildContext context,
  WidgetRef ref,
  String connectionId,
) => useHermesConnectionReading(context, ref.read, connectionId);

/// [useHermesConnection] for a caller that reads providers without a widget
/// ref, such as a tapped notification.
Future<bool> useHermesConnectionReading(
  BuildContext context,
  T Function<T>(ProviderListenable<T> provider) read,
  String connectionId,
) async {
  if (read(hermesActiveConnectionIdProvider) != connectionId) {
    final switched = await switchHermesConnectionOf(
      context,
      read(hermesConfigProvider.notifier),
      connectionId,
    );
    if (!switched || !context.mounted) return false;
  }
  if (read(hermesEnabledProvider)) return true;
  try {
    await read(hermesConfigProvider.notifier).setEnabled(true);
    return true;
  } catch (error, stackTrace) {
    DebugLogger.error(
      'hermes-enable-failed',
      scope: 'profile/accounts',
      error: error,
      stackTrace: stackTrace,
    );
    if (context.mounted) {
      UiUtils.showMessage(
        context,
        AppLocalizations.of(context)!.errorMessage,
      );
    }
    return false;
  }
}

/// Signs out of every account, after asking whether to keep the servers'
/// details for signing in again.
Future<void> signOutOfAllAccounts(BuildContext context, WidgetRef ref) async {
  final keepServerDetails = await showSignOutOptionsDialog(context);
  if (!context.mounted || keepServerDetails == null) return;
  try {
    await ref
        .read(signOutCoordinatorProvider)
        .signOut(keepServerDetails: keepServerDetails);
  } catch (_) {
    if (!context.mounted) return;
    UiUtils.showMessage(context, AppLocalizations.of(context)!.errorMessage);
  }
}

/// Makes [accountId] the active account, asking first when that would stop
/// a reply that is still being written, and opens its sign-in when it needs
/// one.
Future<OpenWebUiAccountChangeResult?> switchToSavedAccount(
  BuildContext context,
  WidgetRef ref,
  String accountId,
) async {
  final l10n = AppLocalizations.of(context)!;
  // The page this began on may not outlast the switch.
  final router = GoRouter.of(context);
  if (ref.read(primaryAccountKindProvider) == PrimaryAccountKind.libreChat) {
    // Open WebUI takes the Chats tab back from LibreChat; routing opens the
    // account's sign-in when its saved session is gone. Chat is opened
    // either way: while the account was restored, the router may have found
    // none and gone to choosing a backend. Read now: the row may be gone,
    // and [ref] with it, by the time a reply-stop question is answered.
    final switcher = ref.read(primaryAccountSwitcherProvider);
    final used = await _usePrimary(
      context,
      (force) => switcher.useOpenWebUi(accountId, force: force),
    );
    if (used) router.go(Routes.chat);
    // The account was not in use while LibreChat was.
    return used ? OpenWebUiAccountChangeResult.done : null;
  }
  final controller = ref.read(openWebUiAccountsControllerProvider);
  try {
    final result = await switchOpenWebUiAccountConfirming(
      controller,
      accountId,
      confirmStopReply: () async =>
          context.mounted && await confirmSwitchStopsReply(context),
    );
    if (result == OpenWebUiAccountChangeResult.needsSignIn) {
      openActiveAccountSignIn(router);
    }
    return result;
  } catch (error, stackTrace) {
    DebugLogger.error(
      'account-switch-failed',
      scope: 'profile/accounts',
      error: error,
      stackTrace: stackTrace,
    );
    if (context.mounted) UiUtils.showMessage(context, l10n.errorMessage);
    return null;
  }
}

/// For signing in to the account in use while the app still takes it for
/// signed in, as when a push check found its session refused: switching to
/// it only answers that it is already active.
///
/// Asks its server about the session. A token past its expiry, or one the
/// server refuses, goes through the app's own expired-session flow
/// ([AuthStateManager.onTokenInvalidated]: a silent sign-in with saved
/// credentials, else sign-in). Answers whether the session still works; a
/// server that cannot be reached says nothing against it, and neither does
/// a refusal that comes after the account or its session changed.
Future<bool> recheckActiveAccountSession(ProviderContainer container) async {
  final api = container.read(apiServiceProvider);
  final token = api?.authToken;
  final expired =
      api == null ||
      token == null ||
      token.isEmpty ||
      TokenValidator.validateTokenFormat(token).isExpired;
  if (!expired) {
    // Listened to while the server answers, so that signing out and in again
    // with the same token (an API key) still counts as another session.
    final session = container.listen(
      openWebUiAuthSessionEpochProvider,
      (_, _) {},
    );
    final epoch = session.read();
    try {
      await api.getCurrentUser(
        suppressAuthFailureNotification: true,
        authSnapshot: api.captureAuthSnapshot(),
      );
      return true;
    } on DioException catch (error) {
      if (error.response?.statusCode != 401) return true;
      // The expired-session flow clears whatever session is current. A
      // switch or a sign-in while the server answered made another one
      // current, which this refusal says nothing about.
      final current = container.read(apiServiceProvider);
      if (current?.serverConfig.id != api.serverConfig.id ||
          current?.authToken != token ||
          !identical(session.read(), epoch)) {
        return true;
      }
    } finally {
      session.close();
    }
  }
  await container.read(authStateManagerProvider.notifier).onTokenInvalidated();
  return false;
}

/// Makes [accountId] the active account through [controller], asking
/// [confirmStopReply] first when that would stop a reply still being
/// written. Returns how the change went, or null when the user kept the
/// reply.
///
/// [switchToSavedAccount] and a tapped notification both switch through this,
/// so they ask, and stop the reply, alike.
Future<OpenWebUiAccountChangeResult?> switchOpenWebUiAccountConfirming(
  OpenWebUiAccountsController controller,
  String accountId, {
  required Future<bool> Function() confirmStopReply,
}) async {
  final result = await controller.switchTo(accountId);
  if (result != OpenWebUiAccountChangeResult.blockedByActiveReply) {
    return result;
  }
  if (!await confirmStopReply()) return null;
  return controller.switchTo(accountId, force: true);
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
) => _mayStopReply(
  context,
  ref.read,
  guard: accountChangeReplyGuardProvider,
  stop: accountChangeStopRepliesProvider,
  confirm: () => confirmSwitchStopsReply(context),
);

/// Whether the address the active account uses may be changed or removed:
/// at once when no reply is being written, else once the user agrees to
/// stop it, which this then does. The clients move off the address with the
/// change, and a reply arriving through them would end without a word.
Future<bool> confirmChangingAddressInUse(
  BuildContext context,
  ProviderContainer container,
) => _mayStopReply(
  context,
  container.read,
  // Only the replies arriving through the address: a Direct or Hermes one
  // runs on.
  guard: addressChangeReplyGuardProvider,
  stop: addressChangeStopRepliesProvider,
  confirm: () {
    final l10n = AppLocalizations.of(context)!;
    return ThemedDialogs.confirm(
      context,
      title: l10n.accountsReplyInProgressTitle,
      message: l10n.accountsAddressChangeStopsReply,
      confirmText: l10n.accountsAddressChangeAnyway,
      isDestructive: true,
    );
  },
);

Future<bool> _mayStopReply(
  BuildContext context,
  T Function<T>(ProviderListenable<T> provider) read, {
  required ProviderListenable<bool Function()> guard,
  required ProviderListenable<void Function()> stop,
  required Future<bool> Function() confirm,
}) async {
  if (!read(guard)()) return true;
  if (!await confirm() || !context.mounted) return false;
  try {
    read(stop)();
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
void openActiveAccountSignIn(GoRouter router) =>
    router.go(Routes.authentication);

/// Asks whether to switch accounts although that stops the reply still
/// being written.
Future<bool> confirmSwitchStopsReply(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  return ThemedDialogs.confirm(
    context,
    title: l10n.accountsReplyInProgressTitle,
    message: l10n.accountsSwitchStopsReply,
    confirmText: l10n.accountsSwitchAnyway,
    isDestructive: true,
  );
}

Future<bool> _confirmSignOutStopsReply(
  BuildContext context, {
  BuildContext? anchorContext,
}) {
  final l10n = AppLocalizations.of(context)!;
  return ThemedDialogs.confirm(
    context,
    title: l10n.accountsReplyInProgressTitle,
    message: l10n.accountsSignOutStopsReply,
    confirmText: l10n.accountsSignOutAnyway,
    isDestructive: true,
    anchorContext: anchorContext,
  );
}

/// Signs out of [entry] after confirming, and again when that would stop a
/// reply that is still being written. When the account that takes over
/// needs a sign-in, opens it. The questions appear over [anchorContext], the
/// row or button the sign-out came from, when there is one.
Future<void> signOutOfSavedAccount(
  BuildContext context,
  WidgetRef ref,
  OpenWebUiAccountEntry entry, {
  BuildContext? anchorContext,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final name = accountDisplayName(entry, l10n);
  final confirmed = await ThemedDialogs.confirm(
    context,
    title: l10n.accountsSignOutConfirmTitle(name),
    message: l10n.accountsSignOutConfirmMessage,
    confirmText: l10n.signOut,
    isDestructive: true,
    anchorContext: anchorContext,
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
      if (!await _confirmSignOutStopsReply(
        context,
        anchorContext: anchorContext,
      )) {
        return;
      }
      result = await controller.signOut(entry.id, force: true);
    }
    // With no account left there is nothing to sign in to: the app carries
    // on with Hermes or Direct, or the router goes back to choosing one.
    if (result == OpenWebUiAccountChangeResult.needsSignIn &&
        await container.read(activeServerProvider.future) != null) {
      openActiveAccountSignIn(router);
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

/// Puts LibreChat account [accountId] in charge of the Chats tab, asking
/// first when that would stop a reply that is still being written, and goes
/// to chat -- or, when its session has ended, routing goes to its sign-in.
///
/// [beforeLeaving] runs once the switch happened, before chat opens: a sheet
/// the switch began in closes there.
Future<void> switchToLibreChatAccount(
  BuildContext context,
  WidgetRef ref,
  String accountId, {
  VoidCallback? beforeLeaving,
}) async {
  final router = GoRouter.of(context);
  // Read now: the row or page this began on may be gone, and [ref] with it,
  // by the time a reply-stop question is answered.
  final switcher = ref.read(primaryAccountSwitcherProvider);
  final used = await _usePrimary(
    context,
    (force) => switcher.useLibreChat(accountId, force: force),
  );
  if (!used) return;
  // The sheet the switch began in may have closed while it ran: there is
  // nothing left to close then, but chat still opens.
  if (context.mounted) beforeLeaving?.call();
  router.go(Routes.chat);
}

/// Runs a primary-account [change], asking once when a reply in progress
/// blocks it. Returns whether it happened.
Future<bool> _usePrimary(
  BuildContext context,
  Future<PrimarySwitchResult> Function(bool force) change,
) async {
  final l10n = AppLocalizations.of(context)!;
  try {
    var result = await change(false);
    if (result == PrimarySwitchResult.blockedByActiveReply) {
      if (!context.mounted) return false;
      if (!await confirmSwitchStopsReply(context)) return false;
      result = await change(true);
    }
    // An account gone by the time the switch ran (signed out of meanwhile)
    // says so; a reply the user chose not to stop is answer enough.
    if (result == PrimarySwitchResult.unknownAccount && context.mounted) {
      UiUtils.showMessage(context, l10n.errorMessage);
    }
    return result == PrimarySwitchResult.done;
  } catch (error, stackTrace) {
    DebugLogger.error(
      'primary-switch-failed',
      scope: 'profile/accounts',
      error: error,
      stackTrace: stackTrace,
    );
    if (context.mounted) UiUtils.showMessage(context, l10n.errorMessage);
    return false;
  }
}

/// Whether LibreChat account [accountId] is in charge of the Chats tab.
bool _libreChatInCharge(ProviderContainer container, String accountId) =>
    container.read(primaryAccountKindProvider) ==
        PrimaryAccountKind.libreChat &&
    container.read(activeLibreChatAccountProvider)?.id == accountId;

/// Signs out of LibreChat account [accountId] with its local history. When
/// it was in charge of the Chats tab, the most recently used other
/// LibreChat account takes over, else an Open WebUI account, else the
/// backend is chosen again. Returns whether it handed the tab over.
Future<bool> signOutOfLibreChatAndHandOver(
  ProviderContainer container,
  String accountId,
) async {
  await container.read(libreChatAccountsProvider).signOut(accountId);
  // Whether the tab needs handing over is asked once the account is gone:
  // the server can take a while to end the session, and the account may
  // have been put in charge meanwhile, leaving LibreChat with none. The
  // accounts left can take a moment to read too, and an account chosen
  // meanwhile keeps the tab -- handing it over would undo that choice -- so
  // this is asked again right before the tab is handed over.
  bool tabStillUnclaimed() =>
      container.read(primaryAccountKindProvider) ==
          PrimaryAccountKind.libreChat &&
      container.read(activeLibreChatAccountProvider) == null;
  if (!tabStillUnclaimed()) return false;
  final remaining = [
    ...(await container.read(libreChatRegistryProvider.future)).accounts,
  ]..sort((a, b) => (b.lastUsedAt ?? DateTime(0)).compareTo(
      a.lastUsedAt ?? DateTime(0),
    ));
  final openWebUi = remaining.isEmpty
      ? await container.read(openWebUiAccountsProvider.future)
      : const <OpenWebUiAccountEntry>[];
  if (!tabStillUnclaimed()) return false;
  final switcher = container.read(primaryAccountSwitcherProvider);
  if (remaining.isNotEmpty) {
    await switcher.useLibreChat(remaining.first.id, force: true);
  } else if (openWebUi.isNotEmpty) {
    await switcher.useOpenWebUi(openWebUi.first.id, force: true);
  } else {
    await container
        .read(preferredBackendProvider.notifier)
        .set(PreferredBackend.unset);
  }
  return true;
}

/// Signs out of LibreChat [account] after confirming; see
/// [signOutOfLibreChatAndHandOver]. The questions appear over
/// [anchorContext], the row the sign-out came from, when there is one.
Future<void> signOutOfLibreChatAccount(
  BuildContext context,
  LibreChatAccount account, {
  BuildContext? anchorContext,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final confirmed = await ThemedDialogs.confirm(
    context,
    title: l10n.accountsSignOutConfirmTitle(account.displayName),
    message: l10n.accountsSignOutConfirmMessage,
    confirmText: l10n.signOut,
    isDestructive: true,
    anchorContext: anchorContext,
  );
  if (!confirmed || !context.mounted) return;
  final router = GoRouter.of(context);
  // The row this started from goes with the account, and its ref with it,
  // so the rest runs on the app's container.
  final container = ProviderScope.containerOf(context, listen: false);
  // Signing out of the account in charge hands the Chats tab over, which
  // stops a reply still being written: ask first, as for Open WebUI.
  if (_libreChatInCharge(container, account.id) &&
      !await _mayStopReply(
        context,
        container.read,
        guard: accountChangeReplyGuardProvider,
        stop: accountChangeStopRepliesProvider,
        confirm: () => _confirmSignOutStopsReply(
          context,
          anchorContext: anchorContext,
        ),
      )) {
    return;
  }
  try {
    final handedOver = await signOutOfLibreChatAndHandOver(
      container,
      account.id,
    );
    if (handedOver) router.go(Routes.chat);
  } catch (error, stackTrace) {
    DebugLogger.error(
      'librechat-sign-out-failed',
      scope: 'profile/accounts',
      error: error,
      stackTrace: stackTrace,
    );
    if (context.mounted) UiUtils.showMessage(context, l10n.errorMessage);
  }
}

/// Opens the connection page to add an account on the saved server
/// [serverId], or on a new one -- carrying on from [handoff] when the
/// account sheet checked the server first.
///
/// The router keeps a signed-in user away from sign-in pages unless an
/// account is being added, and it decides that as the page opens, so the
/// addition begins here; the page ends it when it goes. The page becomes
/// the router's location rather than being pushed: the router redirects
/// from its location, so over chat a finished sign-in would stay on screen,
/// and the new account's first, signed-out attempt would replace the stack.
void openAddAccount(
  BuildContext context,
  WidgetRef ref, {
  String? serverId,
  ServerConnectionHandoff? handoff,
}) {
  ref
      .read(accountAdditionOriginProvider.notifier)
      .begin(ref.read(settledActiveAccountIdProvider));
  context.goNamed(RouteNames.addServer, extra: handoff ?? serverId);
}

/// Opens the connection page for a first Open WebUI account, next to a
/// Hermes or Direct backend in use -- carrying on from [handoff] when the
/// account sheet checked the server first. With no account to come back to
/// there is no addition to begin.
void connectFirstOpenWebUiAccount(
  BuildContext context, {
  ServerConnectionHandoff? handoff,
}) => context.goNamed(RouteNames.serverConnection, extra: handoff);

/// Drops the added account whose sign-in never finished, which makes the
/// account it was added from active again, and returns to chat.
///
/// When it could not be dropped and is still there, signed out, the flow
/// stays open, with its Cancel: in chat, the router would only open that
/// account's sign-in again, without one. Returns false then, for the page to
/// say so.
Future<bool> abandonAddedAccount(BuildContext context, WidgetRef ref) async {
  var left = false;
  try {
    left = await ref
        .read(openWebUiAccountsControllerProvider)
        .abandonPendingSignIn();
  } catch (error, stackTrace) {
    DebugLogger.error(
      'abandon-added-account-failed',
      scope: 'auth/accounts',
      error: error,
      stackTrace: stackTrace,
    );
  }
  if (!context.mounted) return true;
  if (!left) {
    // Not dropped because a sign-in reached it is not still pending; read
    // again, not as last shown. Unreadable, it may be: stay.
    final stillPending = await ref
        .read(pendingSignInAbandonableProvider.future)
        .then((pending) => pending, onError: (Object _) => true);
    if (!context.mounted) return true;
    if (stillPending) return false;
  }
  context.go(Routes.chat);
  return true;
}

/// Opens the account sheet to add an account or connection, on the tab for
/// [kind].
Future<void> showAddAccountSheet(
  BuildContext context,
  WidgetRef ref, {
  AccountKind kind = AccountKind.openWebUi,
}) => showAccountSheet(context, AddAccountRequest(kind));
