import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Lightweight wrapper around FlutterTts to centralize configuration
class TextToSpeechService {
  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;
  bool _available = false;
  bool _voiceConfigured = false;

  VoidCallback? _onStart;
  VoidCallback? _onComplete;
  VoidCallback? _onCancel;
  VoidCallback? _onPause;
  VoidCallback? _onContinue;
  void Function(String message)? _onError;

  bool get isInitialized => _initialized;
  bool get isAvailable => _available;

  /// Register callbacks for TTS lifecycle events
  void bindHandlers({
    VoidCallback? onStart,
    VoidCallback? onComplete,
    VoidCallback? onCancel,
    VoidCallback? onPause,
    VoidCallback? onContinue,
    void Function(String message)? onError,
  }) {
    _onStart = onStart;
    _onComplete = onComplete;
    _onCancel = onCancel;
    _onPause = onPause;
    _onContinue = onContinue;
    _onError = onError;

    _tts.setStartHandler(_handleStart);
    _tts.setCompletionHandler(_handleComplete);
    _tts.setCancelHandler(_handleCancel);
    _tts.setPauseHandler(_handlePause);
    _tts.setContinueHandler(_handleContinue);
    _tts.setErrorHandler(_handleError);
  }

  /// Initialize the native TTS engine lazily
  Future<bool> initialize({
    String? voice,
    double speechRate = 0.5,
    double pitch = 1.0,
    double volume = 1.0,
  }) async {
    if (_initialized) {
      return _available;
    }

    try {
      await _tts.awaitSpeakCompletion(false);

      // Set volume
      await _tts.setVolume(volume);

      // Set speech rate
      await _tts.setSpeechRate(speechRate);

      // Set pitch
      await _tts.setPitch(pitch);

      if (!kIsWeb && Platform.isIOS) {
        await _tts.setSharedInstance(true);
        await _tts.setIosAudioCategory(IosTextToSpeechAudioCategory.playback, [
          IosTextToSpeechAudioCategoryOptions.mixWithOthers,
          IosTextToSpeechAudioCategoryOptions.defaultToSpeaker,
          IosTextToSpeechAudioCategoryOptions.allowBluetooth,
          IosTextToSpeechAudioCategoryOptions.allowBluetoothA2DP,
        ]);
      }

      // Set the voice (specific or default)
      await _setVoiceByName(voice);
      _available = true;
    } catch (e) {
      _available = false;
      _onError?.call(e.toString());
    }

    _initialized = true;
    return _available;
  }

  Future<void> speak(String text) async {
    if (text.trim().isEmpty) {
      throw ArgumentError('Cannot speak empty text');
    }

    if (!_initialized) {
      await initialize();
    }

    if (!_available) {
      throw StateError('Text-to-speech is unavailable on this device');
    }

    await _tts.stop();
    if (!_voiceConfigured) {
      await _configurePreferredVoice();
    }
    final result = await _tts.speak(text);
    if (result == null) {
      return;
    }

    if (result is int && result != 1) {
      _onError?.call('Text-to-speech engine returned code $result');
    }
  }

  Future<void> pause() async {
    if (!_initialized || !_available) {
      return;
    }

    try {
      await _tts.pause();
    } catch (e) {
      _onError?.call(e.toString());
    }
  }

  Future<void> stop() async {
    if (!_initialized) {
      return;
    }

    try {
      await _tts.stop();
    } catch (e) {
      _onError?.call(e.toString());
    }
  }

  Future<void> dispose() async {
    await stop();
  }

  /// Update TTS settings on-the-fly
  Future<void> updateSettings({
    String? voice,
    double? speechRate,
    double? pitch,
    double? volume,
  }) async {
    if (!_initialized || !_available) {
      return;
    }

    try {
      if (volume != null) {
        await _tts.setVolume(volume);
      }
      if (speechRate != null) {
        await _tts.setSpeechRate(speechRate);
      }
      if (pitch != null) {
        await _tts.setPitch(pitch);
      }
      // Set specific voice by name
      await _setVoiceByName(voice);
    } catch (e) {
      _onError?.call(e.toString());
    }
  }

  /// Set voice by name, or use system default if null
  Future<void> _setVoiceByName(String? voiceName) async {
    if (kIsWeb || (!Platform.isIOS && !Platform.isAndroid)) {
      return;
    }

    try {
      if (voiceName == null) {
        // Use system default - reset voice configuration
        _voiceConfigured = false;
        await _configurePreferredVoice();
        return;
      }

      // Get all available voices
      final voicesRaw = await _tts.getVoices;
      if (voicesRaw is! List) {
        return;
      }

      // Find the voice by name
      Map<String, dynamic>? targetVoice;
      for (final entry in voicesRaw) {
        if (entry is Map) {
          final normalized = _normalizeVoiceEntry(entry);
          final name = normalized['name'] as String?;
          if (name == voiceName) {
            targetVoice = normalized;
            break;
          }
        }
      }

      // Set the voice if found
      if (targetVoice != null) {
        await _tts.setVoice(_voiceCommandFrom(targetVoice));
        _voiceConfigured = true;
      } else {
        // Voice not found, fall back to default
        _voiceConfigured = false;
        await _configurePreferredVoice();
      }
    } catch (e) {
      _onError?.call(e.toString());
    }
  }

