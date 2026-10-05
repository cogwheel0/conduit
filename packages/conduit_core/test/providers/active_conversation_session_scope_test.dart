// The startup rule: the active conversation lives in memory for one app
// session and is never restored. A cold start (a new provider container)
// opens a new chat, however many chats with messages exist. The app must not
// persist or restore it (a reported "relaunch reopens the last chat" traced
// to a relaunch that kept the old process, not to any restore in the code).
import 'dart:io';

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/database_opener.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/host_ports.dart';
import 'package:conduit_core/testing.dart';
import 'package:drift/drift.dart' show QueryExecutor, Value;
import 'package:drift/native.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

Conversation _chatWithMessages() => Conversation(
  id: 'chat-1',
  title: 'A chat with messages',
  createdAt: DateTime(2026, 9, 30),
  updatedAt: DateTime(2026, 9, 30),
  messages: [
    ChatMessage(
      id: 'm1',
      role: 'user',
      content: 'hello',
      timestamp: DateTime(2026, 9, 30),
    ),
    ChatMessage(
      id: 'm2',
      role: 'assistant',
      content: 'hi',
      timestamp: DateTime(2026, 9, 30),
    ),
  ],
);

void main() {
  test('a new session starts on a new chat, not the last one', () {
    final first = ProviderContainer();
    first.read(activeConversationProvider.notifier).set(_chatWithMessages());
    expect(first.read(activeConversationProvider)?.id, 'chat-1');
    first.dispose();

    // The relaunch: a new container over the same (persisted) data.
    final second = ProviderContainer();
    addTearDown(second.dispose);
    expect(second.read(activeConversationProvider), isNull);
  });

  test('starting a new chat clears the open one', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(activeConversationProvider.notifier)
        .set(_chatWithMessages());

    container.read(activeConversationProvider.notifier).clear();

    expect(container.read(activeConversationProvider), isNull);
  });

  group('over persisted chats', () {
    late AppDatabase db;
    late InMemoryKeyValueStore prefs;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      prefs = InMemoryKeyValueStore();
      PreferencesStore.debugOverride(prefs);
      // A chat the previous session left behind, with its messages.
      await db
          .into(db.chats)
          .insert(
            ChatsCompanion.insert(
              id: 'chat-1',
              title: 'A chat with messages',
              createdAt: 1,
              updatedAt: 1,
              bodySynced: const Value(true),
            ),
          );
    });

    tearDown(() async {
      PreferencesStore.debugReset();
      await db.close();
    });

    ProviderContainer launch() {
      final container = ProviderContainer(
        overrides: [
          ...openWebUiStorageOpenOverrides(database: db),
          databaseOpenerProvider.overrideWithValue(_MemoryDatabaseOpener()),
          apiServiceProvider.overrideWithValue(null),
          reviewerModeProvider.overrideWithValue(false),
          isAuthenticatedProvider2.overrideWithValue(true),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('a cold start lists the stored chat but opens none', () async {
      final session = launch();
      session
          .read(activeConversationProvider.notifier)
          .set(_chatWithMessages());
      session.dispose();

      // The relaunch: a new container over the same database.
      final relaunched = launch();
      final listed = await relaunched.read(conversationsProvider.future);

      // The chat is stored and listed, yet nothing opens it.
      expect(listed.map((c) => c.id), contains('chat-1'));
      expect(relaunched.read(activeConversationProvider), isNull);
      expect(relaunched.read(chatMessagesProvider), isEmpty);
    });

    test('opening a chat writes nothing that a relaunch could restore', () {
      final before = Set<String>.of(prefs.keys);
      final session = launch();

      session
          .read(activeConversationProvider.notifier)
          .set(_chatWithMessages());

      expect(Set<String>.of(prefs.keys), before);
      for (final key in prefs.keys) {
        expect(prefs.get(key).toString(), isNot(contains('chat-1')));
      }
    });
  });
}

class _MemoryDatabaseOpener implements DatabaseOpenerPort {
  @override
  QueryExecutor open(String serverId) => NativeDatabase.memory();

  @override
  Future<Directory> databaseDirectory() async => Directory.systemTemp;
}
