import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/utils/account_display.dart';
import 'package:conduit/core/utils/native_sheet_utils.dart';
import 'package:conduit/features/auth/views/backend_chooser_page.dart';
import 'package:conduit/features/librechat/views/librechat_sign_in_page.dart';
import 'package:conduit/features/librechat/views/librechat_sso_page.dart';
import 'package:conduit/features/profile/widgets/account_actions.dart'
    show
        signOutOfLibreChatAccount,
        signOutOfLibreChatAndHandOver,
        switchToLibreChatAccount;
import 'package:conduit/features/auth/widgets/auth_grouped_form.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/utility_components.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/features/librechat/models/librechat_account.dart';
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/models/librechat_server_info.dart';
import 'package:conduit_core/features/librechat/models/librechat_session.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/features/librechat/services/librechat_session_store.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show OpenWebUiAccountEntry, openWebUiAccountsProvider;
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/providers/primary_account_providers.dart';
import 'package:conduit_core/providers/primary_account_switcher.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:conduit_core/providers/storage_providers.dart';
import 'package:conduit_core/testing.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart'
    show InAppWebView;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  group('single sign-on navigation', () {
    final origins = [Uri.parse('https://chat.example.com')];
    LibreChatSsoNavigation decide(String url) =>
        libreChatSsoNavigation(Uri.parse(url), serverOrigins: origins);

    test('lets the provider and LibreChat\'s own routes load', () {
      check(
        decide('https://chat.example.com/oauth/openid'),
      ).equals(LibreChatSsoNavigation.allow);
      check(
        decide('https://idp.example.org/authorize?client_id=x'),
      ).equals(LibreChatSsoNavigation.allow);
      check(
        decide('https://chat.example.com/oauth/error'),
      ).equals(LibreChatSsoNavigation.allow);
      check(
        decide('https://chat.example.com/api/auth/refresh'),
      ).equals(LibreChatSsoNavigation.allow);
    });

    test('notes the provider returning through LibreChat\'s callback', () {
      check(
        decide('https://chat.example.com/oauth/openid/callback?code=c'),
      ).equals(LibreChatSsoNavigation.providerReturned);
      check(
        decide('https://chat.example.com/lc/oauth/saml/callback'),
      ).equals(LibreChatSsoNavigation.providerReturned);
    });

    test('the web app\'s pages are where a returned sign-in stops', () {
      check(
        decide('https://chat.example.com/c/new'),
      ).equals(LibreChatSsoNavigation.appPage);
      check(
        decide('https://CHAT.example.com:443/'),
      ).equals(LibreChatSsoNavigation.appPage);
      // A provider sharing LibreChat's address is also an app page here;
      // the page only stops there once the provider returned.
      check(
        decide('https://chat.example.com/auth/realms/main/protocol/login'),
      ).equals(LibreChatSsoNavigation.appPage);
    });

    test('a return to sign-in with an error fails', () {
      check(
        decide('https://chat.example.com/login?error=auth_failed'),
      ).equals(LibreChatSsoNavigation.fail);
      // The same page without an error is the web app's.
      check(
        decide('https://chat.example.com/login'),
      ).equals(LibreChatSsoNavigation.appPage);
    });

    test('starts and reads the session at the configured server only', () {
      check(
        libreChatSsoBase('https://chat.example.com', 'https://chat.example.com'),
      ).equals(Uri.parse('https://chat.example.com'));
      // The server's own address keeps its sub-path.
      check(
        libreChatSsoBase('https://example.com/lc', 'https://example.com/lc/'),
      ).equals(Uri.parse('https://example.com/lc'));
      // Another path on the same host can be another server behind the
      // same proxy: not followed either.
      check(
        libreChatSsoBase('https://example.com', 'https://example.com/lc/'),
      ).equals(Uri.parse('https://example.com'));
      check(
        libreChatSsoBase('https://example.com/a', 'https://example.com/b'),
      ).equals(Uri.parse('https://example.com/a'));
      // Another server named as the server's own is not followed: its
      // session would be sent to the configured one.
      check(
        libreChatSsoBase('https://evil.example', 'https://chat.example.com'),
      ).equals(Uri.parse('https://evil.example'));
      check(
        libreChatSsoBase('https://chat.example.com', null),
      ).equals(Uri.parse('https://chat.example.com'));
    });

    test('reads the session under the server\'s path', () {
      check(
        libreChatSsoCookieUrl(Uri.parse('https://chat.example.com')),
      ).equals(Uri.parse('https://chat.example.com/'));
      check(
        libreChatSsoCookieUrl(Uri.parse('https://example.com:8443/lc')),
      ).equals(Uri.parse('https://example.com:8443/lc/'));
    });

    test('reads a sub-path server\'s routes below its path', () {
      final subPath = [Uri.parse('https://example.com/oauth/librechat')];
      LibreChatSsoNavigation decideOn(String url) =>
          libreChatSsoNavigation(Uri.parse(url), serverOrigins: subPath);

      check(
        decideOn('https://example.com/oauth/librechat/oauth/openid'),
      ).equals(LibreChatSsoNavigation.allow);
      check(
        decideOn(
          'https://example.com/oauth/librechat/oauth/openid/callback?code=c',
        ),
      ).equals(LibreChatSsoNavigation.providerReturned);
      // Where LibreChat sends the browser once signed in.
      check(
        decideOn('https://example.com/oauth/librechat/c/new'),
      ).equals(LibreChatSsoNavigation.appPage);
      check(
        decideOn('https://example.com/oauth/librechat/login?error=x'),
      ).equals(LibreChatSsoNavigation.fail);
    });

    test('another port or scheme on the same host is not the server', () {
      check(
        decide('http://chat.example.com/c/new'),
      ).equals(LibreChatSsoNavigation.allow);
      check(
        decide('https://chat.example.com:8443/c/new'),
      ).equals(LibreChatSsoNavigation.allow);
    });

    testWidgets('an earlier session that cannot be cleared keeps the page '
        'closed until a retry clears it', (tester) async {
      final results = [false, true];
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: LibreChatSsoPage(
            server: const LibreChatServer(baseUrl: 'https://chat.example.com'),
            info: const LibreChatServerInfo(appTitle: 'LibreChat'),
            provider: const LibreChatSsoProvider(kind: LibreChatSsoKind.openid),
            prepareSession: () async => results[calls++],
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const Key('librechat-sso-cleanup-failed')),
        findsOneWidget,
      );
      expect(find.byType(InAppWebView), findsNothing);

      await tester.tap(find.byKey(const Key('librechat-sso-retry')));
      await tester.pump();
      check(calls).equals(2);
      expect(
        find.byKey(const Key('librechat-sso-cleanup-failed')),
        findsNothing,
      );
    });

    test('harvested cookies keep the ones that carry the session', () {
      final cookies = libreChatCookiesFrom({
        'refreshToken': 'r1',
        'token_provider': 'openid',
        'openid_user_id': 'u1',
        'empty': '',
      });
      check(cookies.hasRefreshToken).isTrue();
      check(cookies.value('openid_user_id')).equals('u1');
      check(cookies.value('empty')).isNull();
    });
  });

  group('account card', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    final account = LibreChatAccount.forUser(
      const LibreChatServer(baseUrl: 'https://chat.example.com'),
      const LibreChatUser(id: 'u1', name: 'Dev'),
      serverTitle: 'Team Chat',
    );
    final other = LibreChatAccount.forUser(
      const LibreChatServer(baseUrl: 'https://other.example.com'),
      const LibreChatUser(id: 'u2', email: 'two@example.com'),
    );

    test('names the LibreChat account in charge and counts the rest', () {
      final card = accountCardSummary(
        l10n,
        signedInName: null,
        accounts: const [],
        hermesConnections: const [
          HermesConnectionProfile(
            id: 'h1',
            name: 'Home agent',
            baseUrl: 'https://home.example',
            documentTrustPrincipalId: 'aaaaaaaa-0000-4000-8000-000000000000',
          ),
        ],
        hermesInUseId: null,
        libreChatPrimary: account,
        libreChatAccounts: [account, other],
      );
      check(card.kind).equals(AccountCardKind.libreChat);
      check(card.title).equals('Dev');
      check(card.subtitle).equals('Team Chat +2');
    });

    test('tells a LibreChat account by its email, as Open WebUI\'s is', () {
      final withEmail = LibreChatAccount.forUser(
        const LibreChatServer(baseUrl: 'https://chat.example.com'),
        const LibreChatUser(id: 'u3', name: 'Dev', email: 'dev@example.com'),
        serverTitle: 'Team Chat',
      );
      final card = accountCardSummary(
        l10n,
        signedInName: null,
        accounts: const [],
        hermesConnections: const [],
        hermesInUseId: null,
        libreChatPrimary: withEmail,
        libreChatAccounts: [withEmail],
        countsOthers: false,
      );
      check(card.kind).equals(AccountCardKind.libreChat);
      check(card.title).equals('Dev');
      check(card.subtitle).equals('dev@example.com');
    });

    test('LibreChat accounts count as others behind another backend', () {
      final card = accountCardSummary(
        l10n,
        signedInName: null,
        accounts: const [],
        hermesConnections: const [],
        hermesInUseId: null,
        libreChatAccounts: [account],
      );
      check(card.kind).equals(AccountCardKind.direct);
      check(card.subtitle).equals('+1');
    });
  });

  group('native Accounts page', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    final account = LibreChatAccount.forUser(
      const LibreChatServer(baseUrl: 'https://chat.example.com'),
      const LibreChatUser(id: 'u1', name: 'Dev'),
    );

    List<String> libreChatRows({
      required bool enabled,
      List<LibreChatAccount> accounts = const [],
      String? inCharge,
      bool signedIn = true,
    }) => [
      for (final section in buildNativeAccountsDetail(
        l10n,
        accounts: const [],
        hermesConnections: const [],
        hermesInUseId: null,
        directProfiles: const [],
        libreChatEnabled: enabled,
        libreChatAccounts: accounts,
        libreChatInChargeId: inCharge,
        libreChatInChargeSignedIn: signedIn,
      ).sections)
        for (final item in section.items)
          if (item.id.contains('librechat'))
            '${item.id}|${item.actionId}|${item.checked}',
    ];

    test('lists LibreChat accounts with a way to switch and to add', () {
      check(libreChatRows(enabled: false)).isEmpty();
      check(
        libreChatRows(enabled: true, accounts: [account]),
      ).deepEquals([
        'accounts-librechat|null|false',
        '$nativeLibreChatUseActionId:${account.id}|'
            '$nativeLibreChatUseActionId|false',
        'accounts-librechat-add|$nativeAccountAddActionId|false',
      ]);
      // Named as Add Account and Add Connection are.
      final add = [
        for (final section in buildNativeAccountsDetail(
          l10n,
          accounts: const [],
          hermesConnections: const [],
          hermesInUseId: null,
          directProfiles: const [],
          libreChatEnabled: true,
          libreChatAccounts: const [],
          libreChatInChargeId: null,
          libreChatInChargeSignedIn: true,
        ).sections)
          ...section.items,
      ].singleWhere((item) => item.id == 'accounts-librechat-add');
      check(add.title).equals('Add LibreChat Account');
    });

    test('the account in charge can be signed out of, and LibreChat\'s '
        'accounts count toward signing out of all', () {
      final other = LibreChatAccount.forUser(
        const LibreChatServer(baseUrl: 'https://ops.example.com'),
        const LibreChatUser(id: 'u2', name: 'Ops'),
      );
      final rows = [
        for (final section in buildNativeAccountsDetail(
          l10n,
          accounts: const [],
          hermesConnections: const [],
          hermesInUseId: null,
          directProfiles: const [],
          libreChatEnabled: true,
          libreChatAccounts: [account, other],
          libreChatInChargeId: account.id,
        ).sections)
          for (final item in section.items) '${item.id}|${item.actionValue}',
      ];
      check(rows).contains(
        '$nativeLibreChatSignOutActionId|${account.id}',
      );
      check(rows).contains('$nativeSignOutActionId|null');
      // Not in charge: nothing to sign out of here.
      check(libreChatRows(enabled: true, accounts: [account])).not(
        (it) => it.any((row) => row.startsWith(nativeLibreChatSignOutActionId)),
      );
    });

    test('the account in charge is checked; signed out, it can be '
        'switched to again', () {
      final inUse = libreChatRows(
        enabled: true,
        accounts: [account],
        inCharge: account.id,
      );
      check(inUse[1]).equals(
        '$nativeLibreChatUseActionId:${account.id}|null|true',
      );
      final signedOut = libreChatRows(
        enabled: true,
        accounts: [account],
        inCharge: account.id,
        signedIn: false,
      );
      check(signedOut[1]).equals(
        '$nativeLibreChatUseActionId:${account.id}|'
        '$nativeLibreChatUseActionId|true',
      );
    });
  });

  group('signing out', () {
    setUp(() {
      addTearDown(PreferencesStore.debugReset);
      PreferencesStore.debugOverride(InMemoryKeyValueStore());
    });

    test('of the account in charge hands the Chats tab to the next one, '
        'with no widget left to ask', () async {
      final older = LibreChatAccount.forUser(
        const LibreChatServer(baseUrl: 'https://chat.example.com'),
        const LibreChatUser(id: 'u1', name: 'Dev'),
      ).copyWith(lastUsedAt: DateTime.utc(2026, 1, 1));
      final newer = LibreChatAccount.forUser(
        const LibreChatServer(baseUrl: 'https://ops.example.com'),
        const LibreChatUser(id: 'u2', name: 'Ops'),
      ).copyWith(lastUsedAt: DateTime.utc(2026, 6, 1));
      final leaving = LibreChatAccount.forUser(
        const LibreChatServer(baseUrl: 'https://old.example.com'),
        const LibreChatUser(id: 'u3', name: 'Old'),
      );
      final container = ProviderContainer(
        overrides: [
          secureStorageProvider.overrideWithValue(
            InMemorySecureKeyValueStore(),
          ),
          accountChangeReplyGuardProvider.overrideWithValue(() => false),
          accountChangeStopRepliesProvider.overrideWithValue(() {}),
        ],
      );
      addTearDown(container.dispose);
      final registry = container.read(libreChatRegistryProvider.notifier);
      await container.read(libreChatRegistryProvider.future);
      await registry.save(older);
      await registry.save(newer);
      await registry.save(leaving, activate: true);
      await container
          .read(preferredBackendProvider.notifier)
          .set(PreferredBackend.libreChat);

      check(
        await signOutOfLibreChatAndHandOver(container, leaving.id),
      ).isTrue();
      check(container.read(primaryAccountProvider)).equals(
        PrimaryAccountRef(PrimaryAccountKind.libreChat, newer.id),
      );
    });

    test('leaves the Chats tab to a choice made while the accounts left '
        'are read', () async {
      final leaving = LibreChatAccount.forUser(
        const LibreChatServer(baseUrl: 'https://old.example.com'),
        const LibreChatUser(id: 'u3', name: 'Old'),
      );
      final openWebUiAccounts = Completer<List<OpenWebUiAccountEntry>>();
      final container = ProviderContainer(
        overrides: [
          secureStorageProvider.overrideWithValue(
            InMemorySecureKeyValueStore(),
          ),
          openWebUiAccountsProvider.overrideWith(
            (ref) => openWebUiAccounts.future,
          ),
          accountChangeReplyGuardProvider.overrideWithValue(() => false),
          accountChangeStopRepliesProvider.overrideWithValue(() {}),
        ],
      );
      addTearDown(container.dispose);
      final registry = container.read(libreChatRegistryProvider.notifier);
      await container.read(libreChatRegistryProvider.future);
      await registry.save(leaving, activate: true);
      await container
          .read(preferredBackendProvider.notifier)
          .set(PreferredBackend.libreChat);

      final signingOut = signOutOfLibreChatAndHandOver(container, leaving.id);
      while ((await container.read(libreChatRegistryProvider.future))
          .accounts
          .isNotEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      // The user picks Hermes before the Open WebUI accounts are read.
      await container
          .read(preferredBackendProvider.notifier)
          .set(PreferredBackend.hermes);
      openWebUiAccounts.complete(const <OpenWebUiAccountEntry>[]);

      check(await signingOut).isFalse();
      check(
        container.read(preferredBackendProvider),
      ).equals(PreferredBackend.hermes);
    });

    test('leaves the Chats tab to an account chosen while the server ends '
        'the session', () async {
      final older = LibreChatAccount.forUser(
        const LibreChatServer(baseUrl: 'https://chat.example.com'),
        const LibreChatUser(id: 'u1', name: 'Dev'),
      ).copyWith(lastUsedAt: DateTime.utc(2026, 1, 1));
      final newer = LibreChatAccount.forUser(
        const LibreChatServer(baseUrl: 'https://ops.example.com'),
        const LibreChatUser(id: 'u2', name: 'Ops'),
      ).copyWith(lastUsedAt: DateTime.utc(2026, 6, 1));
      final leaving = LibreChatAccount.forUser(
        const LibreChatServer(baseUrl: 'https://old.example.com'),
        const LibreChatUser(id: 'u3', name: 'Old'),
      );
      final secure = InMemorySecureKeyValueStore();
      final server = FakeLibreChatServer();
      final logout = Completer<void>();
      server.on('POST', '/api/auth/logout', (request, match) async {
        await logout.future;
        return FakeLibreChatResponse.json({'message': 'Logout successful'});
      });
      final container = ProviderContainer(
        overrides: [
          secureStorageProvider.overrideWithValue(secure),
          libreChatHttpAdapterProvider.overrideWithValue(server),
          accountChangeReplyGuardProvider.overrideWithValue(() => false),
          accountChangeStopRepliesProvider.overrideWithValue(() {}),
        ],
      );
      addTearDown(container.dispose);
      final registry = container.read(libreChatRegistryProvider.notifier);
      await container.read(libreChatRegistryProvider.future);
      await registry.save(older);
      await registry.save(newer);
      await registry.save(leaving, activate: true);
      await SecureLibreChatSessionStore(secure, leaving.id).write(
        const LibreChatSession(
          accessToken: 'old-token',
          user: LibreChatUser(id: 'u3', name: 'Old'),
        ),
      );
      await container
          .read(preferredBackendProvider.notifier)
          .set(PreferredBackend.libreChat);

      final signingOut = signOutOfLibreChatAndHandOver(container, leaving.id);
      while (!server.requests.any(
        (request) => request.path == '/api/auth/logout',
      )) {
        await Future<void>.delayed(Duration.zero);
      }
      // The user picks an account while the server is still answering.
      await container
          .read(primaryAccountSwitcherProvider)
          .useLibreChat(older.id);
      logout.complete();

      check(await signingOut).isFalse();
      check(container.read(primaryAccountProvider)).equals(
        PrimaryAccountRef(PrimaryAccountKind.libreChat, older.id),
      );
    });

    test('hands the Chats tab over when the account leaving was put in '
        'charge while the server ended its session', () async {
      final older = LibreChatAccount.forUser(
        const LibreChatServer(baseUrl: 'https://chat.example.com'),
        const LibreChatUser(id: 'u1', name: 'Dev'),
      ).copyWith(lastUsedAt: DateTime.utc(2026, 1, 1));
      final newer = LibreChatAccount.forUser(
        const LibreChatServer(baseUrl: 'https://ops.example.com'),
        const LibreChatUser(id: 'u2', name: 'Ops'),
      ).copyWith(lastUsedAt: DateTime.utc(2026, 6, 1));
      final leaving = LibreChatAccount.forUser(
        const LibreChatServer(baseUrl: 'https://old.example.com'),
        const LibreChatUser(id: 'u3', name: 'Old'),
      );
      final secure = InMemorySecureKeyValueStore();
      final server = FakeLibreChatServer();
      final logout = Completer<void>();
      server.on('POST', '/api/auth/logout', (request, match) async {
        await logout.future;
        return FakeLibreChatResponse.json({'message': 'Logout successful'});
      });
      final container = ProviderContainer(
        overrides: [
          secureStorageProvider.overrideWithValue(secure),
          libreChatHttpAdapterProvider.overrideWithValue(server),
          accountChangeReplyGuardProvider.overrideWithValue(() => false),
          accountChangeStopRepliesProvider.overrideWithValue(() {}),
        ],
      );
      addTearDown(container.dispose);
      final registry = container.read(libreChatRegistryProvider.notifier);
      await container.read(libreChatRegistryProvider.future);
      await registry.save(older);
      await registry.save(leaving);
      await registry.save(newer, activate: true);
      await SecureLibreChatSessionStore(secure, leaving.id).write(
        const LibreChatSession(
          accessToken: 'old-token',
          user: LibreChatUser(id: 'u3', name: 'Old'),
        ),
      );
      await container
          .read(preferredBackendProvider.notifier)
          .set(PreferredBackend.libreChat);

      // Not in charge when the sign-out starts.
      final signingOut = signOutOfLibreChatAndHandOver(container, leaving.id);
      while (!server.requests.any(
        (request) => request.path == '/api/auth/logout',
      )) {
        await Future<void>.delayed(Duration.zero);
      }
      // Put in charge while the server is still answering.
      await container
          .read(primaryAccountSwitcherProvider)
          .useLibreChat(leaving.id);
      logout.complete();

      check(await signingOut).isTrue();
      check(container.read(primaryAccountProvider)).equals(
        PrimaryAccountRef(PrimaryAccountKind.libreChat, newer.id),
      );
    });

    testWidgets('of the account in charge asks first when that stops a '
        'reply', (tester) async {
      final staying = LibreChatAccount.forUser(
        const LibreChatServer(baseUrl: 'https://ops.example.com'),
        const LibreChatUser(id: 'u2', name: 'Ops'),
      );
      final leaving = LibreChatAccount.forUser(
        const LibreChatServer(baseUrl: 'https://old.example.com'),
        const LibreChatUser(id: 'u3', name: 'Old'),
      );
      var stops = 0;
      final container = ProviderContainer(
        overrides: [
          secureStorageProvider.overrideWithValue(
            InMemorySecureKeyValueStore(),
          ),
          accountChangeReplyGuardProvider.overrideWithValue(() => true),
          accountChangeStopRepliesProvider.overrideWithValue(() => stops++),
        ],
      );
      addTearDown(container.dispose);
      final registry = container.read(libreChatRegistryProvider.notifier);
      await container.read(libreChatRegistryProvider.future);
      await registry.save(staying);
      await registry.save(leaving, activate: true);
      await container
          .read(preferredBackendProvider.notifier)
          .set(PreferredBackend.libreChat);
      final router = GoRouter(
        initialLocation: Routes.profile,
        routes: [
          GoRoute(
            path: Routes.profile,
            builder: (context, state) => TextButton(
              onPressed: () => signOutOfLibreChatAccount(context, leaving),
              child: const Text('leave'),
            ),
          ),
          GoRoute(
            path: Routes.chat,
            builder: (context, state) => const Text('chat'),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      Future<void> signOut({required String thenAnswer}) async {
        await tester.tap(find.text('leave'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sign Out'));
        await tester.pumpAndSettle();
        expect(find.text('Signing out stops it.'), findsOneWidget);
        await tester.tap(find.text(thenAnswer));
        await tester.pumpAndSettle();
      }

      await signOut(thenAnswer: 'Cancel');
      check(stops).equals(0);
      check(
        (await container.read(libreChatRegistryProvider.future)).byId(
          leaving.id,
        ),
      ).isNotNull();
      check(container.read(primaryAccountProvider)).equals(
        PrimaryAccountRef(PrimaryAccountKind.libreChat, leaving.id),
      );

      await signOut(thenAnswer: 'Sign Out Anyway');
      check(stops).isGreaterThan(0);
      check(container.read(primaryAccountProvider)).equals(
        PrimaryAccountRef(PrimaryAccountKind.libreChat, staying.id),
      );
      expect(find.text('chat'), findsOneWidget);
    });
  });

  testWidgets('a session that ended leaves the saved accounts in reach', (
    tester,
  ) async {
    final account = LibreChatAccount.forUser(
      const LibreChatServer(baseUrl: 'https://chat.example.com'),
      const LibreChatUser(id: 'u1', name: 'Dev'),
    );
    final router = GoRouter(
      initialLocation: Routes.libreChatSignIn,
      routes: [
        GoRoute(
          path: Routes.libreChatSignIn,
          builder: (context, state) => const LibreChatSignInPage(),
        ),
        GoRoute(
          path: Routes.accounts,
          builder: (context, state) => const Text('saved accounts'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          primaryAccountKindProvider.overrideWithValue(
            PrimaryAccountKind.libreChat,
          ),
          libreChatSessionProvider.overrideWith(() => _Ended(account)),
        ],
        child: MaterialApp.router(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('librechat-sign-in-accounts')));
    await tester.pumpAndSettle();

    expect(find.text('saved accounts'), findsOneWidget);
  });

  group('on iOS the page', () {
    final account = LibreChatAccount.forUser(
      const LibreChatServer(baseUrl: 'https://chat.example.com'),
      const LibreChatUser(id: 'u1', name: 'Dev'),
    );

    setUp(() {
      // The Flutter fallbacks of the native iOS 26 controls render in tests.
      PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
      PlatformUiCapabilities.debugIOSMajorVersionOverride = 18;
    });
    tearDown(PlatformUiCapabilities.resetDebugOverrides);

    Future<void> pumpPage(
      WidgetTester tester, {
      required PrimaryAccountKind inCharge,
    }) async {
      tester.view.physicalSize = const Size(1206, 2622);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final router = GoRouter(
        initialLocation: Routes.libreChatSignIn,
        routes: [
          GoRoute(
            path: Routes.libreChatSignIn,
            builder: (context, state) => const LibreChatSignInPage(),
          ),
          GoRoute(
            path: Routes.accounts,
            builder: (context, state) => const Text('saved accounts'),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            primaryAccountKindProvider.overrideWithValue(inCharge),
            libreChatSessionProvider.overrideWith(() => _Ended(account)),
            libreChatHttpAdapterProvider.overrideWithValue(
              FakeLibreChatServer(),
            ),
          ],
          child: MaterialApp.router(
            theme: ThemeData(platform: TargetPlatform.iOS),
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('has a large title, the address with the keyboard, and '
        'Connect pinned under the form', (tester) async {
      await pumpPage(tester, inCharge: PrimaryAccountKind.openWebUi);
      final page = tester.widget<UtilityPageScaffold>(
        find.byType(UtilityPageScaffold),
      );
      check(page.title).equals('LibreChat');
      check(page.largeTitle).isTrue();
      check(page.bottomAction).isA<AuthPrimaryButton>();
      check(
        tester
            .widget<AuthGroupedTextField>(
              find.byKey(const Key('librechat-server-field')),
            )
            .autofocus,
      ).isTrue();
    });

    testWidgets('a session that ended starts at its server, says why under '
        'it, and keeps the saved accounts a row away', (tester) async {
      await pumpPage(tester, inCharge: PrimaryAccountKind.libreChat);
      // Past the address the page says Sign In, as the Open WebUI sign-in
      // does; the server's row names LibreChat.
      check(
        tester
            .widget<UtilityPageScaffold>(find.byType(UtilityPageScaffold))
            .title,
      ).equals('Sign In');
      expect(
        find.descendant(
          of: find.byKey(const Key('librechat-server-row-section')),
          matching: find.text(
            'Your session on chat.example.com ended. Sign in again.',
          ),
        ),
        findsOneWidget,
      );
      final accounts = find.byKey(const Key('librechat-sign-in-accounts'));
      check(tester.widget<AuthGroupedRow>(accounts).showChevron).isTrue();
      await tester.tap(accounts);
      await tester.pumpAndSettle();
      expect(find.text('saved accounts'), findsOneWidget);
    });
  });

  testWidgets('switching to an account gone by then says so', (
    tester,
  ) async {
    addTearDown(PreferencesStore.debugReset);
    PreferencesStore.debugOverride(InMemoryKeyValueStore());
    final container = ProviderContainer(
      overrides: [
        secureStorageProvider.overrideWithValue(InMemorySecureKeyValueStore()),
        accountChangeReplyGuardProvider.overrideWithValue(() => false),
        accountChangeStopRepliesProvider.overrideWithValue(() {}),
      ],
    );
    addTearDown(container.dispose);
    await container.read(libreChatRegistryProvider.future);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                // Signed out of on another screen a moment ago.
                onPressed: () =>
                    switchToLibreChatAccount(context, ref, 'gone'),
                child: const Text('switch'),
              ),
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('switch'));
    await tester.pumpAndSettle();

    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(find.text(l10n.errorMessage), findsOneWidget);
  });

  testWidgets('a switch confirmed after the row that asked went still runs', (
    tester,
  ) async {
    addTearDown(PreferencesStore.debugReset);
    PreferencesStore.debugOverride(InMemoryKeyValueStore());
    final container = ProviderContainer(
      overrides: [
        secureStorageProvider.overrideWithValue(InMemorySecureKeyValueStore()),
        // A reply is being written: the switch asks first.
        accountChangeReplyGuardProvider.overrideWithValue(() => true),
        accountChangeStopRepliesProvider.overrideWithValue(() {}),
      ],
    );
    addTearDown(container.dispose);
    final account = LibreChatAccount.forUser(
      const LibreChatServer(baseUrl: 'https://chat.example.com'),
      const LibreChatUser(id: 'u1', name: 'Dev'),
    );
    await container.read(libreChatRegistryProvider.future);
    await container.read(libreChatRegistryProvider.notifier).save(account);
    // LibreChat is in charge already, with no account in use.
    await container
        .read(preferredBackendProvider.notifier)
        .set(PreferredBackend.libreChat);
    final showRow = ValueNotifier<bool>(true);
    addTearDown(showRow.dispose);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: showRow,
              builder: (context, show, _) => show
                  ? Consumer(
                      builder: (context, ref, _) => TextButton(
                        onPressed: () => switchToLibreChatAccount(
                          context,
                          ref,
                          account.id,
                          // As the account sheet closes itself: through its
                          // own context, gone with the row.
                          beforeLeaving: () => Navigator.of(context).pop(),
                        ),
                        child: const Text('switch'),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
        GoRoute(
          path: Routes.chat,
          builder: (context, state) => const Text('chat'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('switch'));
    await tester.pumpAndSettle();
    // The row goes while the question is up.
    showRow.value = false;
    await tester.pump();
    await tester.tap(find.text('Switch Anyway'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    check(container.read(primaryAccountProvider)).equals(
      PrimaryAccountRef(PrimaryAccountKind.libreChat, account.id),
    );
    // Chat opens all the same.
    expect(find.text('chat'), findsOneWidget);
  });

  group('backend chooser', () {
    setUp(() {
      addTearDown(PreferencesStore.debugReset);
      PreferencesStore.debugOverride(InMemoryKeyValueStore());
    });

    Future<void> pumpChooser(WidgetTester tester, {required bool enabled}) =>
        tester.pumpWidget(
          ProviderScope(
            overrides: [
              libreChatBackendEnabledProvider.overrideWithValue(enabled),
            ],
            child: MaterialApp(
              localizationsDelegates: conduitLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const BackendChooserPage(),
            ),
          ),
        );

    testWidgets('offers LibreChat, as beta, only once it is on', (
      tester,
    ) async {
      await pumpChooser(tester, enabled: false);
      await tester.pump();
      check(
        find.byKey(const Key('backend-chooser-librechat')).evaluate(),
      ).isEmpty();

      await pumpChooser(tester, enabled: true);
      await tester.pump();
      check(
        find.byKey(const Key('backend-chooser-librechat')).evaluate(),
      ).isNotEmpty();
      expect(find.text('Beta'), findsOneWidget);
    });
  });
}

/// The account in charge, whose session ended.
final class _Ended extends LibreChatSessionController {
  _Ended(this.account);

  final LibreChatAccount account;

  @override
  Future<LibreChatSessionState> build() async =>
      LibreChatNeedsSignIn(account);
}
