import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import '../utils/debug_logger.dart';

/// Handles background streaming continuation for iOS and Android.
///
/// This service keeps the app alive when streaming content in the background,
/// ensuring that chat responses, voice calls, and socket connections continue
/// even when the app is not in the foreground.
///
/// ## Platform Implementations
///
/// ### iOS
/// - Uses `beginBackgroundTask` for ~30 seconds of execution
/// - Uses `BGProcessingTask` for extended time (~1-3 minutes when granted)
/// - **Limitation**: iOS may not grant extended time; streams may be interrupted
/// - Audio mode (`UIBackgroundModes: audio`) provides reliable background for voice calls
///
/// ### Android
/// - Uses foreground service with notification (reliable, can run for hours)
/// - Acquires wake lock to prevent CPU sleep during active streaming
/// - **Android 14+**: dataSync services limited to 6 hours (we stop at 5h with warning)
///
/// ## Usage
///
/// For most streaming operations, only [startBackgroundExecution] and
/// [stopBackgroundExecution] are needed:
///
/// ```dart
/// // When streaming starts
/// await BackgroundStreamingHandler.instance.startBackgroundExecution(['stream-123']);
///
/// // When streaming completes
/// await BackgroundStreamingHandler.instance.stopBackgroundExecution(['stream-123']);
/// ```
///
/// For extended background sessions (e.g., voice calls), call [keepAlive] periodically:
///
/// ```dart
/// Timer.periodic(Duration(minutes: 5), (_) {
///   BackgroundStreamingHandler.instance.keepAlive();
/// });
/// ```
class BackgroundStreamingHandler {
  static const MethodChannel _channel = MethodChannel(
    'qonduit/background_streaming',
  );

  /// Stream ID used for socket keepalive - not counted as an "active stream"
  /// since it's a background task, not user-visible streaming.
  static const String socketKeepaliveId = 'socket-keepalive';

  static BackgroundStreamingHandler? _instance;
  static BackgroundStreamingHandler get instance =>
      _instance ??= BackgroundStreamingHandler._();

  BackgroundStreamingHandler._() {
    _setupMethodCallHandler();
  }

  final Set<String> _activeStreamIds = <String>{};
  final Set<String> _microphoneStreamIds = <String>{};
  bool _initialized = false;

  /// Initialize the background streaming handler with callbacks.
  ///
  /// This should be called once during app startup to register error and
  /// event callbacks.
  Future<void> initialize({
    void Function(String error, String errorType, List<String> streamIds)?
    serviceFailedCallback,
    void Function(int remainingMinutes)? timeLimitApproachingCallback,
    void Function()? microphonePermissionFallbackCallback,
    void Function(List<String> streamIds)? streamsSuspendingCallback,
    void Function()? backgroundTaskExpiringCallback,
    void Function(List<String> streamIds, int estimatedSeconds)?
    backgroundTaskExtendedCallback,
    void Function()? backgroundKeepAliveCallback,
  }) async {
    if (_initialized) {
      DebugLogger.stream('already-initialized', scope: 'background');
      return;
    }
    _initialized = true;

    // Register callbacks
    onServiceFailed = serviceFailedCallback;
    onBackgroundTimeLimitApproaching = timeLimitApproachingCallback;
    onMicrophonePermissionFallback = microphonePermissionFallbackCallback;
    onStreamsSuspending = streamsSuspendingCallback;
    onBackgroundTaskExpiring = backgroundTaskExpiringCallback;
    onBackgroundTaskExtended = backgroundTaskExtendedCallback;
    onBackgroundKeepAlive = backgroundKeepAliveCallback;

    DebugLogger.stream('initialized', scope: 'background');
  }

  /// Returns count of actual content streams (excludes socket keepalive).
  int get _userVisibleStreamCount =>
      _activeStreamIds.where((id) => id != socketKeepaliveId).length;

  // Callbacks for platform-specific events
  void Function(List<String> streamIds)? onStreamsSuspending;
  void Function()? onBackgroundTaskExpiring;
  void Function(List<String> streamIds, int estimatedSeconds)?
  onBackgroundTaskExtended;
  void Function()? onBackgroundKeepAlive;
  bool Function()? shouldContinueInBackground;
  void Function(String error, String errorType, List<String> streamIds)?
  onServiceFailed;

  /// Called when Android 14's foreground service time limit is reached.
  /// The service stops after 5 hours (buffer before Android's 6-hour limit).
  /// [remainingMinutes] will be 0 when this is called.
  void Function(int remainingMinutes)? onBackgroundTimeLimitApproaching;

  /// Called when microphone permission was requested but not granted,
  /// causing fallback to dataSync-only foreground service type.
  void Function()? onMicrophonePermissionFallback;

  void _setupMethodCallHandler() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'checkStreams':
          return _activeStreamIds.length;

