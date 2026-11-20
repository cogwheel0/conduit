import 'package:freezed_annotation/freezed_annotation.dart';

import 'hermes_admin.dart';
import 'hermes_rooms.dart';

part 'hermes.freezed.dart';
part 'hermes.g.dart';

/// The Hermes Agent connection as settings show it. Secrets are never
/// sent back, only whether they are set.
@freezed
abstract class HermesSettings with _$HermesSettings {
  const factory HermesSettings({
    @Default(false) bool enabled,
    @Default('') String baseUrl,

    /// `responses` (the API server, with a key) or `desktop` (the
    /// desktop gateway).
    @Default('responses') String mode,
    @Default(false) bool hasApiKey,

    /// The long-term memory key; made on first use when unset.
    @Default(false) bool hasSessionKey,
    @Default('default') String desktopProfile,

    /// `legacyToken`, `nativePkce` or `dashboardCookie`.
    @Default('legacyToken') String desktopAuthKind,
    @Default(false) bool desktopSignedIn,
    @Default(false) bool allowSelfSignedCertificates,

    /// Whether it is on and has what it needs to be used.
    @Default(false) bool usable,
  }) = _HermesSettings;

  factory HermesSettings.fromJson(Map<String, dynamic> json) =>
      _$HermesSettingsFromJson(json);
}

/// Params for `hermes.saveSettings` and `hermes.test`. A null secret keeps
/// the one stored; an empty one clears it.
@freezed
abstract class HermesSettingsEdit with _$HermesSettingsEdit {
  const factory HermesSettingsEdit({
    @Default(true) bool enabled,
    required String baseUrl,
    @Default('responses') String mode,
    String? apiKey,
    String? sessionKey,
    @Default('default') String desktopProfile,
    @Default('legacyToken') String desktopAuthKind,

    /// A Desktop Gateway's legacy session token (`desktopAuthKind`
    /// `legacyToken`, and what a loopback gateway asks for whatever the
    /// kind). As the other secrets: null keeps it, empty clears it.
    String? legacyToken,
    @Default(false) bool allowSelfSignedCertificates,

    /// Saved by onboarding's Hermes choice: Hermes becomes the backend the
    /// app is used through, as the phone's chooser makes it on "Finish
    /// setup" (saved, turned on and chosen together, or none of them).
    /// Saved from settings, Hermes joins the backend already in use.
    @Default(false) bool onboarding,
  }) = _HermesSettingsEdit;

  factory HermesSettingsEdit.fromJson(Map<String, dynamic> json) =>
      _$HermesSettingsEditFromJson(json);
}

/// Reply to `hermes.test`.
@freezed
abstract class HermesTestResult with _$HermesTestResult {
  const factory HermesTestResult({
    @Default(false) bool ok,

    /// A code the window words: `unreachable`, `unauthorized`, `invalid`.
    String? reason,
  }) = _HermesTestResult;

  factory HermesTestResult.fromJson(Map<String, dynamic> json) =>
      _$HermesTestResultFromJson(json);
}

/// What the connected Hermes server can do.
@freezed
abstract class HermesCapabilitiesDto with _$HermesCapabilitiesDto {
  const factory HermesCapabilitiesDto({
    @Default(false) bool runApproval,
    @Default(false) bool skills,
    @Default(false) bool toolsets,
    @Default(false) bool jobs,
    @Default(false) bool jobsAdmin,
    @Default(false) bool sessions,
    @Default(false) bool inputImages,
    @Default(false) bool inputFiles,
  }) = _HermesCapabilitiesDto;

  factory HermesCapabilitiesDto.fromJson(Map<String, dynamic> json) =>
      _$HermesCapabilitiesDtoFromJson(json);
}

/// Reply to `hermes.status`.
@freezed
abstract class HermesStatus with _$HermesStatus {
  const factory HermesStatus({
    @Default(false) bool configured,
    @Default(false) bool reachable,
    @Default(HermesCapabilitiesDto()) HermesCapabilitiesDto capabilities,

    /// The server's detailed health, as it reports it: sessions, agents,
    /// resources.
    @Default(<String, dynamic>{}) Map<String, dynamic> details,

    /// The Hermes connection this answer is for: a new value whenever the
    /// connection changes (see [HermesChanged.connection]).
    String? connection,
  }) = _HermesStatus;

  factory HermesStatus.fromJson(Map<String, dynamic> json) =>
      _$HermesStatusFromJson(json);
}

