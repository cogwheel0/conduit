import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import '../utils/debug_logger.dart';

/// Handles background streaming continuation for iOS and Android
///
/// On iOS: Uses beginBackgroundTask (~30s) + BGTaskScheduler (~3+ minutes)
/// On Android: Uses foreground service notifications
class BackgroundStreamingHandler {
  static const MethodChannel _channel = MethodChannel(
    'conduit/background_streaming',
  );

  static BackgroundStreamingHandler? _instance;
  static BackgroundStreamingHandler get instance =>
      _instance ??= BackgroundStreamingHandler._();

  BackgroundStreamingHandler._() {
    _setupMethodCallHandler();
  }

  final Set<String> _activeStreamIds = <String>{};
  final Map<String, StreamState> _streamStates = <String, StreamState>{};

  // Callbacks for platform-specific events
  void Function(List<String> streamIds)? onStreamsSuspending;
  void Function()? onBackgroundTaskExpiring;
  void Function(List<String> streamIds, int estimatedSeconds)?
  onBackgroundTaskExtended;
  void Function()? onBackgroundKeepAlive;
  bool Function()? shouldContinueInBackground;

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

          // Save stream states for recovery
          await saveStreamStatesForRecovery(streamIds, reason);
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
      }
    });
  }

  /// Start background execution for given stream IDs
  Future<void> startBackgroundExecution(
    List<String> streamIds, {
    bool requiresMicrophone = false,
  }) async {
    if (!Platform.isIOS && !Platform.isAndroid) return;

    _activeStreamIds.addAll(streamIds);

    try {
      await _channel.invokeMethod('startBackgroundExecution', {
        'streamIds': streamIds,
        'requiresMicrophone': requiresMicrophone,
      });

      DebugLogger.stream(
        'start',
        scope: 'background',
        data: {'count': streamIds.length},
      );
    } catch (e) {
      DebugLogger.error(
        'start-failed',
        scope: 'background',
        error: e,
        data: {'count': streamIds.length},
      );
    }
  }

  /// Stop background execution for given stream IDs
  Future<void> stopBackgroundExecution(List<String> streamIds) async {
    if (!Platform.isIOS && !Platform.isAndroid) return;

    _activeStreamIds.removeAll(streamIds);
    streamIds.forEach(_streamStates.remove);

    try {
      await _channel.invokeMethod('stopBackgroundExecution', {
        'streamIds': streamIds,
      });

      DebugLogger.stream(
        'stop',
        scope: 'background',
        data: {'count': streamIds.length},
      );
    } catch (e) {
      DebugLogger.error(
        'stop-failed',
        scope: 'background',
        error: e,
        data: {'count': streamIds.length},
      );
    }
  }

  /// Register a stream with its current state
  void registerStream(
    String streamId, {
    required String conversationId,
    required String messageId,
    String? sessionId,
    int? lastChunkSequence,
    String? lastContent,
  }) {
    _streamStates[streamId] = StreamState(
      streamId: streamId,
      conversationId: conversationId,
      messageId: messageId,
      sessionId: sessionId,
      lastChunkSequence: lastChunkSequence ?? 0,
      lastContent: lastContent ?? '',
      timestamp: DateTime.now(),
    );

    _activeStreamIds.add(streamId);
  }

  /// Update stream state with new chunk
  void updateStreamState(
    String streamId, {
    int? chunkSequence,
    String? content,
    String? appendedContent,
  }) {
    final state = _streamStates[streamId];
    if (state == null) return;

    _streamStates[streamId] = state.copyWith(
      lastChunkSequence: chunkSequence ?? state.lastChunkSequence,
      lastContent: appendedContent != null
          ? (state.lastContent + appendedContent)
          : (content ?? state.lastContent),
      timestamp: DateTime.now(),
    );
  }

  /// Unregister a stream when it completes
  void unregisterStream(String streamId) {
    _activeStreamIds.remove(streamId);
    _streamStates.remove(streamId);
  }

  /// Get current stream state for recovery
  StreamState? getStreamState(String streamId) {
    return _streamStates[streamId];
  }

  /// Keep alive the background task
  ///
  /// On iOS: Refreshes background task to prevent early termination
  /// On Android: Refreshes wake lock to keep service running
  Future<void> keepAlive() async {
    if (!Platform.isIOS && !Platform.isAndroid) return;

    try {
      await _channel.invokeMethod('keepAlive');
      DebugLogger.stream('keepalive-success', scope: 'background');
    } catch (e) {
      DebugLogger.error('keepalive-failed', scope: 'background', error: e);
    }
  }

  /// Recover stream states from previous app session
  Future<List<StreamState>> recoverStreamStates() async {
    if (!Platform.isIOS && !Platform.isAndroid) return [];

    try {
      final List<dynamic>? states = await _channel.invokeMethod(
        'recoverStreamStates',
      );
      if (states == null) return [];

      final recovered = <StreamState>[];
      for (final stateData in states) {
        // Platform channels return Map<Object?, Object?>, need to convert
        final map = Map<String, dynamic>.from(stateData as Map);
        final state = StreamState.fromMap(map);
        if (state != null) {
          recovered.add(state);
          _streamStates[state.streamId] = state;
        }
      }

      DebugLogger.stream(
        'recovered',
        scope: 'background',
        data: {'count': recovered.length},
      );
      return recovered;
    } catch (e) {
      DebugLogger.error('recover-failed', scope: 'background', error: e);
      return [];
    }
  }

  /// Save stream states for recovery after app restart
  Future<void> saveStreamStatesForRecovery(
    List<String> streamIds,
    String reason,
  ) async {
    // Skip on desktop platforms (macOS, Windows, Linux, web)
    if (!Platform.isIOS && !Platform.isAndroid) {
      DebugLogger.stream(
        'skip-desktop',
        scope: 'background',
        data: {'platform': Platform.operatingSystem},
      );
      return;
    }

    DebugLogger.stream(
      'saveStreamStatesForRecovery called',
      scope: 'background',
      data: {
        'streamIds': streamIds,
        'reason': reason,
        'statesCount': _streamStates.length,
      },
    );

    final statesToSave = streamIds
        .map((id) => _streamStates[id])
        .where((state) => state != null)
        .map((state) => state!.toMap())
        .toList();

    DebugLogger.stream(
      'statesToSave prepared',
      scope: 'background',
      data: {'count': statesToSave.length},
    );

    try {
      await _channel.invokeMethod('saveStreamStates', {
        'states': statesToSave,
        'reason': reason,
      });
      DebugLogger.stream(
        'save-states-success',
        scope: 'background',
        data: {'count': statesToSave.length, 'reason': reason},
      );
    } catch (e) {
      DebugLogger.error(
        'save-states-failed',
        scope: 'background',
        error: e,
        data: {'count': streamIds.length, 'reason': reason},
      );
    }
  }

  /// Check if any streams are currently active
  bool get hasActiveStreams => _activeStreamIds.isNotEmpty;

  /// Get list of active stream IDs
  List<String> get activeStreamIds => _activeStreamIds.toList();

  /// Clear all stream data (usually on app termination)
  void clearAll() {
    _activeStreamIds.clear();
    _streamStates.clear();
  }
}

