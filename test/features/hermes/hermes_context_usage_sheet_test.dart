import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/features/hermes/widgets/hermes_context_usage_sheet.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show isChatStreamingProvider;
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_context_usage.dart';
import 'package:conduit_core/features/hermes/providers/hermes_context_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final _l10n = AppLocalizationsEn();

/// What a legacy gateway reports for a synthetic chat.
const _desktopReport = HermesContextReport(
  model: 'synthetic-model',
  contextUsed: 32768,
  contextMax: 131072,
  estimatedTotal: 11865,
  categories: [
    HermesContextCategory(
      id: 'system_prompt',
      label: 'System prompt',
      tokens: 2545,
    ),
    HermesContextCategory(
      id: 'tool_definitions',
      label: 'Tool definitions',
      tokens: 8929,
    ),
    HermesContextCategory(id: 'skills', label: 'Synthetic skills', tokens: 391),
  ],
  totals: HermesTokenTotals(
    input: 4800,
    output: 1600,
    cacheRead: 2400,
    cacheHitPercent: 50,
    calls: 4,
    compressions: 1,
    costUsd: 0.0425,
    costEstimated: true,
  ),
  usageBars: HermesUsageBars(
    planName: 'Synthetic Plus',
    renews: 'Dec 1',
    plan: HermesUsageBar(
      kind: 'plan',
      fill: 0.4,
      remaining: r'$12.00',
      total: r'$20.00',
      usedPercent: 40,
    ),
    topup: HermesUsageBar(
      kind: 'topup',
      fill: 0,
      remaining: r'$5.00',
      total: r'$5.00',
    ),
  ),
  providerPlan: HermesProviderPlan(
    provider: 'Synthetic Portal',
    gauges: [HermesPlanGauge(id: 'day', usedFraction: 0.63)],
    rateLimited: true,
    usageLevel: 'medium',
  ),
  creditsLines: [r'Synthetic credits: $4.20 left'],
  canCompact: true,
);

Widget _sheet(List<Override> overrides) => ProviderScope(
  overrides: overrides,
  child: MaterialApp(
    theme: AppTheme.light(TweakcnThemes.t3Chat),
    localizationsDelegates: conduitLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const Scaffold(body: HermesContextUsageSheet(sessionId: 'stored-1')),
  ),
);

List<Override> _withReport(
  Future<HermesContextReport> Function() load, {
  HermesBackendService? service,
  bool streaming = false,
}) => [
  hermesApiServiceProvider.overrideWithValue(service),
  isChatStreamingProvider.overrideWithValue(streaming),
  hermesContextReportProvider.overrideWith((ref, key) => load()),
];

