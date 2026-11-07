import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:conduit_core/providers/primary_account_providers.dart';
import 'package:conduit_core/providers/storage_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// How a change of the primary account went.
enum PrimarySwitchResult {
  /// The account now owns the Chats tab.
  done,

  /// A reply is still being written; ask, then call again with `force`.
  blockedByActiveReply,

  /// The account to switch to is not saved here.
  unknownAccount,
}

final primaryAccountSwitcherProvider = Provider<PrimaryAccountSwitcher>(
  PrimaryAccountSwitcher.new,
);

/// Moves the Chats tab between an Open WebUI account and a LibreChat one.
///
/// Leaving Open WebUI parks it: its session goes to the per-account vault
/// and its database closes, both intact, so switching back takes them up
/// again without a sign-in. Leaving LibreChat needs nothing parked: its
/// accounts keep their own sessions and databases, and the active one stays
/// active for when LibreChat is primary again.
///
/// Each switch writes its intent first and clears it once the target has
/// settled, so a crash in between is finished or undone by
/// [recoverAtStart] and the app never comes up with no account in charge.
///
/// Switches run one at a time, in the order they were asked for: one that
/// read where the tab stood while another was moving it would undo it.
final class PrimaryAccountSwitcher {
  PrimaryAccountSwitcher(this._ref);

  final Ref _ref;
  Future<void> _lastSwitch = Future<void>.value();

