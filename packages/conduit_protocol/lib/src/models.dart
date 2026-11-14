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

    /// A coding agent on one of the server's terminals (Open WebUI 0.13.1
    /// and later), listed under [ModelList.agents]; null for every other
    /// model. Its [name] is the picker's ("Codex · gpt-5.1").
    TerminalAgentDto? agent,
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

    /// The selected terminal's coding agents, listed after the account's
    /// models under "Coding Agents" (core's `terminalAgentModelsProvider`):
    /// only the server's own terminals offer them, only in a saved chat
    /// ([ModelListQuery.chatId], or a new one that is not temporary), and
    /// only on Open WebUI 0.13.1 and later. Empty when the terminal could
    /// not be asked in time. [featuredIds] may name one (when it is
    /// selected or pinned), and so may [selectedId].
    @Default(<ModelSummary>[]) List<ModelSummary> agents,

    /// The coding agents this chat's replies came from, by model id, named
    /// as the picker names them ("Codex · gpt-5.1"), for a reply's header
    /// when its terminal no longer offers the agent.
    @Default(<String, String>{}) Map<String, String> agentNames,
  }) = _ModelList;

  factory ModelList.fromJson(Map<String, dynamic> json) =>
      _$ModelListFromJson(json);
}

/// A coding agent's place: the terminal it runs on, the agent (`codex`,
/// `claude-code`, ...) and the agent's own model, as its model id
/// (`agent:<terminal>:<agent>:<model>`) names them.
@freezed
abstract class TerminalAgentDto with _$TerminalAgentDto {
  const factory TerminalAgentDto({
    required String terminalId,

    /// The terminal's name, when the server listed it.
    String? terminalName,

    /// The agent's id (`codex`).
    required String agent,

    /// The agent's name as its maker gives it (`Codex`).
    @Default('') String agentName,

    /// The agent's own model (`gpt-5.1`).
    required String model,
  }) = _TerminalAgentDto;

  factory TerminalAgentDto.fromJson(Map<String, dynamic> json) =>
      _$TerminalAgentDtoFromJson(json);
}

/// Params for `models.list`: the chat the picker is for. Nothing set lists
/// for a new chat.
@freezed
abstract class ModelListQuery with _$ModelListQuery {
  const factory ModelListQuery({
    /// The open chat; null for a new one.
    String? chatId,

    /// The new chat is a temporary one, where no coding agent answers.
    @Default(false) bool temporary,
  }) = _ModelListQuery;

  factory ModelListQuery.fromJson(Map<String, dynamic> json) =>
      _$ModelListQueryFromJson(json);
}

/// Params for `models.select`.
@freezed
abstract class SelectModel with _$SelectModel {
  const factory SelectModel({
    required String id,

    /// The chat the picker is for: a coding agent ([ModelList.agents]) is
    /// found among the ones its terminal offers there. Null for a new
    /// chat.
    String? chatId,
  }) = _SelectModel;

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

/// One option of a model's control.
@freezed
abstract class ModelControlOptionDto with _$ModelControlOptionDto {
  const factory ModelControlOptionDto({
    /// What Open WebUI stores for it.
    required String value,

    /// The server's label; the window names the values it knows (a
    /// reasoning effort's `high`) in its own language.
    @Default('') String label,
  }) = _ModelControlOptionDto;

  factory ModelControlOptionDto.fromJson(Map<String, dynamic> json) =>
      _$ModelControlOptionDtoFromJson(json);
}

/// A setting a model offers beside its name, such as a coding agent's
/// reasoning effort or service tier (Open WebUI's `model_controls`, core's
/// `ModelControl`). Every one picks one of its [options].
@freezed
abstract class ModelControlDto with _$ModelControlDto {
  const factory ModelControlDto({
    /// Open WebUI's key: `reasoning_effort`, `service_tier`, or another
    /// the server names.
    required String key,

    /// The server's label; the window names the two keys above itself.
    @Default('') String label,
    String? description,
    @Default(<ModelControlOptionDto>[]) List<ModelControlOptionDto> options,

    /// The option that applies while the user has picked none, if any.
    String? defaultValue,

    /// The option that applies now: the user's pick, else [defaultValue];
    /// null for none ("Default").
    String? value,
  }) = _ModelControlDto;

  factory ModelControlDto.fromJson(Map<String, dynamic> json) =>
      _$ModelControlDtoFromJson(json);
}

/// Params for `models.controls`.
@freezed
abstract class ModelControlsQuery with _$ModelControlsQuery {
  const factory ModelControlsQuery({
    /// Null for the account's selection.
    String? modelId,

    /// The chat the picker is for, where a coding agent is looked up.
    String? chatId,
  }) = _ModelControlsQuery;

  factory ModelControlsQuery.fromJson(Map<String, dynamic> json) =>
      _$ModelControlsQueryFromJson(json);
}

/// Reply to `models.controls` and `models.setControl`: one model's
/// controls, in the order the server lists them. Empty for a model with
/// none.
@freezed
abstract class ModelControlList with _$ModelControlList {
  const factory ModelControlList({
    String? modelId,
    @Default(<ModelControlDto>[]) List<ModelControlDto> controls,
  }) = _ModelControlList;

  factory ModelControlList.fromJson(Map<String, dynamic> json) =>
      _$ModelControlListFromJson(json);
}

/// Params for `models.setControl`: the pick for one of a model's controls,
/// saved in the account's Open WebUI settings (`ui.params.model_controls`),
/// where every turn and the web client read it.
@freezed
abstract class SetModelControl with _$SetModelControl {
  const factory SetModelControl({
    /// Null for the account's selection.
    String? modelId,
    String? chatId,
    required String key,

    /// One of the control's option values; null clears the pick.
    String? value,
  }) = _SetModelControl;

  factory SetModelControl.fromJson(Map<String, dynamic> json) =>
      _$SetModelControlFromJson(json);
}
