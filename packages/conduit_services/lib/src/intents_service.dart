import 'dart:async';

import 'package:conduit_markdown/conduit_markdown.dart'
    show ConduitMarkdownPreprocessor;
import 'package:conduit_protocol/conduit_protocol.dart';

import 'chats_service.dart';
import 'event_bus.dart';
import 'turns_service.dart';

/// Implements `intents.*`: what the Mac app's App Intents (Shortcuts, Siri,
/// Spotlight) ask the daemon for.
///
/// * `intents.ask` (Ask Conduit) sends a question as a new chat through
///   `turns.send`'s path ([TurnsService.send]), and waits for the answer
///   on the [EventBus] (a [EventBus.tap], so it is never mistaken for a
///   window that could be asked to approve something). The reply carries
///   the answer as the Copy action copies it, or, when the answer failed,
///   waits in the outbox or takes longer than the shortcut waits, the chat
///   it will be in.
/// * `intents.chats` lists the chats Open Chat offers: the given ids, the
///   chats a search finds, or the recent ones.
final class IntentsService {
  IntentsService({
    required Future<SendTurnAccepted> Function(SendTurn request) send,
    required Future<ChatList> Function() list,
    required Future<ChatSearchResults> Function(ChatSearchQuery query) search,
    required Future<ChatDetail?> Function(String id) get,
    required EventBus events,
  }) : _send = send,
       _list = list,
       _search = search,
       _get = get,
       _events = events;

  /// Over the daemon's own services: the composer's send, the sidebar's
  /// list and search, and `chats.get`.
  factory IntentsService.over({
    required TurnsService turns,
    required ChatsService chats,
    required EventBus events,
  }) => IntentsService(
    send: turns.send,
    list: chats.list,
    search: chats.search,
    get: chats.get,
    events: events,
  );

  final Future<SendTurnAccepted> Function(SendTurn request) _send;
  final Future<ChatList> Function() _list;
  final Future<ChatSearchResults> Function(ChatSearchQuery query) _search;
  final Future<ChatDetail?> Function(String id) _get;
  final EventBus _events;

  /// The shortest and longest wait a caller may ask for.
  static const int minTimeoutMs = 1000;
  static const int maxTimeoutMs = 10 * 60 * 1000;

  /// The most chats one `intents.chats` call returns.
  static const int maxChats = 50;

  /// The longest an answer waits for its chat's title: a slow chat read
  /// gives no title rather than keeping Shortcuts waiting.
  static const int titleWaitMs = 2000;

