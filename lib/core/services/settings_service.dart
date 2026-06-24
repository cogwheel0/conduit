import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../persistence/persistence_keys.dart';
import '../persistence/preferences_store.dart';
import 'animation_service.dart';

part 'settings_service.g.dart';

/// Speech-to-text preference selection.
enum SttPreference { deviceOnly, serverOnly }

/// TTS engine selection
enum TtsEngine { device, server }

/// Action to take when the Android digital assistant is triggered.
enum AndroidAssistantTrigger { overlay, newChat, voiceCall }

extension AndroidAssistantTriggerStorage on AndroidAssistantTrigger {
  String get storageValue {
    switch (this) {
      case AndroidAssistantTrigger.overlay:
        return 'overlay';
      case AndroidAssistantTrigger.newChat:
        return 'new_chat';
      case AndroidAssistantTrigger.voiceCall:
        return 'voice_call';
    }
  }
}

/// Service for managing app-wide settings including accessibility preferences
class SettingsService {
  static const int minVoiceSilenceDurationMs = 300;
  static const int defaultVoiceSilenceDurationMs = 2000;
  static const int maxVoiceSilenceDurationMs = 5000;
  static const String _reduceMotionKey = PreferenceKeys.reduceMotion;
  static const String _animationSpeedKey = PreferenceKeys.animationSpeed;
  static const String _hapticFeedbackKey = PreferenceKeys.hapticFeedback;
  static const String _disableHapticsWhileStreamingKey =
      PreferenceKeys.disableHapticsWhileStreaming;
  static const String _highContrastKey = PreferenceKeys.highContrast;
  static const String _darkModeKey = PreferenceKeys.darkMode;
  static const String _defaultModelKey = PreferenceKeys.defaultModel;
  // Voice input settings
  static const String _voiceLocaleKey = PreferenceKeys.voiceLocaleId;
  static const String _voiceHoldToTalkKey = PreferenceKeys.voiceHoldToTalk;
  static const String _voiceAutoSendKey = PreferenceKeys.voiceAutoSendFinal;
  static const String _voiceSttLanguageCodeKey =
      PreferenceKeys.voiceSttLanguageCode;
  // Realtime transport preference
  static const String _socketTransportModeKey =
      PreferenceKeys.socketTransportMode; // 'polling' or 'ws'
  // Quick pill visibility selections (max 2)
  static const String _quickPillsKey = PreferenceKeys
      .quickPills; // StringList of identifiers e.g. ['web','image','tools']
  static const String _chatWebSearchEnabledKey =
      PreferenceKeys.chatWebSearchEnabled;
  static const String _chatImageGenerationEnabledKey =
      PreferenceKeys.chatImageGenerationEnabled;
  static const String _chatCodeInterpreterEnabledKey =
      PreferenceKeys.chatCodeInterpreterEnabled;
  // Chat input behavior
  static const String _sendOnEnterKey = PreferenceKeys.sendOnEnterKey;
  // Voice silence duration for auto-stop (milliseconds)
  static const String _voiceSilenceDurationKey =
      PreferenceKeys.voiceSilenceDuration;
  static const String _androidAssistantTriggerKey =
      PreferenceKeys.androidAssistantTrigger;
  static const String _pinnedModelsKey = PreferenceKeys.pinnedModels;
  // Notifications
  static const String _notificationsEnabledKey =
      PreferenceKeys.notificationsEnabled;
  static const String _notificationSoundKey = PreferenceKeys.notificationSound;
  static const String _notificationSoundAlwaysKey =
      PreferenceKeys.notificationSoundAlways;
  static const String _notificationInAppBannerKey =
      PreferenceKeys.notificationInAppBanner;
  static const String _notificationSystemKey = PreferenceKeys.notificationSystem;
  static const String _notificationChatEnabledKey =
      PreferenceKeys.notificationChatEnabled;
  static const String _notificationChannelEnabledKey =
      PreferenceKeys.notificationChannelEnabled;

  static T? _getPreference<T>(String key) => PreferencesStore.get<T>(key);

  static Future<void> _putPreference(String key, Object? value) =>
      PreferencesStore.put(key, value);

  /// Get reduced motion preference
  static Future<bool> getReduceMotion() {
    final value = _getPreference<bool>(_reduceMotionKey);
    return Future.value(value ?? false);
  }

  /// Set reduced motion preference
  static Future<void> setReduceMotion(bool value) {
    return _putPreference(_reduceMotionKey, value);
  }

  /// Get animation speed multiplier (0.5 - 2.0)
  static Future<double> getAnimationSpeed() {
    final value = _getPreference<num>(_animationSpeedKey);
    return Future.value((value?.toDouble() ?? 1.0).clamp(0.5, 2.0));
  }

  /// Set animation speed multiplier
  static Future<void> setAnimationSpeed(double value) {
    final sanitized = value.clamp(0.5, 2.0).toDouble();
    return _putPreference(_animationSpeedKey, sanitized);
  }

  /// Get haptic feedback preference
  static Future<bool> getHapticFeedback() {
    final value = _getPreference<bool>(_hapticFeedbackKey);
    return Future.value(value ?? true);
  }

  /// Set haptic feedback preference
  static Future<void> setHapticFeedback(bool value) {
    return _putPreference(_hapticFeedbackKey, value);
  }

  /// Get streaming haptics suppression preference.
  static Future<bool> getDisableHapticsWhileStreaming() {
    final value = _getPreference<bool>(_disableHapticsWhileStreamingKey);
    return Future.value(value ?? false);
  }

  /// Set streaming haptics suppression preference.
  static Future<void> setDisableHapticsWhileStreaming(bool value) {
    return _putPreference(_disableHapticsWhileStreamingKey, value);
  }

  // -- Notifications --------------------------------------------------------

