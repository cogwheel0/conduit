/// The CarPlay voice-conversation coordinator.
///
/// CarPlay shows Conduit as a voice-control template (iOS 26.4+): Start,
/// Pause, Resume and End buttons, and a state that follows the voice call.
/// The template lives in native code (`ConduitCarPlaySceneDelegate.swift`);
/// everything it asks for is decided here, over the voice-mode
/// controller the phone's call UI also drives.
///
/// The native scene reaches Dart through a [CarPlayBridgePort], which the app
/// binds to the `conduit/carplay` method channel
/// (`lib/platform/carplay_service.dart`). Without a bridge ([carPlayBridgeProvider] is null,
/// as on Android, the daemon and in tests that bind nothing) the coordinator
/// does nothing.
library;

import 'dart:async';

import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/chat/voice_call/voice_call_eligibility.dart';
import 'package:conduit_core/features/chat/voice_mode/chat_voice_mode_controller.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// Answers one call from the CarPlay scene. The reply is the payload the
/// native side decodes: `success`, an optional `error`, and the voice `state`.
typedef CarPlayCallHandler = Future<Map<String, Object?>> Function(
  String method,
);

/// Thrown by [CarPlayBridgePort.invoke] when this runtime has no native
/// CarPlay bridge (Flutter's `MissingPluginException`: a headless engine, a
/// hot restart before the plugin re-attaches).
final class CarPlayBridgeUnavailable implements Exception {
  const CarPlayBridgeUnavailable();

  @override
  String toString() => 'CarPlayBridgeUnavailable';
}

/// The native CarPlay scene, as a method channel.
///
/// Calls from the scene (`carPlaySceneDidConnect`, `startVoiceConversation`,
/// `endVoiceConversation`, `pauseVoiceConversation`,
/// `resumeVoiceConversation`, `carPlaySceneDidDisconnect`) go to the handler.
/// Calls to it are `carPlayDartReady` and `voiceConversationStateChanged`.
abstract interface class CarPlayBridgePort {
  /// Installs the handler for calls from the scene; null removes it.
  void setCallHandler(CarPlayCallHandler? handler);

  /// Sends [method] to the scene. Throws [CarPlayBridgeUnavailable] when
  /// there is no native bridge to receive it.
  Future<void> invoke(String method, [Map<String, Object?>? arguments]);
}

/// The host's CarPlay bridge. Null (the default) where there is no CarPlay.
final carPlayBridgeProvider = Provider<CarPlayBridgePort?>((ref) => null);

/// Keeps the coordinator alive. The app reads it before its first frame:
/// CarPlay can cold-launch Conduit with no phone scene on screen.
final carPlayCoordinatorProvider = Provider<void>((ref) {
  final bridge = ref.watch(carPlayBridgeProvider);
  if (bridge == null) return;
  CarPlayCoordinator(ref, bridge).initialize();
});

final class CarPlayCoordinator {
  CarPlayCoordinator(this._ref, this._bridge);

  final Ref _ref;
  final CarPlayBridgePort _bridge;
  bool _startedByCarPlay = false;
  bool _sceneConnected = false;
  int _sceneGeneration = 0;
  Completer<void>? _sceneDisconnectSignal;
  String? _lastSentStateKey;

  void initialize() {
    _bridge.setCallHandler(handleCall);
    unawaited(_notifyNativeReady());
    _ref.listen<ChatVoiceModeSnapshot>(
      chatVoiceModeControllerProvider,
      (_, next) => unawaited(_sendSnapshot(next)),
      fireImmediately: true,
    );
    _ref.onDispose(() {
      _bridge.setCallHandler(null);
    });
  }

