import 'dart:async';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/push/models/push_status.dart';
import 'package:conduit_core/features/push/models/push_target.dart';
import 'package:conduit_core/features/push/providers/push_providers.dart';
import 'package:conduit_core/features/push/services/openwebui_push_backend.dart'
    show kConduitPushFunctionId;
import 'package:conduit_core/features/push/services/hermes_push_backend.dart'
    show kConduitHermesPluginRepo;
import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart'
    show OpenWebUiAccountChangeResult;
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../../l10n/app_localizations.dart';
import '../../profile/widgets/account_actions.dart';
import '../../profile/widgets/account_sheet.dart';
import 'push_install_sheet.dart';

/// Where the Open WebUI function's source is published.
const String kConduitPushFunctionSourceUrl =
    'https://github.com/cogwheel0/conduit/blob/main/server-plugins/openwebui/conduit_push.py';

/// The raw file an Open WebUI admin imports with "Import From Link".
const String kConduitPushFunctionRawUrl =
    'https://raw.githubusercontent.com/cogwheel0/conduit/main/server-plugins/openwebui/conduit_push.py';

/// The admin setup guide.
const String kConduitPushAdminGuideUrl =
    'https://github.com/cogwheel0/conduit/blob/main/docs/push/ADMIN_SETUP.md';

/// Where the Hermes plugin's source is published.
const String kConduitHermesPluginSourceUrl =
    'https://github.com/$kConduitHermesPluginRepo';

/// The plain-language threat model.
const String kConduitPushThreatModelUrl =
    'https://github.com/cogwheel0/conduit/blob/main/docs/push/THREAT_MODEL.md';

/// Where UnifiedPush lists its distributors.
const String kUnifiedPushDistributorsUrl =
    'https://unifiedpush.org/users/distributors/';

/// The one-tap fix a target row offers.
enum PushTargetAction {
  setUp,
  askAdmin,
  update,
  installHermes,
  copyCommand,
  signIn,
  retry,
}

/// The fix for [target]'s status, or null when there is nothing to do.
PushTargetAction? pushTargetAction(PushTargetState target) {
  if (target.optedOut) return null;
  return switch (target.status) {
    PushStatus.canInstall => PushTargetAction.setUp,
    PushStatus.needsAdminSetup => PushTargetAction.askAdmin,
    PushStatus.updateAvailable => PushTargetAction.update,
    PushStatus.needsHermesPlugin =>
      target.canInstallHermesPlugin
          ? PushTargetAction.installHermes
          : target.hermesInstallCommand == null
          ? null
          : PushTargetAction.copyCommand,
    PushStatus.signInNeeded => PushTargetAction.signIn,
    PushStatus.failed || PushStatus.permissionDenied => PushTargetAction.retry,
    _ => null,
  };
}

/// Whether [target] is waiting on something that resolves by itself.
bool pushTargetBusy(PushTargetState target) =>
    !target.optedOut &&
    (target.status == PushStatus.settingUp ||
        target.status == PushStatus.verifying ||
        target.status == PushStatus.restartHermes);

/// Whether the Accounts page should point at [target]: push is set up there
/// and something needs the user.
bool pushTargetNeedsAttention(PushTargetState target) =>
    !target.optedOut &&
    switch (target.status) {
      PushStatus.on ||
      PushStatus.verifying ||
      PushStatus.settingUp ||
      PushStatus.off => false,
      _ => true,
    };

String pushActionLabel(AppLocalizations l10n, PushTargetAction action) =>
    switch (action) {
      PushTargetAction.setUp => l10n.pushActionSetUp,
      PushTargetAction.askAdmin => l10n.pushActionAskAdmin,
      PushTargetAction.update => l10n.pushActionUpdate,
      PushTargetAction.installHermes => l10n.pushActionInstall,
      PushTargetAction.copyCommand => l10n.pushActionCopyCommand,
      PushTargetAction.signIn => l10n.signIn,
      PushTargetAction.retry => l10n.retry,
    };

/// What a target row says about [target], in a few words.
String pushStatusText(AppLocalizations l10n, PushTargetState target) {
  if (target.optedOut) return l10n.pushStatusOptedOut;
  final text = switch (target.status) {
    PushStatus.off => l10n.pushStatusOff,
    PushStatus.settingUp => l10n.pushStatusSettingUp,
    PushStatus.verifying => l10n.pushStatusVerifying,
    PushStatus.on => l10n.pushStatusOn,
    PushStatus.needsAdminSetup => l10n.pushStatusNeedsAdminSetup,
    PushStatus.canInstall => l10n.pushStatusCanInstall,
    PushStatus.updateAvailable => l10n.pushStatusUpdateAvailable,
    PushStatus.pluginsDisabled => l10n.pushStatusPluginsDisabled,
    PushStatus.serverTooOld =>
      target.target.kind == PushTargetKind.hermes
          ? l10n.pushStatusServerTooOldHermes
          : l10n.pushStatusServerTooOldOpenWebUi,
    PushStatus.needsHermesPlugin => l10n.pushStatusNeedsHermesPlugin,
    PushStatus.restartHermes => l10n.pushStatusRestartHermes,
    PushStatus.signInNeeded => l10n.pushStatusSignInNeeded,
    PushStatus.relayUnavailable => l10n.pushUnavailableBuild,
    PushStatus.permissionDenied => l10n.pushStatusPermissionDenied,
    PushStatus.failed => pushFailureText(l10n, target.failure),
  };
  final on =
      target.status == PushStatus.on ||
      target.status == PushStatus.updateAvailable;
  return on && target.notificationsOff ? l10n.pushStatusNotificationsOff : text;
}

