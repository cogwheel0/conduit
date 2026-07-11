import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/features/hermes/models/hermes_config.dart';
import 'package:conduit/features/hermes/models/hermes_run_event.dart';
import 'package:conduit/features/hermes/providers/hermes_providers.dart';
import 'package:conduit/features/hermes/services/hermes_api_service.dart';
import 'package:conduit/features/hermes/services/hermes_run_transport.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeHermesApiService extends HermesApiService {
  _FakeHermesApiService(
    this.events, {
    this.runResult = const {},
    this.runResults = const [],
    this.eventsOverride,
    this.createRunGate,
    this.getRunGate,
    this.stopRunGate,
    this.stopRunError,
  }) : super(
         config: HermesConfig(enabled: true, baseUrl: 'http://x', apiKey: 'k'),
         dio: Dio(),
       );

  final List<HermesRunEvent> events;
  final Map<String, dynamic> runResult;
  final List<Map<String, dynamic>> runResults;
  final Stream<HermesRunEvent>? eventsOverride;
  final Completer<String>? createRunGate;
  final Completer<Map<String, dynamic>>? getRunGate;
  final Completer<void>? stopRunGate;
  final Object? stopRunError;
  var getRunCalls = 0;
  final List<String> stoppedRuns = [];
  CancelToken? lastStopCancelToken;

  @override
  Future<String> createRun({
    required String input,
    String? sessionId,
    String? instructions,
    String? previousResponseId,
    CancelToken? cancelToken,
  }) async => createRunGate?.future ?? 'run-1';

  @override
  Stream<HermesRunEvent> runEvents(
    String runId, {
    String? sessionId,
    CancelToken? cancelToken,
  }) => eventsOverride ?? Stream<HermesRunEvent>.fromIterable(events);

  @override
  Future<Map<String, dynamic>> getRun(
    String runId, {
    CancelToken? cancelToken,
  }) async {
    final index = getRunCalls++;
    if (getRunGate != null) return getRunGate!.future;
    if (runResults.isNotEmpty) {
      return runResults[index.clamp(0, runResults.length - 1)];
    }
    return runResult;
  }

  @override
  Future<void> stopRun(String runId, {CancelToken? cancelToken}) async {
    stoppedRuns.add(runId);
    lastStopCancelToken = cancelToken;
    await stopRunGate?.future;
    final error = stopRunError;
    if (error != null) throw error;
  }
}

