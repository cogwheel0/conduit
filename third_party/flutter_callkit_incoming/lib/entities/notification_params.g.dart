// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'notification_params.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

NotificationParams _$NotificationParamsFromJson(Map<String, dynamic> json) =>
    NotificationParams(
      id: (json['id'] as num?)?.toInt(),
      showNotification: json['showNotification'] as bool?,
      subtitle: json['subtitle'] as String?,
      callbackText: json['callbackText'] as String?,
      isShowCallback: json['isShowCallback'] as bool?,
      count: (json['count'] as num?)?.toInt(),
    );

Map<String, dynamic> _$NotificationParamsToJson(NotificationParams instance) =>
    <String, dynamic>{
      'id': instance.id,
      'showNotification': instance.showNotification,
      'subtitle': instance.subtitle,
      'callbackText': instance.callbackText,
      'isShowCallback': instance.isShowCallback,
      'count': instance.count,
    };
