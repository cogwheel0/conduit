import 'package:freezed_annotation/freezed_annotation.dart';

part 'valves.freezed.dart';
part 'valves.g.dart';

/// What a valve set belongs to: a tool, or a function (a filter or the
/// pipe behind a model).
enum ValveTargetKind { tool, function }

/// One tool, filter or pipe whose personal valves the user may set.
@freezed
abstract class ValveTarget with _$ValveTarget {
  const factory ValveTarget({
    required ValveTargetKind kind,

    /// The server resource the valves belong to (for a pipe, the function
    /// behind the model).
    required String id,
    @Default('') String label,
  }) = _ValveTarget;

  factory ValveTarget.fromJson(Map<String, dynamic> json) =>
      _$ValveTargetFromJson(json);
}

/// Params for `valves.targets`: the chat's model and the tools and filters
/// its composer has on.
@freezed
abstract class ValveTargetsQuery with _$ValveTargetsQuery {
  const factory ValveTargetsQuery({
    String? modelId,
    @Default(<String>[]) List<String> toolIds,
    @Default(<String>[]) List<String> filterIds,
  }) = _ValveTargetsQuery;

  factory ValveTargetsQuery.fromJson(Map<String, dynamic> json) =>
      _$ValveTargetsQueryFromJson(json);
}

/// Reply to `valves.targets`. Empty when there is nothing to set, or the
/// account's `chat.valves` permission is off.
@freezed
abstract class ValveTargets with _$ValveTargets {
  const factory ValveTargets({
    @Default(<ValveTarget>[]) List<ValveTarget> targets,

    /// Settings › Chat › Advanced, which offers the command.
    @Default(false) bool advanced,
  }) = _ValveTargets;

  factory ValveTargets.fromJson(Map<String, dynamic> json) =>
      _$ValveTargetsFromJson(json);
}

/// Names a valve set for `valves.get`.
@freezed
abstract class ValvesRef with _$ValvesRef {
  const factory ValvesRef({
    required ValveTargetKind kind,
    required String id,
    @Default('') String label,
  }) = _ValvesRef;

  factory ValvesRef.fromJson(Map<String, dynamic> json) =>
      _$ValvesRefFromJson(json);
}

/// What a valve's value is.
enum ValveFieldType { text, number, integer, boolean, choice, list }

/// One valve, as the form draws it.
@freezed
abstract class ValveField with _$ValveField {
  const factory ValveField({
    required String key,
    required String title,
    String? description,
    @Default(ValveFieldType.text) ValveFieldType type,
    @Default(false) bool isRequired,

    /// A secret: drawn masked.
    @Default(false) bool password,

    /// A choice's options, as text.
    @Default(<String>[]) List<String> options,

    /// At the server's default (no value of its own).
    @Default(true) bool isDefault,

    /// The schema declares a default (else "None" stands for it).
    @Default(false) bool hasDefault,

    /// The value as text (`true`/`false` for a switch; a list joined with
    /// commas).
    @Default('') String text,

    /// What the field starts at when it stops using the default.
    @Default('') String seed,
  }) = _ValveField;

  factory ValveField.fromJson(Map<String, dynamic> json) =>
      _$ValveFieldFromJson(json);
}

/// Where a valve set's loading ended.
enum ValvesPhase { ready, unavailable, loadFailed, ownerChanged }

/// Reply to `valves.get` and `valves.save`.
@freezed
abstract class ValvesDocument with _$ValvesDocument {
  const factory ValvesDocument({
    required ValveTargetKind kind,
    required String id,
    @Default('') String label,
    @Default(ValvesPhase.ready) ValvesPhase phase,
    @Default(<ValveField>[]) List<ValveField> fields,
  }) = _ValvesDocument;

  factory ValvesDocument.fromJson(Map<String, dynamic> json) =>
      _$ValvesDocumentFromJson(json);
}

/// One valve as the form holds it.
@freezed
abstract class ValveEdit with _$ValveEdit {
  const factory ValveEdit({
    required String key,
    @Default(true) bool isDefault,
    @Default('') String text,
  }) = _ValveEdit;

  factory ValveEdit.fromJson(Map<String, dynamic> json) =>
      _$ValveEditFromJson(json);
}

/// Params for `valves.save`.
@freezed
abstract class ValvesSave with _$ValvesSave {
  const factory ValvesSave({
    required ValveTargetKind kind,
    required String id,
    @Default('') String label,
    @Default(<ValveEdit>[]) List<ValveEdit> values,
  }) = _ValvesSave;

  factory ValvesSave.fromJson(Map<String, dynamic> json) =>
      _$ValvesSaveFromJson(json);
}
