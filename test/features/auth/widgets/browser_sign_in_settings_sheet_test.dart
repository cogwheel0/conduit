import 'package:checks/checks.dart';
import 'package:conduit/features/auth/utils/browser_sign_in_messages.dart';
import 'package:conduit/features/auth/widgets/browser_sign_in_settings_sheet.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/auth/browser_sign_in/browser_sign_in_failure.dart';
import 'package:conduit_core/auth/browser_sign_in/browser_sign_in_service.dart';
import 'package:conduit_core/auth/openwebui_account_summaries.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/browser_sign_in_config.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/ports/browser_auth_port.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/host_ports.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

  testWidgets('starts with the suggested client ID, and needs one', (
    tester,
  ) async {
    final calls = await openSheet(tester);

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('browser-sign-in-client-id')),
        matching: find.text('conduit'),
      ),
      findsOneWidget,
    );
    await enterClientId(tester, '');
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
    expect(find.text('Remove Browser Sign-In?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    check(calls.removed).equals(0);

    await tapKey(tester, 'browser-sign-in-remove');
    await tester.tap(find.text('Remove').last);
    await tester.pumpAndSettle();
    check(calls.removed).equals(1);
    expect(find.byKey(const ValueKey('browser-sign-in-settings')), findsNothing);
  });

  test('the checklist asks for the trusted-client list only where the '
      'provider can be checked against it', () {
    check(browserSignInChecklist('oidc'))
      ..contains(BrowserSignInChecklistItem.trustedClients)
      ..not((c) => c.contains(BrowserSignInChecklistItem.noClientCheck))
      ..not((c) => c.contains(BrowserSignInChecklistItem.microsoft))
      ..not((c) => c.contains(BrowserSignInChecklistItem.google));
    for (final provider in ['google', 'microsoft']) {
      check(browserSignInChecklist(provider))
        ..contains(BrowserSignInChecklistItem.noClientCheck)
        ..not((c) => c.contains(BrowserSignInChecklistItem.trustedClients));
    }
    // Microsoft finds users by email, so it alone warns about merging.
    check(browserSignInChecklist('microsoft'))
        .contains(BrowserSignInChecklistItem.microsoft);
    check(browserSignInChecklist('google'))
      ..contains(BrowserSignInChecklistItem.google)
      ..not((c) => c.contains(BrowserSignInChecklistItem.microsoft));
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

  group('opened from a saved server\'s settings', () {
    const savedConfig = BrowserSignInConfig(
      provider: 'oidc',
      clientId: 'conduit',
    );

    Future<_ServerActions> openFromServerPage(
      WidgetTester tester, {
      BrowserSignInConfig? saved,
      BackendConfig? backend,
    }) async {
      tester.view.physicalSize = const Size(400, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final actions = _ServerActions(backend);
      final entry = OpenWebUiAccountEntry(
        account: OpenWebUiAccount(
          id: 'account-1',
          serverId: 'server-1',
          isActive: true,
        ),
        server: OpenWebUiServer(
          id: 'server-1',
          name: 'Chat',
          endpoints: [
            OpenWebUiEndpoint(
              id: 'endpoint-1',
              url: 'https://chat.example.com',
            ),
          ],
          browserSignIn: saved,
        ),
        summary: const OpenWebUiAccountSummary(),
        isActive: true,
        hasSession: true,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            openWebUiAccountsProvider.overrideWith((ref) async => [entry]),
            serverConfigsProvider.overrideWith(
              (ref) async => const [
                ServerConfig(
                  id: 'account-1',
                  name: 'Chat',
                  url: 'https://chat.example.com',
                ),
              ],
            ),
            authActionsProvider.overrideWithValue(actions),
            browserAuthPortProvider.overrideWithValue(
              const _SupportedBrowser(),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => Center(
                  child: GestureDetector(
                    onTap: () => showServerBrowserSignInSettings(
                      context,
                      ref,
                      serverId: 'server-1',
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return actions;
    }

    testWidgets('keep saved settings removable when the server can\'t be '
        'read', (tester) async {
      final actions = await openFromServerPage(tester, saved: savedConfig);

      expect(find.byKey(const ValueKey('browser-sign-in-settings')), findsOne);
      await tapKey(tester, 'browser-sign-in-remove');
      await tester.tap(find.text('Remove').last);
      await tester.pumpAndSettle();
      check(actions.saved).deepEquals([null]);
    });

    testWidgets('keep saved settings open when the server no longer offers '
        'their provider', (tester) async {
      await openFromServerPage(
        tester,
        saved: savedConfig,
        backend: const BackendConfig(
          oauthProviders: OAuthProviders(github: 'GitHub'),
        ),
      );

      expect(find.byKey(const ValueKey('browser-sign-in-settings')), findsOne);
    });

    testWidgets('say the server can\'t use it when nothing is saved', (
      tester,
    ) async {
      await openFromServerPage(tester);

      expect(
        find.byKey(const ValueKey('browser-sign-in-settings')),
        findsNothing,
      );
      expect(
        find.textContaining("This server can't use browser sign-in"),
        findsOneWidget,
      );
    });
  });
}

final class _SheetCalls {
  final saved = <BrowserSignInConfig>[];
  final tested = <BrowserSignInConfig>[];
  int removed = 0;
}

/// Answers the server page's settings with [backend], and records saves.
final class _ServerActions extends Fake implements AuthActions {
  _ServerActions(this.backend);

  final BackendConfig? backend;
  final saved = <BrowserSignInConfig?>[];

  @override
  Future<BackendConfig?> backendConfigOf(ServerConfig account) async =>
      backend;

  @override
  Future<void> saveBrowserSignInConfig({
    required String accountId,
    BrowserSignInConfig? config,
  }) async => saved.add(config);
}

final class _SupportedBrowser implements BrowserAuthPort {
  const _SupportedBrowser();

  @override
  bool get isSupported => true;

  @override
  Future<BrowserAuthResult> authorize(
    Uri url, {
    required Uri redirectUri,
    bool preferEphemeral = false,
  }) async => const BrowserAuthResult.cancelled();

  @override
  Future<void> cancel() async {}
}
