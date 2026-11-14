import 'package:freezed_annotation/freezed_annotation.dart';

import 'models.dart';

part 'automations.freezed.dart';
part 'automations.g.dart';

/// A scheduled task's schedule, as the editor's controls hold it.
///
/// Times are wall clocks with no zone: the server reads them in the
/// account's Open WebUI time zone.
@freezed
abstract class AutomationScheduleDto with _$AutomationScheduleDto {
  const factory AutomationScheduleDto({
    /// `once`, `daily`, `weekly`, or `custom` for a rule the controls do
    /// not write (kept exactly as stored in [rrule]).
    required String kind,

    /// A one-time run's day.
    @Default(0) int year,
    @Default(0) int month,
    @Default(0) int day,
    @Default(0) int hour,
    @Default(0) int minute,

    /// A weekly run's days, `MO` to `SU`, Monday first.
    @Default(<String>[]) List<String> days,

    /// The rule the server stores.
    @Default('') String rrule,
  }) = _AutomationScheduleDto;

  factory AutomationScheduleDto.fromJson(Map<String, dynamic> json) =>
      _$AutomationScheduleDtoFromJson(json);
}

/// One scheduled task, as its list row shows it.
@freezed
abstract class AutomationSummary with _$AutomationSummary {
  const factory AutomationSummary({
    required String id,
    @Default('') String name,
    @Default(true) bool active,
    required AutomationScheduleDto schedule,

    /// The next run of an active task, in milliseconds since the epoch.
    int? nextRunAt,

    /// The last run, in milliseconds since the epoch.
    int? lastRunAt,
    @Default(false) bool lastRunFailed,

    /// The coding agent it runs, when its model is one (a task made on the
    /// web with an agent): the list names it instead of a model.
    TerminalAgentDto? agent,
  }) = _AutomationSummary;

  factory AutomationSummary.fromJson(Map<String, dynamic> json) =>
      _$AutomationSummaryFromJson(json);
}

/// Reply to `automations.list` and the calls that change the list.
@freezed
abstract class AutomationList with _$AutomationList {
  const factory AutomationList({
    /// The server and account allow scheduled tasks.
    @Default(false) bool available,

    /// Nothing could be read: `unavailable`, `accountChanged` or `failed`.
    String? failure,

    /// A change went through but reading the list back failed.
    @Default(false) bool stale,
    @Default('') String query,

    /// `all`, `active` or `paused`.
    @Default('all') String status,
    @Default(<AutomationSummary>[]) List<AutomationSummary> items,

    /// Matches across every page.
    @Default(0) int total,
    @Default(false) bool hasMore,
  }) = _AutomationList;

  factory AutomationList.fromJson(Map<String, dynamic> json) =>
      _$AutomationListFromJson(json);
}

/// Params for `automations.list`. A changed search or status starts again
/// from the first page; nothing set answers with the list as it stands.
@freezed
abstract class AutomationQuery with _$AutomationQuery {
  const factory AutomationQuery({
    String? query,

    /// `all`, `active` or `paused`.
    String? status,
    @Default(false) bool refresh,
  }) = _AutomationQuery;

  factory AutomationQuery.fromJson(Map<String, dynamic> json) =>
      _$AutomationQueryFromJson(json);
}

/// Params naming one task.
@freezed
abstract class AutomationRef with _$AutomationRef {
  const factory AutomationRef({required String id}) = _AutomationRef;

  factory AutomationRef.fromJson(Map<String, dynamic> json) =>
      _$AutomationRefFromJson(json);
}

/// One entry of a task's history.
@freezed
abstract class AutomationRunDto with _$AutomationRunDto {
  const factory AutomationRunDto({
    required String id,
    @Default('') String status,
    @Default(false) bool succeeded,
    String? error,

    /// When it finished, in milliseconds since the epoch.
    int? createdAt,
    String? resultChatId,
    String? resultChannelId,
  }) = _AutomationRunDto;

  factory AutomationRunDto.fromJson(Map<String, dynamic> json) =>
      _$AutomationRunDtoFromJson(json);
}

