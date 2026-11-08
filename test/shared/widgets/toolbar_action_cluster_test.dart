import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/adaptive_toolbar_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

ConduitToolbarClusterItem _item(String id, {String symbol = 'circle'}) =>
    ConduitToolbarClusterItem(
      id: id,
      fallbackIcon: Icons.circle_outlined,
      action: ConduitNativeToolbarAction(
        iosSymbol: symbol,
        accessibilityLabel: id,
        onPressed: () {},
      ),
    );

ConduitToolbarClusterItem _menu(String id) => ConduitToolbarClusterItem(
  id: id,
  fallbackIcon: Icons.more_horiz,
  action: ConduitNativeToolbarAction(
    iosSymbol: 'ellipsis',
    accessibilityLabel: id,
    menuItems: [
      ConduitNativeToolbarMenuItem(label: 'Rename', onSelected: () {}),
      ConduitNativeToolbarMenuItem(
        label: 'Delete',
        isDestructive: true,
        onSelected: () {},
      ),
    ],
  ),
);

Widget _host(
  List<ConduitToolbarClusterItem> items, {
  bool reduceMotion = false,
}) {
  return MaterialApp(
    theme: AppTheme.light(TweakcnThemes.t3Chat),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: ConduitToolbarActionCluster(
              key: const ValueKey('cluster'),
              items: items,
            ),
          ),
        ),
      ),
    ),
  );
}

double _opacityOf(WidgetTester tester, String id) {
  final slot = find.byKey(ValueKey<Object>(id));
  if (slot.evaluate().isEmpty) return 0;
  return tester
      .widget<Opacity>(
        find.descendant(of: slot, matching: find.byType(Opacity)),
      )
      .opacity;
}