        case 'streamsSuspending':
          final Map<String, dynamic> args =
              call.arguments as Map<String, dynamic>;
          final List<String> streamIds = (args['streamIds'] as List)
              .cast<String>();
          final String reason = args['reason'] as String;

          DebugLogger.stream(
            'suspending',
            scope: 'background',
            data: {'count': streamIds.length, 'reason': reason},
          );
          onStreamsSuspending?.call(streamIds);
          break;

        case 'backgroundTaskExpiring':
          DebugLogger.stream('task-expiring', scope: 'background');
          onBackgroundTaskExpiring?.call();
          break;

        case 'backgroundTaskExtended':
          final Map<String, dynamic> args =
              call.arguments as Map<String, dynamic>;
          final List<String> streamIds = (args['streamIds'] as List)
              .cast<String>();
          final int estimatedTime = args['estimatedTime'] as int;

          DebugLogger.stream(
            'task-extended',
            scope: 'background',
            data: {'count': streamIds.length, 'time': estimatedTime},
          );
          onBackgroundTaskExtended?.call(streamIds, estimatedTime);
          break;

        case 'backgroundKeepAlive':
          DebugLogger.stream('keepalive-signal', scope: 'background');
          onBackgroundKeepAlive?.call();
          break;

        case 'serviceFailed':
          final Map<String, dynamic> args =
              call.arguments as Map<String, dynamic>;
          final String error = args['error'] as String? ?? 'Unknown error';
          final String errorType = args['errorType'] as String? ?? 'Exception';
          final List<String> streamIds =
              (args['streamIds'] as List?)?.cast<String>() ?? [];

          DebugLogger.error(
            'service-failed',
            scope: 'background',
            error: error,
            data: {'type': errorType, 'streams': streamIds.length},
          );

          // Notify callback about service failure
          onServiceFailed?.call(error, errorType, streamIds);

          // Clean up failed streams
          for (final streamId in streamIds) {
            _activeStreamIds.remove(streamId);
          }
          break;

        case 'timeLimitApproaching':
          final Map<String, dynamic> args =
              call.arguments as Map<String, dynamic>;
          final int remainingMinutes = args['remainingMinutes'] as int? ?? -1;

          DebugLogger.stream(
            'time-limit-approaching',
            scope: 'background',
            data: {'remainingMinutes': remainingMinutes},
          );

          onBackgroundTimeLimitApproaching?.call(remainingMinutes);
          break;

        case 'microphonePermissionFallback':
          DebugLogger.stream('mic-permission-fallback', scope: 'background');

