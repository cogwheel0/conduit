import 'package:checks/checks.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/services/navigation_service.dart';
import 'package:conduit/features/auth/views/backend_chooser_page.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/connection_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/material.dart';
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

      check(
        harness.router.routeInformationProvider.value.uri.path,
      ).equals(Routes.authentication);
      check(harness.router.canPop()).isFalse();

      await tester.tap(
        find.byKey(const ValueKey<String>('authentication-back-button')),
      );
      await tester.pumpAndSettle();

      check(
        harness.router.routeInformationProvider.value.uri.path,
      ).equals(Routes.serverConnection);
      check(harness.router.canPop()).isFalse();
      expect(
        find.byKey(const ValueKey<String>('server-connection-back-button')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('server-connection-back-button')),
      );
      await tester.pumpAndSettle();

      check(
        harness.router.routeInformationProvider.value.uri.path,
      ).equals(Routes.backendChooser);
      expect(find.byType(BackendChooserPage), findsOneWidget);
      await harness.unmount(tester);
    },
  );

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
    check(renderedUrlField.cupertinoDecoration!.border).isNull();

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
      check(field.cupertinoDecoration!.border).isNull();
    }
    final addHeaderFinder = find.byKey(
      const ValueKey<String>('add-custom-header-button'),
    );
    expect(addHeaderFinder, findsOneWidget);
    final addHeaderButton = tester.widget<ConduitButton>(addHeaderFinder);
    check(addHeaderButton.text).equals('Add header');
    check(addHeaderButton.icon).isNull();
    check(addHeaderButton.useNativeLabel).isTrue();
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