  /// Get available voices from the TTS engine
  Future<List<Map<String, dynamic>>> getAvailableVoices() async {
    if (!_initialized) {
      await initialize();
    }

    if (!_available) {
      return [];
    }

    try {
      final voicesRaw = await _tts.getVoices;
      if (voicesRaw is! List) {
        return [];
      }

      final parsedVoices = <Map<String, dynamic>>[];
      for (final entry in voicesRaw) {
        if (entry is Map) {
          final normalized = _normalizeVoiceEntry(entry);
          if (normalized.isNotEmpty) {
            parsedVoices.add(normalized);
          }
        }
      }

      return parsedVoices;
    } catch (e) {
      _onError?.call(e.toString());
      return [];
    }
  }

  Future<void> _configurePreferredVoice() async {
    if (_voiceConfigured) {
      return;
    }
    if (kIsWeb || (!Platform.isIOS && !Platform.isAndroid)) {
      _voiceConfigured = true;
      return;
    }

    var configured = false;
    try {
      Map<String, dynamic>? defaultVoice;
      bool voiceSet = false;

      if (Platform.isIOS) {
        try {
          final rawDefault = await _tts.getDefaultVoice;
          if (rawDefault is Map) {
            defaultVoice = _normalizeVoiceEntry(rawDefault);
            await _tts.setVoice(_voiceCommandFrom(defaultVoice));
            configured = true;
            voiceSet = true;
          }
        } catch (_) {
          defaultVoice = null;
        }
      }

      if (voiceSet) {
        return;
      }

      final voicesRaw = await _tts.getVoices;
      if (voicesRaw is! List) {
        return;
      }

      final parsedVoices = <Map<String, dynamic>>[];
      for (final entry in voicesRaw) {
        if (entry is Map) {
          final normalized = _normalizeVoiceEntry(entry);
          if (normalized.isNotEmpty) {
            parsedVoices.add(normalized);
          }
        }
      }

      if (parsedVoices.isEmpty) {
        return;
      }

      final localeTag = WidgetsBinding.instance.platformDispatcher.locale
          .toLanguageTag()
          .toLowerCase();
      final preferred = _selectPreferredVoice(
        parsedVoices,
        localeTag,
        defaultVoice: defaultVoice,
      );
      if (preferred == null) {
        if (Platform.isIOS) {
          configured = true; // Allow system default voice to be used
        }
        return;
      }

      await _tts.setVoice(_voiceCommandFrom(preferred));
      configured = true;
    } catch (e) {
      _onError?.call(e.toString());
    } finally {
      _voiceConfigured = configured || _voiceConfigured;
    }
  }

  Map<String, dynamic> _normalizeVoiceEntry(Map<dynamic, dynamic> entry) {
    final normalized = <String, dynamic>{};
    entry.forEach((key, value) {
      if (key != null) {
        normalized[key.toString()] = value;
      }
    });
    return normalized;
  }

  Map<String, String> _voiceCommandFrom(Map<String, dynamic> voice) {
    final command = <String, String>{};
    for (final key in [
      'name',
      'locale',
      'identifier',
      'id',
      'voiceIdentifier',
      'engine',
    ]) {
      final value = voice[key];
      if (value != null) {
        command[key] = value.toString();
      }
    }
    if (!command.containsKey('name') && voice['name'] != null) {
      command['name'] = voice['name'].toString();
    }
    if (!command.containsKey('locale') && voice['locale'] != null) {
      command['locale'] = voice['locale'].toString();
    }
    return command;
  }

  int _iosVoiceScore(Map<String, dynamic> voice) {
    final identifier =
        voice['identifier']?.toString().toLowerCase() ??
        voice['id']?.toString().toLowerCase() ??
        '';
    final name = voice['name']?.toString().toLowerCase() ?? '';

    int score = 0;
    if (identifier.contains('premium')) {
      score += 400;
    } else if (identifier.contains('enhanced')) {
      score += 250;
    } else if (identifier.contains('compact')) {
      score += 50;
    }

    if (identifier.contains('siri') || name.contains('siri')) {
      score += 150;
    }

    if (identifier.contains('female') || name.contains('female')) {
      score += 15;
    }
    if (identifier.contains('male') || name.contains('male')) {
      score += 10;
    }

    // Prefer non-compact by default when no other hints are present
    if (!identifier.contains('compact')) {
      score += 25;
    }

    return score;
  }

