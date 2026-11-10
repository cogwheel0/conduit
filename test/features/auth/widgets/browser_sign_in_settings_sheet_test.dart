import 'package:checks/checks.dart';
import 'package:conduit/features/auth/utils/browser_sign_in_messages.dart';
import 'package:conduit/features/auth/widgets/browser_sign_in_settings_sheet.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/auth/browser_sign_in/browser_sign_in_failure.dart';
import 'package:conduit_core/auth/browser_sign_in/browser_sign_in_service.dart';
import 'package:conduit_core/models/browser_sign_in_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  const saved = BrowserSignInConfig(provider: 'oidc', clientId: 'conduit-app');

  /// Opens the sheet from a button, as the sign-in page does, recording what
  /// it saves, tests and removes.
  Future<_SheetCalls> openSheet(
    WidgetTester tester, {
    List<String> providers = const ['oidc'],
    BrowserSignInConfig? initial,
    bool removable = false,
    BrowserSignInDiagnosis diagnosis = const BrowserSignInDiagnosis(),
  }) async {
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final calls = _SheetCalls();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: GestureDetector(
                onTap: () => BrowserSignInSettingsSheet.show(
                  context,
                  providers: providers,
                  providerLabel: (provider) => switch (provider) {
                    'google' => 'Google',
                    'microsoft' => 'Microsoft',
                    _ => 'Authentik',
                  },
                  initial: initial,
                  onTest: (config) async {
                    calls.tested.add(config);
                    return diagnosis;
                  },
                  onSave: (config) async => calls.saved.add(config),
                  onRemove: removable ? () async => calls.removed++ : null,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return calls;
  }

  Future<void> enterClientId(WidgetTester tester, String value) async {
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('browser-sign-in-client-id')),
        matching: find.byType(TextField),
      ),
      value,
    );
    await tester.pump();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  testWidgets('saves the provider and client ID, and closes', (tester) async {
    final calls = await openSheet(tester, providers: const ['oidc', 'google']);

    expect(find.byKey(const ValueKey('browser-sign-in-provider')), findsOne);
    expect(
      find.text('These settings apply to every account on this server.'),
      findsOneWidget,
    );
    await enterClientId(tester, '  conduit-app ');
    await tapKey(tester, 'browser-sign-in-save');

    check(calls.saved).deepEquals([saved]);
    expect(find.byKey(const ValueKey('browser-sign-in-settings')), findsNothing);
  });

  testWidgets('needs a client ID', (tester) async {
    final calls = await openSheet(tester);

    await tapKey(tester, 'browser-sign-in-save');

    check(calls.saved).isEmpty();
    expect(find.byKey(const ValueKey('browser-sign-in-settings')), findsOne);
  });

  testWidgets('shows the redirect URI to register, Google\'s from its '
      'client ID', (tester) async {
    await openSheet(tester, providers: const ['oidc', 'google']);

    expect(find.text('conduit://oauth/callback'), findsOneWidget);

    await tester.tap(find.text('Google'));
    await tester.pumpAndSettle();
    expect(find.text('conduit://oauth/callback'), findsNothing);
    expect(find.byKey(const ValueKey('browser-sign-in-google-hint')), findsOne);

    await enterClientId(tester, '1234-abc.apps.googleusercontent.com');
    expect(
      find.text('com.googleusercontent.apps.1234-abc:/oauth2redirect'),
      findsOneWidget,
    );
  });

  testWidgets('Test reports what it found', (tester) async {
    final calls = await openSheet(
      tester,
      initial: saved,
      diagnosis: const BrowserSignInDiagnosis(issuer: 'https://id.example.com'),
    );

    await tapKey(tester, 'browser-sign-in-test');

    check(calls.tested).deepEquals([saved]);
    expect(find.text('Found https://id.example.com'), findsOneWidget);
    expect(find.text('Turned on'), findsOneWidget);
  });

  testWidgets('Test reveals the issuer field when the identity provider was '
      'not found', (tester) async {
    await openSheet(
      tester,
      initial: saved,
      diagnosis: const BrowserSignInDiagnosis(
        discoveryFailure: BrowserSignInFailure.discoveryNotFound,
        exchangeFailure: BrowserSignInFailure.exchangeDisabled,
      ),
    );
    expect(find.byKey(const ValueKey('browser-sign-in-advanced')), findsOne);

    await tapKey(tester, 'browser-sign-in-test');

    expect(find.byKey(const ValueKey('browser-sign-in-advanced')), findsNothing);
    expect(find.byKey(const ValueKey('browser-sign-in-issuer')), findsOne);
    expect(find.textContaining('ENABLE_OAUTH_TOKEN_EXCHANGE'), findsWidgets);
  });

  testWidgets('saves an issuer typed by hand, and refuses one that is not '
      'https', (tester) async {
    final calls = await openSheet(
      tester,
      initial: const BrowserSignInConfig(
        provider: 'oidc',
        clientId: 'conduit-app',
        issuer: 'http://id.example.com',
      ),
    );

    await tapKey(tester, 'browser-sign-in-save');
    check(calls.saved).isEmpty();

    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('browser-sign-in-issuer')),
        matching: find.byType(TextField),
      ),
      'https://id.example.com/application/o/conduit/',
    );
    await tester.pump();
    await tapKey(tester, 'browser-sign-in-save');

    check(calls.saved).deepEquals([
      const BrowserSignInConfig(
        provider: 'oidc',
        clientId: 'conduit-app',
        issuer: 'https://id.example.com/application/o/conduit/',
      ),
    ]);
  });

  testWidgets('Remove asks first', (tester) async {
    final calls = await openSheet(tester, initial: saved, removable: true);

    await tapKey(tester, 'browser-sign-in-remove');
    expect(find.text('Remove browser sign-in?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    check(calls.removed).equals(0);

    await tapKey(tester, 'browser-sign-in-remove');
    await tester.tap(find.text('Remove').last);
    await tester.pumpAndSettle();
    check(calls.removed).equals(1);
    expect(find.byKey(const ValueKey('browser-sign-in-settings')), findsNothing);
  });

  group('the checklist', () {
    Finder inChecklist(String text) => find.descendant(
      of: find.byKey(const ValueKey('browser-sign-in-checklist')),
      matching: find.textContaining(text),
    );

    testWidgets('asks to limit token exchange to this client', (tester) async {
      await openSheet(tester, initial: saved);

      expect(inChecklist('OAUTH_TOKEN_EXCHANGE_TRUSTED_CLIENT_IDS'), findsOne);
      expect(inChecklist('has no token introspection'), findsNothing);
    });

    for (final provider in ['google', 'microsoft']) {
      testWidgets('says why $provider tokens from any app are accepted', (
        tester,
      ) async {
        await openSheet(
          tester,
          providers: [provider],
          initial: BrowserSignInConfig(provider: provider, clientId: 'app'),
        );

        expect(inChecklist('has no token introspection'), findsOne);
        expect(
          inChecklist('OAUTH_TOKEN_EXCHANGE_TRUSTED_CLIENT_IDS'),
          findsNothing,
        );
      });
    }

    testWidgets('warns that merging by email covers every provider', (
      tester,
    ) async {
      await openSheet(
        tester,
        providers: const ['microsoft'],
        initial: const BrowserSignInConfig(
          provider: 'microsoft',
          clientId: 'app',
        ),
      );

      expect(inChecklist('verifies email addresses'), findsOne);
    });
  });

  test('every failure the user should hear about has a message', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    for (final failure in BrowserSignInFailure.values) {
      final message = browserSignInFailureMessage(l10n, failure);
      if (failure.isSilent) {
        check(message).isNull();
      } else {
        check(message).isNotNull().isNotEmpty();
      }
    }
  });
}

final class _SheetCalls {
  final saved = <BrowserSignInConfig>[];
  final tested = <BrowserSignInConfig>[];
  int removed = 0;
}
