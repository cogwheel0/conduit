import 'dart:convert';

import 'package:conduit_core/features/hermes/services/hermes_identifier.dart';

/// Hermes asks at most five questions per clarify call, each with at most
/// four choices; a little slack keeps a newer server's extra row visible.
const int kMaxHermesClarifyQuestions = 6;
const int kMaxHermesClarifyChoices = 6;
const int kMaxHermesClarifyQuestionCharacters = 600;

/// Hermes' own limit (`MAX_CHOICE_CHARS`): a choice is sent back whole, so
/// a longer one is left out rather than cut.
const int kMaxHermesClarifyChoiceCharacters = 8000;

/// The most of a choice a form shows.
const int kMaxHermesClarifyChoiceLabelCharacters = 300;
const int kMaxHermesClarifyAnswerCharacters = 4000;

/// The label Hermes appends to the choice it recommends. Hermes strips it
/// from answers itself; Conduit sends the bare choice like its own UIs do.
const String _recommendedLabel = '(Recommended)';

/// One question of a Hermes clarify form.
final class HermesClarifyQuestion {
  const HermesClarifyQuestion({
    required this.id,
    required this.text,
    this.choices = const <String>[],
    this.multiSelect = false,
    this.locked = false,
    this.lockedAnswer,
  });

  /// The question's id (`qid`), which keys its answer.
  final String id;
  final String text;
  final List<String> choices;
  final bool multiSelect;

  /// Answered already (locked with `clarify.lock` on another surface):
  /// shown read-only, and left out of the answers sent from here.
  final bool locked;

  /// The locked answer; null when the question was skipped.
  final String? lockedAnswer;

  Map<String, Object?> toJson() => {
    'qid': id,
    'question': text,
    if (choices.isNotEmpty) 'choices': choices,
    if (multiSelect) 'multi_select': true,
    if (locked) 'locked': true,
    'answer': ?lockedAnswer,
  };

  /// A question as Hermes sends it (`{qid, question, choices,
  /// multi_select}`) or as [toJson] stored it; null when malformed.
  static HermesClarifyQuestion? fromJson(
    Object? raw, {
    Map<Object?, Object?> lockedAnswers = const {},
  }) {
    if (raw is! Map) return null;
    final id = validateHermesOpaqueIdentifier(raw['qid']);
    final text = _bounded(raw['question'], kMaxHermesClarifyQuestionCharacters);
    if (id == null || text == null) return null;
    final rawChoices = raw['choices'];
    final choices = <String>[
      if (rawChoices is List)
        for (final choice in rawChoices.take(kMaxHermesClarifyChoices))
          ?_whole(choice, kMaxHermesClarifyChoiceCharacters),
    ];
    final locked = raw['locked'] == true || lockedAnswers.containsKey(id);
    final answer = lockedAnswers.containsKey(id)
        ? lockedAnswers[id]
        : raw['answer'];
    return HermesClarifyQuestion(
      id: id,
      text: text,
      choices: List.unmodifiable(choices),
      multiSelect: raw['multi_select'] == true && choices.isNotEmpty,
      locked: locked,
      lockedAnswer: locked
          ? _bounded(answer, kMaxHermesClarifyAnswerCharacters)
          : null,
    );
  }
}

/// The questions of a clarify request: `questions` with the `answers`
/// Hermes already locked (a reconnect replay). Empty when malformed.
List<HermesClarifyQuestion> hermesClarifyQuestions(
  Object? questions, {
  Object? answers,
}) {
  if (questions is! List) return const [];
  final locked = answers is Map ? answers : const <Object?, Object?>{};
  final parsed = <HermesClarifyQuestion>[];
  final ids = <String>{};
  for (final raw in questions.take(kMaxHermesClarifyQuestions)) {
    final question = HermesClarifyQuestion.fromJson(raw, lockedAnswers: locked);
    if (question == null || !ids.add(question.id)) continue;
    parsed.add(question);
  }
  return List.unmodifiable(parsed);
}

