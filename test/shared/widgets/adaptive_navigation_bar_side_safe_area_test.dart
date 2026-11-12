import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/adaptive_toolbar_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/sidebar_ios26_scaffold.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _screen = Size(402, 874);

/// iPhone Duo's front display: the status bar runs down the right edge.
const _rightStrip = EdgeInsets.only(top: 24, right: 54);

/// An iPhone in landscape: the notch side and the other side are both
/// inset.
const _landscapeNotch = EdgeInsets.only(left: 59, right: 59);

Widget _app({required EdgeInsets padding, required Widget home}) {
  return MaterialApp(
    theme: AppTheme.light(TweakcnThemes.t3Chat)
        .copyWith(platform: TargetPlatform.iOS),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(padding: padding, viewPadding: padding),
      child: child!,
    ),
    home: home,
  );
}

Widget _bar() {
  return const Scaffold(
    appBar: ConduitAdaptiveCupertinoNavigationBar(
      textScaler: TextScaler.noScaling,
      leading: SizedBox(key: ValueKey('leading'), width: 44, height: 44),
      middle: SizedBox(key: ValueKey('middle'), width: 120, height: 44),
      trailing: SizedBox(key: ValueKey('trailing'), width: 103, height: 44),
    ),
  );
}

void main() {
  setUp(() {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
  });
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  Future<void> sizeScreen(WidgetTester tester) async {
    tester.view.physicalSize = _screen;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('the bar keeps its trailing controls clear of a right-hand '
      'status bar strip', (tester) async {
    await sizeScreen(tester);
    await tester.pumpWidget(_app(padding: _rightStrip, home: _bar()));

    final leading = tester.getRect(find.byKey(const ValueKey('leading')));
    final trailing = tester.getRect(find.byKey(const ValueKey('trailing')));
    final middle = tester.getRect(find.byKey(const ValueKey('middle')));
    // The usual 16 pt margin, measured from the strip's inner edge.
    expect(trailing.right, _screen.width - 54 - Spacing.inputPadding);
    expect(leading.left, Spacing.inputPadding);
    // Below the top inset, as before.
    expect(leading.top, 24);
    // The title stays between the controls.
    expect(middle.left, greaterThanOrEqualTo(leading.right));
    expect(middle.right, lessThanOrEqualTo(trailing.left));
  });

  testWidgets('the bar keeps clear of both sides in landscape', (tester) async {
    await sizeScreen(tester);
    await tester.pumpWidget(_app(padding: _landscapeNotch, home: _bar()));

    final leading = tester.getRect(find.byKey(const ValueKey('leading')));
    final trailing = tester.getRect(find.byKey(const ValueKey('trailing')));
    expect(leading.left, 59 + Spacing.inputPadding);
    expect(trailing.right, _screen.width - 59 - Spacing.inputPadding);
  });

  testWidgets('without a side inset the bar keeps its 16 pt margins', (
    tester,
  ) async {
    await sizeScreen(tester);
    await tester.pumpWidget(_app(padding: EdgeInsets.zero, home: _bar()));

    expect(
      tester.getRect(find.byKey(const ValueKey('leading'))).left,
      Spacing.inputPadding,
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('trailing'))).right,
      _screen.width - Spacing.inputPadding,
    );
  });

  testWidgets('the sidebar header keeps Search and New Chat clear of the '
      'strip', (tester) async {
    await sizeScreen(tester);
    await tester.pumpWidget(
      _app(
        padding: _rightStrip,
        home: SidebarIos26Scaffold(
          showNativeView: false,
          leading: const SizedBox(
            key: ValueKey('sidebar-leading'),
            width: 44,
            height: 44,
          ),
          actions: [
            AdaptiveAppBarAction(
              iosSymbol: 'magnifyingglass',
              semanticLabel: 'Search',
              onPressed: () {},
            ),
            AdaptiveAppBarAction(
              iosSymbol: 'square.and.pencil',
              semanticLabel: 'New Chat',
              onPressed: () {},
            ),
          ],
          body: const SizedBox.expand(),
        ),
      ),
    );

    // Without native views the two actions hold their glass group's place.
    final bar = find.byType(ConduitAdaptiveCupertinoNavigationBar);
    final actions = find.descendant(
      of: bar,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is SizedBox &&
            widget.width == 2 * kConduitToolbarClusterSlotExtent &&
            widget.height == TouchTarget.minimum,
      ),
    );
    expect(actions, findsOneWidget);
    expect(
      tester.getRect(actions).right,
      _screen.width - 54 - Spacing.inputPadding,
    );
  });

  testWidgets('a bar title is sized to the width inside the side insets', (
    tester,
  ) async {
    await sizeScreen(tester);
    late BuildContext context;
    await tester.pumpWidget(
      _app(
        padding: _rightStrip,
        home: Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(conduitAdaptiveToolbarWidthOf(context), _screen.width - 54);

    double pillWidth() => resolveConduitAdaptiveLeadingPillWidth(
      context,
      trailingActionCount: 1,
      maxWidth: double.infinity,
    );
    final inset = pillWidth();

    await tester.pumpWidget(
      _app(
        padding: EdgeInsets.zero,
        home: Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(conduitAdaptiveToolbarWidthOf(context), _screen.width);
    expect(pillWidth() - inset, 54);
  });
}
