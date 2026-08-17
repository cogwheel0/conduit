import 'dart:async';

import '../utils/debug_logger.dart';

/// Signature for callbacks that receive streaming text updates.
typedef StreamingChunkCallback = void Function(String chunk);

/// Signature for callbacks invoked when a streaming session finishes.
typedef StreamingCompletionCallback = void Function();

/// Signature for callbacks invoked when a streaming session encounters an
/// error.
typedef StreamingErrorCallback = void Function(
  Object error,
  StackTrace stackTrace,
);

/// A lightweight controller that manages the lifecycle of a streamed response.
///
/// This wraps a [StreamSubscription], normalises error handling, and exposes
/// a unified cancel method so UI layers can stop streaming without having to
/// know the underlying transport (WebSocket, polling, etc.).
class StreamingResponseController {
  StreamingResponseController({
    required Stream<String> stream,
    required StreamingChunkCallback onChunk,
    required StreamingCompletionCallback onComplete,
    required StreamingErrorCallback onError,
    bool cancelOnError = true,
  }) : _onChunk = onChunk,
       _onComplete = onComplete,
       _onError = onError {
    _subscription = stream.listen(
      _handleChunk,
      cancelOnError: cancelOnError,
      onDone: _handleCompleted,
      onError: _handleError,
    );
  }

  final StreamingChunkCallback _onChunk;
  final StreamingCompletionCallback _onComplete;
  final StreamingErrorCallback _onError;

  StreamSubscription<String>? _subscription;
  bool _isCancelled = false;

  /// Whether the underlying stream subscription is still active.
  bool get isActive => _subscription != null && !_isCancelled;

  void _handleChunk(String chunk) {
    if (_isCancelled) {
      return;
    }
    try {
      _onChunk(chunk);
    } catch (err, stackTrace) {
      DebugLogger.error(
        'streaming-chunk-handler-failed',
        scope: 'streaming/controller',
        error: err,
      );
      _handleError(err, stackTrace);
    }
  }

  void _handleCompleted() {
    if (_isCancelled) {
      return;
    }
    _subscription = null;
    try {
      _onComplete();
    } catch (err, stackTrace) {
      _handleError(err, stackTrace);
    }
  }

  void _handleError(Object error, StackTrace stackTrace) {
    if (_isCancelled) {
      return;
    }
    _subscription = null;
    _onError(error, stackTrace);
  }

  /// Cancels the underlying stream subscription.
  Future<void> cancel() async {
    if (_isCancelled) {
      return;
    }
    _isCancelled = true;
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
  }
}
