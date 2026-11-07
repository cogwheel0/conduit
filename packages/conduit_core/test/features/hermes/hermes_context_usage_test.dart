import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_chat_input.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_context_usage.dart';
import 'package:conduit_core/features/hermes/providers/hermes_context_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// `session.usage` as a legacy v0.23 gateway answers it (synthetic).
const Map<String, Object?> _legacyUsage = {
  'model': 'synthetic-model',
  'input': 4800,
  'output': 1600,
  'reasoning': 120,
  'prompt': 4800,
  'completion': 1600,
  'total': 6400,
  'calls': 4,
  'context_used': 32768,
  'context_max': 131072,
  'context_percent': 25,
  'context_source': 'provider_usage',
  'context_estimated': false,
  'compressions': 1,
  'cache_read': 2400,
  'cache_write': 300,
  'cache_hit_pct': 50,
  'cost_usd': 0.0425,
  'cost_status': 'estimated',
  'plan_gauge': {
    'id': 'day',
    'label': 'Daily',
    'used_bp': 6300,
    'resets_at_ms': 1794146400000,
  },
  'credits_lines': ['Synthetic credits: \$4.20 left'],
};

/// `session.stats` as a session authority answers it (synthetic).
const Map<String, Object?> _canonicalStats = {
  'input_tokens': 480,
  'output_tokens': 160,
  'cache_read_tokens': 120,
  'cache_write_tokens': 0,
  'prompt_tokens': 600,
  'completion_tokens': 160,
  'total_tokens': 640,
  'reasoning_tokens': 0,
  'api_calls': 4,
  'last_prompt_tokens': 300,
  'context_tokens': 410,
  'context_length': 131072,
  'config_context_length': 131072,
  'context_source': 'provider_usage',
  'compression_count': 2,
  'last_turn_tokens': 40,
  'active_subagents': 0,
  'model': 'synthetic-model',
  'provider': 'custom',
};

const Map<String, Object?> _breakdown = {
  'categories': [
    {
      'color': 'var(--context-usage-system)',
      'id': 'system_prompt',
      'label': 'System prompt',
      'tokens': 2545,
    },
    {
      'color': 'var(--context-usage-tools)',
      'id': 'tool_definitions',
      'label': 'Tool definitions',
      'tokens': 8929,
    },
    {
      'color': 'var(--context-usage-conversation)',
      'id': 'conversation',
      'label': 'Conversation',
      'tokens': 391,
    },
    {'id': 'empty', 'label': 'Empty', 'tokens': 0},
  ],
  'estimated_total': 11865,
  'context_max': 131072,
  'context_percent': 0,
  'context_used': 160,
  'context_source': 'provider_usage',
  'context_estimated': false,
  'model': 'synthetic-model',
};

const Map<String, Object?> _bars = {
  'ok': true,
  'available': true,
  'plan_name': 'Synthetic Plus',
  'renews_display': 'Dec 1',
  'plan_bar': {
    'kind': 'plan',
    'remaining_display': r'$12.00',
    'total_display': r'$20.00',
    'spent_display': r'$8.00',
    'pct_used': 40,
    'fill_fraction': 0.4,
  },
  'topup_bar': {
    'kind': 'topup',
    'remaining_display': r'$5.00',
    'total_display': r'$5.00',
    'spent_display': r'$0.00',
    'fill_fraction': 0.0,
  },
};

const Map<String, Object?> _modelOptions = {
  'model': 'synthetic-model',
  'provider': 'nous',
  'providers': [
    {'slug': 'other', 'name': 'Other', 'is_current': false},
    {
      'slug': 'nous',
      'name': 'Synthetic Portal',
      'is_current': true,
      'plan_usage': {
        'kind': 'window',
        'plan': 'Synthetic Plus',
        'gauges': [
          {
            'label': 'day',
            'left_fraction': 0.25,
            'style': 'bar',
            'resets_at_ms': 1794146400000,
          },
          {
            'label': 'burst',
            'title': 'Burst',
            'left_fraction': 1,
            'style': 'bar',
          },
        ],
      },
      'limit': {
        'scope': 'models',
        'models': {'synthetic-model': '2026-11-07T15:00:00Z'},
      },
      'usage_levels': {'synthetic-model': 'medium'},
    },
  ],
};

