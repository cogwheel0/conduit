import 'dart:async';

import 'package:conduit/features/terminal/widgets/computer_page.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/terminal/models/computer_models.dart';
import 'package:conduit_core/features/terminal/providers/computer_providers.dart';
import 'package:conduit_core/features/terminal/services/computer_service.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:conduit/features/terminal/widgets/computer_surface.dart';
import 'package:conduit/features/terminal/widgets/computer_browser_tabs.dart';

import 'computer_test_platform.dart';

import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

class _Service extends Mock implements ComputerService {}

class _Messages extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => [];
}

Widget _harness(
  ComputerService service, {
  Future<bool> Function()? takeControl,
  double textScale = 1,
}) => ProviderScope(
  overrides: [
    computerServiceProvider.overrideWith((ref) async => service),
    chatMessagesProvider.overrideWith(_Messages.new),
    if (takeControl != null)
      computerTakeControlProvider.overrideWithValue(takeControl),
  ],
  child: MaterialApp(
    theme: ThemeData(platform: TargetPlatform.android),
    localizationsDelegates: conduitLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: ComputerPage(
      service: service,
      capabilities: const ComputerCapabilities(desktop: true, browser: true),
    ),
  ),
);

ComputerConnection _connection(ComputerSurface surface) => ComputerConnection(
  surface: surface,
  streamUri: Uri.parse('ws://computer.example/${surface.name}/stream'),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  registerFallbackValue(ComputerSurface.desktop);
  late InAppWebViewPlatform? previous;
  setUp(() {
    rootBundle.evict('assets/computer/viewer.js');
    previous = InAppWebViewPlatform.instance;
    InAppWebViewPlatform.instance = ComputerTestPlatform();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
          'flutter/assets',
          (_) async => const StringCodec().encodeMessage('// synthetic viewer'),
        );
  });
  tearDown(() {
    if (previous != null) InAppWebViewPlatform.instance = previous;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
  });

  testWidgets(
    'tabs require takeover, close to empty, and dismiss on background',
    (tester) async {
      final service = _Service();
      var tabs = [const ComputerBrowserTab(id: 'one', title: 'Workshop')];
      var gates = 0;
      final browser = ComputerConnection(
        surface: ComputerSurface.browser,
        streamUri: Uri.parse('ws://computer.example/browser/stream'),
        browserSession: const ComputerBrowserSession(
          id: 'one',
          token: 'synthetic',
          chromeAvailable: true,
        ),
      );
      when(() => service.open(any())).thenAnswer(
        (call) async =>
            call.positionalArguments.first == ComputerSurface.browser
            ? browser
            : _connection(ComputerSurface.desktop),
      );
      when(service.browserTabs).thenAnswer((_) async => tabs);
      when(() => service.closeBrowserTab('one')).thenAnswer((_) async {
        tabs = [];
      });
      when(service.createBrowserTab).thenAnswer((_) async => browser);
      await tester.pumpWidget(
        _harness(
          service,
          takeControl: () async {
            gates++;
            return true;
          },
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('Browser'));
      await tester.pump();
      await tester.pump();
      tester
          .widget<ComputerSurfaceView>(find.byType(ComputerSurfaceView))
          .onState({'status': 'live'});
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Browser tabs'));
      await tester.pumpAndSettle();
      expect(find.byType(ComputerBrowserTabs), findsOneWidget);
      await tester.tap(find.text('Take control').last);
      await tester.pumpAndSettle();
      expect(gates, 1);
      await tester.tap(find.bySemanticsLabel('Close tab: Workshop'));
      await tester.pumpAndSettle();
      verify(() => service.closeBrowserTab('one')).called(1);
      expect(find.byType(ComputerSurfaceView), findsNothing);
      verifyNever(service.createBrowserTab);
      await tester.tap(find.text('Browser tabs'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Take control').last);
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('New tab'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      verify(service.createBrowserTab).called(1);
      tester
          .widget<ComputerSurfaceView>(find.byType(ComputerSurfaceView))
          .onState({'status': 'live'});
      await tester.pumpAndSettle();
      expect(find.text('Watching live'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Browser tabs'));
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(ComputerBrowserTabs), findsNothing);
      expect(find.byType(ComputerPage), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('late Desktop events cannot corrupt a Browser connection', (
    tester,
  ) async {
    final service = _Service();
    final browser = Completer<ComputerConnection>();
    when(() => service.open(ComputerSurface.desktop))
        .thenAnswer((_) async => _connection(ComputerSurface.desktop));
    when(() => service.open(ComputerSurface.browser))
        .thenAnswer((_) => browser.future);
    await tester.pumpWidget(_harness(service));
    await tester.pump();
    await tester.pump();
    final old = tester.widget<ComputerSurfaceView>(
      find.byType(ComputerSurfaceView),
    );
    old.onState({'status': 'live'});
    await tester.pump();
    await tester.tap(find.text('Browser'));
    // A queued native callback can arrive before the old WebView is disposed.
    old.onState({'status': 'live'});
    old.onState({'status': 'state', 'url': 'https://old.example'});
    await tester.pump();
    expect(find.text('Watching live'), findsNothing);
    expect(find.text('old.example'), findsNothing);
    old.onState({'status': 'connecting'});
    browser.complete(_connection(ComputerSurface.browser));
    await tester.pump();
    await tester.pump();
    final current = tester.widget<ComputerSurfaceView>(
      find.byType(ComputerSurfaceView),
    );
    expect(current.connection.surface, ComputerSurface.browser);
    current.onState({'status': 'live'});
    await tester.pump();
    expect(find.text('Watching live'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'mode changes cancel pending control and rotation keeps the viewer',
    (tester) async {
      final service = _Service();
      final permission = Completer<bool>();
      when(() => service.open(any())).thenAnswer(
        (call) async =>
            _connection(call.positionalArguments[0] as ComputerSurface),
      );
      await tester.pumpWidget(
        _harness(service, takeControl: () => permission.future),
      );
      await tester.pump();
      await tester.pump();
      var view = tester.widget<ComputerSurfaceView>(
        find.byType(ComputerSurfaceView),
      );
      view.onState({'status': 'live'});
      await tester.pump();
      await tester.tap(find.text('Take control'));
      await tester.tap(find.text('Browser'));
      permission.complete(true);
      await tester.pump();
      await tester.pump();
      view = tester.widget<ComputerSurfaceView>(
        find.byType(ComputerSurfaceView),
      );
      view.onState({'status': 'state', 'transport': 'vnc'});
      view.onState({'status': 'live'});
      await tester.pumpAndSettle();
      expect(find.text('You’re in control'), findsNothing);
      final web = ComputerTestWebController();
      tester
          .widget<InAppWebView>(find.byType(InAppWebView))
          .platform
          .params
          .onWebViewCreated!(web);
      await tester.tap(find.text('Take control'));
      await tester.pumpAndSettle();
      expect(
        find.text('Tap to click, drag to move items, two fingers to scroll.'),
        findsOneWidget,
      );
      expect(web.scripts, contains('window.computer?.control(true)'));
      final state = tester.state(find.byType(ComputerSurfaceView));
      tester.view.physicalSize = const Size(844, 390);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(ComputerSurfaceView)), same(state));
      await tester.tap(find.text('Return to Watch'));
      await tester.pumpAndSettle();
      expect(find.text('Watching live'), findsOneWidget);
      expect(
        find.text('Send a new chat message to continue the task.'),
        findsOneWidget,
      );
      expect(web.scripts, contains('window.computer?.control(false)'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final size in [const Size(320, 568), const Size(568, 320)]) {
    testWidgets('connection failure stays usable at large text in $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = _Service();
      when(() => service.open(any()))
          .thenThrow(const ComputerBrowserUnavailable());
      await tester.pumpWidget(_harness(service, textScale: 2));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Retry'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('Desktop and Browser have distinct descriptions and navigation', (
    tester,
  ) async {
    final service = _Service();
    when(() => service.open(any()))
        .thenThrow(const ComputerBrowserUnavailable());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          computerServiceProvider.overrideWith((ref) async => service),
          chatMessagesProvider.overrideWith(_Messages.new),
        ],
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ComputerPage(
            service: service,
            capabilities: const ComputerCapabilities(
              desktop: true,
              browser: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Full desktop · apps and windows'), findsOneWidget);
    expect(find.byIcon(Icons.refresh_rounded), findsNothing);
    verify(() => service.open(ComputerSurface.desktop)).called(1);
    await tester.tap(find.text('Browser'));
    await tester.pumpAndSettle();
    expect(find.text('Browser tab · web pages'), findsOneWidget);
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
    verify(() => service.open(ComputerSurface.browser)).called(1);
    await tester.tap(find.text('Desktop'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.refresh_rounded), findsNothing);
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpAndSettle();
    expect(find.text('Full desktop · apps and windows'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Browser'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
