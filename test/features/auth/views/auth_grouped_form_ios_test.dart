import 'package:checks/checks.dart';
import 'package:conduit/features/auth/widgets/auth_grouped_form.dart';
import 'package:conduit/platform/webview_cookie_helper.dart';
import 'package:conduit/shared/services/navigation_service.dart';
import 'package:conduit/shared/widgets/adaptive_toolbar_components.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/utility_components.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/adaptive_auth_harness.dart';

const _server = ServerConfig(
  id: 'server-1',
  name: 'Open WebUI',
  url: 'https://open-webui.example',
  isActive: true,
);

/// The iOS sign-in flow reads like account setup in a first-party app:
/// large titles, inset-grouped rows named by their placeholders, footers that
/// guide and carry errors, and a keyboard that walks the fields.
void main() {
  setUp(() {
    // The Flutter fallbacks of the native iOS 26 controls render in tests.
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 18;
    debugIsWebViewSupportedOverride = false;
  });
  tearDown(() {
    PlatformUiCapabilities.resetDebugOverrides();
    debugIsWebViewSupportedOverride = null;
  });

  AuthPrimaryButton primaryButton(WidgetTester tester) =>
      tester.widget<AuthPrimaryButton>(find.byType(AuthPrimaryButton));

  AuthGroupedTextField groupedField(WidgetTester tester, String placeholder) =>
      tester
          .widgetList<AuthGroupedTextField>(find.byType(AuthGroupedTextField))
          .singleWhere((field) => field.placeholder == placeholder);

  testWidgets('server address step is an inset-grouped form', (tester) async {
    usePhoneViewport(tester);
    final harness = AdaptiveAuthHarness(
      server: _server,
      platform: TargetPlatform.iOS,
      disableAnimations: true,
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.build(initialLocation: Routes.serverConnection),
    );
    await tester.pumpAndSettle();

    // A large title, a section header, and a footer saying what comes next;
    // no web-form label above the field and no required-field asterisk.
    expect(find.text('Open WebUI'), findsWidgets);
    expect(find.text('Server Address'), findsOneWidget);
    expect(
      find.text(
        "Use the address you open in a web browser. You'll sign in next.",
      ),
      findsOneWidget,
    );
    expect(find.text('*'), findsNothing);
    expect(find.byType(AccessibleFormField), findsNothing);

    final url = tester.widget<AuthGroupedTextField>(
      find.byKey(const ValueKey<String>('server-url-field')),
    );
    check(url.placeholder).equals('https://openwebui.example.com');
    check(url.autofocus).isTrue();
    check(url.textInputAction).equals(TextInputAction.go);
    check(url.keyboardType).equals(TextInputType.url);

    // Connect waits for an address.
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey<String>('server-url-field')),
        matching: find.byType(EditableText),
      ),
      '',
    );
    await tester.pump();
    check(primaryButton(tester).onPressed).isNull();
    check(primaryButton(tester).label).equals('Connect');
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey<String>('server-url-field')),
        matching: find.byType(EditableText),
      ),
      'chat.example.com',
    );
    await tester.pump();
    check(primaryButton(tester).onPressed).isNotNull();

    // Advanced Settings is a disclosure row inside a grouped card; it opens
    // grouped sections at once with reduced motion.
    final advanced = find.byKey(
      const ValueKey<String>('advanced-settings-toggle'),
    );
    check(tester.widget<AuthGroupedRow>(advanced).expanded).equals(false);
    expect(
      find.ancestor(of: advanced, matching: find.byType(AuthGroupedCard)),
      findsOneWidget,
    );
    await tester.tap(advanced);
    await tester.pump();
    check(tester.widget<AuthGroupedRow>(advanced).expanded).equals(true);
    expect(find.byType(AnimatedSize), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('custom-header-name-field')),
      findsOneWidget,
    );
    expect(find.text('Allow Unverified Certificate'), findsOneWidget);
    // Row values sit at the trailing edge, next to their chevron.
    final certificateRow = find.byKey(
      const ValueKey<String>('mtls-certificate-row'),
    );
    final chooseValue = find.descendant(
      of: certificateRow,
      matching: find.text('Choose…'),
    );
    final chevron = find.descendant(
      of: certificateRow,
      matching: find.byType(AuthChevron),
    );
    check(tester.getTopLeft(chevron).dx - tester.getTopRight(chooseValue).dx)
        .isLessThan(Spacing.md);
    final addHeader = tester.widget<AuthGroupedRow>(
      find.byKey(const ValueKey<String>('add-custom-header-button')),
    );
    check(addHeader.title).equals('Add Header');
    check(addHeader.onTap).isNull();

    await harness.unmount(tester);
  });

  testWidgets('sign-in shows the server as a row with Change and walks the '
      'fields from the keyboard', (tester) async {
    usePhoneViewport(tester);
    final harness = AdaptiveAuthHarness(
      server: _server,
      platform: TargetPlatform.iOS,
      backendConfig: const BackendConfig(),
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.build(initialLocation: Routes.authentication),
    );
    await tester.pumpAndSettle();

    // The server is a grouped row, not a lone monospace address.
    final serverRow = find.byKey(
      const ValueKey<String>('authentication-server-row'),
    );
    expect(
      find.descendant(of: serverRow, matching: find.text('open-webui.example')),
      findsOneWidget,
    );
    expect(find.text('https://open-webui.example'), findsNothing);

    final username = groupedField(tester, 'Email or username');
    final password = groupedField(tester, 'Password');
    check(username.textInputAction).equals(TextInputAction.next);
    check(password.textInputAction).equals(TextInputAction.go);
    check(password.obscureText).isTrue();
    check(primaryButton(tester).label).equals('Sign In');
    check(primaryButton(tester).onPressed).isNull();

    // The first empty field has the cursor; Next moves on to the password.
    check(username.focusNode!.hasFocus).isTrue();
    await tester.enterText(
      find.descendant(
        of: find.byWidget(username),
        matching: find.byType(EditableText),
      ),
      'robin@example.com',
    );
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();
    check(password.focusNode!.hasFocus).isTrue();

    // The row reads as one element and Change stays its own button.
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel('Open WebUI. https://open-webui.example'),
        findsOneWidget);
    expect(find.bySemanticsLabel('Change'), findsOneWidget);
    semantics.dispose();

    await tester.tap(
      find.byKey(const ValueKey<String>('authentication-change-server')),
    );
    await tester.pumpAndSettle();
    check(harness.router.routeInformationProvider.value.uri.path)
        .equals(Routes.serverConnection);

    await harness.unmount(tester);
  });

  testWidgets('a rejected sign-in says why in the fields\' footer', (
    tester,
  ) async {
    usePhoneViewport(tester);
    final harness = AdaptiveAuthHarness(
      server: _server,
      platform: TargetPlatform.iOS,
      authActions: _RejectingAuthActions(),
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.build(initialLocation: Routes.authentication),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('auth-footer-error')), findsNothing);

    final form = find.byKey(const ValueKey('credentials_form'));
    final fields = find.descendant(of: form, matching: find.byType(EditableText));
    await tester.enterText(fields.at(0), 'robin@example.com');
    await tester.enterText(fields.at(1), 'not-the-password');
    await tester.pump();
    await tester.tap(find.byType(AuthPrimaryButton));
    // The attempt waits on timers (server selection) that pumpAndSettle does
    // not advance.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    final error = find.descendant(
      of: form,
      matching: find.byKey(const ValueKey('auth-footer-error')),
    );
    expect(error, findsOneWidget);
    expect(
      find.descendant(
        of: error,
        matching: find.textContaining("couldn't sign you in"),
      ),
      findsOneWidget,
    );

    await harness.unmount(tester);
  });

  testWidgets('the welcome hero hands its title to the bar once scrolled', (
    tester,
  ) async {
    usePhoneViewport(tester);
    final harness = AdaptiveAuthHarness(
      server: _server,
      platform: TargetPlatform.iOS,
    );
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.build(initialLocation: Routes.backendChooser),
    );
    await tester.pumpAndSettle();

    double barTitleOpacity() => tester
        .widget<AnimatedOpacity>(
          find.descendant(
            of: find.byType(ConduitAdaptiveCupertinoNavigationBar),
            matching: find.byType(AnimatedOpacity),
          ),
        )
        .opacity;

    check(barTitleOpacity()).equals(0);
    await tester.drag(
      find
          .descendant(
            of: find.byType(UtilityPageScaffold),
            matching: find.byType(Scrollable),
          )
          .first,
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();
    check(barTitleOpacity()).equals(1);

    await harness.unmount(tester);
  });
}

class _RejectingAuthActions extends Fake implements AuthActions {
  @override
  Future<bool> login(
    String username,
    String password, {
    bool rememberCredentials = false,
  }) async => false;
}