/// Reply to `automations.get` and `automations.setActive`.
@freezed
abstract class AutomationDetail with _$AutomationDetail {
  const factory AutomationDetail({
    required AutomationSummary summary,
    @Default('') String prompt,
    @Default('') String modelId,

    /// The model's name, when the account's models list it.
    String? modelName,

    /// `chat` or `channel`.
    @Default('chat') String target,
    String? channelId,
    String? channelName,
    String? folderId,
    String? folderName,

    /// A terminal is attached; edits keep it.
    @Default(false) bool terminal,

    /// The server terminal it runs with, by id, and its name when the
    /// server lists it.
    String? terminalId,
    String? terminalName,

    /// The folder on [terminalId] it starts in; null for the terminal's own.
    String? workingDirectory,

    /// The coding agent it runs, when [modelId] is one's.
    TerminalAgentDto? agent,

    /// The server's next runs, in milliseconds since the epoch (empty for a
    /// paused task).
    @Default(<int>[]) List<int> nextRuns,
  }) = _AutomationDetail;

  factory AutomationDetail.fromJson(Map<String, dynamic> json) =>
      _$AutomationDetailFromJson(json);
}

/// Params for `automations.runs`: a page of history, newest first.
@freezed
abstract class AutomationRunsQuery with _$AutomationRunsQuery {
  const factory AutomationRunsQuery({
    required String id,
    @Default(0) int skip,
  }) = _AutomationRunsQuery;

  factory AutomationRunsQuery.fromJson(Map<String, dynamic> json) =>
      _$AutomationRunsQueryFromJson(json);
}

/// Reply to `automations.runs`.
@freezed
abstract class AutomationRuns with _$AutomationRuns {
  const factory AutomationRuns({
    @Default(<AutomationRunDto>[]) List<AutomationRunDto> items,
    @Default(false) bool hasMore,
  }) = _AutomationRuns;

  factory AutomationRuns.fromJson(Map<String, dynamic> json) =>
      _$AutomationRunsFromJson(json);
}

/// Params for `automations.setActive`.
@freezed
abstract class AutomationToggle with _$AutomationToggle {
  const factory AutomationToggle({required String id, required bool active}) =
      _AutomationToggle;

  factory AutomationToggle.fromJson(Map<String, dynamic> json) =>
      _$AutomationToggleFromJson(json);
}

/// Where a Run Now stands (`automations.run`, `automations.runState` and the
/// `automations.runProgress` event).
@freezed
abstract class AutomationRunProgress with _$AutomationRunProgress {
  const factory AutomationRunProgress({
    required String id,

    /// `idle`, `requesting`, `waiting`, `finished`, `failed` or `timedOut`.
    @Default('idle') String phase,

    /// The run it produced, once recorded.
    AutomationRunDto? run,

    /// Why the request was refused, when it was: the server's own words,
    /// or `accountChanged` / `unavailable`.
    String? failure,
  }) = _AutomationRunProgress;

  factory AutomationRunProgress.fromJson(Map<String, dynamic> json) =>
      _$AutomationRunProgressFromJson(json);
}

/// What the task editor holds.
@freezed
abstract class AutomationFields with _$AutomationFields {
  const factory AutomationFields({
    @Default('') String name,
    @Default('') String prompt,
    @Default('') String modelId,
    @Default(true) bool active,
    required AutomationScheduleDto schedule,

    /// `chat` or `channel`.
    @Default('chat') String target,
    String? channelId,

    /// A chat result's folder, or null for none.
    String? folderId,

    /// The server terminal the task runs with (its tools, and its agents
    /// when [modelId] is a coding agent's), or null for none. Moving to
    /// another terminal drops an agent of the old one and its working
    /// folder (`automations.checkDraft` answers with that).
    String? terminalId,

    /// The folder on [terminalId] the task starts in, or null for the
    /// terminal's own.
    String? workingDirectory,
  }) = _AutomationFields;

  factory AutomationFields.fromJson(Map<String, dynamic> json) =>
      _$AutomationFieldsFromJson(json);
}

/// A model, channel or folder the editor offers.
@freezed
abstract class AutomationOption with _$AutomationOption {
  const factory AutomationOption({
    required String id,
    @Default('') String name,

    /// A second line: the terminal a coding agent runs on.
    String? detail,

    /// The model is a coding agent (it posts only to a new chat).
    @Default(false) bool agent,
  }) = _AutomationOption;

  factory AutomationOption.fromJson(Map<String, dynamic> json) =>
      _$AutomationOptionFromJson(json);
}

