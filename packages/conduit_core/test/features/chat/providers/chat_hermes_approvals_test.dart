import 'dart:async';
import 'dart:typed_data';

import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_transport.dart';
import 'package:conduit_core/features/hermes/services/hermes_run_transport.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// A Hermes server that records each answer, and refuses with [refusal].
final class _Hermes extends HermesApiService {
  _Hermes()
    : super(
        config: const HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          apiKey: 'test-key',
        ),
      );

  final sent =
      <
        ({
          String runId,
          String approvalId,
          bool approved,
          int? executionGeneration,
          String? choice,
        })
      >[];
  Object? refusal;

  @override
  Future<void> resolveApproval(
    String runId, {
    required String approvalId,
    required bool approved,
    int? executionGeneration,
    String? choice,
  }) async {
    sent.add((
      runId: runId,
      approvalId: approvalId,
      approved: approved,
      executionGeneration: executionGeneration,
      choice: choice,
    ));
    final refused = refusal;
    if (refused != null) throw refused;
  }
}

final class _Chat extends ActiveConversationNotifier {
  _Chat(this.conversation);

  final Conversation conversation;

  @override
  Conversation? build() => conversation;
}

final class _Transcript extends ChatMessagesNotifier {
  _Transcript(this.initial);

  final List<ChatMessage> initial;

  @override
  List<ChatMessage> build() => initial;
}

Conversation _chat({Map<String, dynamic> metadata = const {}}) => Conversation(
  id: 'hermes-chat',
  title: 'Tide tables',
  createdAt: DateTime.utc(2026, 11, 8),
  updatedAt: DateTime.utc(2026, 11, 8),
  metadata: metadata,
);

ChatMessage _answer(Map<String, dynamic> metadata) => ChatMessage(
  id: 'answer',
  role: 'assistant',
  content: '',
  timestamp: DateTime.utc(2026, 11, 8),
  metadata: <String, dynamic>{'transport': kHermesTransport, ...metadata},
);

ChatMessage _asking({
  String state = 'pending',
  List<String> choices = const <String>['once', 'session', 'always', 'deny'],
  int? executionGeneration,
}) => _answer(<String, dynamic>{
  kHermesApprovalMeta: <String, dynamic>{
    'state': state,
    'approvalId': 'approval-1',
    'runId': 'run-1',
    'summary': 'Clean the build folder',
    'choices': choices,
    'executionGeneration': ?executionGeneration,
  },
});

