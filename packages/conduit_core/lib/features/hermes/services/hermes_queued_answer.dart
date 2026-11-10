import 'dart:math' as math;

import 'package:clock/clock.dart';

import 'package:conduit_core/features/hermes/services/hermes_message_mapper.dart';

/// How often a chat looks for the answer of a message Hermes saved during a
/// restart: soon at first, then every half minute.
const List<Duration> kHermesQueuedAnswerDelays = [
  Duration(seconds: 2),
  Duration(seconds: 3),
  Duration(seconds: 5),
  Duration(seconds: 8),
  Duration(seconds: 13),
  Duration(seconds: 20),
  Duration(seconds: 30),
];

/// How often it looks while it has no row count to start from (the first
/// read failed, as while Hermes restarts): often, so the count is taken
/// soon after Hermes is back, before the saved message can have run.
const Duration kHermesQueuedAnswerBaselineRetry = Duration(seconds: 1);

/// How long a chat waits for that answer before it stops looking.
const Duration kHermesQueuedAnswerTimeout = Duration(minutes: 10);

/// The status a turn shows while its saved message's answer is followed,
/// then what came of it.
const String kHermesQueuedAnswerAction = 'hermes_queued_answer';
const String kHermesQueuedAnswerWaitingMessage =
    'Waiting for Hermes to come back and answer.';
const String kHermesQueuedAnswerArrivedMessage =
    'Hermes answered once it was back.';
const String kHermesQueuedAnswerLateMessage =
    'Hermes has not answered yet. Open this chat again later to see its '
    'answer.';

/// What came of following a saved message's answer.
sealed class HermesQueuedAnswer {
  const HermesQueuedAnswer();
}

/// The answer arrived: [rows] are the session's rows added since following
/// began, the saved message's and its answer's.
final class HermesQueuedAnswerArrived extends HermesQueuedAnswer {
  const HermesQueuedAnswerArrived(this.rows);

  final List<Map<String, dynamic>> rows;
}

/// No answer within the time allowed.
final class HermesQueuedAnswerPending extends HermesQueuedAnswer {
  const HermesQueuedAnswerPending();
}

/// The chat stopped waiting: it was left, or something else was sent.
final class HermesQueuedAnswerAbandoned extends HermesQueuedAnswer {
  const HermesQueuedAnswerAbandoned();
}

/// Follows a session in which Hermes saved a message to run once it is back
/// (`admission_queued`), reading it with [readTranscript] until rows added
/// after the first [baseline] end in an answer. Nothing is ever sent again.
///
/// A null [baseline] is taken from the first read that succeeds, looking
/// every [baselineRetry] until one does; [delays] start from there. Reads
/// that fail, as while Hermes restarts, are tried again at the next look.
/// It stops as soon as [isCurrent] turns false, and gives up after
/// [timeout].
Future<HermesQueuedAnswer> awaitHermesQueuedAnswer({
  required Future<List<Map<String, dynamic>>> Function() readTranscript,
  required bool Function() isCurrent,
  int? baseline,
  List<Duration> delays = kHermesQueuedAnswerDelays,
  Duration baselineRetry = kHermesQueuedAnswerBaselineRetry,
  Duration timeout = kHermesQueuedAnswerTimeout,
}) async {
  final deadline = clock.now().add(timeout);
  var known = baseline;
  var looks = 0;
  for (;;) {
    final delay = known == null
        ? baselineRetry
        : delays[math.min(looks++, delays.length - 1)];
    if (clock.now().add(delay).isAfter(deadline)) {
      return const HermesQueuedAnswerPending();
    }
    await Future<void>.delayed(delay);
    if (!isCurrent()) return const HermesQueuedAnswerAbandoned();
    final List<Map<String, dynamic>> rows;
    try {
      rows = await readTranscript();
    } catch (_) {
      continue;
    }
    if (!isCurrent()) return const HermesQueuedAnswerAbandoned();
    final from = known ??= rows.length;
    if (rows.length <= from) continue;
    final added = List<Map<String, dynamic>>.unmodifiable(rows.sublist(from));
    if (hermesRowsEndInAnswer(added)) return HermesQueuedAnswerArrived(added);
  }
}

/// Whether [rows] end in a finished answer: their last message, as a chat
/// shows it, is the agent's and has text.
bool hermesRowsEndInAnswer(List<Map<String, dynamic>> rows) {
  final last = hermesMessagesToChatMessages(rows).lastOrNull;
  return last != null &&
      last.role == 'assistant' &&
      last.error == null &&
      last.content.trim().isNotEmpty;
}
