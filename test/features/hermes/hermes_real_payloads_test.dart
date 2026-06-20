import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit/features/hermes/models/hermes_job.dart';
import 'package:conduit/features/hermes/models/hermes_session.dart';
import 'package:conduit/features/hermes/models/hermes_run_event.dart';
import 'package:conduit/features/hermes/models/hermes_toolset.dart';
import 'package:conduit/features/hermes/services/hermes_message_mapper.dart';
import 'package:conduit/features/hermes/services/hermes_stream_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// These fixtures are real responses captured from a live Hermes Agent server
/// (hermes.cogwheel.app), so the parsers stay locked to the actual wire format.
void main() {
  test('capabilities: real payload resolves suffixed flags', () {
    final caps = HermesCapabilities.fromJson({
      'features': {
        'run_approval_response': true,
        'approval_events': true,
        'skills_api': true,
        'session_resources': true,
        'session_fork': true,
        'jobs_admin': false,
      },
      'endpoints': {
        'toolsets': {'method': 'GET', 'path': '/v1/toolsets'},
        'sessions': {'method': 'GET', 'path': '/api/sessions'},
      },
    });
    check(caps.runApproval).isTrue();
    check(caps.skills).isTrue();
    check(caps.sessions).isTrue();
    check(caps.toolsets).isTrue();
    check(caps.jobs).isTrue(); // list surface shown
    check(caps.jobsAdmin).isFalse(); // writes disabled
  });

  test('toolsets: real payload parses tools', () {
    final ts = HermesToolset.fromJson({
      'name': 'web',
      'label': '🔍 Web Search & Scraping',
      'description': 'web_search, web_extract',
      'enabled': true,
      'configured': true,
      'tools': ['web_extract', 'web_search'],
    });
    check(ts!.tools).deepEquals(['web_extract', 'web_search']);
    check(ts.enabled).isTrue();
  });

  test('session summary: float-epoch last_active + preview', () {
    final s = HermesSessionSummary.fromJson({
      'id': '20260620_092744_a2de784a',
      'source': 'telegram',
      'title': 'Troubleshooting Missing Handoff File',
      'started_at': 1781947664.2978716,
      'last_active': 1781947724.5275855,
      'preview': 'cat: /Users/cogwheel/... No such file',
    });
    check(s!.updatedAt).isNotNull();
    check(s.updatedAt!.millisecondsSinceEpoch).equals(1781947724528);
    check(s.preview).equals('cat: /Users/cogwheel/... No such file');
    check(s.source).equals('telegram');
  });

  test('session summary: null title falls back', () {
    final s = HermesSessionSummary.fromJson({
      'id': 'cron_x',
      'source': 'cron',
      'title': null,
      'last_active': 1781946301.77,
    });
    check(s!.title).equals('Untitled session');
  });

  test('message mapper: skips session_meta, parses numeric-string timestamps', () {
    final messages = hermesMessagesToChatMessages([
      {'id': '367', 'role': 'user', 'content': 'hi', 'timestamp': '1781947673.7'},
      {'id': '368', 'role': 'assistant', 'content': 'hello', 'timestamp': '1781947673.71'},
      {'id': '369', 'role': 'session_meta', 'content': 'None'},
    ], modelId: 'hermes:agent:default');
    check(messages).has((m) => m.length, 'length').equals(2);
    check(messages[0].timestamp.year).equals(2026);
    check(messages[1].role).equals('assistant');
  });

  test('job: nested schedule object + name', () {
    final job = HermesJob.fromJson({
      'id': '2baeace557ae',
      'name': 'Monitor mentions',
      'prompt': 'long prompt...',
      'schedule': {'kind': 'cron', 'expr': '0 9 * * *', 'display': '0 9 * * *'},
      'schedule_display': '0 9 * * *',
      'enabled': true,
      'last_status': 'ok',
      'next_run_at': '2026-06-21T09:00:00+00:00',
    });
    check(job!.schedule).equals('0 9 * * *');
    check(job.displayName).equals('Monitor mentions');
    check(job.enabled).isTrue();
    check(job.nextRun).isNotNull();
  });

  test('SSE: decodes a Uint8List byte stream (Dio shape) without variance error',
      () async {
    // Dio delivers Stream<Uint8List>; runEvents casts to Stream<List<int>>.
    final bytes = utf8.encode(
      'data: {"event":"message.delta","delta":"hi"}\n\n'
      'data: {"event":"run.completed","output":"hi"}\n\n',
    );
    final uint8Stream = Stream<Uint8List>.value(Uint8List.fromList(bytes));
    final events =
        await parseHermesRunStream(uint8Stream.cast<List<int>>()).toList();
    check(events.first)
        .isA<HermesTokenDelta>()
        .has((e) => e.content, 'content')
        .equals('hi');
    check(events.last).isA<HermesRunDone>();
  });

  test('SSE: real tool.started / tool.completed events', () async {
    final frames = [
      'data: {"event":"tool.started","tool":"terminal","preview":"python3 ..."}\n\n',
      'data: {"event":"tool.completed","tool":"terminal","duration":"0.3","error":"False"}\n\n',
    ];
    final events = await parseHermesRunStream(
      Stream<List<int>>.fromIterable(frames.map(utf8.encode)),
    ).toList();

    check(events[0]).isA<HermesToolProgress>()
      ..has((e) => e.toolName, 'toolName').equals('terminal')
      ..has((e) => e.done, 'done').isFalse()
      ..has((e) => e.detail, 'detail').equals('python3 ...');
    check(events[1]).isA<HermesToolProgress>()
      ..has((e) => e.toolName, 'toolName').equals('terminal')
      ..has((e) => e.done, 'done').isTrue();
  });

  test('SSE: real message.delta / reasoning.available / run.completed', () async {
    final frames = [
      'data: {"event":"message.delta","run_id":"r","delta":"pong"}\n\n',
      'data: {"event":"reasoning.available","run_id":"r","text":"pong"}\n\n',
      'data: {"event":"run.completed","run_id":"r","output":"pong","usage":{"total_tokens":1}}\n\n',
    ];
    final events = await parseHermesRunStream(
      Stream<List<int>>.fromIterable(frames.map(utf8.encode)),
    ).toList();

    // message.delta → token; reasoning.available skipped (would duplicate);
    // run.completed → final output fallback + done.
    check(events[0])
        .isA<HermesTokenDelta>()
        .has((e) => e.content, 'content')
        .equals('pong');
    check(events.any((e) => e is HermesReasoningDelta)).isFalse();
    check(events.whereType<HermesFinalOutput>().single.text).equals('pong');
    check(events.last).isA<HermesRunDone>();
  });
}
