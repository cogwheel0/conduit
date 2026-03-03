import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_ce/hive.dart';
import '../persistence/hive_bootstrap.dart';
import '../persistence/hive_boxes.dart';
import '../persistence/persistence_keys.dart';
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
  static const String _reduceMotionKey = PreferenceKeys.reduceMotion;
  static const String _animationSpeedKey = PreferenceKeys.animationSpeed;
  static const String _hapticFeedbackKey = PreferenceKeys.hapticFeedback;
  static const String _highContrastKey = PreferenceKeys.highContrast;
  static const String _largeTextKey = PreferenceKeys.largeText;
  static const String _darkModeKey = PreferenceKeys.darkMode;
  static const String _defaultModelKey = PreferenceKeys.defaultModel;
  // Voice input settings
  static const String _voiceLocaleKey = PreferenceKeys.voiceLocaleId;
  static const String _voiceHoldToTalkKey = PreferenceKeys.voiceHoldToTalk;
  static const String _voiceAutoSendKey = PreferenceKeys.voiceAutoSendFinal;
  // Realtime transport preference
  static const String _socketTransportModeKey =
      PreferenceKeys.socketTransportMode; // 'polling' or 'ws'
  // Quick pill visibility selections (max 2)
  static const String _quickPillsKey = PreferenceKeys
      .quickPills; // StringList of identifiers e.g. ['web','image','tools']
  // Chat input behavior
  static const String _sendOnEnterKey = PreferenceKeys.sendOnEnterKey;
  // Voice silence duration for auto-stop (milliseconds)
  static const String _voiceSilenceDurationKey =
      PreferenceKeys.voiceSilenceDuration;
  static const String _androidAssistantTriggerKey =
      PreferenceKeys.androidAssistantTrigger;
  static Box<dynamic> _preferencesBox() =>
      Hive.box<dynamic>(HiveBoxNames.preferences);

  /// Get reduced motion preference
  static Future<bool> getReduceMotion() {
    final value = _preferencesBox().get(_reduceMotionKey) as bool?;
    return Future.value(value ?? false);
  }

  /// Set reduced motion preference
  static Future<void> setReduceMotion(bool value) {
    return _preferencesBox().put(_reduceMotionKey, value);
  }

  /// Get animation speed multiplier (0.5 - 2.0)
  static Future<double> getAnimationSpeed() {
    final value = _preferencesBox().get(_animationSpeedKey) as num?;
    return Future.value((value?.toDouble() ?? 1.0).clamp(0.5, 2.0));
  }

  /// Set animation speed multiplier
  static Future<void> setAnimationSpeed(double value) {
    final sanitized = value.clamp(0.5, 2.0).toDouble();
    return _preferencesBox().put(_animationSpeedKey, sanitized);
  }

  /// Get haptic feedback preference
  static Future<bool> getHapticFeedback() {
    final value = _preferencesBox().get(_hapticFeedbackKey) as bool?;
    return Future.value(value ?? true);
  }

  /// Set haptic feedback preference
  static Future<void> setHapticFeedback(bool value) {
    return _preferencesBox().put(_hapticFeedbackKey, value);
  }

  /// Get high contrast preference
  static Future<bool> getHighContrast() {
    final value = _preferencesBox().get(_highContrastKey) as bool?;
    return Future.value(value ?? false);
  }

  /// Set high contrast preference
  static Future<void> setHighContrast(bool value) {
    return _preferencesBox().put(_highContrastKey, value);
  }

  /// Get large text preference
  static Future<bool> getLargeText() {
    final value = _preferencesBox().get(_largeTextKey) as bool?;
    return Future.value(value ?? false);
  }

  /// Set large text preference
  static Future<void> setLargeText(bool value) {
    return _preferencesBox().put(_largeTextKey, value);
  }

  /// Get dark mode preference
  static Future<bool> getDarkMode() {
    final value = _preferencesBox().get(_darkModeKey) as bool?;
    return Future.value(value ?? true);
  }

  /// Set dark mode preference
  static Future<void> setDarkMode(bool value) {
    return _preferencesBox().put(_darkModeKey, value);
  }

  /// Get default model preference
  static Future<String?> getDefaultModel() {
    final value = _preferencesBox().get(_defaultModelKey) as String?;
    return Future.value(value);
  }

  /// Set default model preference
  static Future<void> setDefaultModel(String? modelId) {
    final box = _preferencesBox();
    if (modelId != null) {
      return box.put(_defaultModelKey, modelId);
    }
    return box.delete(_defaultModelKey);
  }

  /// Load all settings
  static Future<AppSettings> loadSettings() {
    final box = _preferencesBox();
    return Future.value(_loadSettingsSync(box));
  }

  /// Save all settings
  static Future<void> saveSettings(AppSettings settings) async {
    final box = _preferencesBox();
    final updates = <String, Object?>{
      _reduceMotionKey: settings.reduceMotion,
      _animationSpeedKey: settings.animationSpeed,
      _hapticFeedbackKey: settings.hapticFeedback,
      _highContrastKey: settings.highContrast,
      _largeTextKey: settings.largeText,
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
      _androidAssistantTriggerKey:
          settings.androidAssistantTrigger.storageValue,
    };

    await box.putAll(updates);

    if (settings.defaultModel != null) {
      await box.put(_defaultModelKey, settings.defaultModel);
    } else {
      await box.delete(_defaultModelKey);
    }

    if (settings.voiceLocaleId != null && settings.voiceLocaleId!.isNotEmpty) {
      await box.put(_voiceLocaleKey, settings.voiceLocaleId);
    } else {
      await box.delete(_voiceLocaleKey);
    }

    if (settings.ttsVoice != null && settings.ttsVoice!.isNotEmpty) {
      await box.put(PreferenceKeys.ttsVoice, settings.ttsVoice);
    } else {
      await box.delete(PreferenceKeys.ttsVoice);
    }

    // Server-specific voice id and friendly name
    if (settings.ttsServerVoiceId != null &&
        settings.ttsServerVoiceId!.isNotEmpty) {
      await box.put(PreferenceKeys.ttsServerVoiceId, settings.ttsServerVoiceId);
    } else {
      await box.delete(PreferenceKeys.ttsServerVoiceId);
    }
    if (settings.ttsServerVoiceName != null &&
        settings.ttsServerVoiceName!.isNotEmpty) {
      await box.put(
        PreferenceKeys.ttsServerVoiceName,
        settings.ttsServerVoiceName,
      );
    } else {
      await box.delete(PreferenceKeys.ttsServerVoiceName);
    }

    await _writeAssistantTriggerToSharedPrefs(settings.androidAssistantTrigger);
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

  // Voice input specific settings
  static Future<String?> getVoiceLocaleId() {
    final value = _preferencesBox().get(_voiceLocaleKey) as String?;
    return Future.value(value);
  }

  static Future<void> setVoiceLocaleId(String? localeId) {
    final box = _preferencesBox();
    if (localeId == null || localeId.isEmpty) {
      return box.delete(_voiceLocaleKey);
    }
    return box.put(_voiceLocaleKey, localeId);
  }

  static Future<bool> getVoiceHoldToTalk() {
    final value = _preferencesBox().get(_voiceHoldToTalkKey) as bool?;
    return Future.value(value ?? false);
  }

  static Future<void> setVoiceHoldToTalk(bool value) {
    return _preferencesBox().put(_voiceHoldToTalkKey, value);
  }

  static Future<bool> getVoiceAutoSendFinal() {
    final value = _preferencesBox().get(_voiceAutoSendKey) as bool?;
    return Future.value(value ?? false);
  }

  static Future<void> setVoiceAutoSendFinal(bool value) {
    return _preferencesBox().put(_voiceAutoSendKey, value);
  }

  /// Transport mode: 'polling' (HTTP polling + WebSocket upgrade) or 'ws'
  static Future<String> getSocketTransportMode() {
    final raw = _preferencesBox().get(_socketTransportModeKey) as String?;
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
    return _preferencesBox().put(_socketTransportModeKey, mode);
  }

  // Quick Pills (visibility)
  static Future<List<String>> getQuickPills() {
    final stored = _preferencesBox().get(_quickPillsKey) as List<dynamic>?;
    if (stored == null) {
      return Future.value(const []);
    }
    return Future.value(List<String>.from(stored));
  }

  static Future<void> setQuickPills(List<String> pills) {
    return _preferencesBox().put(_quickPillsKey, pills.toList());
  }

  // Chat input behavior
  static Future<bool> getSendOnEnter() {
    final value = _preferencesBox().get(_sendOnEnterKey) as bool?;
    return Future.value(value ?? false);
  }

  static Future<void> setSendOnEnter(bool value) {
    return _preferencesBox().put(_sendOnEnterKey, value);
  }

  static Future<int> getVoiceSilenceDuration() {
    final value = _preferencesBox().get(_voiceSilenceDurationKey) as int?;
    return Future.value((value ?? 2000).clamp(300, 3000));
  }

  static Future<void> setVoiceSilenceDuration(int milliseconds) {
    final sanitized = milliseconds.clamp(300, 3000);
    return _preferencesBox().put(_voiceSilenceDurationKey, sanitized);
  }

  static Future<void> setAndroidAssistantTrigger(
    AndroidAssistantTrigger trigger,
  ) async {
    await _preferencesBox().put(
      _androidAssistantTriggerKey,
      trigger.storageValue,
    );
    await _writeAssistantTriggerToSharedPrefs(trigger);
  }

  static Future<void> _writeAssistantTriggerToSharedPrefs(
    AndroidAssistantTrigger trigger,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        PreferenceKeys.androidAssistantTrigger,
        trigger.storageValue,
      );
    } catch (_) {
      // SharedPreferences writes are best-effort for Android assistant access
    }
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

  /// Get text scale factor considering user preferences
  static double getEffectiveTextScaleFactor(
    BuildContext context,
    AppSettings settings,
  ) {
    final textScaler = MediaQuery.of(context).textScaler;
    double baseScale = textScaler.scale(1.0);

    // Apply large text preference
    if (settings.largeText) {
      baseScale *= 1.3;
    }

    // Ensure reasonable bounds
    return baseScale.clamp(0.8, 3.0);
  }

  static AppSettings _loadSettingsSync(Box<dynamic> box) {
    return AppSettings(
      reduceMotion: (box.get(_reduceMotionKey) as bool?) ?? false,
      animationSpeed: (box.get(_animationSpeedKey) as num?)?.toDouble() ?? 1.0,
      hapticFeedback: (box.get(_hapticFeedbackKey) as bool?) ?? true,
      highContrast: (box.get(_highContrastKey) as bool?) ?? false,
      largeText: (box.get(_largeTextKey) as bool?) ?? false,
      darkMode: (box.get(_darkModeKey) as bool?) ?? true,
      defaultModel: box.get(_defaultModelKey) as String?,
      voiceLocaleId: box.get(_voiceLocaleKey) as String?,
      voiceHoldToTalk: (box.get(_voiceHoldToTalkKey) as bool?) ?? false,
      voiceAutoSendFinal: (box.get(_voiceAutoSendKey) as bool?) ?? false,
      socketTransportMode:
          box.get(_socketTransportModeKey, defaultValue: 'ws') as String,
      quickPills: List<String>.from(
        (box.get(_quickPillsKey) as List<dynamic>?) ?? const <String>[],
      ),
      sendOnEnter: (box.get(_sendOnEnterKey) as bool?) ?? false,
      ttsVoice: box.get(PreferenceKeys.ttsVoice) as String?,
      ttsSpeechRate:
          (box.get(PreferenceKeys.ttsSpeechRate) as num?)?.toDouble() ?? 0.5,
      ttsPitch: (box.get(PreferenceKeys.ttsPitch) as num?)?.toDouble() ?? 1.0,
      ttsVolume: (box.get(PreferenceKeys.ttsVolume) as num?)?.toDouble() ?? 1.0,
      ttsEngine: _parseTtsEngine(box.get(PreferenceKeys.ttsEngine) as String?),
      ttsServerVoiceId: box.get(PreferenceKeys.ttsServerVoiceId) as String?,
      ttsServerVoiceName: box.get(PreferenceKeys.ttsServerVoiceName) as String?,
      sttPreference: _parseSttPreference(
        box.get(PreferenceKeys.voiceSttPreference) as String?,
      ),
      androidAssistantTrigger: _parseAndroidAssistantTrigger(
        box.get(_androidAssistantTriggerKey) as String?,
      ),
      voiceSilenceDuration: (box.get(_voiceSilenceDurationKey) as int? ?? 2000)
          .clamp(300, 3000),
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
  final bool highContrast;
  final bool largeText;
  final bool darkMode;
  final String? defaultModel;
  final String? voiceLocaleId;
  final bool voiceHoldToTalk;
  final bool voiceAutoSendFinal;
  final String socketTransportMode; // 'polling' or 'ws'
  final List<String> quickPills; // e.g., ['web','image']
  final bool sendOnEnter;
  final SttPreference sttPreference;
  final String? ttsVoice;
  final double ttsSpeechRate;
  final double ttsPitch;
  final double ttsVolume;
  final TtsEngine ttsEngine;
  final String? ttsServerVoiceId;
  final String? ttsServerVoiceName;
  final AndroidAssistantTrigger androidAssistantTrigger;
  final int voiceSilenceDuration;
  const AppSettings({
    this.reduceMotion = false,
    this.animationSpeed = 1.0,
    this.hapticFeedback = true,
    this.highContrast = false,
    this.largeText = false,
    this.darkMode = true,
    this.defaultModel,
    this.voiceLocaleId,
    this.voiceHoldToTalk = false,
    this.voiceAutoSendFinal = false,
    this.socketTransportMode = 'ws',
    this.quickPills = const [],
    this.sendOnEnter = false,
    this.sttPreference = SttPreference.deviceOnly,
    this.ttsVoice,
    this.ttsSpeechRate = 0.5,
    this.ttsPitch = 1.0,
    this.ttsVolume = 1.0,
    this.ttsEngine = TtsEngine.device,
    this.ttsServerVoiceId,
    this.ttsServerVoiceName,
    this.androidAssistantTrigger = AndroidAssistantTrigger.overlay,
    this.voiceSilenceDuration = 2000,
  });

  AppSettings copyWith({
    bool? reduceMotion,
    double? animationSpeed,
    bool? hapticFeedback,
    bool? highContrast,
    bool? largeText,
    bool? darkMode,
    Object? defaultModel = const _DefaultValue(),
    Object? voiceLocaleId = const _DefaultValue(),
    bool? voiceHoldToTalk,
    bool? voiceAutoSendFinal,
    String? socketTransportMode,
    List<String>? quickPills,
    bool? sendOnEnter,
    SttPreference? sttPreference,
    Object? ttsVoice = const _DefaultValue(),
    double? ttsSpeechRate,
    double? ttsPitch,
    double? ttsVolume,
    TtsEngine? ttsEngine,
    Object? ttsServerVoiceId = const _DefaultValue(),
    Object? ttsServerVoiceName = const _DefaultValue(),
    int? voiceSilenceDuration,
    AndroidAssistantTrigger? androidAssistantTrigger,
  }) {
    return AppSettings(
      reduceMotion: reduceMotion ?? this.reduceMotion,
      animationSpeed: animationSpeed ?? this.animationSpeed,
      hapticFeedback: hapticFeedback ?? this.hapticFeedback,
      highContrast: highContrast ?? this.highContrast,
      largeText: largeText ?? this.largeText,
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
      sendOnEnter: sendOnEnter ?? this.sendOnEnter,
      sttPreference: sttPreference ?? this.sttPreference,
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
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AppSettings &&
        other.reduceMotion == reduceMotion &&
        other.animationSpeed == animationSpeed &&
        other.hapticFeedback == hapticFeedback &&
        other.highContrast == highContrast &&
        other.largeText == largeText &&
        other.darkMode == darkMode &&
        other.defaultModel == defaultModel &&
        other.voiceLocaleId == voiceLocaleId &&
        other.voiceHoldToTalk == voiceHoldToTalk &&
        other.voiceAutoSendFinal == voiceAutoSendFinal &&
        other.sttPreference == sttPreference &&
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
        _listEquals(other.quickPills, quickPills);
    // socketTransportMode intentionally not included in == to avoid frequent rebuilds
  }

  @override
  int get hashCode {
    return Object.hashAll([
      reduceMotion,
      animationSpeed,
      hapticFeedback,
      highContrast,
      largeText,
      darkMode,
      defaultModel,
      voiceLocaleId,
      voiceHoldToTalk,
      voiceAutoSendFinal,
      sttPreference,
      socketTransportMode,
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
      Object.hashAllUnordered(quickPills),
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
    if (Hive.isBoxOpen(HiveBoxNames.preferences)) {
      final box = Hive.box<dynamic>(HiveBoxNames.preferences);
      return SettingsService._loadSettingsSync(box);
    }

    _pendingLoad ??= _hydrateFromHive();
    return const AppSettings();
  }

  Future<void> _hydrateFromHive() async {
    try {
      await HiveBootstrap.instance.ensureInitialized();
      if (!ref.mounted) return;
      final box = Hive.box<dynamic>(HiveBoxNames.preferences);
      state = SettingsService._loadSettingsSync(box);
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

  Future<void> setHighContrast(bool value) async {
    state = state.copyWith(highContrast: value);
    await SettingsService.setHighContrast(value);
  }

  Future<void> setLargeText(bool value) async {
    state = state.copyWith(largeText: value);
    await SettingsService.setLargeText(value);
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

  Future<void> setSendOnEnter(bool value) async {
    state = state.copyWith(sendOnEnter: value);
    await SettingsService.setSendOnEnter(value);
  }

  Future<void> setSttPreference(SttPreference preference) async {
    if (state.sttPreference == preference) {
      return;
    }
    state = state.copyWith(sttPreference: preference);
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

/// Provider for effective animation settings
final effectiveAnimationSettingsProvider = Provider<AnimationSettings>((ref) {
  final appSettings = ref.watch(appSettingsProvider);

  return AnimationSettings(
    reduceMotion: appSettings.reduceMotion,
    performance: AnimationPerformance.adaptive,
    animationSpeed: appSettings.animationSpeed,
  );
});
