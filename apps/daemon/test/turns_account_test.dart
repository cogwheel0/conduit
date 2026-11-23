@TestOn('vm')
library;

import 'dart:async';

import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show chatMessagesProvider, isChatStreamingProvider;
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show
        Models,
        apiServiceProvider,
        loadConversationProvider,
        modelsProvider,
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
  test(
    'another LibreChat account takes the last one\'s chats with it',
    () async {
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
    },
  );

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

  test('words sent as another account takes charge while the model is read '
      'are not sent under it', () async {
    var primary = const PrimaryAccountRef(
      PrimaryAccountKind.libreChat,
      'librechat-a',
    );
    final epoch = Object();
    final asked = Completer<void>();
    final listed = Completer<void>();
    final container = ProviderContainer(
      overrides: [
        primaryAccountProvider.overrideWith((ref) => primary),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
        apiServiceProvider.overrideWith((ref) => null),
        modelsProvider.overrideWith(
          () => _HeldModels(() {
            if (!asked.isCompleted) asked.complete();
            return listed.future;
          }),
        ),
      ],
    );
    addTearDown(container.dispose);
    final turns = TurnsService(container, EventBus());
    addTearDown(turns.dispose);

    final sending = turns.send(
      const SendTurn(model: 'trail-model', text: 'Plan the ridge walk'),
    );
    await asked.future;
    primary = const PrimaryAccountRef(
      PrimaryAccountKind.libreChat,
      'librechat-b',
    );
    container.invalidate(primaryAccountProvider);
    container.read(primaryAccountProvider);
    listed.complete();

    await expectLater(
      sending,
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.sessionExpired,
        ),
      ),
    );
  });

  group('a chat already open', () {
    late PrimaryAccountRef primary;
    late ProviderContainer container;
    late TurnsService turns;
    late Completer<void> listed;
    final now = DateTime.utc(2026, 11, 2);
    final chat = Conversation(
      id: 'chat-trail',
      title: 'Trail plans',
      createdAt: now,
      updatedAt: now,
      messages: <ChatMessage>[
        ChatMessage(id: 'm1', role: 'user', content: 'Ridge?', timestamp: now),
        ChatMessage(
          id: 'm2',
          role: 'assistant',
          content: 'Start at dawn.',
          timestamp: now,
          model: 'trail-model',
        ),
      ],
    );

    setUp(() async {
      primary = const PrimaryAccountRef(
        PrimaryAccountKind.libreChat,
        'librechat-a',
      );
      listed = Completer<void>()..complete();
      final epoch = Object();
      container = ProviderContainer(
        overrides: [
          primaryAccountProvider.overrideWith((ref) => primary),
          openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
          apiServiceProvider.overrideWith((ref) => null),
          loadConversationProvider.overrideWith((ref, id) async => chat),
          modelsProvider.overrideWith(() => _HeldModels(() => listed.future)),
        ],
      );
      addTearDown(container.dispose);
      turns = TurnsService(container, EventBus());
      addTearDown(turns.dispose);
      // Opened under the first account, and kept open.
      await turns.holdScope('chat-trail');
    });

    void anotherTakesCharge() {
      primary = const PrimaryAccountRef(
        PrimaryAccountKind.libreChat,
        'librechat-b',
      );
      container.invalidate(primaryAccountProvider);
      container.read(primaryAccountProvider);
    }

    final refused = throwsA(
      isA<RpcError>().having(
        (e) => e.code,
        'code',
        ConduitErrorCodes.sessionExpired,
      ),
    );

    test('counts or deletes nothing for a request begun under the last '
        'account', () async {
      final deleting = turns.deleteMessages(
        const DeleteMessages(
          chatId: 'chat-trail',
          messageIds: <String>['m2'],
          dryRun: true,
        ),
      );
      // The request has its chat; another account takes charge before it
      // counts.
      anotherTakesCharge();
      await expectLater(deleting, refused);
    });

    test('is held for no call begun under the last account', () async {
      listed = Completer<void>();
      final holding = turns.holdForCall(
        chatId: 'chat-trail',
        model: 'trail-model',
      );
      // The call's model is read; another account takes charge meanwhile.
      anotherTakesCharge();
      listed.complete();
      await expectLater(holding, refused);
    });

    test('a Stop on an answer left generating stops nothing once another '
        'account is in charge', () async {
      PreferencesStore.debugOverride(InMemoryKeyValueStore());
      addTearDown(PreferencesStore.debugReset);
      await PreferencesStore.put(PreferenceKeys.activeServerId, 'server-ada');
      // An answer the core still shows as generating, with no turn behind
      // it: Stop settles it with the core's own stop.
      final scope = await turns.holdScope('chat-trail');
      addTearDown(() => turns.releaseScope('chat-trail'));
      scope.read(chatMessagesProvider.notifier).setMessages(<ChatMessage>[
        for (final message in chat.messages)
          message.role == 'assistant'
              ? message.copyWith(isStreaming: true)
              : message,
      ]);
      expect(scope.read(isChatStreamingProvider), isTrue);

      final stopping = turns.stop('chat-trail');
      // Stop has its chat; another account's settings take charge before
      // it reaches the core.
      unawaited(
        PreferencesStore.put(PreferenceKeys.activeServerId, 'server-bo'),
      );
      await stopping;
      expect(
        scope.read(isChatStreamingProvider),
        isTrue,
        reason: 'the last account\'s Stop reached the core under the next one',
      );
    });

    test('a temporary chat is saved into no account but the one that '
        'asked', () async {
      turns.temporary.start('local:sketch-ideas');
      turns.temporary.replace('local:sketch-ideas', chat.messages);
      final saving = turns.saveTemporary('local:sketch-ideas');
      await pumpEventQueue();
      // It waits for the chat to settle (half a second without a change);
      // another account takes charge meanwhile, before the chat is read.
      anotherTakesCharge();
      await expectLater(saving, refused);
    });
  });
}

/// The models list, read once [listed] lets it.
final class _HeldModels extends Models {
  _HeldModels(this.listed);

  final Future<void> Function() listed;

  @override
  Future<List<Model>> build() async {
    await listed();
    return const <Model>[Model(id: 'trail-model', name: 'Trail model')];
  }
}
