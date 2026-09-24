import 'dart:io';

import 'package:conduit_core/conduit_core.dart';

import '../core/services/background_streaming_handler.dart';

/// The mobile [BackgroundExecutionPort].
///
/// Wraps the existing `BackgroundStreamingHandler`, which owns the pigeon
/// channel to the iOS background task and the Android foreground service.
///
/// The `Platform` test lives here rather than in the streaming code it used
/// to guard. That is the whole point of the port: desktop hosts bind
/// [NoBackgroundExecution] and never ask, so "which platforms support this"
/// stops being a question the send path has to answer.
class MobileBackgroundExecution implements BackgroundExecutionPort {
  const MobileBackgroundExecution();

  bool get _supported => Platform.isIOS || Platform.isAndroid;

  @override
  Future<void> begin(List<String> streamIds) async {
    if (!_supported) return;
    await BackgroundStreamingHandler.instance.startBackgroundExecution(
      streamIds,
    );
  }

  @override
  Future<void> end(List<String> streamIds) async {
    if (!_supported) return;
    await BackgroundStreamingHandler.instance.stopBackgroundExecution(
      streamIds,
    );
  }
}
