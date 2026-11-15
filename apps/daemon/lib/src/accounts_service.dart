import 'dart:async';

import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/features/channels/providers/channel_providers.dart';
import 'package:conduit_core/features/chat/providers/context_attachments_provider.dart';
import 'package:conduit_core/features/chat/providers/knowledge_cache_provider.dart';
import 'package:conduit_core/features/notes/providers/notes_providers.dart'
    show activeNoteProvider;
import 'package:conduit_core/features/prompts/providers/prompts_providers.dart'
    show activePromptCommandProvider;
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/misc.dart' show ProviderOrFamily;
import 'package:riverpod/riverpod.dart';
import 'package:uuid/uuid.dart';

import 'event_bus.dart';
import 'servers_service.dart';
import 'settled.dart';
import 'turns_service.dart';

/// Implements `accounts.*` over the core's [OpenWebUiAccountsController], the
/// layer mobile's Accounts page calls.
///
/// The controller decides everything that makes an account change safe:
/// which account takes over when the active one is signed out of (the most
/// recently used, preferring one still signed in), falling back to Direct or
/// Hermes when none is left, parking the session being left, purging a
/// removed account's local data, and folding a sign-in into the account the
/// same user already has on that server. This adds the boundary -- no token
/// leaves, errors leave as codes -- and the daemon's own running answers to
/// the controller's question "is a reply still being written".
final class AccountsService {
  AccountsService(this._container, {required EventBus events, this.turns})
    : _events = events {
    _watches = <ProviderSubscription<Object?>>[
      // Which account is active, after a switch, an addition or a sign-in
      // through any window or path.
      _container.listen<String?>(settledActiveAccountIdProvider, (
        previous,
        next,
      ) {
        if (previous != null && previous != next) _resetUserScoped();
        _announceSoon();
      }),
      // A sign-in finishing, or a session ending, changes whether an account
      // has a session; finishing one also ends the addition it was for.
      _container.listen<bool>(
        authStateManagerProvider.select(
          (state) => state.asData?.value.isAuthenticated ?? false,
        ),
        (previous, next) {
          if (next) _endFinishedAddition();
          _container.invalidate(openWebUiAccountsProvider);
          _announceSoon();
        },
      ),
    ];
  }

  final ProviderContainer _container;
  final EventBus _events;

  /// The daemon's running answers, which the controller cannot see: they
  /// stream in chat scopes, not in the root's one open chat.
  final TurnsService? turns;

  late final List<ProviderSubscription<Object?>> _watches;
  bool _announceScheduled = false;
  String? _lastAnnounced;

  static const Uuid _uuid = Uuid();

  OpenWebUiAccountsController get _controller =>
      _container.read(openWebUiAccountsControllerProvider);

  void dispose() {
    for (final watch in _watches) {
      watch.close();
    }
  }

