import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../utils/debug_logger.dart';
import '../providers/app_providers.dart';

/// Service to handle Text-to-Speech functionality
///
/// Provides TTS capabilities with platform-specific optimizations
class TTSService {
  static TTSService? _instance;
  static TTSService get instance {
    _instance ??= TTSService._();
    return _instance!;
  }

  TTSService._() {
    DebugLogger.log('TTS: New TTSService instance created');
  }

  FlutterTts? _flutterTts;
  bool _isInitialized = false;
  bool _isSpeaking = false;
  String? _currentMessageId;

  /// Initialize the TTS service
  Future<bool> initialize() async {
    return initializeWithLanguage(null);
  }

  /// Initialize the TTS service with specific language
  Future<bool> initializeWithLanguage(String? languageCode) async {
    if (_isInitialized) {
      // If already initialized, always update language (including null/system)
      await updateLanguage(languageCode);
      return true;
    }

    try {
      _flutterTts = FlutterTts();
      DebugLogger.log('TTS: FlutterTts instance created');

      // Determine language to use
      final targetLanguage = _resolveTargetLanguage(languageCode);

      // Check if target language is available on this device
      final isAvailable = await _flutterTts!.isLanguageAvailable(
        targetLanguage,
      );
      if (!isAvailable) {
        DebugLogger.log(
          'TTS: $targetLanguage not available, falling back to en-US',
        );
      }

      if (Platform.isAndroid) {
        await _setupAndroid(languageCode: languageCode);
      } else if (Platform.isIOS) {
        await _setupiOS(languageCode: languageCode);
      }

      // Set up completion handlers
      _flutterTts!.setCompletionHandler(() {
        DebugLogger.log('TTS: Speech completed');
        _isSpeaking = false;
        _currentMessageId = null;
      });

      _flutterTts!.setErrorHandler((msg) {
        DebugLogger.error('TTS: Error occurred', msg);
        _isSpeaking = false;
        _currentMessageId = null;
      });

      _isInitialized = true;
      DebugLogger.log(
        'TTS: Service initialized successfully with language: $targetLanguage',
      );
      return true;
    } catch (e) {
      DebugLogger.error('TTS: Failed to initialize', e);
      return false;
    }
  }

  /// Setup Android-specific TTS configuration
  Future<void> _setupAndroid({String? languageCode}) async {
    try {
      final language = languageCode ?? 'en-US';
      await _flutterTts!.setLanguage(language);
      await _flutterTts!.setSpeechRate(
        0.5,
      ); // Slightly slower for better comprehension
      await _flutterTts!.setVolume(0.8);
      await _flutterTts!.setPitch(1.0);
      DebugLogger.log(
        'TTS: Basic Android configuration completed with language: $language',
      );
    } catch (e) {
      DebugLogger.error('TTS: Failed to set basic Android configuration', e);
      // Continue anyway with default settings
    }

    // Use Android's high-quality TTS engine if available
    try {
      final engines = await _flutterTts!.getEngines;
      if (engines != null && engines.isNotEmpty) {
        // Prefer Google TTS engine if available
        String? selectedEngine;

        // Search for Google TTS engine
        for (final engine in engines) {
          if (engine is Map<String, dynamic> && engine['name'] != null) {
            final engineName = engine['name'].toString().toLowerCase();
            if (engineName.contains('google')) {
              selectedEngine = engine['name'].toString();
              break;
            }
          }
        }

        // If no Google engine found, use the first available
        if (selectedEngine == null && engines.isNotEmpty) {
          final firstEngine = engines.first;
          if (firstEngine is Map<String, dynamic> &&
              firstEngine['name'] != null) {
            selectedEngine = firstEngine['name'].toString();
          }
        }

        if (selectedEngine != null) {
          await _flutterTts!.setEngine(selectedEngine);
          DebugLogger.log('TTS: Using engine: $selectedEngine');
        }
      }
    } catch (e) {
      DebugLogger.log('TTS: Failed to set custom engine, using default: $e');
      // Continue with default engine
    }
  }

