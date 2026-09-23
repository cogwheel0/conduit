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

    /// Palette id from `conduit_theme`'s desktop palettes, e.g. `t3_chat`.
    /// Stable across upgrades because a stored preference has to survive
    /// them.
    @Default('zai') String themePaletteId,

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
