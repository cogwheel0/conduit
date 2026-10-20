import 'api_service.dart';

/// Rates an answer the way Open WebUI's web client does.
///
/// Two records change, and both have to: the evaluation (what the
/// leaderboard and the admin's feedback list read) and the message's own
/// `annotation` and `feedbackId` in the chat (what every client reads to
/// show the thumb). Rating twice updates the same evaluation rather than
/// filing a second one, which is what `feedbackId` is for.
///
/// Mirrors `feedbackHandler` in `ResponseMessage.svelte`, including its
/// order: the evaluation first, because the message needs its id.
class MessageRating {
  const MessageRating(this._api);

  final ApiService _api;

  /// Rates [messageId] in [chatId]: 1 for up, -1 for down.
  Future<void> rate({
    required String chatId,
    required String messageId,
    required int rating,
  }) async {
    if (rating != 1 && rating != -1) {
      throw ArgumentError.value(rating, 'rating', 'must be 1 or -1');
    }
    final raw = await _api.getChatRaw(chatId);
    if (raw == null) throw StateError('no chat $chatId');
    final chat = _map(raw['chat']);
    final history = _map(chat['history']);
    final messages = _map(history['messages']);
    final original = messages[messageId];
    if (original is! Map) throw StateError('no message $messageId');
    final message = Map<String, dynamic>.from(original);

    final previous = _map(message['annotation']);
    final annotation = <String, dynamic>{
      ...previous,
      'rating': rating,
      // A changed verdict clears the reason given for the old one.
      if (previous['rating'] != rating) ...<String, dynamic>{
        'reason': null,
        'details': null,
      },
    };

    final siblings = _siblingIds(messages, message, messageId);
    final feedback = <String, dynamic>{
      'type': 'rating',
      'data': <String, dynamic>{
        ...annotation,
        'model_id': message['selectedModelId'] ?? message['model'],
        if (siblings.isNotEmpty)
          'sibling_model_ids': <Object?>[
            for (final id in siblings)
              _map(messages[id])['selectedModelId'] ??
                  _map(messages[id])['model'],
          ],
      },
      'meta': <String, dynamic>{
        'arena': message['arena'] ?? false,
        'model_id': message['model'],
        'message_id': messageId,
        'message_index': _depth(messages, messageId),
        'chat_id': chatId,
      },
      'snapshot': <String, dynamic>{'chat': raw},
    };

    // The annotation is saved even when filing the evaluation fails: the
    // user's thumb is their record of what they thought, and the server
    // refusing an evaluation (evaluations turned off, say) is no reason to
    // lose it. The failure is still reported afterwards.
    Object? failure;
    StackTrace? failureTrace;
    try {
      Map<String, dynamic>? saved;
      final existing = message['feedbackId'];
      if (existing is String && existing.isNotEmpty) {
        saved = await _api.updateFeedback(existing, feedback);
      }
      saved ??= await _api.createFeedback(feedback);
      if (saved['id'] case final String id) message['feedbackId'] = id;
    } on Object catch (error, trace) {
      failure = error;
      failureTrace = trace;
    }

    message['annotation'] = annotation;
    messages[messageId] = message;
    history['messages'] = messages;
    chat['history'] = history;
    // The flat list older clients read, kept in step with the tree.
    if (chat['messages'] case final List<dynamic> flat) {
      chat['messages'] = <Object?>[
        for (final entry in flat)
          if (entry is Map && entry['id'] == messageId)
            <String, dynamic>{
              ...Map<String, dynamic>.from(entry),
              'annotation': annotation,
              if (message['feedbackId'] != null)
                'feedbackId': message['feedbackId'],
            }
          else
            entry,
      ];
    }
    await _api.updateChatRaw(chatId, chat);

    if (failure != null) Error.throwWithStackTrace(failure, failureTrace!);
  }

  /// The other answers to the same question, which the leaderboard counts
  /// this one as having beaten or lost to.
  static List<String> _siblingIds(
    Map<String, dynamic> messages,
    Map<String, dynamic> message,
    String messageId,
  ) {
    final parent = messages[message['parentId']];
    if (parent is! Map) return const <String>[];
    final children = parent['childrenIds'];
    if (children is! List || children.length < 2) return const <String>[];
    return <String>[
      for (final id in children)
        if ('$id' != messageId) '$id',
    ];
  }

  /// How many messages lead to [messageId], itself included -- the web
  /// client's `createMessagesList(history, id).length`.
  static int _depth(Map<String, dynamic> messages, String messageId) {
    var depth = 0;
    Object? id = messageId;
    final seen = <Object?>{};
    while (id != null && seen.add(id)) {
      final message = messages[id];
      if (message is! Map) break;
      depth++;
      id = message['parentId'];
    }
    return depth;
  }

  static Map<String, dynamic> _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
}
