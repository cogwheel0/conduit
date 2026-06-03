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
    if (event is CallEventActionCallEnded) {
      return NativeCallEvent(type: NativeCallEventType.ended, callId: event.id);
    }
    if (event is CallEventActionCallDecline) {
      return NativeCallEvent(type: NativeCallEventType.ended, callId: event.id);
    }
    if (event is CallEventActionCallTimeout) {
      return NativeCallEvent(
        type: NativeCallEventType.timeout,
        callId: event.id,
      );
    }
    if (event is CallEventActionCallConnected) {
      return NativeCallEvent(
        type: NativeCallEventType.connected,
        callId: event.id,
      );
    }
    if (event is CallEventActionCallToggleMute) {
      return NativeCallEvent(
        type: NativeCallEventType.muteToggled,
        callId: event.id,
        isMuted: event.isMuted,
      );
    }
    if (event is CallEventActionCallToggleHold) {
      return NativeCallEvent(
        type: NativeCallEventType.holdToggled,
        callId: event.id,
        isOnHold: event.isOnHold,
      );
    }
    return null;
  }
}

final nativeCallSurfaceProvider = Provider<NativeCallSurface>((ref) {
  final service = ref.watch(callKitServiceProvider);
  return NativeCallSurfaceCallkit(service);
});
