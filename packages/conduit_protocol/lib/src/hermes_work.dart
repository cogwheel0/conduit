import 'package:freezed_annotation/freezed_annotation.dart';

part 'hermes_work.freezed.dart';
part 'hermes_work.g.dart';

// ---------------------------------------------------------------------------
// hermes.work.* -- what a Hermes chat's agent has running besides its reply
// ---------------------------------------------------------------------------

/// Params for `hermes.work.watch`: the window shows [chatId] and wants its
/// agent's work, live, as `hermes.work.changed` events scoped to the chat.
///
/// Watching again with another [subagentId] changes whose output comes
/// with the work; without one, none does. `hermes.work.unwatch` (or the
/// window's connection closing) stops it.
@freezed
abstract class HermesWorkWatch with _$HermesWorkWatch {
  const factory HermesWorkWatch({
    required String chatId,

    /// The subagent whose output the window shows, read every 2 s while it
    /// runs.
    String? subagentId,
  }) = _HermesWorkWatch;

  factory HermesWorkWatch.fromJson(Map<String, dynamic> json) =>
      _$HermesWorkWatchFromJson(json);
}

/// A chat's agent at work: its subagents, its background processes and its
/// plan. Reply to `hermes.work.watch` and payload of `hermes.work.changed`.
///
/// Only a Hermes Desktop Gateway reports subagents, processes and a plan;
/// any other chat has none of them.
@freezed
abstract class HermesWork with _$HermesWork {
  const factory HermesWork({
    required String chatId,

    /// False until the first list arrives (and for a chat with no Hermes
    /// session to list).
    @Default(false) bool loaded,
    @Default(<HermesSubagentDto>[]) List<HermesSubagentDto> subagents,

    /// Every process Hermes lists, finished ones too; a chip counts the
    /// running ones.
    @Default(<HermesProcessDto>[]) List<HermesProcessDto> processes,

    /// The agent's task list, when it keeps one.
    HermesPlanDto? plan,

    /// The output of the subagent the watch named.
    HermesSubagentOutputDto? output,

    /// The directory the chat runs its tools in, when Hermes said: changed
    /// files inside it are listed by their path from there.
    String? workingDirectory,
  }) = _HermesWork;

  factory HermesWork.fromJson(Map<String, dynamic> json) =>
      _$HermesWorkFromJson(json);
}

/// A child agent the chat's agent delegated a task to.
@freezed
abstract class HermesSubagentDto with _$HermesSubagentDto {
  const factory HermesSubagentDto({
    required String id,

    /// What it was asked to do; empty when Hermes did not say.
    @Default('') String goal,

    /// The subagent that started this one, when it is nested.
    String? parentId,

    /// How deep it is nested (0 at the top).
    @Default(0) int depth,
    String? model,

    /// When it started, in milliseconds since the epoch.
    int? startedAtMs,

    /// Hermes' word for where it is: `queued`, `running`, `completed`…
    String? status,

    /// Queued or running.
    @Default(true) bool running,
    @Default(0) int toolCount,

    /// The tool it used last, by its id.
    String? lastTool,

    /// Whether Hermes still passes new instructions on to it.
    @Default(true) bool acceptingSteer,
  }) = _HermesSubagentDto;

  factory HermesSubagentDto.fromJson(Map<String, dynamic> json) =>
      _$HermesSubagentDtoFromJson(json);
}

/// A command the agent left running: a dev server, a watcher, a build.
@freezed
abstract class HermesProcessDto with _$HermesProcessDto {
  const factory HermesProcessDto({
    required String id,

    /// Its first line, shortened.
    required String command,
    @Default(true) bool running,

    /// When it started, in milliseconds since the epoch.
    int? startedAtMs,
    int? exitCode,

    /// The end of what it printed, when Hermes sent it.
    String? output,
  }) = _HermesProcessDto;

  factory HermesProcessDto.fromJson(Map<String, dynamic> json) =>
      _$HermesProcessDtoFromJson(json);
}

/// The agent's task list, as Hermes last reported it.
@freezed
abstract class HermesPlanDto with _$HermesPlanDto {
  const factory HermesPlanDto({
    @Default(<HermesPlanItemDto>[]) List<HermesPlanItemDto> items,

    /// How many are completed.
    @Default(0) int done,

    /// Whether anything is still to do or under way.
    @Default(false) bool active,

    /// The item under way, else the next to do.
    String? currentId,

    /// Only grows; a later empty list is a cleared plan.
    @Default(0) int revision,
  }) = _HermesPlanDto;

