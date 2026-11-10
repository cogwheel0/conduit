import 'dart:async';
import 'dart:convert';

import 'package:conduit/features/terminal/widgets/computer_browser_tabs.dart';
import 'package:conduit/features/terminal/widgets/computer_page.dart';
import 'package:conduit/features/terminal/widgets/computer_surface.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/terminal/models/computer_models.dart';
import 'package:conduit_core/features/terminal/providers/computer_providers.dart';
import 'package:conduit_core/features/terminal/services/computer_service.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import 'package:conduit/shared/widgets/adaptive_toolbar_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';

import '../../../support/native_platform_views.dart';
import 'computer_test_platform.dart';

class _Service extends Mock implements ComputerService {}

class _Messages extends ChatMessagesNotifier {
  _Messages(this.initial);

  final List<ChatMessage> initial;

  @override
  List<ChatMessage> build() => initial;
}

const _both = ComputerCapabilities(desktop: true, browser: true);
const _browserOnly = ComputerCapabilities(browser: true);

ChatMessage _response() => ChatMessage(
  id: 'running-response',
  role: 'assistant',
  content: '',
  timestamp: DateTime.utc(2026),
  isStreaming: true,
);

Widget _harness(
  ComputerService service, {
  Future<bool> Function()? takeControl,
  double textScale = 1,
  Future<ComputerService?> Function()? loadService,
  bool Function()? enabled,
  ComputerCapabilities capabilities = _both,
  bool responding = false,
  TargetPlatform platform = TargetPlatform.android,
}) => ProviderScope(
  overrides: [
    computerEnabledProvider.overrideWith((ref) => enabled?.call() ?? true),
    computerServiceProvider.overrideWith(
      (ref) async => !ref.watch(computerEnabledProvider)
          ? null
          : loadService == null
          ? service
          : await loadService(),
    ),
    chatMessagesProvider.overrideWith(
      () => _Messages(responding ? [_response()] : []),
    ),
    if (takeControl != null)
      computerTakeControlProvider.overrideWithValue(takeControl),
  ],
  child: MaterialApp(
    theme: ThemeData(platform: platform),
    localizationsDelegates: conduitLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: ComputerPage(service: service, capabilities: capabilities),
  ),
);

ComputerConnection _connection(ComputerSurface surface) => ComputerConnection(
  surface: surface,
  streamUri: Uri.parse('ws://computer.example/${surface.name}/stream'),
);

ComputerConnection _tab(String id, {String mode = 'chrome'}) =>
    ComputerConnection(
      surface: ComputerSurface.browser,
      streamUri: Uri.parse('ws://computer.example/browser/stream'),
      browserSession: ComputerBrowserSession(
        id: id,
        token: 'synthetic',
        chromeAvailable: true,
        mode: mode,
      ),
    );

/// Frames without settling: spinners animate forever.
Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

ComputerSurfaceView _view(WidgetTester tester) =>
    tester.widget<ComputerSurfaceView>(find.byType(ComputerSurfaceView));

/// Rejects the first command, as a viewer replaced mid-send does.
class _DroppingWeb extends ComputerTestWebController {
  var _dropped = false;

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    if (!_dropped && source.startsWith('window.computer?.command(')) {
      _dropped = true;
      throw PlatformException(code: 'viewer-gone');
    }
    return super.evaluateJavascript(source: source, contentWorld: contentWorld);
  }
}

/// Mounts the viewer's WebView controller and reports the stream live.
Future<ComputerTestWebController> _live(
  WidgetTester tester, {
  ComputerTestWebController? controller,
}) async {
  final web = controller ?? ComputerTestWebController();
  tester
      .widget<InAppWebView>(find.byType(InAppWebView))
      .platform
      .params
      .onWebViewCreated!(web);
  _view(tester).onState({'status': 'live'});
  await _frames(tester);
  return web;
}

/// The commands the viewer received, decoded.
List<Map<String, dynamic>> _commands(ComputerTestWebController web) => [
  for (final script in web.scripts)
    if (script.startsWith('window.computer?.command('))
      jsonDecode(
        script.substring('window.computer?.command('.length, script.length - 1),
      ) as Map<String, dynamic>,
];

