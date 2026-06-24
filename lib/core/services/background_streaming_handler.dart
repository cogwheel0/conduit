import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../platform/conduit_platform_apis.g.dart';
import '../utils/debug_logger.dart';

enum BackgroundStreamKind {
  chat('chat'),
  voice('voice');

  const BackgroundStreamKind(this.platformValue);

  final String platformValue;

  PlatformBackgroundStreamKind get platformKind => switch (this) {
    BackgroundStreamKind.chat => PlatformBackgroundStreamKind.chat,
    BackgroundStreamKind.voice => PlatformBackgroundStreamKind.voice,
  };
}

class BackgroundStreamLease {
  const BackgroundStreamLease({
    required this.id,
    required this.kind,
    required this.requiresMicrophone,
    required this.startedAt,
  });

  final String id;
  final BackgroundStreamKind kind;
  final bool requiresMicrophone;
  final DateTime startedAt;

  Map<String, dynamic> toPlatformMap() => {
    'id': id,
    'kind': kind.platformValue,
    'requiresMicrophone': requiresMicrophone,
    'startedAt': startedAt.millisecondsSinceEpoch,
  };

  PlatformBackgroundStreamLease toPlatform() {
    return PlatformBackgroundStreamLease(
      id: id,
      kind: kind.platformKind,
      requiresMicrophone: requiresMicrophone,
      startedAtMillis: startedAt.millisecondsSinceEpoch,
    );
  }
}

class _NativeLeaseSnapshot {
  const _NativeLeaseSnapshot({
    required this.id,
    required this.kind,
    required this.requiresMicrophone,
  });

  final String id;
  final PlatformBackgroundStreamKind kind;
  final bool requiresMicrophone;

  static _NativeLeaseSnapshot fromPlatform(
    PlatformBackgroundStreamLease value,
  ) {
    return _NativeLeaseSnapshot(
      id: value.id,
      kind: value.kind,
      requiresMicrophone: value.requiresMicrophone,
    );
  }
}

@visibleForTesting
List<BackgroundStreamLease> buildBackgroundStreamLeasesForTesting(
  List<String> streamIds, {
  required bool requiresMicrophone,
  required BackgroundStreamKind kind,
  required DateTime startedAt,
}) {
  return _buildBackgroundStreamLeases(
    streamIds,
    requiresMicrophone: requiresMicrophone,
    kind: kind,
    startedAt: startedAt,
  );
}

List<BackgroundStreamLease> _buildBackgroundStreamLeases(
  List<String> streamIds, {
  required bool requiresMicrophone,
  required BackgroundStreamKind kind,
  required DateTime startedAt,
}) {
  return <BackgroundStreamLease>[
    for (final streamId in streamIds)
      if (streamId != BackgroundStreamingHandler.socketKeepaliveId)
        BackgroundStreamLease(
          id: streamId,
          kind: kind,
          requiresMicrophone: requiresMicrophone,
          startedAt: startedAt,
        ),
  ];
}

/// Handles background streaming continuation for iOS and Android.
///
/// This service keeps the app alive when streaming content in the background,
/// ensuring that chat responses and voice calls get short-lived native support
/// when the app is not in the foreground. Idle sockets reconnect on resume.
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
class BackgroundStreamingHandler implements BackgroundStreamingFlutterApi {
  /// Stream ID used for socket keepalive - not counted as an "active stream"
  /// since it's a background task, not user-visible streaming.
  static const String socketKeepaliveId = 'socket-keepalive';

  static BackgroundStreamingHandler? _instance;
  static BackgroundStreamingHandler get instance =>
      _instance ??= BackgroundStreamingHandler._();

  BackgroundStreamingHandler._() {
    BackgroundStreamingFlutterApi.setUp(this);
  }

  final BackgroundStreamingHostApi _api = BackgroundStreamingHostApi();
  final Map<String, BackgroundStreamLease> _activeLeases =
      <String, BackgroundStreamLease>{};
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
  int get _userVisibleStreamCount => _activeLeases.values
      .where((lease) => lease.id != socketKeepaliveId)
      .length;

