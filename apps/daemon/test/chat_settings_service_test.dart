@TestOn('vm')
library;

import 'dart:async';

import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// `chatSettings.*` across an account change.
void main() {
  test("a chat's settings read under one account are not the next one's",
      () async {
    var account = Object();
    final chat = Completer<Conversation>();
    final container = ProviderContainer(
      overrides: [
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => account),
        appDatabaseProvider.overrideWithValue(null),
        loadConversationProvider.overrideWith((ref, id) => chat.future),
      ],
    );
    addTearDown(container.dispose);
    final reading = ChatSettingsService(
      container,
    ).get(const ChatSettingsQuery(chatId: 'chat-1'));
    // Another account signs in while the chat is read.
    account = Object();
    container.invalidate(openWebUiAuthSessionEpochProvider);
    chat.complete(
      Conversation(
        id: 'chat-1',
        title: 'Garden plans',
        createdAt: DateTime.utc(2026, 11, 1),
        updatedAt: DateTime.utc(2026, 11, 1),
        chatParams: const <String, dynamic>{'system': 'Answer briefly.'},
      ),
    );
    await expectLater(
      reading,
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.sessionExpired,
        ),
      ),
    );
  });
}
