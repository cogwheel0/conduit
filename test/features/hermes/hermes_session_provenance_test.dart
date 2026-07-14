import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/features/hermes/services/hermes_session_provenance.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Conversation _conversation({String id = 'local:hermes_session'}) =>
    Conversation(
      id: id,
      title: 'Hermes',
      createdAt: DateTime.utc(2026, 7, 14),
      updatedAt: DateTime.utc(2026, 7, 14),
      metadata: const <String, dynamic>{
        'backend': 'hermes',
        'hermesSessionId': 'session',
      },
    );

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
    HermesMixedSessionBindingTrustStore.debugResetRuntimeState();
  });

  tearDown(() {
    HermesMixedSessionBindingTrustStore.debugResetRuntimeState();
    PreferencesStore.debugReset();
  });

  test('serialized backend metadata cannot mint native provenance', () {
    final forged = _conversation();
    check(isNativeHermesConversation(forged)).isFalse();

    final native = markNativeHermesConversation(_conversation());
    check(isNativeHermesConversation(native)).isTrue();
    check(
      isNativeHermesConversation(
        inheritNativeHermesConversationProvenance(
          native,
          native.copyWith(title: 'Updated locally'),
        ),
      ),
    ).isTrue();
    check(
      isNativeHermesConversation(native.copyWith(title: 'Untrusted copy')),
    ).isFalse();
  });

  test(
    'mixed binding trusts only the exact persisted metadata snapshot',
    () async {
      final owner =
          HermesMixedSessionBindingTrustStore.durableStorageAccountIdentity(
            serverId: 'server-a',
            userId: 'user-a',
            tokenFingerprint: 'token-fingerprint-a',
          );
      await HermesMixedSessionBindingTrustStore.remember(
        storageAccountIdentity: owner,
        conversationId: 'chat-a',
        assistantMessageId: 'assistant-a',
        sessionId: 'session-a',
        connectionIdentity: 'connection-a',
        responseId: 'response-a',
        runId: 'run-a',
        transportMode: 'responses',
      );

      bool trusts({
        String storageAccountIdentity = '',
        String conversationId = 'chat-a',
        String assistantMessageId = 'assistant-a',
        String sessionId = 'session-a',
        String connectionIdentity = 'connection-a',
        String? responseId = 'response-a',
        String? runId = 'run-a',
        String? transportMode = 'responses',
      }) => HermesMixedSessionBindingTrustStore.trusts(
        storageAccountIdentity: storageAccountIdentity.isEmpty
            ? owner
            : storageAccountIdentity,
        conversationId: conversationId,
        assistantMessageId: assistantMessageId,
        sessionId: sessionId,
        connectionIdentity: connectionIdentity,
        responseId: responseId,
        runId: runId,
        transportMode: transportMode,
      );

      check(trusts()).isTrue();
      check(trusts(conversationId: 'chat-b')).isFalse();
      check(trusts(assistantMessageId: 'assistant-b')).isFalse();
      check(trusts(sessionId: 'session-b')).isFalse();
      check(trusts(connectionIdentity: 'connection-b')).isFalse();
      check(trusts(responseId: 'copied-response')).isFalse();
      check(trusts(runId: 'copied-run')).isFalse();
      check(trusts(transportMode: 'runs')).isFalse();
      check(
        trusts(
          storageAccountIdentity:
              HermesMixedSessionBindingTrustStore.durableStorageAccountIdentity(
                serverId: 'server-a',
                userId: 'user-b',
                tokenFingerprint: 'token-fingerprint-b',
              ),
        ),
      ).isFalse();
    },
  );

  test(
    'conversation deletion revokes an otherwise replayable binding',
    () async {
      final owner =
          HermesMixedSessionBindingTrustStore.durableStorageAccountIdentity(
            serverId: 'server-a',
            userId: 'user-a',
            tokenFingerprint: 'token-fingerprint-a',
          );
      Future<void> remember() => HermesMixedSessionBindingTrustStore.remember(
        storageAccountIdentity: owner,
        conversationId: 'deleted-chat',
        assistantMessageId: 'assistant',
        sessionId: 'session',
        connectionIdentity: 'connection',
      );
      bool trusts() => HermesMixedSessionBindingTrustStore.trusts(
        storageAccountIdentity: owner,
        conversationId: 'deleted-chat',
        assistantMessageId: 'assistant',
        sessionId: 'session',
        connectionIdentity: 'connection',
      );

      await remember();
      check(trusts()).isTrue();
      await HermesMixedSessionBindingTrustStore.forgetConversation(
        storageAccountIdentity: owner,
        conversationId: 'deleted-chat',
      );
      check(trusts()).isFalse();

      // Keep the scope blocked through the caller's remote-delete confirmation;
      // even a late in-flight persistence callback cannot re-establish it.
      await remember();
      check(trusts()).isFalse();
      HermesMixedSessionBindingTrustStore.debugResetRuntimeState();
      check(trusts()).isFalse();
      await remember();
      check(trusts()).isTrue();
    },
  );

  test('delete revocation wins a delayed remember write', () async {
    final owner =
        HermesMixedSessionBindingTrustStore.durableStorageAccountIdentity(
          serverId: 'server-a',
          userId: 'user-a',
          tokenFingerprint: 'token-fingerprint-a',
        );
    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    var gateFirstWrite = true;
    final preferences = await SharedPreferences.getInstance();
    PreferencesStore.debugOverride(
      preferences,
      writeInterceptor: (preferences, key, value) async {
        if (gateFirstWrite && key.contains('hermes_mixed_session_binding')) {
          gateFirstWrite = false;
          writeStarted.complete();
          await releaseWrite.future;
        }
        return null;
      },
    );

    Future<void> remember() => HermesMixedSessionBindingTrustStore.remember(
      storageAccountIdentity: owner,
      conversationId: 'racing-chat',
      assistantMessageId: 'assistant',
      sessionId: 'session',
      connectionIdentity: 'connection',
    );
    bool trusts() => HermesMixedSessionBindingTrustStore.trusts(
      storageAccountIdentity: owner,
      conversationId: 'racing-chat',
      assistantMessageId: 'assistant',
      sessionId: 'session',
      connectionIdentity: 'connection',
    );

    final staleRemember = remember();
    await writeStarted.future;
    final revocation = HermesMixedSessionBindingTrustStore.forgetConversation(
      storageAccountIdentity: owner,
      conversationId: 'racing-chat',
    );
    final lateRemember = remember();
    releaseWrite.complete();
    await Future.wait(<Future<void>>[staleRemember, revocation, lateRemember]);

    check(trusts()).isFalse();
  });
}
