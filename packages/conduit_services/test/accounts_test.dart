@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show chatSessionRegistryProvider;
import 'package:conduit_core/database/database_provider.dart'
    show openWebUiCertifiedDatabaseServerProvider;
import 'package:conduit_core/features/direct_connections/services/direct_model_registry.dart';
import 'package:conduit_core/providers/account_change_reset.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show
        defaultModelProvider,
        searchQueryProvider,
        settledActiveAccountIdProvider;
import 'package:conduit_core/providers/openwebui_accounts_controller.dart'
    show openWebUiAccountsControllerProvider;
import 'package:conduit_core/providers/storage_providers.dart'
    show optimizedStorageServiceProvider;
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduit_services/conduit_services.dart';
import 'package:test/test.dart';

import 'support/fake_owui_auth_server.dart';
import 'support/core.dart';
import 'support/scripted_openai.dart';

/// `accounts.*` over the core's accounts controller, against a fake Open
/// WebUI with two synthetic users: adding an account and cancelling it,
/// switching, signing out with hand-over to the next account, removing the
/// last one, folding a duplicate sign-in, and refusing to leave an account
/// mid-answer unless told to.
///
/// One daemon for the file, and the tests run in order: `PreferencesStore`
/// and Hive are process-wide.
void main() {
  late Directory temporary;
  late CoreRuntime runtime;
  late FakeOwuiAuthServer owui;
  late ScriptedOpenAi provider;
  late EventBus events;
  late TurnsService turns;
  late AccountsService accounts;
  late AuthService auth;
  final announced = <AccountsChanged>[];
  final announcements = StreamController<void>.broadcast();

  setUpAll(() async {
    temporary = Directory.systemTemp.createTempSync('accounts-test');
    runtime = await startTestCore(temporary);
    owui = await FakeOwuiAuthServer.start(
      users: const {
        'ada@example.com': (id: 'user-ada', name: 'Ada', password: 'pw-ada'),
        'bob@example.com': (id: 'user-bob', name: 'Bob', password: 'pw-bob'),
      },
    );
    provider = await ScriptedOpenAi.start();
    events = EventBus();
    events.attach('window', (envelope) {
      if (envelope.event == ConduitEvents.accountsChanged) {
        announced.add(AccountsChanged.fromJson(envelope.payload));
        announcements.add(null);
      }
    });
    turns = TurnsService(runtime.container, events);
    accounts = AccountsService(runtime.container, events: events, turns: turns);
    auth = AuthService(runtime.container);
  });

  tearDownAll(() async {
    accounts.dispose();
    await turns.dispose();
    await provider.close();
    await owui.close();
    await runtime.dispose();
    await announcements.close();
    temporary.deleteSync(recursive: true);
  });

  Future<void> signIn(String email, String password) async {
    final snapshot = await auth.loginWithPassword(
      PasswordLogin(username: email, password: password),
    );
    expect(snapshot.isAuthenticated, isTrue, reason: 'signed in as $email');
  }

  /// The account list once [ready] holds. Every change it can wait for
  /// (the active account, an addition, a session, a user) is announced, so
  /// it reads again after each announcement.
  Future<AccountList> settledList(bool Function(AccountList) ready) async {
    while (true) {
      final next = announcements.stream.first;
      final list = await accounts.list();
      if (ready(list)) return list;
      await next;
    }
  }

  /// Waits until [accountId]'s database is certified for its signed-in user.
  /// That is when the core records which user the account belongs to, and
  /// a later sign-in as the same user folds into it only once recorded. A
  /// switch before then abandons the certification, so a test that switches
  /// right after a sign-in waits here first.
  Future<void> certified(String accountId) async {
    final done = Completer<void>();
    final watch = runtime.container.listen<String?>(
      openWebUiCertifiedDatabaseServerProvider,
      (_, next) {
        if (next == accountId && !done.isCompleted) done.complete();
      },
      fireImmediately: true,
    );
    await done.future;
    watch.close();
  }

  /// The user the core has recorded for [accountId].
  Future<String?> recordedUser(String accountId) async {
    final registry = await runtime.container
        .read(optimizedStorageServiceProvider)
        .getOpenWebUiRegistryStrict();
    return registry.account(accountId)?.userId;
  }

  AccountSummary active(AccountList list) =>
      list.accounts.singleWhere((a) => a.id == list.activeAccountId);

  late String adaAccount;
  late String bobAccount;

  test('a fresh daemon has no accounts', () async {
    final list = await accounts.list();
    expect(list.accounts, isEmpty);
    expect(list.activeAccountId, isNull);
    expect(list.addingAccount, isFalse);
  });

  test('the first account is added, then signed in to', () async {
    final added = await accounts.add(
      AddAccount(
        server: ServerDraft(name: 'Fake', url: owui.url),
      ),
    );
    expect(added.outcome, AccountChangeOutcome.needsSignIn);
    // The first account is simply the account, not an addition.
    expect(added.accounts.addingAccount, isFalse);
    expect(added.accounts.accounts, hasLength(1));
    final first = active(added.accounts);
    expect(first.hasSession, isFalse);
    expect(first.connection.url, owui.url);

    await signIn('ada@example.com', 'pw-ada');
    final list = await settledList((l) => active(l).hasSession);
    adaAccount = list.activeAccountId!;
    await certified(adaAccount);
    expect(await recordedUser(adaAccount), 'user-ada');
    expect(active(list).hasSession, isTrue);
    expect(active(list).user?.name, 'Ada');
    expect(active(list).user?.email, 'ada@example.com');
    expect(announced, isNotEmpty);
  });

  test('adding another account keeps the first one\'s session', () async {
    final added = await accounts.add(
      AddAccount(
        server: ServerDraft(name: 'Fake', url: owui.url),
      ),
    );
    expect(added.outcome, AccountChangeOutcome.needsSignIn);
    expect(added.accounts.addingAccount, isTrue);
    expect(added.accounts.activeAccountId, isNot(adaAccount));
    final ada = added.accounts.accounts.singleWhere((a) => a.id == adaAccount);
    expect(ada.hasSession, isTrue);
    // On the same server, so listed together.
    expect(active(added.accounts).serverId, ada.serverId);
  });

  test('cancelling the addition goes back, still signed in', () async {
    final cancelled = await accounts.cancelAdd();
    expect(cancelled.outcome, AccountChangeOutcome.done);
    expect(cancelled.accounts.addingAccount, isFalse);
    expect(cancelled.accounts.activeAccountId, adaAccount);
    expect(cancelled.accounts.accounts, hasLength(1));
    final status = await auth.status();
    expect(status.isAuthenticated, isTrue);
    expect(status.user?.name, 'Ada');
    // Nothing left to cancel.
    expect(
      (await accounts.cancelAdd()).outcome,
      AccountChangeOutcome.unchanged,
    );
  });

  test('a second account is added and signed in to', () async {
    await accounts.add(
      AddAccount(
        server: ServerDraft(name: 'Fake', url: owui.url),
      ),
    );
    await signIn('bob@example.com', 'pw-bob');
    final list = await settledList(
      (l) => !l.addingAccount && active(l).hasSession,
    );
    bobAccount = list.activeAccountId!;
    expect(bobAccount, isNot(adaAccount));
    await certified(bobAccount);
    expect(await recordedUser(bobAccount), 'user-bob');
    expect(list.addingAccount, isFalse);
    expect(
      list.accounts.map((a) => a.id),
      containsAll([adaAccount, bobAccount]),
    );
    expect(list.accounts.every((a) => a.hasSession), isTrue);
    expect(active(list).user?.name, 'Bob');
  });

  test('switching restores the other account\'s session', () async {
    final switched = await accounts.switchTo(AccountRef(accountId: adaAccount));
    expect(switched.outcome, AccountChangeOutcome.done);
    expect(switched.accounts.activeAccountId, adaAccount);
    final status = await auth.status();
    expect(status.isAuthenticated, isTrue);
    expect(status.user?.name, 'Ada');
    expect(announced.last.activeAccountId, adaAccount);

    final again = await accounts.switchTo(AccountRef(accountId: adaAccount));
    expect(again.outcome, AccountChangeOutcome.alreadyActive);
  });

  test('over a container an app shares, a switch is reset once, by the '
      "app's own listener, whether the app or a window starts it", () async {
    // The app's container: its root listener resets the departing account's
    // state on every change of account, as `userScopedProviderCleanup`
    // does, and was listening before the services came. Right after, the
    // app starts filling the new account's state, which a second reset
    // would drop.
    accounts.dispose();
    var resets = 0;
    var appHasReset = Completer<void>();
    final appReset = runtime.container.listen<String?>(
      settledActiveAccountIdProvider,
      (previous, next) {
        if (previous == null || previous == next) return;
        resets++;
        resetOpenWebUiAccountState(runtime.container);
        runtime.container.read(searchQueryProvider.notifier).set(next!);
        if (!appHasReset.isCompleted) appHasReset.complete();
      },
    );
    final query = runtime.container.listen(searchQueryProvider, (_, _) {});
    accounts = AccountsService(
      runtime.container,
      events: events,
      turns: turns,
      sharesAppContainer: true,
    );
    addTearDown(() {
      accounts.dispose();
      appReset.close();
      query.close();
      accounts = AccountsService(
        runtime.container,
        events: events,
        turns: turns,
      );
    });

    // The services' own listener on the same change runs in the same round
    // as the app's, so once the app has reset, a second reset has happened
    // too if there is one.
    Future<void> expectResetOnce(String accountId, String startedBy) async {
      await appHasReset.future;
      expect(resets, 1, reason: '$startedBy: resets');
      expect(
        runtime.container.read(searchQueryProvider),
        accountId,
        reason: "$startedBy: the app's state for the new account kept",
      );
      resets = 0;
      appHasReset = Completer<void>();
    }

    // Started in the app's own interface: the core's accounts controller.
    await runtime.container
        .read(openWebUiAccountsControllerProvider)
        .switchTo(bobAccount);
    await expectResetOnce(bobAccount, 'the app');

    // Started by a window: `accounts.switch`.
    final switched = await accounts.switchTo(AccountRef(accountId: adaAccount));
    expect(switched.outcome, AccountChangeOutcome.done);
    await expectResetOnce(adaAccount, 'a window');
  });

  test('switching to an unknown account is resource.notFound', () async {
    await expectLater(
      accounts.switchTo(const AccountRef(accountId: 'no-such-account')),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.notFound,
        ),
      ),
    );
  });

  test('an account mid-answer is not left unless told to', () async {
    final direct = DirectService(runtime.container);
    final saved = await direct.save(
      DirectConnectionEdit(
        name: 'Scripted',
        kind: DirectKind.openai,
        baseUrl: provider.baseUrl,
        manualModelIds: const <String>['scripted-model'],
      ),
    );
    final model = DirectModelId.encode(
      saved.connections.single.id,
      'scripted-model',
    );
    final accepted = await turns.send(
      SendTurn(model: model, text: 'hold:busy writing a long answer'),
    );
    expect(turns.activeChatIds, contains(accepted.chatId));
    // A temporary chat of Ada's, which the next account must not see.
    turns.temporary.start('local:ada-scratch');

    final blocked = await accounts.switchTo(AccountRef(accountId: bobAccount));
    expect(blocked.outcome, AccountChangeOutcome.blockedByActiveReply);
    expect(blocked.accounts.activeAccountId, adaAccount);

    // Switch Anyway names the account it was asked over.
    final forced = await accounts.switchTo(
      AccountRef(accountId: bobAccount, force: true, askedOver: adaAccount),
    );
    expect(forced.outcome, AccountChangeOutcome.done);
    expect(forced.accounts.activeAccountId, bobAccount);
    expect(turns.activeChatIds, isEmpty);
    expect(turns.temporary.contains('local:ada-scratch'), isFalse);
    // The chat belonged to the account it was opened under: its scope went
    // with it.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (runtime.container
            .read(chatSessionRegistryProvider)
            .scopes
            .isNotEmpty &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(runtime.container.read(chatSessionRegistryProvider).scopes, isEmpty);
    provider.release('busy');
    await direct.remove(saved.connections.single.id);
    await accounts.switchTo(AccountRef(accountId: adaAccount));
  });

  test('a Direct model picked stays New Chat\'s across a change of account; '
      'an Open WebUI one stays with its account', () async {
    owui.models = const <String>['harbor-model', 'cove-model'];
    addTearDown(() => owui.models = const <String>[]);
    final direct = DirectService(runtime.container);
    final saved = await direct.save(
      DirectConnectionEdit(
        name: 'Bench',
        kind: DirectKind.openai,
        baseUrl: provider.baseUrl,
        manualModelIds: const <String>['bench-model'],
      ),
    );
    final connection = saved.connections.singleWhere((c) => c.name == 'Bench');
    addTearDown(() => direct.remove(connection.id));
    final directModel = DirectModelId.encode(connection.id, 'bench-model');
    final models = ModelsService(runtime.container);

    /// New Chat's model under [accountId], once the change to it has
    /// settled: the account's default is restored as it changes.
    Future<String?> newChatUnder(String accountId) async {
      final switched = await accounts.switchTo(AccountRef(accountId: accountId));
      expect(switched.outcome, AccountChangeOutcome.done);
      await pumpEventQueue();
      await runtime.container.read(defaultModelProvider.future);
      return (await models.list()).selectedId;
    }

    // Ada picks the Direct model for New Chat; Bob's New Chat keeps it.
    await models.select(directModel);
    expect(await newChatUnder(bobAccount), directModel);
    // Bob picks one of the server's: Ada's New Chat does not take it.
    await models.select('cove-model');
    expect(await newChatUnder(adaAccount), isNot('cove-model'));
  });

  test('signing in again as a saved user folds into that account', () async {
    await accounts.add(
      AddAccount(
        server: ServerDraft(name: 'Fake', url: owui.url),
      ),
    );
    await signIn('bob@example.com', 'pw-bob');
    final list = await settledList(
      (l) => l.accounts.length == 2 && !l.addingAccount,
    );
    expect(list.accounts.map((a) => a.id).toSet(), {adaAccount, bobAccount});
    expect(list.activeAccountId, bobAccount);
  });

  test('signing out hands over to the next account', () async {
    final before = owui.signedOut.length;
    final signedOut = await accounts.signOut(const AccountSignOut());
    expect(signedOut.outcome, AccountChangeOutcome.done);
    // Bob is gone, with his session ended on the server; Ada takes over,
    // still signed in.
    expect(signedOut.accounts.accounts.map((a) => a.id), [adaAccount]);
    expect(signedOut.accounts.activeAccountId, adaAccount);
    expect(owui.signedOut.skip(before), contains('bob@example.com'));
    final status = await auth.status();
    expect(status.isAuthenticated, isTrue);
    expect(status.user?.name, 'Ada');
  });

  test(
    'removing the last account leaves none, for the backend chooser',
    () async {
      final removed = await accounts.remove(AccountRef(accountId: adaAccount));
      expect(removed.outcome, AccountChangeOutcome.done);
      expect(removed.accounts.accounts, isEmpty);
      expect(removed.accounts.activeAccountId, isNull);
      expect(owui.signedOut, contains('ada@example.com'));
      expect(announced.last.activeAccountId, isNull);
      // Nothing left to sign out of.
      await expectLater(
        accounts.signOut(const AccountSignOut()),
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            ConduitErrorCodes.unauthenticated,
          ),
        ),
      );
    },
  );

  test('an address that is not http(s) is refused', () async {
    for (final url in <String>['file:///etc/passwd', 'not a url', 'https://']) {
      await expectLater(
        accounts.add(
          AddAccount(
            server: ServerDraft(name: 'Bad', url: url),
          ),
        ),
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            ConduitErrorCodes.invalidParams,
          ),
        ),
        reason: url,
      );
    }
  });
}
