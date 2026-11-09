import 'dart:convert';

import 'package:meta/meta.dart';

import 'package:conduit_core/features/librechat/models/librechat_message.dart';

/// One frame of a LibreChat generation stream
/// (`GET /api/agents/chat/stream/:streamId`).
///
/// Every frame is SSE `event: message` with a JSON body told apart by its
/// keys, except failures, which are `event: error`. See LibreChat's
/// `api/server/routes/agents/index.js` and `client/src/hooks/SSE/`.
@immutable
sealed class LibreChatStreamEvent {
  const LibreChatStreamEvent();

  /// Reads one SSE frame; null for a frame with no JSON body.
  static LibreChatStreamEvent? fromFrame({
    required String? event,
    required String data,
  }) {
    Object? decoded;
    try {
      decoded = jsonDecode(data);
    } on FormatException {
      return event == 'error' ? LibreChatStreamFailed(data) : null;
    }
    if (event == 'error') return LibreChatStreamFailed.fromJson(decoded);
    if (decoded is! Map) return null;
    return fromJson(Map<String, dynamic>.from(decoded));
  }

  /// Reads one decoded `event: message` body, as frames and the resume
  /// snapshot's pending events carry them.
  static LibreChatStreamEvent fromJson(Map<String, dynamic> json) {
    if (json['final'] == true) return LibreChatStreamFinal(json);
    if (json['sync'] == true) return LibreChatStreamSync.fromJson(json);
    if (json['created'] == true) {
      final message = json['message'];
      return LibreChatStreamCreated(
        message is Map ? Map<String, dynamic>.from(message) : const {},
      );
    }
    final name = json['event'];
    final rawData = json['data'];
    final data = rawData is Map
        ? Map<String, dynamic>.from(rawData)
        : const <String, dynamic>{};
    switch (name) {
      case 'attachment':
        return LibreChatStreamAttachment(data);
      case 'title':
        return LibreChatStreamTitle(
          conversationId: data['conversationId'] as String?,
          title: data['title'] is String ? data['title'] as String : '',
        );
      case 'on_pending_action':
        return LibreChatStreamPendingAction(data);
      case String() when LibreChatStreamStep.handled.contains(name):
        return LibreChatStreamStep(name, data);
      default:
        return LibreChatStreamIgnored(json);
    }
  }
}

/// The server took the turn: [userMessage] is the user's message as saved,
/// with the ids it was given.
final class LibreChatStreamCreated extends LibreChatStreamEvent {
  const LibreChatStreamCreated(this.userMessage);

  final Map<String, dynamic> userMessage;
}

/// A run-step event that builds the reply's parts.
final class LibreChatStreamStep extends LibreChatStreamEvent {
  const LibreChatStreamStep(this.name, this.data);

  /// The step events Conduit folds into the reply. Others (tool timings,
  /// summaries, sub-agents, steering) are passed over; the final frame
  /// carries their result.
  static const Set<String> handled = {
    'on_run_step',
    'on_agent_update',
    'on_message_delta',
    'on_reasoning_delta',
    'on_run_step_delta',
    'on_run_step_completed',
  };

  final String name;
  final Map<String, dynamic> data;
}

/// A file a tool produced: an image, web search results, code output.
final class LibreChatStreamAttachment extends LibreChatStreamEvent {
  const LibreChatStreamAttachment(this.attachment);

  final Map<String, dynamic> attachment;
}

/// The server titled the conversation.
final class LibreChatStreamTitle extends LibreChatStreamEvent {
  const LibreChatStreamTitle({
    required this.conversationId,
    required this.title,
  });

  final String? conversationId;
  final String title;
}

/// The run paused for the user: a tool waits for approval, or the agent
/// asked a question. The stream stays open until it is answered.
final class LibreChatStreamPendingAction extends LibreChatStreamEvent {
  const LibreChatStreamPendingAction(this.action);

  /// The `PendingAction`: `actionId`, `payload` (`tool_approval` with
  /// `action_requests` and `review_configs`, or `ask_user_question`), ...
  final Map<String, dynamic> action;

  String? get actionId => action['actionId'] as String?;
}

/// What a resumed subscription sees first: the reply so far, then the
/// events since that snapshot.
final class LibreChatStreamSync extends LibreChatStreamEvent {
  const LibreChatStreamSync({
    required this.resumeState,
    required this.pendingEvents,
  });

  static LibreChatStreamSync fromJson(Map<String, dynamic> json) {
    final state = json['resumeState'];
    final pending = json['pendingEvents'];
    return LibreChatStreamSync(
      resumeState: state is Map ? Map<String, dynamic>.from(state) : null,
      pendingEvents: [
        if (pending is List)
          for (final event in pending)
            if (event is Map)
              LibreChatStreamEvent.fromJson(Map<String, dynamic>.from(event)),
      ],
    );
  }

  /// `runSteps`, `aggregatedContent`, `userMessage`, `responseMessageId`,
  /// `pendingAction`, ...; null when the server had no snapshot.
  final Map<String, dynamic>? resumeState;
  final List<LibreChatStreamEvent> pendingEvents;
}

/// The turn ended. Either it carries the saved messages, or, as a
/// `reconcile` frame, it says only that the saved result must be fetched.
final class LibreChatStreamFinal extends LibreChatStreamEvent {
  const LibreChatStreamFinal(this.raw);

  final Map<String, dynamic> raw;

  /// The result is not in this frame: refetch the conversation's messages.
  bool get reconcile => raw['reconcile'] == true;

  bool get aborted => raw['aborted'] == true;

  /// Stopped before anything was saved; nothing to refetch.
  bool get earlyAbort => raw['earlyAbort'] == true;

  Map<String, dynamic>? get conversation => _map('conversation');
  Map<String, dynamic>? get requestMessage => _map('requestMessage');
  Map<String, dynamic>? get responseMessage => _map('responseMessage');

  String? get title {
    final value = raw['title'];
    return value is String && value.isNotEmpty ? value : null;
  }

  Map<String, dynamic>? _map(String key) {
    final value = raw[key];
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }
}

/// The stream failed; [message] is what the server said.
final class LibreChatStreamFailed extends LibreChatStreamEvent {
  const LibreChatStreamFailed(this.message);

  static LibreChatStreamFailed fromJson(Object? json) {
    if (json is Map) {
      final error = json['error'] ?? json['message'] ?? json['text'];
      if (error is String) {
        return LibreChatStreamFailed(libreChatReadableError(error));
      }
      if (error is Map) {
        final nested = error['message'] ?? error['text'];
        if (nested is String) return LibreChatStreamFailed(nested);
      }
    }
    if (json is String) {
      return LibreChatStreamFailed(libreChatReadableError(json));
    }
    return const LibreChatStreamFailed(
      'The LibreChat server stopped the reply.',
    );
  }

  final String message;

  /// uaParser's refusal of a non-browser User-Agent.
  bool get isIllegalRequest => message == 'Illegal request';
}

/// A frame Conduit does not act on: usage, labels, steering, ...
final class LibreChatStreamIgnored extends LibreChatStreamEvent {
  const LibreChatStreamIgnored(this.raw);

  final Map<String, dynamic> raw;
}