  /// Master notifications toggle. Defaults to `false`: notifications stay off
  /// until the user opts in (which is also when permission is requested).
  static Future<bool> getNotificationsEnabled() {
    return Future.value(
      _getPreference<bool>(_notificationsEnabledKey) ?? false,
    );
  }

  static Future<void> setNotificationsEnabled(bool value) {
    return _putPreference(_notificationsEnabledKey, value);
  }

  static Future<bool> getNotificationSound() {
    return Future.value(_getPreference<bool>(_notificationSoundKey) ?? true);
  }

  static Future<void> setNotificationSound(bool value) {
    return _putPreference(_notificationSoundKey, value);
  }

  static Future<bool> getNotificationSoundAlways() {
    return Future.value(
      _getPreference<bool>(_notificationSoundAlwaysKey) ?? false,
    );
  }

  static Future<void> setNotificationSoundAlways(bool value) {
    return _putPreference(_notificationSoundAlwaysKey, value);
  }

  static Future<bool> getNotificationInAppBanner() {
    return Future.value(
      _getPreference<bool>(_notificationInAppBannerKey) ?? true,
    );
  }

  static Future<void> setNotificationInAppBanner(bool value) {
    return _putPreference(_notificationInAppBannerKey, value);
  }

  static Future<bool> getNotificationSystem() {
    return Future.value(_getPreference<bool>(_notificationSystemKey) ?? true);
  }

  static Future<void> setNotificationSystem(bool value) {
    return _putPreference(_notificationSystemKey, value);
  }

  static Future<bool> getNotificationChatEnabled() {
    return Future.value(
      _getPreference<bool>(_notificationChatEnabledKey) ?? true,
    );
  }

  static Future<void> setNotificationChatEnabled(bool value) {
    return _putPreference(_notificationChatEnabledKey, value);
  }

  static Future<bool> getNotificationChannelEnabled() {
    return Future.value(
      _getPreference<bool>(_notificationChannelEnabledKey) ?? true,
    );
  }

  static Future<void> setNotificationChannelEnabled(bool value) {
    return _putPreference(_notificationChannelEnabledKey, value);
  }

  /// Get high contrast preference
  static Future<bool> getHighContrast() {
    final value = _getPreference<bool>(_highContrastKey);
    return Future.value(value ?? false);
  }

  /// Set high contrast preference
  static Future<void> setHighContrast(bool value) {
    return _putPreference(_highContrastKey, value);
  }

  /// Get dark mode preference
  static Future<bool> getDarkMode() {
    final value = _getPreference<bool>(_darkModeKey);
    return Future.value(value ?? true);
  }

  /// Set dark mode preference
  static Future<void> setDarkMode(bool value) {
    return _putPreference(_darkModeKey, value);
  }

  /// Get default model preference
  static Future<String?> getDefaultModel() {
    final value = _getPreference<String>(_defaultModelKey);
    return Future.value(value);
  }

  /// Set default model preference
  static Future<void> setDefaultModel(String? modelId) {
    if (modelId != null) {
      return PreferencesStore.put(_defaultModelKey, modelId);
    }
    return PreferencesStore.remove(_defaultModelKey);
  }

  /// Load all settings
  static Future<AppSettings> loadSettings() {
    return Future.value(
      PreferencesStore.isReady ? _loadSettingsSync() : const AppSettings(),
    );
  }

  /// Save all settings
  static Future<void> saveSettings(AppSettings settings) async {
    if (!PreferencesStore.isReady) return;
    final updates = <String, Object?>{
      _reduceMotionKey: settings.reduceMotion,
      _animationSpeedKey: settings.animationSpeed,
      _hapticFeedbackKey: settings.hapticFeedback,
      _disableHapticsWhileStreamingKey: settings.disableHapticsWhileStreaming,
      _highContrastKey: settings.highContrast,
      _darkModeKey: settings.darkMode,
      _voiceHoldToTalkKey: settings.voiceHoldToTalk,
      _voiceAutoSendKey: settings.voiceAutoSendFinal,
      _socketTransportModeKey: settings.socketTransportMode,
      _quickPillsKey: settings.quickPills.toList(),
      _sendOnEnterKey: settings.sendOnEnter,
      PreferenceKeys.ttsSpeechRate: settings.ttsSpeechRate,
      PreferenceKeys.ttsPitch: settings.ttsPitch,
      PreferenceKeys.ttsVolume: settings.ttsVolume,
      PreferenceKeys.ttsEngine: settings.ttsEngine.name,
      PreferenceKeys.voiceSttPreference: settings.sttPreference.name,
      _voiceSilenceDurationKey: settings.voiceSilenceDuration,
      // Lands in shared_preferences as `flutter.android_assistant_trigger`,
      // which the native Android voice-interaction session reads directly.
      _androidAssistantTriggerKey:
          settings.androidAssistantTrigger.storageValue,
      PreferenceKeys.temporaryChatByDefault: settings.temporaryChatByDefault,
      _pinnedModelsKey: settings.pinnedModels.toList(),
      _notificationsEnabledKey: settings.notificationsEnabled,
      _notificationSoundKey: settings.notificationSound,
      _notificationSoundAlwaysKey: settings.notificationSoundAlways,
      _notificationInAppBannerKey: settings.notificationInAppBanner,
      _notificationSystemKey: settings.notificationSystem,
      _notificationChatEnabledKey: settings.notificationChatEnabled,
      _notificationChannelEnabledKey: settings.notificationChannelEnabled,
    };

    await PreferencesStore.putAll(updates);

    await _putOrRemove(_chatWebSearchEnabledKey, settings.chatWebSearchEnabled);
    await _putOrRemove(
      _chatImageGenerationEnabledKey,
      settings.chatImageGenerationEnabled,
    );
    await _putOrRemove(
      _chatCodeInterpreterEnabledKey,
      settings.chatCodeInterpreterEnabled,
    );
    await _putOrRemove(_defaultModelKey, settings.defaultModel);
    await _putOrRemove(
      _voiceLocaleKey,
      (settings.voiceLocaleId?.isNotEmpty ?? false)
          ? settings.voiceLocaleId
          : null,
    );
    await _putOrRemove(
      _voiceSttLanguageCodeKey,
      normalizeSttLanguageCode(settings.sttLanguageCode),
    );
    await _putOrRemove(
      PreferenceKeys.ttsVoice,
      (settings.ttsVoice?.isNotEmpty ?? false) ? settings.ttsVoice : null,
    );
    await _putOrRemove(
      PreferenceKeys.ttsServerVoiceId,
      (settings.ttsServerVoiceId?.isNotEmpty ?? false)
          ? settings.ttsServerVoiceId
          : null,
    );
    await _putOrRemove(
      PreferenceKeys.ttsServerVoiceName,
      (settings.ttsServerVoiceName?.isNotEmpty ?? false)
          ? settings.ttsServerVoiceName
          : null,
    );
  }