  factory HermesPlanDto.fromJson(Map<String, dynamic> json) =>
      _$HermesPlanDtoFromJson(json);
}

/// One item of the agent's task list.
@freezed
abstract class HermesPlanItemDto with _$HermesPlanItemDto {
  const factory HermesPlanItemDto({
    required String id,
    required String content,

    /// `pending`, `in_progress`, `completed` or `cancelled`.
    @Default('pending') String status,

    /// How deep it is nested under other items (0 at the top, at most 3).
    @Default(0) int depth,
  }) = _HermesPlanItemDto;

  factory HermesPlanItemDto.fromJson(Map<String, dynamic> json) =>
      _$HermesPlanItemDtoFromJson(json);
}

/// The end of a subagent's live output.
@freezed
abstract class HermesSubagentOutputDto with _$HermesSubagentOutputDto {
  const factory HermesSubagentOutputDto({
    required String subagentId,

    /// False until the first read answers.
    @Default(false) bool loaded,

    /// Reading it failed, with nothing to show.
    @Default(false) bool failed,

    /// False while the subagent has no output yet, or once it is gone.
    @Default(false) bool available,
    @Default('') String text,

    /// Earlier output was cut off.
    @Default(false) bool truncated,
  }) = _HermesSubagentOutputDto;

  factory HermesSubagentOutputDto.fromJson(Map<String, dynamic> json) =>
      _$HermesSubagentOutputDtoFromJson(json);
}

/// Params for `hermes.work.unwatch`.
@freezed
abstract class HermesWorkChat with _$HermesWorkChat {
  const factory HermesWorkChat({required String chatId}) = _HermesWorkChat;

  factory HermesWorkChat.fromJson(Map<String, dynamic> json) =>
      _$HermesWorkChatFromJson(json);
}

/// Params for `hermes.work.steer`: new instructions for a running
/// subagent.
@freezed
abstract class HermesSteerSubagent with _$HermesSteerSubagent {
  const factory HermesSteerSubagent({
    required String chatId,
    required String subagentId,
    required String text,
  }) = _HermesSteerSubagent;

  factory HermesSteerSubagent.fromJson(Map<String, dynamic> json) =>
      _$HermesSteerSubagentFromJson(json);
}

/// Params for `hermes.work.stop`.
@freezed
abstract class HermesSubagentRef with _$HermesSubagentRef {
  const factory HermesSubagentRef({
    required String chatId,
    required String subagentId,
  }) = _HermesSubagentRef;

  factory HermesSubagentRef.fromJson(Map<String, dynamic> json) =>
      _$HermesSubagentRefFromJson(json);
}

/// Params for `hermes.work.kill`.
@freezed
abstract class HermesProcessRef with _$HermesProcessRef {
  const factory HermesProcessRef({
    required String chatId,
    required String processId,
  }) = _HermesProcessRef;

  factory HermesProcessRef.fromJson(Map<String, dynamic> json) =>
      _$HermesProcessRefFromJson(json);
}

/// What `hermes.work.kill` did.
enum HermesProcessKillStatus { killed, alreadyExited, notFound, failed }

/// Reply to `hermes.work.kill`.
@freezed
abstract class HermesProcessKill with _$HermesProcessKill {
  const factory HermesProcessKill({
    required HermesProcessKillStatus status,

    /// The end of what the process printed.
    String? output,

    /// Hermes' own words for a failure.
    String? error,
  }) = _HermesProcessKill;

  factory HermesProcessKill.fromJson(Map<String, dynamic> json) =>
      _$HermesProcessKillFromJson(json);
}

// ---------------------------------------------------------------------------
// hermes.context.* -- a Hermes chat's context window and usage
// ---------------------------------------------------------------------------

/// Params for `hermes.context.get`.
@freezed
abstract class HermesContextRef with _$HermesContextRef {
  const factory HermesContextRef({required String chatId}) = _HermesContextRef;

  factory HermesContextRef.fromJson(Map<String, dynamic> json) =>
      _$HermesContextRefFromJson(json);
}

