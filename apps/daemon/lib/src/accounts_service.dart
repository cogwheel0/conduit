import 'dart:async';

import 'package:conduit_core/auth/auth_state_manager.dart';
import 'package:conduit_core/features/channels/providers/channel_providers.dart';
import 'package:conduit_core/features/chat/providers/context_attachments_provider.dart';
import 'package:conduit_core/features/chat/providers/knowledge_cache_provider.dart';
import 'package:conduit_core/features/notes/providers/notes_providers.dart'
    show activeNoteProvider;
import 'package:conduit_core/features/prompts/providers/prompts_providers.dart'
    show activePromptCommandProvider;
import 'package:conduit_core/features/librechat/models/librechat_account.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/providers/account_change_superseded.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart'
    show persistOpenWebUiBackendPreference;
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/openwebui_registry.dart'
    show OpenWebUiRegistry, isCapturedSessionHeader;
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart' as backend;
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:conduit_core/providers/primary_account_providers.dart'
    show PrimaryAccountRef, primaryAccountProvider;
import 'package:conduit_core/providers/primary_account_switcher.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/misc.dart' show ProviderOrFamily;
import 'package:riverpod/riverpod.dart';
import 'package:uuid/uuid.dart';

import 'account_scope.dart';
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
          if (next) {
            _endFinishedAddition();
            unawaited(_endLibreChatAddition());
          }
          _container.invalidate(openWebUiAccountsProvider);
          _announceSoon();
        },
      ),
      // The LibreChat account in charge changing (to another LibreChat
      // account, to Open WebUI, or signed out) ends what it owned: the
      // composer's context, as mobile's startup listener does. The lists,
      // models and settings follow on their own, since they watch who owns
      // the chats.
      _container.listen<PrimaryAccountRef>(primaryAccountProvider, (
        previous,
        next,
      ) {
        if (previous != null &&
            previous.kind == backend.PrimaryAccountKind.libreChat &&
            previous.id != null &&
            previous != next) {
          _container.read(contextAttachmentsProvider.notifier).clear();
        }
        _announceSoon();
      }),
      // LibreChat accounts saved, removed, signed in or out.
      _container.listen<Object?>(
        libreChatRegistryProvider,
        (_, _) => _announceSoon(),
      ),
      _container.listen<Object?>(
        libreChatSessionProvider,
        (_, _) => _announceSoon(),
      ),
    ];
  }

  final ProviderContainer _container;
  final EventBus _events;

  /// The daemon's running answers, which the controller cannot see: they
  /// stream in chat scopes, not in the root's one open chat.
  final TurnsService? turns;

  late final List<ProviderSubscription<Object?>> _watches;

  /// An Open WebUI account being added while a LibreChat account owns the
  /// chats: that LibreChat account, which Cancel goes back to. The core's
  /// own addition tracking is Open WebUI's (it parks no LibreChat account).
  String? _libreChatAdditionFrom;

  /// Which addition [_libreChatAdditionFrom] is for: one that gives way
  /// clears it only while it is still its own, not a later one's from the
  /// same LibreChat account.
  Object? _libreChatAddition;
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
    final libreChat = await _libreChatAccounts();
    final primary = _primary();
    return AccountList(
      accounts: accounts,
      // An Open WebUI account parked for a LibreChat one in charge is not
      // in use, even while its id is still being let go of.
      activeAccountId:
          primary == PrimaryAccount.libreChat && _libreChatAdditionFrom == null
          ? null
          : activeId,
      addingAccount:
          _container.read(accountAdditionOriginProvider) != null ||
          _libreChatAdditionFrom != null,
      libreChatAccounts: libreChat.accounts,
      primary: primary,
      activeLibreChatAccountId: libreChat.activeId,
      libreChatSession: _libreChatSession(),
    );
  }

  PrimaryAccount _primary() =>
      _container.read(backend.primaryAccountKindProvider) ==
          backend.PrimaryAccountKind.libreChat
      ? PrimaryAccount.libreChat
      : PrimaryAccount.openWebUi;

  /// The saved LibreChat accounts, newest-used first, as the phone's
  /// Accounts page lists them.
  Future<({List<LibreChatAccountSummary> accounts, String? activeId})>
  _libreChatAccounts() async {
    final LibreChatRegistry registry;
    try {
      registry = await readSettled(
        _container,
        libreChatRegistryProvider.future,
      );
    } on Object catch (error) {
      DebugLogger.warning(
        'librechat-registry-unread',
        scope: 'daemon/accounts',
        data: <String, Object?>{'errorType': error.runtimeType.toString()},
      );
      return (accounts: const <LibreChatAccountSummary>[], activeId: null);
    }
    final store = _container.read(libreChatRegistryStoreProvider);
    final sorted = [...registry.accounts]
      ..sort(
        (a, b) => (b.lastUsedAt ?? DateTime(0)).compareTo(
          a.lastUsedAt ?? DateTime(0),
        ),
      );
    final accounts = <LibreChatAccountSummary>[];
    for (final account in sorted) {
      var hasSession = false;
      try {
        hasSession = await store.sessionStore(account.id).read() != null;
      } on Object {
        // Unreadable reads as needing a sign-in, as the core treats it.
      }
      final name = account.displayName.trim();
      accounts.add(
        LibreChatAccountSummary(
          id: account.id,
          baseUrl: account.server.baseUrl,
          title: (account.serverTitle?.trim().isNotEmpty ?? false)
              ? account.serverTitle!.trim()
              : account.host,
          user: name.isEmpty && account.email == null
              ? null
              : AccountUser(
                  name: name.isEmpty ? null : name,
                  email: account.email,
                ),
          isActive: account.id == registry.activeId,
          hasSession: hasSession,
          lastUsedMs: account.lastUsedAt?.millisecondsSinceEpoch,
        ),
      );
    }
    return (accounts: accounts, activeId: registry.activeId);
  }

  LibreChatSessionPhase _libreChatSession() =>
      switch (_container.read(libreChatSessionProvider)) {
        AsyncData(value: LibreChatSignedInState()) =>
          LibreChatSessionPhase.signedIn,
        AsyncData(value: LibreChatNeedsSignIn()) ||
        AsyncError() => LibreChatSessionPhase.needsSignIn,
        AsyncData(value: LibreChatNoAccount()) => LibreChatSessionPhase.none,
        _ => LibreChatSessionPhase.loading,
      };

  /// Puts LibreChat account [accountId] in charge of the chats, parking
  /// Open WebUI: the core's switch, as the phone's account rows and sign-in
  /// use it. Refused while an answer is being written, unless [force].
  ///
  /// A switch bound to the account it was asked under passes [scope]; a
  /// sign-in also passes [stillCurrent]. Both are asked after every wait
  /// here and at the core switch's turn, before anything changes;
  /// [stillCurrent] again inside the switch, last just before the account
  /// is put in charge. A change superseded by then switches nothing and
  /// this throws [AccountChangeSuperseded].
  Future<AccountChangeResult> useLibreChat(
    String accountId, {
    bool force = false,
    AccountScope? scope,
    bool Function()? stillCurrent,
  }) async {
    void requireCurrent() {
      if (!(scope?.isCurrent ?? true) || !(stillCurrent?.call() ?? true)) {
        throw const AccountChangeSuperseded();
      }
    }

    requireCurrent();
    final inCharge =
        _primary() == PrimaryAccount.libreChat &&
        _container.read(activeLibreChatAccountProvider)?.id == accountId;
    if (inCharge) {
      return _result(AccountChangeOutcome.alreadyActive, announce: true);
    }
    if (!await _mayLeave(force: force)) {
      return _result(AccountChangeOutcome.blockedByActiveReply);
    }
    requireCurrent();
    final result = await _container
        .read(primaryAccountSwitcherProvider)
        .useLibreChat(
          accountId,
          force: true,
          stillFrom: scope == null ? null : () => scope.isCurrent,
          stillCurrent: stillCurrent,
        );
    return _result(switch (result) {
      PrimarySwitchResult.done => await _libreChatSettled(),
      PrimarySwitchResult.blockedByActiveReply =>
        AccountChangeOutcome.blockedByActiveReply,
      PrimarySwitchResult.unknownAccount => throw RpcError(
        code: ConduitErrorCodes.notFound,
        args: <String, String>{'accountId': accountId},
        debugMessage: 'no saved LibreChat account with that id',
      ),
    }, announce: true);
  }

  /// Whether the LibreChat account now in charge is signed in, once its
  /// saved session has been read (briefly waited for).
  Future<AccountChangeOutcome> _libreChatSettled() async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      switch (_libreChatSession()) {
        case LibreChatSessionPhase.signedIn:
          return AccountChangeOutcome.done;
        case LibreChatSessionPhase.needsSignIn:
          return AccountChangeOutcome.needsSignIn;
        case LibreChatSessionPhase.none:
        case LibreChatSessionPhase.loading:
          await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    return AccountChangeOutcome.done;
  }

  /// Signs out of LibreChat account [accountId] with its local chats; the
  /// next account takes over when it was in charge (the core's hand-over:
  /// the LibreChat account used last, else an Open WebUI account, else the
  /// backend is chosen again).
  Future<AccountChangeResult> _removeLibreChat(
    String accountId, {
    required bool force,
  }) async {
    final inCharge =
        _primary() == PrimaryAccount.libreChat &&
        _container.read(activeLibreChatAccountProvider)?.id == accountId;
    if (inCharge && !await _mayLeave(force: force)) {
      return _result(AccountChangeOutcome.blockedByActiveReply);
    }
    await signOutOfLibreChatAndHandOver(_container, accountId);
    return _result(AccountChangeOutcome.done, announce: true);
  }

  /// Begins adding an account on [request]'s server: a new account there
  /// becomes active, signed out, for `auth.login*` to sign in to. The account
  /// it was added from keeps its session, for [cancelAdd] to go back to.
  ///
  /// Bound to the account in charge when it was asked: once another one
  /// is (another window switched meanwhile), it stops no reply and adds
  /// nothing. Refused the same way when the addition ended, or was
  /// overtaken, before its account was selected.
  Future<AccountChangeResult> add(AddAccount request) async {
    final scope = AccountScope.capture(_container);
    final draft = request.server;
    // Add Account on This Server: its first address, as it is saved.
    final onServer = request.serverId == null
        ? null
        : await _firstAddressOf(request.serverId!);
    final url = onServer?.url ?? ServersService.validateUrl(draft.url);
    final name = onServer?.name ?? ServersService.validateName(draft.name);
    scope.require('an account addition stops replies');
    final activeId = _container.read(settledActiveAccountIdProvider);
    // Added while a LibreChat account owns the chats: its sign-in shows
    // (the window routes on the addition), and Cancel goes back to it.
    final fromLibreChat = _primary() == PrimaryAccount.libreChat
        ? _container.read(activeLibreChatAccountProvider)?.id
        : null;
    if ((activeId != null || fromLibreChat != null) &&
        !await _mayLeave(force: request.force)) {
      return _result(AccountChangeOutcome.blockedByActiveReply);
    }
    // The server's first address as saved now, after the wait above; and,
    // when the selection is written, that address must still be the
    // server's first, or the account would join through another one, or
    // become a server of its own (another window moved or removed it).
    final joined = request.serverId == null
        ? null
        : await _firstAddressOf(request.serverId!);
    scope.require('an account addition begins');
    // Only once that lookup held: Cancel goes back to LibreChat.
    final thisAddition = Object();
    if (fromLibreChat != null) {
      _libreChatAdditionFrom = fromLibreChat;
      _libreChatAddition = thisAddition;
    }
    var moved = false;
    bool joins(OpenWebUiRegistry stored) {
      final still =
          stored
              .server(request.serverId!)
              ?.endpoints
              .firstOrNull
              ?.carries(joined!) ??
          false;
      if (!still) moved = true;
      return still;
    }

    final config =
        joined ??
        ServerConfig(
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
    void Function()? endAddition;
    if (activeId != null) {
      addition.begin(activeId);
      stillAdding = addition.stillInProgress();
      endAddition = addition.endLater();
    }
    // Ends this addition alone: never one begun after it, from the same
    // account or LibreChat account included, which it gave way to.
    void giveUp() {
      endAddition?.call();
      if (identical(_libreChatAddition, thisAddition)) {
        _libreChatAdditionFrom = null;
        _libreChatAddition = null;
      }
    }

    final bool selected;
    try {
      selected = await _container
          .read(authStateManagerProvider.notifier)
          .selectUnauthenticatedServerConfig(
            config,
            canCommit: stillAdding,
            joins: joined == null ? null : joins,
          );
    } on Object catch (error) {
      giveUp();
      throw RpcError(
        code: ConduitErrorCodes.serverError,
        args: <String, String>{'detail': '$error'},
        debugMessage: 'could not add the account: $error',
      );
    }
    if (moved) {
      giveUp();
      throw RpcError(
        code: ConduitErrorCodes.notFound,
        args: <String, String>{'serverId': request.serverId!},
        debugMessage:
            "the server's first address changed while the account was "
            'added: add it again',
      );
    }
    if (!selected) {
      giveUp();
      throw const RpcError(
        code: ConduitErrorCodes.sessionExpired,
        args: <String, String>{'reason': 'account'},
        debugMessage: 'the addition ended before its account was selected',
      );
    }
    _container.invalidate(openWebUiAccountsProvider);
    return _result(AccountChangeOutcome.needsSignIn, announce: true);
  }

  /// A new account's connection on the saved server [serverId]: its first
  /// address with that address's headers and certificates, as the phone's
  /// Add Account on This Server fills its form. Not the proxy cookie an
  /// account keeps there: that is the account's own.
  Future<ServerConfig> _firstAddressOf(String serverId) async {
    final registry = await _container
        .read(optimizedStorageServiceProvider)
        .getOpenWebUiRegistryStrict();
    final server = registry.server(serverId);
    if (server == null) {
      throw RpcError(
        code: ConduitErrorCodes.notFound,
        args: <String, String>{'serverId': serverId},
        debugMessage: 'no saved server with that id',
      );
    }
    final endpoint = server.endpoints.first;
    return ServerConfig(
      id: _uuid.v4(),
      name: server.name,
      url: endpoint.url,
      customHeaders: <String, String>{
        for (final header in endpoint.customHeaders.entries)
          if (!isCapturedSessionHeader(header.key)) header.key: header.value,
      },
      isActive: true,
      allowSelfSignedCertificates: endpoint.allowSelfSignedCertificates,
      mtlsCertificateChainPem: endpoint.mtlsCertificateChainPem,
      mtlsCertificateLabel: endpoint.mtlsCertificateLabel,
      mtlsPrivateKeyPem: endpoint.mtlsPrivateKeyPem,
      mtlsPrivateKeyLabel: endpoint.mtlsPrivateKeyLabel,
      mtlsPrivateKeyPassword: endpoint.mtlsPrivateKeyPassword,
    );
  }

  /// Leaves an addition whose sign-in has not finished: the new account is
  /// dropped and the one it was added from is active again.
  Future<AccountChangeResult> cancelAdd() async {
    final libreChat = _libreChatAdditionFrom;
    if (libreChat != null) {
      // The new account goes (it never signed in), and the LibreChat account
      // it was added from owns the chats again.
      _libreChatAdditionFrom = null;
      final storage = _container.read(optimizedStorageServiceProvider);
      final pending = await storage.getEffectiveActiveServerId();
      if (pending != null) {
        await _controller.signOut(pending, force: true);
      }
      return useLibreChat(libreChat, force: true);
    }
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

  /// Switches to [request]'s account.
  ///
  /// A forced switch (it stops the answer being written in the account it
  /// leaves) must name the account the user was asked over (`askedOver`),
  /// and is bound to it: refused when another account is in charge as it
  /// arrives, after each wait here, and at its turn in the switch queue,
  /// before anything is stopped or changed. A plain switch, which stops
  /// nothing, goes ahead from whichever account is in charge.
  Future<AccountChangeResult> switchTo(AccountRef request) async {
    // Before anything is awaited: the account in charge as it came in.
    final scope = AccountScope.capture(_container);
    final askedOver = request.askedOver;
    if (request.force && askedOver == null) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        args: const <String, String>{'reason': 'askedOver'},
        debugMessage:
            'a forced switch to ${request.accountId} names the account it '
            'was asked over',
      );
    }
    final bound = askedOver == null ? null : scope;
    final refused = RpcError(
      code: ConduitErrorCodes.sessionExpired,
      args: const <String, String>{'reason': 'account'},
      debugMessage:
          'the switch to ${request.accountId} was asked over another '
          'account than the one in charge',
    );
    void requireBound() {
      if (bound != null && !bound.isCurrent) throw refused;
    }

    final bool Function()? stillFrom = bound == null
        ? null
        : () => bound.isCurrent;
    if (bound != null && bound.primary?.id != askedOver) throw refused;
    try {
      if (LibreChatAccount.isLibreChatAccountId(request.accountId)) {
        return await useLibreChat(
          request.accountId,
          force: request.force,
          scope: bound,
        );
      }
      await _requireAccount(request.accountId);
      requireBound();
      if (_primary() == PrimaryAccount.libreChat) {
        // Open WebUI comes back out of its park, through the core's switch.
        if (!await _mayLeave(force: request.force)) {
          return await _result(AccountChangeOutcome.blockedByActiveReply);
        }
        requireBound();
        await _container
            .read(primaryAccountSwitcherProvider)
            .useOpenWebUi(request.accountId, force: true, stillFrom: stillFrom);
        return await _result(
          await _settled(AccountChangeOutcome.needsSignIn),
          announce: true,
        );
      }
      final activeId = _container.read(settledActiveAccountIdProvider);
      if (activeId != request.accountId &&
          !await _mayLeave(force: request.force)) {
        return await _result(AccountChangeOutcome.blockedByActiveReply);
      }
      requireBound();
      final outcome = await _controller.switchTo(
        request.accountId,
        force: request.force,
        stillFrom: stillFrom,
      );
      return await _result(await _settled(_outcome(outcome)), announce: true);
    } on AccountChangeSuperseded {
      // Another account took charge while it waited its turn.
      throw refused;
    }
  }

  /// Signs out of [request]'s account and removes it with its local data,
  /// handing over to the next account when it was the active one.
  Future<AccountChangeResult> remove(AccountRef request) async {
    if (LibreChatAccount.isLibreChatAccountId(request.accountId)) {
      return _removeLibreChat(request.accountId, force: request.force);
    }
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
    if (_primary() == PrimaryAccount.libreChat) {
      final active = _container.read(activeLibreChatAccountProvider);
      if (active != null) {
        return _removeLibreChat(active.id, force: request.force);
      }
    }
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

  /// An Open WebUI account added from LibreChat signed in: Open WebUI owns
  /// the chats now, as a sign-in on the phone makes it (the core's
  /// `persistOpenWebUiBackendPreference`).
  Future<void> _endLibreChatAddition() async {
    if (_libreChatAdditionFrom == null) return;
    _libreChatAdditionFrom = null;
    try {
      await persistOpenWebUiBackendPreference(
        current: _container.read(backend.preferredBackendProvider),
        persist: _container.read(backend.preferredBackendProvider.notifier).set,
      );
    } on Object catch (error) {
      DebugLogger.warning(
        'librechat-addition-prefer-failed',
        scope: 'daemon/accounts',
        data: <String, Object?>{'errorType': error.runtimeType.toString()},
      );
    }
    _announceSoon();
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
      accounts.primary.name,
      accounts.activeLibreChatAccountId ?? '',
      accounts.libreChatSession.name,
      for (final account in accounts.libreChatAccounts)
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