  static Future<void> _putOrRemove(String key, Object? value) {
    return value == null
        ? PreferencesStore.remove(key)
        : PreferencesStore.put(key, value);
  }

  static TtsEngine _parseTtsEngine(String? raw) {
    switch ((raw ?? '').toLowerCase()) {
      case 'server':
        return TtsEngine.server;
      case 'device':
        return TtsEngine.device;
      default:
        return TtsEngine.device;
    }
  }

  static SttPreference _parseSttPreference(String? raw) {
    switch ((raw ?? '').toLowerCase()) {
      case 'deviceonly':
      case 'device_only':
      case 'device':
        return SttPreference.deviceOnly;
      case 'serveronly':
      case 'server_only':
      case 'server':
        return SttPreference.serverOnly;
      default:
        return SttPreference.deviceOnly;
    }
  }

  static AndroidAssistantTrigger _parseAndroidAssistantTrigger(String? raw) {
    switch ((raw ?? '').toLowerCase()) {
      case 'new_chat':
      case 'newchat':
        return AndroidAssistantTrigger.newChat;
      case 'voice_call':
      case 'voicecall':
        return AndroidAssistantTrigger.voiceCall;
      case 'overlay':
      default:
        return AndroidAssistantTrigger.overlay;
    }
  }

  static String? normalizeSttLanguageCode(String? raw) {
    final trimmed = raw?.trim();
    if (isSttLanguageAutoInput(trimmed)) {
      return null;
    }

    final lower = trimmed!.replaceAll('_', '-').toLowerCase();
    final primary = lower.split('-').first;
    if (RegExp(r'^[a-z]{2}$').hasMatch(primary)) {
      return primary;
    }
    return null;
  }

  static bool isSttLanguageAutoInput(String? raw) {
    final lower = raw?.trim().toLowerCase();
    return lower == null ||
        lower.isEmpty ||
        lower == 'auto' ||
        lower == 'default' ||
        lower == 'system';
  }

  // Voice input specific settings
  static Future<String?> getVoiceLocaleId() {
    final value = _getPreference<String>(_voiceLocaleKey);
    return Future.value(value);
  }

  static Future<void> setVoiceLocaleId(String? localeId) {
    return _putOrRemove(
      _voiceLocaleKey,
      (localeId?.isNotEmpty ?? false) ? localeId : null,
    );
  }

  static Future<String?> getSttLanguageCode() {
    final value = _getPreference<String>(_voiceSttLanguageCodeKey);
    return Future.value(normalizeSttLanguageCode(value));
  }

  static Future<void> setSttLanguageCode(String? languageCode) {
    return _putOrRemove(
      _voiceSttLanguageCodeKey,
      normalizeSttLanguageCode(languageCode),
    );
  }

  static Future<bool> getVoiceHoldToTalk() {
    final value = _getPreference<bool>(_voiceHoldToTalkKey);
    return Future.value(value ?? false);
  }

  static Future<void> setVoiceHoldToTalk(bool value) {
    return _putPreference(_voiceHoldToTalkKey, value);
  }

  static Future<bool> getVoiceAutoSendFinal() {
    final value = _getPreference<bool>(_voiceAutoSendKey);
    return Future.value(value ?? false);
  }

  static Future<void> setVoiceAutoSendFinal(bool value) {
    return _putPreference(_voiceAutoSendKey, value);
  }

  /// Transport mode: 'polling' (HTTP polling + WebSocket upgrade) or 'ws'
  static Future<String> getSocketTransportMode() {
    final raw = _getPreference<String>(_socketTransportModeKey);
    if (raw == null) {
      return Future.value('ws');
    }
    if (raw == 'auto') {
      return Future.value('polling');
    }
    if (raw != 'polling' && raw != 'ws') {
      return Future.value('ws');
    }
    return Future.value(raw);
  }

  static Future<void> setSocketTransportMode(String mode) {
    if (mode == 'auto') {
      mode = 'polling';
    }
    if (mode != 'polling' && mode != 'ws') {
      mode = 'polling';
    }
    return _putPreference(_socketTransportModeKey, mode);
  }

  // Quick Pills (visibility)
  static Future<List<String>> getQuickPills() {
    final stored = _getPreference<List<dynamic>>(_quickPillsKey);
    if (stored == null) {
      return Future.value(const []);
    }
    return Future.value(List<String>.from(stored));
  }

  static Future<void> setQuickPills(List<String> pills) {
    return _putPreference(_quickPillsKey, pills.toList());
  }

  static Future<bool?> getChatWebSearchEnabled() {
    return Future.value(PreferencesStore.getBool(_chatWebSearchEnabledKey));
  }

  static Future<void> setChatWebSearchEnabled(bool? value) {
    return _putOrRemove(_chatWebSearchEnabledKey, value);
  }

  static Future<bool?> getChatImageGenerationEnabled() {
    return Future.value(
      PreferencesStore.getBool(_chatImageGenerationEnabledKey),
    );
  }

