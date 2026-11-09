import 'dart:async';
import 'dart:io' show IOException;

import 'package:dio/dio.dart';
import 'package:meta/meta.dart';

import 'package:conduit_core/features/librechat/models/librechat_stream_event.dart';
import 'package:conduit_core/features/librechat/services/librechat_errors.dart';
import 'package:conduit_core/features/librechat/services/librechat_stream_client.dart';
import 'package:conduit_core/features/librechat/services/librechat_stream_reducer.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// What a LibreChat turn reports as it runs.
@immutable
sealed class LibreChatTurnUpdate {
  const LibreChatTurnUpdate();
}

/// The server accepted the turn.
final class LibreChatTurnStarted extends LibreChatTurnUpdate {
  const LibreChatTurnStarted(this.generation);

  final LibreChatGeneration generation;
}

/// The server saved the user's message, with the ids it gave it.
final class LibreChatTurnCreated extends LibreChatTurnUpdate {
  const LibreChatTurnCreated(this.userMessage);

  final Map<String, dynamic> userMessage;
}

/// The reply changed: [parts] is all of it so far.
final class LibreChatTurnProgress extends LibreChatTurnUpdate {
  const LibreChatTurnProgress({
    required this.responseMessageId,
    required this.parts,
    required this.attachments,
  });

  final String? responseMessageId;
  final List<Map<String, dynamic>> parts;
  final List<Map<String, dynamic>> attachments;
}

/// The run waits for the user to approve a tool or answer a question.
final class LibreChatTurnPaused extends LibreChatTurnUpdate {
  const LibreChatTurnPaused(this.action);

  final Map<String, dynamic> action;
}

/// The run waits on no one: a resume snapshot without a pause. One shown
/// before was answered elsewhere (in LibreChat's web app, say) while the
/// stream was away.
final class LibreChatTurnPauseCleared extends LibreChatTurnUpdate {
  const LibreChatTurnPauseCleared();
}

/// The server titled the conversation.
final class LibreChatTurnTitled extends LibreChatTurnUpdate {
  const LibreChatTurnTitled(this.title);

  final String title;
}

/// The turn ended. [frame] is the final frame when it carried the result;
/// null when the result has to be fetched (the generation was gone,
/// replaced, or reconciled). Either way the conversation should be fetched
/// again so the local copy holds what the server saved.
final class LibreChatTurnFinished extends LibreChatTurnUpdate {
  const LibreChatTurnFinished({
    required this.conversationId,
    this.frame,
    this.aborted = false,
  });

  final String conversationId;
  final LibreChatStreamFinal? frame;
  final bool aborted;
}

/// The turn failed with what the server said.
final class LibreChatTurnFailed extends LibreChatTurnUpdate {
  const LibreChatTurnFailed(this.message, {this.illegalRequest = false});

  final String message;

  /// The server refused this client's User-Agent. A bug, and a ban risk.
  final bool illegalRequest;
}

/// Runs LibreChat turns from start to end, across dropped connections.
///
/// A generation runs on the server whether or not anyone listens, so a
/// subscription that drops is picked up again with `resume`, which starts
/// from the server's snapshot. When following fails for good, the turn
/// ends as [LibreChatTurnFinished] without a frame: the server still saves
/// the reply, so fetching the conversation recovers it.
final class LibreChatTurnRunner {
  LibreChatTurnRunner(
    this._streams, {
    this.maxReconnects = 5,
    Future<void> Function(Duration delay)? sleep,
    CancelToken? cancelToken,
  }) : _sleep = sleep ?? Future<void>.delayed,
       _cancelToken = cancelToken;

  final LibreChatStreamClient _streams;
  final int maxReconnects;
  final Future<void> Function(Duration delay) _sleep;

  /// Cancels the start and the stream in flight; a cancelled runner stops
  /// rather than reconnecting.
  final CancelToken? _cancelToken;

  bool get _cancelled => _cancelToken?.isCancelled ?? false;

  /// Starts [request] and follows it to the end. Throws what
  /// [LibreChatStreamClient.start] throws when the server will not take it.
  Stream<LibreChatTurnUpdate> run(LibreChatTurnRequest request) async* {
    final generation = await _streams.start(
      request,
      cancelToken: _cancelToken,
    );
    yield LibreChatTurnStarted(generation);
    if (!generation.isLive) {
      yield LibreChatTurnFinished(conversationId: generation.conversationId);
      return;
    }
    yield* follow(
      generation.conversationId,
      generationCreatedAt: generation.createdAt,
      resume: generation.outcome == LibreChatStartOutcome.resumed,
    );
  }

