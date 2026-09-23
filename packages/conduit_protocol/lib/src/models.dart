import 'package:freezed_annotation/freezed_annotation.dart';

part 'models.freezed.dart';
part 'models.g.dart';

/// A model the active server offers.
@freezed
abstract class ModelSummary with _$ModelSummary {
  const factory ModelSummary({
    required String id,
    required String name,
    String? description,

    /// Whether the user has pinned it to the top of the picker.
    @Default(false) bool pinned,

    /// Capability hints the server reported -- vision, tools, reasoning.
    /// Names rather than a fixed struct, because the set is the server's and
    /// grows without this protocol changing.
    @Default(<String>[]) List<String> capabilities,

    /// The direct connection that offers it, by name (M4); null for the
    /// server's own. Two connections can offer a model of the same name,
    /// and the server may too.
    String? connection,
  }) = _ModelSummary;

  factory ModelSummary.fromJson(Map<String, dynamic> json) =>
      _$ModelSummaryFromJson(json);
}

/// Reply to `models.list`.
@freezed
abstract class ModelList with _$ModelList {
  const factory ModelList({
    @Default(<ModelSummary>[]) List<ModelSummary> models,

    /// The one new turns use when the caller does not name another. Null
    /// when the server offers none, which the composer shows rather than
    /// discovering at send time.
    String? selectedId,
  }) = _ModelList;

  factory ModelList.fromJson(Map<String, dynamic> json) =>
      _$ModelListFromJson(json);
}

/// Params for `models.select`.
@freezed
abstract class SelectModel with _$SelectModel {
  const factory SelectModel({required String id}) = _SelectModel;

  factory SelectModel.fromJson(Map<String, dynamic> json) =>
      _$SelectModelFromJson(json);
}
