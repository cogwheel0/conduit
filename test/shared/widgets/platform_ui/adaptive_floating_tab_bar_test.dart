import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _openWebUi = AdaptiveFloatingTab(
  label: 'Open WebUI',
  icon: Icon(Icons.circle),
  nativeAsset: 'assets/icons/open_webui_tab.png',
);
const _hermes = AdaptiveFloatingTab(
  label: 'Hermes',
  icon: Icon(Icons.square),
  nativeAsset: 'assets/icons/hermes_agent.png',
);

Widget _bar(
  List<AdaptiveFloatingTab> tabs, {
  Color? tint,
  AssetBundle? bundle,
}) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.bottomCenter,
      child: AdaptiveFloatingTabBar(
        tabs: tabs,
        selectedIndex: 0,
        selectedItemColor: tint,
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
  builder: bundle == null
      ? null
      : (context, child) => DefaultAssetBundle(bundle: bundle, child: child!),
);

/// Mocks the native bar's view and records the configuration each created
/// view is given, first at creation and then through updates.
List<Map<Object?, Object?>> _recordNativeBar(WidgetTester tester) {
  PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
  PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
  PlatformUiCapabilities.debugNativeIOS26Override = true;
  addTearDown(PlatformUiCapabilities.resetDebugOverrides);
  addTearDown(AdaptiveFloatingTabBar.debugReset);
  final configurations = <Map<Object?, Object?>>[];
  final channels = <MethodChannel>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
    call,
  ) async {
    if (call.method == 'create') {
      final arguments = call.arguments as Map;
      final params = arguments['params'];
      if (params is Uint8List) {
        configurations.add(
          const StandardMessageCodec().decodeMessage(ByteData.sublistView(params))
              as Map<Object?, Object?>,
        );
      }
      final channel = MethodChannel(
        '${arguments['viewType']}_${arguments['id']}',
      );
      channels.add(channel);
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'update') {
          configurations.add(call.arguments as Map<Object?, Object?>);
        }
        return null;
      });
    }
    return null;
  });
  addTearDown(() {
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    for (final channel in channels) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
  return configurations;
}

class _NamedBundle extends CachingAssetBundle {
  _NamedBundle(this.name);

  final String name;

  @override
  Future<ByteData> load(String key) async => ByteData(0);
}

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
    // Updates the created native view receives, by tab labels.
    final updates = <List<Object?>>[];
    final viewChannels = <MethodChannel>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      if (call.method == 'create') {
        final arguments = call.arguments as Map;
        final channel = MethodChannel(
          '${arguments['viewType']}_${arguments['id']}',
        );
        viewChannels.add(channel);
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'update') {
            updates.add([
              for (final tab
                  in ((call.arguments as Map)['tabs'] as List).cast<Map>())
                tab['label'],
            ]);
          }
          return null;
        });
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
      for (final channel in viewChannels) {
        messenger.setMockMethodCallHandler(channel, null);
      }
    });

    await tester.pumpWidget(_bar(const []));
    await tester.pumpAndSettle();
    expect(viewChannels, hasLength(1));
    final created = updates.length;

    // A second backend appears before its icons have rendered.
    await tester.pumpWidget(_bar(const [_openWebUi, _hermes]));
    expect(tester.takeException(), isNull);
    expect(find.byType(UiKitView), findsOneWidget);
    expect(updates.skip(created), isEmpty);

    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(viewChannels, hasLength(1));
    expect(updates.skip(created), [
      ['Open WebUI', 'Hermes'],
    ]);
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
  testWidgets('clearing a tint tells the native bar to restore its own', (
    tester,
  ) async {
    final configurations = _recordNativeBar(tester);
    AdaptiveFloatingTabBar.debugIconRenderer = (_, asset, _, _) async =>
        Uint8List.fromList(asset.codeUnits);
    const red = Color(0xFFFF0000);
    await tester.pumpWidget(_bar(const [_openWebUi, _hermes], tint: red));
    await tester.pumpAndSettle();
    expect(configurations.last['tint'], red.toARGB32());

    await tester.pumpWidget(_bar(const [_openWebUi, _hermes]));
    await tester.pumpAndSettle();
    expect(configurations.last.containsKey('tint'), isTrue);
    expect(configurations.last['tint'], isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('icons are rendered from the bar\'s own asset bundle', (
    tester,
  ) async {
    final configurations = _recordNativeBar(tester);
    AdaptiveFloatingTabBar.debugIconRenderer = (bundle, _, _, _) async =>
        Uint8List.fromList((bundle as _NamedBundle).name.codeUnits);
    String firstIcon() => String.fromCharCodes(
      ((configurations.last['tabs'] as List).first as Map)['image']
          as Uint8List,
    );

    await tester.pumpWidget(
      _bar(const [_openWebUi, _hermes], bundle: _NamedBundle('first')),
    );
    await tester.pumpAndSettle();
    expect(firstIcon(), 'first');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      _bar(const [_openWebUi, _hermes], bundle: _NamedBundle('second')),
    );
    await tester.pumpAndSettle();
    expect(firstIcon(), 'second');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