/// Represents the state of a streaming request
class StreamState {
  final String streamId;
  final String conversationId;
  final String messageId;
  final String? sessionId;
  final int lastChunkSequence;
  final String lastContent;
  final DateTime timestamp;

  const StreamState({
    required this.streamId,
    required this.conversationId,
    required this.messageId,
    this.sessionId,
    required this.lastChunkSequence,
    required this.lastContent,
    required this.timestamp,
  });

  StreamState copyWith({
    String? streamId,
    String? conversationId,
    String? messageId,
    String? sessionId,
    int? lastChunkSequence,
    String? lastContent,
    DateTime? timestamp,
  }) {
    return StreamState(
      streamId: streamId ?? this.streamId,
      conversationId: conversationId ?? this.conversationId,
      messageId: messageId ?? this.messageId,
      sessionId: sessionId ?? this.sessionId,
      lastChunkSequence: lastChunkSequence ?? this.lastChunkSequence,
      lastContent: lastContent ?? this.lastContent,
      timestamp: timestamp ?? this.timestamp,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'streamId': streamId,
      'conversationId': conversationId,
      'messageId': messageId,
      'sessionId': sessionId,
      'lastChunkSequence': lastChunkSequence,
      'lastContent': lastContent,
      'timestamp': timestamp.millisecondsSinceEpoch,
    };
  }

  static StreamState? fromMap(Map<String, dynamic> map) {
    try {
      return StreamState(
        streamId: map['streamId'] as String,
        conversationId: map['conversationId'] as String,
        messageId: map['messageId'] as String,
        sessionId: map['sessionId'] as String?,
        lastChunkSequence: map['lastChunkSequence'] as int? ?? 0,
        lastContent: map['lastContent'] as String? ?? '',
        timestamp: DateTime.fromMillisecondsSinceEpoch(
          map['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } catch (e) {
      DebugLogger.error('parse-failed', scope: 'background', error: e);
      return null;
    }
  }

  /// Check if this state is stale (older than threshold)
  bool isStale({Duration threshold = const Duration(minutes: 5)}) {
    return DateTime.now().difference(timestamp) > threshold;
  }

  @override
  String toString() {
    return 'StreamState(streamId: $streamId, conversationId: $conversationId, '
        'messageId: $messageId, sequence: $lastChunkSequence, '
        'contentLength: ${lastContent.length}, timestamp: $timestamp)';
  }
}
