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
  _FakeHermesApiService(this.events, {this.runResult = const {}})
    : super(
        config: HermesConfig(
          enabled: true,
          baseUrl: 'http://x',
          apiKey: 'k',
        ),
        dio: Dio(),
      );

  final List<HermesRunEvent> events;
  final Map<String, dynamic> runResult;

  @override
  Future<String> createRun({
    required String input,
    String? sessionId,
    String? instructions,
    String? previousResponseId,
  }) async => 'run-1';

  @override
  Stream<HermesRunEvent> runEvents(
    String runId, {
    String? sessionId,
    CancelToken? cancelToken,
  }) => Stream<HermesRunEvent>.fromIterable(events);

  @override
  Future<Map<String, dynamic>> getRun(String runId) async => runResult;
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
}
