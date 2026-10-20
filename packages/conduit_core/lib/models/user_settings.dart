import 'package:freezed_annotation/freezed_annotation.dart';

part 'user_settings.freezed.dart';
part 'user_settings.g.dart';

@freezed
sealed class UserSettings with _$UserSettings {
  const factory UserSettings({
    // Chat preferences
    @Default(true) bool showReadReceipts,
    @Default(true) bool enableNotifications,
    @Default(false) bool enableSounds,
    @Default('auto') String theme, // 'light', 'dark', 'auto'
    // AI preferences
    @Default(0.7) double temperature,
    @Default(2048) int maxTokens,
    @Default(false) bool streamResponses,
    @Default(false) bool webSearchEnabled,

    // Privacy settings
    @Default(true) bool saveConversations,
    @Default(false) bool shareUsageData,

    // Interface preferences
    @Default('comfortable')
    String density, // 'compact', 'comfortable', 'spacious'
    @Default('en') String language,

    // Accessibility settings
    @Default(false) bool reduceMotion,
    @Default(true) bool hapticFeedback,

    // Model preferences
    String? defaultModelId,

    // Advanced settings
    @Default({}) Map<String, dynamic> customSettings,
  }) = _UserSettings;

  factory UserSettings.fromJson(Map<String, dynamic> json) =>
      _$UserSettingsFromJson(json);
}
