import 'package:checks/checks.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit/shared/services/navigation_service.dart';
import 'package:conduit/features/auth/views/backend_chooser_page.dart';
import 'package:conduit/features/auth/views/server_connection_page.dart';
import 'package:conduit/features/auth/views/authentication_page.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/utility_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/adaptive_auth_harness.dart';

const _server = ServerConfig(
  id: 'server-1',
  name: 'Open WebUI',
  url: 'https://open-webui.example',
  isActive: true,
);

void main() {
  testWidgets(
    'post-logout sign-in flow can return from server setup to backend chooser',
    (tester) async {
      final harness = AdaptiveAuthHarness(server: _server);
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        harness.build(initialLocation: Routes.authentication),
      );
      await tester.pumpAndSettle();

      check(harness.router.routeInformationProvider.value.uri.path)
          .equals(Routes.authentication);
      check(harness.router.canPop()).isFalse();

      await tester.tap(
        find.byKey(const ValueKey<String>('authentication-back-button')),
      );
      await tester.pumpAndSettle();

      check(harness.router.routeInformationProvider.value.uri.path)
          .equals(Routes.serverConnection);
      check(harness.router.canPop()).isFalse();
      expect(
        find.byKey(const ValueKey<String>('server-connection-back-button')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('server-connection-back-button')),
      );
      await tester.pumpAndSettle();

      check(harness.router.routeInformationProvider.value.uri.path)
          .equals(Routes.backendChooser);
      expect(find.byType(BackendChooserPage), findsOneWidget);
      await harness.unmount(tester);
    },
  );

  testWidgets(
    'server setup returns to chat when a local backend already works',
    (tester) async {
      // Adding Open WebUI from settings next to a working Apple, Direct, or
      // Hermes backend must not strand the user in first-time onboarding.
      final harness = AdaptiveAuthHarness(
        server: _server,
        accountlessBackendUsable: true,
      );
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        harness.build(initialLocation: Routes.serverConnection),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('server-connection-back-button')),
      );
      await tester.pumpAndSettle();

      check(harness.router.routeInformationProvider.value.uri.path)
          .equals(Routes.chat);
      expect(find.byKey(const ValueKey<String>('chat')), findsOneWidget);
      await harness.unmount(tester);
    },
  );

  // Nothing awaited the read, so its failure reached only the zone and the
  // form sat empty without a word.
  testWidgets('adding an account says when the saved server cannot be read', (
    tester,
  ) async {
    final harness = AdaptiveAuthHarness(
      server: _server,
      savedServersError: Exception('The keychain is locked.'),
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build(initialLocation: Routes.chat));
    await tester.pumpAndSettle();
    harness.router.goNamed(RouteNames.addServer, extra: _server.id);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.text('Something went wrong. Please try again.'),
      findsOneWidget,
    );
    // Leave first: the page ends the addition after it goes, which needs the
    // providers still there.
    harness.router.go(Routes.chat);
    await tester.pumpAndSettle();
    await harness.unmount(tester);
  });

  // The account sheet checks a server itself, and hands it on: the page it
  // opens goes straight to that server's sign-in.
  testWidgets('a server the account sheet checked goes on to its sign-in', (
    tester,
  ) async {
    final harness = AdaptiveAuthHarness(server: _server);
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build(initialLocation: Routes.chat));
    await tester.pumpAndSettle();
    harness.router.goNamed(
      RouteNames.addServer,
      extra: const ServerConnectionHandoff(
        config: _server,
        authFlow: AuthFlowConfig(serverConfig: _server),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AuthenticationPage), findsOneWidget);
    // Back from sign-in finds the address it was checked at.
    harness.router.pop();
    await tester.pumpAndSettle();
    expect(find.text(_server.url), findsOneWidget);
    harness.router.go(Routes.chat);
    await tester.pumpAndSettle();
    await harness.unmount(tester);
  });

  // The sheet named a saved server the page could not read: it connected
  // anyway, with no address, and asked for one over the reason.
  testWidgets('a saved server the sheet named but cannot be read says so, '
      'and asks for no address', (tester) async {
    final harness = AdaptiveAuthHarness(
      server: _server,
      savedServersError: Exception('The keychain is locked.'),
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build(initialLocation: Routes.chat));
    await tester.pumpAndSettle();
    harness.router.goNamed(
      RouteNames.addServer,
      extra: ServerConnectionHandoff(serverId: _server.id),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Something went wrong. Please try again.'),
      findsOneWidget,
    );
    expect(find.text('This field is required'), findsNothing);
    harness.router.go(Routes.chat);
    await tester.pumpAndSettle();
    await harness.unmount(tester);
  });

  testWidgets('a first account\'s server, checked in the sheet, goes on to '
      'its sign-in too', (tester) async {
    final harness = AdaptiveAuthHarness(server: _server);
    addTearDown(harness.dispose);

    await tester.pumpWidget(harness.build(initialLocation: Routes.chat));
    await tester.pumpAndSettle();
    harness.router.goNamed(
      RouteNames.serverConnection,
      extra: const ServerConnectionHandoff(
        config: _server,
        authFlow: AuthFlowConfig(serverConfig: _server),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AuthenticationPage), findsOneWidget);
    await harness.unmount(tester);
  });

  testWidgets('Android auth back surface stays at toolbar action size', (
    tester,
  ) async {
    usePhoneViewport(tester);
    final harness = AdaptiveAuthHarness(server: _server);
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.build(initialLocation: Routes.serverConnection),
    );
    await tester.pumpAndSettle();

    check(
      tester.getSize(
        find.byKey(const ValueKey<String>('server-connection-back-button')),
      ),
    ).equals(const Size.square(TouchTarget.minimum));

    await harness.unmount(tester);
  });

  testWidgets('server advanced disclosure respects reduced motion', (
    tester,
  ) async {
    final harness = AdaptiveAuthHarness(
      server: _server,
      disableAnimations: true,
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.build(initialLocation: Routes.serverConnection),
    );
    await tester.pumpAndSettle();

    final toggle = find.byKey(
      const ValueKey<String>('advanced-settings-toggle'),
    );
    final rotation = tester.widget<AnimatedRotation>(
      find.descendant(of: toggle, matching: find.byType(AnimatedRotation)),
    );

    check(rotation.duration).equals(Duration.zero);
    expect(find.byType(AnimatedCrossFade), findsNothing);

    final urlField = tester.widget<AccessibleFormField>(
      find.byKey(const ValueKey<String>('server-url-field')),
    );
    check(urlField.prefixIcon).isNull();
    final renderedUrlField = tester.widget<AdaptiveTextFormField>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('server-url-field')),
        matching: find.byType(AdaptiveTextFormField),
      ),
    );
    check(renderedUrlField.cupertinoDecoration).isNotNull();
    // Fields use a hairline outline.
    check(renderedUrlField.cupertinoDecoration!.border).isNotNull();

    final disclosure = tester.widget<UtilityDisclosureSection>(toggle);
    check(disclosure.contentPadding).equals(EdgeInsets.zero);
    expect(find.byIcon(Icons.hub), findsNothing);
    expect(find.byIcon(Icons.hub_outlined), findsNothing);
    expect(find.image(const AssetImage('assets/icons/icon.png')), findsNothing);

    await tester.tap(toggle);
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('custom-header-name-field')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('custom-header-value-field')),
      findsOneWidget,
    );
    for (final field in tester.widgetList<AccessibleFormField>(
      find.byType(AccessibleFormField),
    )) {
      check(field.prefixIcon).isNull();
    }
    for (final field in tester.widgetList<AdaptiveTextFormField>(
      find.byType(AdaptiveTextFormField),
    )) {
      check(field.prefixIcon).isNull();
      check(field.cupertinoDecoration).isNotNull();
      // Fields use a hairline outline.
      check(field.cupertinoDecoration!.border).isNotNull();
    }
    final addHeaderFinder = find.byKey(
      const ValueKey<String>('add-custom-header-button'),
    );
    expect(addHeaderFinder, findsOneWidget);
    final addHeaderButton = tester.widget<ConduitButton>(addHeaderFinder);
    check(addHeaderButton.text).equals('Add header');
    check(addHeaderButton.icon).isNull();
    check(addHeaderButton.onPressed).isNull();

    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey<String>('custom-header-name-field')),
        matching: find.byType(EditableText),
      ),
      'X-Test-Header',
    );
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey<String>('custom-header-value-field')),
        matching: find.byType(EditableText),
      ),
      'test-value',
    );
    await tester.pump();
    check(tester.widget<ConduitButton>(addHeaderFinder).onPressed).isNotNull();

    await harness.unmount(tester);
  });
}
