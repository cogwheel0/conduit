import 'package:freezed_annotation/freezed_annotation.dart';

part 'chat_settings.freezed.dart';
part 'chat_settings.g.dart';

/// What a chat's More menu offers for its own settings (Open WebUI only).
enum ChatSettingsEntry {
  /// Nothing: not an Open WebUI chat, or nothing to show.
  none,

  /// The editor: Settings › Chat › Advanced is on and the account may edit.
  editor,

  /// A read-only summary of the settings that apply.
  applied,
}

/// How one setting stands relative to the user's own defaults.
enum ChatSettingMode {
  /// No override: the user's default applies ("Your Default").
  inherit,

  /// An explicit null: the model's own default ("Model Default").
  modelDefault,

  /// A value of its own.
  custom,
}

/// What kind of value a setting takes.
enum ChatSettingKind { text, decimal, integer, stopList, responseFormat, choice }

/// Why a typed value is not accepted.
enum ChatSettingError {
  required,
  notANumber,
  notAWholeNumber,
  outOfRange,
  notJson,
  notAChoice,
}

/// Params for `chatSettings.get`.
@freezed
abstract class ChatSettingsQuery with _$ChatSettingsQuery {
  const factory ChatSettingsQuery({
    /// Null for a new chat, whose settings the window keeps in [draft]
    /// until the chat is created (`turns.send` takes them).
    String? chatId,

    /// The model the chat runs on, which decides the reasoning choices;
    /// null for the account's selection.
    String? modelId,

    /// A new chat's settings so far, as the last answer returned them.
    @Default(<String, dynamic>{}) Map<String, dynamic> draft,
  }) = _ChatSettingsQuery;

  factory ChatSettingsQuery.fromJson(Map<String, dynamic> json) =>
      _$ChatSettingsQueryFromJson(json);
}

/// One field of the editor.
@freezed
abstract class ChatSettingField with _$ChatSettingField {
  const factory ChatSettingField({
    /// The `chat.params` key (`system`, `temperature`, `stop`, ...).
    required String key,
    required ChatSettingKind kind,
    @Default(ChatSettingMode.inherit) ChatSettingMode mode,

    /// What the field holds as text (a choice's value for a choice).
    @Default('') String text,

    /// A choice field's values, without "Your Default" and the model's
    /// default, which every choice has.
    @Default(<String>[]) List<String> choices,

    /// A value outside [choices] may be typed (a custom reasoning effort).
    @Default(false) bool allowsCustom,

    /// The range a number must fall in, when it has one.
    double? min,
    double? max,

    /// Why what is typed cannot be saved; null when it can.
    ChatSettingError? error,
  }) = _ChatSettingField;

  factory ChatSettingField.fromJson(Map<String, dynamic> json) =>
      _$ChatSettingFieldFromJson(json);
}

/// One row of the read-only summary.
@freezed
abstract class ChatSettingApplied with _$ChatSettingApplied {
  const factory ChatSettingApplied({
    required String key,

    /// Null: the model's own default was chosen.
    String? value,
  }) = _ChatSettingApplied;

  factory ChatSettingApplied.fromJson(Map<String, dynamic> json) =>
      _$ChatSettingAppliedFromJson(json);
}

/// Reply to `chatSettings.get`, `chatSettings.check` and
/// `chatSettings.save`: the form as it stands.
@freezed
abstract class ChatSettingsState with _$ChatSettingsState {
  const factory ChatSettingsState({
    String? chatId,
    @Default(ChatSettingsEntry.none) ChatSettingsEntry entry,

    /// Settings › Chat › Advanced.
    @Default(false) bool advanced,
    @Default(false) bool canEditSystemPrompt,
    @Default(false) bool canEditParameters,

    /// The `system` field.
    required ChatSettingField systemPrompt,

    /// The parameters the editor offers, in order.
    @Default(<ChatSettingField>[]) List<ChatSettingField> parameters,

    /// Saved keys the editor does not offer, which are kept as they are.
    @Default(false) bool otherKept,

    /// What applies, for the read-only summary.
    @Default(<ChatSettingApplied>[]) List<ChatSettingApplied> applied,

    /// The chat's settings as saved. For a new chat, what the window keeps
    /// and sends with its first message.
    @Default(<String, dynamic>{}) Map<String, dynamic> params,

    /// The edit changes something.
    @Default(false) bool dirty,

    /// Some field of the edit cannot be saved.
    @Default(false) bool hasErrors,

    /// `chatSettings.save` wrote the edit.
    @Default(false) bool saved,
  }) = _ChatSettingsState;

  factory ChatSettingsState.fromJson(Map<String, dynamic> json) =>
      _$ChatSettingsStateFromJson(json);
}

/// One field as the editor holds it.
@freezed
abstract class ChatSettingFieldEdit with _$ChatSettingFieldEdit {
  const factory ChatSettingFieldEdit({
    required String key,
    required ChatSettingMode mode,
    @Default('') String text,
  }) = _ChatSettingFieldEdit;

  factory ChatSettingFieldEdit.fromJson(Map<String, dynamic> json) =>
      _$ChatSettingFieldEditFromJson(json);
}

/// Params for `chatSettings.check` and `chatSettings.save`: every field
/// the editor shows, as it holds them. Only what differs from what is saved
/// is written; the rest stays exactly as stored.
@freezed
abstract class ChatSettingsEdit with _$ChatSettingsEdit {
  const factory ChatSettingsEdit({
    String? chatId,
    String? modelId,
    @Default(<String, dynamic>{}) Map<String, dynamic> draft,
    @Default(<ChatSettingFieldEdit>[]) List<ChatSettingFieldEdit> fields,
  }) = _ChatSettingsEdit;

  factory ChatSettingsEdit.fromJson(Map<String, dynamic> json) =>
      _$ChatSettingsEditFromJson(json);
}
