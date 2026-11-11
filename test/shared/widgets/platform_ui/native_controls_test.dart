import 'dart:ui' show PointerDeviceKind;

import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/features/hermes/views/hermes_mcp_page.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit/features/terminal/widgets/terminal_section_components.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/markdown/markdown_config.dart';
import 'package:conduit/shared/widgets/adaptive_toolbar_components.dart';
import 'package:conduit/shared/widgets/legacy_design_compatibility.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/themed_sheets.dart';
import 'package:cupertino_native_better/cupertino_native_better.dart'
    show
        CNIcon,
        CNProgressIndicator,
        CNSliderStyle,
        CNSymbolEffectType,
        CNSymbolReplaceTransition;
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../support/native_platform_views.dart';

void main() {
  setUp(() {
    stubNativePlatformViews();
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 27;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
  });
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  Widget host(Widget child) => ProviderScope(
    child: MaterialApp(
      localizationsDelegates: conduitLocalizationsDelegates,
      builder: (context, child) => LegacyDesignCompatibility(child: child!),
      home: Scaffold(
        body: Material(
          type: MaterialType.transparency,
          child: Center(child: child),
        ),
      ),
    ),
  );

  for (final iosMajorVersion in <int?>[27, 25, null]) {
    testWidgets(
      'catalog action retains its tooltip on ${iosMajorVersion == null ? 'Android' : 'iOS $iosMajorVersion'}',
      (tester) async {
        PlatformUiCapabilities.debugPlatformOverride = iosMajorVersion == null
            ? TargetPlatform.android
            : TargetPlatform.iOS;
        PlatformUiCapabilities.debugIOSMajorVersionOverride = iosMajorVersion;
        await tester.pumpWidget(
          host(
            ProviderScope(
              overrides: [hermesApiServiceProvider.overrideWithValue(null)],
              child: const HermesMcpPage(),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        final tooltip = find.byWidgetPredicate(
          (widget) =>
              widget is AdaptiveTooltip && widget.message == 'Add from Catalog',
        );
        expect(tooltip, findsOneWidget);
        expect(
          tester.widget<AdaptiveTooltip>(tooltip).excludeFromSemantics,
          isTrue,
        );
        if (iosMajorVersion != 27) {
          final semantics = tester.ensureSemantics();
          try {
            await tester.pump();
            final node = tester.getSemantics(
              find.byType(ConduitAdaptiveAppBarIconButton),
            );
            expect(node.label, 'Add from Catalog');
            expect(node.tooltip, isEmpty);
          } finally {
            semantics.dispose();
          }
        }
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer();
        await mouse.moveTo(tester.getCenter(tooltip));
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.text('Add from Catalog'), findsOneWidget);
        await mouse.removePointer();
        await tester.pumpAndSettle();
      },
    );
  }

  for (final enabled in [true, false]) {
    testWidgets('toolbar icon has one native label when enabled=$enabled', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          ConduitAdaptiveAppBarIconButton(
            icon: Icons.auto_awesome_outlined,
            iosSymbol: 'sparkles',
            semanticLabel: 'Add from Catalog',
            onPressed: enabled ? () {} : null,
          ),
        ),
      );
      final button = tester.widget<CNButton>(find.byType(CNButton));
      expect(button.semanticLabel, 'Add from Catalog');
      expect(button.enabled, enabled);
      expect(
        find.ancestor(
          of: find.byType(CNButton),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                widget.properties.label == 'Add from Catalog',
          ),
        ),
        findsNothing,
      );
      await tester.pump(const Duration(milliseconds: 500));
    });
  }

  testWidgets('iOS progress retains its unconstrained design size', (
    tester,
  ) async {
    for (final value in <double?>[null, 0.4]) {
      await tester.pumpWidget(host(AdaptiveProgressIndicator(value: value)));
      expect(
        tester.getSize(find.byType(AdaptiveProgressIndicator)),
        const Size(36, 36),
      );
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('iOS progress preserves bounds, color and accessible progress', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      host(
        const SizedBox.square(
          dimension: 16,
          child: AdaptiveProgressIndicator(
            value: 0.4,
            color: CupertinoColors.systemRed,
            semanticLabel: 'Exporting sketch',
          ),
        ),
      ),
    );
    final spinner = tester.widget<CupertinoActivityIndicator>(
      find.byType(CupertinoActivityIndicator),
    );
    expect(spinner.color, CupertinoColors.systemRed);
    expect(spinner.progress, 0.4);
    expect(
      tester.getSize(find.byType(AdaptiveProgressIndicator)),
      const Size(16, 16),
    );
    expect(find.bySemanticsLabel('Exporting sketch'), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Exporting sketch')).value,
      '40%',
    );
    semantics.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('iOS 26 linear progress is native only with a known value', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      host(
        const SizedBox(
          width: 200,
          child: AdaptiveProgressIndicator.linear(
            value: 0.4,
            color: CupertinoColors.systemRed,
            minHeight: 2,
            semanticLabel: 'Listening',
          ),
        ),
      ),
    );
    final bar = tester.widget<CNProgressIndicator>(
      find.byType(CNProgressIndicator),
    );
    expect((bar.value, bar.tint), (0.4, CupertinoColors.systemRed));
    expect(
      tester.getSemantics(find.bySemanticsLabel('Listening')).value,
      '40%',
    );
    // UIKit has no indeterminate bar and no track colour: those stay Flutter.
    for (final flutterBar in const [
      AdaptiveProgressIndicator.linear(minHeight: 2),
      AdaptiveProgressIndicator.linear(
        value: 0.4,
        backgroundColor: CupertinoColors.systemGrey,
      ),
    ]) {
      await tester.pumpWidget(host(SizedBox(width: 200, child: flutterBar)));
      expect(find.byType(CNProgressIndicator), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    }
    semantics.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('iOS 26 sliders mark each step only when the steps are few', (
    tester,
  ) async {
    for (final (divisions, ticks) in <(int?, int?)>[
      (4, 5),
      (12, 13),
      (13, null),
      (47, null),
      (null, null),
    ]) {
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 300,
            child: AdaptiveSlider(
              value: 0,
              divisions: divisions,
              onChanged: (_) {},
            ),
          ),
        ),
      );
      expect(
        tester.widget<CNSlider>(find.byType(CNSlider)).numberOfTicks,
        ticks,
        reason: 'divisions: $divisions',
      );
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('iOS 26 media scrubbers use the thumbless system slider', (
    tester,
  ) async {
    for (final thumbless in [true, false]) {
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 300,
            child: AdaptiveSlider(
              value: 0.3,
              thumbless: thumbless,
              onChanged: (_) {},
            ),
          ),
        ),
      );
      expect(
        tester.widget<CNSlider>(find.byType(CNSlider)).style,
        thumbless ? CNSliderStyle.thumbless : CNSliderStyle.standard,
      );
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('an iOS 26 slider reports only a touch that changes its value', (
    tester,
  ) async {
    final reports = <String>[];
    await tester.pumpWidget(
      host(
        SizedBox(
          width: 300,
          child: AdaptiveSlider(
            value: 0.3,
            onChangeStart: (value) => reports.add('start:$value'),
            onChanged: (value) => reports.add('change:$value'),
            onChangeEnd: (value) => reports.add('end:$value'),
          ),
        ),
      ),
    );
    CNSlider slider() => tester.widget<CNSlider>(find.byType(CNSlider));
    // UIKit reports the start and end of a touch that moved nothing.
    slider().onChangeStart!(0.3);
    slider().onChangeEnd!(0.3);
    expect(reports, isEmpty);

    slider().onChangeStart!(0.3);
    slider().onChanged(0.6);
    slider().onChanged(0.7);
    slider().onChangeEnd!(0.7);
    expect(reports, ['start:0.3', 'change:0.6', 'change:0.7', 'end:0.7']);

    // VoiceOver adjusts it without a touch.
    reports.clear();
    slider().onChanged(0.8);
    expect(reports, ['change:0.8']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('an iOS 26 slider leaves a tap to seek to the system slider', (
    tester,
  ) async {
    for (final seekOnTap in [true, false]) {
      final reports = <String>[];
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 300,
            child: AdaptiveSlider(
              value: 0,
              seekOnTap: seekOnTap,
              onChangeStart: (value) => reports.add('start:$value'),
              onChanged: (value) => reports.add('change:$value'),
              onChangeEnd: (value) => reports.add('end:$value'),
            ),
          ),
        ),
      );
      expect(
        tester.widget<CNSlider>(find.byType(CNSlider)).seekOnTap,
        seekOnTap,
      );
      // The system slider reports the tap itself; seeking here as well
      // would seek twice.
      final track = tester.getRect(find.byType(AdaptiveSlider));
      await tester.tapAt(
        Offset(track.left + track.width * .68, track.center.dy),
      );
      await tester.pump();
      expect(reports, isEmpty, reason: 'seekOnTap: $seekOnTap');
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  for (final direction in TextDirection.values) {
    testWidgets('before iOS 26 a tap anywhere on a slider that seeks on tap '
        'moves it there, onto a step (${direction.name})', (tester) async {
      PlatformUiCapabilities.debugIOSMajorVersionOverride = 18;
      PlatformUiCapabilities.debugNativeIOS26Override = false;
      final reports = <String>[];
      await tester.pumpWidget(
        host(
          Directionality(
            textDirection: direction,
            child: SizedBox(
              width: 300,
              child: AdaptiveSlider(
                value: 0,
                max: 10,
                divisions: 10,
                seekOnTap: true,
                onChangeStart: (value) => reports.add('start:$value'),
                onChanged: (value) => reports.add('change:$value'),
                onChangeEnd: (value) => reports.add('end:$value'),
              ),
            ),
          ),
        ),
      );
      // Far from the thumb, at the start, where the Cupertino slider would
      // not answer.
      final track = tester.getRect(find.byType(AdaptiveSlider));
      final along = direction == TextDirection.ltr ? .68 : .32;
      await tester.tapAt(
        Offset(track.left + track.width * along, track.center.dy),
      );
      await tester.pump();
      expect(reports, ['start:0.0', 'change:7.0', 'end:7.0']);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  }

  testWidgets('before iOS 26 a tap on the thumb at the maximum stays there', (
    tester,
  ) async {
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 18;
    PlatformUiCapabilities.debugNativeIOS26Override = false;
    final reports = <String>[];
    await tester.pumpWidget(
      host(
        SizedBox(
          width: 300,
          child: AdaptiveSlider(
            value: 1,
            seekOnTap: true,
            onChanged: (value) => reports.add('change:$value'),
          ),
        ),
      ),
    );
    // The thumb's centre stays 22 points in from the end of the slider.
    final track = tester.getRect(find.byType(AdaptiveSlider));
    await tester.tapAt(Offset(track.right - 22, track.center.dy));
    expect(reports, ['change:1.0']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('before iOS 26 a press on the thumb that does not move ends '
      'once, as a tap', (tester) async {
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 18;
    PlatformUiCapabilities.debugNativeIOS26Override = false;
    final reports = <String>[];
    await tester.pumpWidget(
      host(
        SizedBox(
          width: 300,
          child: AdaptiveSlider(
            value: 0.5,
            seekOnTap: true,
            onChangeStart: (value) => reports.add('start:$value'),
            onChanged: (value) => reports.add('change:$value'),
            onChangeEnd: (value) => reports.add('end:$value'),
          ),
        ),
      ),
    );
    // The Cupertino slider takes a press on its thumb as a drag at once,
    // and ends it with the value it started from.
    await tester.tapAt(tester.getCenter(find.byType(AdaptiveSlider)));
    expect(reports, ['start:0.5', 'change:0.5', 'end:0.5']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('before iOS 26 a short mouse drag is the slider\'s, not also a '
      'tap', (tester) async {
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 18;
    PlatformUiCapabilities.debugNativeIOS26Override = false;
    final changes = <double>[];
    final ends = <double>[];
    await tester.pumpWidget(
      host(
        SizedBox(
          width: 300,
          child: AdaptiveSlider(
            value: 0.5,
            seekOnTap: true,
            onChanged: changes.add,
            onChangeEnd: ends.add,
          ),
        ),
      ),
    );
    // A mouse drags sooner than a finger: well within a touch's slop.
    final pointer = await tester.startGesture(
      tester.getCenter(find.byType(AdaptiveSlider)),
      kind: PointerDeviceKind.mouse,
    );
    await pointer.moveBy(const Offset(8, 0));
    await tester.pump();
    await pointer.up();
    expect(changes, isNotEmpty);
    expect(ends, [changes.last]);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('before iOS 26 a drag that comes back near its start is not '
      'also a tap', (tester) async {
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 18;
    PlatformUiCapabilities.debugNativeIOS26Override = false;
    final ends = <double>[];
    await tester.pumpWidget(
      host(
        SizedBox(
          width: 300,
          child: AdaptiveSlider(
            value: 0.5,
            seekOnTap: true,
            onChanged: (_) {},
            onChangeEnd: ends.add,
          ),
        ),
      ),
    );
    // From the thumb, halfway along, out and nearly back.
    final track = tester.getRect(find.byType(AdaptiveSlider));
    final finger = await tester.startGesture(track.center);
    await finger.moveBy(const Offset(60, 0));
    await tester.pump();
    await finger.moveBy(const Offset(-55, 0));
    await tester.pump();
    await finger.up();
    expect(ends, hasLength(1));
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  for (final native in [true, false]) {
    testWidgets('segmented controls carry their field name (native: $native)', (
      tester,
    ) async {
      PlatformUiCapabilities.debugIOSMajorVersionOverride = native ? 27 : 18;
      PlatformUiCapabilities.debugNativeIOS26Override = native;
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        host(
          SizedBox(
            width: 240,
            child: AdaptiveSegmentedControl(
              labels: const ['Edit', 'Preview'],
              selectedIndex: 0,
              onValueChanged: (_) {},
              semanticLabel: 'Sketch content',
            ),
          ),
        ),
      );
      if (native) {
        // UIKit reads it; the native view's own tree is outside Flutter's.
        expect(
          tester
              .widget<CNSegmentedControl>(find.byType(CNSegmentedControl))
              .semanticLabel,
          'Sketch content',
        );
      } else {
        expect(find.bySemanticsLabel('Sketch content'), findsOneWidget);
      }
      semantics.dispose();
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  }

  testWidgets('diagram glass controls retain zoom, reset and pan locking', (
    tester,
  ) async {
    const diagram = MermaidRenderResult(
      svg: '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"><rect width="200" height="100" fill="blue"/></svg>',
      sceneSize: Size(200, 100),
    );
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => ConduitMarkdown.showMermaidPreviewSheet(
              context,
              light: diagram,
              dark: diagram,
            ),
            child: const Text('Preview sketch'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Preview sketch'));
    await tester.pumpAndSettle();
    AdaptiveButton action(String label) => tester.widget<AdaptiveButton>(
      find.byWidgetPredicate(
        (widget) => widget is AdaptiveButton && widget.semanticLabel == label,
      ),
    );
    final controller = tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!;
    final initial = Matrix4.copy(controller.value);
    expect(action('Zoom In').style, AdaptiveButtonStyle.glass);
    expect(
      tester
          .widget<AdaptiveTooltip>(
            find.ancestor(
              of: find.byWidgetPredicate(
                (widget) =>
                    widget is AdaptiveButton &&
                    widget.semanticLabel == 'Zoom In',
              ),
              matching: find.byType(AdaptiveTooltip),
            ),
          )
          .excludeFromSemantics,
      isTrue,
    );
    action('Zoom In').onPressed!();
    await tester.pump();
    expect(
      controller.value.getMaxScaleOnAxis(),
      greaterThan(initial.getMaxScaleOnAxis()),
    );
    action('Reset Diagram Position').onPressed!();
    await tester.pump();
    expect(controller.value.storage, orderedEquals(initial.storage));
    expect(
      action('Lock pan and zoom').style,
      AdaptiveButtonStyle.prominentGlass,
    );
    action('Lock pan and zoom').onPressed!();
    await tester.pump();
    expect(
      tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .panEnabled,
      isFalse,
    );
    expect(action('Enable pan and zoom').style, AdaptiveButtonStyle.glass);
    await tester.pump(const Duration(milliseconds: 500));
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('toolbar title actions retain busy and disabled behavior', (
    tester,
  ) async {
    var saves = 0;
    await tester.pumpWidget(
      host(
        ConduitAdaptiveAppBarTextButton(
          label: 'Save sketch',
          onPressed: () => saves++,
          prominent: true,
        ),
      ),
    );
    final button = tester.widget<CNButton>(find.byType(CNButton));
    expect(button.label, 'Save sketch');
    expect(button.config.style, CNButtonStyle.prominentGlass);
    button.onPressed!();
    expect(saves, 1);
    await tester.pumpWidget(
      host(
        ConduitAdaptiveAppBarTextButton(
          label: 'Save sketch',
          onPressed: () => saves++,
          isLoading: true,
        ),
      ),
    );
    expect(find.byType(CNButton), findsNothing);
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
    expect(find.byType(AdaptiveGlassBackdrop), findsOneWidget);
    expect(saves, 1);
    await tester.pump(const Duration(milliseconds: 500));
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('older iOS toolbar actions show their disabled state', (
    tester,
  ) async {
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 25;
    PlatformUiCapabilities.debugNativeIOS26Override = false;
    await tester.pumpWidget(
      host(
        const ConduitAdaptiveAppBarTextButton(
          label: 'Save sketch',
          onPressed: null,
        ),
      ),
    );
    final text = tester.widget<Text>(find.text('Save sketch'));
    final context = tester.element(
      find.byType(ConduitAdaptiveAppBarTextButton),
    );
    expect(text.style?.color, context.conduitTheme.buttonDisabledText);
    expect(
      tester.widget<CupertinoButton>(find.byType(CupertinoButton)).onPressed,
      isNull,
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('default toolbar labels retain Flutter text scaling', (
    tester,
  ) async {
    for (final scale in [1.0, 2.0]) {
      await tester.pumpWidget(
        host(
          MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: ConduitAdaptiveAppBarTextButton(
              label: 'Save sketch',
              onPressed: () {},
            ),
          ),
        ),
      );
      final button = tester.widget<CNButton>(find.byType(CNButton));
      // Match the Cupertino fallback's standard 17-point label at each scale.
      expect(button.config.labelFontSize, 17 * scale);
      expect(button.config.labelFontFamily, isNull);
      expect(button.config.minHeight, TouchTarget.minimum);
      await tester.pump(const Duration(milliseconds: 500));
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('terminal actions give UIKit one localized accessible label', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        TerminalIconActionButton(
          tooltip: 'Open sketch',
          iosIcon: CupertinoIcons.folder,
          materialIcon: Icons.folder,
          onPressed: () {},
        ),
      ),
    );
    expect(
      tester.widget<CNButton>(find.byType(CNButton)).semanticLabel,
      'Open sketch',
    );
    expect(
      tester
          .widget<AdaptiveTooltip>(find.byType(AdaptiveTooltip))
          .excludeFromSemantics,
      isTrue,
    );
    await tester.pump(const Duration(milliseconds: 500));
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets(
    'native icon foreground remains independent from prominent glass tint',
    (tester) async {
      await tester.pumpWidget(
        host(
          AdaptiveButton.icon(
            icon: Icons.arrow_upward,
            iconColor: CupertinoColors.white,
            color: CupertinoColors.activeBlue,
            style: AdaptiveButtonStyle.prominentGlass,
            onPressed: () {},
          ),
        ),
      );
      final button = tester.widget<CNButton>(find.byType(CNButton));
      expect(button.icon?.name, 'arrow.up');
      expect(button.icon?.color, CupertinoColors.white);
      expect(button.tint, CupertinoColors.activeBlue);
      await tester.pump(const Duration(milliseconds: 500));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'sheet close uses a native symbol within its existing touch target',
    (tester) async {
      var closes = 0;
      await tester.pumpWidget(
        host(
          SheetCloseButton(tooltip: 'Close sketch', onPressed: () => closes++),
        ),
      );
      final button = tester.widget<CNButton>(find.byType(CNButton));
      expect(button.icon?.name, 'xmark');
      expect(button.semanticLabel, 'Close sketch');
      expect(
        tester.widget<Tooltip>(find.byType(Tooltip)).excludeFromSemantics,
        isTrue,
      );
      expect(
        tester.getSize(find.byType(SheetCloseButton)),
        const Size.square(44),
      );
      button.onPressed!();
      expect(closes, 1);
      await tester.pump(const Duration(milliseconds: 500));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'native icon labels retain text scaling and existing button geometry',
    (tester) async {
      await tester.pumpWidget(
        host(
          MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: ConduitButton(
              text: 'Add sketch',
              icon: Icons.add,
              // Linux lays out the SDK fallback using the wider Ahem test font.
              width: 480,
              onPressed: () {},
            ),
          ),
        ),
      );
      final button = tester.widget<CNButton>(find.byType(CNButton));
      expect(button.config.labelFontSize, AppTypography.standard.fontSize! * 2);
      expect(button.config.imagePadding, 8);
      expect(
        tester.getSize(find.byType(ConduitButton)),
        const Size(480, TouchTarget.comfortable),
      );
      await tester.pump(const Duration(milliseconds: 500));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'labelled actions use native glass while inline icons retain Cupertino rendering',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        host(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConduitButton(
                text: 'Add sketch',
                icon: Icons.add,
                // The Linux SDK fallback uses the wider Ahem test font.
                width: 320,
                onPressed: () => taps++,
              ),
              ConduitIconButton(
                icon: Icons.share,
                tooltip: 'Share sketch',
                onPressed: () => taps++,
              ),
              const ConduitIconButton(
                icon: Icons.close,
                tooltip: 'Unavailable close',
              ),
              ConduitIconButton(
                icon: Icons.edit,
                tooltip: 'Selected edit',
                isActive: true,
                onPressed: () {},
              ),
            ],
          ),
        ),
      );
      final button = tester.widget<CNButton>(find.byType(CNButton));
      expect(button.label, 'Add sketch');
      expect(button.icon!.name, 'plus');
      expect(button.config.style, CNButtonStyle.prominentGlass);
      expect(button.config.minHeight, TouchTarget.comfortable);
      // These content actions have no glass surface and create no platform views.
      expect(find.byType(CupertinoButton), findsNWidgets(3));
      button.onPressed!();
      await tester.tap(find.byTooltip('Share sketch'));
      expect(taps, 2);
      await tester.pump(const Duration(milliseconds: 500));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'floating media icons use clear glass without changing inline defaults',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        host(
          ConduitIconButton(
            icon: Icons.close_rounded,
            tooltip: 'Close preview',
            useGlass: true,
            onPressed: () => taps++,
          ),
        ),
      );
      final button = tester.widget<CNButton>(find.byType(CNButton));
      expect(button.icon!.name, 'xmark');
      expect(button.semanticLabel, 'Close preview');
      // UIKit owns this name; Flutter must not add another labelled ancestor.
      expect(
        find.ancestor(
          of: find.byType(CNButton),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                (widget.properties.label == 'Close preview' ||
                    widget.properties.tooltip == 'Close preview'),
          ),
        ),
        findsNothing,
      );
      // Clear glass lets the photo or video behind it through.
      expect(button.config.style, CNButtonStyle.clearGlass);
      expect(
        tester.getSize(find.byType(ConduitIconButton)),
        Size.square(TouchTarget.comfortable),
      );
      button.onPressed!();
      expect(taps, 1);
      await tester.pump(const Duration(milliseconds: 500));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  for (final (name, iosMajorVersion, reduceMotion) in <(String, int?, bool)>[
    ('iOS 26', 26, false),
    ('iOS 26 with Reduce Motion', 26, true),
    ('iOS 25', 25, false),
    ('Android', null, false),
  ]) {
    testWidgets(
      'symbol icon on $name keeps its label and animates only natively',
      (tester) async {
        PlatformUiCapabilities.debugPlatformOverride = iosMajorVersion == null
            ? TargetPlatform.android
            : TargetPlatform.iOS;
        PlatformUiCapabilities.debugIOSMajorVersionOverride = iosMajorVersion;
        final semantics = tester.ensureSemantics();
        try {
          await tester.pumpWidget(
            host(
              MediaQuery(
                data: MediaQueryData(disableAnimations: reduceMotion),
                child: const AdaptiveSymbolIcon(
                  symbol: 'speaker.wave.3.fill',
                  fallbackIcon: CupertinoIcons.speaker_3_fill,
                  size: 20,
                  color: Color(0xFF336699),
                  semanticLabel: 'Speaker off',
                  effect: AdaptiveSymbolEffect.variableColor,
                  transition: AdaptiveSymbolTransition.replace,
                ),
              ),
            ),
          );

          expect(
            tester.getSemantics(find.byType(AdaptiveSymbolIcon)).label,
            'Speaker off',
          );
          if (iosMajorVersion != null && iosMajorVersion >= 26) {
            final icon = tester.widget<CNIcon>(find.byType(CNIcon));
            expect(icon.symbol!.name, 'speaker.wave.3.fill');
            expect(icon.size, 20);
            expect(icon.color, const Color(0xFF336699));
            // Reduce Motion keeps the symbol and drops every animation.
            expect(
              icon.effect?.type,
              reduceMotion ? isNull : CNSymbolEffectType.variableColor,
            );
            expect(
              icon.replaceTransition,
              reduceMotion ? isNull : CNSymbolReplaceTransition.replace,
            );
          } else {
            expect(find.byType(CNIcon), findsNothing);
            expect(find.byIcon(CupertinoIcons.speaker_3_fill), findsOneWidget);
          }
        } finally {
          semantics.dispose();
        }
        await tester.pump(const Duration(milliseconds: 500));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }
}
