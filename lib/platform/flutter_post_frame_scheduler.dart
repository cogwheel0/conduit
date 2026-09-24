import 'package:conduit_core/conduit_core.dart';
import 'package:flutter/widgets.dart';

/// The Flutter app's [PostFrameScheduler].
///
/// `addPostFrameCallback`, not `scheduleFrameCallback`: the caller wants the
/// current frame to finish before its work runs, and a frame callback would
/// run at the start of the *next* frame instead — which still leaves it
/// inside a build phase.
class FlutterPostFrameScheduler implements PostFrameScheduler {
  const FlutterPostFrameScheduler();

  @override
  void runAfterCurrentFrame(void Function() callback) {
    WidgetsBinding.instance.addPostFrameCallback((_) => callback());
  }
}
