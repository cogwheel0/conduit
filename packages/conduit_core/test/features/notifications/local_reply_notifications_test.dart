import 'package:checks/checks.dart';
import 'package:conduit_core/database/chat_database_repository.dart'
    show ChatStorageKind;
import 'package:conduit_core/features/direct_connections/services/direct_run_registry.dart';
import 'package:conduit_core/features/notifications/models/app_notification.dart';
import 'package:conduit_core/features/notifications/services/local_reply_notifications.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:test/test.dart';

ChatMessage _reply(String content, {String? error}) => ChatMessage(
  id: 'assistant-1',
  role: 'assistant',
  content: content,
  timestamp: DateTime(2026, 10, 10),
  error: error == null ? null : ChatMessageError(content: error),
);

DirectRunCompletion _completion({
  String content = 'Hello',
  String? error,
  String? title = 'Trip ideas',
  ChatStorageKind? storage = ChatStorageKind.directLocal,
  String? accountId,
}) => DirectRunCompletion(
  conversationId: 'direct-local:1',
  message: _reply(content, error: error),
  title: title,
  storage: storage,
  openWebUiAccountId: accountId,
);

void main() {
  group('appNotificationForDirectRun', () {
    test('an on-device reply is a direct chat completion', () {
      final n = appNotificationForDirectRun(_completion())!;
      check(n.kind).equals(NotificationKind.chatCompletion);
      check(n.scope).equals('direct');
      check(n.sourceId).equals('direct-local:1');
      check(n.title).equals('Trip ideas');
      check(n.body).equals('Hello');
      check(n.dedupKey).equals('direct|direct:direct-local:1:assistant-1');
      check(n.group).equals('chat:direct-local:1');
    });

    test('the preview is plain text, clipped to 200 code points', () {
      final n = appNotificationForDirectRun(
        _completion(
          content:
              '<details type="reasoning">\nhmm\n</details>\n'
              '## Plan\n```dart\nmain();\n```\n**Done** ${'x' * 300}',
        ),
      )!;
      check(n.body).startsWith('Plan Done xxx');
      check(n.body.runes.length).equals(200);
      check(n.body).endsWith('…');
    });

    test('a failure is replyFailed, without the error text', () {
      final n = appNotificationForDirectRun(
        _completion(content: 'partial', error: 'HTTP 500 from provider'),
      )!;
      check(n.kind).equals(NotificationKind.replyFailed);
      check(n.body).equals('');
    });

    test('a temporary chat is direct too', () {
      final n = appNotificationForDirectRun(
        _completion(storage: null, title: null),
      )!;
      check(n.scope).equals('direct');
      check(n.title).equals('');
    });

    test('a chat in an Open WebUI account belongs to that account', () {
      final n = appNotificationForDirectRun(
        _completion(storage: ChatStorageKind.openWebUi, accountId: 'acct-1'),
      )!;
      check(n.scope).equals('owui:acct-1');
      check(
        n.dedupKey,
      ).equals('owui:acct-1|direct:direct-local:1:assistant-1');
    });

    test('an Open WebUI-stored chat without its account is dropped', () {
      check(
        appNotificationForDirectRun(
          _completion(storage: ChatStorageKind.openWebUi),
        ),
      ).isNull();
    });
  });

  group('DirectRunRegistry.completions', () {
    const key = (
      ownerConversationId: 'conversation',
      assistantMessageId: 'assistant-1',
    );

    test('announces the latest generation', () async {
      final registry = DirectRunRegistry();
      addTearDown(registry.dispose);
      final seen = <DirectRunCompletion>[];
      registry.completions.listen(seen.add);

      final reservation = registry.reserve(key, 'profile');
      registry.announceCompletion(reservation, _completion());
      await Future<void>.delayed(Duration.zero);

      check(seen).length.equals(1);
      check(seen.single.assistantMessageId).equals('assistant-1');
    });

    test('a stopped run is not announced', () async {
      final registry = DirectRunRegistry();
      addTearDown(registry.dispose);
      final seen = <DirectRunCompletion>[];
      registry.completions.listen(seen.add);

      final reservation = registry.reserve(key, 'profile');
      await registry.cancel(key);
      registry.announceCompletion(reservation, _completion());
      await Future<void>.delayed(Duration.zero);

      check(seen).isEmpty();
    });

    test('a replaced run is not announced', () async {
      final registry = DirectRunRegistry();
      addTearDown(registry.dispose);
      final seen = <DirectRunCompletion>[];
      registry.completions.listen(seen.add);

      final first = registry.reserve(key, 'profile');
      registry.reserve(key, 'profile');
      registry.announceCompletion(first, _completion());
      await Future<void>.delayed(Duration.zero);

      check(seen).isEmpty();
    });

    test('announcing after dispose is a no-op', () {
      final registry = DirectRunRegistry();
      final reservation = registry.reserve(key, 'profile');
      registry.dispose();
      registry.announceCompletion(reservation, _completion());
    });
  });
}
