/// Keys previously stored in SharedPreferences. Centralized so Hive-based
/// storage and migration logic stay aligned.
final class PreferenceKeys {
  static const String reduceMotion = 'reduce_motion';
  static const String animationSpeed = 'animation_speed';
  static const String hapticFeedback = 'haptic_feedback';
  static const String disableHapticsWhileStreaming =
      'disable_haptics_while_streaming';
  static const String highContrast = 'high_contrast';
  static const String darkMode = 'dark_mode';
  static const String defaultModel = 'default_model';
  static const String voiceLocaleId = 'voice_locale_id';
  static const String voiceHoldToTalk = 'voice_hold_to_talk';
  static const String voiceAutoSendFinal = 'voice_auto_send_final';
  static const String voiceSttPreference = 'voice_stt_preference';
  static const String voiceSttLanguageCode = 'voice_stt_language_code';
  static const String socketTransportMode = 'socket_transport_mode';
  static const String quickPills = 'quick_pills';
  static const String chatWebSearchEnabled = 'chat_web_search_enabled';
  static const String chatImageGenerationEnabled =
      'chat_image_generation_enabled';
  static const String chatCodeInterpreterEnabled =
      'chat_code_interpreter_enabled';
  static const String sendOnEnterKey = 'send_on_enter';
  static const String activeServerId = 'active_server_id';
  static const String themeMode = 'theme_mode';
  static const String themePalette = 'theme_palette_v1';
  static const String localeCode = 'locale_code_v1';
  static const String reviewerMode = 'reviewer_mode_v1';
  static const String ttsVoice = 'tts_voice';
  static const String ttsSpeechRate = 'tts_speech_rate';
  static const String ttsPitch = 'tts_pitch';
  static const String ttsVolume = 'tts_volume';
  static const String ttsEngine = 'tts_engine'; // 'device' | 'server'
  static const String ttsServerVoiceId = 'tts_server_voice_id';
  static const String ttsServerVoiceName = 'tts_server_voice_name';
  static const String voiceSilenceDuration = 'voice_silence_duration';
  static const String androidAssistantTrigger = 'android_assistant_trigger';
  static const String temporaryChatByDefault = 'temporary_chat_by_default';
  static const String pinnedModels = 'pinned_models';

  // Notifications. The first three mirror Open WebUI's user-settings fields and
  // are synced to the server; the rest are Conduit-only client preferences.
  static const String notificationsEnabled = 'notifications_enabled';
  static const String notificationSound = 'notification_sound';
  static const String notificationSoundAlways = 'notification_sound_always';
  static const String notificationInAppBanner = 'notification_in_app_banner';
  static const String notificationSystem = 'notification_system';
  static const String notificationChatEnabled = 'notification_chat_enabled';
  static const String notificationChannelEnabled =
      'notification_channel_enabled';

  // Drawer section collapsed states
  static const String drawerShowPinned = 'drawer_show_pinned';
  static const String drawerShowFolders = 'drawer_show_folders';
  static const String drawerShowRecent = 'drawer_show_recent';

  /// Notes sidebar tab section visibility (separate from [drawerShowPinned] /
  /// [drawerShowRecent]).
  static const String notesListShowPinned = 'notes_list_show_pinned';
  static const String notesListShowRecent = 'notes_list_show_recent';

  static const String sidebarActiveTab = 'sidebar_active_tab';
  static const String serverFeatureAvailability =
      'server_feature_availability_v1';

  /// One-time gate for the Hive `preferences_v1` → shared_preferences migration
  /// (PR-1 of the Hive removal). Set last, after every key is copied.
  static const String hiveToPrefsMigrationV1 = 'hive_to_prefs_migration_v1';

  /// Prefix for the per-server transport-options cache moved out of the Hive
  /// `caches` box (it needs a synchronous read). Combined with a safe-encoded
  /// server id: `transport_options:<safeServerId>`.
  static const String transportOptionsPrefix = 'transport_options';
}

final class LegacyPreferenceKeys {
  static const String attachmentUploadQueue = 'attachment_upload_queue';
  static const String taskQueue = 'outbound_task_queue_v1';
}
