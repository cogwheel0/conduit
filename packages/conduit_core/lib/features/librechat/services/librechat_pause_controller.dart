import 'dart:convert';

import 'package:meta/meta.dart';

import 'package:conduit_core/features/librechat/models/librechat_tools.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// Sends the answer to a paused run: [decisions] for tool calls, or
/// [answers] for questions (`resolveLibreChatPendingAction`).
typedef LibreChatPauseResolver =
    Future<void> Function({
      Map<String, LibreChatToolDecisionInput>? decisions,
      Map<String, String>? answers,
    });

/// What a card's answer came to.
enum LibreChatPauseStep {
  /// Taken; the next card is up.
  next,

  /// The last answer was taken and the run's answer went out.
  sent,

  /// The run's answer could not be sent: the last card is up again, its
  /// answer cleared, to be answered again.
  failed,

  /// The run's answer is going out, or has gone: nothing more is taken.
  busy,

  /// An answer for a card that is not the one up: one already answered, or
  /// one not shown yet. A window that answers twice, or late, never decides
  /// a card the user did not see.
  stale,

  /// A decision the server does not allow for this call.
  notAllowed,

  /// An edit whose arguments are not a JSON object, which is all LibreChat
  /// runs a tool with.
  invalidArguments,

  /// A response, or an answer, with no text.
  empty,
}

/// One card a paused run puts to the user.
@immutable
sealed class LibreChatPauseCard {
  const LibreChatPauseCard({required this.index, required this.count});

  /// Its place among the pause's cards, from 0, and how many there are.
  final int index;
  final int count;

  /// The id it is answered under: the tool call's, or the question's.
  String get id;
}

/// A paused tool call and the decisions the server allows for it, in the
/// server's order.
final class LibreChatToolCard extends LibreChatPauseCard {
  const LibreChatToolCard(
    this.request, {
    required super.index,
    required super.count,
  });

  final LibreChatToolRequest request;

  @override
  String get id => request.toolCallId;

  List<LibreChatToolDecision> get allowed => request.allowed;

  /// The arguments as the user reads them; null when there are none.
  String? get argumentsText {
    final arguments = request.arguments;
    if (arguments == null) return null;
    if (arguments is String) {
      final text = arguments.trim();
      return text.isEmpty || text == '{}' ? null : text;
    }
    if (arguments is Map && arguments.isEmpty) return null;
    try {
      return const JsonEncoder.withIndent('  ').convert(arguments);
    } catch (_) {
      return arguments.toString();
    }
  }

  /// The arguments to start an edit from, as JSON: the call's own, or an
  /// empty object.
  String get editableArguments {
    final arguments = request.arguments;
    var value = arguments;
    if (arguments is String) {
      try {
        value = jsonDecode(arguments);
      } on FormatException {
        return arguments;
      }
    }
    if (value == null) return '{}';
    try {
      return const JsonEncoder.withIndent('  ').convert(value);
    } catch (_) {
      return '{}';
    }
  }
}

/// A question the agent asked: its choices, each shown by its label and
/// answered with its value, as LibreChat's own client answers.
final class LibreChatQuestionCard extends LibreChatPauseCard {
  const LibreChatQuestionCard({
    required this.id,
    required this.question,
    required this.description,
    required this.choices,
    required this.multiSelect,
    required super.index,
    required super.count,
  });

  @override
  final String id;
  final String question;
  final String? description;
  final List<({String label, String value})> choices;
  final bool multiSelect;

  /// The answer to send for what was [picked]: a choice's label becomes its
  /// value. Several choices come as a JSON list of labels, and LibreChat
  /// takes one answer per question, the values joined with ", ". Typed text
  /// goes as it is.
  String answerFor(String picked) {
    String valueOf(String label) =>
        choices.where((choice) => choice.label == label).firstOrNull?.value ??
        label;
    if (!multiSelect) return valueOf(picked);
    try {
      final decoded = jsonDecode(picked);
      if (decoded is List) {
        return decoded.map((label) => valueOf('$label')).join(', ');
      }
    } on FormatException {
      // Typed text, not a list of choices.
    }
    return picked;
  }
}

/// The policy of one LibreChat pause, for every host: one card at a time,
/// each tool call offering only the decisions the server allows and each
/// question its choices; every answer kept until the last, then all sent
/// together. A card waits until it is answered: nothing here times out or
/// dismisses, and a reply stops only by the user stopping it. A failed send
/// puts the last card back, its answer cleared, to be answered again.
final class LibreChatPauseController {
  LibreChatPauseController(this.action, {required LibreChatPauseResolver resolve})
    : _resolve = resolve;

  final LibreChatPendingAction action;
  final LibreChatPauseResolver _resolve;

  final Map<String, LibreChatToolDecisionInput> _decisions = {};
  final Map<String, String> _answers = {};
  bool _sending = false;
  bool _failed = false;
  bool _sent = false;

  /// The run's answer is going out.
  bool get sending => _sending;

  /// The last send failed; the card it took is up again.
  bool get failed => _failed;

