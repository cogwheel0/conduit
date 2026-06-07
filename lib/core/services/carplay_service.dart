import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/providers/unified_auth_providers.dart';
import '../../features/chat/voice_mode/chat_voice_mode_controller.dart';
import '../providers/app_providers.dart';
import '../utils/debug_logger.dart';

const _carPlayChannel = MethodChannel('conduit/carplay');

final carPlayCoordinatorProvider = Provider<void>((ref) {
  if (kIsWeb || !Platform.isIOS) {
    return;
  }

  final coordinator = CarPlayCoordinator(ref);
  coordinator.initialize();
});

final class CarPlayCoordinator {
  CarPlayCoordinator(this._ref);

  final Ref _ref;
  bool _startedByCarPlay = false;
  bool _sceneConnected = false;
  int _sceneGeneration = 0;
  String? _lastSentStateKey;

  void initialize() {
    _carPlayChannel.setMethodCallHandler(_handleMethodCall);
    unawaited(_notifyNativeReady());
    _ref.listen<ChatVoiceModeSnapshot>(
      chatVoiceModeControllerProvider,
      (_, next) => unawaited(_sendSnapshot(next)),
      fireImmediately: true,
    );
    _ref.onDispose(() {
      _carPlayChannel.setMethodCallHandler(null);
    });
  }

  Future<Map<String, Object?>> _handleMethodCall(MethodCall call) async {
    try {
      switch (call.method) {
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
          return {
            'success': false,
            'error': 'Unknown CarPlay method: ${call.method}',
          };
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

    final authState = await _waitForAuthReady();
    if (!_isCurrentScene(sceneGeneration)) {
      return _failure('CarPlay disconnected.');
    }
    if (authState != AuthNavigationState.authenticated) {
      return _failure('Please sign in to Conduit on iPhone first.');
    }

    await _ensureModelSelected();
    if (!_isCurrentScene(sceneGeneration)) {
      return _failure('CarPlay disconnected.');
    }
    if (_ref.read(selectedModelProvider) == null) {
      return _failure('Please select a model in Conduit on iPhone first.');
    }

    _startedByCarPlay = true;
    await _ref
        .read(chatVoiceModeControllerProvider.notifier)
        .start(startNewConversation: true);
    if (!_isCurrentScene(sceneGeneration)) {
      final snapshot = _ref.read(chatVoiceModeControllerProvider);
      if (snapshot.isActive || snapshot.phase == ChatVoiceModePhase.error) {
        await _ref.read(chatVoiceModeControllerProvider.notifier).stop();
      }
      _startedByCarPlay = false;
      return _failure('CarPlay disconnected.');
    }

    final next = _ref.read(chatVoiceModeControllerProvider);
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
    }
    return _sceneGeneration;
  }

  void _markSceneDisconnected() {
    if (_sceneConnected) {
      _sceneConnected = false;
      _sceneGeneration++;
    }
  }

  bool _isCurrentScene(int generation) {
    return _sceneConnected && _sceneGeneration == generation;
  }

  Future<void> _notifyNativeReady() async {
    for (var attempt = 0; attempt < 20 && _ref.mounted; attempt++) {
      try {
        await _carPlayChannel.invokeMethod<void>('carPlayDartReady');
        _lastSentStateKey = null;
        await _sendSnapshot(_ref.read(chatVoiceModeControllerProvider));
        return;
      } on MissingPluginException {
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
      await _carPlayChannel.invokeMethod<void>(
        'voiceConversationStateChanged',
        payload,
      );
      _lastSentStateKey = stateKey;
    } on MissingPluginException {
      // Native CarPlay bridge is not installed in this runtime.
    } catch (error, stackTrace) {
      DebugLogger.error(
        'carplay-state-update',
        scope: 'carplay',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<AuthNavigationState> _waitForAuthReady() async {
    for (var attempt = 0; attempt < 50; attempt++) {
      final state = _ref.read(authNavigationStateProvider);
      if (state != AuthNavigationState.loading) {
        return state;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    return _ref.read(authNavigationStateProvider);
  }

  Future<void> _ensureModelSelected() async {
    if (_ref.read(selectedModelProvider) != null) {
      return;
    }

    try {
      await _ref
          .read(defaultModelProvider.future)
          .timeout(const Duration(seconds: 3), onTimeout: () => null);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'carplay-default-model',
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
      'phase': _carPlayPhase(snapshot.phase),
      'isActive': snapshot.isActive,
      'canPause': snapshot.canPause,
      'canResume': snapshot.canResume,
      'isMuted': snapshot.isMuted,
      'error': snapshot.errorMessage,
      'modelName': _ref.read(selectedModelProvider)?.name,
    };
  }

  String _carPlayPhase(ChatVoiceModePhase phase) {
    return switch (phase) {
      ChatVoiceModePhase.sending => 'thinking',
      ChatVoiceModePhase.error => 'failed',
      _ => phase.name,
    };
  }
}