          onMicrophonePermissionFallback?.call();
          break;
      }
    });
  }

  /// Start background execution for given stream IDs
  Future<void> startBackgroundExecution(
    List<String> streamIds, {
    bool requiresMicrophone = false,
  }) async {
    if (!Platform.isIOS && !Platform.isAndroid) return;

    try {
      await _channel.invokeMethod('startBackgroundExecution', {
        'streamIds': streamIds,
        'requiresMicrophone': requiresMicrophone,
      });

      // Only add to active streams after successful platform call
      _activeStreamIds.addAll(streamIds);

      // Track which streams require microphone for reconciliation
      if (requiresMicrophone) {
        _microphoneStreamIds.addAll(streamIds);
      }

      DebugLogger.stream(
        'start',
        scope: 'background',
        data: {'count': streamIds.length, 'mic': requiresMicrophone},
      );
    } catch (e) {
      DebugLogger.error(
        'start-failed',
        scope: 'background',
        error: e,
        data: {'count': streamIds.length},
      );
      // Re-throw so callers know the background execution failed
      rethrow;
    }
  }

  /// Stop background execution for given stream IDs
  Future<void> stopBackgroundExecution(List<String> streamIds) async {
    if (!Platform.isIOS && !Platform.isAndroid) return;

    try {
      await _channel.invokeMethod('stopBackgroundExecution', {
        'streamIds': streamIds,
      });

      // Only remove from tracking after successful platform call
      // to maintain state consistency between Flutter and native layers
      _activeStreamIds.removeAll(streamIds);
      _microphoneStreamIds.removeAll(streamIds);

      DebugLogger.stream(
        'stop',
        scope: 'background',
        data: {'count': streamIds.length},
      );
    } catch (e) {
      // Still remove from local tracking on error - the platform may have
      // already stopped, and keeping stale state causes issues
      _activeStreamIds.removeAll(streamIds);
      _microphoneStreamIds.removeAll(streamIds);

      DebugLogger.error(
        'stop-failed',
        scope: 'background',
        error: e,
        data: {'count': streamIds.length},
      );
    }
  }

  /// Keep alive the background task
  ///
  /// On iOS: Refreshes background task to prevent early termination
  /// On Android: Refreshes wake lock to keep service running
  ///
  /// Returns true if keep-alive succeeded, false otherwise.
  Future<bool> keepAlive() async {
    if (!Platform.isIOS && !Platform.isAndroid) return true;

    // Skip keep-alive if no active streams - this ensures Android's count
    // stays synchronized with Flutter's actual state
    if (_activeStreamIds.isEmpty) return true;

    try {
      await _channel.invokeMethod('keepAlive', {
        // Pass user-visible stream count (excludes socket-keepalive)
        // for accurate logging, but service still runs for any background task
        'streamCount': _userVisibleStreamCount,
      });
      DebugLogger.stream('keepalive-success', scope: 'background');
      return true;
    } catch (e) {
      DebugLogger.error('keepalive-failed', scope: 'background', error: e);
      return false;
    }
  }

  /// Check if background app refresh is enabled (iOS only).
  ///
  /// Returns true on Android or if iOS background refresh is available.
  /// Returns false if iOS background refresh is disabled by user.
  Future<bool> checkBackgroundRefreshStatus() async {
    if (!Platform.isIOS) return true;

    try {
      final bool? status = await _channel.invokeMethod<bool>(
        'checkBackgroundRefreshStatus',
      );
      return status ?? true;
    } catch (e) {
      DebugLogger.error(
        'check-background-refresh-failed',
        scope: 'background',
        error: e,
      );
      return true; // Assume available on error to not block functionality
    }
  }

  /// Check if notification permission is granted (Android 13+ only).
  ///
  /// Returns true on iOS, Android < 13, or if permission is granted.
  /// Returns false if Android 13+ and permission is not granted.
  Future<bool> checkNotificationPermission() async {
    if (!Platform.isAndroid) return true;

    try {
      final bool? hasPermission = await _channel.invokeMethod<bool>(
        'checkNotificationPermission',
      );
      return hasPermission ?? true;
    } catch (e) {
      DebugLogger.error(
        'check-notification-permission-failed',
        scope: 'background',
        error: e,
      );
      return true; // Assume granted on error to not block functionality
    }
  }

  /// Check if any streams are currently active
  bool get hasActiveStreams => _activeStreamIds.isNotEmpty;

  /// Get list of active stream IDs
  List<String> get activeStreamIds => _activeStreamIds.toList();

  /// Notify the native layer that an external component (e.g., speech_to_text
  /// plugin) is managing the audio session.
  ///
  /// On iOS, this prevents VoiceBackgroundAudioManager from conflicting with
  /// the speech_to_text plugin's audio session management.
  /// On Android, this is a no-op as audio session management is different.
  Future<void> setExternalAudioSessionOwner(bool isExternal) async {
    if (!Platform.isIOS) return;

    try {
      await _channel.invokeMethod('setExternalAudioSessionOwner', {
        'isExternal': isExternal,
      });
      DebugLogger.stream(
        isExternal
            ? 'external-audio-owner-set'
            : 'external-audio-owner-cleared',
        scope: 'background',
      );
    } catch (e) {
      DebugLogger.error(
        'set-external-audio-owner-failed',
        scope: 'background',
        error: e,
      );
    }
  }

  /// Clear all stream data (usually on app termination)
  void clearAll() {
    _activeStreamIds.clear();
    _microphoneStreamIds.clear();
  }

  /// Reconcile Flutter state with native platform state.
  ///
  /// This should be called on app resume to detect and fix state drift
  /// caused by native service crashes or other edge cases. Returns true
  /// if reconciliation was needed and performed.
  Future<bool> reconcileState() async {
    if (!Platform.isIOS && !Platform.isAndroid) return false;

    try {
      final int? nativeCount = await _channel.invokeMethod<int>(
        'getActiveStreamCount',
      );

      if (nativeCount == null) return false;

      // If native has streams but Flutter doesn't, the native service is orphaned
      if (nativeCount > 0 && _activeStreamIds.isEmpty) {
        DebugLogger.warning(
          'reconcile-orphaned-service',
          scope: 'background',
          data: {'nativeCount': nativeCount},
        );
        // Stop the orphaned native service
        await _channel.invokeMethod('stopAllBackgroundExecution');
        return true;
      }

      // If Flutter has streams but native doesn't, restart the service
      if (_activeStreamIds.isNotEmpty && nativeCount == 0) {
        // Preserve microphone requirement from tracked streams
        final requiresMicrophone = _microphoneStreamIds.isNotEmpty;
        DebugLogger.warning(
          'reconcile-restart-service',
          scope: 'background',
          data: {
            'flutterCount': _activeStreamIds.length,
            'requiresMic': requiresMicrophone,
          },
        );
        // Restart background execution for active streams with preserved capabilities
        await _channel.invokeMethod('startBackgroundExecution', {
          'streamIds': _activeStreamIds.toList(),
          'requiresMicrophone': requiresMicrophone,
        });
        return true;
      }

      return false;
    } catch (e) {
      DebugLogger.error('reconcile-failed', scope: 'background', error: e);
      return false;
    }
  }
}