  List<PlatformBackgroundStreamLease> get _platformLeases => _activeLeases
      .values
      .map((lease) => lease.toPlatform())
      .toList(growable: false);

  bool _nativeLeasesMatchFlutter(List<_NativeLeaseSnapshot> nativeLeases) {
    if (nativeLeases.length != _activeLeases.length) return false;

    for (final nativeLease in nativeLeases) {
      final flutterLease = _activeLeases[nativeLease.id];
      if (flutterLease == null ||
          flutterLease.kind.platformKind != nativeLease.kind ||
          flutterLease.requiresMicrophone != nativeLease.requiresMicrophone) {
        return false;
      }
    }

    return true;
  }

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

  @override
  int checkStreams() => _activeLeases.length;

  @override
  void streamsSuspending(PlatformStreamsSuspendingEvent event) {
    DebugLogger.stream(
      'suspending',
      scope: 'background',
      data: {'count': event.streamIds.length, 'reason': event.reason},
    );
    onStreamsSuspending?.call(event.streamIds);
  }

  @override
  void backgroundTaskExpiring() {
    DebugLogger.stream('task-expiring', scope: 'background');
    onBackgroundTaskExpiring?.call();
  }

  @override
  void backgroundTaskExtended(PlatformBackgroundTaskExtendedEvent event) {
    DebugLogger.stream(
      'task-extended',
      scope: 'background',
      data: {'count': event.streamIds.length, 'time': event.estimatedTime},
    );
    onBackgroundTaskExtended?.call(event.streamIds, event.estimatedTime);
  }

  @override
  void backgroundKeepAlive() {
    DebugLogger.stream('keepalive-signal', scope: 'background');
    onBackgroundKeepAlive?.call();
  }

  @override
  void serviceFailed(PlatformServiceFailureEvent event) {
    DebugLogger.error(
      'service-failed',
      scope: 'background',
      error: event.error,
      data: {'type': event.errorType, 'streams': event.streamIds.length},
    );

    onServiceFailed?.call(event.error, event.errorType, event.streamIds);

    for (final streamId in event.streamIds) {
      _activeLeases.remove(streamId);
    }
  }

  @override
  void timeLimitApproaching(PlatformTimeLimitWarningEvent event) {
    DebugLogger.stream(
      'time-limit-approaching',
      scope: 'background',
      data: {'remainingMinutes': event.remainingMinutes},
    );

    onBackgroundTimeLimitApproaching?.call(event.remainingMinutes);
  }

  @override
  void microphonePermissionFallback() {
    DebugLogger.stream('mic-permission-fallback', scope: 'background');
    onMicrophonePermissionFallback?.call();
  }

  /// Start background execution for given stream IDs
  Future<void> startBackgroundExecution(
    List<String> streamIds, {
    bool requiresMicrophone = false,
    BackgroundStreamKind kind = BackgroundStreamKind.chat,
  }) async {
    if (!Platform.isIOS && !Platform.isAndroid) return;
    final startedAt = DateTime.now();
    final newLeases = _buildBackgroundStreamLeases(
      streamIds,
      requiresMicrophone: requiresMicrophone,
      kind: kind,
      startedAt: startedAt,
    );
    if (newLeases.isEmpty) return;
    final effectiveStreamIds = newLeases
        .map((lease) => lease.id)
        .toList(growable: false);

    try {
      await _api.startBackgroundExecution(
        PlatformBackgroundStartRequest(
          streamIds: effectiveStreamIds,
          requiresMicrophone: requiresMicrophone,
          leases: newLeases.map((lease) => lease.toPlatform()).toList(),
        ),
      );

      // Only add to active streams after successful platform call
      for (final lease in newLeases) {
        _activeLeases[lease.id] = lease;
      }

      DebugLogger.stream(
        'start',
        scope: 'background',
        data: {
          'count': streamIds.length,
          'effectiveCount': effectiveStreamIds.length,
          'mic': requiresMicrophone,
          'kind': kind.platformValue,
        },
      );
    } catch (e) {
      DebugLogger.error(
        'start-failed',
        scope: 'background',
        error: e,
        data: {
          'count': streamIds.length,
          'effectiveCount': effectiveStreamIds.length,
        },
      );
      // Re-throw so callers know the background execution failed
      rethrow;
    }
  }