/// Reply to `hermes.context.get`: a Hermes chat's context window, token
/// totals and plan allowances. A Desktop Gateway reports all of it; an API
/// server only the session's totals.
@freezed
abstract class HermesContextReportDto with _$HermesContextReportDto {
  const factory HermesContextReportDto({
    String? model,

    /// Tokens in the context window now, and its size.
    int? contextUsed,
    int? contextMax,

    /// The fill is Hermes' estimate, not a measured count.
    @Default(false) bool contextEstimated,

    /// Hermes' estimate of the next request's size.
    int? estimatedTotal,

    /// What fills the window, as Hermes lists it.
    @Default(<HermesContextCategoryDto>[])
    List<HermesContextCategoryDto> categories,
    @Default(HermesTokenTotalsDto()) HermesTokenTotalsDto totals,

    /// The plan's allowances (day, week, month…).
    @Default(<HermesPlanGaugeDto>[]) List<HermesPlanGaugeDto> planGauges,

    /// Hermes' own lines about credits, shown as written.
    @Default(<String>[]) List<String> creditsLines,
    HermesUsageBarsDto? usageBars,
    HermesProviderPlanDto? providerPlan,

    /// Compact Now is offered.
    @Default(false) bool canCompact,

    /// A compaction is still running on the server.
    @Default(false) bool compacting,
  }) = _HermesContextReportDto;

  factory HermesContextReportDto.fromJson(Map<String, dynamic> json) =>
      _$HermesContextReportDtoFromJson(json);
}

/// One part of what fills the context window.
@freezed
abstract class HermesContextCategoryDto with _$HermesContextCategoryDto {
  const factory HermesContextCategoryDto({
    /// `system_prompt`, `tool_definitions`, `subagent_definitions`,
    /// `conversation`, or another server id.
    required String id,

    /// Hermes' name for it, for an id the window has no words for.
    @Default('') String label,
    required int tokens,
  }) = _HermesContextCategoryDto;

  factory HermesContextCategoryDto.fromJson(Map<String, dynamic> json) =>
      _$HermesContextCategoryDtoFromJson(json);
}

/// A chat's token counters so far.
@freezed
abstract class HermesTokenTotalsDto with _$HermesTokenTotalsDto {
  const factory HermesTokenTotalsDto({
    int? input,
    int? output,
    int? reasoning,
    int? cacheRead,
    int? cacheWrite,
    int? cacheHitPercent,
    int? total,
    int? calls,
    int? compressions,

    /// In US dollars.
    double? costUsd,
    @Default(false) bool costEstimated,
  }) = _HermesTokenTotalsDto;

  factory HermesTokenTotalsDto.fromJson(Map<String, dynamic> json) =>
      _$HermesTokenTotalsDtoFromJson(json);
}

/// One plan allowance.
@freezed
abstract class HermesPlanGaugeDto with _$HermesPlanGaugeDto {
  const factory HermesPlanGaugeDto({
    /// `day`, `week`, `month`, `top_tier`, or another server id.
    required String id,

    /// Hermes' words, for an id the window has none for.
    String? title,

    /// 0 (untouched) to 1 (used up).
    required double usedFraction,

    /// In milliseconds since the epoch.
    int? resetsAtMs,
  }) = _HermesPlanGaugeDto;

  factory HermesPlanGaugeDto.fromJson(Map<String, dynamic> json) =>
      _$HermesPlanGaugeDtoFromJson(json);
}

/// One of Hermes' dollar bars: a plan or a top-up balance.
@freezed
abstract class HermesUsageBarDto with _$HermesUsageBarDto {
  const factory HermesUsageBarDto({
    /// `plan` or `topup`.
    required String kind,

    /// 0 to 1.
    required double fill,

    /// Amounts Hermes formats itself (`$4.20`).
    String? remaining,
    String? total,
    String? spent,
    int? usedPercent,
  }) = _HermesUsageBarDto;

  factory HermesUsageBarDto.fromJson(Map<String, dynamic> json) =>
      _$HermesUsageBarDtoFromJson(json);
}

/// The account's subscription and top-up balance.
@freezed
abstract class HermesUsageBarsDto with _$HermesUsageBarsDto {
  const factory HermesUsageBarsDto({
    String? planName,

    /// When the plan renews, in Hermes' words.
    String? renews,
    HermesUsageBarDto? plan,
    HermesUsageBarDto? topup,
    String? totalSpendable,
  }) = _HermesUsageBarsDto;