void _respond(WidgetTester tester, {required bool running}) =>
    ProviderScope.containerOf(tester.element(find.byType(ComputerPage)))
        .read(chatMessagesProvider.notifier)
        .setMessages(running ? [_response()] : []);

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('computer-more-button')));
  await _frames(tester);
}

Future<void> _menu(WidgetTester tester, String item) async {
  await _openMenu(tester);
  await tester.tap(find.text(item).last);
  await _frames(tester);
}

Future<void> _switchTo(WidgetTester tester, String surface) async {
  await tester.tap(find.byKey(const ValueKey('computer-surface-menu')));
  await _frames(tester);
  await tester.tap(find.text(surface).last);
  await _frames(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  registerFallbackValue(ComputerSurface.desktop);
  registerFallbackValue(_connection(ComputerSurface.desktop));
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

  test('a typed address without a scheme opens over https', () {
    expect(
      computerAddressUrl(' example.com/path '),
      'https://example.com/path',
    );
    expect(
      computerAddressUrl('http://192.168.1.4:8080'),
      'http://192.168.1.4:8080',
    );
    expect(computerAddressUrl('about:blank'), 'about:blank');
    // A host and port is an address, not a scheme.
    expect(computerAddressUrl('localhost:3000'), 'https://localhost:3000');
    expect(
      computerAddressUrl('example.com:8080/board'),
      'https://example.com:8080/board',
    );
  });

  testWidgets('on iOS 26 Keyboard and More share one glass capsule', (
    tester,
  ) async {
    stubNativePlatformViews();
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
    addTearDown(PlatformUiCapabilities.resetDebugOverrides);
    final service = _Service();
    when(() => service.open(any()))
        .thenAnswer((_) async => _connection(ComputerSurface.desktop));
    await tester.pumpWidget(_harness(service, platform: TargetPlatform.iOS));
    await _frames(tester);

    final cluster = tester.widget<ConduitToolbarActionCluster>(
      find.descendant(
        of: find.byKey(const ValueKey('computer-toolbar-actions')),
        matching: find.byType(ConduitToolbarActionCluster),
      ),
    );
    expect(
      [for (final item in cluster.items) item.action.iosSymbol],
      ['keyboard', 'ellipsis'],
    );
    // More keeps its sections and palette row inside the capsule.
    expect(cluster.items.last.action.menuEntries, isNotEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  for (final accepted in [true, false]) {
    testWidgets('the user drives while idle and watches a running response '
        'until Take Control stops it (accepted: $accepted)', (tester) async {
      final service = _Service();
      when(() => service.open(any()))
          .thenAnswer((_) async => _connection(ComputerSurface.desktop));
      var gates = 0;
      await tester.pumpWidget(
        _harness(
          service,
          takeControl: () async {
            gates++;
            // The real gate returns once the response has ended.
            if (accepted) _respond(tester, running: false);
            return accepted;
          },
        ),
      );
      await _frames(tester);
      final web = await _live(tester);
      expect(web.scripts.last, 'window.computer?.control(true)');
      expect(find.text('Agent is working'), findsNothing);
      // Pointer and audio reports never read as a change of connection.
      _view(tester).onState({'status': 'pointer', 'dragging': false});
      _view(tester).onState({'status': 'audio', 'available': false});
      await _frames(tester);
      expect(find.text('Connecting to computer…'), findsNothing);

      _respond(tester, running: true);
      await _frames(tester);
      expect(web.scripts.last, 'window.computer?.control(false)');
      expect(find.text('Agent is working'), findsOneWidget);
      // Nothing types on the agent's screen meanwhile.
      await tester.tap(find.byKey(const ValueKey('computer-keyboard-button')));
      await _frames(tester);
      expect(find.byKey(const ValueKey('computer-key-row')), findsNothing);

      await tester.tap(find.text('Take Control'));
      await _frames(tester);
      expect(gates, 1);
      if (accepted) {
        expect(web.scripts.last, 'window.computer?.control(true)');
        expect(find.text('Agent is working'), findsNothing);
      } else {
        expect(web.scripts.last, 'window.computer?.control(false)');
        expect(find.text('Agent is working'), findsOneWidget);
        expect(
          find.text(
            'Could not stop the current response. You can keep watching '
            'and try again.',
          ),
          findsOneWidget,
        );
      }
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'the keyboard types on the remote screen and keeps the browser viewport',
    (tester) async {
      final service = _Service();
      when(() => service.open(any()))
          .thenAnswer((_) async => _connection(ComputerSurface.browser));
      await tester.pumpWidget(_harness(service, capabilities: _browserOnly));
      await _frames(tester);
      final web = await _live(tester);
      await tester.tap(find.byKey(const ValueKey('computer-keyboard-button')));
      await _frames(tester);
      expect(find.byKey(const ValueKey('computer-key-row')), findsOneWidget);
      expect(_view(tester).holdViewport, isTrue);

      final field = find.byKey(const ValueKey('computer-keyboard-field'));
      String text() => tester.widget<EditableText>(field).controller.text;
      Future<void> edit(String value, {TextRange? composing}) async {
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: value,
            selection: TextSelection.collapsed(offset: value.length),
            composing: composing ?? TextRange.empty,
          ),
        );
        await tester.pump();
      }

      await edit('${text()}Hé 👋');
      // An input method sends its text once it is committed.
      final base = text();
      await edit(
        '$baseに',
        composing: TextRange(start: base.length, end: base.length + 1),
      );
      expect(_commands(web), hasLength(1));
      await edit('$base日');
      await edit(text().characters.skipLast(1).string);
      await edit('${text()}\n');
      await tester.tap(find.text('esc'));
      await tester.pump();
      expect(_commands(web), [
        {'type': 'paste', 'text': 'Hé 👋'},
        {'type': 'paste', 'text': '日'},
        {'type': 'shortcut', 'key': 'Backspace'},
        {'type': 'shortcut', 'key': 'Enter'},
        {'type': 'shortcut', 'key': 'Escape'},
      ]);

      // A response takes the screen back and closes the keyboard.
      _respond(tester, running: true);
      await _frames(tester);
      expect(find.byKey(const ValueKey('computer-key-row')), findsNothing);
      expect(_view(tester).holdViewport, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a keystroke the viewer drops does not stop later typing', (
    tester,
  ) async {
    final service = _Service();
    when(() => service.open(any()))
        .thenAnswer((_) async => _connection(ComputerSurface.desktop));
    await tester.pumpWidget(_harness(service));
    await _frames(tester);
    final web = await _live(tester, controller: _DroppingWeb());
    await tester.tap(find.byKey(const ValueKey('computer-keyboard-button')));
    await _frames(tester);
    await tester.tap(find.text('esc'));
    await tester.pump();
    await tester.tap(find.text('tab'));
    await tester.pump();
    expect(_commands(web), [
      {'type': 'shortcut', 'key': 'Tab'},
    ]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('keyboard shortcuts preserve literal input', (tester) async {
    final service = _Service();
    final connection = _connection(ComputerSurface.desktop);
    when(() => service.open(any())).thenAnswer((_) async => connection);
    when(() => service.sendShortcut(connection, 'Ctrl+S'))
        .thenAnswer((_) async {});
    await tester.pumpWidget(_harness(service));
    await _frames(tester);
    await _live(tester);
    await tester.tap(find.byKey(const ValueKey('computer-keyboard-button')));
    await _frames(tester);
    await tester.tap(find.bySemanticsLabel('Keyboard Shortcut'));
    await _frames(tester);
    final input = tester.widget<EditableText>(
      find.descendant(
        of: find.byType(TextField),
        matching: find.byType(EditableText),
      ),
    );
    expect(input.autocorrect, isFalse);
    expect(input.smartQuotesType, SmartQuotesType.disabled);
    await tester.enterText(find.byType(TextField), 'Ctrl+S');
    await tester.tap(find.text('Send'));
    await _frames(tester);
    verify(() => service.sendShortcut(connection, 'Ctrl+S')).called(1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'the More menu turns on a trackpad that survives a switch of surface, '
    'recenters its pointer and pastes only while in control',
    (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => call.method == 'Clipboard.getData'
            ? {'text': 'Workshop plan'}
            : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final service = _Service();
      when(() => service.open(any())).thenAnswer(
        (call) async =>
            _connection(call.positionalArguments.first as ComputerSurface),
      );
      await tester.pumpWidget(_harness(service));
      await _frames(tester);
      var web = await _live(tester);
      await _openMenu(tester);
      expect(find.text('Recenter Pointer'), findsNothing);
      await tester.tap(find.text('Trackpad Mode'));
      await _frames(tester);
      expect(web.scripts, contains('window.computer?.trackpad(true)'));
      await _menu(tester, 'Recenter Pointer');
      await _menu(tester, 'Paste');
      await _menu(tester, 'Right-Click');
      await _menu(tester, 'Start Drag');
      // The viewer reports the held drag; the same row now ends it.
      _view(tester).onState({'status': 'pointer', 'dragging': true});
      await _frames(tester);
      await _menu(tester, 'End Drag');
      expect(_commands(web), [
        {'type': 'recenter'},
        {'type': 'paste', 'text': 'Workshop plan'},
        {'type': 'rightClick'},
        {'type': 'startDrag'},
        {'type': 'endDrag'},
      ]);

      _respond(tester, running: true);
      await _frames(tester);
      await _menu(tester, 'Paste');
      expect(_commands(web), hasLength(5));
      await tester.tapAt(const Offset(4, 400));
      await _frames(tester);

      _respond(tester, running: false);
      await _switchTo(tester, 'Browser');
      web = await _live(tester);
      expect(web.scripts, contains('window.computer?.trackpad(true)'));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('closing the last tab leaves an empty browser to start again', (
    tester,
  ) async {
    final service = _Service();
    var tabs = [const ComputerBrowserTab(id: 'one', title: 'Workshop')];
    when(() => service.open(ComputerSurface.browser))
        .thenAnswer((_) async => tabs.isEmpty ? null : _tab('one'));
    when(service.browserTabs).thenAnswer((_) async => tabs);
    when(() => service.closeBrowserTab('one')).thenAnswer((_) async {
      tabs = [];
    });
    when(service.createBrowserTab).thenAnswer((_) async => _tab('two'));
    await tester.pumpWidget(_harness(service, capabilities: _browserOnly));
    await _frames(tester);
    await _live(tester);
    await _menu(tester, 'Browser Tabs');
    await _frames(tester);
    expect(find.byType(ComputerBrowserTabs), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Close Tab: Workshop'));
    await _frames(tester);
    verify(() => service.closeBrowserTab('one')).called(1);
    expect(find.byType(ComputerSurfaceView), findsNothing);
    expect(find.text('No browser tabs'), findsOneWidget);
    verifyNever(service.createBrowserTab);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _frames(tester);
    expect(find.text('No browser tabs'), findsOneWidget);
    verifyNever(service.createBrowserTab);

    await tester.tap(find.text('New Tab'));
    await _frames(tester);
    verify(service.createBrowserTab).called(1);
    await _live(tester);
    await _menu(tester, 'Browser Tabs');
    expect(find.byType(ComputerBrowserTabs), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await _frames(tester);
    expect(find.byType(ComputerBrowserTabs), findsNothing);
    expect(find.byType(ComputerPage), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox());
  });

  for (final background in [false, true]) {
    testWidgets('an empty browser finds the agent’s next tab '
        '(background: $background)', (tester) async {
      final service = _Service();
      ComputerConnection? browser;
      when(() => service.open(ComputerSurface.browser))
          .thenAnswer((_) async => browser);
      await tester.pumpWidget(_harness(service, capabilities: _browserOnly));
      await _frames(tester);
      expect(find.text('No browser tabs'), findsOneWidget);
      verify(() => service.open(ComputerSurface.browser)).called(1);
      if (background) {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
      }
      browser = _tab('agent-tab');
      await tester.pump(const Duration(seconds: 3));
      if (background) {
        verifyNever(() => service.open(ComputerSurface.browser));
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
      await _frames(tester);
      expect(_view(tester).connection, same(browser));
      verifyNever(service.createBrowserTab);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final outcome in ['idle', 'accepted', 'denied']) {
    testWidgets('a waiting browser tab starts its live view only while the '
        'chat is idle: $outcome', (tester) async {
      final service = _Service();
      final gate = Completer<bool>();
      when(() => service.open(ComputerSurface.browser))
          .thenAnswer((_) async => _tab('proxy-tab', mode: 'proxy'));
      when(() => service.selectBrowserTab('proxy-tab'))
          .thenAnswer((_) async => _tab('proxy-tab'));
      await tester.pumpWidget(
        _harness(
          service,
          capabilities: _browserOnly,
          responding: outcome != 'idle',
          takeControl: () async {
            final accepted = await gate.future;
            if (accepted) _respond(tester, running: false);
            return accepted;
          },
        ),
      );
      await _frames(tester);
      if (outcome == 'idle') {
        verify(() => service.selectBrowserTab('proxy-tab')).called(1);
        expect(find.byType(ComputerSurfaceView), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        return;
      }
      expect(find.byType(ComputerSurfaceView), findsNothing);
      expect(
        find.text('Take Control to start this tab’s live view.'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.tap(find.text('Take Control'));
      await tester.pump();
      verifyNever(() => service.selectBrowserTab('proxy-tab'));
      gate.complete(outcome == 'accepted');
      await _frames(tester);
      if (outcome == 'denied') {
        verifyNever(() => service.selectBrowserTab('proxy-tab'));
        expect(find.byType(ComputerSurfaceView), findsNothing);
      } else {
        verify(() => service.selectBrowserTab('proxy-tab')).called(1);
        final web = await _live(tester);
        expect(web.scripts.last, 'window.computer?.control(true)');
      }
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final discoveredMode in ['proxy', 'chrome']) {
    testWidgets('a response during activation watches the $discoveredMode tab '
        'it finds', (tester) async {
      final service = _Service();
      final activation = Completer<ComputerConnection>();
      var mode = 'proxy';
      when(() => service.open(ComputerSurface.browser))
          .thenAnswer((_) async => _tab('proxy-tab', mode: mode));
      when(() => service.selectBrowserTab('proxy-tab'))
          .thenAnswer((_) => activation.future);
      await tester.pumpWidget(_harness(service, capabilities: _browserOnly));
      await _frames(tester);
      verify(() => service.selectBrowserTab('proxy-tab')).called(1);
      mode = discoveredMode;
      _respond(tester, running: true);
      await _frames(tester);
      mode = 'chrome';
      activation.complete(_tab('proxy-tab'));
      await tester.pump(const Duration(seconds: 3));
      await _frames(tester);
      final web = await _live(tester);
      expect(web.scripts, isNot(contains('window.computer?.control(true)')));
      expect(find.text('Agent is working'), findsOneWidget);
      verifyNever(() => service.selectBrowserTab('proxy-tab'));
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('Watch follows a tab the agent activates itself', (tester) async {
    final service = _Service();
    var mode = 'proxy';
    when(() => service.open(ComputerSurface.browser))
        .thenAnswer((_) async => _tab('agent-tab', mode: mode));
    await tester.pumpWidget(
      _harness(service, capabilities: _browserOnly, responding: true),
    );
    await _frames(tester);
    expect(find.byType(ComputerSurfaceView), findsNothing);
    mode = 'chrome';
    await tester.pump(const Duration(seconds: 3));
    await _frames(tester);
    final web = await _live(tester);
    expect(web.scripts, isNot(contains('window.computer?.control(true)')));
    verifyNever(() => service.selectBrowserTab('agent-tab'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('disabling Computer releases an open viewer', (tester) async {
    final service = _Service();
    when(() => service.open(any()))
        .thenAnswer((_) async => _connection(ComputerSurface.desktop));
    var enabled = true;
    await tester.pumpWidget(_harness(service, enabled: () => enabled));
    await _frames(tester);
    expect(find.byType(ComputerSurfaceView), findsOneWidget);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ComputerPage)),
    );
    enabled = false;
    container.invalidate(computerEnabledProvider);
    await _frames(tester);
    expect(find.byType(ComputerSurfaceView), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('pending scope lookup closes the previous live viewer', (
    tester,
  ) async {
    final service = _Service();
    when(() => service.open(any()))
        .thenAnswer((_) async => _connection(ComputerSurface.desktop));
    final pending = Completer<ComputerService?>();
    var refreshing = false;
    await tester.pumpWidget(
      _harness(
        service,
        loadService: () async => refreshing ? await pending.future : service,
      ),
    );
    await _frames(tester);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ComputerPage)),
    );
    refreshing = true;
    container.invalidate(computerServiceProvider);
    await _frames(tester);
    expect(find.byType(ComputerSurfaceView), findsNothing);
    pending.complete(null);
    await tester.pumpWidget(const SizedBox());
  });

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
    await _frames(tester);
    final old = _view(tester);
    old.onState({'status': 'live'});
    await tester.pump();
    await _switchTo(tester, 'Browser');
    // A queued native callback can arrive before the old WebView is disposed.
    old.onState({'status': 'live'});
    old.onState({'status': 'state', 'url': 'https://old.example'});
    await tester.pump();
    expect(find.text('old.example'), findsNothing);
    expect(find.text('Connecting to computer…'), findsOneWidget);
    browser.complete(_connection(ComputerSurface.browser));
    await _frames(tester);
    expect(_view(tester).connection.surface, ComputerSurface.browser);
    _view(tester).onState({'status': 'state', 'url': 'https://example.com'});
    final web = await _live(tester);
    expect(find.text('example.com'), findsOneWidget);
    expect(web.scripts.last, 'window.computer?.control(true)');
    await tester.pumpWidget(const SizedBox());
  });

  for (final overlay in [
    'Browser Tabs',
    'Go to Address',
    'Keyboard Shortcut',
  ]) {
    testWidgets('a response invalidates $overlay without acting for the user', (
      tester,
    ) async {
      final service = _Service();
      final connection = _connection(ComputerSurface.browser);
      when(() => service.open(any())).thenAnswer((_) async => connection);
      when(service.browserTabs).thenAnswer((_) async => []);
      await tester.pumpWidget(_harness(service, capabilities: _browserOnly));
      await _frames(tester);
      final web = await _live(tester);
      if (overlay == 'Keyboard Shortcut') {
        await tester.tap(
          find.byKey(const ValueKey('computer-keyboard-button')),
        );
        await _frames(tester);
        await tester.tap(find.bySemanticsLabel(overlay));
        await _frames(tester);
      } else {
        await _menu(tester, overlay);
      }
      if (overlay != 'Browser Tabs') {
        await tester.enterText(find.byType(TextField), 'synthetic');
      }
      _respond(tester, running: true);
      await _frames(tester);
      if (overlay == 'Browser Tabs') {
        expect(find.byType(ComputerBrowserTabs), findsNothing);
      } else {
        await tester.tap(find.text('Send'));
        await _frames(tester);
      }
      verifyNever(() => service.sendShortcut(any(), any()));
      expect(_commands(web), isEmpty);
      expect(find.text('Agent is working'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final timing in ['pending', 'pushed', 'covered']) {
    testWidgets('a response dismisses only its tab sheet ($timing)', (
      tester,
    ) async {
      final service = _Service();
      when(() => service.open(any()))
          .thenAnswer((_) async => _connection(ComputerSurface.browser));
      when(service.browserTabs).thenAnswer((_) async => []);
      await tester.pumpWidget(_harness(service, capabilities: _browserOnly));
      await _frames(tester);
      final context = tester.element(find.byType(ComputerPage));
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                ComputerPage(service: service, capabilities: _browserOnly),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await _frames(tester);
      await _live(tester);
      await _openMenu(tester);
      await tester.tap(find.text('Browser Tabs').last);
      if (timing == 'pushed') await tester.pump();
      if (timing == 'covered') {
        await _frames(tester);
        unawaited(
          showDialog<void>(
            context: context,
            builder: (_) => const AlertDialog(title: Text('Another dialog')),
          ),
        );
        await _frames(tester);
      }
      // Without pumping, interruption lands before the native-chrome handoff.
      ProviderScope.containerOf(context)
          .read(chatMessagesProvider.notifier)
          .setMessages([_response()]);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.byType(ComputerBrowserTabs, skipOffstage: false),
        findsNothing,
      );
      if (timing == 'covered') {
        expect(find.text('Another dialog'), findsOneWidget);
      }
      expect(find.byType(ComputerPage, skipOffstage: false), findsNWidgets(2));
      await tester.pumpWidget(const SizedBox());
    });
  }

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
}