/// A viewport tall enough for the whole sheet: its list builds lazily.
void _tall(WidgetTester tester) {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = const Size(800, 4000);
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() => PreferencesStore.debugOverride(InMemoryKeyValueStore()));

  testWidgets('shows the window, what fills it, totals and plan usage', (
    tester,
  ) async {
    _tall(tester);
    await tester.pumpWidget(_sheet(_withReport(() async => _desktopReport)));
    await tester.pumpAndSettle();

    expect(find.text(_l10n.hermesContextUsage), findsOneWidget);
    expect(find.text('synthetic-model'), findsOneWidget);
    expect(find.text('32,768 of 131,072 tokens'), findsOneWidget);
    expect(find.text(_l10n.hermesContextPercentFull(25)), findsOneWidget);
    expect(find.byKey(const ValueKey('hermes-context-meter')), findsOneWidget);

    // Categories Conduit has words for are translated; others keep Hermes'.
    expect(find.text(_l10n.hermesContextSystemPrompt), findsOneWidget);
    expect(find.text(_l10n.hermesContextToolDefinitions), findsOneWidget);
    expect(find.text('Synthetic skills'), findsOneWidget);

    expect(find.text(_l10n.hermesContextInput), findsOneWidget);
    expect(find.text('4,800'), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
    expect(find.text(_l10n.hermesContextCostEstimated), findsOneWidget);
    expect(find.text(r'$0.0425'), findsOneWidget);

    expect(
      find.text('Synthetic Plus · ${_l10n.hermesContextRenews('Dec 1')}'),
      findsOneWidget,
    );
    expect(find.text(_l10n.hermesContextGaugeDay), findsOneWidget);
    expect(find.text(_l10n.hermesContextUsedPercent(63)), findsOneWidget);
    expect(find.text(_l10n.hermesContextTopUp), findsOneWidget);
    expect(
      find.text(_l10n.hermesContextLeftOf(r'$5.00', r'$5.00')),
      findsOneWidget,
    );
    expect(find.text(_l10n.hermesContextRateLimited), findsOneWidget);
    expect(
      find.text(_l10n.hermesContextUsageLevel(_l10n.hermesContextLevelMedium)),
      findsOneWidget,
    );
    expect(find.text(r'Synthetic credits: $4.20 left'), findsOneWidget);
    expect(find.text(_l10n.hermesContextCompactNow), findsOneWidget);
  });

  testWidgets('an API server chat shows its totals and no Compact', (
    tester,
  ) async {
    _tall(tester);
    await tester.pumpWidget(
      _sheet(
        _withReport(
          () async => const HermesContextReport(
            totals: HermesTokenTotals(input: 900, output: 300, total: 1200),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(_l10n.hermesContextNoWindow), findsOneWidget);
    expect(find.text('900'), findsOneWidget);
    expect(find.text(_l10n.hermesContextCompactNow), findsNothing);
    expect(find.text(_l10n.hermesContextPlan), findsNothing);
  });

  testWidgets('a report that fails offers to load it again', (tester) async {
    var loads = 0;
    await tester.pumpWidget(
      _sheet(
        _withReport(() async {
          loads++;
          throw StateError('synthetic');
        }),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(_l10n.hermesContextLoadFailed), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('hermes-context-reload')));
    await tester.pumpAndSettle();
    expect(loads, 2);
  });

  testWidgets('Compact waits for a running reply', (tester) async {
    _tall(tester);
    final gateway = _Gateway();
    await tester.pumpWidget(
      _sheet(
        _withReport(
          () async => _desktopReport,
          service: _service(gateway),
          streaming: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text(_l10n.hermesContextCompactNow));
    await tester.tap(find.text(_l10n.hermesContextCompactNow));
    await tester.pumpAndSettle();

    expect(find.text(_l10n.hermesContextCompactWait), findsOneWidget);
    expect(gateway.methods, isNot(contains('session.compress')));
  });

  testWidgets('Compact now compacts with the focus and shows before and '
      'after', (tester) async {
    _tall(tester);
    final gateway = _Gateway();
    var loads = 0;
    await tester.pumpWidget(
      _sheet(
        _withReport(() async {
          loads++;
          return _desktopReport;
        }, service: _service(gateway)),
      ),
    );
    await tester.pumpAndSettle();

    final focus = find.byKey(const ValueKey('hermes-context-focus'));
    await tester.ensureVisible(focus);
    await tester.enterText(
      find.descendant(of: focus, matching: find.byType(EditableText)),
      'the dessert',
    );
    await tester.tap(find.text(_l10n.hermesContextCompactNow));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();

    final call = gateway.calls('session.compress').single;
    expect(call['session_id'], 'rt-1');
    expect(call['focus_topic'], 'the dessert');
    expect(find.text(_l10n.hermesContextCompacted), findsOneWidget);
    expect(
      find.text(_l10n.hermesContextCompactedTokens('12,351', '4,020')),
      findsOneWidget,
    );
    expect(
      find.text(_l10n.hermesContextCompactedMessages(24, 8)),
      findsOneWidget,
    );
    // The report is read again for the compacted chat.
    expect(loads, 2);
  });

  testWidgets('a compaction still running refreshes the report when done', (
    tester,
  ) async {
    _tall(tester);
    final gateway = _Gateway()
      ..answers['session.compress'] = {
        'status': 'pending',
        'turn_isolation': true,
        'message': 'compression still running in the background',
      };
    var loads = 0;
    await tester.pumpWidget(
      _sheet(
        _withReport(() async {
          loads++;
          return _desktopReport;
        }, service: _service(gateway)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text(_l10n.hermesContextCompactNow));
    await tester.tap(find.text(_l10n.hermesContextCompactNow));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();

    expect(find.text(_l10n.hermesContextCompactPending), findsOneWidget);
    expect(loads, 1);
    // Another compaction would replace this one's result before it ends.
    expect(
      tester
          .widget<ConduitButton>(
            find.byKey(const ValueKey<String>('hermes-context-compact')),
          )
          .onPressed,
      isNull,
    );

    // Hermes reports the session in once its host finishes compacting, and
    // says it is done.
    gateway.emit('session.info', {'model': 'synthetic-model'});
    gateway.emit('status.update', {'kind': 'compacted'});
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();

    expect(find.text(_l10n.hermesContextCompactPending), findsNothing);
    expect(loads, 2);
  });

  // Opened again while one ran, the sheet forgot it: Compact came back,
  // and a second compaction took over the first one's watch.
  testWidgets('a sheet opened again keeps Compact off while one runs', (
    tester,
  ) async {
    _tall(tester);
    final gateway = _Gateway()
      ..answers['session.compress'] = {
        'status': 'pending',
        'turn_isolation': true,
      };
    final service = _service(gateway);
    Widget sheet() =>
        _sheet(_withReport(() async => _desktopReport, service: service));
    ConduitButton compact() => tester.widget<ConduitButton>(
      find.byKey(const ValueKey<String>('hermes-context-compact')),
    );
    await tester.pumpWidget(sheet());
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(_l10n.hermesContextCompactNow));
    await tester.tap(find.text(_l10n.hermesContextCompactNow));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();

    // Closed, then opened again.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(sheet());
    await tester.pumpAndSettle();
    expect(compact().onPressed, isNull);

    gateway.emit('status.update', {'kind': 'compacted'});
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();
    expect(compact().onPressed, isNotNull);
  });

  // A reconnect gave the session a new runtime id, and the next change to
  // its chat brought Compact back while the first compaction still ran.
  testWidgets('Compact stays off across a reconnect while one runs', (
    tester,
  ) async {
    _tall(tester);
    final gateway = _Gateway()
      ..answers['session.compress'] = {
        'status': 'pending',
        'turn_isolation': true,
      };
    final service = _service(gateway);
    ConduitButton compact() => tester.widget<ConduitButton>(
      find.byKey(const ValueKey<String>('hermes-context-compact')),
    );
    await tester.pumpWidget(
      _sheet(_withReport(() async => _desktopReport, service: service)),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(_l10n.hermesContextCompactNow));
    await tester.tap(find.text(_l10n.hermesContextCompactNow));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();

    gateway
      ..answers['session.resume'] = {
        'session_id': 'rt-2',
        'stored_session_id': 'stored-1',
        'running': false,
      }
      ..incoming.addError(StateError('gone'));
    await tester.pump();
    // The report read resumes the session on a new socket.
    await tester.runAsync(() => service.contextReport('stored-1'));
    service.refreshTranscript('stored-1');
    await tester.pumpAndSettle();
    expect(gateway.calls('session.resume'), hasLength(2));
    expect(compact().onPressed, isNull);

    // The new socket hears the end.
    await tester.runAsync(() async {
      gateway.emit('status.update', {'kind': 'compacted'}, sessionId: 'rt-2');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    expect(compact().onPressed, isNotNull);
  });

  // A switch to another connection that landed while the sheet was open:
  // the sheet read this chat's session id through the new connection, and
  // its Compact could compact a chat of the same id there.
  testWidgets('the sheet closes when its connection changes', (tester) async {
    final first = _Elsewhere();
    final second = _Elsewhere();
    var closed = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hermesApiServiceProvider.overrideWith(
            (ref) => ref.watch(_connection),
          ),
          isChatStreamingProvider.overrideWithValue(false),
        ],
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  await showHermesContextUsageSheet(
                    context,
                    sessionId: 'stored-1',
                  );
                  closed = true;
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.text('Open')),
    );
    container.read(_connection.notifier).switchTo(first);
    await tester.pump();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byType(HermesContextUsageSheet), findsOneWidget);

    container.read(_connection.notifier).switchTo(second);
    await tester.pumpAndSettle();

    expect(find.byType(HermesContextUsageSheet), findsNothing);
    expect(closed, isTrue);
    expect(first.read, ['stored-1']);
    expect(second.read, isEmpty);
  });
}

/// The Hermes connection in use, switched by a test.
final class _Connection extends Notifier<HermesBackendService?> {
  @override
  HermesBackendService? build() => null;

  void switchTo(HermesBackendService? service) => state = service;
}

final _connection = NotifierProvider<_Connection, HermesBackendService?>(
  _Connection.new,
);

/// An API server connection that reports a chat's totals.
final class _Elsewhere extends Fake implements HermesBackendService {
  final read = <String>[];

  @override
  Future<Map<String, dynamic>?> getSession(String id) async {
    read.add(id);
    return {'input_tokens': 900, 'output_tokens': 300};
  }
}

final class _MockWebSocketChannel extends Mock implements WebSocketChannel {}

final class _MockWebSocketSink extends Mock implements WebSocketSink {}

/// A legacy gateway socket that resumes `stored-1` and compacts it.
final class _Gateway {
  _Gateway() {
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
      final frame = Map<String, dynamic>.from(
        jsonDecode(invocation.positionalArguments.single as String) as Map,
      );
      final id = frame['id'];
      final method = frame['method'];
      if (id == null || method is! String) return;
      sent.add(frame);
      scheduleMicrotask(
        () => incoming.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            'result': answers[method] ?? _answer(method),
          }),
        ),
      );
    });
  }

  final channel = _MockWebSocketChannel();
  final sink = _MockWebSocketSink();
  final incoming = StreamController<dynamic>.broadcast();
  final sent = <Map<String, dynamic>>[];
  final answers = <String, Object?>{};

  void emit(
    String type,
    Map<String, dynamic> payload, {
    String sessionId = 'rt-1',
  }) => incoming.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'method': 'event',
      'params': {'type': type, 'session_id': sessionId, 'payload': payload},
    }),
  );

  List<String> get methods => [
    for (final frame in sent) frame['method'] as String,
  ];

  List<Map<String, dynamic>> calls(String method) => [
    for (final frame in sent)
      if (frame['method'] == method)
        Map<String, dynamic>.from(frame['params'] as Map),
  ];

  Object? _answer(String method) => switch (method) {
    'session.resume' => {
      'session_id': 'rt-1',
      'stored_session_id': 'stored-1',
      'running': false,
    },
    'session.compress' => {
      'status': 'compressed',
      'before_messages': 24,
      'after_messages': 8,
      'before_tokens': 12351,
      'after_tokens': 4020,
      'summary': {'noop': false, 'aborted': false},
    },
    _ => const <String, Object?>{},
  };
}

/// Serves `/api/status` only.
final class _Rest implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    jsonEncode(
      options.uri.path == '/api/status'
          ? {'auth_required': false, 'gateway_running': true}
          : <String, Object?>{},
    ),
    200,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

HermesDesktopApiService _service(_Gateway gateway) {
  final service = HermesDesktopApiService(
    config: HermesConfig(
      enabled: true,
      baseUrl: 'https://hermes.example',
      mode: HermesBackendMode.desktopGateway,
      desktopAuthKind: HermesDesktopAuthKind.legacyToken,
      desktopCredentials: HermesDesktopCredentials(
        legacyToken: 'session-token',
      ),
    ),
    dio: Dio()..httpClientAdapter = _Rest(),
    rpc: HermesDesktopRpcClient(
      channelFactory: (_, _, {httpClient}) => gateway.channel,
    ),
    gatewayStartRetryDelays: const [Duration.zero],
  );
  addTearDown(() async {
    service.close();
    await gateway.incoming.close();
  });
  return service;
}
