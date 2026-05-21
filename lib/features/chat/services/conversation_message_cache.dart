import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/persistence/persistence_providers.dart';
import '../../../core/utils/debug_logger.dart';

/// Per-conversation message snapshot cache.
///
/// Pillar #4 of the local-first thesis: re-opening an old chat should be
/// instant, including offline. Upstream caches the conversation list but
/// not the messages inside each conversation. This service stores the last
/// `_cap` messages per conversation in the existing Hive `caches` box so
/// the chat page can hydrate immediately while the server fetch (which
/// upstream already triggers) refreshes in the background.
///
/// Storage layout: key `$_prefix$conversationId`, value JSON-encoded
/// `List<Map<String, dynamic>>` (each entry is `ChatMessage.toJson`).
class ConversationMessageCache {
  ConversationMessageCache(this._ref);

  final Ref _ref;

  static const String _prefix = 'convmsgs::';
  static const int _cap = 100;

  String _keyFor(String conversationId) => '$_prefix$conversationId';

  List<ChatMessage>? load(String conversationId) {
    if (conversationId.isEmpty) return null;
    try {
      final raw = _ref.read(hiveBoxesProvider).caches.get(_keyFor(conversationId));
      if (raw is! String || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      final messages = <ChatMessage>[];
      for (final entry in decoded) {
        if (entry is Map) {
          messages.add(ChatMessage.fromJson(Map<String, dynamic>.from(entry)));
        }
      }
      return messages.isEmpty ? null : messages;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'load-failed',
        scope: 'chat/msg-cache',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<void> save(String conversationId, List<ChatMessage> messages) async {
    if (conversationId.isEmpty) return;
    try {
      final box = _ref.read(hiveBoxesProvider).caches;
      if (messages.isEmpty) {
        await box.delete(_keyFor(conversationId));
        return;
      }
      // Cap to the most recent _cap to keep the cache bounded.
      final capped = messages.length > _cap
          ? messages.sublist(messages.length - _cap)
          : messages;
      final encoded = jsonEncode(
        capped.map((m) => m.toJson()).toList(growable: false),
      );
      await box.put(_keyFor(conversationId), encoded);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'save-failed',
        scope: 'chat/msg-cache',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> clear(String conversationId) async {
    if (conversationId.isEmpty) return;
    try {
      await _ref.read(hiveBoxesProvider).caches.delete(_keyFor(conversationId));
    } catch (_) {}
  }
}

final conversationMessageCacheProvider =
    Provider<ConversationMessageCache>(ConversationMessageCache.new);
