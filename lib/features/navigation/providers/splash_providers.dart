import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/auth/auth_state_manager.dart';
import '../../../core/providers/app_providers.dart';

/// State for the splash launcher screen
class SplashState {
  const SplashState({
    this.showTimeout = false,
    this.isRecovering = false,
    this.tapCount = 0,
  });

  final bool showTimeout;
  final bool isRecovering;
  final int tapCount; // For triple-tap detection

  SplashState copyWith({
    bool? showTimeout,
    bool? isRecovering,
    int? tapCount,
  }) {
    return SplashState(
      showTimeout: showTimeout ?? this.showTimeout,
      isRecovering: isRecovering ?? this.isRecovering,
      tapCount: tapCount ?? this.tapCount,
    );
  }
}

/// Manages splash screen state and timeout logic
class SplashStateManager extends ChangeNotifier {
  SplashStateManager(this._ref) {
    _initialize();
  }

  final Ref _ref;
  Timer? _timeoutTimer;
  Timer? _tapResetTimer;
  SplashState _state = const SplashState();

  SplashState get state => _state;

  void _initialize() {
    // Listen to auth state for automatic error detection
    _ref.listen<AsyncValue<AuthState>>(authStateManagerProvider, (prev, next) {
      final authState = next.asData?.value;
      if (authState?.status == AuthStatus.error) {
        // Show timeout UI immediately on auth error
        _updateState(_state.copyWith(showTimeout: true));
      }
    });

    // Start timeout timer
    _startTimeoutTimer();
  }

  void _updateState(SplashState newState) {
    _state = newState;
    notifyListeners();
  }

  void _startTimeoutTimer() {
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(const Duration(seconds: 45), () {
      _updateState(_state.copyWith(showTimeout: true));
    });
  }

  /// Handle tap on loading indicator (for triple-tap detection)
  void onLoadingTap() {
    final newTapCount = _state.tapCount + 1;

    // Reset tap timer on each tap
    _tapResetTimer?.cancel();
    _tapResetTimer = Timer(const Duration(seconds: 2), () {
      _updateState(_state.copyWith(tapCount: 0));
    });

    _updateState(_state.copyWith(tapCount: newTapCount));

    // Trigger timeout UI on triple-tap
    if (newTapCount >= 3) {
      _updateState(_state.copyWith(showTimeout: true, tapCount: 0));
      _tapResetTimer?.cancel();
    }
  }

  /// Handle logout recovery action
  Future<void> logout() async {
    _updateState(_state.copyWith(isRecovering: true));

    try {
      final storage = _ref.read(optimizedStorageServiceProvider);
      await storage.clearAuthData();
      await storage.setActiveServerId(null);

      _ref.invalidate(authStateManagerProvider);
      _ref.invalidate(activeServerProvider);
    } catch (e) {
      // Error will be handled by UI
    } finally {
      _updateState(_state.copyWith(isRecovering: false));
    }
  }

  /// Handle retry recovery action
  Future<void> retry() async {
    _updateState(_state.copyWith(isRecovering: true, showTimeout: false));

    try {
      _ref.invalidate(authStateManagerProvider);

      // Restart timeout timer
      _startTimeoutTimer();

      _updateState(_state.copyWith(isRecovering: false));
    } catch (e) {
      _updateState(_state.copyWith(isRecovering: false, showTimeout: true));
    }
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    _tapResetTimer?.cancel();
    super.dispose();
  }
}

/// Provider for splash screen state management
final splashStateProvider = Provider<SplashStateManager>(
  (ref) {
    final manager = SplashStateManager(ref);
    ref.onDispose(manager.dispose);
    return manager;
  },
);
