import 'package:freezed_annotation/freezed_annotation.dart';

part 'chat_prompts.freezed.dart';
part 'chat_prompts.g.dart';

/// What an Open WebUI prompt asks for.
enum ChatPromptKind {
  /// Questions for the user (Open WebUI's `ask_user`, or a coding agent's
  /// own questions): [ChatPromptDto.questions], answered with
  /// `chatPrompts.answer`.
  askUser,

  /// A tool wants to run: [ChatPromptDto.title] is the tool's name and
  /// [ChatPromptDto.message] its arguments, pretty-printed. Answered with
  /// `chatPrompts.decide`.
  toolApproval,

  /// The server (or a coding agent) asks for a yes or a no:
  /// [ChatPromptDto.title] and [ChatPromptDto.message] are its words.
  /// Answered with `chatPrompts.decide`.
  confirmation,
}

/// One choice of a [ChatPromptQuestionDto].
@freezed
abstract class ChatPromptOptionDto with _$ChatPromptOptionDto {
  const factory ChatPromptOptionDto({
    required String label,

    /// What choosing it means; a coding agent's choices can come without
    /// one.
    @Default('') String description,
  }) = _ChatPromptOptionDto;

  factory ChatPromptOptionDto.fromJson(Map<String, dynamic> json) =>
      _$ChatPromptOptionDtoFromJson(json);
}

/// One question of an [ChatPromptKind.askUser] prompt.
@freezed
abstract class ChatPromptQuestionDto with _$ChatPromptQuestionDto {
  const factory ChatPromptQuestionDto({
    /// The key its answer goes under. A coding agent's can be the whole
    /// question.
    required String id,

    /// A short title ("Question 1" when the server gave none).
    required String header,
    required String question,

    /// The choices, the recommended one first; none for a question that
    /// can only be answered in words.
    @Default(<ChatPromptOptionDto>[]) List<ChatPromptOptionDto> options,

    /// An answer of the user's own words is accepted.
    @Default(true) bool allowOther,
  }) = _ChatPromptQuestionDto;

  factory ChatPromptQuestionDto.fromJson(Map<String, dynamic> json) =>
      _$ChatPromptQuestionDtoFromJson(json);
}

/// A question or approval Open WebUI is waiting on in a chat: the card
/// docked above that chat's composer.
///
/// Server and agent text is prose as written; the window words the rest.
@freezed
abstract class ChatPromptDto with _$ChatPromptDto {
  const factory ChatPromptDto({
    /// This prompt; an answer names it, so an answer to one that has gone
    /// does not count.
    required String id,
    required String chatId,
    required ChatPromptKind kind,

    /// [ChatPromptKind.toolApproval]: the tool's name ("Tool" when it has
    /// none). [ChatPromptKind.confirmation]: the server's title; may be
    /// empty.
    @Default('') String title,

    /// The tool's arguments, or the confirmation's message; may be empty.
    @Default('') String message,

    /// [ChatPromptKind.askUser]: the questions, in order.
    @Default(<ChatPromptQuestionDto>[]) List<ChatPromptQuestionDto> questions,

    /// When the server stops waiting (milliseconds since the epoch), for a
    /// prompt asked over the live connection; null for one saved in the
    /// chat, which waits until answered.
    int? expiresAtMs,
  }) = _ChatPromptDto;

  factory ChatPromptDto.fromJson(Map<String, dynamic> json) =>
      _$ChatPromptDtoFromJson(json);
}

/// Params for `chatPrompts.get`.
@freezed
abstract class ChatPromptRef with _$ChatPromptRef {
  const factory ChatPromptRef({required String chatId}) = _ChatPromptRef;

  factory ChatPromptRef.fromJson(Map<String, dynamic> json) =>
      _$ChatPromptRefFromJson(json);
}

/// Reply to `chatPrompts.get`, and the payload of `chatPrompts.changed`
/// (scoped to the chat): the prompt waiting in [chatId], or none.
@freezed
abstract class ChatPromptState with _$ChatPromptState {
  const factory ChatPromptState({
    required String chatId,
    @JsonKey(includeIfNull: true) ChatPromptDto? prompt,
  }) = _ChatPromptState;

  factory ChatPromptState.fromJson(Map<String, dynamic> json) =>
      _$ChatPromptStateFromJson(json);
}

/// The answer to one question: an option by its index, or the user's own
/// [text].
@freezed
abstract class ChatPromptAnswerItem with _$ChatPromptAnswerItem {
  const factory ChatPromptAnswerItem({
    required String questionId,

    /// The chosen option's index in the question's options.
    int? optionIndex,

    /// The user's own words, when the question accepts them.
    String? text,
  }) = _ChatPromptAnswerItem;

  factory ChatPromptAnswerItem.fromJson(Map<String, dynamic> json) =>
      _$ChatPromptAnswerItemFromJson(json);
}

/// Params for `chatPrompts.answer`: every question's answer.
@freezed
abstract class ChatPromptAnswer with _$ChatPromptAnswer {
  const factory ChatPromptAnswer({
    required String chatId,
    required String promptId,
    @Default(<ChatPromptAnswerItem>[]) List<ChatPromptAnswerItem> answers,
  }) = _ChatPromptAnswer;

  factory ChatPromptAnswer.fromJson(Map<String, dynamic> json) =>
      _$ChatPromptAnswerFromJson(json);
}

/// Params for `chatPrompts.decide`: an approval or confirmation answered,
/// or questions declined ([approved] false).
@freezed
abstract class ChatPromptDecision with _$ChatPromptDecision {
  const factory ChatPromptDecision({
    required String chatId,
    required String promptId,
    required bool approved,
  }) = _ChatPromptDecision;

  factory ChatPromptDecision.fromJson(Map<String, dynamic> json) =>
      _$ChatPromptDecisionFromJson(json);
}