/// `hermes.changed`: the connection, its settings or what it lists changed.
@freezed
abstract class HermesChanged with _$HermesChanged {
  const factory HermesChanged({
    /// The Hermes connection in use now, as the daemon names it: an opaque
    /// value, new whenever the connection changes, never the same across two
    /// daemon runs. A request sent with another value (`connection` on the
    /// Hermes requests that take it) is refused with `sessionExpired`, and
    /// an answer or event carrying another value belongs to the last
    /// connection.
    String? connection,
  }) = _HermesChanged;

  factory HermesChanged.fromJson(Map<String, dynamic> json) =>
      _$HermesChangedFromJson(json);
}

/// A Hermes session, as the sidebar lists it. Opened as a chat with
/// [chatId].
@freezed
abstract class HermesSessionDto with _$HermesSessionDto {
  const factory HermesSessionDto({
    required String id,
    required String chatId,
    @Default('') String title,
    String? preview,
    int? updatedAtMs,

    /// Kept at the top of the list, however old.
    @Default(false) bool pinned,

    /// Set aside in the list's Archived row.
    @Default(false) bool archived,

    /// Hidden from every list: only Hidden Chats reaches it.
    @Default(false) bool hidden,

    /// The Hermes app that started it, as Hermes names it (`api_server`,
    /// `cli`, `telegram`, ...), when Hermes says.
    String? source,

    /// A reply is being written in it now.
    @Default(false) bool running,
  }) = _HermesSessionDto;

  factory HermesSessionDto.fromJson(Map<String, dynamic> json) =>
      _$HermesSessionDtoFromJson(json);
}

/// Reply to `hermes.sessions`.
@freezed
abstract class HermesSessions with _$HermesSessions {
  const factory HermesSessions({
    /// Pinned first, then the rest, newest first.
    @Default(<HermesSessionDto>[]) List<HermesSessionDto> sessions,

    /// The archived sessions, newest first.
    @Default(<HermesSessionDto>[]) List<HermesSessionDto> archived,

    /// The archived sessions could not be read: the Archived row says so,
    /// with Try Again. The conversations are listed all the same.
    @Default(false) bool archivedFailed,

    /// How many scheduled agents' runs the lists leave out while Show
    /// Scheduled Runs is off (pinned ones are listed): the list says so,
    /// with Show.
    @Default(0) int hiddenScheduledRuns,
  }) = _HermesSessions;

  factory HermesSessions.fromJson(Map<String, dynamic> json) =>
      _$HermesSessionsFromJson(json);
}

/// Params naming a Hermes session, job, or anything else by id.
@freezed
abstract class HermesRef with _$HermesRef {
  const factory HermesRef({required String id}) = _HermesRef;

  factory HermesRef.fromJson(Map<String, dynamic> json) =>
      _$HermesRefFromJson(json);
}

/// Params naming a scheduled job by id, for an action on the connection
/// in use (`hermes.runJob`, `hermes.deleteJob`, `hermes.jobs.stop`,
/// `hermes.jobs.runs`).
@freezed
abstract class HermesJobRef with _$HermesJobRef {
  const factory HermesJobRef({
    required String id,

    /// The Hermes connection the request was made under
    /// (`HermesChanged.connection`): refused once another is in use. Null
    /// from an older window, not checked.
    String? connection,
  }) = _HermesJobRef;

  factory HermesJobRef.fromJson(Map<String, dynamic> json) =>
      _$HermesJobRefFromJson(json);
}

/// Params of `hermes.signIn`: the connection the sign-in is for.
@freezed
abstract class HermesSignInRequest with _$HermesSignInRequest {
  const factory HermesSignInRequest({
    /// The Hermes connection the request was made under
    /// (`HermesChanged.connection`, or the one an activation answered
    /// with): refused once another is in use. Null from an older window,
    /// not checked.
    String? connection,
  }) = _HermesSignInRequest;

  factory HermesSignInRequest.fromJson(Map<String, dynamic> json) =>
      _$HermesSignInRequestFromJson(json);
}

/// Params for `hermes.renameSession`.
@freezed
abstract class HermesRename with _$HermesRename {
  const factory HermesRename({required String id, required String title}) =
      _HermesRename;

  factory HermesRename.fromJson(Map<String, dynamic> json) =>
      _$HermesRenameFromJson(json);
}

/// Params for `hermes.sessions.update`: the flags to change on session
/// [id]; a null one stays as it is. Archiving or hiding a pinned session
/// unpins it, as on a phone.
@freezed
abstract class HermesSessionUpdate with _$HermesSessionUpdate {
  const factory HermesSessionUpdate({
    required String id,
    bool? pinned,
    bool? archived,
    bool? hidden,
  }) = _HermesSessionUpdate;

  factory HermesSessionUpdate.fromJson(Map<String, dynamic> json) =>
      _$HermesSessionUpdateFromJson(json);
}

