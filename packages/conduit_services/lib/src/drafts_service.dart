import 'package:conduit_core/database/chat_database_repository.dart'
    show ChatStorageKind;
import 'package:conduit_core/features/chat/composer/composer_draft_context.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

import 'hermes_service.dart';
import 'settled.dart';
import 'temporary_chats.dart';

/// Implements `drafts.*`: the composer's text, kept per chat in the
/// account's database as mobile keeps it.
///
/// Where a draft lives is the core's [resolveComposerDraftContext]: a stored
/// chat's under its id, a new chat's under its folder, a Hermes session's
/// under its connection, in the database its messages use. A temporary or
/// read-only chat keeps none.
final class DraftsService {
  DraftsService(this._container, {required TemporaryChats temporary})
    : _temporary = temporary;

  final ProviderContainer _container;
  final TemporaryChats _temporary;

  Future<Draft> get(DraftRef ref) async {
    final context = await _context(ref.chatId, ref.folderId);
    final store = context.store;
    if (store == null) return const Draft(stored: false);
    return Draft(text: await store.read(context.scope, context.chatId) ?? '');
  }

  Future<Draft> save(DraftSave request) async {
    final context = await _context(request.chatId, request.folderId);
    final store = context.store;
    if (store == null) return Draft(text: request.text, stored: false);
    try {
      await store.save(context.scope, context.chatId, request.text);
    } on StateError {
      // The chat was deleted, here or elsewhere: nothing to keep it under.
      return Draft(text: request.text, stored: false);
    }
    return Draft(text: request.text);
  }

  /// Where [chatId]'s draft (a new chat's in [folderId]) lives, for what
  /// else is kept with it: its recordings (`recordings.*`).
  Future<ComposerDraftContext> contextFor(String? chatId, String? folderId) =>
      _context(chatId, folderId);

  Future<ComposerDraftContext> _context(
    String? chatId,
    String? folderId,
  ) async {
    // Placed for the account in use when asked: once another one is, the
    // chat id may name one of its chats, whose draft is not this one's.
    final account = _container.read(openWebUiAuthSessionEpochProvider);
    final active = chatId == null ? null : await _conversation(chatId);
    if (!identical(account, _container.read(openWebUiAuthSessionEpochProvider))) {
      throw const RpcError(
        code: ConduitErrorCodes.sessionExpired,
        debugMessage: 'the account changed',
      );
    }
    return resolveComposerDraftContext(
      _container.read,
      active: active,
      selected: _container.read(selectedModelProvider),
      pendingFolderId: chatId == null ? folderId : null,
      temporaryEnabled: false,
    );
  }

  /// Enough of [chatId]'s conversation to place its draft: whose it is, and
  /// where its messages are kept. A Hermes session's transcript is not
  /// fetched for that, nor a temporary chat's (which keeps no draft).
  Future<Conversation> _conversation(String chatId) async {
    final now = DateTime.now();
    final bare = Conversation(
      id: chatId,
      title: '',
      createdAt: now,
      updatedAt: now,
    );
    if (hermesSessionOf(chatId) case final sessionId?) {
      return markNativeHermesConversation(
        bare.copyWith(
          metadata: <String, dynamic>{
            'backend': 'hermes',
            'hermesSessionId': sessionId,
          },
        ),
      );
    }
    if (_temporary.contains(chatId) || TemporaryChats.isTemporary(chatId)) {
      return bare;
    }
    try {
      return await readSettled(
        _container,
        loadConversationProvider(chatId).future,
      );
    } on Object {
      // Not readable now: its draft stays where its messages are kept.
      return chatId.startsWith('direct-local:')
          ? withChatStorageProvenance(bare, ChatStorageKind.directLocal)
          : bare;
    }
  }
}
