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
      expect(find.text('Return to Watch'), findsNothing);
      expect(find.bySemanticsLabel('Type on computer'), findsNothing);
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

  testWidgets('Computer shortcuts preserve literal keyboard input', (
    tester,
  ) async {
    final service = _Service();
    final connection = _connection(ComputerSurface.desktop);
    when(() => service.open(any())).thenAnswer((_) async => connection);
    when(() => service.sendShortcut(connection, 'Ctrl+S'))
        .thenAnswer((_) async {});
    await tester.pumpWidget(_harness(service, takeControl: () async => true));
    await tester.pump();
    await tester.pump();
    tester
        .widget<ComputerSurfaceView>(find.byType(ComputerSurfaceView))
        .onState({'status': 'live'});
    await tester.pump();
    await tester.tap(find.text('Take control'));
    await tester.pumpAndSettle();
    final shortcut = find.bySemanticsLabel('Keyboard shortcut');
    await tester.ensureVisible(shortcut);
    await tester.tap(shortcut);
    await tester.pumpAndSettle();
    final field = tester.widget<EditableText>(find.byType(EditableText));
    expect(field.autocorrect, isFalse);
    expect(field.smartQuotesType, SmartQuotesType.disabled);
    await tester.enterText(find.byType(EditableText), 'Ctrl+S');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    verify(() => service.sendShortcut(connection, 'Ctrl+S')).called(1);
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

  testWidgets('dialog keyboard does not resize the remote workspace', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final service = _Service();
    when(() => service.open(any()))
        .thenAnswer((_) async => _connection(ComputerSurface.desktop));
    await tester.pumpWidget(_harness(service, takeControl: () async => true));
    await tester.pump();
    await tester.pump();
    tester.widget<ComputerSurfaceView>(find.byType(ComputerSurfaceView))
        .onState({'status': 'live'});
    await tester.pumpAndSettle();
    await tester.tap(find.text('Take control'));
    await tester.pumpAndSettle();
    final before = tester.getRect(find.byType(ComputerSurfaceView));
    await tester.tap(find.bySemanticsLabel('Type on computer'));
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(ComputerSurfaceView)), before);
    await tester.tap(find.text('Cancel'));
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(ComputerSurfaceView)), before);
    await tester.pumpWidget(const SizedBox());
  });

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

  for (final size in [
    const Size(320, 568),
    const Size(820, 1180),
    const Size(1280, 800),
  ]) {
    testWidgets('trackpad actions and drag state remain usable at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = _Service();
      when(() => service.open(any()))
          .thenAnswer((_) async => _connection(ComputerSurface.desktop));
      await tester.pumpWidget(_harness(service, takeControl: () async => true));
      await tester.pump();
      await tester.pump();
      final view = tester.widget<ComputerSurfaceView>(
        find.byType(ComputerSurfaceView),
      );
      view.onState({'status': 'live'});
      final web = ComputerTestWebController();
      tester
          .widget<InAppWebView>(find.byType(InAppWebView))
          .platform
          .params
          .onWebViewCreated!(web);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Take control'));
      await tester.pumpAndSettle();
      if (size.width > size.height) {
        expect(
          tester.getRect(find.byType(ComputerSurfaceView)).left,
          greaterThan(
            tester.getRect(find.text('Full desktop · apps and windows')).right,
          ),
        );
        expect(
          tester.getSize(find.byType(ComputerSurfaceView)).height,
          greaterThan(size.height * .8),
        );
      }
      expect(
        tester.getSize(find.byTooltip('Pointer controls')).width,
        greaterThanOrEqualTo(44),
      );
      await tester.tap(find.byTooltip('Pointer controls'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Trackpad'));
      await tester.pumpAndSettle();
      expect(web.scripts, contains('window.computer?.trackpad(true)'));
      expect(
        find.text(
          'Slide to move the cursor. Tap to click, hold to drag; two fingers scroll.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Pointer controls'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start drag'));
      await tester.pumpAndSettle();
      expect(web.scripts.any((s) => s.contains('startDrag')), isTrue);
      view.onState({'status': 'pointer', 'dragging': true});
      await tester.pumpAndSettle();
      expect(find.text('You’re in control'), findsOneWidget);
      expect(
        find.text('Drag is held. Slide to move, then tap or choose End drag.'),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Pointer controls'));
      await tester.pumpAndSettle();
      // A native menu can release the pointer on blur. Its selected End action
      // must still release, never toggle a fresh drag on after reacquiring control.
      view.onState({'status': 'pointer', 'dragging': false});
      await tester.tap(find.text('End drag'));
      await tester.pumpAndSettle();
      expect(web.scripts.any((s) => s.contains('endDrag')), isTrue);
      expect(tester.takeException(), isNull);
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