  static Future<void> setChatImageGenerationEnabled(bool? value) {
    return _putOrRemove(_chatImageGenerationEnabledKey, value);
  }

  static Future<bool?> getChatCodeInterpreterEnabled() {
    return Future.value(
      PreferencesStore.getBool(_chatCodeInterpreterEnabledKey),
    );
  }

  static Future<void> setChatCodeInterpreterEnabled(bool? value) {
    return _putOrRemove(_chatCodeInterpreterEnabledKey, value);
  }

  // Chat input behavior
  static Future<bool> getSendOnEnter() {
    final value = _getPreference<bool>(_sendOnEnterKey);
    return Future.value(value ?? false);
  }

  static Future<void> setSendOnEnter(bool value) {
    return _putPreference(_sendOnEnterKey, value);
  }

  static Future<bool> getTemporaryChatByDefault() {
    final value = _getPreference<bool>(PreferenceKeys.temporaryChatByDefault);
    return Future.value(value ?? false);
  }

  static Future<void> setTemporaryChatByDefault(bool value) {
    return _putPreference(PreferenceKeys.temporaryChatByDefault, value);
  }

  static List<String> sanitizePinnedModels(Iterable<String> modelIds) {
    final sanitized = <String>[];
    final seen = <String>{};
    for (final modelId in modelIds) {
      final trimmed = modelId.trim();
      if (trimmed.isEmpty || !seen.add(trimmed)) {
        continue;
      }
      sanitized.add(trimmed);
    }
    return sanitized;
  }

  static Future<List<String>> getPinnedModels() {
    final raw = PreferencesStore.getStringList(_pinnedModelsKey);
    if (raw == null) {
      return Future.value(const []);
    }
    return Future.value(sanitizePinnedModels(raw));
  }

  static Future<void> setPinnedModels(List<String> modelIds) {
    return _putPreference(_pinnedModelsKey, sanitizePinnedModels(modelIds));
  }

  static Future<int> getVoiceSilenceDuration() {
    final value = _getPreference<int>(_voiceSilenceDurationKey);
    return Future.value(
      (value ?? defaultVoiceSilenceDurationMs).clamp(
        minVoiceSilenceDurationMs,
        maxVoiceSilenceDurationMs,
      ),
    );
  }

  static Future<void> setVoiceSilenceDuration(int milliseconds) {
    final sanitized = milliseconds.clamp(
      minVoiceSilenceDurationMs,
      maxVoiceSilenceDurationMs,
    );
    return _putPreference(_voiceSilenceDurationKey, sanitized);
  }

  static Future<void> setAndroidAssistantTrigger(
    AndroidAssistantTrigger trigger,
  ) async {
    // Stored in shared_preferences as `flutter.android_assistant_trigger`; the
    // native Android voice-interaction session (ConduitVoiceInteractionSession)
    // reads that key directly, so no separate native dual-write is needed.
    await _putPreference(_androidAssistantTriggerKey, trigger.storageValue);
  }

  /// Get effective animation duration considering all settings
  static Duration getEffectiveAnimationDuration(
    BuildContext context,
    Duration defaultDuration,
    AppSettings settings,
  ) {
    // Check system reduced motion first
    if (MediaQuery.of(context).disableAnimations || settings.reduceMotion) {
      return Duration.zero;
    }

    // Apply user animation speed preference
    final adjustedMs =
        (defaultDuration.inMilliseconds / settings.animationSpeed).round();
    return Duration(milliseconds: adjustedMs.clamp(50, 1000));
  }

  static AppSettings _loadSettingsSync() {
    return AppSettings(
      reduceMotion: PreferencesStore.get<bool>(_reduceMotionKey) ?? false,
      animationSpeed:
          PreferencesStore.get<num>(_animationSpeedKey)?.toDouble() ?? 1.0,
      hapticFeedback: PreferencesStore.get<bool>(_hapticFeedbackKey) ?? true,
      disableHapticsWhileStreaming:
          PreferencesStore.get<bool>(_disableHapticsWhileStreamingKey) ?? false,
      highContrast: PreferencesStore.get<bool>(_highContrastKey) ?? false,
      darkMode: PreferencesStore.get<bool>(_darkModeKey) ?? true,
      defaultModel: PreferencesStore.get<String>(_defaultModelKey),
      voiceLocaleId: PreferencesStore.get<String>(_voiceLocaleKey),
      voiceHoldToTalk: PreferencesStore.get<bool>(_voiceHoldToTalkKey) ?? false,
      voiceAutoSendFinal:
          PreferencesStore.get<bool>(_voiceAutoSendKey) ?? false,
      socketTransportMode:
          PreferencesStore.get<String>(_socketTransportModeKey) ?? 'ws',
      quickPills: PreferencesStore.getStringList(_quickPillsKey) ?? const [],
      chatWebSearchEnabled: PreferencesStore.get<bool>(_chatWebSearchEnabledKey),
      chatImageGenerationEnabled: PreferencesStore.get<bool>(
        _chatImageGenerationEnabledKey,
      ),
      chatCodeInterpreterEnabled: PreferencesStore.get<bool>(
        _chatCodeInterpreterEnabledKey,
      ),
      sendOnEnter: PreferencesStore.get<bool>(_sendOnEnterKey) ?? false,
      ttsVoice: PreferencesStore.get<String>(PreferenceKeys.ttsVoice),
      ttsSpeechRate:
          PreferencesStore.get<num>(PreferenceKeys.ttsSpeechRate)?.toDouble() ??
          0.5,
      ttsPitch:
          PreferencesStore.get<num>(PreferenceKeys.ttsPitch)?.toDouble() ?? 1.0,
      ttsVolume:
          PreferencesStore.get<num>(PreferenceKeys.ttsVolume)?.toDouble() ?? 1.0,
      ttsEngine: _parseTtsEngine(
        PreferencesStore.get<String>(PreferenceKeys.ttsEngine),
      ),
      ttsServerVoiceId: PreferencesStore.get<String>(
        PreferenceKeys.ttsServerVoiceId,
      ),
      ttsServerVoiceName: PreferencesStore.get<String>(
        PreferenceKeys.ttsServerVoiceName,
      ),
      sttPreference: _parseSttPreference(
        PreferencesStore.get<String>(PreferenceKeys.voiceSttPreference),
      ),
      sttLanguageCode: normalizeSttLanguageCode(
        PreferencesStore.get<String>(_voiceSttLanguageCodeKey),
      ),
      androidAssistantTrigger: _parseAndroidAssistantTrigger(
        PreferencesStore.get<String>(_androidAssistantTriggerKey),
      ),
      voiceSilenceDuration:
          (PreferencesStore.get<int>(_voiceSilenceDurationKey) ??
                  defaultVoiceSilenceDurationMs)
              .clamp(minVoiceSilenceDurationMs, maxVoiceSilenceDurationMs),
      temporaryChatByDefault:
          PreferencesStore.get<bool>(PreferenceKeys.temporaryChatByDefault) ??
          false,
      pinnedModels: sanitizePinnedModels(
        PreferencesStore.getStringList(_pinnedModelsKey) ?? const <String>[],
      ),
      notificationsEnabled:
          PreferencesStore.get<bool>(_notificationsEnabledKey) ?? false,
      notificationSound:
          PreferencesStore.get<bool>(_notificationSoundKey) ?? true,
      notificationSoundAlways:
          PreferencesStore.get<bool>(_notificationSoundAlwaysKey) ?? false,
      notificationInAppBanner:
          PreferencesStore.get<bool>(_notificationInAppBannerKey) ?? true,
      notificationSystem:
          PreferencesStore.get<bool>(_notificationSystemKey) ?? true,
      notificationChatEnabled:
          PreferencesStore.get<bool>(_notificationChatEnabledKey) ?? true,
      notificationChannelEnabled:
          PreferencesStore.get<bool>(_notificationChannelEnabledKey) ?? true,
    );
  }
}

