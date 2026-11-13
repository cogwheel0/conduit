import 'package:checks/checks.dart';
import 'package:conduit_core/database/chat_database_repository.dart'
    show ChatStorageKind;
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/librechat/models/librechat_capabilities.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/connectivity_service.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

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
}
