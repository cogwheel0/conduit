// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ios_params.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

IOSParams _$IOSParamsFromJson(Map<String, dynamic> json) => IOSParams(
      iconName: json['iconName'] as String?,
      handleType: json['handleType'] as String?,
      normalHandle: (json['normalHandle'] as num?)?.toInt(),
      supportsVideo: json['supportsVideo'] as bool?,
      maximumCallGroups: (json['maximumCallGroups'] as num?)?.toInt(),
      maximumCallsPerCallGroup:
          (json['maximumCallsPerCallGroup'] as num?)?.toInt(),
      supportsDTMF: json['supportsDTMF'] as bool?,
      supportsHolding: json['supportsHolding'] as bool?,
      supportsGrouping: json['supportsGrouping'] as bool?,
      supportsUngrouping: json['supportsUngrouping'] as bool?,
      includesCallsInRecents: json['includesCallsInRecents'] as bool?,
      ringtonePath: json['ringtonePath'] as String?,
      configureAudioSession: json['configureAudioSession'] as bool?,
      audioSessionMode: json['audioSessionMode'] as String?,
      audioSessionActive: json['audioSessionActive'] as bool?,
      audioSessionPreferredSampleRate:
          (json['audioSessionPreferredSampleRate'] as num?)?.toDouble(),
      audioSessionPreferredIOBufferDuration:
          (json['audioSessionPreferredIOBufferDuration'] as num?)?.toDouble(),
    );

Map<String, dynamic> _$IOSParamsToJson(IOSParams instance) => <String, dynamic>{
      'iconName': instance.iconName,
      'handleType': instance.handleType,
      'normalHandle': instance.normalHandle,
      'supportsVideo': instance.supportsVideo,
      'maximumCallGroups': instance.maximumCallGroups,
      'maximumCallsPerCallGroup': instance.maximumCallsPerCallGroup,
      'supportsDTMF': instance.supportsDTMF,
      'supportsHolding': instance.supportsHolding,
      'supportsGrouping': instance.supportsGrouping,
      'supportsUngrouping': instance.supportsUngrouping,
      'includesCallsInRecents': instance.includesCallsInRecents,
      'ringtonePath': instance.ringtonePath,
      'configureAudioSession': instance.configureAudioSession,
      'audioSessionMode': instance.audioSessionMode,
      'audioSessionActive': instance.audioSessionActive,
      'audioSessionPreferredSampleRate':
          instance.audioSessionPreferredSampleRate,
      'audioSessionPreferredIOBufferDuration':
          instance.audioSessionPreferredIOBufferDuration,
    };
