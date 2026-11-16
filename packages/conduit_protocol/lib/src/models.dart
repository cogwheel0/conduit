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

    /// The direct connection that offers it, by name; null for the
    /// server's own. Two connections can offer a model of the same name,
    /// and the server may too.
    String? connection,

    /// A direct model's maker (or provider): the id of a logo in the
    /// app's bundled models.dev catalog (`openai`, `ollama-cloud`). Null
    /// draws the model's initial.
    String? logo,
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

    /// The picker's first list, as mobile's: the pinned models, or with
    /// none pinned the first few, the default and the selected one.
    @Default(<String>[]) List<String> featuredIds,

    /// The rest, under "More Models": an untitled group first, then the
    /// titled ones.
    @Default(<ModelSection>[]) List<ModelSection> moreSections,

    /// Models may be pinned and unpinned (`models.setPinned`).
    @Default(false) bool canPin,

    /// The account's default model (Settings › Personalization).
    String? defaultId,
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

/// A group of models under "More Models"; [label] is empty for the
/// untitled one.
@freezed
abstract class ModelSection with _$ModelSection {
  const factory ModelSection({
    @Default('') String label,
    @Default(<String>[]) List<String> ids,
  }) = _ModelSection;

  factory ModelSection.fromJson(Map<String, dynamic> json) =>
      _$ModelSectionFromJson(json);
}

/// Params for `models.setPinned`.
@freezed
abstract class SetModelPinned with _$SetModelPinned {
  const factory SetModelPinned({required String id, required bool pinned}) =
      _SetModelPinned;

  factory SetModelPinned.fromJson(Map<String, dynamic> json) =>
      _$SetModelPinnedFromJson(json);
}

/// Params for `models.options`: the model a chat runs on.
@freezed
abstract class ModelOptionsQuery with _$ModelOptionsQuery {
  const factory ModelOptionsQuery({
    /// Null for the account's selection.
    String? modelId,

    /// The chat a reasoning pick is saved on; null for a new chat.
    String? chatId,
  }) = _ModelOptionsQuery;

  factory ModelOptionsQuery.fromJson(Map<String, dynamic> json) =>
      _$ModelOptionsQueryFromJson(json);
}

/// How the picker offers reasoning effort for one model.
@freezed
abstract class ReasoningOptions with _$ReasoningOptions {
  const factory ReasoningOptions({
    /// The model takes a reasoning effort at all.
    @Default(false) bool visible,

    /// The efforts to offer, `automatic` first.
    @Default(<String>[]) List<String> options,

    /// Another value may be typed.
    @Default(false) bool allowsCustom,

    /// What the next turn would send (`automatic` for the server's own).
    @Default('automatic') String current,

    /// The model is an Ollama model, whose effort is its thinking level.
    @Default(false) bool ollama,
  }) = _ReasoningOptions;

  factory ReasoningOptions.fromJson(Map<String, dynamic> json) =>
      _$ReasoningOptionsFromJson(json);
}

/// Reply to `models.options`, `models.setReasoningEffort` and
/// `models.setFastTier`: the picker's extras for one model.
@freezed
abstract class ModelOptionsDto with _$ModelOptionsDto {
  const factory ModelOptionsDto({
    String? modelId,
    @Default(ReasoningOptions()) ReasoningOptions reasoning,

    /// Hermes' Fast tier: null when the model has none, else whether it is
    /// on.
    bool? fastTier,

    /// A new chat's settings after a reasoning pick (it is saved on the
    /// chat as mobile saves it); null when the pick is not for a new chat.
    Map<String, dynamic>? draft,
  }) = _ModelOptionsDto;

  factory ModelOptionsDto.fromJson(Map<String, dynamic> json) =>
      _$ModelOptionsDtoFromJson(json);
}

/// Params for `models.setReasoningEffort`.
@freezed
abstract class SetReasoningEffort with _$SetReasoningEffort {
  const factory SetReasoningEffort({
    required String modelId,

    /// The chat the pick is saved on; null for a new chat, whose settings
    /// are [draft].
    String? chatId,
    @Default(<String, dynamic>{}) Map<String, dynamic> draft,

    /// A preset (`automatic`, `low`, ...) or a custom value.
    required String effort,
  }) = _SetReasoningEffort;

  factory SetReasoningEffort.fromJson(Map<String, dynamic> json) =>
      _$SetReasoningEffortFromJson(json);
}

/// Params for `models.setFastTier`.
@freezed
abstract class SetFastTier with _$SetFastTier {
  const factory SetFastTier({String? modelId, required bool on}) = _SetFastTier;

  factory SetFastTier.fromJson(Map<String, dynamic> json) =>
      _$SetFastTierFromJson(json);
}