  Future<IntentAnswer> ask(IntentAsk request) async {
    final text = request.text.trim();
    if (text.isEmpty) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'intents.ask needs a question',
      );
    }
    final timeout = Duration(
      milliseconds: request.timeoutMs.clamp(minTimeoutMs, maxTimeoutMs),
    );
    // Listening before the send: a fast answer can end before the send's
    // reply is read. Every answer that ends meanwhile is noted by its
    // message id, and the one this question started is picked out after.
    final watch = _AnswerWatch();
    final untap = _events.tap(watch.hear);
    try {
      final accepted = await _send(SendTurn(text: text, model: request.model));
      final ended = await watch
          .endOf(accepted.assistantMessageId)
          .then<_AnswerEnd?>((end) => end)
          .timeout(timeout, onTimeout: () => null);
      final progress = watch.progress(accepted.assistantMessageId);
      final chatId = progress.chatId ?? accepted.chatId;
      final outcome = switch (ended) {
        null => IntentAskOutcome.timedOut,
        _AnswerEnd(queued: true) => IntentAskOutcome.queued,
        _AnswerEnd(ok: true) => IntentAskOutcome.answered,
        _ => IntentAskOutcome.failed,
      };
      return IntentAnswer(
        chatId: chatId,
        messageId: accepted.assistantMessageId,
        outcome: outcome,
        text: _copyable(progress.text),
        detail: outcome == IntentAskOutcome.failed ? progress.detail : null,
        title: await _titleOf(chatId),
      );
    } finally {
      untap();
    }
  }

  Future<IntentChats> chats(IntentChatsQuery request) async {
    final limit = request.limit.clamp(1, maxChats);
    final list = await _list();
    final byId = <String, ChatSummary>{
      for (final chat in list.chats) chat.id: chat,
    };
    if (request.ids.isNotEmpty) {
      final found = <IntentChat>[];
      for (final id in request.ids.toSet()) {
        final known = byId[id];
        if (known != null) {
          found.add(_entry(known));
          continue;
        }
        // Beyond the loaded page, or archived: the stored copy says.
        final detail = await _detail(id);
        if (detail != null) found.add(_entry(detail.summary));
      }
      return IntentChats(chats: found.take(maxChats).toList());
    }
    final query = request.query?.trim() ?? '';
    final shown = list.chats.where((c) => !c.archived).toList();
    if (query.isEmpty) {
      // Pinned first, then the most recently changed: the sidebar's order.
      shown.sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return b.updatedAtMs.compareTo(a.updatedAtMs);
      });
      return IntentChats(chats: shown.take(limit).map(_entry).toList());
    }
    final matches = <IntentChat>[];
    final seen = <String>{};
    void add(IntentChat chat) {
      if (matches.length < limit && seen.add(chat.id)) matches.add(chat);
    }

    // Titles first: what a person typing a chat's name expects at the top.
    final needle = query.toLowerCase();
    for (final chat in shown) {
      if (chat.title.toLowerCase().contains(needle)) add(_entry(chat));
    }
    final hits = await _search(ChatSearchQuery(query: query, limit: limit));
    for (final hit in hits.hits) {
      final known = byId[hit.chatId];
      add(
        known != null
            ? _entry(known)
            : IntentChat(
                id: hit.chatId,
                title: hit.title,
                updatedAtMs: hit.updatedAtMs,
              ),
      );
    }
    return IntentChats(chats: matches);
  }

  static IntentChat _entry(ChatSummary chat) => IntentChat(
    id: chat.id,
    title: chat.title,
    updatedAtMs: chat.updatedAtMs,
    pinned: chat.pinned,
  );

  Future<ChatDetail?> _detail(String id) async {
    try {
      return await _get(id);
    } on Object {
      return null;
    }
  }

  Future<String?> _titleOf(String chatId) async {
    final detail = await _detail(
      chatId,
    ).timeout(const Duration(milliseconds: titleWaitMs), onTimeout: () => null);
    final title = detail?.summary.title.trim();
    return title == null || title.isEmpty ? null : title;
  }

  /// The answer as the Copy action copies it (the phone's and the
  /// desktop's): no reasoning, no tool-call blocks, entities decoded.
  static String _copyable(String text) =>
      ConduitMarkdownPreprocessor.sanitizeForClipboard(text);
}

/// How one answer ended, from `turn.finished`.
final class _AnswerEnd {
  const _AnswerEnd({required this.ok, required this.queued});

  final bool ok;
  final bool queued;
}

/// One answer's text and failure as they arrive.
final class _AnswerProgress {
  String? chatId;
  String text = '';
  String? detail;
}

/// Follows every answer's events ([EventBus.tap]) until the one wanted is
/// known; answers that end before it is named are kept.
final class _AnswerWatch {
  final Map<String, _AnswerProgress> _progress = <String, _AnswerProgress>{};
  final Map<String, _AnswerEnd> _ends = <String, _AnswerEnd>{};
  final Map<String, Completer<_AnswerEnd>> _waiting =
      <String, Completer<_AnswerEnd>>{};

  _AnswerProgress progress(String messageId) =>
      _progress.putIfAbsent(messageId, _AnswerProgress.new);

  Future<_AnswerEnd> endOf(String messageId) {
    final ended = _ends[messageId];
    if (ended != null) return Future<_AnswerEnd>.value(ended);
    return _waiting.putIfAbsent(messageId, Completer<_AnswerEnd>.new).future;
  }

  void hear(String event, String? scope, Map<String, dynamic> payload) {
    switch (event) {
      case ConduitEvents.turnDelta:
        final delta = TurnDelta.fromJson(payload);
        progress(delta.messageId)
          ..chatId = delta.chatId
          // The text so far, not an increment.
          ..text = delta.text;
      case ConduitEvents.turnCompleted:
        final completed = TurnCompleted.fromJson(payload);
        progress(completed.messageId)
          ..chatId = completed.chatId
          ..text = completed.text;
      case ConduitEvents.turnFailed:
        final failed = TurnFailed.fromJson(payload);
        final detail = failed.args['detail']?.trim();
        final answer = progress(failed.messageId)..chatId = failed.chatId;
        if (failed.partialText.isNotEmpty) answer.text = failed.partialText;
        if (detail != null && detail.isNotEmpty) answer.detail = detail;
      case ConduitEvents.turnFinished:
        final finished = TurnFinished.fromJson(payload);
        progress(finished.messageId).chatId = finished.chatId;
        final end = _AnswerEnd(ok: finished.ok, queued: finished.queued);
        _ends[finished.messageId] = end;
        _waiting.remove(finished.messageId)?.complete(end);
    }
  }
}
