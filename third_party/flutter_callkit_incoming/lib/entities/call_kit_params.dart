import 'package:flutter_callkit_incoming/entities/notification_params.dart';
import 'package:json_annotation/json_annotation.dart';

import 'android_params.dart';
import 'ios_params.dart';

part 'call_kit_params.g.dart';

/// Object config for General.
@JsonSerializable(explicitToJson: true)
class CallKitParams {
  const CallKitParams({
    required this.id,
    this.nameCaller,
    this.appName,
    this.avatar,
    this.handle,
    this.type,
    this.duration,
    this.isAccepted = false,
    this.missedCallNotification,
    this.callingNotification,
    this.extra,
    this.headers,
    this.android,
    this.ios,
  });

  final String id;
  final String? nameCaller;
  final String? appName;
  final String? avatar;
  final String? handle;
  final int? type;
  final int? duration;
  final bool isAccepted;

  final NotificationParams? missedCallNotification;
  final NotificationParams? callingNotification;

  final Map<String, dynamic>? extra;
  final Map<String, dynamic>? headers;

  final AndroidParams? android;
  final IOSParams? ios;

  factory CallKitParams.fromJson(Map<String, dynamic> json) =>
      _$CallKitParamsFromJson(json);

  Map<String, dynamic> toJson() => _$CallKitParamsToJson(this);

  @override
  String toString() {
    return 'CallKitParams{'
        'id: $id, '
        'nameCaller: $nameCaller, '
        'appName: $appName, '
        'avatar: $avatar, '
        'handle: $handle, '
        'type: $type, '
        'duration: $duration, '
        'isAccepted: $isAccepted, '
        'missedCallNotification: $missedCallNotification, '
        'callingNotification: $callingNotification, '
        'extra: $extra, '
        'headers: $headers, '
        'android: $android, '
        'ios: $ios'
        '}';
  }
}
