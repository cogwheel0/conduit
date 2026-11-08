import 'package:checks/checks.dart';
import 'package:conduit/features/librechat/views/librechat_account_form.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/features/librechat/models/librechat_account.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/providers/storage_providers.dart';
import 'package:conduit_core/testing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  late FakeLibreChatServer fake;
  late List<LibreChatAccount> signedIn;

  setUp(() {
    addTearDown(PreferencesStore.debugReset);
    PreferencesStore.debugOverride(InMemoryKeyValueStore());
    fake = FakeLibreChatServer();
    signedIn = <LibreChatAccount>[];
  });

  Future<ProviderContainer> pumpForm(
    WidgetTester tester, {
    SecureKeyValueStore? storage,
    Future<void> Function(LibreChatAccount account)? onSignedIn,
  }) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStorageProvider.overrideWithValue(
            storage ?? InMemorySecureKeyValueStore(),
          ),
          libreChatHttpAdapterProvider.overrideWithValue(fake),
        ],
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: LibreChatAccountForm(
                onSignedIn:
                    onSignedIn ?? (account) async => signedIn.add(account),
              ),
            ),
          ),
        ),
      ),
    );
    return ProviderScope.containerOf(
      tester.element(find.byType(LibreChatAccountForm)),
    );
  }

  Future<void> type(WidgetTester tester, String key, String text) =>
      tester.enterText(
        find.descendant(
          of: find.byKey(Key(key)),
          matching: find.byType(EditableText),
        ),
        text,
      );

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  Future<void> probe(WidgetTester tester) async {
    await type(tester, 'librechat-server-field', 'chat.example.com');
    await tapKey(tester, 'librechat-continue');
  }

  String? issue(WidgetTester tester) {
    final finder = find.byKey(const Key('librechat-form-issue'));
    return finder.evaluate().isEmpty
        ? null
        : tester.widget<Text>(finder).data;
  }

  testWidgets('signs in with a password and saves the account', (
    tester,
  ) async {
    fake.addUser();
    final container = await pumpForm(tester);
    await probe(tester);
    check(
      find.byKey(const Key('librechat-email-field')).evaluate(),
    ).isNotEmpty();

    await type(tester, 'librechat-email-field', 'dev@example.com');
    await type(tester, 'librechat-password-field', 'devpassword');
    await tapKey(tester, 'librechat-sign-in');

    check(signedIn).length.equals(1);
    check(signedIn.single.email).equals('dev@example.com');
    final registry = await container.read(libreChatRegistryProvider.future);
    check(registry.byId(signedIn.single.id)).isNotNull();
    // Saved, not yet in use: the switch the form hands it to puts it in
    // use, asking first when that would stop a reply.
    check(registry.activeId).isNull();
  });

  testWidgets('a sign-in that cannot be saved says so', (tester) async {
    fake.addUser();
    await pumpForm(tester, storage: _FailingWrites());
    await probe(tester);
    await type(tester, 'librechat-email-field', 'dev@example.com');
    await type(tester, 'librechat-password-field', 'devpassword');
    await tapKey(tester, 'librechat-sign-in');
    check(signedIn).isEmpty();
    final l10n = lookupAppLocalizations(const Locale('en'));
    check(issue(tester)).equals(l10n.errorMessage);
  });

  testWidgets('an account that cannot be put in use says so', (
    tester,
  ) async {
    fake.addUser();
    await pumpForm(
      tester,
      onSignedIn: (_) async => throw StateError('switch failed'),
    );
    await probe(tester);
    await type(tester, 'librechat-email-field', 'dev@example.com');
    await type(tester, 'librechat-password-field', 'devpassword');
    await tapKey(tester, 'librechat-sign-in');
    final l10n = lookupAppLocalizations(const Locale('en'));
    check(issue(tester)).equals(l10n.errorMessage);
  });

  testWidgets('an address and code are sent without spaces around them', (
    tester,
  ) async {
    fake.addUser(totpCode: '123456');
    await pumpForm(tester);
    await probe(tester);
    // As autofill and paste can leave them; the sign-in service trims both.
    await type(tester, 'librechat-email-field', ' dev@example.com ');
    await type(tester, 'librechat-password-field', 'devpassword');
    await tapKey(tester, 'librechat-sign-in');
    await type(tester, 'librechat-code-field', '123456 ');
    await tapKey(tester, 'librechat-verify');
    check(signedIn).length.equals(1);
  });

  testWidgets('another server starts with nothing typed for the last one', (
    tester,
  ) async {
    fake.addUser();
    await pumpForm(tester);
    await probe(tester);
    await type(tester, 'librechat-email-field', 'dev@example.com');
    await type(tester, 'librechat-password-field', 'devpassword');
    await tapKey(tester, 'librechat-change-server');
    await probe(tester);

    String typed(String key) => tester
        .widget<EditableText>(
          find.descendant(
            of: find.byKey(Key(key)),
            matching: find.byType(EditableText),
          ),
        )
        .controller
        .text;
    check(typed('librechat-email-field')).isEmpty();
    check(typed('librechat-password-field')).isEmpty();
  });

  testWidgets('passes on a wrong password in the server\'s words', (
    tester,
  ) async {
    fake.addUser();
    await pumpForm(tester);
    await probe(tester);
    await type(tester, 'librechat-email-field', 'dev@example.com');
    await type(tester, 'librechat-password-field', 'nope');
    await tapKey(tester, 'librechat-sign-in');
    check(signedIn).isEmpty();
    check(issue(tester)).equals('Incorrect password.');
  });

  testWidgets('two-step verification by code, then by backup code', (
    tester,
  ) async {
    fake.addUser(totpCode: '123456', backupCodes: ['backup-1']);
    await pumpForm(tester);
    await probe(tester);
    await type(tester, 'librechat-email-field', 'dev@example.com');
    await type(tester, 'librechat-password-field', 'devpassword');
    await tapKey(tester, 'librechat-sign-in');
    check(find.byKey(const Key('librechat-code-field')).evaluate()).isNotEmpty();

    await type(tester, 'librechat-code-field', '000000');
    await tapKey(tester, 'librechat-verify');
    check(signedIn).isEmpty();
    check(issue(tester)).equals(
      "That code didn't work. Check it and try again.",
    );

    await tapKey(tester, 'librechat-toggle-backup');
    await type(tester, 'librechat-code-field', 'backup-1');
    await tapKey(tester, 'librechat-verify');
    check(signedIn).length.equals(1);
  });

  testWidgets('Google is refused before a web view opens', (tester) async {
    fake.startupConfig = {
      ...fake.startupConfig,
      'socialLoginEnabled': true,
      'socialLogins': ['google'],
      'googleLoginEnabled': true,
    };
    await pumpForm(tester);
    await probe(tester);
    await tapKey(tester, 'librechat-sso-google');
    check(issue(tester)).equals(
      "Google doesn't allow signing in inside apps. Use another way to sign in.",
    );
  });

  testWidgets('a server that offers only single sign-on says so', (
    tester,
  ) async {
    fake.startupConfig = {
      ...fake.startupConfig,
      'emailLoginEnabled': false,
      'socialLoginEnabled': true,
      'socialLogins': ['openid'],
      'openidLoginEnabled': true,
      'openidLabel': 'Company SSO',
    };
    await pumpForm(tester);
    await probe(tester);
    check(find.byKey(const Key('librechat-email-field')).evaluate()).isEmpty();
    expect(find.text('This server only allows single sign-on.'), findsOneWidget);
    expect(find.text('Company SSO'), findsOneWidget);
  });

  testWidgets('another kind of server is named', (tester) async {
    fake.on(
      'GET',
      '/api/config',
      (request, match) => FakeLibreChatResponse.json({
        'status': true,
        'name': 'Open WebUI',
        'version': '0.12.3',
        'features': <String, Object>{},
      }),
    );
    await pumpForm(tester);
    await probe(tester);
    check(issue(tester)).equals(
      'This is an Open WebUI server. Add it on the Open WebUI tab.',
    );

    fake.on(
      'GET',
      '/api/config',
      (request, match) => FakeLibreChatResponse.json({'hello': 'world'}),
    );
    await tapKey(tester, 'librechat-continue');
    check(issue(tester)).equals(
      "This server isn't LibreChat. Check the address.",
    );
  });

  testWidgets('a malformed address never reaches the network', (
    tester,
  ) async {
    await pumpForm(tester);
    await type(tester, 'librechat-server-field', 'ftp://chat.example.com');
    await tapKey(tester, 'librechat-continue');
    check(issue(tester)).equals(
      'Enter a server address, like chat.example.com.',
    );
    check(fake.requests).isEmpty();
  });
}

/// Secure storage whose writes fail, as a locked keychain's can.
final class _FailingWrites extends InMemorySecureKeyValueStore {
  @override
  Future<void> write({required String key, required String? value}) =>
      Future.error(StateError('secure storage unavailable'));
}