/// Params for `hermes.sessions.continue`: a read-only session's chat
/// [chatId], continued in a session this app owns.
@freezed
abstract class HermesContinue with _$HermesContinue {
  const factory HermesContinue({
    required String chatId,

    /// Continue in a Copy: a new session with the chat's messages, which
    /// leaves the other app's chat alone. Otherwise Continue Here: Hermes's
    /// fork, after which the other app starts a new chat on its next
    /// message.
    @Default(false) bool copy,
  }) = _HermesContinue;

  factory HermesContinue.fromJson(Map<String, dynamic> json) =>
      _$HermesContinueFromJson(json);
}

/// Params for `hermes.history.branch`: a new session with Hermes chat
/// [chatId] up to the end of reply [messageId]'s turn.
@freezed
abstract class HermesBranch with _$HermesBranch {
  const factory HermesBranch({
    required String chatId,
    required String messageId,
  }) = _HermesBranch;

  factory HermesBranch.fromJson(Map<String, dynamic> json) =>
      _$HermesBranchFromJson(json);
}

/// What a Hermes session's chat is, beside its messages
/// (`ChatDetail.hermes`).
@freezed
abstract class HermesChatDto with _$HermesChatDto {
  const factory HermesChatDto({
    required String sessionId,

    /// Another Hermes app owns the session and Hermes refuses this app's
    /// turns in it: it is read here, and continued in a session of this
    /// app's (`hermes.sessions.continue`).
    @Default(false) bool readOnly,

    /// The app that owns it, by name ("Hermes CLI", "Telegram"), or empty
    /// when Hermes did not say.
    @Default('') String owner,

    /// The bot whose Bot Chat it is: the chat is titled with the bot, and
    /// its replies carry the bot's name and face.
    HermesBotDto? bot,
  }) = _HermesChatDto;

  factory HermesChatDto.fromJson(Map<String, dynamic> json) =>
      _$HermesChatDtoFromJson(json);
}

/// The cadences core reads in a Hermes job's cron schedule (the core's
/// `HermesCadenceKind`).
enum HermesCadenceKind {
  none,
  everyMinute,
  everyMinutes,
  everyHour,
  everyHours,
  daily,
  weekdays,
  weekends,
  weekly,
  monthly,
}

/// A Hermes job's schedule, read (the core's `HermesCadence`): what
/// [HermesJobDto.scheduleText] says in English, for the window to word in
/// its own language.
@freezed
abstract class HermesCadenceDto with _$HermesCadenceDto {
  const factory HermesCadenceDto({
    required HermesCadenceKind kind,

    /// The step of `everyMinutes` and `everyHours`.
    int? every,

    /// The time's hour, 0–23.
    int? hour,

    /// The time's minute, 0–59; for the hourly kinds, the minute past the
    /// hour.
    int? minute,

    /// `weekly`'s day: 0 is Sunday, 6 Saturday.
    int? weekday,

    /// `monthly`'s day of the month, 1–31.
    int? day,
  }) = _HermesCadenceDto;

  factory HermesCadenceDto.fromJson(Map<String, dynamic> json) =>
      _$HermesCadenceDtoFromJson(json);
}

/// A scheduled agent.
@freezed
abstract class HermesJobDto with _$HermesJobDto {
  const factory HermesJobDto({
    required String id,
    String? name,
    @Default('') String prompt,

    /// Cron, or Hermes's own words for it (`every 1h`).
    @Default('') String schedule,

    /// The schedule in words, when it could be read.
    String? scheduleText,

    /// [scheduleText] as data, when core read the schedule: the window
    /// words it in its own language (the English is the fallback).
    HermesCadenceDto? cadence,
    @Default(true) bool enabled,
    String? lastStatus,
    String? lastError,
    int? lastRunAtMs,
    int? nextRunAtMs,

    /// Hermes's own word for where the job is (`scheduled`, `paused`,
    /// `completed`), when it says.
    String? state,

    /// Where each run goes, in the stored order (a Desktop Gateway's; an
    /// API server's runs are saved in Hermes).
    @Default(<HermesDeliveryTargetDto>[])
    List<HermesDeliveryTargetDto> deliver,

    /// Why the last run's delivery failed, when it did.
    String? lastDeliveryError,

    /// Runs missed while Hermes was not running: `default` (Hermes's
    /// policy), `runOnce` or `skip`.
    @Default('default') String catchUp,

    /// A run is in flight, or a Run Now is waiting for its run.
    @Default(false) bool running,

    /// A Stop was sent and the run has not ended yet.
    @Default(false) bool stopping,

    /// The last run was stopped: why (empty when Hermes gave no reason).
    /// Null when it was not stopped.
    String? lastCancelReason,

    /// Where runs go could be read: false when the stored routes could not
    /// be (then [deliver] is empty and no edit may replace them).
    @Default(true) bool deliveryKnown,
  }) = _HermesJobDto;