  /// What the departing account owned goes when the active account changes:
  /// its conversation and folder lists, models, settings, permissions,
  /// tools, knowledge, channels, server config and socket, and the
  /// selections that name them. The same core providers mobile resets at
  /// that boundary (`app_startup_providers.dart`), less the ones only a
  /// screen has. Several rebuild on their own when the session changes;
  /// the keep-alive ones would otherwise answer for the previous account.
  void _resetUserScoped() {
    try {
      for (final provider in <ProviderOrFamily>[
        conversationsProvider,
        foldersProvider,
        modelsProvider,
        selectedModelProvider,
        isManualModelSelectionProvider,
        defaultModelProvider,
        imageModelsProvider,
        currentUserProvider,
        userSettingsProvider,
        rawUserSettingsProvider,
        personalizationSettingsProvider,
        userMemoriesProvider,
        accountProfileProvider,
        serverAboutInfoProvider,
        userPermissionsProvider,
        availableVoicesProvider,
        backendConfigProvider,
        socketServiceManagerProvider,
        toolsListProvider,
        selectedToolIdsProvider,
        selectedTerminalIdProvider,
        selectedFilterIdsProvider,
        contextAttachmentsProvider,
        knowledgeBasesProvider,
        channelsListProvider,
        activeChannelProvider,
        channelMessagesProvider,
        threadMessagesProvider,
        channelTypingUsersProvider,
        pendingFolderIdProvider,
        searchQueryProvider,
        activePromptCommandProvider,
        activeNoteProvider,
      ]) {
        _container.invalidate(provider);
      }
      _container.read(knowledgeCacheProvider.notifier).clearAllCaches();
    } on Object catch (error, stackTrace) {
      DebugLogger.error(
        'account-change-reset-failed',
        scope: 'daemon/accounts',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<AccountList> list() async {
    final entries = await readSettled(
      _container,
      openWebUiAccountsProvider.future,
    );
    final storage = _container.read(optimizedStorageServiceProvider);
    final configs = await storage.getServerConfigsStrict();
    final configsById = <String, ServerConfig>{
      for (final config in configs) config.id: config,
    };
    // The active account's user is loaded: fresher than its summary.
    final auth = _container.read(authStateManagerProvider).asData?.value;
    final activeUser = auth != null && auth.isAuthenticated ? auth.user : null;
    String? activeId;
    final accounts = <AccountSummary>[];
    for (final entry in entries) {
      if (entry.isActive) activeId = entry.id;
      final config = configsById[entry.id];
      final endpoint = entry.server.endpoints.first;
      final connection = config == null
          ? ServerSummary(
              id: entry.id,
              name: entry.server.name,
              url: endpoint.url,
              isActive: entry.isActive,
              hasStoredSession: entry.hasSession,
            )
          : ServersService.summarize(
              config,
              activeId: entry.isActive ? entry.id : '',
              hasStoredSession: entry.hasSession,
            );
      final summary = entry.summary;
      final user = entry.isActive && activeUser != null
          ? AccountUser(
              name: (activeUser.name?.trim().isNotEmpty ?? false)
                  ? activeUser.name!.trim()
                  : activeUser.username,
              email: activeUser.email.isEmpty ? null : activeUser.email,
              avatarUrl: activeUser.profileImage,
            )
          : (summary.name == null &&
                summary.email == null &&
                summary.profileImage == null)
          ? null
          : AccountUser(
              name: summary.name,
              email: summary.email,
              avatarUrl: summary.profileImage,
            );
      accounts.add(
        AccountSummary(
          id: entry.id,
          serverId: entry.server.id,
          connection: connection,
          user: user,
          isActive: entry.isActive,
          hasSession: entry.hasSession,
          lastUsedMs: summary.lastUsedAt?.millisecondsSinceEpoch,
        ),
      );
    }
    return AccountList(
      accounts: accounts,
      activeAccountId: activeId,
      addingAccount: _container.read(accountAdditionOriginProvider) != null,
    );
  }

  /// Begins adding an account on [request]'s server: a new account there
  /// becomes active, signed out, for `auth.login*` to sign in to. The account
  /// it was added from keeps its session, for [cancelAdd] to go back to.
  Future<AccountChangeResult> add(AddAccount request) async {
    final draft = request.server;
    final url = ServersService.validateUrl(draft.url);
    final name = ServersService.validateName(draft.name);
    final activeId = _container.read(settledActiveAccountIdProvider);
    if (activeId != null && !await _mayLeave(force: request.force)) {
      return _result(AccountChangeOutcome.blockedByActiveReply);
    }
    final config = ServerConfig(
      id: _uuid.v4(),
      name: name,
      url: url,
      customHeaders: draft.customHeaders ?? const <String, String>{},
      isActive: true,
      allowSelfSignedCertificates: draft.allowSelfSignedCertificates,
      mtlsCertificateChainPem: draft.mtlsCertificateChainPem,
      mtlsCertificateLabel: draft.mtlsCertificateLabel,
      mtlsPrivateKeyPem: draft.mtlsPrivateKeyPem,
      mtlsPrivateKeyLabel: draft.mtlsPrivateKeyLabel,
      mtlsPrivateKeyPassword: draft.mtlsPrivateKeyPassword,
    );
    // With an account in use this is an addition, which the core tracks so a
    // sign-in screen can go back to that account; the very first account is
    // simply the account.
    final addition = _container.read(accountAdditionOriginProvider.notifier);
    bool Function()? stillAdding;
    if (activeId != null) {
      addition.begin(activeId);
      stillAdding = addition.stillInProgress();
    }
    try {
      await _container
          .read(authStateManagerProvider.notifier)
          .selectUnauthenticatedServerConfig(config, canCommit: stillAdding);
    } on Object catch (error) {
      if (activeId != null) addition.end(activeId);
      throw RpcError(
        code: ConduitErrorCodes.serverError,
        args: <String, String>{'detail': '$error'},
        debugMessage: 'could not add the account: $error',
      );
    }
    _container.invalidate(openWebUiAccountsProvider);
    return _result(AccountChangeOutcome.needsSignIn, announce: true);
  }

  /// Leaves an addition whose sign-in has not finished: the new account is
  /// dropped and the one it was added from is active again.
  Future<AccountChangeResult> cancelAdd() async {
    final origin = _container.read(accountAdditionOriginProvider);
    if (origin == null) return _result(AccountChangeOutcome.unchanged);
    final left = await _controller.abandonPendingSignIn();
    if (!left) {
      // Nothing to drop -- the sign-in finished, or the account added from
      // is still the active one -- so the addition just ends.
      _container.read(accountAdditionOriginProvider.notifier).end(origin);
      return _result(AccountChangeOutcome.unchanged, announce: true);
    }
    _container.read(accountAdditionOriginProvider.notifier).end(origin);
    return _result(AccountChangeOutcome.done, announce: true);
  }

  Future<AccountChangeResult> switchTo(AccountRef request) async {
    await _requireAccount(request.accountId);
    final activeId = _container.read(settledActiveAccountIdProvider);
    if (activeId != request.accountId &&
        !await _mayLeave(force: request.force)) {
      return _result(AccountChangeOutcome.blockedByActiveReply);
    }
    final outcome = await _controller.switchTo(
      request.accountId,
      force: request.force,
    );
    return _result(await _settled(_outcome(outcome)), announce: true);
  }

  /// Signs out of [request]'s account and removes it with its local data,
  /// handing over to the next account when it was the active one.
  Future<AccountChangeResult> remove(AccountRef request) async {
    await _requireAccount(request.accountId);
    final activeId = _container.read(settledActiveAccountIdProvider);
    if (activeId == request.accountId &&
        !await _mayLeave(force: request.force)) {
      return _result(AccountChangeOutcome.blockedByActiveReply);
    }
    final outcome = await _controller.signOut(
      request.accountId,
      force: request.force,
    );
    return _result(await _settled(_outcome(outcome)), announce: true);
  }

  /// Signs out of the active account, as mobile's Sign out does: the next
  /// account takes over, and the others keep their sessions and data.
  Future<AccountChangeResult> signOut(AccountSignOut request) async {
    final storage = _container.read(optimizedStorageServiceProvider);
    final activeId = await storage.getEffectiveActiveServerId();
    if (activeId == null) {
      throw const RpcError(
        code: ConduitErrorCodes.unauthenticated,
        debugMessage: 'no Open WebUI account is in use',
      );
    }
    return remove(AccountRef(accountId: activeId, force: request.force));
  }

  /// Whether the active account may be left now: no answer is being written
  /// there, or [force] was given, in which case the daemon's own answers are
  /// stopped first. The controller asks the same of the root's own chat and
  /// of the direct and Hermes runs this process holds.
  Future<bool> _mayLeave({required bool force}) async {
    final running = turns?.activeChatIds.isNotEmpty ?? false;
    if (!force) {
      if (running) return false;
      try {
        return !_container.read(accountChangeReplyGuardProvider)();
      } on Object {
        return true;
      }
    }
    await turns?.stopAll();
    return true;
  }

  Future<void> _requireAccount(String accountId) async {
    final entries = await readSettled(
      _container,
      openWebUiAccountsProvider.future,
    );
    if (!entries.any((entry) => entry.id == accountId)) {
      throw RpcError(
        code: ConduitErrorCodes.notFound,
        args: <String, String>{'accountId': accountId},
        debugMessage: 'no saved account with that id',
      );
    }
  }

  /// Ends an addition whose sign-in has finished: the account it added is
  /// active and signed in, so there is nothing left to cancel.
  void _endFinishedAddition() {
    final origin = _container.read(accountAdditionOriginProvider);
    if (origin == null) return;
    final active = _container.read(settledActiveAccountIdProvider);
    if (active != null && active != origin) {
      _container.read(accountAdditionOriginProvider.notifier).end(origin);
    }
  }

  /// [outcome] once the account change has settled.
  ///
  /// The core reports whether the account now active is signed in at the
  /// moment the change returns, which can be while that account's saved
  /// session is still being checked: a switch to a signed-in account came
  /// back as "needs a sign-in" a moment before it was signed in. So a
  /// sign-in is waited for, briefly. And with no account left there is
  /// nothing to sign in to: the change is simply done.
  Future<AccountChangeOutcome> _settled(AccountChangeOutcome outcome) async {
    if (outcome != AccountChangeOutcome.needsSignIn) return outcome;
    final storage = _container.read(optimizedStorageServiceProvider);
    if (await storage.getEffectiveActiveServerId() == null) {
      return AccountChangeOutcome.done;
    }
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      final state = _container.read(authStateManagerProvider);
      final value = state.asData?.value;
      if (!state.isLoading &&
          value != null &&
          !value.isLoading &&
          value.status != AuthStatus.loading) {
        return value.isAuthenticated ? AccountChangeOutcome.done : outcome;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return outcome;
  }

  Future<AccountChangeResult> _result(
    AccountChangeOutcome outcome, {
    bool announce = false,
  }) async {
    final accounts = await list();
    if (announce) _announce(accounts);
    return AccountChangeResult(outcome: outcome, accounts: accounts);
  }

  void _announceSoon() {
    if (_announceScheduled) return;
    _announceScheduled = true;
    scheduleMicrotask(() async {
      _announceScheduled = false;
      try {
        _announce(await list());
      } on Object catch (error) {
        DebugLogger.warning(
          'accounts-announce-failed',
          scope: 'daemon/accounts',
          data: <String, Object?>{'errorType': error.runtimeType.toString()},
        );
      }
    });
  }

  /// Tells every window, once per distinct state, so a change seen through
  /// two paths (the call and the listener) is announced once.
  void _announce(AccountList accounts) {
    final signature = <String>[
      accounts.activeAccountId ?? '',
      '${accounts.addingAccount}',
      for (final account in accounts.accounts)
        '${account.id}:${account.hasSession}:${account.user?.name ?? ''}',
    ].join('|');
    if (signature == _lastAnnounced) return;
    _lastAnnounced = signature;
    _events.emit(
      ConduitEventSpecs.accountsChanged,
      AccountsChanged(activeAccountId: accounts.activeAccountId),
    );
  }

  static AccountChangeOutcome _outcome(OpenWebUiAccountChangeResult result) =>
      switch (result) {
        OpenWebUiAccountChangeResult.done => AccountChangeOutcome.done,
        OpenWebUiAccountChangeResult.needsSignIn =>
          AccountChangeOutcome.needsSignIn,
        OpenWebUiAccountChangeResult.alreadyActive =>
          AccountChangeOutcome.alreadyActive,
        OpenWebUiAccountChangeResult.blockedByActiveReply =>
          AccountChangeOutcome.blockedByActiveReply,
      };
}
