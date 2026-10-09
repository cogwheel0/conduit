import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_run_event.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_local_document_trust_store.dart';
import 'package:conduit_core/features/hermes/services/hermes_run_transport.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/features/notifications/models/app_notification.dart';
import 'package:conduit_core/features/notifications/services/local_reply_notifications.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _config = HermesConfig(
  enabled: true,
  connectionId: 'conn-1',
  name: 'Home',
  baseUrl: 'https://hermes.example',
  apiKey: 'key',
  sessionKey: 'memory',
);

final class _FixedHermesConfig extends HermesConfigController {
  @override
  HermesConfig build() => _config;

  @override
  Future<String> ensureSessionKey() async => 'memory';
}

final class _OpenDatabaseAccess extends OpenWebUiDatabaseAccessNotifier {
  @override
  OpenWebUiDatabaseAccessPhase build() => OpenWebUiDatabaseAccessPhase.open;
}

/// A Runs-mode Hermes that answers [events] for every run, or keeps the run
/// going until it is stopped when [events] is null.
final class _ScriptedHermesApi extends HermesApiService {
  _ScriptedHermesApi(this.events) : super(config: _config, dio: Dio());

  final List<HermesRunEvent>? events;
  final Completer<void> started = Completer<void>();

  @override
  Future<String> createSession({
    String? title,
    CancelToken? cancelToken,
  }) async => 'session-new';

  @override
  Future<String> createRun({
    required String input,
    String? sessionId,
    String? instructions,
    String? previousResponseId,
    List<Map<String, dynamic>>? conversationHistory,
    CancelToken? cancelToken,
  }) async {
    if (!started.isCompleted) started.complete();
    return 'run-1';
  }

  @override
  Future<void> stopRun(String runId, {CancelToken? cancelToken}) async {}

  @override
  Stream<HermesRunEvent> runEvents(
    String runId, {
    String? sessionId,
    CancelToken? cancelToken,
  }) {
    final scripted = events;
    if (scripted != null) return Stream<HermesRunEvent>.fromIterable(scripted);
    final open = StreamController<HermesRunEvent>();
    addTearDown(open.close);
    return open.stream;
  }
}

ProviderContainer _container(HermesApiService service) => ProviderContainer(
  overrides: [
    openWebUiDatabaseAccessProvider.overrideWith(_OpenDatabaseAccess.new),
    appDatabaseProvider.overrideWith((ref) {
      final database = AppDatabase(NativeDatabase.memory());
      ref.onDispose(() => unawaited(database.close()));
      return database;
    }),
    apiServiceProvider.overrideWithValue(null),
    socketServiceProvider.overrideWithValue(null),
    hermesConfigProvider.overrideWith(_FixedHermesConfig.new),
    hermesApiServiceProvider.overrideWithValue(service),
  ],
);

/// Runs one turn in the native Hermes chat of session `s-1`, and returns
/// what the run registry announced.
Future<List<HermesTurnCompletion>> _runTurn(
  ProviderContainer container, {
  Future<void> Function(HermesRunRegistry registry)? whileRunning,
}) async {
  final registry = container.read(hermesRunRegistryProvider);
  final announced = <HermesTurnCompletion>[];
  final subscription = registry.completions.listen(announced.add);
  addTearDown(subscription.cancel);
  final placeholder = ChatMessage(
    id: 'assistant-1',
    role: 'assistant',
    content: '',
    timestamp: DateTime.utc(2026, 10, 10),
    isStreaming: true,
    metadata: const <String, dynamic>{'transport': kHermesTransport},
  );
  final conversation = markNativeHermesConversation(
    Conversation(
      id: 'local:hermes_s-1',
      title: 'Refactor plan',
      createdAt: DateTime.utc(2026, 10, 10),
      updatedAt: DateTime.utc(2026, 10, 10),
      messages: <ChatMessage>[placeholder],
      metadata: const <String, dynamic>{
        'backend': 'hermes',
        'hermesSessionId': 's-1',
      },
    ),
  );
  container.read(activeConversationProvider.notifier).set(conversation);
  container.read(chatMessagesProvider.notifier).setMessages(<ChatMessage>[
    placeholder,
  ]);
  final dispatch = dispatchHermesRunFromChatForTest(
    container,
    assistantMessageId: placeholder.id,
    assistantSeed: placeholder,
    input: 'go',
    existingMessages: const <ChatMessage>[],
  );
  await whileRunning?.call(registry);
  await dispatch;
  await Future<void>.delayed(Duration.zero);
  return announced;
}

void main() {
  setUp(() {
    PreferencesStore.debugOverride(InMemoryKeyValueStore());
    HermesLocalDocumentTrustStore.debugResetRuntimeState();
  });
  tearDown(() {
    HermesLocalDocumentTrustStore.debugResetRuntimeState();
    PreferencesStore.debugReset();
  });

  test('a finished turn is announced with its connection', () async {
    final container = _container(
      _ScriptedHermesApi(const <HermesRunEvent>[
        HermesTokenDelta('Done. Tests pass.'),
        HermesRunDone(),
      ]),
    );
    addTearDown(container.dispose);

    final announced = await _runTurn(container);

    check(announced).length.equals(1);
    final turn = announced.single;
    check(turn.connectionId).equals('conn-1');
    check(turn.sessionId).isNotEmpty();
    check(turn.failed).isFalse();
    check(turn.message.content).contains('Done. Tests pass.');

    final notification = appNotificationForHermesTurn(turn)!;
    check(notification.kind).equals(NotificationKind.chatCompletion);
    check(notification.scope).equals('hermes:conn-1');
    check(notification.sourceId).equals(turn.sessionId);
    check(notification.group).equals('hermes:${turn.sessionId}');
    check(notification.dedupKey).equals(
      'hermes:conn-1|hermes:${turn.sessionId}:assistant-1',
    );
  });

  test('a failed turn is announced as failed', () async {
    final container = _container(
      _ScriptedHermesApi(const <HermesRunEvent>[
        HermesRunError('model overloaded'),
      ]),
    );
    addTearDown(container.dispose);

    final announced = await _runTurn(container);

    check(announced).length.equals(1);
    check(announced.single.failed).isTrue();
    check(
      appNotificationForHermesTurn(announced.single)!.kind,
    ).equals(NotificationKind.replyFailed);
  });

  test('a stopped turn is not announced', () async {
    final service = _ScriptedHermesApi(null);
    final container = _container(service);
    addTearDown(container.dispose);

    final announced = await _runTurn(
      container,
      whileRunning: (registry) async {
        await service.started.future;
        await Future<void>.delayed(Duration.zero);
        await Future.wait(registry.cancelAll());
      },
    );

    check(announced).isEmpty();
  });
}
