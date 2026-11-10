import 'package:checks/checks.dart';
import 'package:conduit/features/auth/widgets/auth_grouped_form.dart';
import 'package:conduit/features/librechat/views/librechat_account_form.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
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
    TargetPlatform platform = TargetPlatform.android,
  }) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    if (platform == TargetPlatform.iOS) {
      // The Flutter fallbacks of the native iOS 26 controls render in tests.
      PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
      PlatformUiCapabilities.debugIOSMajorVersionOverride = 18;
      addTearDown(PlatformUiCapabilities.resetDebugOverrides);
    }
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStorageProvider.overrideWithValue(
            storage ?? InMemorySecureKeyValueStore(),
          ),
          libreChatHttpAdapterProvider.overrideWithValue(fake),
        ],
        child: MaterialApp(
          theme: ThemeData(platform: platform),
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

  /// Types into a field and lets the step's action follow: it waits for
  /// what it needs to be typed.
  Future<void> type(WidgetTester tester, String key, String text) async {
    await tester.enterText(
      find.descendant(
        of: find.byKey(Key(key)),
        matching: find.byType(EditableText),
      ),
      text,
    );
    await tester.pump();
  }

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

  testWidgets('Continue waits for an address', (tester) async {
    await pumpForm(tester);
    ConduitButton continueButton() => tester.widget<ConduitButton>(
      find.byKey(const Key('librechat-continue')),
    );
    check(continueButton().onPressed).isNull();
    await type(tester, 'librechat-server-field', 'chat.example.com');
    check(continueButton().onPressed).isNotNull();
  });

  /// On iOS the steps are the Open WebUI server and sign-in steps' grouped
  /// form: labelled rows, footers that guide and carry errors, the server as
  /// a row with Change, and a glass action that waits for what it needs.
  group('on iOS', () {
    AuthPrimaryButton action(WidgetTester tester) =>
        tester.widget<AuthPrimaryButton>(find.byType(AuthPrimaryButton));

    AuthGroupedTextField field(WidgetTester tester, String key) =>
        tester.widget<AuthGroupedTextField>(find.byKey(Key(key)));

    Finder inSection(String section, String text) => find.descendant(
      of: find.byKey(Key(section)),
      matching: find.text(text),
    );

    Future<void> signInStep(WidgetTester tester) async {
      await pumpForm(tester, platform: TargetPlatform.iOS);
      await probe(tester);
    }

    Future<void> enterPassword(WidgetTester tester, String password) async {
      await type(tester, 'librechat-email-field', 'dev@example.com');
      await type(tester, 'librechat-password-field', password);
      await tapKey(tester, 'librechat-sign-in');
    }

    testWidgets('the address is a labelled row with a footer, and Connect '
        'waits for it', (tester) async {
      await pumpForm(tester, platform: TargetPlatform.iOS);

      // No web-form label under an intro sentence.
      expect(find.text('Server Address'), findsNothing);
      expect(
        find.text('Enter the address of your LibreChat server.'),
        findsNothing,
      );
      final server = field(tester, 'librechat-server-field');
      check(server.label).equals('Server');
      check(server.placeholder).equals('https://chat.example.com');
      check(server.keyboardType).equals(TextInputType.url);
      check(server.textInputAction).equals(TextInputAction.go);
      // Not by default: in the account sheet a hidden tab's field would
      // take the keyboard.
      check(server.autofocus).isFalse();
      expect(
        inSection(
          'librechat-server-section',
          'Use the address you open in a web browser.',
        ),
        findsOneWidget,
      );

      check(action(tester).label).equals('Connect');
      check(action(tester).onPressed).isNull();
      await type(tester, 'librechat-server-field', 'chat.example.com');
      check(action(tester).onPressed).isNotNull();

      // Go on the keyboard connects, as Connect does.
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('librechat-email-field')), findsOneWidget);
    });

    testWidgets('a server that is not LibreChat is said in the footer\'s '
        'place', (tester) async {
      fake.on(
        'GET',
        '/api/config',
        (request, match) => FakeLibreChatResponse.json({'hello': 'world'}),
      );
      await signInStep(tester);
      expect(
        inSection(
          'librechat-server-section',
          "This server isn't LibreChat. Check the address.",
        ),
        findsOneWidget,
      );
      expect(
        find.text('Use the address you open in a web browser.'),
        findsNothing,
      );
      // Not also the Material line under the form.
      expect(find.byKey(const Key('librechat-form-issue')), findsNothing);
    });

    testWidgets('sign-in shows the server as a row with Change, labelled '
        'fields and Continue', (tester) async {
      fake.addUser();
      await signInStep(tester);

      final row = find.byKey(const Key('librechat-server-row'));
      for (final text in ['chat.example.com', 'LibreChat', 'Change']) {
        expect(
          find.descendant(of: row, matching: find.text(text)),
          findsOneWidget,
        );
      }
      final email = field(tester, 'librechat-email-field');
      final password = field(tester, 'librechat-password-field');
      check(email.label).equals('Email');
      check(email.placeholder).equals('name@example.com');
      check(email.textInputAction).equals(TextInputAction.next);
      check(password.label).equals('Password');
      check(password.placeholder).equals('Required');
      check(password.textInputAction).equals(TextInputAction.go);
      check(password.obscureText).isTrue();

      // The step takes the keyboard at its first field; Next moves on.
      check(email.focusNode!.hasFocus).isTrue();
      check(action(tester).label).equals('Continue');
      check(action(tester).onPressed).isNull();
      await type(tester, 'librechat-email-field', 'dev@example.com');
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pump();
      check(password.focusNode!.hasFocus).isTrue();
      check(action(tester).onPressed).isNull();

      await tester.tap(
        find.byKey(const Key('librechat-password-visibility')),
      );
      await tester.pump();
      check(field(tester, 'librechat-password-field').obscureText).isFalse();

      await type(tester, 'librechat-password-field', 'devpassword');
      check(action(tester).onPressed).isNotNull();
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();
      check(signedIn).length.equals(1);
    });

    testWidgets('a wrong password is said in the fields\' footer', (
      tester,
    ) async {
      fake.addUser();
      await signInStep(tester);
      await enterPassword(tester, 'nope');
      check(signedIn).isEmpty();
      expect(
        inSection('librechat-password-section', 'Incorrect password.'),
        findsOneWidget,
      );
    });

    testWidgets('two-step verification keeps the server row and asks in a '
        'group of its own', (tester) async {
      fake.addUser(totpCode: '123456', backupCodes: ['backup-1']);
      await signInStep(tester);
      await enterPassword(tester, 'devpassword');

      expect(find.byKey(const Key('librechat-server-row')), findsOneWidget);
      expect(
        inSection('librechat-code-section', 'Verify Your Sign-In'),
        findsOneWidget,
      );
      expect(
        inSection(
          'librechat-code-section',
          'Enter the six-digit code from your authenticator app.',
        ),
        findsOneWidget,
      );
      final code = field(tester, 'librechat-code-field');
      check(code.placeholder).equals('Authenticator Code');
      check(code.keyboardType).equals(TextInputType.number);
      check(code.focusNode!.hasFocus).isTrue();
      check(action(tester).onPressed).isNull();

      await type(tester, 'librechat-code-field', '000000');
      await tapKey(tester, 'librechat-verify');
      expect(
        inSection(
          'librechat-code-section',
          "That code didn't work. Check it and try again.",
        ),
        findsOneWidget,
      );

      await tapKey(tester, 'librechat-toggle-backup');
      check(
        field(tester, 'librechat-code-field').placeholder,
      ).equals('Recovery Code');
      await type(tester, 'librechat-code-field', 'backup-1');
      await tapKey(tester, 'librechat-verify');
      check(signedIn).length.equals(1);
    });

    testWidgets('Change goes back to the address from two-step verification, '
        'keeping nothing typed for that server', (tester) async {
      fake.addUser(totpCode: '123456');
      await signInStep(tester);
      await enterPassword(tester, 'devpassword');
      expect(find.byKey(const Key('librechat-code-field')), findsOneWidget);

      await tapKey(tester, 'librechat-change-server');
      check(
        field(tester, 'librechat-server-field').focusNode!.hasFocus,
      ).isTrue();
      await probe(tester);
      check(
        tester
            .widget<EditableText>(
              find.descendant(
                of: find.byKey(const Key('librechat-email-field')),
                matching: find.byType(EditableText),
              ),
            )
            .controller
            .text,
      ).isEmpty();
    });

    testWidgets('single sign-on is a group of rows, whose footer says when '
        'it is the only way', (tester) async {
      fake.startupConfig = {
        ...fake.startupConfig,
        'emailLoginEnabled': false,
        'socialLoginEnabled': true,
        'socialLogins': ['openid', 'google'],
        'openidLoginEnabled': true,
        'openidLabel': 'Company SSO',
        'googleLoginEnabled': true,
      };
      await signInStep(tester);

      expect(find.byKey(const Key('librechat-email-field')), findsNothing);
      // No password, so no Continue: the rows are the actions.
      expect(find.byType(AuthPrimaryButton), findsNothing);
      final openid = tester.widget<AuthGroupedRow>(
        find.byKey(const Key('librechat-sso-openid')),
      );
      check(openid.title).equals('Company SSO');
      check(openid.showChevron).isTrue();
      check(
        tester
            .widget<AuthGroupedRow>(
              find.byKey(const Key('librechat-sso-google')),
            )
            .title,
      ).equals('Continue with Google');
      expect(
        inSection(
          'librechat-sso-section',
          'This server only allows single sign-on.',
        ),
        findsOneWidget,
      );

      await tapKey(tester, 'librechat-sso-google');
      expect(
        inSection(
          'librechat-sso-section',
          "Google doesn't allow signing in inside apps. Use another way to "
              'sign in.',
        ),
        findsOneWidget,
      );
    });
  });
}

/// Secure storage whose writes fail, as a locked keychain's can.
final class _FailingWrites extends InMemorySecureKeyValueStore {
  @override
  Future<void> write({required String key, required String? value}) =>
      Future.error(StateError('secure storage unavailable'));
}
