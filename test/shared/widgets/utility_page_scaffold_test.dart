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
    // No scroll edge under the bar; only one above the home indicator,
    // which stays clear while nothing scrolls under it.
    final fade = tester.widget<ConduitChromeGradientFade>(
      find.byType(ConduitChromeGradientFade),
    );
    expect(fade.edge, ConduitChromeFadeEdge.bottom);
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey<String>('utility-bottom-scroll-edge')),
          )
          .opacity,
      0,
    );
    // Nothing is under the bar yet, so it has no background.
    expect(
      tester
          .widget<BackdropFilter>(
            find.descendant(
              of: find.byType(ConduitAdaptiveCupertinoNavigationBar),
              matching: find.byType(BackdropFilter),
            ),
          )
          .enabled,
      isFalse,
    );

    final list = tester.widget<ListView>(find.byType(ListView));
    expect(
      list.padding,
      EdgeInsets.fromLTRB(
        Spacing.screenPadding,
        Spacing.sm +
            tester.view.padding.top / tester.view.devicePixelRatio +
            kConduitCupertinoToolbarHeight,
        Spacing.screenPadding,
        Spacing.lg + tester.view.padding.bottom / tester.view.devicePixelRatio,
      ),
    );
  });

  testWidgets(
    'the iOS bar frosts, with a hairline, only while content is under it',
    (tester) async {
      PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
      PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
      PlatformUiCapabilities.debugNativeIOS26Override = true;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat)
              .copyWith(platform: TargetPlatform.iOS),
          home: UtilityPageScaffold.settings(
            title: 'Scheduled Tasks',
            children: const <Widget>[SizedBox(height: 2000)],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final barBlur = find.descendant(
        of: find.byType(ConduitAdaptiveCupertinoNavigationBar),
        matching: find.byType(BackdropFilter),
      );
      BoxDecoration barBackground() =>
          tester
                  .widget<DecoratedBox>(
                    find.descendant(
                      of: barBlur,
                      matching: find.byType(DecoratedBox),
                    ),
                  )
                  .decoration
              as BoxDecoration;
      Color barFill() => barBackground().color!;
      BorderSide barHairline() => (barBackground().border! as Border).bottom;
      final pageColor = tester
          .element(find.byType(UtilityPageScaffold))
          .conduitTheme
          .groupedBackground;

      expect(tester.widget<BackdropFilter>(barBlur).enabled, isFalse);
      expect(barFill().a, 0);
      expect(barHairline().color.a, 0);

      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(tester.widget<BackdropFilter>(barBlur).enabled, isTrue);
      // The page's own tone, translucent, never a band of another colour.
      expect(barFill().withValues(alpha: 1), pageColor.withValues(alpha: 1));
      expect(barFill().a, closeTo(pageColor.a * 0.6, 0.01));
      // One device pixel of the system separator under it.
      expect(barHairline().color.a, greaterThan(0));
      expect(barHairline().width, 1 / tester.view.devicePixelRatio);

      await tester.drag(find.byType(ListView), const Offset(0, 400));
      await tester.pumpAndSettle();
      expect(tester.widget<BackdropFilter>(barBlur).enabled, isFalse);
      expect(barFill().a, 0);
      expect(barHairline().color.a, 0);
    },
  );

  testWidgets('Material utility routes retain their trailing action', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: UtilityPageScaffold.settings(
          title: 'Settings',
          trailing: const Icon(Icons.done, key: ValueKey('trailing-action')),
          children: const [SizedBox(height: 20)],
        ),
      ),
    );

    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byKey(const ValueKey('trailing-action')),
      ),
      findsOneWidget,
    );
  });
}