  /// Answers one call from the scene. Never throws: a failure is a
  /// `success: false` reply the template shows as unavailable.
  Future<Map<String, Object?>> handleCall(String method) async {
    try {
      switch (method) {
        case 'carPlaySceneDidConnect':
          return _handleCarPlaySceneConnected();
        case 'startVoiceConversation':
          return await _startVoiceConversation();
        case 'endVoiceConversation':
          return await _endVoiceConversation();
        case 'pauseVoiceConversation':
          return await _pauseVoiceConversation();
        case 'resumeVoiceConversation':
          return await _resumeVoiceConversation();
        case 'carPlaySceneDidDisconnect':
          return await _handleCarPlaySceneDisconnected();
        default:
          return {'success': false, 'error': 'Unknown CarPlay method: $method'};
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'carplay-method',
        scope: 'carplay',
        error: error,
        stackTrace: stackTrace,
      );
      return {
        'success': false,
        'error': error.toString(),
        'state': _snapshotPayload(_ref.read(chatVoiceModeControllerProvider)),
      };
    }
  }

  Future<Map<String, Object?>> _startVoiceConversation() async {
    final sceneGeneration = _markSceneConnected();
    final current = _ref.read(chatVoiceModeControllerProvider);
    if (current.isActive) {
      return _success();
    }

    final disconnectSignal = _sceneDisconnectSignal!;
    late final VoiceCallEligibility eligibility;
    try {
      eligibility = await resolveVoiceCallEligibility(
        _ref,
        cancellationSignal: disconnectSignal.future,
        cancellationRequested: () => !_isCurrentScene(sceneGeneration),
      );
    } on VoiceCallEligibilityResolutionCancelled {
      if (!_isCurrentScene(sceneGeneration)) {
        return _failure('CarPlay disconnected.');
      }
      rethrow;
    }
    if (!_isCurrentScene(sceneGeneration)) {
      return _failure('CarPlay disconnected.');
    }

    if (!eligibility.canStart) {
      return _failure(eligibility.errorMessage!);
    }

    final startResult = await _ref
        .read(chatVoiceModeControllerProvider.notifier)
        .start(
          startNewConversation: true,
          shouldStart: () => _isCurrentScene(sceneGeneration),
          admittedModel: eligibility.model!,
        );
    if (!_isCurrentScene(sceneGeneration)) {
      final snapshot = _ref.read(chatVoiceModeControllerProvider);
      final claimedOwnership = startResult == ChatVoiceModeStartResult.started;
      if (claimedOwnership &&
          (snapshot.isActive || snapshot.phase == ChatVoiceModePhase.error)) {
        await _ref.read(chatVoiceModeControllerProvider.notifier).stop();
      }
      if (claimedOwnership) {
        _startedByCarPlay = false;
      }
      return _failure('CarPlay disconnected.');
    }

    final next = _ref.read(chatVoiceModeControllerProvider);
    if (startResult == ChatVoiceModeStartResult.started) {
      _startedByCarPlay = true;
    }
    if (next.phase == ChatVoiceModePhase.error) {
      _startedByCarPlay = false;
      return _failure(
        next.errorMessage ?? 'Unable to start Conduit voice conversation.',
      );
    }
    if (!next.isActive) {
      _startedByCarPlay = false;
      return _failure('Conduit voice conversation ended before it started.');
    }

    return _success(next);
  }

  Map<String, Object?> _handleCarPlaySceneConnected() {
    _markSceneConnected();
    return _success();
  }

  Future<Map<String, Object?>> _endVoiceConversation() async {
    final snapshot = _ref.read(chatVoiceModeControllerProvider);
    if (snapshot.isActive || snapshot.phase == ChatVoiceModePhase.error) {
      await _ref.read(chatVoiceModeControllerProvider.notifier).stop();
    }
    _startedByCarPlay = false;
    return _success();
  }

  Future<Map<String, Object?>> _pauseVoiceConversation() async {
    final snapshot = _ref.read(chatVoiceModeControllerProvider);
    if (!snapshot.canPause) {
      return _failure('Conduit is not currently listening.');
    }

    await _ref.read(chatVoiceModeControllerProvider.notifier).pause();
    return _success();
  }