/// A longer explanation of [target]'s status, for its detail sheet.
String pushStatusExplanation(AppLocalizations l10n, PushTargetState target) {
  if (target.optedOut) return l10n.pushExplainOptedOut;
  return switch (target.status) {
    PushStatus.off => l10n.pushExplainOptedOut,
    PushStatus.settingUp => l10n.pushExplainSettingUp,
    PushStatus.verifying => l10n.pushExplainVerifying,
    PushStatus.on =>
      target.notificationsOff
          ? l10n.pushExplainNotificationsOff
          : l10n.pushExplainOn,
    PushStatus.needsAdminSetup => l10n.pushExplainNeedsAdminSetup,
    PushStatus.canInstall => l10n.pushExplainCanInstall,
    PushStatus.updateAvailable => l10n.pushExplainUpdateAvailable,
    PushStatus.pluginsDisabled => l10n.pushExplainPluginsDisabled,
    PushStatus.serverTooOld => l10n.pushExplainServerTooOld,
    PushStatus.needsHermesPlugin =>
      target.canInstallHermesPlugin
          ? l10n.pushExplainNeedsHermesPlugin
          : l10n.pushExplainHermesCommand,
    PushStatus.restartHermes => l10n.pushExplainRestartHermes,
    PushStatus.signInNeeded => l10n.pushExplainSignInNeeded,
    PushStatus.relayUnavailable => l10n.pushExplainRelayUnavailable,
    PushStatus.permissionDenied => l10n.pushExplainPermissionDenied,
    // The failure itself is the status line above this.
    PushStatus.failed => l10n.pushExplainFailed,
  };
}

/// [failure] in plain words.
String pushFailureText(AppLocalizations l10n, PushFailure? failure) =>
    switch (failure?.reason) {
      PushFailureReason.noTransport => l10n.pushFailureNoTransport,
      PushFailureReason.noToken => l10n.pushFailureNoToken,
      PushFailureReason.distributorFailed => l10n.pushFailureDistributor,
      PushFailureReason.relayError => l10n.pushFailureRelay,
      PushFailureReason.relayRateLimited => l10n.pushFailureRelayBusy,
      PushFailureReason.serverUnreachable => l10n.pushFailureServerUnreachable,
      PushFailureReason.serverRejected => l10n.pushFailureServerRejected,
      PushFailureReason.hermesAuthFailed => l10n.pushFailureHermesAuth,
      PushFailureReason.subscriptionLost => l10n.pushFailureSubscriptionLost,
      PushFailureReason.installFailed => l10n.pushFailureInstall,
      PushFailureReason.testTimeout => l10n.pushFailureTestTimeout,
      PushFailureReason.deliveryFailed => l10n.pushFailureDelivery,
      PushFailureReason.platformError => l10n.pushFailurePlatform,
      PushFailureReason.unknown || null => l10n.pushFailureUnknown,
    };

/// What the user calls [target]: an Open WebUI account as the Accounts page
/// names it, with its server, or a Hermes connection by name.
String pushTargetTitle(
  AppLocalizations l10n,
  PushTarget target,
  Map<String, OpenWebUiAccountEntry> accounts,
) {
  if (target is! OpenWebUiPushTarget) return target.label;
  final entry = accounts[target.accountId];
  if (entry == null) return target.label;
  final name = accountDisplayName(entry, l10n);
  final server = serverDisplayName(entry.server);
  return name == server ? name : '$name · $server';
}

/// The saved Open WebUI accounts by id, for [pushTargetTitle].
Map<String, OpenWebUiAccountEntry> pushAccountEntries(WidgetRef ref) => {
  for (final entry
      in ref.watch(openWebUiAccountsProvider).asData?.value ??
          const <OpenWebUiAccountEntry>[])
    entry.id: entry,
};

