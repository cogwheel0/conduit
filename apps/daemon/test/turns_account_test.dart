@TestOn('vm')
library;

import 'dart:async';

import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show
        apiServiceProvider,
        loadConversationProvider,
        openWebUiAuthSessionEpochProvider;
import 'package:conduit_core/providers/backend_mode_providers.dart'
    show PrimaryAccountKind;
import 'package:conduit_core/providers/primary_account_providers.dart'
    show PrimaryAccountRef, primaryAccountProvider;
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// A chat belongs to the account it was opened under, whichever backend
/// that account is on.
void main() {
  test('another LibreChat account takes the last one\'s chats with it', () async {
    var primary = const PrimaryAccountRef(
      PrimaryAccountKind.libreChat,
      'librechat-a',
    );
    // Open WebUI's session stays as it was: only the LibreChat account in
    // charge changes.
    final epoch = Object();
    final container = ProviderContainer(
      overrides: [
        primaryAccountProvider.overrideWith((ref) => primary),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
        apiServiceProvider.overrideWith((ref) => null),
      ],
    );
    addTearDown(container.dispose);
    final turns = TurnsService(container, EventBus());
    addTearDown(turns.dispose);
    turns.temporary.start('local:sketch-ideas');
    expect(turns.temporary.contains('local:sketch-ideas'), isTrue);

    primary = const PrimaryAccountRef(
      PrimaryAccountKind.libreChat,
      'librechat-b',
    );
    container.invalidate(primaryAccountProvider);
    container.read(primaryAccountProvider);

    expect(turns.temporary.contains('local:sketch-ideas'), isFalse);
  });

  test('a chat still loading as another LibreChat account takes charge is '
      'not opened under it', () async {
    var primary = const PrimaryAccountRef(
      PrimaryAccountKind.libreChat,
      'librechat-a',
    );
    final epoch = Object();
    final asked = Completer<void>();
    final loaded = Completer<Conversation>();
    final container = ProviderContainer(
      overrides: [
        primaryAccountProvider.overrideWith((ref) => primary),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
        apiServiceProvider.overrideWith((ref) => null),
        loadConversationProvider.overrideWith((ref, id) {
          if (!asked.isCompleted) asked.complete();
          return loaded.future;
        }),
      ],
    );
    addTearDown(container.dispose);
    final turns = TurnsService(container, EventBus());
    addTearDown(turns.dispose);

    // The first account's chat is read; another LibreChat account takes
    // charge before it arrives.
    final deleting = turns.deleteMessages(
      const DeleteMessages(
        chatId: 'chat-trail',
        messageIds: <String>['m1'],
        dryRun: true,
      ),
    );
    await asked.future;
    primary = const PrimaryAccountRef(
      PrimaryAccountKind.libreChat,
      'librechat-b',
    );
    container.invalidate(primaryAccountProvider);
    container.read(primaryAccountProvider);
    final now = DateTime.utc(2026, 11, 2);
    loaded.complete(
      Conversation(
        id: 'chat-trail',
        title: 'Trail plans',
        createdAt: now,
        updatedAt: now,
      ),
    );

    await expectLater(
      deleting,
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
