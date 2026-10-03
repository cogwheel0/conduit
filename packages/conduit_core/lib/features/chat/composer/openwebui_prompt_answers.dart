// The answer state of an Open WebUI composer prompt (ask-user questions, a
// tool approval or a confirmation), kept out of the overlay
// (lib/features/chat/widgets/openwebui_prompt_overlay.dart) so it is tested
// without Flutter. The widgets draw it and call setState when
// [OpenWebUiPromptAnswers.onChanged] fires.
import 'dart:async';

import 'package:conduit_core/models/openwebui_chat_prompt.dart';

/// One prompt's answers, the question being shown, and whether an answer or
/// decision is being sent.
class OpenWebUiPromptAnswers {
  OpenWebUiPromptAnswers(this.prompt);

  final OpenWebUiComposerPrompt prompt;
  final Map<String, Map<String, dynamic>> _answers = {};
  var _questionIndex = 0;
  var _busy = false;
  var _failed = false;

  /// The index of the question on screen.
  int get questionIndex => _questionIndex;

  /// The question on screen; null for an approval or confirmation.
  OpenWebUiPromptQuestion? get question =>
      prompt.questions.isEmpty ? null : prompt.questions[_questionIndex];

  /// "2/3" while there is more than one question, else null.
  String? get progressLabel => prompt.questions.length > 1
      ? '${_questionIndex + 1}/${prompt.questions.length}'
      : null;

  /// An answer or decision is on its way.
  bool get busy => _busy;

  /// The last answer or decision failed.
  bool get failed => _failed;

  /// The recorded answer to [questionId].
  Map<String, dynamic>? answerFor(String questionId) => _answers[questionId];

  /// Whether option [index] of [questionId] is the chosen answer.
  bool isOptionSelected(String questionId, int index) {
    final answer = _answers[questionId];
    return answer?['type'] == 'option' && answer?['option_index'] == index;
  }

  /// Every question has an option, or a non-blank "other" text.
  bool get complete =>
      prompt.questions.isNotEmpty &&
      prompt.questions.every((question) {
        final answer = _answers[question.id];
        return answer?['type'] == 'option' ||
            (answer?['type'] == 'other' &&
                (answer?['text']?.toString().trim().isNotEmpty ?? false));
      });

  bool get canGoPrevious => _questionIndex > 0;

  bool get hasNext => _questionIndex < prompt.questions.length - 1;

  /// Next is offered once the question on screen has an answer.
  bool get canGoNext {
    final current = question;
    return hasNext && current != null && _answers.containsKey(current.id);
  }

  void previous() {
    if (canGoPrevious) _questionIndex--;
  }

  void next() {
    if (hasNext) _questionIndex++;
  }

  void selectOption(
    OpenWebUiPromptQuestion question,
    OpenWebUiPromptOption option,
    int index,
  ) {
    _answers[question.id] = <String, dynamic>{
      'type': 'option',
      'option_index': index,
      'label': option.label,
      'description': option.description,
    };
  }

  /// Focusing the "other" field chooses it, with the text typed so far.
  void selectOther(OpenWebUiPromptQuestion question, String text) {
    _answers[question.id] = <String, dynamic>{
      'type': 'other',
      'text': text.trim(),
    };
  }

  void updateOther(OpenWebUiPromptQuestion question, String text) {
    _answers[question.id] = <String, dynamic>{'type': 'other', 'text': text};
  }

  /// The answers Open WebUI takes: each "other" text trimmed, and no text
  /// on an option answer.
  Map<String, dynamic> submission() => <String, dynamic>{
    for (final entry in _answers.entries)
      entry.key: Map<String, dynamic>.from(entry.value)
        ..update('text', (value) => value.toString().trim(), ifAbsent: () => '')
        ..removeWhere(
          (key, _) => key == 'text' && entry.value['type'] != 'other',
        ),
  };

  /// Runs [action] (an answer or a decision) once at a time. While it runs
  /// the prompt is busy; a throw clears busy and marks the prompt failed. A
  /// success leaves it busy: the prompt goes away when the turn resumes.
  /// [onChanged] fires on each transition.
  Future<void> run(
    FutureOr<void> Function() action, {
    void Function()? onChanged,
  }) async {
    if (_busy) return;
    _busy = true;
    _failed = false;
    onChanged?.call();
    try {
      await action();
    } catch (_) {
      _busy = false;
      _failed = true;
      onChanged?.call();
    }
  }
}

/// Whether a prompt persisted on a message may be answered from the chat on
/// screen: the conversation has loaded and owns the prompt.
bool canUsePersistedOpenWebUiPrompt({
  required bool isLoadingConversation,
  required String? ownerConversationId,
  required String? activeConversationId,
}) {
  return !isLoadingConversation &&
      ownerConversationId != null &&
      ownerConversationId == activeConversationId;
}
