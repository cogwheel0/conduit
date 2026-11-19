import 'package:freezed_annotation/freezed_annotation.dart';

part 'release_notes.freezed.dart';
part 'release_notes.g.dart';

/// One version's release note, as core's catalog reads it.
@freezed
abstract class ReleaseNoteDto with _$ReleaseNoteDto {
  const factory ReleaseNoteDto({
    required String version,
    @Default('') String title,
    @Default('') String intro,
    @Default(<ReleaseNoteBullet>[]) List<ReleaseNoteBullet> bullets,
  }) = _ReleaseNoteDto;

  factory ReleaseNoteDto.fromJson(Map<String, dynamic> json) =>
      _$ReleaseNoteDtoFromJson(json);
}

/// A line of a release note, with core's icon name (`local`, `hermes`,
/// `direct`, `polish`) or none.
@freezed
abstract class ReleaseNoteBullet with _$ReleaseNoteBullet {
  const factory ReleaseNoteBullet({required String text, String? icon}) =
      _ReleaseNoteBullet;

  factory ReleaseNoteBullet.fromJson(Map<String, dynamic> json) =>
      _$ReleaseNoteBulletFromJson(json);
}

/// Params for `releaseNotes.check` and `releaseNotes.latest`.
///
/// The notes describe the app that shows them, so the app ships its own
/// catalog and hands it over: [catalogs] maps a catalog name (`en`, `de`,
/// `zh_Hant`) to its JSON document, in core's format. [languageCode],
/// [scriptCode] and [countryCode] pick one the way core's catalog does
/// (most specific first, then English). [currentVersion] is the app's
/// version; a pre-release or build suffix (`-beta.2`, `+5`) is ignored.
@freezed
abstract class ReleaseNotesQuery with _$ReleaseNotesQuery {
  const factory ReleaseNotesQuery({
    required String currentVersion,
    required String languageCode,
    String? scriptCode,
    String? countryCode,
    @Default(<String, String>{}) Map<String, String> catalogs,
  }) = _ReleaseNotesQuery;

  factory ReleaseNotesQuery.fromJson(Map<String, dynamic> json) =>
      _$ReleaseNotesQueryFromJson(json);
}

/// Reply to `releaseNotes.check` and `releaseNotes.latest`.
@freezed
abstract class ReleaseNotesState with _$ReleaseNotesState {
  const factory ReleaseNotesState({
    /// The version the notes were evaluated for, as core read it.
    required String currentVersion,

    /// The after-update banner shows: this launch is the first since an
    /// update with notes, or the banner was not dismissed yet.
    @Default(false) bool banner,

    /// What the banner or the Release Notes sheet shows, oldest first.
    @Default(<ReleaseNoteDto>[]) List<ReleaseNoteDto> notes,
  }) = _ReleaseNotesState;

  factory ReleaseNotesState.fromJson(Map<String, dynamic> json) =>
      _$ReleaseNotesStateFromJson(json);
}