/// A chat open on [conversation] with [transcript], answered by [service].
ProviderContainer _open(
  List<ChatMessage> transcript, {
  required HermesBackendService service,
  Conversation? conversation,
}) {
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWith((ref) => null),
      apiServiceProvider.overrideWithValue(null),
      socketServiceProvider.overrideWithValue(null),
      hermesApiServiceProvider.overrideWithValue(service),
      hermesCapabilitiesProvider.overrideWith(
        (ref) async => HermesCapabilities.enabledByDefault,
      ),
      activeConversationProvider.overrideWith(
        () => _Chat(conversation ?? _chat()),
      ),
      chatMessagesProvider.overrideWith(() => _Transcript(transcript)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Starts run `run-1` for the answer, as the run transport does.
void _startRun(ProviderContainer container) {
  final key = hermesRunKeyForConversation(
    container,
    conversation: container.read(activeConversationProvider)!,
    assistantMessageId: 'answer',
  );
  final subscription = const Stream<void>.empty().listen(null);
  addTearDown(subscription.cancel);
  container
      .read(hermesRunRegistryProvider)
      .register(
        key,
        runId: 'run-1',
        cancelToken: CancelToken(),
        subscription: subscription,
        stopRemote: (_) async {},
      );
}

String? _stateOf(ProviderContainer container) {
  final approval =
      container.read(chatMessagesProvider).single.metadata?[kHermesApprovalMeta]
          as Map?;
  return approval?['state'] as String?;
}

void main() {
  group('reading an approval', () {
    test('reads a pending approval with the choices Hermes offers', () {
      final container = _open([
        _asking(
          choices: const <String>['once', 'always', 'deny', 'everything'],
          executionGeneration: 7,
        ),
      ], service: _Hermes());
      _startRun(container);

      final approval = pendingHermesApprovalOf(
        container,
        container.read(chatMessagesProvider).single,
      );

      expect(approval, isNotNull);
      expect(approval!.messageId, 'answer');
      expect(approval.approvalId, 'approval-1');
      expect(approval.runId, 'run-1');
      expect(approval.summary, 'Clean the build folder');
      // Only the answers Hermes defines.
      expect(approval.choices, <String>['once', 'always', 'deny']);
      expect(approval.executionGeneration, 7);
      expect(approval.restoredDesktopDecision, isFalse);
    });

    test('ignores an approval whose run is not running here', () {
      final container = _open([_asking()], service: _Hermes());

      expect(
        pendingHermesApprovalOf(
          container,
          container.read(chatMessagesProvider).single,
        ),
        isNull,
      );
    });

    test('ignores an approval already being answered or answered', () {
      for (final state in <String>[
        'resolving',
        'approved',
        'denied',
        'settled',
      ]) {
        final container = _open([_asking(state: state)], service: _Hermes());
        _startRun(container);
        expect(
          pendingHermesApprovalOf(
            container,
            container.read(chatMessagesProvider).single,
          ),
          isNull,
          reason: state,
        );
      }
    });

    test('ignores answers that are not Hermes, or lack the ids to answer', () {
      final container = _open([_asking()], service: _Hermes());
      _startRun(container);
      expect(
        pendingHermesApprovalOf(
          container,
          ChatMessage(
            id: 'answer',
            role: 'assistant',
            content: '',
            timestamp: DateTime.utc(2026, 11, 8),
            metadata: const <String, dynamic>{
              kHermesApprovalMeta: <String, dynamic>{
                'approvalId': 'approval-1',
                'runId': 'run-1',
              },
            },
          ),
        ),
        isNull,
      );
      expect(
        pendingHermesApprovalOf(
          container,
          _answer(<String, dynamic>{
            kHermesApprovalMeta: <String, dynamic>{'runId': 'run-1'},
          }),
        ),
        isNull,
      );
      // A restored desktop approval is answered through its session, so one
      // without it cannot be answered at all.
      expect(
        pendingHermesApprovalOf(
          container,
          _answer(<String, dynamic>{
            'restoredDesktopDecision': true,
            kHermesApprovalMeta: <String, dynamic>{
              'approvalId': 'approval-1',
              'runId': 'run-1',
            },
          }),
        ),
        isNull,
      );
    });
  });

  group('answering an approval', () {
    test('sends the execution that asked and the scope picked', () async {
      final hermes = _Hermes();
      final container = _open([
        _asking(executionGeneration: 7),
      ], service: hermes);
      _startRun(container);
      final approval = pendingHermesApprovalOf(
        container,
        container.read(chatMessagesProvider).single,
      )!;

      final taken = await resolveHermesApproval(
        container,
        approval,
        choice: 'session',
      );

      expect(taken, isTrue);
      expect(hermes.sent.single, (
        runId: 'run-1',
        approvalId: 'approval-1',
        approved: true,
        executionGeneration: 7,
        choice: 'session',
      ));
      expect(_stateOf(container), 'approved');
    });

    test(
      'leaves the scope to the server when only yes or no is offered',
      () async {
        final hermes = _Hermes();
        final container = _open([
          _asking(choices: const <String>[]),
        ], service: hermes);
        _startRun(container);
        final approval = pendingHermesApprovalOf(
          container,
          container.read(chatMessagesProvider).single,
        )!;

        await resolveHermesApproval(container, approval, choice: 'deny');

        expect(hermes.sent.single.approved, isFalse);
        expect(hermes.sent.single.choice, isNull);
        expect(_stateOf(container), 'denied');
      },
    );

    test('does not answer a run that replaced the one that asked', () async {
      final hermes = _Hermes();
      final container = _open([_asking()], service: hermes);
      _startRun(container);
      final approval = pendingHermesApprovalOf(
        container,
        container.read(chatMessagesProvider).single,
      )!;
      // While the user decides, the turn is sent again: a new run under the
      // same message and run ids.
      _startRun(container);

      final taken = await resolveHermesApproval(
        container,
        approval,
        choice: 'once',
      );

      expect(taken, isFalse);
      expect(hermes.sent, isEmpty);
      expect(_stateOf(container), 'pending');
    });

    test('settles an approval Hermes no longer waits on', () async {
      for (final code in <String>[
        HermesApiErrorCode.approvalNotPending,
        HermesApiErrorCode.staleGeneration,
      ]) {
        final hermes = _Hermes()
          ..refusal = HermesApiException(
            requestOptions: RequestOptions(path: '/v1/runs/run-1/approval'),
            statusCode: 409,
            code: code,
          );
        final container = _open([_asking()], service: hermes);
        _startRun(container);
        final approval = pendingHermesApprovalOf(
          container,
          container.read(chatMessagesProvider).single,
        )!;

        final taken = await resolveHermesApproval(
          container,
          approval,
          choice: 'once',
        );

        expect(taken, isFalse, reason: code);
        // Offering it again could only fail the same way.
        expect(_stateOf(container), 'settled', reason: code);
      }
    });

    test('offers an approval again when sending it failed', () async {
      final hermes = _Hermes()
        ..refusal = DioException(
          requestOptions: RequestOptions(path: '/v1/runs/run-1/approval'),
          type: DioExceptionType.connectionError,
        );
      final container = _open([_asking()], service: hermes);
      _startRun(container);
      final approval = pendingHermesApprovalOf(
        container,
        container.read(chatMessagesProvider).single,
      )!;

      final taken = await resolveHermesApproval(
        container,
        approval,
        choice: 'once',
      );

      expect(taken, isFalse);
      expect(_stateOf(container), 'pending');
    });

    test('sends a restored approval only once', () async {
      // A restored approval is answered through its gateway session. Read
      // while pending, it is already being answered by the time this answer
      // is given, as when two answers are given at once.
      final requests = <String>[];
      final desktop = HermesDesktopApiService(
        config: HermesConfig(
          enabled: true,
          baseUrl: 'https://hermes.example',
          mode: HermesBackendMode.desktopGateway,
          desktopAuthKind: HermesDesktopAuthKind.legacyToken,
          desktopCredentials: HermesDesktopCredentials(legacyToken: 'token'),
        ),
        dio: Dio()..httpClientAdapter = _Refusing(requests),
        rpc: HermesDesktopRpcClient(
          channelFactory: (uri, _, {httpClient}) {
            requests.add('connect $uri');
            throw StateError('No gateway in this test.');
          },
        ),
      );
      addTearDown(desktop.close);
      ChatMessage restored(String state) => _answer(<String, dynamic>{
        'restoredDesktopDecision': true,
        kHermesApprovalMeta: <String, dynamic>{
          'state': state,
          'approvalId': 'approval-1',
          'runId': 'run-1',
          'storedSessionId': 'session-1',
          'choices': const <String>['once', 'deny'],
        },
      });
      final reader = _open(
        [restored('pending')],
        service: desktop,
        conversation: _chat(metadata: {'hermesSessionId': 'session-1'}),
      );
      final approval = pendingHermesApprovalOf(
        reader,
        reader.read(chatMessagesProvider).single,
      )!;
      final container = _open(
        [restored('resolving')],
        service: desktop,
        conversation: _chat(metadata: {'hermesSessionId': 'session-1'}),
      );

      final taken = await resolveHermesApproval(
        container,
        approval,
        choice: 'once',
      );

      expect(taken, isFalse);
      expect(requests, isEmpty);
      expect(_stateOf(container), 'resolving');
    });
  });
}

/// Records each REST request and refuses it.
final class _Refusing implements HttpClientAdapter {
  _Refusing(this.requests);

  final List<String> requests;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add('${options.method} ${options.uri.path}');
    return ResponseBody.fromString('{}', 503);
  }
}