/// Sentinel class to detect when defaultModel parameter is not provided
class _DefaultValue {
  const _DefaultValue();
}

/// Data class for app settings
class AppSettings {
  final bool reduceMotion;
  final double animationSpeed;
  final bool hapticFeedback;
  final bool disableHapticsWhileStreaming;
  final bool highContrast;
  final bool darkMode;
  final String? defaultModel;
  final String? voiceLocaleId;
  final bool voiceHoldToTalk;
  final bool voiceAutoSendFinal;
  final String socketTransportMode; // 'polling' or 'ws'
  final List<String> quickPills; // e.g., ['web','image']
  final bool? chatWebSearchEnabled;
  final bool? chatImageGenerationEnabled;
  final bool? chatCodeInterpreterEnabled;
  final bool sendOnEnter;
  final SttPreference sttPreference;
  final String? sttLanguageCode;
  final String? ttsVoice;
  final double ttsSpeechRate;
  final double ttsPitch;
  final double ttsVolume;
  final TtsEngine ttsEngine;
  final String? ttsServerVoiceId;
  final String? ttsServerVoiceName;
  final AndroidAssistantTrigger androidAssistantTrigger;
  final int voiceSilenceDuration;
  final bool temporaryChatByDefault;
  final List<String> pinnedModels;
  // Notifications (see PreferenceKeys for which are server-synced).
  final bool notificationsEnabled;
  final bool notificationSound;
  final bool notificationSoundAlways;
  final bool notificationInAppBanner;
  final bool notificationSystem;
  final bool notificationChatEnabled;
  final bool notificationChannelEnabled;
  const AppSettings({
    this.reduceMotion = false,
    this.animationSpeed = 1.0,
    this.hapticFeedback = true,
    this.disableHapticsWhileStreaming = false,
    this.highContrast = false,
    this.darkMode = true,
    this.defaultModel,
    this.voiceLocaleId,
    this.voiceHoldToTalk = false,
    this.voiceAutoSendFinal = false,
    this.socketTransportMode = 'ws',
    this.quickPills = const [],
    this.chatWebSearchEnabled,
    this.chatImageGenerationEnabled,
    this.chatCodeInterpreterEnabled,
    this.sendOnEnter = false,
    this.sttPreference = SttPreference.deviceOnly,
    this.sttLanguageCode,
    this.ttsVoice,
    this.ttsSpeechRate = 0.5,
    this.ttsPitch = 1.0,
    this.ttsVolume = 1.0,
    this.ttsEngine = TtsEngine.device,
    this.ttsServerVoiceId,
    this.ttsServerVoiceName,
    this.androidAssistantTrigger = AndroidAssistantTrigger.overlay,
    this.voiceSilenceDuration = SettingsService.defaultVoiceSilenceDurationMs,
    this.temporaryChatByDefault = false,
    this.pinnedModels = const [],
    this.notificationsEnabled = false,
    this.notificationSound = true,
    this.notificationSoundAlways = false,
    this.notificationInAppBanner = true,
    this.notificationSystem = true,
    this.notificationChatEnabled = true,
    this.notificationChannelEnabled = true,
  });