  /// Follows the generation running in [conversationId] to the end; with
  /// [resume], from the server's snapshot (after a restart, say).
  Stream<LibreChatTurnUpdate> follow(
    String conversationId, {
    int? generationCreatedAt,
    bool resume = false,
  }) async* {
    final reducer = LibreChatStreamReducer();
    var resumeNext = resume;
    var failures = 0;
    while (true) {
      try {
        await for (final event in _streams.subscribe(
          conversationId,
          generationCreatedAt: generationCreatedAt,
          resume: resumeNext,
          cancelToken: _cancelToken,
        )) {
          final changed = reducer.apply(event);
          // Only the reply moving on earns back the retry budget: a resume
          // snapshot comes first on every reconnect, so a stream that sends
          // one and drops would otherwise retry forever.
          if (changed && event is! LibreChatStreamSync) failures = 0;
          switch (event) {
            case LibreChatStreamCreated(:final userMessage):
              yield LibreChatTurnCreated(userMessage);
            case LibreChatStreamTitle(:final title):
              if (title.trim().isNotEmpty) yield LibreChatTurnTitled(title);
            case LibreChatStreamPendingAction(:final action):
              yield LibreChatTurnPaused(action);
            case LibreChatStreamFinal():
              if (!event.reconcile && reducer.parts.isNotEmpty) {
                yield _progress(reducer);
              }
              yield LibreChatTurnFinished(
                conversationId: conversationId,
                frame: event.reconcile ? null : event,
                aborted: event.aborted,
              );
              return;
            case LibreChatStreamFailed(:final message):
              yield LibreChatTurnFailed(
                message,
                illegalRequest: event.isIllegalRequest,
              );
              return;
            case LibreChatStreamSync():
              final userMessage = reducer.userMessage;
              if (userMessage != null) yield LibreChatTurnCreated(userMessage);
              if (reducer.pendingAction != null) {
                yield LibreChatTurnPaused(reducer.pendingAction!);
              } else {
                yield const LibreChatTurnPauseCleared();
              }
              final title = reducer.title;
              if (title != null) yield LibreChatTurnTitled(title);
              if (changed) yield _progress(reducer);
            default:
              if (changed) yield _progress(reducer);
          }
        }
      } on LibreChatSessionExpiredException {
        rethrow;
      } on LibreChatApiException catch (error) {
        if (_cancelled) return;
        DebugLogger.warning(
          'follow-failed',
          scope: 'librechat/turn',
          data: {'status': error.statusCode},
        );
        // A refusal (a ban, a permission taken away) is not a dropped
        // connection: asking again only repeats it, and the reply cannot
        // be shown as finished when it was never followed.
        if (_isRefusal(error.statusCode)) {
          yield LibreChatTurnFailed(error.message);
          return;
        }
      } on DioException catch (error) {
        // The body broke off after the stream opened.
        final cause = error.error;
        if (cause is LibreChatSessionExpiredException) throw cause;
        DebugLogger.warning(
          'follow-dropped',
          scope: 'librechat/turn',
          data: {'type': error.type.name},
        );
      } on IOException catch (error) {
        DebugLogger.warning(
          'follow-dropped',
          scope: 'librechat/turn',
          data: {'error': error.runtimeType.toString()},
        );
      }
      if (_cancelled) return;
      // The subscription ended without a final frame: the connection
      // dropped, or the server closed a paused stream. Pick it up again.
      failures++;
      if (failures > maxReconnects) {
        yield LibreChatTurnFinished(conversationId: conversationId);
        return;
      }
      await _sleep(Duration(milliseconds: 500 * (1 << (failures - 1))));
      resumeNext = true;
    }
  }

  /// A client error the server would give again: any 4xx but 408 (timed
  /// out) and 429 (asked to wait), which a retry can outlast.
  static bool _isRefusal(int? status) =>
      status != null &&
      status >= 400 &&
      status < 500 &&
      status != 408 &&
      status != 429;

  static LibreChatTurnProgress _progress(LibreChatStreamReducer reducer) =>
      LibreChatTurnProgress(
        responseMessageId: reducer.responseMessageId,
        parts: reducer.parts,
        attachments: List.unmodifiable(reducer.attachments),
      );
}
