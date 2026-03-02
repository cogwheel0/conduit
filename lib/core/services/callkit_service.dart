import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';

part 'callkit_service.g.dart';

/// Thin wrapper around `flutter_callkit_incoming` for voice calls.
class CallKitService {
  CallKitService({Uuid? uuid})
    : _uuid = uuid ?? const Uuid(),
      _callKitAllowed = _computeCallKitAllowed();

  final Uuid _uuid;
  final bool _callKitAllowed;
  bool _loggedCallKitDisabled = false;
  static const int _defaultCallDurationMs = 2 * 60 * 60 * 1000; // 2 hours

  /// Returns whether CallKit can be used on this device/region.
  bool get isAvailable => _callKitAllowed;

  /// Requests the notification/full-screen intent permissions needed on Android.
  Future<void> requestPermissions() async {
    if (!_shouldUseCallKit('request permissions')) return;

    await _safe(
      () => FlutterCallkitIncoming.requestNotificationPermission(
        <String, dynamic>{
          'title': 'Notification permission',
          'rationaleMessagePermission':
              'Call alerts need notification permission.',
          'postNotificationMessageRequired':
              'Allow notifications to show incoming calls.',
        },
      ),
    );
    // Full-screen intent permission not needed for outgoing-only calls.
  }

  /// Starts an outgoing call with the native UI and returns the call id.
  Future<String?> startOutgoingVoiceCall({
    required String calleeName,
    required String handle,
    String? avatar,
    int? durationMs,
  }) async {
    if (!_shouldUseCallKit('start call')) return null;

    final id = _uuid.v4();
    final params = _buildParams(
      id: id,
      callerName: calleeName,
      handle: handle,
      avatar: avatar,
      durationMs: durationMs ?? _defaultCallDurationMs,
    );
    try {
      await FlutterCallkitIncoming.startCall(params);
      return id;
    } catch (error, stackTrace) {
      developer.log(
        'CallKit startCall failed: $error',
        name: 'callkit',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  /// Marks the current call as connected so iOS shows an incrementing timer.
  Future<void> markCallConnected(String id) async {
    if (!_shouldUseCallKit('mark call connected')) return;

    try {
      await FlutterCallkitIncoming.setCallConnected(id);
    } catch (error, stackTrace) {
      developer.log(
        'CallKit setCallConnected failed: $error',
        name: 'callkit',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Ends a specific call id.
  Future<void> endCall(String id) async {
    if (!_shouldUseCallKit('end call')) return;

    await _safe(() => FlutterCallkitIncoming.endCall(id));
  }

  /// Clears all ongoing/missed calls.
  Future<void> endAllCalls() async {
    if (!_shouldUseCallKit('end all calls')) return;

    await _safe(FlutterCallkitIncoming.endAllCalls);
  }

  /// Returns the platform VOIP token (iOS PushKit) when available.
  Future<String?> getVoipToken() async {
    if (!_shouldUseCallKit('fetch VoIP token')) return null;

    final token = await _safe<dynamic>(
      () => FlutterCallkitIncoming.getDevicePushTokenVoIP(),
    );
    if (token == null) return null;
    if (token is String) return token;
    return token.toString();
  }

  /// Returns the raw active call list from the plugin.
  Future<List<Map<String, dynamic>>> activeCalls() async {
    if (!_shouldUseCallKit('fetch active calls')) {
      return <Map<String, dynamic>>[];
    }

    final calls = await _safe<dynamic>(FlutterCallkitIncoming.activeCalls);
    if (calls is List) {
      return calls
          .whereType<Map<dynamic, dynamic>>()
          .map(Map<String, dynamic>.from)
          .toList();
    }
    return <Map<String, dynamic>>[];
  }

  /// Checks for active calls and clears them if they are not tracked by the app.
  Future<void> checkAndCleanActiveCalls() async {
    if (!_shouldUseCallKit('check active calls')) return;

    try {
      final calls = await activeCalls();
      if (calls.isNotEmpty) {
        developer.log(
          'Found ${calls.length} active CallKit calls on startup. Cleaning up.',
          name: 'callkit',
        );
        await endAllCalls();
      }
    } catch (error, stackTrace) {
      developer.log(
        'Failed to clean up active calls: $error',
        name: 'callkit',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Stream of CallKit events from the native layer.
  Stream<CallEvent> get events {
    if (!_callKitAllowed) {
      return const Stream<CallEvent>.empty();
    }
    return FlutterCallkitIncoming.onEvent
        .where((event) => event != null)
        .cast();
  }

  CallKitParams _buildParams({
    required String id,
    required String callerName,
    required String handle,
    String? avatar,
    int durationMs = _defaultCallDurationMs,
  }) {
    return CallKitParams(
      id: id,
      nameCaller: callerName,
      appName: 'Conduit',
      avatar: avatar,
      handle: handle,
      type: 0, // 0 = audio call
      duration: durationMs,
      textAccept: 'Accept',
      textDecline: 'Decline',
      missedCallNotification: const NotificationParams(
        showNotification: true,
        isShowCallback: true,
        subtitle: 'Missed call',
        callbackText: 'Call back',
      ),
      callingNotification: const NotificationParams(
        showNotification: true,
        isShowCallback: true,
        subtitle: 'Calling...',
        callbackText: 'Hang up',
      ),
      extra: const <String, dynamic>{'transport': 'voice'},
      android: const AndroidParams(
        isCustomNotification: true,
        isShowLogo: true,
        ringtonePath: 'system_ringtone_default',
        backgroundColor: '#0D1726',
        actionColor: '#4CAF50',
        incomingCallNotificationChannelName: 'Incoming Call',
        missedCallNotificationChannelName: 'Missed Call',
      ),
      ios: const IOSParams(
        iconName: '',
        handleType: 'generic',
        supportsVideo: false,
        audioSessionMode: 'voiceChat',
        audioSessionActive: false,
        configureAudioSession: false,
        audioSessionPreferredSampleRate: 44100.0,
        audioSessionPreferredIOBufferDuration: 0.005,
        supportsDTMF: true,
        supportsHolding: true,
        supportsGrouping: false,
        supportsUngrouping: false,
        ringtonePath: 'system_ringtone_default',
      ),
    );
  }

  Future<T?> _safe<T>(Future<T> Function() action) async {
    try {
      return await action();
    } catch (error, stackTrace) {
      developer.log(
        'CallKit error: $error',
        name: 'callkit',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  bool _shouldUseCallKit(String reason) {
    if (_callKitAllowed) return true;
    if (_loggedCallKitDisabled) return false;
    _loggedCallKitDisabled = true;
    developer.log(
      'CallKit disabled on iOS devices set to mainland China; '
      'skipping $reason.',
      name: 'callkit',
    );
    return false;
  }

  static bool _computeCallKitAllowed() {
    if (!Platform.isIOS) return true;

    final dispatcher = ui.PlatformDispatcher.instance;
    final locale = dispatcher.locale;
    return !_isMainlandChinaLocale(locale);
  }

  static bool _isMainlandChinaLocale(ui.Locale? locale) {
    if (locale == null) return false;
    final country = locale.countryCode?.toUpperCase();
    return country == 'CN';
  }
}

@Riverpod(keepAlive: true)
CallKitService callKitService(Ref ref) => CallKitService();
