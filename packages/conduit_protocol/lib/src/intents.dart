import 'package:freezed_annotation/freezed_annotation.dart';

import 'composer.dart';

part 'intents.freezed.dart';
part 'intents.g.dart';

/// Params for `intents.ask`: Shortcuts' Ask Conduit, a question whose answer
/// goes back to the shortcut as text.
@freezed
abstract class IntentAsk with _$IntentAsk {
  const factory IntentAsk({
    required String text,

    /// Null lets the daemon choose, as `turns.send` does: the account's
    /// default model.
    String? model,

    /// How long to wait for the answer before giving the shortcut the chat
    /// instead. The answer keeps going in the chat either way.
    @Default(120000) int timeoutMs,
  }) = _IntentAsk;

  factory IntentAsk.fromJson(Map<String, dynamic> json) =>
      _$IntentAskFromJson(json);
}

/// How an `intents.ask` question ended.
abstract final class IntentAskOutcome {
  /// The answer is in [IntentAnswer.text].
  static const String answered = 'answered';

  /// The model answered with an error; [IntentAnswer.detail] has the
  /// server's words, when it gave any.
  static const String failed = 'failed';

  /// The question waits in the outbox (sent while offline); its answer
  /// comes once the server is back.
  static const String queued = 'queued';

  /// No answer within [IntentAsk.timeoutMs]; it keeps going in the chat.
  static const String timedOut = 'timedOut';
}

/// Reply to `intents.ask`.
///
/// A question that started always names its chat, whatever happened next,
/// so the shortcut can say where the answer will be and open it.
@freezed
abstract class IntentAnswer with _$IntentAnswer {
  const factory IntentAnswer({
    required String chatId,
    required String messageId,

    /// One of [IntentAskOutcome].
    required String outcome,

    /// The answer as the Copy action copies it: Markdown, without the
    /// reasoning and tool-call blocks. Whatever had arrived when it failed
    /// or timed out.
    @Default('') String text,

    /// The server's own words for a failure.
    String? detail,

    /// The chat's title as it is now (a new chat's title may not be in yet).
    String? title,
  }) = _IntentAnswer;

  factory IntentAnswer.fromJson(Map<String, dynamic> json) =>
      _$IntentAnswerFromJson(json);
}

/// Params for `intents.chats`: the chats Shortcuts offers for Open Chat.
///
/// With [ids], those chats (a saved shortcut checking that its chat is still
/// there); else with [query], the chats that match it; else the recent ones.
@freezed
abstract class IntentChatsQuery with _$IntentChatsQuery {
  const factory IntentChatsQuery({
    @Default(<String>[]) List<String> ids,
    String? query,
    @Default(20) int limit,
  }) = _IntentChatsQuery;

  factory IntentChatsQuery.fromJson(Map<String, dynamic> json) =>
      _$IntentChatsQueryFromJson(json);
}

/// One chat as Shortcuts shows it.
@freezed
abstract class IntentChat with _$IntentChat {
  const factory IntentChat({
    required String id,
    required String title,
    @Default(0) int updatedAtMs,
    @Default(false) bool pinned,
  }) = _IntentChat;

  factory IntentChat.fromJson(Map<String, dynamic> json) =>
      _$IntentChatFromJson(json);
}

/// Reply to `intents.chats`.
@freezed
abstract class IntentChats with _$IntentChats {
  const factory IntentChats({
    @Default(<IntentChat>[]) List<IntentChat> chats,
  }) = _IntentChats;

  factory IntentChats.fromJson(Map<String, dynamic> json) =>
      _$IntentChatsFromJson(json);
}

/// Params for `intents.sendLink`: Shortcuts' Send Link to Conduit, a link
/// put into a new chat for a summary or an analysis.
@freezed
abstract class IntentLink with _$IntentLink {
  const factory IntentLink({required String url}) = _IntentLink;

  factory IntentLink.fromJson(Map<String, dynamic> json) =>
      _$IntentLinkFromJson(json);
}

/// Reply to `intents.sendLink`: what the server read from the link, as the
/// composer's Web Page attaches it, or why it read nothing.
///
/// The app opens a new chat either way, as the phone does: with the page's
/// text (or the video's transcript) attached when there is one.
@freezed
abstract class IntentLinkResult with _$IntentLinkResult {
  const factory IntentLinkResult({
    /// The link, trimmed.
    required String url,

    /// A YouTube video, whose transcript is read instead of the page.
    @Default(false) bool youtube,

    /// The page's text or the video's transcript, ready for the composer.
    ContextAttachmentDto? attachment,

    /// Null with an attachment; else `invalidUrl` (not an http or https
    /// link), `noContent` (nothing readable, no transcript) or `failed` (no
    /// Open WebUI account to read it, or the server refused).
    String? error,
  }) = _IntentLinkResult;

  factory IntentLinkResult.fromJson(Map<String, dynamic> json) =>
      _$IntentLinkResultFromJson(json);
}
