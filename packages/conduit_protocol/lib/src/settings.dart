import 'package:freezed_annotation/freezed_annotation.dart';

part 'settings.freezed.dart';
part 'settings.g.dart';

/// Light, dark, or whatever the OS says.
@JsonEnum(fieldRename: FieldRename.none)
enum AppThemeMode { light, dark, system }

/// The preferences that belong to the app rather than to a server account.
///
/// Stored by the daemon in the same `PreferencesStore` keys the mobile app
/// uses -- `theme_mode`, `theme_palette_v1`, `locale_code_v1` -- so the two
/// front-ends agree on what a stored value means, and so a key does not get
/// invented twice under two spellings.
///
/// Server-side user settings (memories, personalization, the account's own
/// preferences) are a different namespace and a different story: they live on
/// the server and sync. These do not leave the machine.
@freezed
abstract class AppPreferences with _$AppPreferences {
  const factory AppPreferences({
    @Default(AppThemeMode.system) AppThemeMode themeMode,

    /// Palette id from `conduit_theme`'s palettes, e.g. `t3_chat`. Stable
    /// across upgrades because a stored preference has to survive them;
    /// the retired desktop-only `zai` reads as `conduit`.
    @Default('conduit') String themePaletteId,

    /// The interface font size in pixels, which the whole text scale
    /// follows. Code, diffs and the terminal keep their own sizes.
    @Default(kDefaultUiFontSize) int uiFontSize,

    /// BCP-47 code, or null to follow the OS. Null is a real value here, not
    /// an absent one: "follow the system" is a choice a user can return to.
    String? localeCode,
  }) = _AppPreferences;

  factory AppPreferences.fromJson(Map<String, dynamic> json) =>
      _$AppPreferencesFromJson(json);
}

/// The interface font size before a user picks one, and its bounds.
const int kDefaultUiFontSize = 14;
const int kMinUiFontSize = 12;
const int kMaxUiFontSize = 18;

/// Params for `settings.setApp`.
///
/// Every field is nullable and means "leave alone", so a palette change does
/// not have to restate the locale. [clearLocaleCode] is how "follow the
/// system" is chosen, since null already means "unchanged".
@freezed
abstract class AppPreferencesPatch with _$AppPreferencesPatch {
  const factory AppPreferencesPatch({
    AppThemeMode? themeMode,
    String? themePaletteId,
    int? uiFontSize,
    String? localeCode,
    @Default(false) bool clearLocaleCode,
  }) = _AppPreferencesPatch;

  factory AppPreferencesPatch.fromJson(Map<String, dynamic> json) =>
      _$AppPreferencesPatchFromJson(json);
}

/// The Direct connection that speaks and listens for Direct and Apple chats
/// (core's `DirectVoiceProviderSettings`, Settings › Voice Provider).
@freezed
abstract class DirectVoiceProviderDto with _$DirectVoiceProviderDto {
  const factory DirectVoiceProviderDto({
    /// The Direct connection's id.
    required String profileId,

    /// The speech-to-text model, as for `POST audio/transcriptions`.
    String? transcriptionModel,

    /// The text-to-speech model, as for `POST audio/speech`.
    String? speechModel,

    /// The voice [speechModel] speaks with.
    String? speechVoice,

    /// The model a realtime call talks to.
    String? realtimeModel,

    /// The voice [realtimeModel] speaks with.
    String? realtimeVoice,

    /// Instructions that replace Conduit's own for a realtime call.
    String? realtimeInstructions,
  }) = _DirectVoiceProviderDto;

  factory DirectVoiceProviderDto.fromJson(Map<String, dynamic> json) =>
      _$DirectVoiceProviderDtoFromJson(json);
}

