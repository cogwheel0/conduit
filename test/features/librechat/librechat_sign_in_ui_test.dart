import 'package:checks/checks.dart';
import 'package:conduit/core/utils/account_display.dart';
import 'package:conduit/core/utils/native_sheet_utils.dart';
import 'package:conduit/features/auth/views/backend_chooser_page.dart';
import 'package:conduit/features/librechat/views/librechat_sso_page.dart';
import 'package:conduit/features/profile/widgets/account_actions.dart'
    show signOutOfLibreChatAndHandOver;
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/features/librechat/models/librechat_account.dart';
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/models/librechat_server_info.dart';
import 'package:conduit_core/features/librechat/models/librechat_session.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/providers/primary_account_providers.dart';
import 'package:conduit_core/providers/openwebui_accounts_controller.dart';
import 'package:conduit_core/providers/storage_providers.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart'
    show InAppWebView;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
        libreChatSsoBase('https://example.com', 'https://example.com/lc/'),
      ).equals(Uri.parse('https://example.com/lc'));
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