  Future<Map<String, Object?>> _resumeVoiceConversation() async {
    final snapshot = _ref.read(chatVoiceModeControllerProvider);
    if (!snapshot.canResume) {
      return _failure('No paused Conduit voice conversation.');
    }

    await _ref.read(chatVoiceModeControllerProvider.notifier).resume();
    return _success();
  }

  Future<Map<String, Object?>> _handleCarPlaySceneDisconnected() async {
    _markSceneDisconnected();
    final snapshot = _ref.read(chatVoiceModeControllerProvider);
    if (_startedByCarPlay && snapshot.isActive) {
      await _ref.read(chatVoiceModeControllerProvider.notifier).stop();
    }
    _startedByCarPlay = false;
    return _success();
  }

  int _markSceneConnected() {
    if (!_sceneConnected) {
      _sceneConnected = true;
      _sceneGeneration++;
      _sceneDisconnectSignal = Completer<void>();
    }
    return _sceneGeneration;
  }

  void _markSceneDisconnected() {
    if (_sceneConnected) {
      _sceneConnected = false;
      _sceneGeneration++;
      final disconnectSignal = _sceneDisconnectSignal;
      _sceneDisconnectSignal = null;
      if (disconnectSignal != null && !disconnectSignal.isCompleted) {
        disconnectSignal.complete();
      }
    }
  }

  bool _isCurrentScene(int generation) {
    return _sceneConnected && _sceneGeneration == generation;
  }

  Future<void> _notifyNativeReady() async {
    for (var attempt = 0; attempt < 20 && _ref.mounted; attempt++) {
      try {
        await _bridge.invoke('carPlayDartReady');
        _lastSentStateKey = null;
        await _sendSnapshot(_ref.read(chatVoiceModeControllerProvider));
        return;
      } on CarPlayBridgeUnavailable {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      } catch (error, stackTrace) {
        DebugLogger.error(
          'carplay-ready',
          scope: 'carplay',
          error: error,
          stackTrace: stackTrace,
        );
        return;
      }
    }
  }

  Future<void> _sendSnapshot(ChatVoiceModeSnapshot snapshot) async {
    if (!snapshot.isActive) {
      _startedByCarPlay = false;
    }

    final payload = _snapshotPayload(snapshot);
    final stateKey = [
      payload['phase'],
      payload['isActive'],
      payload['canPause'],
      payload['canResume'],
      payload['isMuted'],
      payload['error'],
    ].join('|');
    if (_lastSentStateKey == stateKey) {
      return;
    }

    try {
      await _bridge.invoke('voiceConversationStateChanged', payload);
      _lastSentStateKey = stateKey;
    } on CarPlayBridgeUnavailable {
      // The native CarPlay bridge is not installed in this runtime.
    } catch (error, stackTrace) {
      DebugLogger.error(
        'carplay-state-update',
        scope: 'carplay',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Map<String, Object?> _success([ChatVoiceModeSnapshot? snapshot]) {
    return {
      'success': true,
      'state': _snapshotPayload(
        snapshot ?? _ref.read(chatVoiceModeControllerProvider),
      ),
    };
  }

  Map<String, Object?> _failure(String message) {
    return {
      'success': false,
      'error': message,
      'state': _snapshotPayload(_ref.read(chatVoiceModeControllerProvider)),
    };
  }

  Map<String, Object?> _snapshotPayload(ChatVoiceModeSnapshot snapshot) {
    return {
      'phase': carPlayPhase(snapshot.phase),
      'isActive': snapshot.isActive,
      'canPause': snapshot.canPause,
      'canResume': snapshot.canResume,
      'isMuted': snapshot.isMuted,
      'error': snapshot.errorMessage,
      'modelName': _ref.read(selectedModelProvider)?.name,
    };
  }
}

/// The phase name the CarPlay template understands for [phase].
String carPlayPhase(ChatVoiceModePhase phase) {
  return switch (phase) {
    ChatVoiceModePhase.sending => 'thinking',
    ChatVoiceModePhase.error => 'failed',
    _ => phase.name,
  };
}
