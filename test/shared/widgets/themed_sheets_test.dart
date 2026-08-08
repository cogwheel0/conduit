import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/utils/adaptive_glass.dart';
import 'package:conduit/shared/widgets/adaptive_toolbar_components.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/middle_ellipsis_text.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:checks/checks.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stupid_simple_sheet/stupid_simple_sheet.dart';

void main() {
  test('shared chrome uses the standard platform icon extent', () {
    check(IconSize.appBar).equals(24);
    check(IconSize.tabBar).equals(24);
    check(IconSize.large).equals(24);
    check(const SFSymbol('circle').size).equals(20);
    check(kConduitModelSelectorChevronExtent).equals(13);
  });

  testWidgets('model selector uses standard text and a compact chevron', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 25;
    PlatformUiCapabilities.debugNativeIOS26Override = false;
    addTearDown(PlatformUiCapabilities.resetDebugOverrides);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(
          TweakcnThemes.t3Chat,
        ).copyWith(platform: TargetPlatform.iOS),
        home: Scaffold(
          body: ConduitAdaptiveAppBarModelSelector(
            label: 'A model with a long standard title',
            maxWidth: 240,
            onPressed: () {},
          ),
        ),
      ),
    );

    final label = tester.widget<MiddleEllipsisText>(
      find.byType(MiddleEllipsisText),
    );
    check(label.style?.fontSize).equals(17);
    check(label.style?.fontWeight).equals(FontWeight.w400);
    final chevron = tester.widget<ConduitSystemAdaptiveIcon>(
      find.byType(ConduitSystemAdaptiveIcon),
    );
    check(chevron.size).equals(kConduitModelSelectorChevronExtent);
  });

  testWidgets('native model selector leaves typography to UIKit', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
    addTearDown(PlatformUiCapabilities.resetDebugOverrides);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(
          TweakcnThemes.t3Chat,
        ).copyWith(platform: TargetPlatform.iOS),
        home: Scaffold(
          body: ConduitAdaptiveAppBarModelSelector(
            label: 'Inkling',
            maxWidth: 240,
            onPressed: () {},
          ),
        ),
      ),
    );

    final button = tester.widget<CNButton>(find.byType(CNButton));
    check(button.icon?.size).equals(kConduitModelSelectorChevronExtent);
    check(button.config.labelFontSize).isNull();
    check(button.config.labelFontWeight).isNull();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 500));
  });

  test('toolbar icons preserve their SF Symbol lookup values', () {
    check(
      conduitToolbarSfSymbolForIcon(CupertinoIcons.line_horizontal_3),
    ).equals('line.3.horizontal');
    check(
      conduitToolbarSfSymbolForIcon(Icons.menu),
    ).equals('line.3.horizontal');
    check(
      conduitToolbarSfSymbolForIcon(CupertinoIcons.chevron_back),
    ).equals('chevron.left');
    check(
      conduitToolbarSfSymbolForIcon(CupertinoIcons.create),
    ).equals('square.and.pencil');
    check(
      conduitToolbarSfSymbolForIcon(CupertinoIcons.eye_slash),
    ).equals('eye.slash');
    check(
      conduitToolbarSfSymbolForIcon(Icons.people_outline),
    ).equals('person.2');
    check(
      conduitToolbarSfSymbolForIcon(Icons.circle, iosSymbol: 'ellipsis'),
    ).equals('ellipsis');
    check(conduitToolbarSfSymbolForIcon(Icons.delete)).isNull();
  });

  test('native model-selector labels remain on one line within their cap', () {
    const maxWidth = 198.0;
    final shortWidth = resolveConduitNativeModelSelectorWidth(
      label: 'Inkling',
      isLoading: false,
      showChevron: true,
      // Widget tests use the wide Ahem test font rather than UIKit's SF Pro.
      // Leave enough room here to exercise the untruncated branch itself.
      maxWidth: 400,
      textDirection: TextDirection.ltr,
    );
    final shortLabel = resolveConduitNativeModelSelectorLabel(
      label: 'Inkling',
      isLoading: false,
      showChevron: true,
      availableWidth: shortWidth,
      textDirection: TextDirection.ltr,
    );
    final longLabel = resolveConduitNativeModelSelectorLabel(
      label: 'google/gemma-4-31b-it',
      isLoading: false,
      showChevron: true,
      availableWidth: maxWidth,
      textDirection: TextDirection.ltr,
    );

    check(shortLabel).equals('Inkling');
    expect(shortWidth, lessThan(400));
    check(longLabel).contains('…');
    check(longLabel.contains('\n')).isFalse();
    check(longLabel.length).isLessThan('google/gemma-4-31b-it'.length);
    check(
      conduitNativeModelSelectorSymbol(showChevron: true),
    ).equals('chevron.down');
    check(conduitNativeModelSelectorSymbol(showChevron: false)).isNull();
  });

  test('native model-selector identity follows its foreground color', () {
    final lightKey = conduitNativeModelSelectorViewKey(Colors.black);
    final darkKey = conduitNativeModelSelectorViewKey(Colors.white);
    final largeTextKey = conduitNativeModelSelectorViewKey(
      Colors.black,
      titleFontSize: 34,
    );

    check(lightKey == darkKey).isFalse();
    check(lightKey == largeTextKey).isFalse();
    check(lightKey).equals(conduitNativeModelSelectorViewKey(Colors.black));
  });

  test('native model-selector parameters preserve the full label', () {
    final label = '${List.filled(5000, 'a').join()}-model-tail';
    final bounded = boundConduitNativeModelLabel(label);
    final params = encodeConduitNativeModelSelectorParams(
      label: label,
      symbolName: 'chevron.down',
      foregroundColor: Colors.black,
      titleFontSize: 17,
      enabled: true,
    );

    check(params['label']).equals(label);
    check(params['label'] == bounded).isFalse();
    check(params.containsKey('symbolSize')).isFalse();
  });

  test('native model-selector title follows Dynamic Type', () {
    check(
      resolveConduitNativeModelTitleFontSize(TextScaler.noScaling),
    ).equals(17);
    check(
      resolveConduitNativeModelTitleFontSize(const TextScaler.linear(2)),
    ).equals(34);
  });

  test('native model-selector semantics expose only valid activation', () {
    var activations = 0;
    void activate() => activations += 1;

    final enabled = conduitNativeModelSelectorActivation(
      isLoading: false,
      showChevron: true,
      onPressed: activate,
    );
    enabled!();

    check(activations).equals(1);
    check(
      conduitNativeModelSelectorActivation(
        isLoading: true,
        showChevron: true,
        onPressed: activate,
      ),
    ).isNull();
    check(
      conduitNativeModelSelectorActivation(
        isLoading: false,
        showChevron: false,
        onPressed: activate,
      ),
    ).isNull();
  });

  test('native model-selector bounds untrusted labels before layout', () {
    final oversized = '${List.filled(5000, 'a').join()}-model-tail';
    final bounded = boundConduitNativeModelLabel(oversized);

    check(bounded.length).isLessOrEqual(kConduitNativeModelLabelMaxCodeUnits);
    check(bounded).startsWith('aaa');
    check(bounded).contains('…');
    check(bounded).endsWith('-model-tail');
  });

  testWidgets('model-selector semantics preserve the full label', (
    tester,
  ) async {
    final label = '${List.filled(5000, 'a').join()}-model-tail';
    final bounded = boundConduitNativeModelLabel(label);
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConduitAdaptiveAppBarModelSelector(
            label: label,
            maxWidth: 198,
            onPressed: () {},
          ),
        ),
      ),
    );

    expect(find.bySemanticsLabel(label), findsOneWidget);
    expect(find.bySemanticsLabel(bounded), findsNothing);
    semantics.dispose();
  });

  test('native model-selector omits chevron width when hidden', () {
    final withChevron = resolveConduitNativeModelSelectorWidth(
      label: 'Inkling',
      isLoading: false,
      showChevron: true,
      maxWidth: 400,
      textDirection: TextDirection.ltr,
    );
    final withoutChevron = resolveConduitNativeModelSelectorWidth(
      label: 'Inkling',
      isLoading: false,
      showChevron: false,
      maxWidth: 400,
      textDirection: TextDirection.ltr,
    );

    check(withoutChevron).isLessThan(withChevron);
    check(
      resolveConduitNativeModelSelectorLabel(
        label: 'Inkling',
        isLoading: false,
        showChevron: false,
        availableWidth: withoutChevron,
        textDirection: TextDirection.ltr,
      ),
    ).equals('Inkling');
  });

  testWidgets('adaptive sheets use the iOS 26 glass route on iOS', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(
          TweakcnThemes.t3Chat,
        ).copyWith(platform: TargetPlatform.iOS),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => ThemedSheets.showAdaptive<void>(
                context: context,
                builder: (_) => const ConduitAdaptiveSheetSurface(
                  child: Text('Adaptive content'),
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

    final route = ModalRoute.of(tester.element(find.text('Adaptive content')));
    expect(route, isA<StupidSimpleGlassSheetRoute<void>>());
    final glassRoute = route! as StupidSimpleGlassSheetRoute<void>;
    final shape = glassRoute.shape as RoundedSuperellipseBorder;
    final context = tester.element(find.text('Adaptive content'));
    expect(shape.side.color, context.conduitTheme.dividerColor);
    expect(shape.side.width, BorderWidth.regular);
  });

  testWidgets('adaptive sheets use the plain package route off iOS', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(
          TweakcnThemes.t3Chat,
        ).copyWith(platform: TargetPlatform.android),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => ThemedSheets.showAdaptive<void>(
                context: context,
                builder: (_) => const ConduitAdaptiveSheetSurface(
                  child: Text('Adaptive content'),
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

    final route = ModalRoute.of(tester.element(find.text('Adaptive content')));
    expect(route, isA<StupidSimpleSheetRoute<void>>());
    expect(find.byType(SheetBackground), findsOneWidget);
    final contentContext = tester.element(find.text('Adaptive content'));
    expect(
      DefaultTextStyle.of(contentContext).style.decoration,
      TextDecoration.none,
      reason: 'The package popup route must not leak WidgetsApp debug text.',
    );
  });

  for (final entry in <TargetPlatform, double>{
    TargetPlatform.iOS: 36,
    TargetPlatform.android: 24,
  }.entries) {
    testWidgets(
      'reduced-motion adaptive sheets keep the ${entry.key.name} shape',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(
              TweakcnThemes.t3Chat,
            ).copyWith(platform: entry.key),
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(disableAnimations: true),
                child: Builder(
                  builder: (reducedMotionContext) => Scaffold(
                    body: TextButton(
                      onPressed: () => ThemedSheets.showAdaptive<void>(
                        context: reducedMotionContext,
                        builder: (_) => const ConduitAdaptiveSheetSurface(
                          child: Text('Reduced-motion content'),
                        ),
                      ),
                      child: const Text('Open'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();

        final bottomSheet = tester.widget<BottomSheet>(
          find.byType(BottomSheet),
        );
        final shape = bottomSheet.shape! as RoundedSuperellipseBorder;
        expect(
          shape.borderRadius.resolve(TextDirection.ltr).topLeft.x,
          entry.value,
        );
        final dismissBarrier = tester
            .widgetList<ModalBarrier>(find.byType(ModalBarrier))
            .firstWhere((barrier) => barrier.dismissible);
        expect(dismissBarrier.semanticsLabel, 'Dismiss');
      },
    );
  }

  testWidgets('adaptive surfaces can defer the bottom safe area to the route', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(402, 874);
    tester.view.padding = const FakeViewPadding(bottom: 34);
    tester.view.viewPadding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        home: const Scaffold(
          body: ConduitAdaptiveSheetSurface(
            bottomSafeArea: false,
            padding: EdgeInsets.zero,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                key: ValueKey<String>('bottom-aligned-action'),
                width: 120,
                height: TouchTarget.comfortable,
              ),
            ),
          ),
        ),
      ),
    );

    expect(
      tester
          .getBottomLeft(
            find.byKey(const ValueKey<String>('bottom-aligned-action')),
          )
          .dy,
      874,
    );
  });

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
    if (conduitSupportsNativeGlass()) {
      expect(
        find.descendant(of: header, matching: find.byType(AdaptiveButton)),
        findsOneWidget,
      );
    } else {
      final closeButton = find.descendant(
        of: header,
        matching: find.byType(IconButton),
      );
      expect(closeButton, findsOneWidget);
      expect(tester.getSize(closeButton), const Size.square(36));
    }
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
      expect(find.byType(FloatingAppBarButton), findsNWidgets(2));
    } else {
      expect(find.byType(AdaptiveButton), findsNWidgets(2));
      expect(find.byType(FloatingAppBarButton), findsNothing);
    }

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    if (usesOpaqueFallback) {
      expect(find.byType(FloatingAppBarButton), findsNWidgets(2));
    } else {
      expect(find.byType(AdaptiveButton), findsNothing);
    }
    expect(ThemedSheets.hasActiveSheet, isTrue);
  });

  testWidgets(
    'chat navigation chrome restores and follows enlarged system text scaling',
    (tester) async {
      const systemTextScaler = TextScaler.linear(3);
      late double observedTextSize;
      late bool observedBoldText;

      final navigationBar = ConduitAdaptiveCupertinoNavigationBar(
        textScaler: systemTextScaler,
        leading: Builder(
          builder: (context) {
            observedTextSize = MediaQuery.textScalerOf(context).scale(17);
            observedBoldText = MediaQuery.boldTextOf(context);
            return const ConduitAdaptiveAppBarIconButton(
              key: ValueKey<String>('scaled-toolbar-button'),
              icon: Icons.menu,
              onPressed: null,
            );
          },
        ),
      );

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            textScaler: systemTextScaler,
            boldText: true,
          ),
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            home: CupertinoPageScaffold(
              navigationBar: navigationBar,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

      check(resolveConduitSystemControlScale(TextScaler.noScaling)).equals(1);
      check(
        resolveConduitSystemControlScale(systemTextScaler),
      ).equals(kConduitMaximumSystemControlScale);
      check(navigationBar.preferredSize.height).equals(72);
      check(observedTextSize).equals(51);
      check(observedBoldText).isTrue();
      check(
        tester.getSize(
          find.byKey(const ValueKey<String>('scaled-toolbar-button')),
        ),
      ).equals(const Size.square(66));
      final icon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const ValueKey<String>('scaled-toolbar-button')),
          matching: find.byType(Icon),
        ),
      );
      check(icon.shadows).isNotNull().isNotEmpty();
    },
  );

  testWidgets('centered route chrome keeps the title in the middle slot', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        home: Builder(
          builder: (context) {
            final adaptiveAppBar = buildConduitCenteredAdaptiveAppBar(
              context: context,
              tintColor: Colors.black,
              leading: const SizedBox.square(
                key: ValueKey<String>('centered-leading'),
                dimension: TouchTarget.minimum,
              ),
              title: const SizedBox(
                key: ValueKey<String>('centered-title'),
                width: 120,
                height: TouchTarget.minimum,
              ),
              actions: const [
                SizedBox.square(
                  key: ValueKey<String>('centered-action'),
                  dimension: TouchTarget.minimum,
                ),
              ],
            );
            return Scaffold(
              appBar: adaptiveAppBar.appBar,
              body: const SizedBox.expand(),
            );
          },
        ),
      ),
    );

    final appBar = tester.widget<AppBar>(find.byType(AppBar));
    check(appBar.centerTitle).equals(true);
    expect(
      find.descendant(
        of: find.byWidget(appBar.title!),
        matching: find.byKey(const ValueKey<String>('centered-title')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byWidget(appBar.leading!),
        matching: find.byKey(const ValueKey<String>('centered-leading')),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Cupertino route chrome centers without overlapping actions', (
    tester,
  ) async {
    const titleKey = ValueKey<String>('cupertino-centered-title');
    const trailingKey = ValueKey<String>('cupertino-centered-trailing');
    await tester.pumpWidget(
      const CupertinoApp(
        home: CupertinoPageScaffold(
          navigationBar: ConduitAdaptiveCupertinoNavigationBar(
            textScaler: TextScaler.noScaling,
            leading: SizedBox.square(dimension: TouchTarget.minimum),
            middle: SizedBox(
              key: titleKey,
              width: 140,
              height: TouchTarget.minimum,
            ),
            trailing: SizedBox(
              key: trailingKey,
              width: 96,
              height: TouchTarget.minimum,
            ),
          ),
          child: SizedBox.expand(),
        ),
      ),
    );

    final titleRect = tester.getRect(find.byKey(titleKey));
    final trailingRect = tester.getRect(find.byKey(trailingKey));
    expect(titleRect.right + Spacing.sm, lessThanOrEqualTo(trailingRect.left));
    final viewportWidth =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect(titleRect.center.dx, closeTo(viewportWidth / 2, 45));
  });

  testWidgets('Cupertino route chrome can lead-align an interactive title', (
    tester,
  ) async {
    const titleKey = ValueKey<String>('cupertino-leading-title');
    const trailingKey = ValueKey<String>('cupertino-leading-trailing');
    await tester.pumpWidget(
      const CupertinoApp(
        home: CupertinoPageScaffold(
          navigationBar: ConduitAdaptiveCupertinoNavigationBar(
            textScaler: TextScaler.noScaling,
            centerMiddle: false,
            leading: SizedBox.square(dimension: TouchTarget.minimum),
            middle: SizedBox(
              key: titleKey,
              width: 260,
              height: TouchTarget.minimum,
            ),
            trailing: SizedBox(
              key: trailingKey,
              width: 96,
              height: TouchTarget.minimum,
            ),
          ),
          child: SizedBox.expand(),
        ),
      ),
    );

    final titleRect = tester.getRect(find.byKey(titleKey));
    final trailingRect = tester.getRect(find.byKey(trailingKey));
    final viewportWidth =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect(titleRect.center.dx, lessThan(viewportWidth / 2));
    expect(titleRect.right + Spacing.sm, lessThanOrEqualTo(trailingRect.left));
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