  Future<T> _afterLastSwitch<T>(Future<T> Function() run) {
    final next = _lastSwitch.then((_) => run());
    _lastSwitch = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  /// Makes LibreChat account [accountId] the primary account.
  Future<PrimarySwitchResult> useLibreChat(
    String accountId, {
    bool force = false,
  }) => _afterLastSwitch(() => _useLibreChat(accountId, force: force));

  Future<PrimarySwitchResult> _useLibreChat(
    String accountId, {
    required bool force,
  }) async {
    final registry = await _ref.read(libreChatRegistryProvider.future);
    if (registry.byId(accountId) == null) {
      return PrimarySwitchResult.unknownAccount;
    }
    final from = _ref.read(primaryAccountProvider);
    final to = PrimaryAccountRef(PrimaryAccountKind.libreChat, accountId);
    if (from == to) return PrimarySwitchResult.done;
    if (!force && _ref.read(accountChangeReplyGuardProvider)()) {
      return PrimarySwitchResult.blockedByActiveReply;
    }
    _ref.read(accountChangeStopRepliesProvider)();
    await PrimarySwitchIntent(from: from, to: to).write();
    if (from.kind == PrimaryAccountKind.openWebUi) {
      await _parkOpenWebUi();
    }
    await _ref.read(libreChatRegistryProvider.notifier).setActive(accountId);
    await _ref
        .read(preferredBackendProvider.notifier)
        .set(PreferredBackend.libreChat);
    await PrimarySwitchIntent.clear();
    return PrimarySwitchResult.done;
  }

  /// Makes Open WebUI account [accountId] the primary account, un-parking
  /// Open WebUI. Its saved session is taken up when it still has one.
  Future<PrimarySwitchResult> useOpenWebUi(
    String accountId, {
    bool force = false,
  }) => _afterLastSwitch(() => _useOpenWebUi(accountId, force: force));

  Future<PrimarySwitchResult> _useOpenWebUi(
    String accountId, {
    required bool force,
  }) async {
    final saved = await _ref
        .read(optimizedStorageServiceProvider)
        .getServerConfigsStrict();
    if (!saved.any((account) => account.id == accountId)) {
      return PrimarySwitchResult.unknownAccount;
    }
    final from = _ref.read(primaryAccountProvider);
    final to = PrimaryAccountRef(PrimaryAccountKind.openWebUi, accountId);
    if (from.kind == PrimaryAccountKind.openWebUi) {
      final result = await _ref
          .read(openWebUiAccountsControllerProvider)
          .switchTo(accountId, force: force);
      return result == OpenWebUiAccountChangeResult.blockedByActiveReply
          ? PrimarySwitchResult.blockedByActiveReply
          : PrimarySwitchResult.done;
    }
    if (!force && _ref.read(accountChangeReplyGuardProvider)()) {
      return PrimarySwitchResult.blockedByActiveReply;
    }
    _ref.read(accountChangeStopRepliesProvider)();
    await PrimarySwitchIntent(from: from, to: to).write();
    // Open WebUI owns the tab before its account switch runs, so that
    // switch's own fallbacks see Open WebUI in charge.
    await _ref
        .read(preferredBackendProvider.notifier)
        .set(PreferredBackend.owui);
    await _ref
        .read(openWebUiAccountsControllerProvider)
        .switchTo(accountId, force: true);
    await PrimarySwitchIntent.clear();
    return PrimarySwitchResult.done;
  }

  /// Finishes or undoes a switch a previous run left unfinished, and takes
  /// Open WebUI back when it was left parked with nothing in charge.
  Future<void> recoverAtStart() => _afterLastSwitch(_recoverAtStart);

  Future<void> _recoverAtStart() async {
    final intent = PrimarySwitchIntent.read();
    final storage = _ref.read(optimizedStorageServiceProvider);
    final registry = await _ref.read(libreChatRegistryProvider.future);
    final openWebUiAccounts = await storage.getServerConfigsStrict();
    // A switch to LibreChat makes its account active last, so a switch cut
    // short can be finished whenever its target account is still saved.
    final target = intent?.to;
    final libreChatUsable =
        target != null && target.kind == PrimaryAccountKind.libreChat
        ? target.id != null && registry.byId(target.id!) != null
        : registry.active != null;
    // Likewise a switch to an Open WebUI account it names, which must still
    // be saved; one that names none takes any.
    final openWebUiUsable =
        target != null &&
            target.kind == PrimaryAccountKind.openWebUi &&
            target.id != null
        ? openWebUiAccounts.any((account) => account.id == target.id)
        : openWebUiAccounts.isNotEmpty;
    final decision = decidePrimaryBootRecovery(
      intent: intent,
      preferredBackend: _ref.read(preferredBackendProvider),
      openWebUiParked: storage.isOpenWebUiParked,
      hasOpenWebUiAccounts: openWebUiUsable,
      hasActiveLibreChatAccount: libreChatUsable,
    );
    DebugLogger.info(
      'primary-boot-recovery',
      scope: 'accounts/primary',
      data: {'decision': decision.name},
    );
    switch (decision) {
      case PrimaryBootRecovery.none:
        return;
      case PrimaryBootRecovery.completeSwitch:
        await _complete(intent!.to, openWebUiAccounts);
      case PrimaryBootRecovery.revertSwitch:
        await _complete(intent!.from, openWebUiAccounts);
      case PrimaryBootRecovery.unparkOpenWebUi:
        final id = openWebUiAccounts.first.id;
        await _ref
            .read(preferredBackendProvider.notifier)
            .set(PreferredBackend.owui);
        await _ref
            .read(openWebUiAccountsControllerProvider)
            .switchTo(id, force: true);
    }
    await PrimarySwitchIntent.clear();
  }

  /// Switches to [target]; an Open WebUI one no longer saved falls back to
  /// the first of [openWebUiAccounts].
  Future<void> _complete(
    PrimaryAccountRef target,
    List<ServerConfig> openWebUiAccounts,
  ) {
    final id = target.id;
    final openWebUiId = openWebUiAccounts.any((account) => account.id == id)
        ? id
        : openWebUiAccounts.firstOrNull?.id;
    return switch (target.kind) {
      PrimaryAccountKind.libreChat when id != null => _useLibreChat(
        id,
        force: true,
      ),
      PrimaryAccountKind.openWebUi when openWebUiId != null => _useOpenWebUi(
        openWebUiId,
        force: true,
      ),
      _ => Future<PrimarySwitchResult>.value(PrimarySwitchResult.done),
    };
  }

  Future<void> _parkOpenWebUi() async {
    final storage = _ref.read(optimizedStorageServiceProvider);
    if (storage.isOpenWebUiParked) return;
    final active = await storage.getEffectiveActiveServerId();
    if (active == null) return;
    await _ref.read(authStateManagerProvider.notifier).parkActiveAccount();
  }
}
