import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/providers/account_change_superseded.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show openWebUiAccountsProvider;
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

  /// Hands the Chats tab over after a sign-out left it with no account: to
  /// the LibreChat account [candidates] names, else its Open WebUI account,
  /// else to choosing the backend again. It waits for the switches asked
  /// for before it, and goes ahead only if [unclaimed] still holds then: a
  /// switch that ran meanwhile keeps the tab. The candidates are read at
  /// its turn, and one gone by the time it is switched to gives way to the
  /// next. Returns whether it handed the tab over.
  Future<bool> handOverUnclaimedTab({
    required bool Function() unclaimed,
    required Future<({String? libreChatId, String? openWebUiId})> Function()
    candidates,
  }) => _afterLastSwitch(() async {
    // Each try that finds its account gone leaves one fewer to pick.
    for (var attempt = 0; attempt < 3; attempt++) {
      if (!unclaimed()) return false;
      final next = await candidates();
      if (!unclaimed()) return false;
      final PrimarySwitchResult result;
      if (next.libreChatId case final id?) {
        result = await _useLibreChat(id, force: true);
      } else if (next.openWebUiId case final id?) {
        result = await _useOpenWebUi(id, force: true);
      } else {
        break;
      }
      if (result != PrimarySwitchResult.unknownAccount) return true;
    }
    if (!unclaimed()) return false;
    await _ref
        .read(preferredBackendProvider.notifier)
        .set(PreferredBackend.unset);
    return true;
  });

  /// Makes LibreChat account [accountId] the primary account.
  ///
  /// [stillFrom] is asked at the switch's turn, once the switches before it
  /// are done and before anything changes: whether the account it was asked
  /// over is still the one in charge. A sign-in step also passes
  /// [stillCurrent], asked then and after every wait of the switch: the
  /// intent, the park, putting the account in charge, and last after the
  /// backend preference is written. Answering false at any of them undoes
  /// what the switch changed so far (the preference, the active LibreChat
  /// account, Open WebUI's park) and the switch throws
  /// [AccountChangeSuperseded].
  Future<PrimarySwitchResult> useLibreChat(
    String accountId, {
    bool force = false,
    bool Function()? stillFrom,
    bool Function()? stillCurrent,
  }) => _afterLastSwitch(
    () => _useLibreChat(
      accountId,
      force: force,
      stillFrom: stillFrom,
      stillCurrent: stillCurrent,
    ),
  );

  /// [stillWanted], from a recovery, is asked just before the switch puts
  /// the backend in charge: one the user chose meanwhile stands.
  Future<PrimarySwitchResult> _useLibreChat(
    String accountId, {
    required bool force,
    bool Function()? stillWanted,
    bool Function()? stillFrom,
    bool Function()? stillCurrent,
  }) async {
    bool current() => stillCurrent?.call() ?? true;
    final registry = await _ref.read(libreChatRegistryProvider.future);
    if (registry.byId(accountId) == null) {
      return PrimarySwitchResult.unknownAccount;
    }
    final from = _ref.read(primaryAccountProvider);
    if (!(stillFrom?.call() ?? true) || !current()) {
      throw const AccountChangeSuperseded();
    }
    final to = PrimaryAccountRef(PrimaryAccountKind.libreChat, accountId);
    if (from == to) return PrimarySwitchResult.done;
    if (!force && _ref.read(accountChangeReplyGuardProvider)()) {
      return PrimarySwitchResult.blockedByActiveReply;
    }
    // What each step changed, captured exactly before anything is written,
    // for a step superseded after it: everything goes back to the value it
    // had (the saved backend choice as stored, Direct, Hermes or none
    // included; the active LibreChat account; the Open WebUI account it
    // parked), in reverse, and nothing of the switch stays.
    final previousBackend = PreferencesStore.getString(
      PreferenceKeys.preferredBackend,
    );
    final previousActive = registry.activeId;
    String? parkedId;
    var activated = false;
    var preferred = false;
    Future<Never> superseded() async {
      if (preferred) await _restoreBackend(previousBackend);
      if (activated) {
        await _ref
            .read(libreChatRegistryProvider.notifier)
            .setActive(previousActive);
      }
      if (parkedId case final id?) {
        await _ref
            .read(openWebUiAccountsControllerProvider)
            .switchTo(id, force: true);
      }
      await PrimarySwitchIntent.clear();
      throw const AccountChangeSuperseded();
    }

    _ref.read(accountChangeStopRepliesProvider)();
    await PrimarySwitchIntent(from: from, to: to).write();
    if (!current()) await superseded();
    if (from.kind == PrimaryAccountKind.openWebUi) {
      parkedId = await _parkOpenWebUi();
      if (!current()) await superseded();
    }
    await _ref.read(libreChatRegistryProvider.notifier).setActive(accountId);
    activated = true;
    if (!current()) await superseded();
    final registryNow = await _ref.read(libreChatRegistryProvider.future);
    if (registryNow.activeId != accountId) {
      // Signed out of while Open WebUI was parked for it: there is nothing
      // to put in charge. The account that was takes the tab back, Open
      // WebUI out of its park as a start-up recovery would take it.
      await _takeOpenWebUiBack(from);
      await PrimarySwitchIntent.clear();
      return PrimarySwitchResult.unknownAccount;
    }
    if (!current()) await superseded();
    if (stillWanted != null && !stillWanted()) {
      await PrimarySwitchIntent.clear();
      return PrimarySwitchResult.done;
    }
    // The last write: a step superseded while it is made takes it back too.
    await _preferBackend(PreferredBackend.libreChat);
    preferred = true;
    if (!current()) await superseded();
    await PrimarySwitchIntent.clear();
    return PrimarySwitchResult.done;
  }

  /// Takes Open WebUI out of the park a switch from [from] put it in, as a
  /// start-up recovery would.
  Future<void> _takeOpenWebUiBack(PrimaryAccountRef from) async {
    if (from.kind == PrimaryAccountKind.openWebUi && from.id != null) {
      await _ref
          .read(openWebUiAccountsControllerProvider)
          .switchTo(from.id!, force: true);
    }
  }

  /// Makes Open WebUI account [accountId] the primary account, un-parking
  /// Open WebUI. Its saved session is taken up when it still has one.
  ///
  /// [stillFrom], as for [useLibreChat]: asked at the switch's turn, and
  /// after the saved accounts are read, before anything changes.
  Future<PrimarySwitchResult> useOpenWebUi(
    String accountId, {
    bool force = false,
    bool Function()? stillFrom,
  }) => _afterLastSwitch(
    () => _useOpenWebUi(accountId, force: force, stillFrom: stillFrom),
  );

  Future<PrimarySwitchResult> _useOpenWebUi(
    String accountId, {
    required bool force,
    bool Function()? stillWanted,
    bool Function()? stillFrom,
  }) async {
    void requireFrom() {
      if (!(stillFrom?.call() ?? true)) {
        throw const AccountChangeSuperseded();
      }
    }

    requireFrom();
    final saved = await _ref
        .read(optimizedStorageServiceProvider)
        .getServerConfigsStrict();
    requireFrom();
    if (!saved.any((account) => account.id == accountId)) {
      return PrimarySwitchResult.unknownAccount;
    }
    final from = _ref.read(primaryAccountProvider);
    final to = PrimaryAccountRef(PrimaryAccountKind.openWebUi, accountId);
    if (from.kind == PrimaryAccountKind.openWebUi) {
      final result = await _ref
          .read(openWebUiAccountsControllerProvider)
          .switchTo(accountId, force: force, stillFrom: stillFrom);
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

  /// The saved backend choice put back exactly as [raw] was stored (none at
  /// all when it was absent).
  Future<void> _restoreBackend(String? raw) async {
    await PreferencesStore.putChecked(PreferenceKeys.preferredBackend, raw);
    _ref.invalidate(preferredBackendProvider);
  }

  /// Parks the active Open WebUI account; returns its id, or null when this
  /// park put nothing away (no account active, or one already parked).
  Future<String?> _parkOpenWebUi() async {
    final storage = _ref.read(optimizedStorageServiceProvider);
    // Parked, no account reads as active, unless a park was cut short after
    // the flag was set, leaving the stored id naming one.
    final active = await storage.getEffectiveActiveServerId();
    if (active == null) return null;
    final wasParked = storage.isOpenWebUiParked;
    if (wasParked) {
      // That park had already filed the session away. Take it up first, so
      // parking again files it rather than the empty live slots over it.
      await storage.switchActiveServer(
        fromServerId: active,
        toServerId: active,
      );
    }
    await _ref.read(authStateManagerProvider.notifier).parkActiveAccount();
    return wasParked ? null : active;
  }
}

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
  // The accounts left are read at the handover's turn, after any switch
  // already under way: the most recently used LibreChat account, else an
  // Open WebUI one.
  Future<({String? libreChatId, String? openWebUiId})> candidates() async {
    final remaining =
        [...(await container.read(libreChatRegistryProvider.future)).accounts]
          ..sort(
            (a, b) => (b.lastUsedAt ?? DateTime(0)).compareTo(
              a.lastUsedAt ?? DateTime(0),
            ),
          );
    if (remaining.isNotEmpty) {
      return (libreChatId: remaining.first.id, openWebUiId: null);
    }
    final openWebUi = await container.read(openWebUiAccountsProvider.future);
    return (libreChatId: null, openWebUiId: openWebUi.firstOrNull?.id);
  }

  return container
      .read(primaryAccountSwitcherProvider)
      .handOverUnclaimedTab(
        unclaimed: tabStillUnclaimed,
        candidates: candidates,
      );
}