  AppSettings copyWith({
    bool? reduceMotion,
    double? animationSpeed,
    bool? hapticFeedback,
    bool? disableHapticsWhileStreaming,
    bool? highContrast,
    bool? darkMode,
    Object? defaultModel = const _DefaultValue(),
    Object? voiceLocaleId = const _DefaultValue(),
    bool? voiceHoldToTalk,
    bool? voiceAutoSendFinal,
    String? socketTransportMode,
    List<String>? quickPills,
    bool? chatWebSearchEnabled,
    bool? chatImageGenerationEnabled,
    bool? chatCodeInterpreterEnabled,
    bool? sendOnEnter,
    SttPreference? sttPreference,
    Object? sttLanguageCode = const _DefaultValue(),
    Object? ttsVoice = const _DefaultValue(),
    double? ttsSpeechRate,
    double? ttsPitch,
    double? ttsVolume,
    TtsEngine? ttsEngine,
    Object? ttsServerVoiceId = const _DefaultValue(),
    Object? ttsServerVoiceName = const _DefaultValue(),
    int? voiceSilenceDuration,
    AndroidAssistantTrigger? androidAssistantTrigger,
    bool? temporaryChatByDefault,
    List<String>? pinnedModels,
    bool? notificationsEnabled,
    bool? notificationSound,
    bool? notificationSoundAlways,
    bool? notificationInAppBanner,
    bool? notificationSystem,
    bool? notificationChatEnabled,
    bool? notificationChannelEnabled,
  }) {
    return AppSettings(
      reduceMotion: reduceMotion ?? this.reduceMotion,
      animationSpeed: animationSpeed ?? this.animationSpeed,
      hapticFeedback: hapticFeedback ?? this.hapticFeedback,
      disableHapticsWhileStreaming:
          disableHapticsWhileStreaming ?? this.disableHapticsWhileStreaming,
      highContrast: highContrast ?? this.highContrast,
      darkMode: darkMode ?? this.darkMode,
      defaultModel: defaultModel is _DefaultValue
          ? this.defaultModel
          : defaultModel as String?,
      voiceLocaleId: voiceLocaleId is _DefaultValue
          ? this.voiceLocaleId
          : voiceLocaleId as String?,
      voiceHoldToTalk: voiceHoldToTalk ?? this.voiceHoldToTalk,
      voiceAutoSendFinal: voiceAutoSendFinal ?? this.voiceAutoSendFinal,
      socketTransportMode: socketTransportMode ?? this.socketTransportMode,
      quickPills: quickPills ?? this.quickPills,
      chatWebSearchEnabled: chatWebSearchEnabled ?? this.chatWebSearchEnabled,
      chatImageGenerationEnabled:
          chatImageGenerationEnabled ?? this.chatImageGenerationEnabled,
      chatCodeInterpreterEnabled:
          chatCodeInterpreterEnabled ?? this.chatCodeInterpreterEnabled,
      sendOnEnter: sendOnEnter ?? this.sendOnEnter,
      sttPreference: sttPreference ?? this.sttPreference,
      sttLanguageCode: sttLanguageCode is _DefaultValue
          ? this.sttLanguageCode
          : sttLanguageCode as String?,
      ttsVoice: ttsVoice is _DefaultValue ? this.ttsVoice : ttsVoice as String?,
      ttsSpeechRate: ttsSpeechRate ?? this.ttsSpeechRate,
      ttsPitch: ttsPitch ?? this.ttsPitch,
      ttsVolume: ttsVolume ?? this.ttsVolume,
      ttsEngine: ttsEngine ?? this.ttsEngine,
      ttsServerVoiceId: ttsServerVoiceId is _DefaultValue
          ? this.ttsServerVoiceId
          : ttsServerVoiceId as String?,
      ttsServerVoiceName: ttsServerVoiceName is _DefaultValue
          ? this.ttsServerVoiceName
          : ttsServerVoiceName as String?,
      androidAssistantTrigger:
          androidAssistantTrigger ?? this.androidAssistantTrigger,
      voiceSilenceDuration: voiceSilenceDuration ?? this.voiceSilenceDuration,
      temporaryChatByDefault:
          temporaryChatByDefault ?? this.temporaryChatByDefault,
      pinnedModels: pinnedModels ?? this.pinnedModels,
      notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
      notificationSound: notificationSound ?? this.notificationSound,
      notificationSoundAlways:
          notificationSoundAlways ?? this.notificationSoundAlways,
      notificationInAppBanner:
          notificationInAppBanner ?? this.notificationInAppBanner,
      notificationSystem: notificationSystem ?? this.notificationSystem,
      notificationChatEnabled:
          notificationChatEnabled ?? this.notificationChatEnabled,
      notificationChannelEnabled:
          notificationChannelEnabled ?? this.notificationChannelEnabled,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AppSettings &&
        other.reduceMotion == reduceMotion &&
        other.animationSpeed == animationSpeed &&
        other.hapticFeedback == hapticFeedback &&
        other.disableHapticsWhileStreaming == disableHapticsWhileStreaming &&
        other.highContrast == highContrast &&
        other.darkMode == darkMode &&
        other.defaultModel == defaultModel &&
        other.voiceLocaleId == voiceLocaleId &&
        other.voiceHoldToTalk == voiceHoldToTalk &&
        other.voiceAutoSendFinal == voiceAutoSendFinal &&
        other.chatWebSearchEnabled == chatWebSearchEnabled &&
        other.chatImageGenerationEnabled == chatImageGenerationEnabled &&
        other.chatCodeInterpreterEnabled == chatCodeInterpreterEnabled &&
        other.sttPreference == sttPreference &&
        other.sttLanguageCode == sttLanguageCode &&
        other.sendOnEnter == sendOnEnter &&
        other.ttsVoice == ttsVoice &&
        other.ttsSpeechRate == ttsSpeechRate &&
        other.ttsPitch == ttsPitch &&
        other.ttsVolume == ttsVolume &&
        other.ttsEngine == ttsEngine &&
        other.ttsServerVoiceId == ttsServerVoiceId &&
        other.ttsServerVoiceName == ttsServerVoiceName &&
        other.androidAssistantTrigger == androidAssistantTrigger &&
        other.voiceSilenceDuration == voiceSilenceDuration &&
        other.temporaryChatByDefault == temporaryChatByDefault &&
        other.notificationsEnabled == notificationsEnabled &&
        other.notificationSound == notificationSound &&
        other.notificationSoundAlways == notificationSoundAlways &&
        other.notificationInAppBanner == notificationInAppBanner &&
        other.notificationSystem == notificationSystem &&
        other.notificationChatEnabled == notificationChatEnabled &&
        other.notificationChannelEnabled == notificationChannelEnabled &&
        _listEquals(other.pinnedModels, pinnedModels) &&
        _listEquals(other.quickPills, quickPills);
    // socketTransportMode intentionally not included in == to avoid frequent rebuilds
  }

  @override
  int get hashCode {
    return Object.hashAll([
      reduceMotion,
      animationSpeed,
      hapticFeedback,
      disableHapticsWhileStreaming,
      highContrast,
      darkMode,
      defaultModel,
      voiceLocaleId,
      voiceHoldToTalk,
      voiceAutoSendFinal,
      chatWebSearchEnabled,
      chatImageGenerationEnabled,
      chatCodeInterpreterEnabled,
      sttPreference,
      sttLanguageCode,
      sendOnEnter,
      ttsVoice,
      ttsSpeechRate,
      ttsPitch,
      ttsVolume,
      ttsEngine,
      ttsServerVoiceId,
      ttsServerVoiceName,
      androidAssistantTrigger,
      voiceSilenceDuration,
      temporaryChatByDefault,
      notificationsEnabled,
      notificationSound,
      notificationSoundAlways,
      notificationInAppBanner,
      notificationSystem,
      notificationChatEnabled,
      notificationChannelEnabled,
      Object.hashAllUnordered(quickPills),
      Object.hashAll(pinnedModels),
    ]);
  }
}

bool _listEquals(List<String> a, List<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Provider for app settings
@Riverpod(keepAlive: true)
class AppSettingsNotifier extends _$AppSettingsNotifier {
  Future<void>? _pendingLoad;

  @override
  AppSettings build() {
    if (PreferencesStore.isReady) {
      return SettingsService._loadSettingsSync();
    }

    _pendingLoad ??= _hydrateFromPrefs();
    return const AppSettings();
  }

  Future<void> _hydrateFromPrefs() async {
    try {
      await PreferencesStore.ensureInitialized();
      if (!ref.mounted) return;
      state = SettingsService._loadSettingsSync();
    } catch (error, stackTrace) {
      developer.log(
        'Failed to hydrate settings',
        name: 'AppSettingsNotifier',
        level: 1000,
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _pendingLoad = null;
    }
  }

  Future<void> setReduceMotion(bool value) async {
    state = state.copyWith(reduceMotion: value);
    await SettingsService.setReduceMotion(value);
  }

  Future<void> setAnimationSpeed(double value) async {
    state = state.copyWith(animationSpeed: value);
    await SettingsService.setAnimationSpeed(value);
  }

  Future<void> setHapticFeedback(bool value) async {
    state = state.copyWith(hapticFeedback: value);
    await SettingsService.setHapticFeedback(value);
  }

  Future<void> setDisableHapticsWhileStreaming(bool value) async {
    state = state.copyWith(disableHapticsWhileStreaming: value);
    await SettingsService.setDisableHapticsWhileStreaming(value);
  }

  Future<void> setNotificationsEnabled(bool value) async {
    state = state.copyWith(notificationsEnabled: value);
    await SettingsService.setNotificationsEnabled(value);
  }

  Future<void> setNotificationSound(bool value) async {
    state = state.copyWith(notificationSound: value);
    await SettingsService.setNotificationSound(value);
  }

  Future<void> setNotificationSoundAlways(bool value) async {
    state = state.copyWith(notificationSoundAlways: value);
    await SettingsService.setNotificationSoundAlways(value);
  }

  Future<void> setNotificationInAppBanner(bool value) async {
    state = state.copyWith(notificationInAppBanner: value);
    await SettingsService.setNotificationInAppBanner(value);
  }

  Future<void> setNotificationSystem(bool value) async {
    state = state.copyWith(notificationSystem: value);
    await SettingsService.setNotificationSystem(value);
  }

  Future<void> setNotificationChatEnabled(bool value) async {
    state = state.copyWith(notificationChatEnabled: value);
    await SettingsService.setNotificationChatEnabled(value);
  }

  Future<void> setNotificationChannelEnabled(bool value) async {
    state = state.copyWith(notificationChannelEnabled: value);
    await SettingsService.setNotificationChannelEnabled(value);
  }

  /// Applies the three server-synced notification prefs fetched from Open WebUI
  /// without echoing them back to the server. Used at bootstrap so the server
  /// stays authoritative for cross-device parity. Only writes when a value
  /// actually changed to avoid spurious rebuilds.
  Future<void> applyServerNotificationPrefs({
    bool? enabled,
    bool? sound,
    bool? soundAlways,
  }) async {
    final next = state.copyWith(
      notificationsEnabled: enabled,
      notificationSound: sound,
      notificationSoundAlways: soundAlways,
    );
    if (next == state) return;
    state = next;
    if (enabled != null) await SettingsService.setNotificationsEnabled(enabled);
    if (sound != null) await SettingsService.setNotificationSound(sound);
    if (soundAlways != null) {
      await SettingsService.setNotificationSoundAlways(soundAlways);
    }
  }

  Future<void> setHighContrast(bool value) async {
    state = state.copyWith(highContrast: value);
    await SettingsService.setHighContrast(value);
  }

  Future<void> setDarkMode(bool value) async {
    state = state.copyWith(darkMode: value);
    await SettingsService.setDarkMode(value);
  }

  Future<void> setDefaultModel(String? modelId) async {
    state = state.copyWith(defaultModel: modelId);
    await SettingsService.setDefaultModel(modelId);
  }

  Future<void> setVoiceLocaleId(String? localeId) async {
    state = state.copyWith(voiceLocaleId: localeId);
    await SettingsService.setVoiceLocaleId(localeId);
  }

  Future<void> setVoiceHoldToTalk(bool value) async {
    state = state.copyWith(voiceHoldToTalk: value);
    await SettingsService.setVoiceHoldToTalk(value);
  }

  Future<void> setVoiceAutoSendFinal(bool value) async {
    state = state.copyWith(voiceAutoSendFinal: value);
    await SettingsService.setVoiceAutoSendFinal(value);
  }

  Future<void> setSocketTransportMode(String mode) async {
    var sanitized = mode;
    if (sanitized == 'auto') {
      sanitized = 'polling';
    }
    if (sanitized != 'polling' && sanitized != 'ws') {
      sanitized = 'polling';
    }
    if (state.socketTransportMode != sanitized) {
      state = state.copyWith(socketTransportMode: sanitized);
    }
    await SettingsService.setSocketTransportMode(sanitized);
  }

  Future<void> setQuickPills(List<String> pills) async {
    // Accept arbitrary server tool IDs plus built-ins
    // Platform-specific limits are enforced in the UI layer
    state = state.copyWith(quickPills: pills);
    await SettingsService.setQuickPills(pills);
  }

  Future<void> setChatWebSearchEnabled(bool value) async {
    state = state.copyWith(chatWebSearchEnabled: value);
    await SettingsService.setChatWebSearchEnabled(value);
  }

  Future<void> setChatImageGenerationEnabled(bool value) async {
    state = state.copyWith(chatImageGenerationEnabled: value);
    await SettingsService.setChatImageGenerationEnabled(value);
  }

  Future<void> setChatCodeInterpreterEnabled(bool value) async {
    state = state.copyWith(chatCodeInterpreterEnabled: value);
    await SettingsService.setChatCodeInterpreterEnabled(value);
  }

  Future<void> setSendOnEnter(bool value) async {
    state = state.copyWith(sendOnEnter: value);
    await SettingsService.setSendOnEnter(value);
  }

  Future<void> setTemporaryChatByDefault(bool value) async {
    state = state.copyWith(temporaryChatByDefault: value);
    await SettingsService.setTemporaryChatByDefault(value);
  }

  Future<void> setPinnedModels(List<String> modelIds) async {
    final sanitized = SettingsService.sanitizePinnedModels(modelIds);
    state = state.copyWith(pinnedModels: sanitized);
    await SettingsService.setPinnedModels(sanitized);
  }

  Future<void> togglePinnedModel(String modelId) async {
    final trimmed = modelId.trim();
    if (trimmed.isEmpty) {
      return;
    }

    final current = state.pinnedModels;
    final updated = current.contains(trimmed)
        ? current.where((id) => id != trimmed).toList(growable: false)
        : SettingsService.sanitizePinnedModels([...current, trimmed]);

    state = state.copyWith(pinnedModels: updated);
    await SettingsService.setPinnedModels(updated);
  }

  Future<void> setSttPreference(SttPreference preference) async {
    if (state.sttPreference == preference) {
      return;
    }
    state = state.copyWith(sttPreference: preference);
    await SettingsService.saveSettings(state);
  }

  Future<void> setSttLanguageCode(String? languageCode) async {
    final normalized = SettingsService.normalizeSttLanguageCode(languageCode);
    if (state.sttLanguageCode == normalized) {
      return;
    }
    state = state.copyWith(sttLanguageCode: normalized);
    await SettingsService.saveSettings(state);
  }

  Future<void> setTtsVoice(String? voice) async {
    state = state.copyWith(ttsVoice: voice);
    await SettingsService.saveSettings(state);
  }

  Future<void> setTtsSpeechRate(double rate) async {
    state = state.copyWith(ttsSpeechRate: rate);
    await SettingsService.saveSettings(state);
  }

  Future<void> setTtsPitch(double pitch) async {
    state = state.copyWith(ttsPitch: pitch);
    await SettingsService.saveSettings(state);
  }

  Future<void> setTtsVolume(double volume) async {
    state = state.copyWith(ttsVolume: volume);
    await SettingsService.saveSettings(state);
  }

  Future<void> setTtsEngine(TtsEngine engine) async {
    state = state.copyWith(ttsEngine: engine);
    await SettingsService.saveSettings(state);
  }

  Future<void> setTtsServerVoiceName(String? name) async {
    state = state.copyWith(ttsServerVoiceName: name);
    await SettingsService.saveSettings(state);
  }

  Future<void> setTtsServerVoiceId(String? id) async {
    state = state.copyWith(ttsServerVoiceId: id);
    await SettingsService.saveSettings(state);
  }

  Future<void> setVoiceSilenceDuration(int milliseconds) async {
    state = state.copyWith(voiceSilenceDuration: milliseconds);
    await SettingsService.setVoiceSilenceDuration(milliseconds);
  }

  Future<void> setAndroidAssistantTrigger(
    AndroidAssistantTrigger trigger,
  ) async {
    if (state.androidAssistantTrigger == trigger) {
      return;
    }
    state = state.copyWith(androidAssistantTrigger: trigger);
    await SettingsService.setAndroidAssistantTrigger(trigger);
  }

  Future<void> resetToDefaults() async {
    const defaultSettings = AppSettings();
    await SettingsService.saveSettings(defaultSettings);
    state = defaultSettings;
  }
}

/// Provider for checking if haptic feedback should be enabled
final hapticEnabledProvider = Provider<bool>((ref) {
  final settings = ref.watch(appSettingsProvider);
  return settings.hapticFeedback;
});

/// Provider for checking if assistant response streaming haptics are enabled.
final streamingHapticsEnabledProvider = Provider<bool>((ref) {
  final settings = ref.watch(appSettingsProvider);
  return settings.hapticFeedback && !settings.disableHapticsWhileStreaming;
});

/// Provider for effective animation settings
final effectiveAnimationSettingsProvider = Provider<AnimationSettings>((ref) {
  final appSettings = ref.watch(appSettingsProvider);

  return AnimationSettings(
    reduceMotion: appSettings.reduceMotion,
    performance: AnimationPerformance.adaptive,
    animationSpeed: appSettings.animationSpeed,
  );
});
