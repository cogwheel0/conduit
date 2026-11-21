import 'package:flutter_callkit_incoming/entities/android_params.dart';
import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';

/// Event name constants for external reference
abstract class CallEventConstants {
  static const String actionDidUpdateDevicePushTokenVoip =
      'com.hiennv.flutter_callkit_incoming.DID_UPDATE_DEVICE_PUSH_TOKEN_VOIP';
  static const String actionCallIncoming =
      'com.hiennv.flutter_callkit_incoming.ACTION_CALL_INCOMING';
  static const String actionCallStart =
      'com.hiennv.flutter_callkit_incoming.ACTION_CALL_START';
  static const String actionCallAccept =
      'com.hiennv.flutter_callkit_incoming.ACTION_CALL_ACCEPT';
  static const String actionCallDecline =
      'com.hiennv.flutter_callkit_incoming.ACTION_CALL_DECLINE';
  static const String actionCallEnded =
      'com.hiennv.flutter_callkit_incoming.ACTION_CALL_ENDED';
  static const String actionCallTimeout =
      'com.hiennv.flutter_callkit_incoming.ACTION_CALL_TIMEOUT';
  static const String actionCallConnected =
      'com.hiennv.flutter_callkit_incoming.ACTION_CALL_CONNECTED';
  static const String actionCallCallback =
      'com.hiennv.flutter_callkit_incoming.ACTION_CALL_CALLBACK';
  static const String actionCallToggleHold =
      'com.hiennv.flutter_callkit_incoming.ACTION_CALL_TOGGLE_HOLD';
  static const String actionCallToggleMute =
      'com.hiennv.flutter_callkit_incoming.ACTION_CALL_TOGGLE_MUTE';
  static const String actionCallToggleDmtf =
      'com.hiennv.flutter_callkit_incoming.ACTION_CALL_TOGGLE_DMTF';
  static const String actionCallToggleGroup =
      'com.hiennv.flutter_callkit_incoming.ACTION_CALL_TOGGLE_GROUP';
  static const String actionCallToggleAudioSession =
      'com.hiennv.flutter_callkit_incoming.ACTION_CALL_TOGGLE_AUDIO_SESSION';
  static const String actionCallCustom =
      'com.hiennv.flutter_callkit_incoming.ACTION_CALL_CUSTOM';
}

/// Base sealed class for CallEvent
sealed class CallEvent {
  const CallEvent();

  String get eventName;
}

class CallEventActionDidUpdateDevicePushTokenVoip extends CallEvent {
  const CallEventActionDidUpdateDevicePushTokenVoip();

  @override
  String get eventName =>
      CallEventConstants.actionDidUpdateDevicePushTokenVoip;

  @override
  String toString() => 'CallEventActionDidUpdateDevicePushTokenVoip()';
}

class CallEventActionCallIncoming extends CallEvent {
  const CallEventActionCallIncoming(this.callKitParams);

  @override
  String get eventName => CallEventConstants.actionCallIncoming;

  final CallKitParams callKitParams;

  @override
  String toString() =>
      'CallEventActionCallIncoming(callKitParams: $callKitParams)';
}

class CallEventActionCallStart extends CallEvent {
  const CallEventActionCallStart(this.callKitParams);

  @override
  String get eventName => CallEventConstants.actionCallStart;

  final CallKitParams callKitParams;

  @override
  String toString() =>
      'CallEventActionCallStart(callKitParams: $callKitParams)';
}

class CallEventActionCallAccept extends CallEvent {
  const CallEventActionCallAccept(this.callKitParams);

  @override
  String get eventName => CallEventConstants.actionCallAccept;

  final CallKitParams callKitParams;

  @override
  String toString() =>
      'CallEventActionCallAccept(callKitParams: $callKitParams)';
}

class CallEventActionCallDecline extends CallEvent {
  const CallEventActionCallDecline(this.callKitParams);

  @override
  String get eventName => CallEventConstants.actionCallDecline;

  final CallKitParams callKitParams;

  @override
  String toString() =>
      'CallEventActionCallDecline(callKitParams: $callKitParams)';
}

class CallEventActionCallEnded extends CallEvent {
  const CallEventActionCallEnded(this.callKitParams);

  @override
  String get eventName => CallEventConstants.actionCallEnded;

  final CallKitParams callKitParams;

  @override
  String toString() =>
      'CallEventActionCallEnded(callKitParams: $callKitParams)';
}

class CallEventActionCallTimeout extends CallEvent {
  const CallEventActionCallTimeout(this.id);

  @override
  String get eventName => CallEventConstants.actionCallTimeout;

  final String id;

  @override
  String toString() => 'CallEventActionCallTimeout(id: $id)';
}

class CallEventActionCallConnected extends CallEvent {
  const CallEventActionCallConnected(this.id);

  @override
  String get eventName => CallEventConstants.actionCallConnected;

  final String id;

  @override
  String toString() => 'CallEventActionCallConnected(id: $id)';
}

class CallEventActionCallCallback extends CallEvent {
  const CallEventActionCallCallback(this.id);

  @override
  String get eventName => CallEventConstants.actionCallCallback;

  final String id;

  @override
  String toString() => 'CallEventActionCallCallback(id: $id)';
}

class CallEventActionCallToggleHold extends CallEvent {
  const CallEventActionCallToggleHold(this.id, this.isOnHold);

  @override
  String get eventName => CallEventConstants.actionCallToggleHold;

  final String id;
  final bool isOnHold;

  @override
  String toString() =>
      'CallEventActionCallToggleHold(id: $id, isOnHold: $isOnHold)';
}

class CallEventActionCallToggleMute extends CallEvent {
  const CallEventActionCallToggleMute(this.id, this.isMuted);

  @override
  String get eventName => CallEventConstants.actionCallToggleMute;

  final String id;
  final bool isMuted;

  @override
  String toString() =>
      'CallEventActionCallToggleMute(id: $id, isMuted: $isMuted)';
}

class CallEventActionCallToggleDmtf extends CallEvent {
  const CallEventActionCallToggleDmtf(this.id, this.digits, this.type);

  @override
  String get eventName => CallEventConstants.actionCallToggleDmtf;

  final String id;
  final String digits;
  final DTMFActionType type;

  @override
  String toString() =>
      'CallEventActionCallToggleDmtf(id: $id, digits: $digits, type: $type)';
}

class CallEventActionCallToggleGroup extends CallEvent {
  const CallEventActionCallToggleGroup(this.id, this.callUUIDToGroupWith);

  @override
  String get eventName => CallEventConstants.actionCallToggleGroup;

  final String id;
  final String? callUUIDToGroupWith;

  @override
  String toString() => 'CallEventActionCallToggleGroup(id: $id,'
      ' callUUIDToGroupWith: $callUUIDToGroupWith)';
}

class CallEventActionCallToggleAudioSession extends CallEvent {
  const CallEventActionCallToggleAudioSession(this.isActive);

  @override
  String get eventName => CallEventConstants.actionCallToggleAudioSession;

  final bool isActive;

  @override
  String toString() =>
      'CallEventActionCallToggleAudioSession(isActive: $isActive)';
}

class CallEventActionCallCustom extends CallEvent {
  const CallEventActionCallCustom(this.body);

  @override
  String get eventName => CallEventConstants.actionCallCustom;

  final Map<String, dynamic> body;

  @override
  String toString() => 'CallEventActionCallCustom(body: $body)';
}
