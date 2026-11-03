import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _openWebUi = AdaptiveFloatingTab(
  label: 'Open WebUI',
  icon: Icon(Icons.circle),
  nativeAsset: 'assets/icons/open_webui_tab.svg',
);
const _hermes = AdaptiveFloatingTab(
  label: 'Hermes',
  icon: Icon(Icons.square),
  nativeAsset: 'assets/icons/hermes_agent.png',
);

Widget _bar(List<AdaptiveFloatingTab> tabs) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.bottomCenter,
      child: AdaptiveFloatingTabBar(
        tabs: tabs,
        selectedIndex: 0,
        onTap: (_) {},
        action: AdaptiveFloatingBarAction(
          label: 'New Chat',
          icon: Icons.edit,
          sfSymbol: 'square.and.pencil',
          onPressed: () {},
        ),
        itemWidth: 72,
      ),
    ),
  ),
);

void main() {
  testWidgets('the native bar keeps its tabs while new icons render', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
    addTearDown(PlatformUiCapabilities.resetDebugOverrides);
    AdaptiveFloatingTabBar.debugIconRenderer = (_, asset, _, _) async =>
        Uint8List.fromList(asset.codeUnits);
    addTearDown(AdaptiveFloatingTabBar.debugReset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      (_) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        null,
      ),
    );

    List<Object?> labels() => [
      for (final tab
          in ((tester.widget<UiKitView>(find.byType(UiKitView)).creationParams
                      as Map)['tabs']
                  as List)
              .cast<Map>())
        tab['label'],
    ];

    await tester.pumpWidget(_bar(const []));
    await tester.pump();
    expect(labels(), isEmpty);

    // A second backend appears before its icons have rendered.
    await tester.pumpWidget(_bar(const [_openWebUi, _hermes]));
    expect(tester.takeException(), isNull);
    expect(find.byType(UiKitView), findsOneWidget);

    expect(labels(), isEmpty);

    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(labels(), ['Open WebUI', 'Hermes']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the Material bar leaves only the action for one backend', (
    tester,
  ) async {
    await tester.pumpWidget(_bar(const []));
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(FloatingActionButton), findsOneWidget);

    await tester.pumpWidget(_bar(const [_openWebUi, _hermes]));
    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar.destinations, hasLength(2));
    expect(bar.labelBehavior, NavigationDestinationLabelBehavior.alwaysHide);
    expect(
      tester.getCenter(find.byType(NavigationBar)).dx,
      lessThan(tester.getCenter(find.byType(FloatingActionButton)).dx),
    );
  });
}