  Map<String, dynamic>? _selectPreferredVoice(
    List<Map<String, dynamic>> voices,
    String localeTag, {
    Map<String, dynamic>? defaultVoice,
  }) {
    Map<String, dynamic>? matchesLocale(Iterable<Map<String, dynamic>> input) {
      for (final voice in input) {
        final locale = voice['locale']?.toString().toLowerCase();
        if (locale == null) continue;
        if (locale == localeTag) {
          return voice;
        }
        final localePrimary = locale.split(RegExp('[-_]')).first;
        final tagPrimary = localeTag.split(RegExp('[-_]')).first;
        if (localePrimary == tagPrimary) {
          return voice;
        }
      }
      return null;
    }

    Map<String, dynamic>? matchDefaultVoice() {
      final dv = defaultVoice;
      if (dv == null) {
        return null;
      }

      final identifiers = <String>{};
      for (final key in ['identifier', 'id', 'voiceIdentifier', 'voice']) {
        final value = dv[key]?.toString();
        if (value != null && value.isNotEmpty) {
          identifiers.add(value.toLowerCase());
        }
      }

      if (identifiers.isNotEmpty) {
        for (final voice in voices) {
          for (final key in ['identifier', 'id', 'voiceIdentifier', 'voice']) {
            final value = voice[key]?.toString();
            if (value != null && identifiers.contains(value.toLowerCase())) {
              return voice;
            }
          }
        }
      }

      final defaultName = dv['name']?.toString();
      final defaultLocale = dv['locale']?.toString();
      if (defaultName != null && defaultLocale != null) {
        final lowerName = defaultName.toLowerCase();
        final lowerLocale = defaultLocale.toLowerCase();
        for (final voice in voices) {
          final name = voice['name']?.toString();
          final locale = voice['locale']?.toString();
          if (name != null &&
              locale != null &&
              name.toLowerCase() == lowerName &&
              locale.toLowerCase() == lowerLocale) {
            return voice;
          }
        }
      }

      return null;
    }

    Map<String, dynamic>? pickIosVoice() {
      final userDefault = matchDefaultVoice();
      if (userDefault != null) {
        return userDefault;
      }

      final siriCandidates = voices.where((voice) {
        final name = voice['name']?.toString().toLowerCase() ?? '';
        final identifier = voice['identifier']?.toString().toLowerCase() ?? '';
        final voiceId = voice['id']?.toString().toLowerCase() ?? '';
        return name.contains('siri') ||
            identifier.contains('siri') ||
            voiceId.contains('siri');
      }).toList();

      if (siriCandidates.isNotEmpty) {
        siriCandidates.sort((a, b) => _iosVoiceScore(b) - _iosVoiceScore(a));
        final localeMatch = matchesLocale(siriCandidates);
        if (localeMatch != null) {
          return localeMatch;
        }
        return siriCandidates.first;
      }

      final ranked = [...voices];
      ranked.sort((a, b) => _iosVoiceScore(b) - _iosVoiceScore(a));
      final localeMatch = matchesLocale(ranked);
      if (localeMatch != null) {
        return localeMatch;
      }
      return ranked.isNotEmpty ? ranked.first : null;
    }

    Map<String, dynamic>? pickAndroidVoice() {
      int qualityScore(String? quality) {
        switch ((quality ?? '').toLowerCase()) {
          case 'very_high':
          case 'very-high':
            return 3;
          case 'high':
            return 2;
          case 'normal':
            return 1;
          default:
            return 0;
        }
      }

      final preferredEngineVoices = voices
          .where(
            (voice) =>
                (voice['engine']?.toString() ?? '').toLowerCase().contains(
                  'google',
                ) ||
                voice['engine'] is! String,
          )
          .toList();

      preferredEngineVoices.sort((a, b) {
        final qualityDiff =
            qualityScore(b['quality']?.toString()) -
            qualityScore(a['quality']?.toString());
        if (qualityDiff != 0) {
          return qualityDiff;
        }
        final latencyA = a['latency']?.toString() ?? '';
        final latencyB = b['latency']?.toString() ?? '';
        return latencyA.compareTo(latencyB);
      });

      final ordered = preferredEngineVoices.isEmpty
          ? voices
          : preferredEngineVoices;
      return matchesLocale(ordered) ?? matchesLocale(voices);
    }

    Map<String, dynamic>? selected;
    if (Platform.isIOS) {
      selected = pickIosVoice();
    } else if (Platform.isAndroid) {
      selected = pickAndroidVoice();
    }

    if (selected == null) {
      return null;
    }

    final name = selected['name']?.toString();
    final locale = selected['locale']?.toString();
    if (name == null || locale == null) {
      return null;
    }

    return selected;
  }

  void _handleStart() {
    _onStart?.call();
  }

  void _handleComplete() {
    _onComplete?.call();
  }

  void _handleCancel() {
    _onCancel?.call();
  }

  void _handlePause() {
    _onPause?.call();
  }

  void _handleContinue() {
    _onContinue?.call();
  }

  void _handleError(dynamic message) {
    final safeMessage = message == null
        ? 'Unknown TTS error'
        : message.toString();
    _onError?.call(safeMessage);
  }
}
