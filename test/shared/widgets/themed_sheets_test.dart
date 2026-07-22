import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/utils/adaptive_glass.dart';
import 'package:conduit/shared/widgets/adaptive_toolbar_components.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';
import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('all themed sheets use the shared edge-to-edge rounded route', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(402, 874);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => ThemedSheets.showSurface<void>(
                context: context,
                builder: (_) => const SizedBox(
                  key: ValueKey<String>('standard-sheet-content'),
                  height: 240,
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final bottomSheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
    final surface = find.byType(ConduitModalSheetSurface);
    expect(
      bottomSheet.shape,
      ThemedSheets.roundedShapeFor(tester.element(surface)),
    );
    expect(bottomSheet.clipBehavior, Clip.antiAlias);
    expect(tester.getSize(surface).width, 402);
    expect(tester.getTopLeft(surface).dx, 0);
  });

  testWidgets('draggable custom sheets remain edge-to-edge', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(402, 874);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => ThemedSheets.showCustom<void>(
                context: context,
                builder: (_) => Stack(
                  children: [
                    DraggableScrollableSheet(
                      expand: false,
                      initialChildSize: 0.4,
                      builder: (_, scrollController) => ColoredBox(
                        key: const ValueKey<String>('custom-sheet-surface'),
                        color: Colors.white,
                        child: ListView(controller: scrollController),
                      ),
                    ),
                  ],
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final surface = find.byKey(const ValueKey<String>('custom-sheet-surface'));
    expect(tester.getSize(surface).width, 402);
    expect(tester.getTopLeft(surface).dx, 0);
  });

  testWidgets('iOS sheets use the native sheet radius, not display radius', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(402, 874);
    tester.view.padding = const FakeViewPadding(top: 62, bottom: 34);
    tester.view.viewPadding = const FakeViewPadding(top: 62, bottom: 34);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(
          TweakcnThemes.t3Chat,
        ).copyWith(platform: TargetPlatform.iOS),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => ThemedSheets.showSurface<void>(
                context: context,
                builder: (_) => const SizedBox(height: 240),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final bottomSheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
    final shape = bottomSheet.shape! as RoundedRectangleBorder;
    expect(
      shape.borderRadius,
      const BorderRadius.vertical(
        top: Radius.circular(AppBorderRadius.bottomSheet),
      ),
    );
  });

  testWidgets('large previews use the shared rounded bottom-sheet route', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(402, 874);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => ThemedSheets.showRoundedPage<void>(
                context: context,
                builder: (sheetContext) => ConduitModalSheetHeader(
                  key: const ValueKey<String>('preview-sheet-header'),
                  leading: const Icon(Icons.account_tree_outlined),
                  title: 'Mermaid Preview',
                  titleStyle: const TextStyle(),
                  onClose: () => Navigator.of(sheetContext).pop(),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
    final route = ModalRoute.of(
      tester.element(
        find.byKey(const ValueKey<String>('preview-sheet-header')),
      ),
    );
    expect(route, isA<ModalBottomSheetRoute<void>>());
    final bottomSheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
    final header = find.byKey(const ValueKey<String>('preview-sheet-header'));
    expect(
      bottomSheet.shape,
      ThemedSheets.roundedShapeFor(tester.element(header)),
    );
    expect(bottomSheet.clipBehavior, Clip.antiAlias);
    expect(tester.getSize(header).width, 402);
    expect(tester.getTopLeft(header).dx, 0);
  });

  testWidgets('shared modal headers paint a divider below the title row', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        home: Scaffold(
          body: ConduitModalSheetHeader(
            leading: const Icon(Icons.account_tree_outlined),
            title: 'Mermaid Preview',
            titleStyle: const TextStyle(),
            onClose: () {},
          ),
        ),
      ),
    );

    final header = find.byType(ConduitModalSheetHeader);
    expect(
      find.descendant(of: header, matching: find.byType(Divider)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: header, matching: find.byType(AdaptiveButton)),
      findsOneWidget,
    );
  });

  testWidgets('root sheets remove native toolbar chrome beneath their edges', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                const ConduitAdaptiveAppBarIconButton(
                  icon: Icons.menu,
                  onPressed: null,
                ),
                ConduitAdaptiveAppBarModelSelector(
                  label: 'Model',
                  maxWidth: 160,
                  onPressed: () {},
                ),
                TextButton(
                  onPressed: () => ThemedSheets.showRoundedPage<void>(
                    context: context,
                    builder: (_) => const SizedBox.expand(),
                  ),
                  child: const Text('Open'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final usesOpaqueFallback = conduitUsesOpaqueGlassFallback();
    if (usesOpaqueFallback) {
      expect(find.byType(AdaptiveButton), findsNothing);
      expect(find.byType(FloatingAppBarIconButton), findsOneWidget);
      expect(find.byType(FloatingAppBarButton), findsNWidgets(2));
    } else {
      expect(find.byType(AdaptiveButton), findsNWidgets(2));
      expect(find.byType(FloatingAppBarIconButton), findsNothing);
      expect(find.byType(FloatingAppBarButton), findsNothing);
    }

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    if (usesOpaqueFallback) {
      expect(find.byType(FloatingAppBarIconButton), findsOneWidget);
      expect(find.byType(FloatingAppBarButton), findsNWidgets(2));
    } else {
      expect(find.byType(AdaptiveButton), findsNothing);
    }
    expect(ThemedSheets.hasActiveSheet, isTrue);
  });

  testWidgets(
    'root sheets remove persistent overlay chrome before presenting',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          home: Builder(
            builder: (context) => Scaffold(
              body: Column(
                children: [
                  ThemedSheets.hideNativeChromeWhileCovered(
                    child: const SizedBox(
                      key: ValueKey<String>('persistent-native-overlay'),
                      width: 40,
                      height: 40,
                    ),
                  ),
                  TextButton(
                    onPressed: () => ThemedSheets.showRoundedPage<void>(
                      context: context,
                      builder: (_) => const SizedBox.expand(),
                    ),
                    child: const Text('Open'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey<String>('persistent-native-overlay')),
        findsOneWidget,
      );

      await tester.tap(find.text('Open'));
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('persistent-native-overlay')),
        findsNothing,
      );
      expect(ThemedSheets.hasActiveSheet, isTrue);
    },
  );
}