  /// Stop background execution for given stream IDs
  Future<void> stopBackgroundExecution(List<String> streamIds) async {
    if (!Platform.isIOS && !Platform.isAndroid) return;

    try {
      await _api.stopBackgroundExecution(
        PlatformBackgroundStopRequest(streamIds: streamIds),
      );

      // Only remove from tracking after successful platform call
      // to maintain state consistency between Flutter and native layers
      for (final streamId in streamIds) {
        _activeLeases.remove(streamId);
      }

      DebugLogger.stream(
        'stop',
        scope: 'background',
        data: {'count': streamIds.length},
      );
    } catch (e) {
      // Still remove from local tracking on error - the platform may have
      // already stopped, and keeping stale state causes issues
      for (final streamId in streamIds) {
        _activeLeases.remove(streamId);
      }

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
    if (_activeLeases.isEmpty) return true;

    try {
      await _api.keepAlive(
        PlatformBackgroundKeepAliveRequest(
          // Pass user-visible stream count (excludes socket-keepalive)
          // for accurate logging, but service still runs for any background task
          streamCount: _userVisibleStreamCount,
          leases: _platformLeases,
        ),
      );
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
      return await _api.checkBackgroundRefreshStatus();
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
      return await _api.checkNotificationPermission();
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
  bool get hasActiveStreams => _activeLeases.isNotEmpty;

  /// Get list of active stream IDs
  List<String> get activeStreamIds => _activeLeases.keys.toList();

  /// Notify the native layer that local speech recognition is managing the
  /// audio session.
  ///
  /// On iOS, this prevents VoiceBackgroundAudioManager from conflicting with
  /// the native STT audio session management.
  /// On Android, this is a no-op as audio session management is different.
  Future<void> setExternalAudioSessionOwner(bool isExternal) async {
    if (!Platform.isIOS) return;

    try {
      await _api.setExternalAudioSessionOwner(
        PlatformBackgroundAudioSessionOwnerRequest(isExternal: isExternal),
      );
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
    _activeLeases.clear();
  }

  /// Reconcile Flutter state with native platform state.
  ///
  /// This should be called on app resume to detect and fix state drift
  /// caused by native service crashes or other edge cases. Returns true
  /// if reconciliation was needed and performed.
  Future<bool> reconcileState() async {
    if (!Platform.isIOS && !Platform.isAndroid) return false;

    try {
      final nativeLeases = (await _api.getActiveStreamLeases())
          .map(_NativeLeaseSnapshot.fromPlatform)
          .toList(growable: false);
      final nativeCount = nativeLeases.length;

      // If native has streams but Flutter doesn't, the native service is orphaned
      if (nativeCount > 0 && _activeLeases.isEmpty) {
        DebugLogger.warning(
          'reconcile-orphaned-service',
          scope: 'background',
          data: {'nativeCount': nativeCount},
        );
        // Stop the orphaned native service
        await _api.stopAllBackgroundExecution();
        return true;
      }

      // If Flutter and native disagree on the lease set, restart native state.
      if (_activeLeases.isNotEmpty &&
          (nativeCount == 0 || !_nativeLeasesMatchFlutter(nativeLeases))) {
        // Preserve microphone requirement from tracked streams
        final requiresMicrophone = _activeLeases.values.any(
          (lease) => lease.requiresMicrophone,
        );
        DebugLogger.warning(
          'reconcile-restart-service',
          scope: 'background',
          data: {
            'flutterCount': _activeLeases.length,
            'requiresMic': requiresMicrophone,
          },
        );
        // Restart background execution for active streams with preserved capabilities
        await _api.startBackgroundExecution(
          PlatformBackgroundStartRequest(
            streamIds: _activeLeases.keys.toList(),
            requiresMicrophone: requiresMicrophone,
            leases: _platformLeases,
          ),
        );
        return true;
      }

      return false;
    } catch (e) {
      DebugLogger.error('reconcile-failed', scope: 'background', error: e);
      return false;
    }
  }
}
