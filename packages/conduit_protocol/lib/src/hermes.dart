import 'package:freezed_annotation/freezed_annotation.dart';

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
    @Default(false) bool allowSelfSignedCertificates,
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
  }) = _HermesStatus;

  factory HermesStatus.fromJson(Map<String, dynamic> json) =>
      _$HermesStatusFromJson(json);
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
  }) = _HermesSessionDto;

  factory HermesSessionDto.fromJson(Map<String, dynamic> json) =>
      _$HermesSessionDtoFromJson(json);
}

/// Reply to `hermes.sessions`.
@freezed
abstract class HermesSessions with _$HermesSessions {
  const factory HermesSessions({
    @Default(<HermesSessionDto>[]) List<HermesSessionDto> sessions,
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

/// Params for `hermes.renameSession`.
@freezed
abstract class HermesRename with _$HermesRename {
  const factory HermesRename({required String id, required String title}) =
      _HermesRename;

  factory HermesRename.fromJson(Map<String, dynamic> json) =>
      _$HermesRenameFromJson(json);
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
    @Default(true) bool enabled,
    String? lastStatus,
    String? lastError,
    int? lastRunAtMs,
    int? nextRunAtMs,
  }) = _HermesJobDto;

  factory HermesJobDto.fromJson(Map<String, dynamic> json) =>
      _$HermesJobDtoFromJson(json);
}

/// Reply to `hermes.jobs`.
@freezed
abstract class HermesJobs with _$HermesJobs {
  const factory HermesJobs({
    @Default(<HermesJobDto>[]) List<HermesJobDto> jobs,
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
  }) = _HermesJobEdit;

  factory HermesJobEdit.fromJson(Map<String, dynamic> json) =>
      _$HermesJobEditFromJson(json);
}

/// Params for `hermes.setJobEnabled`.
@freezed
abstract class HermesJobToggle with _$HermesJobToggle {
  const factory HermesJobToggle({required String id, required bool enabled}) =
      _HermesJobToggle;

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

/// Reply to `hermes.catalog`: the agent's skills (its `/` commands) and
/// toolsets.
@freezed
abstract class HermesCatalog with _$HermesCatalog {
  const factory HermesCatalog({
    @Default(<HermesSkillDto>[]) List<HermesSkillDto> skills,
    @Default(<HermesToolsetDto>[]) List<HermesToolsetDto> toolsets,
  }) = _HermesCatalog;

  factory HermesCatalog.fromJson(Map<String, dynamic> json) =>
      _$HermesCatalogFromJson(json);
}