/// The settings core keeps in `AppSettings` that the phone's Settings pages
/// expose (Chats, Personalization, Data & Connection, Audio, Voice
/// Provider), named as core names them so a host reads them by the same
/// names. Reply to `settings.get` and `settings.set`. `settings.changed`
/// carries no payload: read them again with `settings.get`.
///
/// The enumerations are core's enum names as strings: [voiceCallMode] is
/// `auto` or `standard`, [sttPreference] `deviceOnly` or `serverOnly`,
/// [ttsEngine] `device` or `server`, [socketTransportMode] `ws` or
/// `polling`. Defaults are core's.
@freezed
abstract class AppSettingsDto with _$AppSettingsDto {
  const factory AppSettingsDto({
    // Chats.
    /// The chat's Computer (Open Terminal's screen) is offered.
    @Default(true) bool computerEnabled,

    /// The composer's one-tap toggles: `web`, `image`, and tool or filter
    /// ids.
    @Default(<String>[]) List<String> quickPills,

    /// The message actions shown inline, in order; null keeps the default
    /// layout, and an empty list puts every action in More.
    List<String>? inlineMessageActions,
    @Default(false) bool sendOnEnter,

    /// The composer's Save as Note button shows.
    @Default(true) bool showComposerNotesButton,

    /// The empty message box names the selected model ("Ask Codex · gpt-5.1")
    /// instead of the app's own words.
    @Default(false) bool showModelNameInComposer,
    @Default(false) bool temporaryChatByDefault,

    /// Inline citations show the source's title, not only its number.
    @Default(false) bool citationShowTitles,

    /// Inline citations sit on a filled badge.
    @Default(true) bool citationBackground,

    /// Shows the Advanced settings (Chat Data Controls and the rest).
    @Default(false) bool advancedFeaturesEnabled,

    // Personalization.
    /// The model new chats start with; null picks one automatically.
    String? defaultModel,

    /// The model OpenRouter generates images with; null is the default.
    String? openRouterImageGenerationModel,

    // Data & Connection.
    @Default('ws') String socketTransportMode,

    // Audio.
    @Default('auto') String voiceCallMode,
    @Default('deviceOnly') String sttPreference,

    /// The device recognizer's language (`en_US`), or null for the
    /// system's.
    String? voiceLocaleId,

    /// The language the server transcribes, or null to let it guess.
    String? sttLanguageCode,

    /// How long a pause ends dictation, in milliseconds.
    @Default(2000) int voiceSilenceDuration,
    @Default(false) bool voiceBargeInEnabled,
    @Default('device') String ttsEngine,

    /// The device voice, by identifier and name.
    String? ttsVoice,
    String? ttsVoiceName,

    /// The server voice, by id and name.
    String? ttsServerVoiceId,
    String? ttsServerVoiceName,

    /// One of core's `ttsSpeedPresets`.
    @Default(1.0) double ttsSpeed,

    // Voice Provider.
    DirectVoiceProviderDto? directVoiceProvider,

    // Hermes.
    /// The chats a scheduled agent starts each time it runs are listed with
    /// the other Hermes chats (a pinned one always is).
    @Default(true) bool hermesShowScheduledSessions,

    /// Every message action, by id, in the order Settings lists them
    /// (core's catalog: `copy`, `tts`, `regenerate`, ...). Not a setting.
    @Default(<String>[]) List<String> messageActions,

    /// What [inlineMessageActions] means while it is null (Automatic).
    @Default(<String>[]) List<String> defaultInlineMessageActions,
  }) = _AppSettingsDto;

  factory AppSettingsDto.fromJson(Map<String, dynamic> json) =>
      _$AppSettingsDtoFromJson(json);
}

/// Params for `settings.set`: a null field is left alone, and [clear]
/// names the nullable fields to set back to null (`defaultModel` picks a
/// model automatically again, `inlineMessageActions` restores the default
/// layout). A field both set and cleared is cleared.
@freezed
abstract class AppSettingsPatch with _$AppSettingsPatch {
  const factory AppSettingsPatch({
    bool? computerEnabled,
    List<String>? quickPills,
    List<String>? inlineMessageActions,
    bool? sendOnEnter,
    bool? showComposerNotesButton,
    bool? showModelNameInComposer,
    bool? temporaryChatByDefault,
    bool? citationShowTitles,
    bool? citationBackground,
    bool? advancedFeaturesEnabled,
    String? defaultModel,
    String? openRouterImageGenerationModel,
    String? socketTransportMode,
    String? voiceCallMode,
    String? sttPreference,
    String? voiceLocaleId,
    String? sttLanguageCode,
    int? voiceSilenceDuration,
    bool? voiceBargeInEnabled,
    String? ttsEngine,
    String? ttsVoice,
    String? ttsVoiceName,
    String? ttsServerVoiceId,
    String? ttsServerVoiceName,
    double? ttsSpeed,
    DirectVoiceProviderDto? directVoiceProvider,
    bool? hermesShowScheduledSessions,

    /// [AppSettingsDto] field names to set back to null.
    @Default(<String>[]) List<String> clear,
  }) = _AppSettingsPatch;

  factory AppSettingsPatch.fromJson(Map<String, dynamic> json) =>
      _$AppSettingsPatchFromJson(json);
}

/// The signed-in Open WebUI account's own settings that Settings shows, kept
/// on its server: "Your system prompt" (Open WebUI's `ui.system`). Reply to
/// `settings.getAccount` and `settings.setAccount`.
@freezed
abstract class AccountSettingsDto with _$AccountSettingsDto {
  const factory AccountSettingsDto({
    /// An Open WebUI account is signed in, so these apply.
    @Default(false) bool available,

    /// Sent before every chat's own system prompt; null for none.
    String? systemPrompt,
  }) = _AccountSettingsDto;

