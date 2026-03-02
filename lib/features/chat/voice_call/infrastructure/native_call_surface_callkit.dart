import 'dart:async';

import 'package:flutter_callkit_incoming/entities/call_event.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/callkit_service.dart';
import '../domain/voice_call_interfaces.dart';

/// CallKit-backed implementation of [NativeCallSurface].
class NativeCallSurfaceCallkit implements NativeCallSurface {
  NativeCallSurfaceCallkit(this._service);

  final CallKitService _service;

  @override
  bool get isAvailable => _service.isAvailable;

  @override
  Stream<NativeCallEvent> get events =>
      _service.events.map(_mapEvent).where((event) => event != null).cast();

  @override
  Future<void> requestPermissions() => _service.requestPermissions();

  @override
  Future<void> checkAndCleanActiveCalls() =>
      _service.checkAndCleanActiveCalls();

  @override
  Future<String?> startOutgoingCall({
    required String callerName,
    required String handle,
  }) {
    return _service.startOutgoingVoiceCall(
      calleeName: callerName,
      handle: handle,
    );
  }

  @override
  Future<void> markConnected(String callId) =>
      _service.markCallConnected(callId);

  @override
  Future<void> endCall(String callId) => _service.endCall(callId);

  @override
  Future<void> endAllCalls() => _service.endAllCalls();

  NativeCallEvent? _mapEvent(CallEvent event) {
    final body = event.body;
    final callId = body is Map ? body['id']?.toString() : null;

    switch (event.event) {
      case Event.actionCallEnded:
      case Event.actionCallDecline:
        return NativeCallEvent(type: NativeCallEventType.ended, callId: callId);
      case Event.actionCallTimeout:
        return NativeCallEvent(
          type: NativeCallEventType.timeout,
          callId: callId,
        );
      case Event.actionCallConnected:
        return NativeCallEvent(
          type: NativeCallEventType.connected,
          callId: callId,
        );
      case Event.actionCallToggleMute:
        final isMuted = body is Map ? body['isMuted'] == true : body == true;
        return NativeCallEvent(
          type: NativeCallEventType.muteToggled,
          callId: callId,
          isMuted: isMuted,
        );
      case Event.actionCallToggleHold:
        final isOnHold = body is Map ? body['isOnHold'] == true : body == true;
        return NativeCallEvent(
          type: NativeCallEventType.holdToggled,
          callId: callId,
          isOnHold: isOnHold,
        );
      default:
        return null;
    }
  }
}

final nativeCallSurfaceProvider = Provider<NativeCallSurface>((ref) {
  final service = ref.watch(callKitServiceProvider);
  return NativeCallSurfaceCallkit(service);
});