  /// Setup iOS-specific TTS configuration
  Future<void> _setupiOS({String? languageCode}) async {
    final language = languageCode ?? 'en-US';
    await _flutterTts!.setLanguage(language);
    await _flutterTts!.setSpeechRate(0.5);
    await _flutterTts!.setVolume(0.8);
    await _flutterTts!.setPitch(1.0);

    // Use shared audio session for iOS
    await _flutterTts!.setSharedInstance(true);
    DebugLogger.log(
      'TTS: iOS configuration completed with language: $language',
    );
  }

  /// Speak the provided text with optional message ID for tracking
  Future<void> speak(String text, {String? messageId}) async {
    DebugLogger.log(
      'TTS: speak() called for message: $messageId, initialized: $_isInitialized',
    );

    if (!_isInitialized) {
      DebugLogger.log(
        'TTS: Service not initialized, waiting for initialization...',
      );

      // Wait up to 5 seconds for initialization to complete
      var attempts = 0;
      const maxAttempts = 50; // 50 * 100ms = 5 seconds

      while (!_isInitialized && attempts < maxAttempts) {
        await Future.delayed(const Duration(milliseconds: 100));
        attempts++;
        DebugLogger.log('TTS: Waiting for initialization... attempt $attempts');
      }

      if (!_isInitialized) {
        DebugLogger.error('TTS: Timeout waiting for initialization', null);
        return;
      }

      DebugLogger.log('TTS: Initialization completed, proceeding with speech');
    }

    if (_isSpeaking) {
      DebugLogger.log('TTS: Already speaking, stopping current speech');
      await stop();
    }

    try {
      // Get current language setting and log it
      final currentLanguages = await _flutterTts!.getLanguages;
      DebugLogger.log('TTS: Available languages: $currentLanguages');

      // Clean up text for better TTS pronunciation
      final cleanText = _preprocessTextForTTS(text);

      DebugLogger.log(
        'TTS: Speaking text: ${cleanText.substring(0, cleanText.length > 50 ? 50 : cleanText.length)}...',
      );
      _isSpeaking = true;
      _currentMessageId = messageId;

      await _flutterTts!.speak(cleanText);
    } catch (e) {
      DebugLogger.error('TTS: Failed to speak text', e);
      _isSpeaking = false;
      _currentMessageId = null;
    }
  }

  /// Stop current speech
  Future<void> stop() async {
    if (_flutterTts != null && _isSpeaking) {
      try {
        await _flutterTts!.stop();
        _isSpeaking = false;
        _currentMessageId = null;
        DebugLogger.log('TTS: Speech stopped');
      } catch (e) {
        DebugLogger.error('TTS: Failed to stop speech', e);
      }
    }
  }

  /// Pause current speech
  Future<void> pause() async {
    if (_flutterTts != null && _isSpeaking) {
      try {
        await _flutterTts!.pause();
        DebugLogger.log('TTS: Speech paused');
      } catch (e) {
        DebugLogger.error('TTS: Failed to pause speech', e);
      }
    }
  }

  /// Check if TTS is currently speaking
  bool get isSpeaking => _isSpeaking;

  /// Check if a specific message is currently being spoken
  bool isPlayingMessage(String messageId) =>
      _isSpeaking && _currentMessageId == messageId;

  /// Get the currently playing message ID
  String? get currentMessageId => _currentMessageId;

  /// Check if TTS is available on this platform
  bool get isAvailable => Platform.isAndroid || Platform.isIOS;

  /// Check if TTS service is initialized
  bool get isInitialized => _isInitialized;

  /// Update the TTS language setting
  Future<void> updateLanguage(String? languageCode) async {
    DebugLogger.log(
      'TTS: updateLanguage called with languageCode: $languageCode',
    );

    if (!_isInitialized) {
      DebugLogger.log(
        'TTS: Service not initialized, calling initializeWithLanguage',
      );
      await initializeWithLanguage(languageCode);
      return;
    }

    final targetLanguage = _resolveTargetLanguage(languageCode);
    DebugLogger.log('TTS: Resolved target language: $targetLanguage');

    try {
      await _flutterTts!.setLanguage(targetLanguage);
      DebugLogger.log('TTS: Language updated successfully to $targetLanguage');
    } catch (e) {
      DebugLogger.error('TTS: Failed to update language to $targetLanguage', e);
    }
  }

