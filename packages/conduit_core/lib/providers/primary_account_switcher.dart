import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
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

/// How long routing waits for [primaryBootRecoveryProvider]. Taking up an
/// Open WebUI session can wait on its server; past this, routing goes on
/// and the recovery moves it again when it lands.
const Duration _bootRecoveryRoutingWait = Duration(seconds: 10);

/// Startup's one run of [PrimaryAccountSwitcher.recoverAtStart]. One that
/// fails is logged and leaves the accounts as they are.
final primaryBootRecoveryProvider = FutureProvider<void>((ref) async {
  final recovery = ref
      .read(primaryAccountSwitcherProvider)
      .recoverAtStart()
      .catchError((Object error, StackTrace stackTrace) {
        DebugLogger.error(
          'primary-boot-recovery-failed',
          scope: 'accounts/primary',
          error: error,
          stackTrace: stackTrace,
        );
      });
  await recovery.timeout(
    _bootRecoveryRoutingWait,
    onTimeout: () => DebugLogger.warning(
      'primary-boot-recovery-slow',
      scope: 'accounts/primary',
    ),
  );
});

/// Whether routing holds the splash screen for startup's recovery of the
/// primary account, so it never picks an account that a switch cut short
/// left half-moved. Only a change left unfinished, or a parked Open WebUI,
/// gives the recovery anything to do; otherwise routing does not wait.
final primaryBootRecoveryPendingProvider = Provider<bool>((ref) {
  final unsettled =
      PrimarySwitchIntent.read() != null ||
      (PreferencesStore.getBool(PreferenceKeys.openWebUiParked) ?? false);
  return unsettled && ref.watch(primaryBootRecoveryProvider).isLoading;
});

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

  /// [stillWanted], from a recovery, is asked just before the switch puts
  /// the backend in charge: one the user chose meanwhile stands.
  Future<PrimarySwitchResult> _useLibreChat(
    String accountId, {
    required bool force,
    bool Function()? stillWanted,
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
    final registryNow = await _ref.read(libreChatRegistryProvider.future);
    if (registryNow.activeId != accountId) {
      // Signed out of while Open WebUI was parked for it: there is nothing
      // to put in charge. The account that was takes the tab back, Open
      // WebUI out of its park as a start-up recovery would take it.
      if (from.kind == PrimaryAccountKind.openWebUi && from.id != null) {
        await _ref
            .read(openWebUiAccountsControllerProvider)
            .switchTo(from.id!, force: true);
      }
      await PrimarySwitchIntent.clear();
      return PrimarySwitchResult.unknownAccount;
    }
    if (stillWanted != null && !stillWanted()) {
      await PrimarySwitchIntent.clear();
      return PrimarySwitchResult.done;
    }
    await _preferBackend(PreferredBackend.libreChat);
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
    bool Function()? stillWanted,
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
    if (stillWanted != null && !stillWanted()) {
      await PrimarySwitchIntent.clear();
      return PrimarySwitchResult.done;
    }
    // Open WebUI owns the tab before its account switch runs, so that
    // switch's own fallbacks see Open WebUI in charge.
    await _preferBackend(PreferredBackend.owui);
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
    final chosenAtStart = _ref.read(preferredBackendProvider);
    final storage = _ref.read(optimizedStorageServiceProvider);
    final registry = await _ref.read(libreChatRegistryProvider.future);
    final openWebUiAccounts = await storage.getServerConfigsStrict();
    // Routing goes on after a while; a backend the user chose while storage
    // was slow to answer stands, over a switch that was cut short.
    bool stillWanted() => _ref.read(preferredBackendProvider) == chosenAtStart;
    if (!stillWanted()) {
      if (intent != null) await PrimarySwitchIntent.clear();
      return;
    }
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
        await _complete(intent!.to, openWebUiAccounts, stillWanted);
      case PrimaryBootRecovery.revertSwitch:
        await _complete(intent!.from, openWebUiAccounts, stillWanted);
      case PrimaryBootRecovery.unparkOpenWebUi:
        final id = openWebUiAccounts.first.id;
        if (!stillWanted()) break;
        await _preferBackend(PreferredBackend.owui);
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
    bool Function() stillWanted,
  ) {
    final id = target.id;
    final openWebUiId = openWebUiAccounts.any((account) => account.id == id)
        ? id
        : openWebUiAccounts.firstOrNull?.id;
    return switch (target.kind) {
      PrimaryAccountKind.libreChat when id != null => _useLibreChat(
        id,
        force: true,
        stillWanted: stillWanted,
      ),
      PrimaryAccountKind.openWebUi when openWebUiId != null => _useOpenWebUi(
        openWebUiId,
        force: true,
        stillWanted: stillWanted,
      ),
      _ => Future<PrimarySwitchResult>.value(PrimarySwitchResult.done),
    };
  }

  /// Makes [backend] the one in charge, and fails, changing nothing, when
  /// that does not reach disk: the switch's intent then stays for the next
  /// start to finish, rather than that start reading the old backend and
  /// undoing the switch.
  Future<void> _preferBackend(PreferredBackend backend) async {
    await PreferencesStore.putChecked(
      PreferenceKeys.preferredBackend,
      backend.name,
    );
    await _ref.read(preferredBackendProvider.notifier).set(backend);
  }

  Future<void> _parkOpenWebUi() async {
    final storage = _ref.read(optimizedStorageServiceProvider);
    // Parked, no account reads as active, unless a park was cut short after
    // the flag was set, leaving the stored id naming one.
    final active = await storage.getEffectiveActiveServerId();
    if (active == null) return;
    if (storage.isOpenWebUiParked) {
      // That park had already filed the session away. Take it up first, so
      // parking again files it rather than the empty live slots over it.
      await storage.switchActiveServer(
        fromServerId: active,
        toServerId: active,
      );
    }
    await _ref.read(authStateManagerProvider.notifier).parkActiveAccount();
  }
}
