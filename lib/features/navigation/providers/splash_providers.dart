import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/auth/auth_state_manager.dart';
import '../../../core/providers/app_providers.dart';

part 'splash_providers.g.dart';

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
@Riverpod(keepAlive: true)
class SplashStateManager extends _$SplashStateManager {
  Timer? _timeoutTimer;
  Timer? _tapResetTimer;

  @override
  SplashState build() {
    // Check initial auth state
    final initialAuthState = ref.read(authStateManagerProvider).asData?.value;
    if (initialAuthState?.status == AuthStatus.error ||
        (initialAuthState?.status == AuthStatus.unauthenticated &&
            initialAuthState?.error != null &&
            initialAuthState!.error!.isNotEmpty)) {
      return const SplashState(showTimeout: true);
    }

    // Listen to auth state for automatic error detection
    ref.listen<AsyncValue<AuthState>>(authStateManagerProvider, (prev, next) {
      final authState = next.asData?.value;
      
      // Show timeout UI on auth error or unauthenticated with error
      if (authState?.status == AuthStatus.error ||
          (authState?.status == AuthStatus.unauthenticated &&
              authState?.error != null &&
              authState!.error!.isNotEmpty)) {
        state = state.copyWith(showTimeout: true);
        _timeoutTimer?.cancel(); // Cancel timer since we're showing recovery
      }
    });

    // Start timeout timer
    _startTimeoutTimer();
    
    // Setup cleanup
    ref.onDispose(() {
      _timeoutTimer?.cancel();
      _tapResetTimer?.cancel();
    });

    return const SplashState();
  }

  void _startTimeoutTimer() {
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(const Duration(seconds: 45), () {
      state = state.copyWith(showTimeout: true);
    });
  }

  /// Handle tap on loading indicator (for triple-tap detection)
  void onLoadingTap() {
    final newTapCount = state.tapCount + 1;

    // Reset tap timer on each tap
    _tapResetTimer?.cancel();
    _tapResetTimer = Timer(const Duration(seconds: 2), () {
      state = state.copyWith(tapCount: 0);
    });

    state = state.copyWith(tapCount: newTapCount);

    // Trigger timeout UI on triple-tap
    if (newTapCount >= 3) {
      // Strong haptic feedback on successful triple tap
      HapticFeedback.mediumImpact();
      state = state.copyWith(showTimeout: true, tapCount: 0);
      _tapResetTimer?.cancel();
    }
  }

  /// Handle logout recovery action
  Future<void> logout() async {
    state = state.copyWith(isRecovering: true);

    try {
      final storage = ref.read(optimizedStorageServiceProvider);
      await storage.clearAuthData();
      await storage.setActiveServerId(null);

      ref.invalidate(authStateManagerProvider);
      ref.invalidate(activeServerProvider);
    } catch (e) {
      // Error will be handled by UI
    } finally {
      state = state.copyWith(isRecovering: false);
    }
  }

  /// Handle retry recovery action
  Future<void> retry() async {
    state = state.copyWith(isRecovering: true, showTimeout: false);

    try {
      ref.invalidate(authStateManagerProvider);

      // Restart timeout timer
      _startTimeoutTimer();

      state = state.copyWith(isRecovering: false);
    } catch (e) {
      state = state.copyWith(isRecovering: false, showTimeout: true);
    }
  }
}
