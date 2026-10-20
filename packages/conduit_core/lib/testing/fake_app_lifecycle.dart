import 'dart:async';

import 'package:conduit_core/conduit_core.dart';

/// A drivable [AppLifecyclePort] for tests.
///
/// Before the port existed, engines observed `WidgetsBinding` directly and a
/// test had to push states through the real binding to exercise
/// foreground/background behaviour. Now a test constructs one of these and
/// calls [emit], which is both easier to read and free of global state.
///
/// Defaults to [AppLifecyclePhase.resumed] because that is what the binding
/// reports under `flutter_test`, so existing tests keep their old behaviour
/// without saying anything.
class FakeAppLifecycle implements AppLifecyclePort {
  FakeAppLifecycle({AppLifecyclePhase? initial = AppLifecyclePhase.resumed})
    : _current = initial;

  /// Synchronous on purpose. The framework used to deliver
  /// `didChangeAppLifecycleState` as a direct call, so tests assert right
  /// after driving a transition. A non-sync controller would defer delivery
  /// by a microtask and turn every one of those into a flake.
  final StreamController<AppLifecyclePhase> _controller =
      StreamController<AppLifecyclePhase>.broadcast(sync: true);

  AppLifecyclePhase? _current;

  @override
  AppLifecyclePhase? get current => _current;

  @override
  Stream<AppLifecyclePhase> get changes => _controller.stream;

  /// Moves to [phase] and notifies listeners, as the host would.
  void emit(AppLifecyclePhase phase) {
    _current = phase;
    _controller.add(phase);
  }

  Future<void> dispose() => _controller.close();
}