void main() {
  test('dispatchHermesRun maps events onto chat callbacks', () async {
    final fake = _FakeHermesApiService([
      const HermesToolProgress(toolName: 'web_search', done: false),
      const HermesTokenDelta('Hello'),
      const HermesTokenDelta(' world'),
      const HermesToolProgress(toolName: 'web_search', done: true),
      const HermesApprovalRequested(approvalId: 'a1', summary: 'ok?'),
      const HermesRunDone(),
    ]);

    final content = StringBuffer();
    final statuses = <ChatStatusUpdate>[];
    var message = ChatMessage(
      id: 'm',
      role: 'assistant',
      content: '',
      timestamp: DateTime.fromMillisecondsSinceEpoch(0),
    );
    var finished = false;
    var completedUi = false;

    await dispatchHermesRun(
      service: fake,
      registry: HermesRunRegistry(),
      assistantMessageId: 'm',
      input: 'hi',
      appendContent: content.write,
      appendStatus: statuses.add,
      updateMessage: (updater) => message = updater(message),
      finishStreaming: () => finished = true,
      completeStreamingUi: () => completedUi = true,
    );

    check(content.toString()).equals('Hello world');
    check(statuses).has((s) => s.length, 'length').equals(2);
    check(statuses.first.done).equals(false);
    check(statuses.last.done).equals(true);

    check(message.metadata?['transport']).equals(kHermesTransport);
    check(message.metadata?['hermesRunId']).equals('run-1');

    final approval = message.metadata?[kHermesApprovalMeta] as Map?;
    check(approval).isNotNull();
    check(approval!['state']).equals('pending');
    check(approval['approvalId']).equals('a1');

    check(finished).isTrue();
    check(completedUi).isTrue();
  });

  test('appends final output when no deltas streamed', () async {
    final fake = _FakeHermesApiService(const [
      HermesFinalOutput('Only the final'),
      HermesRunDone(),
    ]);
    final content = StringBuffer();
    await dispatchHermesRun(
      service: fake,
      registry: HermesRunRegistry(),
      assistantMessageId: 'm',
      input: 'hi',
      appendContent: content.write,
      appendStatus: (_) {},
      updateMessage: (_) {},
      finishStreaming: () {},
      completeStreamingUi: () {},
    );
    check(content.toString()).equals('Only the final');
  });

  test('does not duplicate when deltas and final output both arrive', () async {
    final fake = _FakeHermesApiService(const [
      HermesTokenDelta('pong'),
      HermesFinalOutput('pong'),
      HermesRunDone(),
    ]);
    final content = StringBuffer();
    await dispatchHermesRun(
      service: fake,
      registry: HermesRunRegistry(),
      assistantMessageId: 'm',
      input: 'hi',
      appendContent: content.write,
      appendStatus: (_) {},
      updateMessage: (_) {},
      finishStreaming: () {},
      completeStreamingUi: () {},
    );
    check(content.toString()).equals('pong');
  });

  test('appends missing suffix from authoritative terminal output', () async {
    final fake = _FakeHermesApiService(const [
      HermesTokenDelta('Hello'),
      HermesFinalOutput('Hello world'),
      HermesRunDone(),
    ]);
    final content = StringBuffer();

    await dispatchHermesRun(
      service: fake,
      registry: HermesRunRegistry(),
      assistantMessageId: 'm',
      input: 'hi',
      appendContent: content.write,
      appendStatus: (_) {},
      updateMessage: (_) {},
      finishStreaming: () {},
      completeStreamingUi: () {},
    );

    check(content.toString()).equals('Hello world');
  });

  test(
    'replaces streamed text when terminal output corrects its prefix',
    () async {
      final fake = _FakeHermesApiService(const [
        HermesTokenDelta('Helo'),
        HermesFinalOutput('Hello world'),
        HermesRunDone(),
      ]);
      var content = '';

      await dispatchHermesRun(
        service: fake,
        registry: HermesRunRegistry(),
        assistantMessageId: 'm',
        input: 'hi',
        appendContent: (delta) => content += delta,
        replaceContent: (value) => content = value,
        appendStatus: (_) {},
        updateMessage: (_) {},
        finishStreaming: () {},
        completeStreamingUi: () {},
      );

      check(content).equals('Hello world');
    },
  );

  test('terminal event completes dispatch while SSE remains open', () async {
    final events = StreamController<HermesRunEvent>();
    addTearDown(events.close);
    final fake = _FakeHermesApiService(const [], eventsOverride: events.stream);
    final dispatch = dispatchHermesRun(
      service: fake,
      registry: HermesRunRegistry(),
      assistantMessageId: 'm',
      input: 'hi',
      appendContent: (_) {},
      appendStatus: (_) {},
      updateMessage: (_) {},
      finishStreaming: () {},
      completeStreamingUi: () {},
    );

    events.add(const HermesRunDone());
    await dispatch.timeout(const Duration(seconds: 1));
  });

  test('stop during createRun stops the remote id once it arrives', () async {
    final gate = Completer<String>();
    final registry = HermesRunRegistry();
    final fake = _FakeHermesApiService(const [], createRunGate: gate);
    final dispatch = dispatchHermesRun(
      service: fake,
      registry: registry,
      assistantMessageId: 'm',
      input: 'hi',
      appendContent: (_) {},
      appendStatus: (_) {},
      updateMessage: (_) {},
      finishStreaming: () {},
      completeStreamingUi: () {},
    );

    registry.cancel('m');
    gate.complete('run-late');

    await dispatch.timeout(const Duration(seconds: 1));
    check(fake.stoppedRuns).deepEquals(['run-late']);
  });

  test('late create cleanup uses a fresh bounded stop token', () async {
    final createGate = Completer<String>();
    final stopGate = Completer<void>();
    final runToken = CancelToken();
    final registry = HermesRunRegistry();
    final fake = _FakeHermesApiService(
      const [],
      createRunGate: createGate,
      stopRunGate: stopGate,
    );
    final dispatch = dispatchHermesRun(
      service: fake,
      registry: registry,
      assistantMessageId: 'm',
      input: 'hi',
      cancelToken: runToken,
      remoteStopTimeout: const Duration(milliseconds: 10),
      appendContent: (_) {},
      appendStatus: (_) {},
      updateMessage: (_) {},
      finishStreaming: () {},
      completeStreamingUi: () {},
    );

    registry.cancel('m');
    createGate.complete('run-late');
    await dispatch.timeout(const Duration(seconds: 1));

    check(fake.stoppedRuns).deepEquals(['run-late']);
    check(fake.lastStopCancelToken).isNotNull();
    check(identical(fake.lastStopCancelToken, runToken)).isFalse();
    check(fake.lastStopCancelToken!.isCancelled).isTrue();
    stopGate.complete();
  });

  test('stop after registration completes dispatch cleanup', () async {
    final events = StreamController<HermesRunEvent>();
    addTearDown(events.close);
    final registry = HermesRunRegistry();
    final fake = _FakeHermesApiService(const [], eventsOverride: events.stream);
    final dispatch = dispatchHermesRun(
      service: fake,
      registry: registry,
      assistantMessageId: 'm',
      input: 'hi',
      appendContent: (_) {},
      appendStatus: (_) {},
      updateMessage: (_) {},
      finishStreaming: () {},
      completeStreamingUi: () {},
    );

    while (registry.runIdFor('m') == null) {
      await Future<void>.delayed(Duration.zero);
    }
    final stop = registry.cancel('m');
    check(stop).isNotNull();
    await stop!;

    await dispatch.timeout(const Duration(seconds: 1));
    check(registry.runIdFor('m')).isNull();
    check(fake.stoppedRuns).deepEquals(['run-1']);
  });

  test(
    'remote stop failure is surfaced without poisoning cancellation',
    () async {
      final events = StreamController<HermesRunEvent>();
      addTearDown(events.close);
      final registry = HermesRunRegistry();
      final fake = _FakeHermesApiService(
        const [],
        eventsOverride: events.stream,
        stopRunError: StateError('offline'),
      );
      var message = ChatMessage(
        id: 'm',
        role: 'assistant',
        content: '',
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      );
      final dispatch = dispatchHermesRun(
        service: fake,
        registry: registry,
        assistantMessageId: 'm',
        input: 'hi',
        appendContent: (_) {},
        appendStatus: (_) {},
        updateMessage: (updater) => message = updater(message),
        finishStreaming: () {},
        completeStreamingUi: () {},
      );

      while (registry.runIdFor('m') == null) {
        await Future<void>.delayed(Duration.zero);
      }
      final cancellation = registry.cancel('m');
      check(cancellation).isNotNull();
      await cancellation;
      await dispatch.timeout(const Duration(seconds: 1));

      check(message.error).isNotNull();
      expect(message.error!.content, contains('may still be running'));
    },
  );

  test('recovers final output when the event stream drops', () async {
    // Stream ends with no terminal event (dropped); getRun reconciles it.
    final fake = _FakeHermesApiService(
      const [],
      runResult: const {'status': 'completed', 'output': 'Recovered answer'},
    );

    final content = StringBuffer();
    var message = ChatMessage(
      id: 'm',
      role: 'assistant',
      content: '',
      timestamp: DateTime.fromMillisecondsSinceEpoch(0),
    );

    await dispatchHermesRun(
      service: fake,
      registry: HermesRunRegistry(),
      assistantMessageId: 'm',
      input: 'hi',
      appendContent: content.write,
      appendStatus: (_) {},
      updateMessage: (updater) => message = updater(message),
      finishStreaming: () {},
      completeStreamingUi: () {},
    );

    check(content.toString()).equals('Recovered answer');
  });

  test(
    'recovery discards a getRun result that arrives after cancellation',
    () async {
      final getRunGate = Completer<Map<String, dynamic>>();
      final runToken = CancelToken();
      final fake = _FakeHermesApiService(const [], getRunGate: getRunGate);
      final content = StringBuffer();
      var message = ChatMessage(
        id: 'm',
        role: 'assistant',
        content: '',
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      );

      final dispatch = dispatchHermesRun(
        service: fake,
        registry: HermesRunRegistry(),
        assistantMessageId: 'm',
        input: 'hi',
        cancelToken: runToken,
        appendContent: content.write,
        appendStatus: (_) {},
        updateMessage: (updater) => message = updater(message),
        finishStreaming: () {},
        completeStreamingUi: () {},
      );
      while (fake.getRunCalls == 0) {
        await Future<void>.delayed(Duration.zero);
      }

      runToken.cancel('stopped');
      getRunGate.complete(const {
        'status': 'completed',
        'output': 'Late answer',
      });
      await dispatch.timeout(const Duration(seconds: 1));

      check(content.toString()).isEmpty();
      check(message.error).isNull();
    },
  );

  test('recovery suppresses getRun errors caused by cancellation', () async {
    final getRunGate = Completer<Map<String, dynamic>>();
    final runToken = CancelToken();
    final fake = _FakeHermesApiService(const [], getRunGate: getRunGate);
    var message = ChatMessage(
      id: 'm',
      role: 'assistant',
      content: '',
      timestamp: DateTime.fromMillisecondsSinceEpoch(0),
    );

    final dispatch = dispatchHermesRun(
      service: fake,
      registry: HermesRunRegistry(),
      assistantMessageId: 'm',
      input: 'hi',
      cancelToken: runToken,
      appendContent: (_) {},
      appendStatus: (_) {},
      updateMessage: (updater) => message = updater(message),
      finishStreaming: () {},
      completeStreamingUi: () {},
    );
    while (fake.getRunCalls == 0) {
      await Future<void>.delayed(Duration.zero);
    }

    runToken.cancel('stopped');
    getRunGate.completeError(StateError('request cancelled'));
    await dispatch.timeout(const Duration(seconds: 1));

    check(message.error).isNull();
  });

  test('recovered remote cancellation is not reported as success', () async {
    for (final status in const ['cancelled', 'canceled', 'stopped']) {
      final fake = _FakeHermesApiService(
        const [],
        runResult: {'status': status, 'output': 'Partial answer'},
      );
      var message = ChatMessage(
        id: 'm-$status',
        role: 'assistant',
        content: '',
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      );

      await dispatchHermesRun(
        service: fake,
        registry: HermesRunRegistry(),
        assistantMessageId: message.id,
        input: 'hi',
        appendContent: (_) {},
        appendStatus: (_) {},
        updateMessage: (updater) => message = updater(message),
        finishStreaming: () {},
        completeStreamingUi: () {},
      );

      check(message.error).isNotNull();
    }
  });

  test(
    'recovery waits for terminal state and ignores running output',
    () async {
      final fake = _FakeHermesApiService(
        const [],
        runResults: const [
          {'status': 'running', 'output': 'Partial'},
          {'status': 'completed', 'output': 'Complete answer'},
        ],
      );
      final content = StringBuffer();

      await dispatchHermesRun(
        service: fake,
        registry: HermesRunRegistry(),
        assistantMessageId: 'm',
        input: 'hi',
        appendContent: content.write,
        appendStatus: (_) {},
        updateMessage: (_) {},
        finishStreaming: () {},
        completeStreamingUi: () {},
      ).timeout(const Duration(seconds: 3));

      check(fake.getRunCalls).equals(2);
      check(content.toString()).equals('Complete answer');
    },
  );

  test('recovery stops after the configured poll budget', () async {
    final fake = _FakeHermesApiService(
      const [],
      runResult: const {'status': 'running', 'output': 'Partial'},
    );
    var message = ChatMessage(
      id: 'm',
      role: 'assistant',
      content: '',
      timestamp: DateTime.fromMillisecondsSinceEpoch(0),
    );

    await dispatchHermesRun(
      service: fake,
      registry: HermesRunRegistry(),
      assistantMessageId: 'm',
      input: 'hi',
      maxRecoveryPolls: 2,
      recoveryPollInterval: Duration.zero,
      appendContent: (_) {},
      appendStatus: (_) {},
      updateMessage: (updater) => message = updater(message),
      finishStreaming: () {},
      completeStreamingUi: () {},
    );

    check(fake.getRunCalls).equals(2);
    check(message.error).isNotNull();
  });

  test(
    'recovery surfaces repeated successful responses with unknown status',
    () async {
      final fake = _FakeHermesApiService(
        const [],
        runResult: const {'status': 'mystery', 'output': 'not final'},
      );
      var message = ChatMessage(
        id: 'm',
        role: 'assistant',
        content: '',
        timestamp: DateTime.fromMillisecondsSinceEpoch(0),
      );

      await dispatchHermesRun(
        service: fake,
        registry: HermesRunRegistry(),
        assistantMessageId: 'm',
        input: 'hi',
        appendContent: (_) {},
        appendStatus: (_) {},
        updateMessage: (updater) => message = updater(message),
        finishStreaming: () {},
        completeStreamingUi: () {},
      ).timeout(const Duration(seconds: 4));

      check(fake.getRunCalls).equals(3);
      check(message.error).isNotNull();
    },
  );
}
