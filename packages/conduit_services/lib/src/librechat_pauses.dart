import 'dart:async';

import 'package:conduit_core/features/librechat/models/librechat_tools.dart';
import 'package:conduit_core/features/librechat/services/librechat_pause_controller.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import 'ui_requests_service.dart';

/// What became of a pause put to the windows.
enum LibreChatPauseOutcome {
  /// Every card was answered and the run goes on with the answers.
  resumed,

  /// The turn that asked is over (stopped, finished, another account in
  /// charge), or there was nothing to put to a window: nothing more is
  /// done for it.
  left,
}

/// Puts what a LibreChat run paused on to the windows, one card at a time,
/// and resumes the run once every card is answered, by the core's rule for
/// a pause ([LibreChatPauseController]): each tool call offers every
/// decision the server allows for it, each question its choices, answered
/// by their values.
///
/// A card waits until it is answered. Nothing here refuses, rejects or
/// stops on its own: with no window to put it to, the pause waits for one
/// while its turn still asks, and a card every window closed comes back
/// when one is there again. It ends when [asking] says the turn no longer
/// waits on it, and its card goes when [until] completes (the turn ended,
/// or the account in charge changed).
///
/// An answer the core does not take (an edit that is not a JSON object, an
/// empty response) puts the card back with the reason and what was typed;
/// answers that could not be sent put the last card back to be answered
/// again.
Future<LibreChatPauseOutcome> answerLibreChatPause(
  LibreChatPendingAction action, {
  required UiRequestsService? windows,
  required String chatId,
  required bool Function() asking,
  required LibreChatPauseResolver resume,
  required Future<void> until,
}) async {
  final pause = LibreChatPauseController(action, resolve: resume);
  // Why the card is put again, and what was typed: shown on it.
  LibreChatPauseStep? problem;
  String? typed;
  var over = false;
  unawaited(until.whenComplete(() => over = true));
  while (!over && asking()) {
    final card = pause.current;
    if (card == null || windows == null) return LibreChatPauseOutcome.left;
    if (!windows.canAsk) {
      if (!await windows.windowBack(until)) return LibreChatPauseOutcome.left;
      continue;
    }
    final reply = await windows.askLibreChatPause(
      chatId: chatId,
      card: card,
      failed: pause.failed,
      refusal: problem,
      typed: typed,
      until: until,
    );
    if (over || !asking()) return LibreChatPauseOutcome.left;
    // Every window went, or the card was taken back: nothing was decided,
    // and the card is put again once a window is there.
    if (!reply.answered) continue;
    final step = await _take(pause, card, reply.choice, reply.text);
    switch (step) {
      case LibreChatPauseStep.sent:
        return LibreChatPauseOutcome.resumed;
      case LibreChatPauseStep.next ||
          LibreChatPauseStep.failed ||
          LibreChatPauseStep.stale ||
          LibreChatPauseStep.busy:
        problem = null;
        typed = null;
      case LibreChatPauseStep.notAllowed ||
          LibreChatPauseStep.invalidArguments ||
          LibreChatPauseStep.empty:
        problem = step;
        typed = reply.text;
    }
  }
  return LibreChatPauseOutcome.left;
}

/// The window's answer to [card], taken by the controller.
Future<LibreChatPauseStep> _take(
  LibreChatPauseController pause,
  LibreChatPauseCard card,
  String choice,
  String? text,
) async {
  try {
    switch (card) {
      case LibreChatToolCard():
        final decision = LibreChatToolDecision.values
            .where((decision) => decision.name == choice)
            .firstOrNull;
        if (decision == null) return LibreChatPauseStep.notAllowed;
        return await pause.decide(card.id, switch (decision) {
          LibreChatToolDecision.edit => LibreChatToolDecisionInput(
            decision,
            editedArguments: LibreChatPauseController.editedArguments(
              text ?? '',
            ),
          ),
          LibreChatToolDecision.respond => LibreChatToolDecisionInput(
            decision,
            responseText: text?.trim(),
          ),
          _ => LibreChatToolDecisionInput(decision),
        });
      case LibreChatQuestionCard():
        // The window's question card answers `allow` with the text, as any
        // question card does; `answer` is the plain word for it.
        if (choice != 'answer' && choice != 'allow') {
          return LibreChatPauseStep.empty;
        }
        return await pause.answer(card.id, card.answerFor(text ?? ''));
    }
  } on Object catch (error, stackTrace) {
    DebugLogger.error(
      'librechat-action-failed',
      scope: 'daemon/turns',
      error: error,
      stackTrace: stackTrace,
    );
    return LibreChatPauseStep.failed;
  }
}