  /// The run's answer went out.
  bool get sent => _sent;

  /// The arguments an edit typed as [text], when they are a JSON object
  /// (all LibreChat runs a tool with); null otherwise.
  static Map<String, dynamic>? editedArguments(String text) {
    try {
      final parsed = jsonDecode(text);
      return parsed is Map ? Map<String, dynamic>.from(parsed) : null;
    } on FormatException {
      return null;
    }
  }

  List<LibreChatToolCard> get _toolCards {
    final requests = action.isToolApproval
        ? action.toolRequests
        : const <LibreChatToolRequest>[];
    return [
      for (final (index, request) in requests.indexed)
        LibreChatToolCard(request, index: index, count: requests.length),
    ];
  }

  List<LibreChatQuestionCard> get _questionCards {
    final questions = action.isQuestion
        ? action.questions
        : const <Map<String, dynamic>>[];
    return [
      for (final (index, question) in questions.indexed)
        LibreChatQuestionCard(
          id: question['id']?.toString() ?? 'question_$index',
          question: question['question']?.toString().trim() ?? '',
          description: _nonEmpty(question['description']?.toString().trim()),
          choices: _choices(question['options']),
          multiSelect: question['multiSelect'] == true,
          index: index,
          count: questions.length,
        ),
    ];
  }

  /// The card to answer: the first one without an answer, else the last
  /// (while the answer goes out, or after it failed). Null when the pause
  /// puts nothing to the user.
  LibreChatPauseCard? get current {
    final tools = _toolCards;
    if (tools.isNotEmpty) {
      return tools.where((card) => !_decisions.containsKey(card.id)).firstOrNull ??
          tools.last;
    }
    final questions = _questionCards;
    if (questions.isNotEmpty) {
      return questions.where((card) => !_answers.containsKey(card.id)).firstOrNull ??
          questions.last;
    }
    return null;
  }

  /// Decides the tool call [cardId], which must be the one up.
  Future<LibreChatPauseStep> decide(
    String cardId,
    LibreChatToolDecisionInput decision,
  ) {
    final card = current;
    if (_sending || _sent || card is! LibreChatToolCard) {
      return Future.value(LibreChatPauseStep.busy);
    }
    if (card.id != cardId || _decisions.containsKey(cardId)) {
      return Future.value(LibreChatPauseStep.stale);
    }
    if (!card.allowed.contains(decision.decision)) {
      return Future.value(LibreChatPauseStep.notAllowed);
    }
    switch (decision.decision) {
      case LibreChatToolDecision.edit when decision.editedArguments == null:
        return Future.value(LibreChatPauseStep.invalidArguments);
      case LibreChatToolDecision.respond
          when (decision.responseText?.trim() ?? '').isEmpty:
        return Future.value(LibreChatPauseStep.empty);
      default:
    }
    _decisions[card.id] = decision;
    if (_decisions.length < card.count) {
      _failed = false;
      return Future.value(LibreChatPauseStep.next);
    }
    return _send(card.id, decisions: Map.of(_decisions));
  }

  /// Answers the question [cardId], which must be the one up, with
  /// [answer], as [LibreChatQuestionCard.answerFor] makes it.
  Future<LibreChatPauseStep> answer(String cardId, String answer) {
    final card = current;
    if (_sending || _sent || card is! LibreChatQuestionCard) {
      return Future.value(LibreChatPauseStep.busy);
    }
    if (card.id != cardId || _answers.containsKey(cardId)) {
      return Future.value(LibreChatPauseStep.stale);
    }
    if (answer.trim().isEmpty) return Future.value(LibreChatPauseStep.empty);
    _answers[card.id] = answer;
    if (_answers.length < card.count) {
      _failed = false;
      return Future.value(LibreChatPauseStep.next);
    }
    return _send(card.id, answers: Map.of(_answers));
  }

  Future<LibreChatPauseStep> _send(
    String lastId, {
    Map<String, LibreChatToolDecisionInput>? decisions,
    Map<String, String>? answers,
  }) async {
    _sending = true;
    _failed = false;
    try {
      await _resolve(decisions: decisions, answers: answers);
      _sent = true;
      return LibreChatPauseStep.sent;
    } on Object catch (error) {
      DebugLogger.warning(
        'pending-action-answer-failed',
        scope: 'librechat/pause',
        data: {'error': error.runtimeType.toString()},
      );
      _decisions.remove(lastId);
      _answers.remove(lastId);
      _failed = true;
      return LibreChatPauseStep.failed;
    } finally {
      _sending = false;
    }
  }
}

String? _nonEmpty(String? text) => text == null || text.isEmpty ? null : text;

/// A question's choices, which LibreChat sends as labels or as
/// `{label, value, description}`.
List<({String label, String value})> _choices(Object? options) => [
  if (options is List)
    for (final option in options)
      if (option is String && option.isNotEmpty)
        (label: option, value: option)
      else if (option is Map && option['label'] is String)
        (
          label: option['label'] as String,
          value: option['value'] is String
              ? option['value'] as String
              : option['label'] as String,
        ),
];
