import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:conduit/features/hermes/widgets/hermes_messages_home.dart';
import 'package:conduit/features/hermes/providers/hermes_messages.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot_group.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit_core/persistence/preferences_store.dart';

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';

import 'package:conduit/features/hermes/widgets/hermes_conversation_actions.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _renderFont = String.fromEnvironment('CONDUIT_RENDER_FONT');
const _capturePath = String.fromEnvironment('CONDUIT_RENAME_CAPTURE');
const _session = HermesSessionSummary(id: 'rename-test', title: 'Old title');
const _config = HermesConfig(enabled: true, baseUrl: 'https://hermes.example');

class _Channel extends Mock implements WebSocketChannel {}

class _Sink extends Mock implements WebSocketSink {}

class _Adapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      jsonEncode(
        options.uri.path.endsWith('/messages')
            ? {
                'messages': [
                  {
                    'role': 'user',
                    'content': 'Redesign the website navigation.',
                  },
                  {
                    'role': 'assistant',
                    'content': 'Use a compact navigation bar.',
                  },
                ],
              }
            : options.uri.path == '/api/sessions'
            ? {'sessions': []}
            : {
                'version': '0.20.1',
                'auth_required': false,
                'gateway_running': true,
              },
      ),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

class _Backend {
  _Backend() {
    when(() => channel.ready).thenAnswer((_) async {});
    when(() => channel.stream).thenAnswer((_) {
      scheduleMicrotask(
        () => incoming.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {'type': 'gateway.ready', 'payload': {}},
          }),
        ),
      );
      return incoming.stream;
    });
    when(() => channel.sink).thenReturn(sink);
    when(() => sink.close()).thenAnswer((_) async {});
    when(() => sink.add(any())).thenAnswer((invocation) {
      final frame =
          jsonDecode(invocation.positionalArguments.single as String) as Map;
      final id = frame['id'];
      if (id == null) return;
      Future<void> respond() async {
        final method = frame['method'];
        if (method == 'llm.oneshot') {
          suggestions.add('rename-test');
          if (failure != null) {
            incoming.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': id,
                'error': {'code': -32000, 'message': 'Unavailable'},
              }),
            );
            return;
          }
        }
        if (method == 'session.title') {
          renames.add((
            'rename-test',
            (frame['params'] as Map)['title'] as String,
          ));
        }
        final result = method == 'llm.oneshot'
            ? {
                'text':
                    await (pending?.future ??
                        Future.value('Website Navigation Redesign')),
              }
            : method == 'session.resume'
            ? {
                'session_id': 'runtime-rename',
                'stored_session_id': 'rename-test',
                'running': false,
              }
            : <String, dynamic>{};
        if (!incoming.isClosed) {
          incoming.add(
            jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}),
          );
        }
      }

      unawaited(respond());
    });
    final dio = Dio()..httpClientAdapter = _Adapter();
    service = HermesDesktopApiService(
      config: HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes.example',
        mode: HermesBackendMode.desktopGateway,
        desktopCredentials: HermesDesktopCredentials(legacyToken: 'test-token'),
      ),
      dio: dio,
      rpc: HermesDesktopRpcClient(
        channelFactory: (_, _, {httpClient}) => channel,
      ),
    );
  }
  final channel = _Channel();
  final sink = _Sink();
  final incoming = StreamController<dynamic>.broadcast();
  late final HermesDesktopApiService service;
  Completer<String>? pending;
  Object? failure;
  final suggestions = <String>[];
  final renames = <(String, String)>[];
  Future<void> dispose() async {
    service.close();
    await incoming.close();
  }
}

class _Config extends HermesConfigController {
  @override
  HermesConfig build() => _config;
}

class _Active extends ActiveConversationNotifier {
  @override
  Conversation? build() => markNativeHermesConversation(
    Conversation(
      id: 'local:hermes_rename-test',
      title: 'Old title',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      metadata: const {'backend': 'hermes', 'hermesSessionId': 'rename-test'},
    ),
  );
}

final _previewBoundary = GlobalKey();

class _Sessions extends HermesSessionsController {
  @override
  Future<List<HermesSessionSummary>> build() async => [_session];
}

