import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:checks/checks.dart';
import 'package:conduit/core/models/backend_config.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/auth/webview_cookie_helper.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/navigation_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/auth/views/authentication_page.dart';
import 'package:conduit/features/profile/widgets/adaptive_segmented_selector.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/adaptive_auth_harness.dart';

void main() {
  const server = ServerConfig(
    id: 'server-1',
    name: 'Open WebUI',
    url: 'https://open-webui.example',
    isActive: true,
  );

  test(
    'authentication server ownership requires the full tokenless transport identity',
    () {
      const expected = ServerConfig(
        id: 'server-1',
        name: 'Open WebUI',
        url: 'https://open-webui.example',
        apiKey: 'legacy-token-that-selection-must-strip',
        customHeaders: {'Cookie': 'proxy=session'},
        isActive: true,
        allowSelfSignedCertificates: true,
        mtlsCertificateChainPem: 'certificate',
        mtlsPrivateKeyPem: 'private-key',
        mtlsPrivateKeyPassword: 'passphrase',
      );
      final selected = expected.copyWith(
        url: 'https://OPEN-WEBUI.example/',
        apiKey: null,
      );

      check(authenticationServerMatchesSelection(selected, expected)).isTrue();
      for (final mismatched in <ServerConfig>[
        selected.copyWith(id: 'replacement-id'),
        selected.copyWith(url: 'https://replacement.example'),
        selected.copyWith(apiKey: 'stale-bearer'),
        selected.copyWith(customHeaders: const {'Cookie': 'proxy=other'}),
        selected.copyWith(allowSelfSignedCertificates: false),
        selected.copyWith(mtlsCertificateChainPem: 'other-certificate'),
        selected.copyWith(mtlsPrivateKeyPem: 'other-private-key'),
        selected.copyWith(mtlsPrivateKeyPassword: 'other-passphrase'),
      ]) {
        check(
          authenticationServerMatchesSelection(mismatched, expected),
        ).isFalse();
      }
      check(authenticationServerMatchesSelection(null, expected)).isFalse();

      final workerManager = WorkerManager();
      final api = ApiService(
        serverConfig: selected,
        workerManager: workerManager,
      );
      addTearDown(api.dispose);
      addTearDown(workerManager.dispose);
      check(authenticationApiMatchesSelection(api, expected)).isTrue();

      api.updateAuthToken('prior-session-bearer');
      check(authenticationApiMatchesSelection(api, expected)).isFalse();
    },
  );

  for (final platform in <TargetPlatform>[
    TargetPlatform.iOS,
    TargetPlatform.android,
  ]) {
    testWidgets('sign-in uses segmented auth methods on ${platform.name}', (
      tester,
    ) async {
      PlatformUiCapabilities.debugPlatformOverride = platform;
      PlatformUiCapabilities.debugIOSMajorVersionOverride = 18;
      debugIsWebViewSupportedOverride = true;
      addTearDown(() {
        PlatformUiCapabilities.resetDebugOverrides();
        debugIsWebViewSupportedOverride = null;
      });
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final harness = AdaptiveAuthHarness(
        server: server,
        platform: platform,
        backendConfig: const BackendConfig(
          oauthProviders: OAuthProviders(google: 'Google'),
          enableLdap: true,
        ),
      );
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        harness.build(initialLocation: Routes.authentication),
      );
      await tester.pumpAndSettle();

      final selectorFinder = find.byKey(
        const ValueKey<String>('authentication-mode-selector'),
      );
      expect(selectorFinder, findsOneWidget);
      final adaptiveSelector = tester.widget<AdaptiveSegmentedControl>(
        find.descendant(
          of: selectorFinder,
          matching: find.byType(AdaptiveSegmentedControl),
        ),
      );
      check(
        adaptiveSelector.labels,
      ).deepEquals(['Password', 'SSO', 'LDAP', 'Token']);
      for (final field in tester.widgetList<AccessibleFormField>(
        find.byType(AccessibleFormField),
      )) {
        check(field.prefixIcon).isNull();
      }
      expect(find.byIcon(Icons.hub), findsNothing);
      expect(find.byIcon(Icons.hub_outlined), findsNothing);
      expect(
        find.image(const AssetImage('assets/icons/icon.png')),
        findsNothing,
      );

      if (platform == TargetPlatform.iOS) {
        expect(
          find.byType(CupertinoSlidingSegmentedControl<int>),
          findsOneWidget,
        );
        expect(find.byType(SegmentedButton<int>), findsNothing);
      } else {
        expect(find.byType(SegmentedButton<int>), findsOneWidget);
        expect(
          find.byType(CupertinoSlidingSegmentedControl<int>),
          findsNothing,
        );
      }

      await tester.tap(
        find.descendant(of: selectorFinder, matching: find.text('Password')),
      );
      await tester.pump();
      final renderedField = tester.widget<AdaptiveTextFormField>(
        find.byType(AdaptiveTextFormField).first,
      );
      check(renderedField.cupertinoDecoration).isNotNull();
      check(renderedField.cupertinoDecoration!.border).isNull();

      await tester.tap(
        find.descendant(of: selectorFinder, matching: find.text('Token')),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('api_key_form')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await harness.unmount(tester);
    });

    testWidgets(
      'adaptive selector handles a missing value on ${platform.name}',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: Scaffold(
              body: AdaptiveSegmentedSelector<int>(
                value: 3,
                showIcons: false,
                onChanged: (_) {},
                options: const [
                  (
                    value: 1,
                    label: 'One',
                    cupertinoIcon: CupertinoIcons.circle,
                    materialIcon: Icons.circle_outlined,
                    enabled: true,
                  ),
                  (
                    value: 2,
                    label: 'Two',
                    cupertinoIcon: CupertinoIcons.circle,
                    materialIcon: Icons.circle_outlined,
                    enabled: true,
                  ),
                ],
              ),
            ),
          ),
        );

        if (platform == TargetPlatform.iOS) {
          final selector = tester.widget<CupertinoSlidingSegmentedControl<int>>(
            find.byType(CupertinoSlidingSegmentedControl<int>),
          );
          check(selector.groupValue).isNull();
        } else {
          final selector = tester.widget<SegmentedButton<int>>(
            find.byType(SegmentedButton<int>),
          );
          check(selector.selected).isEmpty();
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('sign-in hides unavailable methods', (tester) async {
    debugIsWebViewSupportedOverride = false;
    addTearDown(() => debugIsWebViewSupportedOverride = null);
    final harness = AdaptiveAuthHarness(
      server: server,
      backendConfig: const BackendConfig(
        enableLoginForm: false,
        enableLdap: true,
        oauthProviders: OAuthProviders(google: 'Google'),
      ),
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.build(initialLocation: Routes.authentication),
    );
    await tester.pumpAndSettle();

    final selector = tester.widget<AdaptiveSegmentedControl>(
      find.byType(AdaptiveSegmentedControl),
    );
    check(selector.labels).deepEquals(['LDAP', 'Token']);
    expect(find.byKey(const ValueKey('ldap_form')), findsOneWidget);

    await harness.unmount(tester);
  });

  testWidgets('sign-in keeps SSO available when backend config is absent', (
    tester,
  ) async {
    debugIsWebViewSupportedOverride = true;
    addTearDown(() => debugIsWebViewSupportedOverride = null);
    final harness = AdaptiveAuthHarness(server: server, backendConfig: null);
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.build(initialLocation: Routes.authentication),
    );
    await tester.pumpAndSettle();

    final selector = tester.widget<AdaptiveSegmentedControl>(
      find.byType(AdaptiveSegmentedControl),
    );
    check(selector.labels).deepEquals(['Password', 'SSO', 'Token']);

    await harness.unmount(tester);
  });

  for (final platform in <TargetPlatform>[
    TargetPlatform.iOS,
    TargetPlatform.android,
  ]) {
    testWidgets(
      'four auth segments fit a 320px viewport at 2x text on ${platform.name}',
      (tester) async {
        PlatformUiCapabilities.debugPlatformOverride = platform;
        PlatformUiCapabilities.debugIOSMajorVersionOverride = 18;
        debugIsWebViewSupportedOverride = true;
        addTearDown(() {
          PlatformUiCapabilities.resetDebugOverrides();
          debugIsWebViewSupportedOverride = null;
        });
        tester.view.physicalSize = const Size(320, 812);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final harness = AdaptiveAuthHarness(
          server: server,
          platform: platform,
          textScaler: const TextScaler.linear(2),
          backendConfig: const BackendConfig(
            oauthProviders: OAuthProviders(google: 'Google'),
            enableLdap: true,
          ),
        );
        addTearDown(harness.dispose);

        await tester.pumpWidget(
          harness.build(initialLocation: Routes.authentication),
        );
        await tester.pumpAndSettle();

        expect(find.byType(AdaptiveSegmentedControl), findsOneWidget);
        expect(tester.takeException(), isNull);
        await harness.unmount(tester);
      },
    );
  }

  testWidgets('sign-in omits selector when only JWT is available', (
    tester,
  ) async {
    debugIsWebViewSupportedOverride = false;
    addTearDown(() => debugIsWebViewSupportedOverride = null);
    final harness = AdaptiveAuthHarness(
      server: server,
      backendConfig: const BackendConfig(enableLoginForm: false),
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.build(initialLocation: Routes.authentication),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('authentication-mode-selector')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('api_key_form')), findsOneWidget);
    expect(find.text('Token'), findsOneWidget);

    await harness.unmount(tester);
  });

  testWidgets('sign-in displays a sanitized Open WebUI address', (
    tester,
  ) async {
    const serverWithSecrets = ServerConfig(
      id: 'server-with-secrets',
      name: 'Open WebUI',
      url:
          'https://user:password@example.com:8443/openwebui?token=secret#private',
      isActive: true,
    );
    final harness = AdaptiveAuthHarness(server: serverWithSecrets);
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.build(initialLocation: Routes.authentication),
    );
    await tester.pumpAndSettle();

    expect(find.text('https://example.com:8443/openwebui'), findsOneWidget);
    expect(find.text(serverWithSecrets.url), findsNothing);
    expect(find.textContaining('user:'), findsNothing);
    expect(find.textContaining('token='), findsNothing);
    expect(find.textContaining('#private'), findsNothing);

    await harness.unmount(tester);
  });

  testWidgets('sign-in hides unsupported saved server addresses', (
    tester,
  ) async {
    const unsupportedServer = ServerConfig(
      id: 'unsupported-server',
      name: 'Legacy server',
      url: 'ftp://user:password@example.com/private?token=secret',
      isActive: true,
    );
    final harness = AdaptiveAuthHarness(server: unsupportedServer);
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.build(initialLocation: Routes.authentication),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Server address unavailable'), findsOneWidget);
    expect(find.textContaining('ftp://'), findsNothing);
    expect(find.textContaining('user:'), findsNothing);
    expect(find.textContaining('token='), findsNothing);

    await harness.unmount(tester);
  });
}