/// The id a lone question gets: a request that asks one question (a REST
/// run's or a session authority's `clarify.request`) has no `qid`.
const String kHermesSingleClarifyQuestionId = 'q0';

/// The questions of a clarify payload: its `questions` form, or the one
/// question a `clarify.request` names (`question`, `choices`,
/// `multi_select`).
List<HermesClarifyQuestion> hermesClarifyQuestionsFromPayload(
  Map<Object?, Object?> payload,
) {
  final questions = payload['questions'];
  if (questions is List) {
    return hermesClarifyQuestions(questions, answers: payload['answers']);
  }
  return hermesClarifyQuestions([
    {
      'qid': kHermesSingleClarifyQuestionId,
      'question': payload['question'] ?? payload['prompt'],
      'choices': payload['choices'],
      'multi_select': payload['multi_select'] ?? payload['multiSelect'],
    },
  ]);
}

/// What the user picked and typed for one question.
final class HermesClarifyDraft {
  const HermesClarifyDraft({
    this.choices = const <String>[],
    this.text = '',
    this.skipped = false,
  });

  final List<String> choices;
  final String text;
  final bool skipped;

  /// The answer Hermes takes for [question]: the bare choice or the typed
  /// text, a JSON array string of both for a multi-select question, null
  /// when skipped or empty.
  String? answerFor(HermesClarifyQuestion question) {
    if (skipped) return null;
    final typed = text.trim();
    if (question.multiSelect) {
      final values = [
        for (final choice in choices) hermesClarifyBareChoice(choice),
        if (typed.isNotEmpty) typed,
      ];
      return values.isEmpty ? null : jsonEncode(values);
    }
    if (choices.isNotEmpty) return hermesClarifyBareChoice(choices.first);
    return typed.isEmpty ? null : typed;
  }

  /// Whether the question has an answer or was skipped on purpose.
  bool settles(HermesClarifyQuestion question) =>
      skipped || answerFor(question) != null;
}

/// [choice] without the "(Recommended)" label Hermes adds to the first one.
String hermesClarifyBareChoice(String choice) {
  final trimmed = choice.trim();
  final lower = trimmed.toLowerCase();
  if (!lower.endsWith(_recommendedLabel.toLowerCase())) return trimmed;
  return trimmed
      .substring(0, trimmed.length - _recommendedLabel.length)
      .trim();
}

/// [choice] as a form shows it: without its "(Recommended)" label, cut to
/// [kMaxHermesClarifyChoiceLabelCharacters]. The answer is the whole choice.
String hermesClarifyChoiceLabel(String choice) =>
    _bounded(
      hermesClarifyBareChoice(choice),
      kMaxHermesClarifyChoiceLabelCharacters,
    ) ??
    '';

/// Whether [choice] carries the "(Recommended)" label.
bool hermesClarifyChoiceIsRecommended(String choice) =>
    hermesClarifyBareChoice(choice) != choice.trim();

/// The answers a form sends: one per question still open (a skipped or
/// empty one as null). Locked questions are left out so their lock stands.
Map<String, String?> hermesClarifyAnswers(
  List<HermesClarifyQuestion> questions,
  Map<String, HermesClarifyDraft> drafts,
) => {
  for (final question in questions)
    if (!question.locked)
      question.id: (drafts[question.id] ?? const HermesClarifyDraft())
          .answerFor(question),
};

/// The `result` that answers a whole clarify server request.
Map<String, Object?> hermesClarifySubmission(Map<String, String?> answers) =>
    {'answers': answers, 'outcome': 'submitted'};

/// [value] trimmed, or null when it is empty or longer than [maxCharacters].
String? _whole(Object? value, int maxCharacters) {
  if (value is! String) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed.contains('\u0000')) return null;
  return trimmed.runes.length <= maxCharacters ? trimmed : null;
}

String? _bounded(Object? value, int maxCharacters) {
  if (value is! String) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed.contains('\u0000')) return null;
  final runes = trimmed.runes;
  if (runes.length <= maxCharacters) return trimmed;
  return '${String.fromCharCodes(runes.take(maxCharacters - 1))}…';
}