  factory HermesUsageBarsDto.fromJson(Map<String, dynamic> json) =>
      _$HermesUsageBarsDtoFromJson(json);
}

/// What the chat's provider says about its plan and limits.
@freezed
abstract class HermesProviderPlanDto with _$HermesProviderPlanDto {
  const factory HermesProviderPlanDto({
    String? provider,
    String? planName,
    @Default(<HermesPlanGaugeDto>[]) List<HermesPlanGaugeDto> gauges,
    @Default(false) bool rateLimited,

    /// In milliseconds since the epoch.
    int? rateLimitedUntilMs,

    /// How much the chat's model draws on the plan: `free`, `low`,
    /// `medium` or `top_tier`.
    String? usageLevel,
  }) = _HermesProviderPlanDto;

  factory HermesProviderPlanDto.fromJson(Map<String, dynamic> json) =>
      _$HermesProviderPlanDtoFromJson(json);
}

/// Params for `hermes.context.compact`: summarize the chat's older
/// messages on the server.
@freezed
abstract class HermesCompact with _$HermesCompact {
  const factory HermesCompact({
    required String chatId,

    /// What the summary should keep in view.
    String? focus,
  }) = _HermesCompact;

  factory HermesCompact.fromJson(Map<String, dynamic> json) =>
      _$HermesCompactFromJson(json);
}

/// How a compaction ended.
enum HermesCompactOutcome {
  /// Older messages were summarized.
  compacted,

  /// Nothing could be removed (a short chat).
  unchanged,

  /// A summary would have been longer than what it replaces.
  refused,

  /// The summary failed; no messages were removed.
  aborted,

  /// Still running on the server.
  pending,

  /// Another compaction holds the chat.
  busy,
}

/// Reply to `hermes.context.compact`.
@freezed
abstract class HermesCompactResultDto with _$HermesCompactResultDto {
  const factory HermesCompactResultDto({
    required HermesCompactOutcome outcome,
    int? beforeTokens,
    int? afterTokens,
    int? beforeMessages,
    int? afterMessages,
  }) = _HermesCompactResultDto;

  factory HermesCompactResultDto.fromJson(Map<String, dynamic> json) =>
      _$HermesCompactResultDtoFromJson(json);
}

// ---------------------------------------------------------------------------
// hermes.decisions.* -- answering what a Hermes agent asks
// ---------------------------------------------------------------------------

/// Params for `hermes.decisions.answer`: the answer to a `ui.request` of
/// kind `hermesClarify`, `hermesSudo` or `hermesSecret` (or a
/// `hermesDecision` set-up card).
///
/// Unlike `ui.respond`, it waits for Hermes to take the answer: the card
/// stays up (and says so) when it did not arrive. A password or secret in
/// [value] is passed on and never logged or kept.
@freezed
abstract class HermesDecisionAnswer with _$HermesDecisionAnswer {
  const factory HermesDecisionAnswer({
    required String requestId,

    /// A form's answers, one per question still open.
    @Default(<HermesClarifyAnswer>[]) List<HermesClarifyAnswer> answers,

    /// Any other question's answer: the password, the secret, the reply,
    /// or a set-up card's `approve` or `decline`.
    String? value,
  }) = _HermesDecisionAnswer;

  factory HermesDecisionAnswer.fromJson(Map<String, dynamic> json) =>
      _$HermesDecisionAnswerFromJson(json);
}

/// One question's answer in a clarify form.
@freezed
abstract class HermesClarifyAnswer with _$HermesClarifyAnswer {
  const factory HermesClarifyAnswer({
    required String questionId,

    /// The choice picked or the words typed; a multi-select question's
    /// several answers as a JSON array string. Null skips the question.
    String? answer,
  }) = _HermesClarifyAnswer;

  factory HermesClarifyAnswer.fromJson(Map<String, dynamic> json) =>
      _$HermesClarifyAnswerFromJson(json);
}

/// How answering a Hermes question went.
enum HermesDecisionStatus {
  /// Hermes took it; the card closes (`ui.settled` follows).
  answered,