  /// Resolve the target language based on user setting and system locale
  String _resolveTargetLanguage(String? languageCode) {
    if (languageCode != null) {
      return languageCode;
    }

    // When languageCode is null (System), try to use system locale
    // This could be enhanced to detect system language, for now default to en-US
    // TODO: In future, could use Platform.localeName or Intl.systemLocale
    return 'en-US';
  }

  /// Test TTS with a simple phrase
  Future<bool> testTTS() async {
    try {
      await speak('TTS test successful', messageId: 'test');
      return true;
    } catch (e) {
      DebugLogger.error('TTS: Test failed', e);
      return false;
    }
  }

  /// Preprocess text to improve TTS pronunciation (remove special characters and markdown symbols)
  String _preprocessTextForTTS(String text) {
    String processed = text;

    // Remove code blocks first (they contain backticks that could interfere)
    processed = processed.replaceAll(
      RegExp(r'```[\s\S]*?```'),
      ' [code block] ',
    );

    // Remove markdown formatting - keep the content, remove the formatting
    processed = processed.replaceAllMapped(
      RegExp(r'\*\*(.*?)\*\*'),
      (match) => match.group(1) ?? '',
    ); // **bold**
    processed = processed.replaceAllMapped(
      RegExp(r'\*(.*?)\*'),
      (match) => match.group(1) ?? '',
    ); // *italic*
    processed = processed.replaceAllMapped(
      RegExp(r'`([^`]+)`'),
      (match) => match.group(1) ?? '',
    ); // `code`

    // Remove headers but keep the text
    processed = processed.replaceAllMapped(
      RegExp(r'^#{1,6}\s+(.*)$', multiLine: true),
      (match) => match.group(1) ?? '',
    );

    // Remove links but keep the text: [text](url) -> text
    processed = processed.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\([^)]+\)'),
      (match) => match.group(1) ?? '',
    );

    // Remove remaining markdown artifacts
    processed = processed.replaceAll(
      RegExp(r'[_~]'),
      '',
    ); // underlines and strikethroughs
    processed = processed.replaceAll(RegExp(r'>\s*'), ''); // blockquotes

    // Replace symbols with speakable text ONLY when they're standalone or at word boundaries
    processed = processed.replaceAll(RegExp(r'\b&\b'), ' and ');
    processed = processed.replaceAll(RegExp(r'\b@\b'), ' at ');
    processed = processed.replaceAll(
      RegExp(r'(?<!\w)#(?!\w)'),
      ' hash ',
    ); // # not part of words
    processed = processed.replaceAll(
      RegExp(r'(?<!\d)%(?!\d)'),
      ' percent',
    ); // % not between digits

    // Handle dollar sign more carefully - only replace standalone $ or at word boundaries
    processed = processed.replaceAll(
      RegExp(r'(?<!\w)\$(?=\d)'),
      'dollar ',
    ); // $100 -> dollar 100
    processed = processed.replaceAll(
      RegExp(r'(?<!\w)\$(?!\w)'),
      ' dollar ',
    ); // standalone $

    // Clean up multiple spaces and trim
    processed = processed.replaceAll(RegExp(r'\s+'), ' ');
    processed = processed.trim();

    // Limit length for very long responses (TTS can timeout)
    if (processed.length > 1000) {
      // Find a good breaking point (end of sentence)
      final sentences = processed.split(RegExp(r'[.!?]+\s+'));
      final truncated = StringBuffer();
      for (final sentence in sentences) {
        if (truncated.length + sentence.length > 950) break;
        truncated.write(sentence.trim());
        if (!sentence.trim().endsWith('.') &&
            !sentence.trim().endsWith('!') &&
            !sentence.trim().endsWith('?')) {
          truncated.write('.');
        }
        truncated.write(' ');
      }
      processed = truncated.toString().trim();
      if (!processed.endsWith('.') &&
          !processed.endsWith('!') &&
          !processed.endsWith('?')) {
        processed = '$processed. Response truncated for voice playback.';
      }
    }

    return processed;
  }

  /// Dispose of resources
  void dispose() {
    _flutterTts?.stop();
    _isInitialized = false;
    _isSpeaking = false;
    DebugLogger.log('TTS: Service disposed');
  }
}

