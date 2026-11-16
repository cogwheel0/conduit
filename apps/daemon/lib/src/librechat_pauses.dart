import 'dart:async';
import 'dart:convert';

import 'package:conduit_core/features/librechat/models/librechat_tools.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import 'ui_requests_service.dart';

/// What became of a pause put to the windows.
enum LibreChatPauseOutcome {
  /// The run goes on with the answers.
  resumed,

  /// A question left unanswered stopped the reply.
  stopped,

  /// The turn that asked is over (stopped, finished, or another one runs):
  /// nothing more is done for it.
  left,

  /// The answers could not be sent: the run still waits on them.
  failed,
}

/// Resumes the paused run with tool-call [decisions] or question
/// [answers].
typedef LibreChatResume =
    Future<void> Function({
      Map<String, LibreChatToolDecisionInput>? decisions,
      Map<String, String>? answers,
    });

/// Puts what a LibreChat run paused on to the windows, one card at a time --
/// each tool call to approve, or each question -- and resumes the run with
/// the answers, as the phone's overlay does. A question left unanswered
/// stops the reply; a tool call left unanswered is rejected where the pause
/// allows that, and stops the reply where it does not.
///
/// [asking] says whether the turn that asked still runs and still waits on
/// [action]. [until] completes when that turn ends: its cards go. [stop]
/// stops the reply.
///
/// Answers that could not be sent (the server unreachable, a retryable
/// refusal) leave the run waiting on them: the cards are put to the windows
/// again for as long as a window can answer and the turn still asks. Only a
/// window's answer sends again: after a failure even a tool call the pause
/// lets refuse without asking (approve not allowed) waits for its card, so
/// nothing goes out over and over on its own. A send is tried again only
/// after a card was put up and answered in that attempt (or, the first
/// time, when the next attempt puts one up); a failure before anything is
/// sent -- a card that could not be put up -- ends the reply once. After a
/// failed send only a window's own answer decides: a card settled with its
/// default (every window gone before answering) sends nothing, refuses
/// nothing and stops nothing; the pause waits for a window again while its
/// turn runs.
Future<LibreChatPauseOutcome> answerLibreChatPause(
  LibreChatPendingAction action, {
  required UiRequestsService? windows,
  required String chatId,
  required bool Function() asking,
  required LibreChatResume resume,
  required Future<void> Function() stop,
  Future<void>? until,
}) async {
  var recovering = false;
  while (true) {
    final attempt = _Attempt();
    final outcome = await _answerOnce(
      action,
      attempt,
      windows: windows,
      chatId: chatId,
      asking: asking,
      resume: resume,
      stop: stop,
      until: until,
      recovering: recovering,
    );
    // Not sent, and no window is there to put the card to (one is
    // reconnecting), or the card went unanswered by any window: the pause
    // waits for a window while its turn runs, rather than being left with
    // no card to answer.
    if (outcome == LibreChatPauseOutcome.failed &&
        windows != null &&
        until != null &&
        (attempt.unanswered || !windows.canAsk) &&
        asking()) {
      if (!await windows.windowBack(until) || !asking()) return outcome;
      recovering = true;
      continue;
    }
    if (outcome != LibreChatPauseOutcome.failed ||
        windows == null ||
        !windows.canAsk ||
        !asking() ||
        // Only a window's answer sends again: this attempt's card was
        // answered, or (the first time) the next attempt puts one up.
        !(attempt.answered || (!recovering && _carded(action)))) {
      return outcome;
    }
    recovering = true;
  }
}

/// One attempt at a pause: whether a card was put up and answered, and
/// whether the answers began going out.
final class _Attempt {
  bool answered = false;
  bool sending = false;

  /// A card after a failed send was settled with its default, not by a
  /// window: nothing was decided.
  bool unanswered = false;
}

/// Whether an attempt after a failed send puts a card to the windows: each
/// question, and (then) each tool call, waits for its answer.
bool _carded(LibreChatPendingAction action) =>
    action.isQuestion && action.questions.isNotEmpty ||
    action.isToolApproval && action.toolRequests.isNotEmpty;