class _Groups extends HermesGroupsController {
  @override
  Future<List<HermesBotGroup>> build() async => [];
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Backend backend, {
  bool dark = false,
  double scale = 1,
  bool fromList = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
  addTearDown(PreferencesStore.debugReset);
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      hermesApiServiceProvider.overrideWithValue(backend.service),
      hermesConfigProvider.overrideWith(_Config.new),
      activeConversationProvider.overrideWith(_Active.new),
      if (fromList) hermesSessionsProvider.overrideWith(_Sessions.new),
      if (fromList) hermesMessagesBotsProvider.overrideWith((_) async => []),
      if (fromList)
        hermesBotConversationsProvider.overrideWith(
          (_) async => const HermesBotConversations([]),
        ),
      if (fromList) hermesBotGroupsProvider.overrideWith(_Groups.new),
    ],
  );
  addTearDown(backend.dispose);
  addTearDown(container.dispose);
  final theme = dark
      ? AppTheme.dark(TweakcnThemes.conduit)
      : AppTheme.light(TweakcnThemes.conduit);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: _previewBoundary,
        child: MaterialApp(
          theme: theme.copyWith(
            textTheme: theme.textTheme.apply(
              fontFamily: _renderFont.isEmpty ? null : 'RenameRender',
            ),
          ),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: fromList
                ? const HermesMessagesHome()
                : const Center(child: HermesChatActions(session: _session)),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (fromList) {
    await tester.longPress(find.text('Old title'));
  } else {
    await tester.tap(find.byTooltip('Conversation actions'));
  }
  await tester.pumpAndSettle();
  await tester.tap(find.text('Rename'));
  await tester.pumpAndSettle();
  return container;
}

Future<void> _waitFor(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 100 && !ready(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(ready(), isTrue);
}

void main() {
  testWidgets('Holding a chat opens the shared Rename flow', (tester) async {
    final backend = _Backend();
    await _pump(tester, backend, fromList: true);
    expect(find.text('Auto rename'), findsOneWidget);
    expect(backend.suggestions, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(backend.renames, isEmpty);
  });
  for (final dark in [false, true]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('Rename sheet renders dark=$dark scale=$scale', (
        tester,
      ) async {
        if (_renderFont.isNotEmpty) {
          await tester.runAsync(() async {
            await (FontLoader('MaterialIcons')
                  ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
                .load();
            await (FontLoader('RenameRender')..addFont(
                  Future.value(
                    ByteData.sublistView(await File(_renderFont).readAsBytes()),
                  ),
                ))
                .load();
          });
        }
        final backend = _Backend();
        await _pump(tester, backend, dark: dark, scale: scale);
        expect(tester.takeException(), isNull);
        if (_capturePath.isNotEmpty) {
          final boundary =
              _previewBoundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            await Directory(_capturePath).create(recursive: true);
            await File('$_capturePath/sheet-$dark-$scale.png')
                .writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      });
    }
  }

  testWidgets(
    'Rename stays scrollable on a small screen with keyboard and large text',
    (tester) async {
      await _pump(tester, _Backend(), scale: 2);
      tester.view.physicalSize = const Size(320, 640);
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Save'));
      expect(find.text('Auto rename'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('Typing while a suggestion is pending preserves the typed name', (
    tester,
  ) async {
    final backend = _Backend()..pending = Completer<String>();
    await _pump(tester, backend);
    await tester.tap(find.text('Auto rename'));
    await _waitFor(tester, () => backend.suggestions.isNotEmpty);
    await tester.enterText(find.byType(TextField), 'My own title');
    backend.pending!.complete('Generated title');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'My own title'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await _waitFor(tester, () => backend.renames.isNotEmpty);
    expect(backend.renames, [('rename-test', 'My own title')]);
  });

  testWidgets('Rename restores Auto rename and saves the reviewed title', (
    tester,
  ) async {
    final backend = _Backend()..pending = Completer<String>();
    final container = await _pump(tester, backend);
    expect(find.text('Auto rename'), findsOneWidget);
    await tester.tap(find.text('Auto rename'));
    await tester.pump();
    await _waitFor(tester, () => backend.suggestions.isNotEmpty);
    expect(backend.suggestions, ['rename-test']);
    expect(backend.renames, isEmpty);
    backend.pending!.complete('Website Navigation Redesign');
    await _waitFor(
      tester,
      () => find
          .widgetWithText(TextField, 'Website Navigation Redesign')
          .evaluate()
          .isNotEmpty,
    );
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(TextField, 'Website Navigation Redesign'),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField), 'Reviewed website title');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await _waitFor(tester, () => backend.renames.isNotEmpty);
    expect(backend.renames, [('rename-test', 'Reviewed website title')]);
    expect(
      container.read(activeConversationProvider)?.title,
      'Reviewed website title',
    );
    expect(
      isNativeHermesConversation(container.read(activeConversationProvider)),
      isTrue,
      reason: 'Renaming must preserve the open native Hermes conversation',
    );
  });
  testWidgets('Cancel ignores a late suggestion without saving', (
    tester,
  ) async {
    final backend = _Backend()..pending = Completer<String>();
    await _pump(tester, backend);
    await tester.tap(find.text('Auto rename'));
    await tester.pump();
    await _waitFor(tester, () => backend.suggestions.isNotEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    backend.pending!.complete('Late title');
    await tester.pumpAndSettle();
    expect(backend.renames, isEmpty);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Suggestion failure preserves manual rename', (tester) async {
    final backend = _Backend()..failure = StateError('Unavailable');
    await _pump(tester, backend);
    await tester.tap(find.text('Auto rename'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Old title'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Manual name');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await _waitFor(tester, () => backend.renames.isNotEmpty);
    expect(backend.renames, [('rename-test', 'Manual name')]);
  });
}