/// Provider for the TTS service
final ttsServiceProvider = Provider<TTSService>((ref) {
  DebugLogger.log('TTS: ttsServiceProvider called');

  final service = TTSService.instance;

  // Ensure the language updater is active first
  ref.read(ttsLanguageUpdaterProvider);

  // Only initialize if not already initialized
  if (!service.isInitialized) {
    final ttsLanguage = ref.read(ttsLanguageProvider);
    DebugLogger.log('TTS: Initial initialization with language: $ttsLanguage');
    service.initializeWithLanguage(ttsLanguage);
  } else {
    DebugLogger.log(
      'TTS: Service already initialized, skipping re-initialization',
    );
  }

  return service;
});

/// Provider to listen for TTS language changes and update the service
final ttsLanguageUpdaterProvider = Provider<void>((ref) {
  // Watch for language changes
  ref.listen(ttsLanguageProvider, (previous, next) {
    // Only update if the language actually changed
    if (previous != next) {
      final service = TTSService.instance;
      service.updateLanguage(next);
    }
  });
});

/// Provider for TTS message control
final ttsMessageControllerProvider =
    StateNotifierProvider<TTSMessageController, Map<String, bool>>((ref) {
      return TTSMessageController(ref);
    });

/// Controller for TTS message playback state
class TTSMessageController extends StateNotifier<Map<String, bool>> {
  final Ref _ref;

  TTSMessageController(this._ref) : super(<String, bool>{}) {
    DebugLogger.log('TTS: TTSMessageController initialized');

    // Initialize the language updater
    _ref.read(ttsLanguageUpdaterProvider);

    DebugLogger.log('TTS: TTSMessageController setup complete');
  }

  /// Toggle TTS playback for a specific message
  Future<void> toggleTTS(String messageId, String messageText) async {
    await playTTS(messageId, messageText, toggle: true);
  }

  /// Play TTS for a specific message
  Future<void> playTTS(
    String messageId,
    String messageText, {
    bool toggle = false,
  }) async {
    DebugLogger.log(
      'TTS: playTTS called for message $messageId, toggle: $toggle',
    );

    final ttsService = _ref.read(ttsServiceProvider);
    final isCurrentlyPlaying = ttsService.isPlayingMessage(messageId);

    DebugLogger.log(
      'TTS: Currently playing: $isCurrentlyPlaying, TTS service speaking: ${ttsService.isSpeaking}',
    );

    if (isCurrentlyPlaying && toggle) {
      // Stop current playback (only if toggling)
      DebugLogger.log('TTS: Stopping current playback for toggle');
      await ttsService.stop();
      state = {...state}..remove(messageId);
    } else if (!isCurrentlyPlaying) {
      // Stop any other playing message first
      if (ttsService.isSpeaking) {
        DebugLogger.log('TTS: Stopping other playing message');
        await ttsService.stop();
        state = <String, bool>{}; // Clear all playing states
      }

      // Start playing this message
      DebugLogger.log('TTS: Starting playback for message $messageId');
      state = {...state, messageId: true};
      await ttsService.speak(messageText, messageId: messageId);

      // The completion handler in TTS service will automatically update state
      // Add a listener to update state when speech completes
      _checkCompletionPeriodically(messageId);
    }
  }

  /// Check if TTS has completed and update state accordingly
  void _checkCompletionPeriodically(String messageId) {
    Future.delayed(const Duration(milliseconds: 500), () {
      final ttsService = _ref.read(ttsServiceProvider);
      if (!ttsService.isPlayingMessage(messageId) &&
          state.containsKey(messageId)) {
        state = {...state}..remove(messageId);
      } else if (state.containsKey(messageId)) {
        // Still playing, check again
        _checkCompletionPeriodically(messageId);
      }
    });
  }

  /// Check if a message is currently playing
  bool isPlaying(String messageId) => state[messageId] ?? false;

  /// Stop all TTS playback
  Future<void> stopAll() async {
    final ttsService = _ref.read(ttsServiceProvider);
    await ttsService.stop();
    state = <String, bool>{};
  }
}