Future<LibreChatPauseOutcome> _answerOnce(
  LibreChatPendingAction action,
  _Attempt attempt, {
  required UiRequestsService? windows,
  required String chatId,
  required bool Function() asking,
  required LibreChatResume resume,
  required Future<void> Function() stop,
  Future<void>? until,
  bool recovering = false,
}) async {
  try {
    if (action.isQuestion) {
      final questions = action.questions;
      // A question action with no question to put: the reply stops, as an
      // unanswered question stops it (there is nothing to resume with).
      if (questions.isEmpty) {
        if (!asking()) return LibreChatPauseOutcome.left;
        await stop();
        return LibreChatPauseOutcome.stopped;
      }
      final answers = <String, String>{};
      for (final (index, question) in questions.indexed) {
        final id = question['id']?.toString() ?? 'question';
        final options = question['options'];
        final reply = windows == null
            ? null
            : await windows.askLibreChatQuestion(
                chatId: chatId,
                question: question['question']?.toString() ?? '',
                description: question['description']?.toString(),
                options: <Map<String, String>>[
                  if (options is List)
                    for (final option in options)
                      if (option is Map && option['label'] != null)
                        <String, String>{
                          'label': '${option['label']}',
                          if (option['description'] != null)
                            'description': '${option['description']}',
                        },
                ],
                multiSelect: question['multiSelect'] == true,
                progress: questions.length > 1
                    ? '${index + 1}/${questions.length}'
                    : null,
                until: until,
              );
        attempt.answered = reply?.answered ?? false;
        // Answered or dismissed after its turn ended (a newer reply may run
        // in the chat now): nothing of that newer one is touched.
        if (!asking()) return LibreChatPauseOutcome.left;
        if (recovering && reply != null && !reply.answered) {
          attempt.unanswered = true;
          return LibreChatPauseOutcome.failed;
        }
        final answer = reply?.text;
        if (answer == null) {
          await stop();
          return LibreChatPauseOutcome.stopped;
        }
        answers[id] = answer;
      }
      attempt.sending = true;
      await resume(answers: answers);
      return LibreChatPauseOutcome.resumed;
    }
    if (!action.isToolApproval) return LibreChatPauseOutcome.left;
    final decisions = <String, LibreChatToolDecisionInput>{};
    for (final request in action.toolRequests) {
      // Answered elsewhere, or its turn ended: no further card for it.
      if (!asking()) return LibreChatPauseOutcome.left;
      final approvable = request.allowed.contains(
        LibreChatToolDecision.approve,
      );
      final carded = windows != null && (approvable || recovering);
      // A call that cannot be approved is refused without a card -- except
      // after a failed send, when the window's answer is what sends again.
      var allowed = false;
      if (carded) {
        final reply = await windows.askLibreChatToolApproval(
          chatId: chatId,
          toolName: request.name,
          description: request.description,
          argumentsJson: _argumentsJson(request.arguments),
          until: until,
        );
        if (!asking()) return LibreChatPauseOutcome.left;
        if (recovering && !reply.answered) {
          attempt.unanswered = true;
          return LibreChatPauseOutcome.failed;
        }
        attempt.answered = reply.answered;
        allowed = reply.allow && approvable;
      }
      final decision = allowed
          ? LibreChatToolDecision.approve
          : LibreChatToolDecision.reject;
      // A refusal the pause does not allow (approve only, or a reply to
      // write, which no card here takes) is never sent: the reply stops, as
      // an unanswered question stops it.
      if (!request.allowed.contains(decision)) {
        if (!asking()) return LibreChatPauseOutcome.left;
        await stop();
        return LibreChatPauseOutcome.stopped;
      }
      decisions[request.toolCallId] = LibreChatToolDecisionInput(decision);
    }
    if (!asking()) return LibreChatPauseOutcome.left;
    attempt.sending = true;
    await resume(decisions: decisions);
    return LibreChatPauseOutcome.resumed;
  } on Object catch (error, stackTrace) {
    DebugLogger.error(
      'librechat-action-failed',
      scope: 'daemon/turns',
      error: error,
      stackTrace: stackTrace,
    );
    if (attempt.sending) return LibreChatPauseOutcome.failed;
  }
  // Nothing was sent: a card could not be put up. The reply ends, once,
  // rather than waiting on a card nobody can see.
  if (!asking()) return LibreChatPauseOutcome.left;
  try {
    await stop();
  } on Object catch (error, stackTrace) {
    DebugLogger.error(
      'librechat-action-stop-failed',
      scope: 'daemon/turns',
      error: error,
      stackTrace: stackTrace,
    );
  }
  return LibreChatPauseOutcome.stopped;
}

/// A tool call's arguments, as pretty JSON for the card.
String? _argumentsJson(Object? arguments) {
  if (arguments == null) return null;
  Object? value = arguments;
  if (arguments is String) {
    try {
      value = jsonDecode(arguments);
    } on FormatException {
      return arguments;
    }
  }
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } on Object {
    // Decoded but not writable as JSON (an infinite number, say): shown as
    // sent.
    return arguments is String ? arguments : '$arguments';
  }
}
