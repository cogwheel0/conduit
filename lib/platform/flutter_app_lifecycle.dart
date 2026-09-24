import 'dart:async';

import 'package:conduit_core/conduit_core.dart';
import 'package:flutter/widgets.dart';

/// The Flutter app's [AppLifecyclePort].
///
/// Registers exactly one `WidgetsBindingObserver` for the whole app. Before
/// this port existed, four engines each registered their own and each
/// re-derived what "foreground" meant; now they share one subscription and
/// one definition.
class FlutterAppLifecycle with WidgetsBindingObserver implements AppLifecyclePort {
  FlutterAppLifecycle() {
    WidgetsBinding.instance.addObserver(this);
  }

  final StreamController<AppLifecyclePhase> _controller =
      StreamController<AppLifecyclePhase>.broadcast();

  @override
  AppLifecyclePhase? get current => _map(WidgetsBinding.instance.lifecycleState);

  @override
  Stream<AppLifecyclePhase> get changes => _controller.stream;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final phase = _map(state);
    if (phase != null && !_controller.isClosed) _controller.add(phase);
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_controller.close());
  }

  static AppLifecyclePhase? _map(AppLifecycleState? state) => switch (state) {
    AppLifecycleState.resumed => AppLifecyclePhase.resumed,
    AppLifecycleState.inactive => AppLifecyclePhase.inactive,
    AppLifecycleState.hidden => AppLifecyclePhase.hidden,
    AppLifecycleState.paused => AppLifecyclePhase.paused,
    AppLifecycleState.detached => AppLifecyclePhase.detached,
    null => null,
  };
}
