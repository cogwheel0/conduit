import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/adaptive_toolbar_components.dart';
import 'package:conduit/shared/widgets/chrome_gradient_fade.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/utility_components.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  testWidgets('iOS utility routes reuse the shared Conduit navigation bar', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat)
            .copyWith(platform: TargetPlatform.iOS),
        home: Builder(
          builder: (context) => CupertinoPageScaffold(
            child: CupertinoButton(
              child: const Text('Open settings'),
              onPressed: () => Navigator.of(context).push(
                CupertinoPageRoute<void>(
                  builder: (_) => UtilityPageScaffold.settings(
                    title: 'Hermes Agent',
                    children: const <Widget>[SizedBox(height: 100)],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();

    final scaffold = tester.widget<CupertinoPageScaffold>(
      find.byType(CupertinoPageScaffold).last,
    );
    expect(
      scaffold.navigationBar,
      isA<ConduitAdaptiveCupertinoNavigationBar>(),
    );
    expect(find.byKey(const ValueKey('utility-route-back-button')), findsOne);
    expect(find.byType(CNButton), findsOneWidget);
    expect(find.byType(ConduitChromeGradientFade), findsOneWidget);
    expect(find.byType(BackdropFilter), findsOneWidget);

    final list = tester.widget<ListView>(find.byType(ListView));
    expect(
      list.padding,
      EdgeInsets.fromLTRB(
        Spacing.pagePadding,
        Spacing.lg +
            tester.view.padding.top / tester.view.devicePixelRatio +
            kTextTabBarHeight,
        Spacing.pagePadding,
        Spacing.pagePadding +
            tester.view.padding.bottom / tester.view.devicePixelRatio,
      ),
    );
  });
}