  /// Hermes had already settled it (answered elsewhere, or it expired);
  /// the card closes and the answer was not sent.
  settled,

  /// It did not arrive: the card stays, to be answered again.
  failed,
}

/// Reply to `hermes.decisions.answer`.
@freezed
abstract class HermesDecisionResult with _$HermesDecisionResult {
  const factory HermesDecisionResult({required HermesDecisionStatus status}) =
      _HermesDecisionResult;

  factory HermesDecisionResult.fromJson(Map<String, dynamic> json) =>
      _$HermesDecisionResultFromJson(json);
}

// ---------------------------------------------------------------------------
// Message cards: the files a reply changed, a classified failure
// ---------------------------------------------------------------------------

/// One file a Hermes reply's tools changed, with its lines.
@freezed
abstract class ChangedFileDto with _$ChangedFileDto {
  const factory ChangedFileDto({
    /// Its path as Hermes sent it (`a/` and `b/` taken off); empty when
    /// Hermes did not name it. A window lists a file inside the chat's
    /// working directory (`HermesWork.workingDirectory`) by its path from
    /// there.
    @Default('') String path,
    @Default(0) int added,
    @Default(0) int removed,
    @Default(<DiffLineDto>[]) List<DiffLineDto> lines,
  }) = _ChangedFileDto;

  factory ChangedFileDto.fromJson(Map<String, dynamic> json) =>
      _$ChangedFileDtoFromJson(json);
}

/// What one line of a diff is.
enum DiffLineKind {
  context,
  added,
  removed,

  /// A hunk header (`@@ -1,3 +1,4 @@`).
  hunk,

  /// Hermes' own remark (how many lines it left out).
  note,
}

/// One line of a changed file's diff.
@freezed
abstract class DiffLineDto with _$DiffLineDto {
  const factory DiffLineDto({
    required DiffLineKind kind,
    @Default('') String text,

    /// Line numbers from the hunk header, when Hermes sent one.
    int? oldNumber,
    int? newNumber,
  }) = _DiffLineDto;

  factory DiffLineDto.fromJson(Map<String, dynamic> json) =>
      _$DiffLineDtoFromJson(json);
}

/// A failed Hermes turn, as Hermes classified it: what broke, whether the
/// chat is stuck, when a limit resets, and what helps. On an `error` block
/// (`MessageBlockDto.hermesError`).
@freezed
abstract class HermesErrorDto with _$HermesErrorDto {
  const factory HermesErrorDto({
    /// `provider`, `endpoint`, `connection`, `auth`, `billing`,
    /// `usageLimit`, `freeTier`, `rateLimit`, `contextOverflow`, `model`,
    /// `policy`, `truncated`, `badReply`, `workspace`, `session`, `busy`,
    /// `gateway`, `disk` or `unknown`.
    required String kind,

    /// The chat is stuck until the cause is fixed (else it can go on).
    @Default(false) bool blocking,

    /// Hermes' sentence about it, when it wrote one.
    String? message,

    /// The provider and model it happened on.
    String? provider,
    String? model,

    /// When the limit resets, in milliseconds since the epoch.
    int? resetsAtMs,

    /// What the reply wrote before it failed is kept.
    @Default(false) bool partial,

    /// The fixes this chat can perform, best first: `retry`,
    /// `continueReply`, `compact`, `switchModel`, `openProviderSettings`,
    /// `openBilling`, `newChat`. A card offers the first.
    @Default(<String>[]) List<String> actions,

    /// For `switchModel`: the model to switch to.
    HermesModelChoiceDto? switchTo,

    /// For `openBilling` and `openProviderSettings`.
    String? billingUrl,
    String? providerSettingsUrl,
  }) = _HermesErrorDto;

  factory HermesErrorDto.fromJson(Map<String, dynamic> json) =>
      _$HermesErrorDtoFromJson(json);
}

/// A model an error card offers to switch to.
@freezed
abstract class HermesModelChoiceDto with _$HermesModelChoiceDto {
  const factory HermesModelChoiceDto({
    /// The model's id in `models.list` (a Hermes model).
    required String modelId,
    required String label,
  }) = _HermesModelChoiceDto;

  factory HermesModelChoiceDto.fromJson(Map<String, dynamic> json) =>
      _$HermesModelChoiceDtoFromJson(json);
}
