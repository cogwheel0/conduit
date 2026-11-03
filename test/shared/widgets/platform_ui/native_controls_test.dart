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
              widget is AdaptiveTooltip && widget.message == 'Add from catalog',
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
            expect(node.label, 'Add from catalog');
            expect(node.tooltip, isEmpty);
          } finally {
            semantics.dispose();
          }
        }
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer();
        await mouse.moveTo(tester.getCenter(tooltip));
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.text('Add from catalog'), findsOneWidget);
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
            semanticLabel: 'Add from catalog',
            onPressed: enabled ? () {} : null,
          ),
        ),
      );
      final button = tester.widget<CNButton>(find.byType(CNButton));
      expect(button.semanticLabel, 'Add from catalog');
      expect(button.enabled, enabled);
      expect(
        find.ancestor(
          of: find.byType(CNButton),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                widget.properties.label == 'Add from catalog',
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
    expect(action('Zoom in').style, AdaptiveButtonStyle.glass);
    expect(
      tester
          .widget<AdaptiveTooltip>(
            find.ancestor(
              of: find.byWidgetPredicate(
                (widget) =>
                    widget is AdaptiveButton &&
                    widget.semanticLabel == 'Zoom in',
              ),
              matching: find.byType(AdaptiveTooltip),
            ),
          )
          .excludeFromSemantics,
      isTrue,
    );
    action('Zoom in').onPressed!();
    await tester.pump();
    expect(
      controller.value.getMaxScaleOnAxis(),
      greaterThan(initial.getMaxScaleOnAxis()),
    );
    action('Reset diagram position').onPressed!();
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
    'floating media icons use native glass without changing inline defaults',
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
      expect(button.config.style, CNButtonStyle.glass);
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
}
