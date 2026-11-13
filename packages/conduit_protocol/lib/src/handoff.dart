import 'package:freezed_annotation/freezed_annotation.dart';

part 'handoff.freezed.dart';
part 'handoff.g.dart';

/// Payload of `handoff.requested`: the server (an Open WebUI function, with
/// `chat:handoff`) suggests carrying on in a new chat with another model.
/// Nothing happens unless the user agrees, and then only this: a new chat
/// on that model with [prompt] in its message field, unsent.
@freezed
abstract class HandoffRequest with _$HandoffRequest {
  const factory HandoffRequest({
    required String requestId,

    /// The chat it came from.
    required String chatId,
    required String modelId,

    /// The model's name, for the question.
    required String modelName,

    /// What the new chat's message field starts with; may be empty.
    @Default('') String prompt,
  }) = _HandoffRequest;

  factory HandoffRequest.fromJson(Map<String, dynamic> json) =>
      _$HandoffRequestFromJson(json);
}

/// Params for `handoff.answer`.
@freezed
abstract class HandoffAnswer with _$HandoffAnswer {
  const factory HandoffAnswer({
    required String requestId,
    required bool accept,
  }) = _HandoffAnswer;

  factory HandoffAnswer.fromJson(Map<String, dynamic> json) =>
      _$HandoffAnswerFromJson(json);
}

/// Reply to `handoff.answer`: whether the window that answered opens the new
/// chat, and with what. False when another window answered first or the
/// question ran out of time.
@freezed
abstract class HandoffAnswered with _$HandoffAnswered {
  const factory HandoffAnswered({
    required bool open,
    String? modelId,
    String? prompt,
  }) = _HandoffAnswered;

  factory HandoffAnswered.fromJson(Map<String, dynamic> json) =>
      _$HandoffAnsweredFromJson(json);
}

/// Payload of `handoff.settled`: [requestId] was answered (or ran out of
/// time). Windows that did not answer close their question.
@freezed
abstract class HandoffSettled with _$HandoffSettled {
  const factory HandoffSettled({required String requestId}) = _HandoffSettled;

  factory HandoffSettled.fromJson(Map<String, dynamic> json) =>
      _$HandoffSettledFromJson(json);
}
