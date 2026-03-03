/// Keys previously stored in SharedPreferences. Centralized so Hive-based
/// storage and migration logic stay aligned.
final class PreferenceKeys {
  static const String reduceMotion = 'reduce_motion';
  static const String animationSpeed = 'animation_speed';
  static const String hapticFeedback = 'haptic_feedback';
  static const String highContrast = 'high_contrast';
  static const String largeText = 'large_text';
  static const String darkMode = 'dark_mode';
  static const String defaultModel = 'default_model';
  static const String voiceLocaleId = 'voice_locale_id';
  static const String voiceHoldToTalk = 'voice_hold_to_talk';
  static const String voiceAutoSendFinal = 'voice_auto_send_final';
  static const String voiceSttPreference = 'voice_stt_preference';
  static const String socketTransportMode = 'socket_transport_mode';
  static const String quickPills = 'quick_pills';
  static const String sendOnEnterKey = 'send_on_enter';
  static const String activeServerId = 'active_server_id';
  static const String themeMode = 'theme_mode';
  static const String themePalette = 'theme_palette_v1';
  static const String localeCode = 'locale_code_v1';
  static const String onboardingSeen = 'onboarding_seen_v1';
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

  // Drawer section collapsed states
  static const String drawerShowPinned = 'drawer_show_pinned';
  static const String drawerShowFolders = 'drawer_show_folders';
  static const String drawerShowRecent = 'drawer_show_recent';
}

final class LegacyPreferenceKeys {
  static const String attachmentUploadQueue = 'attachment_upload_queue';
  static const String taskQueue = 'outbound_task_queue_v1';
}