void main() {
  setUp(() => PreferencesStore.debugOverride(InMemoryKeyValueStore()));

  group('a legacy gateway report', () {
    final report = hermesDesktopContextReport(
      usage: Map.of(_legacyUsage),
      breakdown: Map.of(_breakdown),
      bars: Map.of(_bars),
      modelOptions: Map.of(_modelOptions),
    );

    test('reads the window from the usage counters', () {
      check(report.model).equals('synthetic-model');
      check(report.contextUsed).equals(32768);
      check(report.contextMax).equals(131072);
      check(report.contextFraction).equals(0.25);
      check(report.estimatedTotal).equals(11865);
      check(report.canCompact).isTrue();
    });

    test('lists the categories that hold tokens', () {
      check(report.categories.map((category) => category.id))
          .deepEquals(['system_prompt', 'tool_definitions', 'conversation']);
    });

    test('keeps the totals, cache and cost', () {
      final totals = report.totals;
      check(totals.input).equals(4800);
      check(totals.output).equals(1600);
      check(totals.reasoning).equals(120);
      check(totals.cacheRead).equals(2400);
      check(totals.cacheHitPercent).equals(50);
      check(totals.calls).equals(4);
      check(totals.compressions).equals(1);
      check(totals.costUsd).equals(0.0425);
      check(totals.costEstimated).isTrue();
    });

    test('reads the plan gauge, bars, credits and provider plan', () {
      final gauge = report.planGauges.single;
      check(gauge.id).equals('day');
      check(gauge.usedFraction).equals(0.63);
      check(gauge.resetsAt).isNotNull();
      check(report.creditsLines).deepEquals([r'Synthetic credits: $4.20 left']);
      check(report.usageBars?.planName).equals('Synthetic Plus');
      check(report.usageBars?.plan?.usedPercent).equals(40);
      check(report.usageBars?.topup?.remaining).equals(r'$5.00');
      final plan = report.providerPlan!;
      check(plan.provider).equals('Synthetic Portal');
      check(plan.gauges.map((gauge) => gauge.id)).deepEquals(['day', 'burst']);
      check(plan.gauges.first.usedFraction).equals(0.75);
      check(plan.gauges.last.title).equals('Burst');
      check(plan.rateLimited).isTrue();
      check(plan.rateLimitedUntil).equals(DateTime.utc(2026, 11, 7, 15));
      check(plan.usageLevel).equals('medium');
    });
  });

  test('totals with only reasoning, cache or compactions are not empty', () {
    check(const HermesTokenTotals().isEmpty).isTrue();
    check(const HermesTokenTotals(input: 0, calls: 0).isEmpty).isTrue();
    for (final totals in const [
      HermesTokenTotals(reasoning: 120),
      HermesTokenTotals(cacheRead: 2400),
      HermesTokenTotals(cacheWrite: 300),
      HermesTokenTotals(cacheHitPercent: 50),
      HermesTokenTotals(compressions: 1),
    ]) {
      check(totals.isEmpty).isFalse();
    }
  });

  test('unavailable bars and a plain provider add nothing', () {
    final report = hermesDesktopContextReport(
      usage: Map.of(_legacyUsage),
      bars: {'ok': true, 'available': false},
      modelOptions: {
        'model': 'stub',
        'provider': 'custom',
        'providers': [
          {'slug': 'custom', 'name': 'Custom endpoint', 'is_current': true},
        ],
      },
    );

    check(report.usageBars).isNull();
    check(report.providerPlan).isNull();
  });

  test('a session authority report maps its stats', () {
    final report = hermesDesktopContextReport(
      stats: Map.of(_canonicalStats),
      breakdown: Map.of(_breakdown),
    );

    check(report.contextUsed).equals(300);
    check(report.contextMax).equals(131072);
    check(report.totals.input).equals(480);
    check(report.totals.cacheHitPercent).equals(20);
    check(report.totals.compressions).equals(2);
  });

  test('a report without a window falls back to the breakdown, then the '
      'last turn', () {
    final fromBreakdown = hermesDesktopContextReport(
      stats: {..._canonicalStats, 'context_length': null},
      breakdown: Map.of(_breakdown),
    );
    check(fromBreakdown.contextUsed).equals(160);

    final fromTurn = hermesDesktopContextReport(
      stats: const {'api_calls': 0},
      lastTurnUsage: {'context_used': 90, 'context_max': 8192},
    );
    check(fromTurn.contextUsed).equals(90);
    check(fromTurn.contextMax).equals(8192);
  });

  test('an API server report has totals and no window', () {
    final report = hermesRestContextReport({
      'id': 'synthetic-session',
      'model': 'synthetic-model',
      'input_tokens': 900,
      'output_tokens': 300,
      'cache_read_tokens': 100,
      'reasoning_tokens': 20,
      'api_call_count': 3,
      'estimated_cost_usd': 0.012,
      'actual_cost_usd': null,
    });

    check(report.contextFraction).isNull();
    check(report.canCompact).isFalse();
    check(report.totals.total).equals(1200);
    check(report.totals.calls).equals(3);
    check(report.totals.costUsd).equals(0.012);
    check(report.totals.costEstimated).isTrue();
  });

  group('a compaction result', () {
    test('from a legacy gateway reports tokens and messages', () {
      final result = HermesCompactResult.fromJson({
        'status': 'compressed',
        'removed': 6,
        'before_messages': 24,
        'after_messages': 8,
        'before_tokens': 12351,
        'after_tokens': 4020,
        'summary': {
          'noop': false,
          'aborted': false,
          'headline': 'Compressed: 24 → 8 messages',
          'token_line': 'Approx request size: ~12,351 → ~4,020 tokens',
        },
      });

      check(result.outcome).equals(HermesCompactOutcome.compacted);
      check(result.changed).isTrue();
      check(result.beforeTokens).equals(12351);
      check(result.afterTokens).equals(4020);
      check(result.beforeMessages).equals(24);
      check(result.afterMessages).equals(8);
    });

    test('from a session authority reads its token line', () {
      final result = HermesCompactResult.fromJson({
        'operation': 'compress',
        'message_count': 6,
        'summary': {
          'noop': false,
          'aborted': false,
          'refused_would_grow': false,
          'headline': 'Compressed: 8 → 6 messages',
          'token_line': 'Approx request size: ~1,404 → ~1,027 tokens',
        },
      });

      check(result.outcome).equals(HermesCompactOutcome.compacted);
      check(result.beforeTokens).equals(1404);
      check(result.afterTokens).equals(1027);
      check(result.afterMessages).equals(6);
    });

    test('that would grow the chat is refused', () {
      final result = HermesCompactResult.fromJson({
        'status': 'compressed',
        'summary': {'noop': true, 'refused_would_grow': true},
      });

      check(result.outcome).equals(HermesCompactOutcome.refused);
      check(result.changed).isFalse();
    });

    test('of a short chat changes nothing', () {
      check(
        HermesCompactResult.fromJson({
          'status': 'noop',
          'summary': {'noop': true},
        }).outcome,
      ).equals(HermesCompactOutcome.unchanged);
    });

    test('held by another compaction is busy', () {
      check(
        HermesCompactResult.fromJson({
          'compressed': false,
          'lock_held': true,
          'message': 'Synthetic lock holder.',
        }).outcome,
      ).equals(HermesCompactOutcome.busy);
    });
  });

  group('a legacy gateway', () {
    test('reads usage, breakdown, bars and the plan row', () async {
      final gateway = _Gateway();
      final service = _service(gateway);

      final report = await service.contextReport('stored-1');

      check(report.contextUsed).equals(32768);
      check(report.usageBars?.planName).equals('Synthetic Plus');
      for (final method in [
        'session.usage',
        'session.context_breakdown',
        'model.options',
      ]) {
        check(gateway.calls(method).single['session_id']).equals('rt-1');
      }
      check(gateway.calls('usage.bars')).length.equals(1);
      check(gateway.calls('session.stats')).isEmpty();
    });

    test('leaves out a read it refuses', () async {
      final gateway = _Gateway()
        ..refuse('usage.bars')
        ..refuse('model.options');
      final service = _service(gateway);

      final report = await service.contextReport('stored-1');

      check(report.usageBars).isNull();
      check(report.providerPlan).isNull();
      check(report.contextMax).equals(131072);
    });

    test('fails when neither usage nor breakdown answers', () async {
      final gateway = _Gateway()
        ..refuse('session.usage')
        ..refuse('session.context_breakdown');
      final service = _service(gateway);

      await check(service.contextReport('stored-1'))
          .throws<HermesDesktopRpcException>();
    });

    test('compacts with a focus topic and reloads the chat', () async {
      final gateway = _Gateway();
      final service = _service(gateway);
      final changes = <String>[];
      final subscription = service.transcriptChanges.listen(changes.add);
      addTearDown(subscription.cancel);

      final result = await service.compactSession(
        'stored-1',
        focus: ' the dessert ',
      );
      await _settle();

      check(result.outcome).equals(HermesCompactOutcome.compacted);
      check(result.beforeTokens).equals(12351);
      final call = gateway.calls('session.compress').single;
      check(call['session_id']).equals('rt-1');
      check(call['focus_topic']).equals('the dessert');
      check(changes).deepEquals(['stored-1']);
      // The shorter read that follows replaces the chat's messages, once.
      check(service.takeCompactedTranscript('stored-1')).isTrue();
      check(service.takeCompactedTranscript('stored-1')).isFalse();
    });

    test('tells the chat of each change, twice for one chat', () async {
      final gateway = _Gateway();
      final service = _service(gateway);
      final container = ProviderContainer(
        overrides: [hermesApiServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);
      final seen = <String>[];
      container.listen(
        hermesDesktopTranscriptChangesProvider,
        (_, next) => next.whenData((change) => seen.add(change.storedId)),
      );

      await service.compactSession('stored-1');
      await _settle();
      await service.compactSession('stored-1');
      await _settle();

      check(seen).deepEquals(['stored-1', 'stored-1']);
    });

    test('reloads the chat when a background compaction finishes', () async {
      final gateway = _Gateway()
        ..answers['session.compress'] = {
          'status': 'pending',
          'turn_isolation': true,
          'message': 'compression still running in the background',
        };
      final service = _service(gateway);
      final changes = <String>[];
      final subscription = service.transcriptChanges.listen(changes.add);
      addTearDown(subscription.cancel);

      final result = await service.compactSession('stored-1');
      await _settle();

      check(result.outcome).equals(HermesCompactOutcome.pending);
      // Nothing changed yet: the chat keeps what it shows.
      check(changes).isEmpty();
      check(service.takeCompactedTranscript('stored-1')).isFalse();

      gateway.emit('session.info', {'model': 'synthetic-model'});
      await _settle();

      check(changes).deepEquals(['stored-1']);
      check(service.takeCompactedTranscript('stored-1')).isTrue();

      // Only once: a later info is the session's own business.
      gateway.emit('session.info', {'model': 'synthetic-model'});
      await _settle();
      check(changes).deepEquals(['stored-1']);
    });

    test('leaves the chat alone when nothing was compacted', () async {
      final gateway = _Gateway()
        ..answers['session.compress'] = {
          'status': 'compressed',
          'summary': {'noop': true, 'refused_would_grow': true},
        };
      final service = _service(gateway);
      final changes = <String>[];
      final subscription = service.transcriptChanges.listen(changes.add);
      addTearDown(subscription.cancel);

      final result = await service.compactSession('stored-1');
      await _settle();

      check(result.outcome).equals(HermesCompactOutcome.refused);
      check(gateway.calls('session.compress').single.containsKey('focus_topic'))
          .isFalse();
      check(changes).isEmpty();
    });

    test('keeps the last turn usage for a window the reads lack', () async {
      final gateway = _Gateway()
        ..answers['session.usage'] = {'calls': 0, 'input': 0}
        ..answers['session.context_breakdown'] = {'categories': <Object?>[]};
      final service = _service(gateway);
      final response = await service.streamDesktopResponse(
        HermesChatInput.text('Plan a synthetic picnic'),
        sessionId: 'stored-1',
        options: const HermesDesktopSessionOptions(),
      );
      final events = response.events.toList();
      await _settle();
      gateway
        ..emit('message.start', const {})
        ..emit('message.complete', {
          'text': 'Synthetic reply.',
          'status': 'complete',
          'usage': {'context_used': 900, 'context_max': 8192},
        })
        ..emit('session.info', {'running': false});
      await events.timeout(const Duration(seconds: 5));

      final report = await service.contextReport('stored-1');

      check(report.contextUsed).equals(900);
      check(report.contextMax).equals(8192);
    });
  });

  group('a session authority', () {
    test('reads its stats instead of session usage', () async {
      final gateway = _Gateway(authority: true);
      final service = _service(gateway);

      final report = await service.contextReport('stored-1');

      check(report.contextUsed).equals(300);
      check(gateway.calls('session.stats').single['session_id']).equals('rt-1');
      check(gateway.calls('session.usage')).isEmpty();
    });

    test('compacts as a fenced compress edit', () async {
      final gateway = _Gateway(authority: true);
      final service = _service(gateway);

      final result = await service.compactSession('stored-1', focus: 'fruit');

      check(result.outcome).equals(HermesCompactOutcome.compacted);
      check(result.afterTokens).equals(1027);
      final edit = gateway.calls('session.mutate').single;
      check(edit['operation']).equals('compress');
      check(edit['payload'] as Map).deepEquals({'focus': 'fruit'});
      check(edit['expected_revision']).equals(5);
      check(gateway.calls('session.compress')).isEmpty();
    });
  });

  test('an API server chat reads its session row', () async {
    final rest = HermesApiService(
      config: HermesConfig(
        enabled: true,
        baseUrl: 'https://hermes.example',
        apiKey: 'synthetic-key',
      ),
      dio: Dio()
        ..httpClientAdapter = _Rest({
          '/api/sessions/synthetic-session': {
            'session': {
              'id': 'synthetic-session',
              'input_tokens': 900,
              'output_tokens': 300,
              'actual_cost_usd': 0.02,
            },
          },
        }),
    );
    addTearDown(rest.close);

    final report = await loadHermesContextReport(rest, 'synthetic-session');

    check(report.totals.total).equals(1200);
    check(report.totals.costUsd).equals(0.02);
    check(report.totals.costEstimated).isFalse();
    check(report.canCompact).isFalse();
  });
}

final class _MockWebSocketChannel extends Mock implements WebSocketChannel {}

final class _MockWebSocketSink extends Mock implements WebSocketSink {}

/// A gateway socket answering a chat's resume and its context reads; the
/// legacy wire, or a session authority's canonical wire when [authority].
final class _Gateway {
  _Gateway({this.authority = false}) {
    when(() => channel.ready).thenAnswer((_) async {});
    when(() => channel.stream).thenAnswer((_) {
      scheduleMicrotask(
        () => emit('gateway.ready', {'session_authority': authority}),
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
      final reply = refused.contains(method)
          ? {
              'error': {'code': -32601, 'message': 'unknown method: $method'},
            }
          : {'result': answers[method] ?? _answer(method)};
      scheduleMicrotask(
        () => incoming.add(jsonEncode({'jsonrpc': '2.0', 'id': id, ...reply})),
      );
    });
  }

  final bool authority;
  final channel = _MockWebSocketChannel();
  final sink = _MockWebSocketSink();
  final incoming = StreamController<dynamic>.broadcast();
  final sent = <Map<String, dynamic>>[];
  final refused = <String>{};
  final answers = <String, Object?>{};

  void refuse(String method) => refused.add(method);

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
      if (authority) ...{
        'revision': 5,
        'execution_generation': 2,
        'subscription_id': 'sub-1',
        'info': {'desktop_protocol': kHermesCanonicalGatewayProtocol},
      },
    },
    'prompt.submit' =>
      authority ? {'admission_id': 'adm-1'} : {'status': 'streaming'},
    'config.get' => {'value': 'medium'},
    'session.usage' => _legacyUsage,
    'session.stats' => _canonicalStats,
    'session.context_breakdown' => _breakdown,
    'usage.bars' => _bars,
    'model.options' => _modelOptions,
    'session.compress' => {
      'status': 'compressed',
      'before_messages': 24,
      'after_messages': 8,
      'before_tokens': 12351,
      'after_tokens': 4020,
      'summary': {'noop': false, 'aborted': false},
      'messages': <Object?>[],
    },
    'session.mutate' => {
      'revision': 6,
      'execution_generation': 3,
      'operation': 'compress',
      'message_count': 6,
      'summary': {
        'noop': false,
        'token_line': 'Approx request size: ~1,404 → ~1,027 tokens',
      },
    },
    _ => const <String, Object?>{},
  };

  void emit(String type, Map<String, dynamic> payload) => incoming.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'method': 'event',
      'params': {
        'type': type,
        if (type != 'gateway.ready') 'session_id': 'rt-1',
        'payload': payload,
      },
    }),
  );
}

/// Serves `/api/status` and the paths in [routes].
final class _Rest implements HttpClientAdapter {
  _Rest([this.routes = const {}]);

  final Map<String, Object?> routes;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    final body = path == '/api/status'
        ? {'auth_required': false, 'gateway_running': true}
        : routes[path] ?? <String, Object?>{};
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
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

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
