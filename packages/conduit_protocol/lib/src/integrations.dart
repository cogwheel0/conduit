import 'package:freezed_annotation/freezed_annotation.dart';

part 'integrations.freezed.dart';
part 'integrations.g.dart';

/// A personal connection's kind.
enum PersonalKind { toolServer, terminal }

/// Whether the account may keep personal connections, by Open WebUI's rule.
enum PersonalAccess {
  allowed,

  /// No Open WebUI account is signed in.
  noAccount,

  /// The server has not switched on direct integrations.
  serverDisabled,

  /// The account is neither an admin nor granted `direct_tool_servers`.
  noPermission,

  /// Open WebUI 0.13.4 and later take personal tools and terminals from the
  /// user's Tether devices, and no longer use the list. It is still listed,
  /// to read only (no `owner`).
  movedToTether,
}

/// One personal tool server (OpenAPI) or terminal, with what its editor
/// fills in. Never its key: [hasKey] says whether one is stored.
@freezed
abstract class PersonalConnectionDto with _$PersonalConnectionDto {
  const factory PersonalConnectionDto({
    required PersonalKind kind,

    /// Names the entry across list changes.
    required String identity,
    @Default('') String name,

    /// The URL without user info, query or fragment, for the list.
    @Default('') String endpoint,
    @Default(true) bool enabled,

    /// The editor understands it; one it does not can still be switched
    /// and deleted.
    @Default(true) bool editable,
    @Default('') String description,
    @Default('') String url,

    /// `url` (the document at [path]) or `json` ([spec] inline).
    @Default('url') String specType,
    @Default('') String path,
    @Default('') String spec,

    /// `bearer` or `none`.
    @Default('bearer') String authType,
    @Default(false) bool hasKey,

    /// A hash of the entry as stored, its key included (never the key
    /// itself). The editor sends it back with a save or a test, which is
    /// refused (`conflict`, reason `changed`) once the entry changed since.
    @Default('') String fingerprint,
  }) = _PersonalConnectionDto;

  factory PersonalConnectionDto.fromJson(Map<String, dynamic> json) =>
      _$PersonalConnectionDtoFromJson(json);
}

/// Reply to `integrations.list` and `integrations.save`.
@freezed
abstract class PersonalConnections with _$PersonalConnections {
  const factory PersonalConnections({
    @Default(PersonalAccess.noAccount) PersonalAccess access,

    /// Names the account the list was read for; every change sends it back
    /// and is refused once another account is signed in.
    @Default('') String owner,
    @Default('') String accountName,
    @Default('') String serverName,
    @Default(<PersonalConnectionDto>[]) List<PersonalConnectionDto> toolServers,
    @Default(<PersonalConnectionDto>[]) List<PersonalConnectionDto> terminals,

    /// Chat selections cleared because their connection went.
    @Default(<String>[]) List<String> cleared,

    /// The list could not be read.
    @Default(false) bool failed,

    /// A save reached the account that asked, which is no longer signed in.
    @Default(false) bool savedForPreviousAccount,
  }) = _PersonalConnections;

  factory PersonalConnections.fromJson(Map<String, dynamic> json) =>
      _$PersonalConnectionsFromJson(json);
}

/// What a form does to the stored key.
enum PersonalKeyMode { keep, replace, clear }

/// An editor's fields.
@freezed
abstract class PersonalConnectionDraft with _$PersonalConnectionDraft {
  const factory PersonalConnectionDraft({
    @Default('') String name,
    @Default('') String description,
    @Default('') String url,
    @Default('url') String specType,
    @Default('') String path,
    @Default('') String spec,
    @Default('bearer') String authType,
    @Default('') String key,
    @Default(PersonalKeyMode.replace) PersonalKeyMode keyMode,
    @Default(true) bool enabled,
  }) = _PersonalConnectionDraft;

  factory PersonalConnectionDraft.fromJson(Map<String, dynamic> json) =>
      _$PersonalConnectionDraftFromJson(json);
}

/// What `integrations.save` does.
enum PersonalEditOp { add, patch, remove, setEnabled }

/// Params for `integrations.save`. [identity] names the entry for every
/// [op] but `add`; [draft] carries the fields for `add` and `patch`.
@freezed
abstract class PersonalConnectionSave with _$PersonalConnectionSave {
  const factory PersonalConnectionSave({
    required String owner,
    required PersonalKind kind,
    required PersonalEditOp op,
    String? identity,
    PersonalConnectionDraft? draft,
    bool? enabled,

    /// For `patch`: the [PersonalConnectionDto.fingerprint] of the entry
    /// the editor opened. The save is refused (`conflict`, reason
    /// `changed`) when the stored entry no longer has it.
    String? fingerprint,
  }) = _PersonalConnectionSave;

  factory PersonalConnectionSave.fromJson(Map<String, dynamic> json) =>
      _$PersonalConnectionSaveFromJson(json);
}

/// Params for `integrations.test`: the form as it stands, for the entry
/// [identity] names (its stored key is used when the form keeps it) or a
/// new one.
@freezed
abstract class PersonalConnectionTest with _$PersonalConnectionTest {
  const factory PersonalConnectionTest({
    required String owner,
    required PersonalKind kind,
    String? identity,
    required PersonalConnectionDraft draft,

    /// For an entry: the [PersonalConnectionDto.fingerprint] it was opened
    /// with. Refused, with nothing probed (`conflict`, reason `changed`),
    /// once the entry changed since.
    String? fingerprint,
  }) = _PersonalConnectionTest;

  factory PersonalConnectionTest.fromJson(Map<String, dynamic> json) =>
      _$PersonalConnectionTestFromJson(json);
}

/// Why a test failed.
enum PersonalProbeFailure {
  invalidTarget,
  unsupportedAuth,
  unauthorized,
  unreachable,
  invalidSpec,
}

/// Reply to `integrations.test`.
@freezed
abstract class PersonalConnectionTestResult
    with _$PersonalConnectionTestResult {
  const factory PersonalConnectionTestResult({
    @Default(false) bool ok,

    /// Operations a tool server exposes; null for a terminal.
    int? operationCount,
    PersonalProbeFailure? failure,
  }) = _PersonalConnectionTestResult;

  factory PersonalConnectionTestResult.fromJson(Map<String, dynamic> json) =>
      _$PersonalConnectionTestResultFromJson(json);
}