/// Runs [action] for [target], asking first where it installs code on a
/// server. Long-running work continues after this returns; the target's
/// state shows how it goes.
Future<void> runPushTargetAction(
  BuildContext context,
  WidgetRef ref,
  PushTargetState target,
  PushTargetAction action,
) async {
  final l10n = AppLocalizations.of(context)!;
  final coordinator = ref.read(pushCoordinatorProvider.notifier);
  final scope = target.scope;
  switch (action) {
    case PushTargetAction.setUp || PushTargetAction.update:
      final update = action == PushTargetAction.update;
      final confirmed = await confirmPushInstall(
        context,
        title: update
            ? l10n.pushUpdateOpenWebUiTitle
            : l10n.pushInstallOpenWebUiTitle,
        message: update
            ? l10n.pushUpdateOpenWebUiMessage
            : l10n.pushInstallOpenWebUiMessage,
        sourceUrl: kConduitPushFunctionSourceUrl,
        confirmLabel: update ? l10n.pushActionUpdate : l10n.pushActionInstall,
      );
      if (!confirmed) return;
      _fireAndForget(coordinator.installOpenWebUiFunction(scope));
    case PushTargetAction.installHermes:
      final confirmed = await confirmPushInstall(
        context,
        title: l10n.pushInstallHermesTitle,
        message: l10n.pushInstallHermesMessage,
        sourceUrl: kConduitHermesPluginSourceUrl,
        confirmLabel: l10n.pushActionInstall,
      );
      if (!confirmed) return;
      _fireAndForget(coordinator.installHermesPlugin(scope));
    case PushTargetAction.askAdmin:
      await SharePlus.instance.share(
        ShareParams(
          text: l10n.pushAskAdminMessage(
            kConduitPushFunctionRawUrl,
            kConduitPushFunctionId,
            kConduitPushAdminGuideUrl,
          ),
          sharePositionOrigin: _origin(context),
        ),
      );
    case PushTargetAction.copyCommand:
      final command = target.hermesInstallCommand;
      if (command == null) return;
      await Clipboard.setData(ClipboardData(text: command));
      if (!context.mounted) return;
      AdaptiveSnackBar.show(
        context,
        message: l10n.copiedToClipboard,
        type: AdaptiveSnackBarType.success,
        duration: const Duration(seconds: 2),
      );
    case PushTargetAction.signIn:
      switch (target.target) {
        case OpenWebUiPushTarget(:final accountId):
          // Read now: the page may not outlast the switch.
          final container = ProviderScope.containerOf(context, listen: false);
          final router = GoRouter.of(context);
          final result = await switchToSavedAccount(context, ref, accountId);
          if (result != OpenWebUiAccountChangeResult.alreadyActive) return;
          // The account in use, which the app still takes for signed in
          // while its server refused push: its session is checked, and an
          // expired one goes through the app's own sign-in-again flow.
          if (await recheckActiveAccountSession(container)) {
            _fireAndForget(
              container.read(pushCoordinatorProvider.notifier).retry(scope),
            );
          } else if (container
                  .read(authStateManagerProvider)
                  .asData
                  ?.value
                  .isAuthenticated !=
              true) {
            openActiveAccountSignIn(router);
          }
        case HermesPushTarget(:final connectionId):
          await showAccountSheet(
            context,
            EditHermesConnectionRequest(connectionId),
          );
      }
    case PushTargetAction.retry:
      _fireAndForget(coordinator.retry(scope));
  }
}

/// Turns push on or off from a switch. Setup goes on after this returns; a
/// failure is logged once, and [onFailed] tells the user.
void setPushEnabledFromSwitch(
  PushCoordinator coordinator,
  bool value, {
  void Function()? onFailed,
}) {
  unawaited(
    coordinator.setEnabled(value).then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        DebugLogger.error(
          'push-toggle-failed',
          scope: 'push/settings',
          error: error,
          stackTrace: stackTrace,
        );
        onFailed?.call();
      },
    ),
  );
}

/// Turns push on or off from the native iOS sheet's switch. [refresh]
/// rebuilds the sheet's rows: once the switch has flipped (or after half a
/// second), and again once setup has finished, which goes on after this
/// returns.
///
/// A failure is reported once, through [onError]: the handler is attached
/// before anything is awaited, so a setup that fails while the switch is
/// still being watched never also surfaces as an unhandled error. A failed
/// refresh is reported the same way, and never as the setup's.
Future<void> setPushEnabledFromNativeSheet({
  required PushCoordinator coordinator,
  required bool Function() enabledNow,
  required bool value,
  required Future<void> Function() refresh,
  required void Function(String message, Object error, StackTrace stackTrace)
  onError,
}) async {
  final setup = coordinator.setEnabled(value).then<void>(
    (_) {},
    onError: (Object error, StackTrace stackTrace) =>
        onError('native-push-toggle-failed', error, stackTrace),
  );
  Future<void> refreshReporting() => refresh().then<void>(
    (_) {},
    onError: (Object error, StackTrace stackTrace) =>
        onError('native-push-refresh-failed', error, stackTrace),
  );

  // The switch flips first; setup goes on in the background.
  for (var i = 0; i < 20; i++) {
    if (enabledNow() == value) break;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  await refreshReporting();
  unawaited(setup.then((_) => refreshReporting()));
}

void _fireAndForget(Future<Object?> work) {
  unawaited(
    work.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) => DebugLogger.error(
        'push-action-failed',
        scope: 'push/settings',
        error: error,
        stackTrace: stackTrace,
      ),
    ),
  );
}

Rect? _origin(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}