/// Params for `automations.editor`: a new task, or the task [id].
@freezed
abstract class AutomationEditorOpen with _$AutomationEditorOpen {
  const factory AutomationEditorOpen({String? id}) = _AutomationEditorOpen;

  factory AutomationEditorOpen.fromJson(Map<String, dynamic> json) =>
      _$AutomationEditorOpenFromJson(json);
}

/// Reply to `automations.editor`: the draft, held by the daemon for the
/// account it was opened for under [token], and what it can pick.
@freezed
abstract class AutomationEditor with _$AutomationEditor {
  const factory AutomationEditor({
    required String token,
    @Default(true) bool isNew,
    required AutomationFields fields,

    /// Null while a list has not loaded: the server decides then.
    List<AutomationOption>? models,
    List<AutomationOption>? channels,
    List<AutomationOption>? folders,

    /// A terminal is attached; edits keep it.
    @Default(false) bool terminal,

    /// The server's terminals a task may run with (`automations.terminals`
    /// answers again for another terminal or folder); null when they could
    /// not be read: the task's own then stays as it is.
    List<AutomationOption>? terminals,

    /// The coding agents [AutomationFields.terminalId] offers, already in
    /// [models]; see [AutomationTerminals].
    @Default(false) bool agentsUnknown,

    /// The task's coding agent named as the picker names it ("Codex ·
    /// gpt-5.1"), when its model is one: what the model row shows while the
    /// terminal does not (or no longer) lists it.
    String? agentName,
  }) = _AutomationEditor;

  factory AutomationEditor.fromJson(Map<String, dynamic> json) =>
      _$AutomationEditorFromJson(json);
}

/// Reply to `automations.terminals`: the server terminals a task may run
/// with, and the models the editor offers with the draft's terminal and
/// working folder: the account's models, then that terminal's coding agents
/// (Open WebUI 0.13.3 and later), each with [AutomationOption.agent] set.
@freezed
abstract class AutomationTerminals with _$AutomationTerminals {
  const factory AutomationTerminals({
    /// Null when the server's terminals could not be read.
    List<AutomationOption>? terminals,

    /// Null while the account's models have not loaded.
    List<AutomationOption>? models,

    /// The terminal could not be asked for its agents (or the result posts
    /// to a channel): whether the task's agent is still offered is unknown,
    /// so it is not refused for that.
    @Default(false) bool agentsUnknown,
  }) = _AutomationTerminals;

  factory AutomationTerminals.fromJson(Map<String, dynamic> json) =>
      _$AutomationTerminalsFromJson(json);
}

/// Params for `automations.checkDraft` and `automations.save`.
@freezed
abstract class AutomationDraftEdit with _$AutomationDraftEdit {
  const factory AutomationDraftEdit({
    required String token,
    required AutomationFields fields,

    /// The schedule's kind was just chosen (`once`, `daily`, `weekly`):
    /// it starts from the current schedule's time (`checkDraft` only).
    String? chooseKind,
  }) = _AutomationDraftEdit;

  factory AutomationDraftEdit.fromJson(Map<String, dynamic> json) =>
      _$AutomationDraftEditFromJson(json);
}

/// Reply to `automations.checkDraft` and `automations.save`.
@freezed
abstract class AutomationDraftState with _$AutomationDraftState {
  const factory AutomationDraftState({
    /// The fields with the schedule settled: a `custom` rule that the
    /// controls can write reads back as their kind, and typed controls
    /// carry their rule.
    required AutomationFields fields,

    /// What stops it being saved: `nameRequired`, `promptRequired`,
    /// `modelRequired`, `modelUnavailable`, `channelRequired`,
    /// `channelUnavailable`, `channelNoWrite`, `folderUnavailable`,
    /// `scheduleIncomplete`, `terminalRequired` (a coding agent needs its
    /// terminal), `agentNeedsChat` (an agent posts only to a new chat).
    @Default(<String>[]) List<String> issues,
    @Default(false) bool changed,

    /// `automations.save` went through; [id] is the task.
    @Default(false) bool saved,
    String? id,

    /// The server refused the save, in its own words when it gave some.
    String? failure,
  }) = _AutomationDraftState;

  factory AutomationDraftState.fromJson(Map<String, dynamic> json) =>
      _$AutomationDraftStateFromJson(json);
}
