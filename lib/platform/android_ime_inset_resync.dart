import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:conduit_core/utils/debug_logger.dart';

/// Recovers a keyboard inset that Android's IME animation sync left behind.
///
/// On Android 11+ Flutter holds back the final IME inset while a keyboard
/// animation runs and applies it when the animation ends. Leaving the app
/// mid-animation can lose that final update, so `viewInsets.bottom` keeps a
/// keyboard height with no keyboard on screen and the composer floats
/// mid-screen until the process dies (#758).
///
/// Once the inset has stopped changing, or the app resumes, a non-zero inset
/// is checked against the window: MainActivity re-applies the real insets
/// only when the system reports the IME hidden.
class AndroidImeInsetResync with WidgetsBindingObserver {
  AndroidImeInsetResync._();

  static final instance = AndroidImeInsetResync._();

  @visibleForTesting
  static const channel = MethodChannel('app.cogwheel.conduit/keyboard_insets');

  /// Longer than an IME animation, so an in-flight keyboard is never judged
  /// until its frames stop arriving.
  @visibleForTesting
  static const settleDelay = Duration(milliseconds: 400);

  bool _installed = false;
  Timer? _settleTimer;

  void install() {
    if (_installed ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    _installed = true;
    WidgetsBinding.instance.addObserver(this);
  }

  @visibleForTesting
  void uninstall() {
    if (!_installed) return;
    _installed = false;
    _settleTimer?.cancel();
    _settleTimer = null;
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeMetrics() => _scheduleCheck();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _scheduleCheck();
  }

  void _scheduleCheck() {
    _settleTimer?.cancel();
    _settleTimer = Timer(settleDelay, _checkSettledInset);
  }

  void _checkSettledInset() {
    _settleTimer = null;
    final binding = WidgetsBinding.instance;
    if (binding.lifecycleState != AppLifecycleState.resumed) return;
    final view = binding.platformDispatcher.implicitView;
    if (view == null || view.viewInsets.bottom <= 0) return;
    unawaited(_requestResync());
  }

  Future<void> _requestResync() async {
    try {
      final applied = await channel.invokeMethod<bool>('resyncImeInsets');
      if (applied == true) {
        DebugLogger.log('stale-ime-inset-cleared', scope: 'platform/keyboard');
      }
    } on MissingPluginException {
      // Hosts without the native handler keep the platform's inset.
    } catch (error) {
      DebugLogger.warning(
        'ime-inset-resync-failed',
        scope: 'platform/keyboard',
        data: {'errorType': error.runtimeType.toString()},
      );
    }
  }
}
