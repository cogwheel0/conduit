import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/database/chat_database_repository.dart'
    show ChatStorageKind;
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/librechat/models/librechat_capabilities.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/features/librechat/providers/librechat_sync_providers.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:mocktail/mocktail.dart' show Fake;
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

final class _Api extends Fake implements ApiService {}

/// Answers the reads [chatMenuAvailability] makes, and nothing else.
final class _Reads {
  _Reads(this.values);

  final Map<Object, Object?> values;

  Object? read(Object provider) {
    if (!values.containsKey(provider)) {
      throw StateError('not read in this test: $provider');
    }
    return values[provider];
  }
}

const _quinn = User(
  id: 'user-1',
  username: 'quinn',
  email: 'quinn@example.test',
  name: 'Quinn',
  role: 'user',
);

Conversation _chat(String id, ChatStorageKind storage) =>
    withChatStorageProvenance(
      Conversation(
        id: id,
        title: 'Tide tables $id',
        createdAt: DateTime.utc(2026, 4, 2),
        updatedAt: DateTime.utc(2026, 4, 2),
        userId: _quinn.id,
      ),
      storage,
    );

_Reads _account({
  bool sharedLinks = false,
  AsyncValue<bool> export = const AsyncData<bool>(true),
  bool online = true,
}) => _Reads(<Object, Object?>{
  currentUserProvider2: _quinn,
  apiServiceProvider: Object(),
  libreChatCapabilitiesProvider: AsyncData<LibreChatCapabilities>(
    LibreChatCapabilities(sharedLinks: sharedLinks),
  ),
  chatMarkUnreadSupportedProvider: true,
  openWebUiChatActionAllowedProvider('export'): export,
  isOnlineProvider: online,
  foldersAvailableProvider: true,
});

void main() {
  test('an Open WebUI chat offers its server actions, not Duplicate', () {
    final menu = chatMenuAvailability(
      _account(),
      _chat('c1', ChatStorageKind.openWebUi),
    );
    check(menu.share).isTrue();
    check(menu.move).isTrue();
    check(menu.markUnread).isTrue();
    check(menu.generateTitle).isTrue();
    check(menu.export).isTrue();
    check(menu.duplicate).isFalse();
  });

  test('a LibreChat chat duplicates and shares only where links are on', () {
    final chat = _chat('c2', ChatStorageKind.libreChat);
    final closed = chatMenuAvailability(_account(), chat);
    check(closed.duplicate).isTrue();
    check(closed.share).isFalse();
    check(closed.move).isFalse();
    check(closed.markUnread).isFalse();
    check(closed.generateTitle).isFalse();
    check(closed.export).isFalse();
    check(chatMenuAvailability(_account(sharedLinks: true), chat).share)
        .isTrue();
    // Offline, nothing to copy it with.
    check(chatMenuAvailability(_account(online: false), chat).duplicate)
        .isFalse();
  });

  test('an on-device Direct chat offers none of the server actions', () {
    final menu = chatMenuAvailability(
      _account(sharedLinks: true),
      _chat('c3', ChatStorageKind.directLocal),
    );
    check(menu.share).isFalse();
    check(menu.move).isFalse();
    check(menu.markUnread).isFalse();
    check(menu.generateTitle).isFalse();
    check(menu.export).isFalse();
    check(menu.duplicate).isFalse();
  });

  test('Export waits for the permission to load', () {
    final menu = chatMenuAvailability(
      _account(export: const AsyncLoading<bool>()),
      _chat('c4', ChatStorageKind.openWebUi),
    );
    check(menu.export).isFalse();
    check(menu.share).isTrue();
  });

  test(
    'the open chat\'s actions wait only on permissions that count',
    () async {
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(_Api()),
          currentUserProvider2.overrideWithValue(_quinn),
          isAuthenticatedProvider2.overrideWithValue(true),
          reviewerModeProvider.overrideWithValue(false),
          appSettingsProvider.overrideWithValue(const AppSettings()),
          appDatabaseProvider.overrideWith((ref) => null),
          libreChatSyncEngineProvider.overrideWithValue(null),
          chatMarkUnreadSupportedProvider.overrideWithValue(true),
          // Neither ever answers.
          libreChatCapabilitiesProvider.overrideWith(
            (ref) => Completer<LibreChatCapabilities>().future,
          ),
          openWebUiChatActionAllowedProvider.overrideWith(
            (ref, action) => Completer<bool>().future,
          ),
        ],
      );
      addTearDown(container.dispose);
      // Each lookup it does not need never answers: awaiting it at all would
      // keep the test from finishing.
      Future<void> settles(Conversation chat, {bool temporary = false}) =>
          chatActionAvailability(container, chat, temporary: temporary);

      final libreChat = _chat('c5', ChatStorageKind.libreChat);
      // Shared already, temporary, or another user's: no link to ask about.
      await settles(libreChat.copyWith(shareId: 'share-1'));
      await settles(libreChat, temporary: true);
      await settles(libreChat.copyWith(userId: 'someone-else'));
      // Not an Open WebUI chat: no Export to ask about.
      await settles(_chat('c6', ChatStorageKind.directLocal));
    },
  );
}
