import 'package:checks/checks.dart';
import 'package:conduit/features/auth/widgets/auth_grouped_form.dart';
import 'package:conduit/platform/webview_cookie_helper.dart';
import 'package:conduit/shared/services/navigation_service.dart';
import 'package:conduit/shared/widgets/adaptive_toolbar_components.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/utility_components.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
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
/// large titles, inset-grouped rows named by leading labels, footers that
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

  AdaptiveButton primaryButtonSurface(WidgetTester tester) =>
      tester.widget<AdaptiveButton>(
        find.descendant(
          of: find.byType(AuthPrimaryButton),
          matching: find.byType(AdaptiveButton),
        ),
      );

  AuthGroupedTextField labelledField(WidgetTester tester, String label) =>
      tester
          .widgetList<AuthGroupedTextField>(find.byType(AuthGroupedTextField))
          .singleWhere((field) => field.label == label);

  Finder fieldLabel(String label) =>
      find.byKey(ValueKey<String>('auth-field-label:$label'));

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

    // A large title, the field named by a leading label in its row, and a
    // one-line footer saying which address to use; no web-form label above
    // the field and no required-field asterisk.
    expect(find.text('Open WebUI'), findsWidgets);
    expect(find.text('Server Address'), findsNothing);
    expect(fieldLabel('Server'), findsOneWidget);
    expect(
      find.text('Use the address you open in a web browser.'),
      findsOneWidget,
    );
    expect(find.text('*'), findsNothing);
    expect(find.byType(AccessibleFormField), findsNothing);

    final url = tester.widget<AuthGroupedTextField>(
      find.byKey(const ValueKey<String>('server-url-field')),
    );
    check(url.label).equals('Server');
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
    // Waiting, its label drops to the secondary tone rather than fading
    // out, so it still reads as the step's button.
    final buttonTheme = tester
        .element(find.byType(AuthPrimaryButton))
        .conduitTheme;
    check(primaryButtonSurface(tester).textColor)
        .equals(buttonTheme.textSecondary);
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey<String>('server-url-field')),
        matching: find.byType(EditableText),
      ),
      'chat.example.com',
    );
    await tester.pump();
    check(primaryButton(tester).onPressed).isNotNull();
    check(primaryButtonSurface(tester).textColor)
        .equals(buttonTheme.buttonPrimaryText);
    check(primaryButtonSurface(tester).color).equals(buttonTheme.buttonPrimary);

    // Advanced Settings is a disclosure row in the address's own group,
    // under the field and above the footer; it opens grouped sections at
    // once with reduced motion.
    final advanced = find.byKey(
      const ValueKey<String>('advanced-settings-toggle'),
    );
    check(tester.widget<AuthGroupedRow>(advanced).expanded).equals(false);
    final addressCard = find.descendant(
      of: find.byKey(const ValueKey<String>('server-address-section')),
      matching: find.byType(AuthGroupedCard),
    );
    expect(
      find.descendant(of: addressCard, matching: advanced),
      findsOneWidget,
    );
    final urlRow = find.byKey(const ValueKey<String>('server-url-field'));
    expect(find.descendant(of: addressCard, matching: urlRow), findsOneWidget);
    check(tester.getTopLeft(advanced).dy)
        .isGreaterThan(tester.getTopLeft(urlRow).dy);
    check(tester.getTopLeft(advanced).dy).isLessThan(
      tester
          .getTopLeft(find.text('Use the address you open in a web browser.'))
          .dy,
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

    final username = labelledField(tester, 'Email');
    final password = labelledField(tester, 'Password');
    check(username.placeholder).equals('name@example.com');
    check(password.placeholder).equals('Required');
    check(username.textInputAction).equals(TextInputAction.next);
    check(password.textInputAction).equals(TextInputAction.go);
    check(password.obscureText).isTrue();
    // The title says Sign In; the button goes on rather than repeat it.
    check(primaryButton(tester).label).equals('Continue');
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

    // Change is a plain button, as a bar button is: no fill or capsule
    // behind it to rival the step's primary action, and a semibold label in
    // the button colour so it still reads as tappable without colour.
    final change = find.byKey(
      const ValueKey<String>('authentication-change-server'),
    );
    expect(
      find.descendant(of: change, matching: find.byType(DecoratedBox)),
      findsNothing,
    );
    final changeLabel = tester.widget<Text>(
      find.descendant(of: change, matching: find.text('Change')),
    );
    final theme = tester.element(change).conduitTheme;
    check(changeLabel.style?.fontWeight).equals(FontWeight.w600);
    check(changeLabel.style?.color).equals(theme.buttonPrimary);

    // The password's show/hide eye is a secondary-tone accessory with a
    // full touch target that names what it will do.
    final eye = find.byKey(
      const ValueKey<String>('authentication-password-visibility'),
    );
    check(tester.getSize(eye).height).isGreaterOrEqual(TouchTarget.minimum);
    check(tester.getSize(eye).width).isGreaterOrEqual(TouchTarget.minimum);
    final eyeIcon = tester.widget<Icon>(
      find.descendant(of: eye, matching: find.byType(Icon)),
    );
    check(eyeIcon.color).equals(theme.textSecondary);

    // The row reads as one element and Change stays its own button.
    final semantics = tester.ensureSemantics();
    expect(
      find.bySemanticsLabel('Open WebUI. https://open-webui.example'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Change'), findsOneWidget);
    expect(find.bySemanticsLabel('Show Password'), findsOneWidget);
    semantics.dispose();

    await tester.tap(eye);
    await tester.pump();
    check(labelledField(tester, 'Password').obscureText).isFalse();
    expect(
      find.descendant(of: eye, matching: find.byIcon(CupertinoIcons.eye)),
      findsOneWidget,
    );
    await tester.tap(eye);
    await tester.pump();
    check(labelledField(tester, 'Password').obscureText).isTrue();

    await tester.tap(
      find.byKey(const ValueKey<String>('authentication-change-server')),
    );
    await tester.pumpAndSettle();
    check(harness.router.routeInformationProvider.value.uri.path)
        .equals(Routes.serverConnection);

    await harness.unmount(tester);
  });

  testWidgets('the token method is named for what the user has, and its '
      'footer says where to find it', (tester) async {
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

    final selector = tester.widget<AdaptiveSegmentedControl>(
      find.byType(AdaptiveSegmentedControl),
    );
    check(selector.labels).deepEquals(['Password', 'Token']);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('authentication-mode-selector')),
        matching: find.text('Token'),
      ),
    );
    await tester.pumpAndSettle();

    final form = tester.widget<AuthGroupedSection>(
      find.byKey(const ValueKey('api_key_form')),
    );
    check(form.footer).isNotNull()
      ..contains('JWT session token')
      ..contains('Settings › Account › API Keys')
      ..contains('sk-');
    check(labelledField(tester, 'Token').obscureText).isTrue();
    check(primaryButton(tester).label).equals('Continue');

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
    final fields = find.descendant(
      of: form,
      matching: find.byType(EditableText),
    );
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

  testWidgets('a filled sign-in still names each field, in one column', (
    tester,
  ) async {
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

    final form = find.byKey(const ValueKey('credentials_form'));
    final fields = find.descendant(
      of: form,
      matching: find.byType(EditableText),
    );
    await tester.enterText(fields.at(0), 'robin@example.com');
    await tester.enterText(fields.at(1), 'synthetic-secret');
    await tester.pump();

    // The placeholders are gone, the labels are not.
    expect(find.text('name@example.com'), findsNothing);
    expect(fieldLabel('Email'), findsOneWidget);
    expect(fieldLabel('Password'), findsOneWidget);
    // Both values start on one line, past the wider label.
    check(tester.getTopLeft(fields.at(0)).dx)
        .equals(tester.getTopLeft(fields.at(1)).dx);
    check(tester.getTopLeft(fields.at(0)).dx)
        .isGreaterThan(tester.getTopRight(fieldLabel('Password')).dx);
    // The label is not read a second time; the field carries its name.
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel('Email or Username'), findsOneWidget);
    semantics.dispose();

    // Tapping a label puts the cursor in its field, as an iOS form row does.
    final password = labelledField(tester, 'Password');
    await tester.tap(fieldLabel('Password'));
    await tester.pump();
    check(password.focusNode!.hasFocus).isTrue();

    await harness.unmount(tester);
  });

  testWidgets('grouped cards take the inset-grouped list corners of iOS 26', (
    tester,
  ) async {
    // iOS 26 draws a softer one-point separator that stops at the row's
    // trailing margin; earlier systems a hairline to the section's edge.
    Future<Padding> separatorPadding() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(TweakcnThemes.conduit),
          // A fresh key per pump: the platform overrides are not inherited
          // state, so the separator has to be built anew to read them.
          home: Scaffold(body: InsetGroupedSeparator(key: UniqueKey())),
        ),
      );
      return tester.widget<Padding>(
        find
            .descendant(
              of: find.byType(InsetGroupedSeparator),
              matching: find.byType(Padding),
            )
            .first,
      );
    }

    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
    check(insetGroupedCornerRadius()).equals(kIOS26InsetGroupedRadius);
    check(
      (await separatorPadding()).padding,
    ).equals(const EdgeInsetsDirectional.only(start: 16, end: 16));
    check(tester.getSize(find.byType(ColoredBox).last).height).equals(1);
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 18;
    PlatformUiCapabilities.debugNativeIOS26Override = null;
    check(insetGroupedCornerRadius()).equals(kLegacyInsetGroupedRadius);
    check(
      (await separatorPadding()).padding,
    ).equals(const EdgeInsetsDirectional.only(start: 16));
    PlatformUiCapabilities.debugPlatformOverride = null;

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

    // The welcome cards and the shared grouped sections draw one shape: the
    // continuous-corner inset-grouped section.
    final card = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byType(AuthGroupedCard).first,
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    final decoration = card.decoration as ShapeDecoration;
    check(decoration.shape).isA<RoundedSuperellipseBorder>();
    check((decoration.shape as RoundedSuperellipseBorder).borderRadius)
        .equals(BorderRadius.circular(insetGroupedCornerRadius()));

    await harness.unmount(tester);
  });

  testWidgets('the welcome list fades out above the home indicator', (
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

    double bottomEdgeOpacity() => tester
        .widget<AnimatedOpacity>(
          find.byKey(const ValueKey<String>('utility-bottom-scroll-edge')),
        )
        .opacity;

    // The last option continues under the home indicator: the edge fades.
    check(bottomEdgeOpacity()).equals(1);
    await tester.drag(
      find
          .descendant(
            of: find.byType(UtilityPageScaffold),
            matching: find.byType(Scrollable),
          )
          .first,
      const Offset(0, -2000),
    );
    await tester.pumpAndSettle();
    // At the end of the list nothing is under it, so nothing is washed out.
    check(bottomEdgeOpacity()).equals(0);

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
