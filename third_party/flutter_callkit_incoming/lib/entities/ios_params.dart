import 'package:json_annotation/json_annotation.dart';

part 'ios_params.g.dart';

/// Object config for iOS.
@JsonSerializable(explicitToJson: true)
class IOSParams {
  /// App's Icon. using for display inside Callkit(iOS)
  final String? iconName;

  /// Type handle call `generic`, `number`, `email`
  final String? handleType;

  /// If normalHandle > 0, handle will not be encrypted
  final int? normalHandle;

  final bool? supportsVideo;
  final int? maximumCallGroups;
  final int? maximumCallsPerCallGroup;
  final bool? supportsDTMF;
  final bool? supportsHolding;
  final bool? supportsGrouping;
  final bool? supportsUngrouping;
  final bool? includesCallsInRecents;

  /// Add file to root project xcode /ios/Runner/Ringtone.caf and Copy Bundle Resources(Build Phases) -> value: "Ringtone.caf"
  final String? ringtonePath;
  final bool? configureAudioSession;
  final String? audioSessionMode;
  final bool? audioSessionActive;
  final double? audioSessionPreferredSampleRate;
  final double? audioSessionPreferredIOBufferDuration;

  const IOSParams({
    this.iconName,
    this.handleType,
    this.normalHandle,
    this.supportsVideo,
    this.maximumCallGroups,
    this.maximumCallsPerCallGroup,
    this.supportsDTMF,
    this.supportsHolding,
    this.supportsGrouping,
    this.supportsUngrouping,
    this.includesCallsInRecents,
    this.ringtonePath,
    this.configureAudioSession,
    this.audioSessionMode,
    this.audioSessionActive,
    this.audioSessionPreferredSampleRate,
    this.audioSessionPreferredIOBufferDuration,
  });

  factory IOSParams.fromJson(Map<String, dynamic> json) =>
      _$IOSParamsFromJson(json);

  Map<String, dynamic> toJson() => _$IOSParamsToJson(this);

  @override
  String toString() {
    return 'IOSParams{'
        'iconName: $iconName, '
        'handleType: $handleType, '
        'normalHandle: $normalHandle, '
        'supportsVideo: $supportsVideo, '
        'maximumCallGroups: $maximumCallGroups, '
        'maximumCallsPerCallGroup: $maximumCallsPerCallGroup, '
        'supportsDTMF: $supportsDTMF, '
        'supportsHolding: $supportsHolding, '
        'supportsGrouping: $supportsGrouping, '
        'supportsUngrouping: $supportsUngrouping, '
        'includesCallsInRecents: $includesCallsInRecents, '
        'ringtonePath: $ringtonePath, '
        'configureAudioSession: $configureAudioSession, '
        'audioSessionMode: $audioSessionMode, '
        'audioSessionActive: $audioSessionActive, '
        'audioSessionPreferredSampleRate: $audioSessionPreferredSampleRate, '
        'audioSessionPreferredIOBufferDuration: $audioSessionPreferredIOBufferDuration'
        '}';
  }
}