void main() {
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  testWidgets('one action is a circle; more share one capsule', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(conduitToolbarClusterWidth(context, 0), 0);
    expect(conduitToolbarClusterWidth(context, 1), 44);
    expect(conduitToolbarClusterWidth(context, 2), 80);
    expect(conduitToolbarClusterWidth(context, 3), 120);
  });

  testWidgets('a bar title may take the room between the controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      ),
    );
    // 402 - 2 * 16 - 44 - 80 - 2 * 12: everything between the sidebar
    // button and the group, 12 pt clear of each, not only what would keep
    // it on the centre line (186).
    expect(
      resolveConduitBarTitleMaxWidth(
        context,
        leadingWidth: 44,
        trailingWidth: 80,
        maxWidth: 320,
      ),
      222,
    );
    expect(
      resolveConduitBarTitleMaxWidth(
        context,
        leadingWidth: 44,
        trailingWidth: 80,
        maxWidth: 200,
      ),
      200,
    );
  });

  testWidgets('a title that needs all the room sits 12 pt from both sides', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          appBar: ConduitAdaptiveCupertinoNavigationBar(
            textScaler: TextScaler.noScaling,
            leading: SizedBox(key: ValueKey('leading'), width: 44, height: 44),
            middle: SizedBox(key: ValueKey('middle'), width: 222, height: 44),
            trailing: SizedBox(
              key: ValueKey('trailing'),
              width: 80,
              height: 44,
            ),
          ),
        ),
      ),
    );
    final middle = tester.getRect(find.byKey(const ValueKey('middle')));
    final leading = tester.getRect(find.byKey(const ValueKey('leading')));
    final trailing = tester.getRect(find.byKey(const ValueKey('trailing')));
    // Off the centre line, toward the narrower sidebar button.
    expect(middle.center.dx, lessThan(201));
    expect(middle.left - leading.right, closeTo(12, 0.01));
    expect(trailing.left - middle.right, closeTo(12, 0.01));
  });

  for (final width in [150.0, 120.0]) {
    testWidgets('a $width pt title too wide to centre moves aside, 12 pt '
        'clear', (tester) async {
      tester.view.physicalSize = const Size(402, 874);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // Accessibility text sizes: a 66 pt sidebar button, a 120 pt group
      // and a pill that cannot keep its clear space on the centre line
      // (the narrower one would fit there, 5 pt from the group).
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: ConduitAdaptiveCupertinoNavigationBar(
              textScaler: TextScaler.noScaling,
              leading: const SizedBox(
                key: ValueKey('leading'),
                width: 66,
                height: 44,
              ),
              middle: SizedBox(
                key: const ValueKey('middle'),
                width: width,
                height: 44,
              ),
              trailing: const SizedBox(
                key: ValueKey('trailing'),
                width: 120,
                height: 44,
              ),
            ),
          ),
        ),
      );
      final middle = tester.getRect(find.byKey(const ValueKey('middle')));
      final trailing = tester.getRect(find.byKey(const ValueKey('trailing')));
      final leading = tester.getRect(find.byKey(const ValueKey('leading')));
      expect(middle.center.dx, lessThan(201));
      expect(trailing.left - middle.right, closeTo(12, 0.01));
      expect(middle.left - leading.right, greaterThanOrEqualTo(12));
    });
  }

  testWidgets('a title with room keeps the centre line', (tester) async {
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          appBar: ConduitAdaptiveCupertinoNavigationBar(
            textScaler: TextScaler.noScaling,
            leading: SizedBox(width: 44, height: 44),
            middle: SizedBox(key: ValueKey('middle'), width: 186, height: 44),
            trailing: SizedBox(width: 80, height: 44),
          ),
        ),
      ),
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('middle'))).center.dx,
      closeTo(201, 0.01),
    );
  });

  testWidgets(
    'on iOS 26 the actions sit on one glass surface as plain glyphs',
    (tester) async {
      PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
      PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
      PlatformUiCapabilities.debugNativeIOS26Override = true;

      await tester.pumpWidget(_host([_item('new-chat'), _menu('more')]));
      await tester.pump();

      expect(tester.getSize(find.byKey(const ValueKey('cluster'))).width, 80);
      // One glass shape for the whole group, never per-button glass that
      // merges into a pinched "dumbbell".
      expect(find.byType(AdaptiveGlassBackdrop), findsOneWidget);
      expect(find.byType(CNGlassButtonGroup), findsNothing);
      final button = tester.widget<CNButton>(find.byType(CNButton));
      expect(button.config.style, CNButtonStyle.plain);
      expect(button.icon?.size, kConduitNativeSingleActionSymbolExtent);
      final popup = tester.widget<CNPopupMenuButton>(
        find.byType(CNPopupMenuButton),
      );
      expect(popup.items, hasLength(2));
      expect(find.bySemanticsLabel('new-chat'), findsOneWidget);
      expect(find.bySemanticsLabel('more'), findsOneWidget);

      // Let the native controls' own timers run out before teardown.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    },
  );

  testWidgets(
    'a change of actions reshapes the capsule once, without overshoot',
    (tester) async {
      await tester.pumpWidget(_host([_item('temporary-chat')]));
      final cluster = find.byKey(const ValueKey('cluster'));
      expect(tester.getSize(cluster).width, 44);
      expect(_opacityOf(tester, 'temporary-chat'), 1);

      await tester.pumpWidget(_host([_item('new-chat'), _menu('more')]));
      // Nothing jumps on the frame of the change.
      expect(tester.getSize(cluster).width, 44);
      expect(_opacityOf(tester, 'temporary-chat'), 1);
      expect(_opacityOf(tester, 'new-chat'), 0);

      final widths = <double>[];
      final outgoing = <double>[];
      final incoming = <double>[];
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        widths.add(tester.getSize(cluster).width);
        outgoing.add(_opacityOf(tester, 'temporary-chat'));
        incoming.add(_opacityOf(tester, 'more'));
      }
      // One continuous change: the width only grows and never passes its
      // target, the old glyph only fades out and the new ones only fade in.
      for (var i = 1; i < widths.length; i++) {
        expect(widths[i], greaterThanOrEqualTo(widths[i - 1]));
        expect(widths[i], lessThanOrEqualTo(80));
        expect(outgoing[i], lessThanOrEqualTo(outgoing[i - 1]));
        expect(incoming[i], greaterThanOrEqualTo(incoming[i - 1]));
      }
      // Settled within about a third of a second.
      final settledAt = widths.indexWhere((width) => width == 80);
      expect(settledAt, isNonNegative);
      expect(settledAt * 16, lessThanOrEqualTo(400));
      expect(
        find.byKey(const ValueKey<Object>('temporary-chat')),
        findsNothing,
      );
      expect(_opacityOf(tester, 'new-chat'), 1);
      expect(_opacityOf(tester, 'more'), 1);
      // The glyph nearest the trailing edge keeps the same spot as the
      // circle's, so the change reads as one control reshaping.
      expect(
        tester.getCenter(find.byKey(const ValueKey<Object>('more'))).dx,
        tester.getTopRight(cluster).dx - 20,
      );
    },
  );

  testWidgets('a change mid-way reverses from where it is', (tester) async {
    await tester.pumpWidget(_host([_item('temporary-chat')]));
    final cluster = find.byKey(const ValueKey('cluster'));
    await tester.pumpWidget(_host([_item('new-chat'), _menu('more')]));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 80));
    final midWidth = tester.getSize(cluster).width;
    expect(midWidth, inExclusiveRange(44, 80));

    await tester.pumpWidget(_host([_item('temporary-chat')]));
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      (tester.getSize(cluster).width - midWidth).abs(),
      lessThan(8),
      reason: 'no jump when the target flips back',
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(cluster).width, 44);
    expect(_opacityOf(tester, 'temporary-chat'), 1);
    expect(find.byKey(const ValueKey<Object>('more')), findsNothing);
  });

  testWidgets('Reduce Motion reshapes at once and only cross-fades', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([_item('temporary-chat')], reduceMotion: true),
    );
    final cluster = find.byKey(const ValueKey('cluster'));
    await tester.pumpWidget(
      _host([_item('new-chat'), _menu('more')], reduceMotion: true),
    );
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.getSize(cluster).width, 80);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(_opacityOf(tester, 'more'), inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(_opacityOf(tester, 'more'), 1);
  });
}