  factory AccountSettingsDto.fromJson(Map<String, dynamic> json) =>
      _$AccountSettingsDtoFromJson(json);
}

/// Params for `settings.setAccount`. An empty [systemPrompt] removes it.
@freezed
abstract class AccountSettingsPatch with _$AccountSettingsPatch {
  const factory AccountSettingsPatch({String? systemPrompt}) =
      _AccountSettingsPatch;

  factory AccountSettingsPatch.fromJson(Map<String, dynamic> json) =>
      _$AccountSettingsPatchFromJson(json);
}

/// Params for `settings.modelPrompt`.
@freezed
abstract class ModelPromptRef with _$ModelPromptRef {
  const factory ModelPromptRef({required String modelId}) = _ModelPromptRef;

  factory ModelPromptRef.fromJson(Map<String, dynamic> json) =>
      _$ModelPromptRefFromJson(json);
}

/// A model's own system prompt on the server (Settings › Chats › Prompt
/// Overrides). Reply to `settings.modelPrompt` and `settings.setModelPrompt`.
@freezed
abstract class ModelPrompt with _$ModelPrompt {
  const factory ModelPrompt({
    required String modelId,

    /// The server has a record for the model to hold a prompt (a base model
    /// with no saved settings has none).
    @Default(false) bool editable,

    /// This account may change it.
    @Default(false) bool writable,
    @Default('') String prompt,
  }) = _ModelPrompt;

  factory ModelPrompt.fromJson(Map<String, dynamic> json) =>
      _$ModelPromptFromJson(json);
}

/// Params for `settings.setModelPrompt`. An empty [prompt] removes it.
@freezed
abstract class ModelPromptEdit with _$ModelPromptEdit {
  const factory ModelPromptEdit({
    required String modelId,
    @Default('') String prompt,
  }) = _ModelPromptEdit;

  factory ModelPromptEdit.fromJson(Map<String, dynamic> json) =>
      _$ModelPromptEditFromJson(json);
}

/// One of the composer's quick pills Settings › Chats can turn on.
@freezed
abstract class QuickPillOption with _$QuickPillOption {
  const factory QuickPillOption({
    /// `web`, `image`, a tool id, or `filter:<id>`.
    required String id,

    /// `web`, `image`, `tool` or `filter`.
    required String kind,

    /// The tool's or filter's name (empty for `web` and `image`, which the
    /// window names itself).
    @Default('') String name,

    /// The tool's or filter's own id, which its switch turns on (a filter's
    /// without the `filter:` prefix); empty for `web` and `image`.
    @Default('') String targetId,
  }) = _QuickPillOption;

  factory QuickPillOption.fromJson(Map<String, dynamic> json) =>
      _$QuickPillOptionFromJson(json);
}

/// Reply to `settings.quickPills`: the pills on offer, in core's order.
@freezed
abstract class QuickPillOptions with _$QuickPillOptions {
  const factory QuickPillOptions({
    @Default(<QuickPillOption>[]) List<QuickPillOption> options,
  }) = _QuickPillOptions;

  factory QuickPillOptions.fromJson(Map<String, dynamic> json) =>
      _$QuickPillOptionsFromJson(json);
}

/// A Direct connection the Voice Provider can use.
@freezed
abstract class VoiceProviderOption with _$VoiceProviderOption {
  const factory VoiceProviderOption({
    required String id,
    @Default('') String name,
  }) = _VoiceProviderOption;

  factory VoiceProviderOption.fromJson(Map<String, dynamic> json) =>
      _$VoiceProviderOptionFromJson(json);
}

/// Reply to `settings.voiceProviders`: the Direct connections that can speak
/// and listen (usable, OpenAI-compatible).
@freezed
abstract class VoiceProviderOptions with _$VoiceProviderOptions {
  const factory VoiceProviderOptions({
    @Default(<VoiceProviderOption>[]) List<VoiceProviderOption> connections,
  }) = _VoiceProviderOptions;

  factory VoiceProviderOptions.fromJson(Map<String, dynamic> json) =>
      _$VoiceProviderOptionsFromJson(json);
}

/// Reply to `settings.about`: About's server rows and Conduit's links.
@freezed
abstract class AboutInfo with _$AboutInfo {
  const factory AboutInfo({
    /// An Open WebUI server is signed in to, so its rows apply.
    @Default(false) bool server,
    String? serverName,
    String? serverVersion,

    /// The newest version the server's maker has released, when it says.
    String? latestVersion,
    @Default('') String repositoryUrl,
    @Default('') String buyMeACoffeeUrl,
    @Default('') String githubSponsorsUrl,
  }) = _AboutInfo;

  factory AboutInfo.fromJson(Map<String, dynamic> json) =>
      _$AboutInfoFromJson(json);
}
