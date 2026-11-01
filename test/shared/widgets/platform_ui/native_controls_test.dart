import 'package:conduit/l10n/conduit_localizations.dart';
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
        host(SheetCloseButton(onPressed: () => closes++)),
      );
      final button = tester.widget<CNButton>(find.byType(CNButton));
      expect(button.icon?.name, 'xmark');
      expect(button.semanticLabel, 'Close');
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