  factory HermesJobDto.fromJson(Map<String, dynamic> json) =>
      _$HermesJobDtoFromJson(json);
}

/// Reply to `hermes.jobs`.
@freezed
abstract class HermesJobs with _$HermesJobs {
  const factory HermesJobs({
    @Default(<HermesJobDto>[]) List<HermesJobDto> jobs,

    /// The server lets jobs be created and changed (its `jobs_admin`):
    /// otherwise the list is read-only.
    @Default(true) bool writable,

    /// A Desktop Gateway: jobs have delivery targets, a missed-run policy,
    /// a run history, and a running one can be stopped.
    @Default(false) bool scheduling,

    /// What happened since the last read that the window says once: a
    /// Stop that settled, a Run Now that failed.
    @Default(<HermesJobNotice>[]) List<HermesJobNotice> notices,

    /// The job a save wrote (`hermes.saveJob`): a new job's id, which the
    /// editor saves to from then on.
    String? savedId,

    /// The change this answers was made, but the jobs could not be read
    /// again after it: [jobs] is not the list (keep the one shown and read
    /// it again). [savedId] still names what the change wrote.
    @Default(false) bool listFailed,
  }) = _HermesJobs;

  factory HermesJobs.fromJson(Map<String, dynamic> json) =>
      _$HermesJobsFromJson(json);
}

/// Params for `hermes.saveJob`: a new job when [id] is null.
@freezed
abstract class HermesJobEdit with _$HermesJobEdit {
  const factory HermesJobEdit({
    String? id,
    String? name,
    required String prompt,
    required String schedule,

    /// The delivery targets, comma-separated as Hermes stores them (a
    /// Desktop Gateway's); null leaves an edited job's as they are.
    String? deliver,

    /// `default`, `runOnce` or `skip` (a Desktop Gateway's); null leaves
    /// an edited job's as it is.
    String? catchUp,

    /// The Hermes connection the request was made under
    /// (`HermesChanged.connection`): refused once another is in use. Null
    /// from an older window, not checked.
    String? connection,
  }) = _HermesJobEdit;

  factory HermesJobEdit.fromJson(Map<String, dynamic> json) =>
      _$HermesJobEditFromJson(json);
}

/// Params for `hermes.setJobEnabled`.
@freezed
abstract class HermesJobToggle with _$HermesJobToggle {
  const factory HermesJobToggle({
    required String id,
    required bool enabled,

    /// The Hermes connection the request was made under
    /// (`HermesChanged.connection`): refused once another is in use. Null
    /// from an older window, not checked.
    String? connection,
  }) = _HermesJobToggle;

  factory HermesJobToggle.fromJson(Map<String, dynamic> json) =>
      _$HermesJobToggleFromJson(json);
}

@freezed
abstract class HermesSkillDto with _$HermesSkillDto {
  const factory HermesSkillDto({required String name, String? description}) =
      _HermesSkillDto;

  factory HermesSkillDto.fromJson(Map<String, dynamic> json) =>
      _$HermesSkillDtoFromJson(json);
}

@freezed
abstract class HermesToolsetDto with _$HermesToolsetDto {
  const factory HermesToolsetDto({
    required String name,
    @Default('') String label,
    String? description,
    @Default(true) bool enabled,
    @Default(<String>[]) List<String> tools,
  }) = _HermesToolsetDto;

  factory HermesToolsetDto.fromJson(Map<String, dynamic> json) =>
      _$HermesToolsetDtoFromJson(json);
}

/// Reply to `hermes.catalog`: the agent's skills and toolsets, and the
/// `/` commands a Hermes chat's composer offers.
@freezed
abstract class HermesCatalog with _$HermesCatalog {
  const factory HermesCatalog({
    @Default(<HermesSkillDto>[]) List<HermesSkillDto> skills,
    @Default(<HermesToolsetDto>[]) List<HermesToolsetDto> toolsets,

    /// What `/` lists in a Hermes chat, as on a phone: each sent as
    /// `/<name> ` (a Desktop Gateway's command catalog, an API server's
    /// skills). Empty when the server offers none.
    @Default(<HermesSkillDto>[]) List<HermesSkillDto> commands,
  }) = _HermesCatalog;

  factory HermesCatalog.fromJson(Map<String, dynamic> json) =>
      _$HermesCatalogFromJson(json);
}
