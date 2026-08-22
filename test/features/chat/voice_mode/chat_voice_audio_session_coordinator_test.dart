// ignore_for_file: experimental_member_use

import 'package:audio_session/audio_session.dart';
import 'package:checks/checks.dart';
import 'package:conduit/features/chat/voice_mode/chat_voice_audio_session_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatVoiceAudioSessionCoordinator.isExternalAudioAccessory', () {
    test('treats attached listening hardware as an accessory', () {
      for (final type in const [
        AudioDeviceType.wiredHeadset,
        AudioDeviceType.wiredHeadphones,
        AudioDeviceType.headsetMic,
        AudioDeviceType.bluetoothSco,
        AudioDeviceType.bluetoothA2dp,
        AudioDeviceType.bluetoothLe,
        AudioDeviceType.usbAudio,
        AudioDeviceType.hearingAid,
        AudioDeviceType.carAudio,
        AudioDeviceType.airPlay,
      ]) {
        check(
          because: '$type should keep the call off the loudspeaker',
          ChatVoiceAudioSessionCoordinator.isExternalAudioAccessory(type),
        ).isTrue();
      }
    });

    test('does not count the phone itself as an accessory', () {
      // A bare phone must fall through to the speakerphone default, so none of
      // the always-present built-ins may look like something to route to.
      for (final type in const [
        AudioDeviceType.builtInEarpiece,
        AudioDeviceType.builtInSpeaker,
        AudioDeviceType.builtInSpeakerSafe,
        AudioDeviceType.builtInMic,
        AudioDeviceType.telephony,
        AudioDeviceType.remoteSubmix,
        AudioDeviceType.unknown,
      ]) {
        check(
          because: '$type is part of the phone, not an accessory',
          ChatVoiceAudioSessionCoordinator.isExternalAudioAccessory(type),
        ).isFalse();
      }
    });
  });

  group('ChatVoiceAudioSessionCoordinator device changes', () {
    late ChatVoiceAudioSessionCoordinator coordinator;
    late List<bool> routeChanges;

    setUp(() {
      coordinator = ChatVoiceAudioSessionCoordinator();
      routeChanges = <bool>[];
      coordinator.speakerphoneRouteChanges.listen(routeChanges.add);
      addTearDown(coordinator.dispose);
    });

    Future<void> reportDevices(List<AudioDeviceType> types) async {
      var id = 0;
      await coordinator.handleAudioDevicesChangedForTesting({
        for (final type in types)
          AudioDevice(
            id: '${id++}',
            name: type.name,
            isInput: false,
            isOutput: true,
            type: type,
          ),
      });
      await pumpEventQueue();
    }

    test('follows accessories plugged in and pulled out mid-call', () async {
      await reportDevices(const [
        AudioDeviceType.builtInEarpiece,
        AudioDeviceType.builtInSpeaker,
      ]);
      check(routeChanges).deepEquals(<bool>[true]);

      await reportDevices(const [
        AudioDeviceType.builtInEarpiece,
        AudioDeviceType.builtInSpeaker,
        AudioDeviceType.wiredHeadphones,
      ]);
      check(routeChanges).deepEquals(<bool>[true, false]);

      // Headphones pulled out: back to the loudspeaker rather than the earpiece.
      await reportDevices(const [
        AudioDeviceType.builtInEarpiece,
        AudioDeviceType.builtInSpeaker,
      ]);
      check(routeChanges).deepEquals(<bool>[true, false, true]);
    });

    test('reroutes once when one accessory announces several ends', () async {
      await reportDevices(const [AudioDeviceType.builtInSpeaker]);
      check(routeChanges).deepEquals(<bool>[true]);

      await reportDevices(const [
        AudioDeviceType.builtInSpeaker,
        AudioDeviceType.bluetoothA2dp,
      ]);
      await reportDevices(const [
        AudioDeviceType.builtInSpeaker,
        AudioDeviceType.bluetoothA2dp,
        AudioDeviceType.bluetoothSco,
      ]);

      check(routeChanges).deepEquals(<bool>[true, false]);
    });

    test('stops second-guessing the route after a manual toggle', () async {
      await coordinator.setSpeakerphoneEnabled(false);

      await reportDevices(const [
        AudioDeviceType.builtInEarpiece,
        AudioDeviceType.builtInSpeaker,
      ]);

      check(routeChanges).isEmpty();
    });

    test('drops a reroute the speaker button overtakes', () async {
      // The reroute is in flight, not finished, when the button is pressed.
      final rerouting = reportDevices(const [AudioDeviceType.builtInEarpiece]);
      await coordinator.setSpeakerphoneEnabled(false);
      await rerouting;

      check(
        because: 'the button press is newer than the accessory scan',
        routeChanges,
      ).isEmpty();
    });

    test('drops a reroute that hanging up overtakes', () async {
      final rerouting = reportDevices(const [AudioDeviceType.builtInEarpiece]);
      await coordinator.deactivate();
      await rerouting;

      check(routeChanges).isEmpty();
    });

    test('reroutes once to the newest route when events overlap', () async {
      // Start the call on a headset, so the loudspeaker is genuinely off.
      await reportDevices(const [
        AudioDeviceType.builtInSpeaker,
        AudioDeviceType.wiredHeadphones,
      ]);
      check(routeChanges).isEmpty();

      // A loose jack: out, in, out again, all before the first reroute has
      // finished talking to the platform. Rerouting three times in a row would
      // leave whichever call finished last owning the route, so the coordinator
      // collapses the flapping into the one move that matches the hardware now.
      final flapping = <Future<void>>[
        coordinator.handleAudioDevicesChangedForTesting({
          _outputDevice(AudioDeviceType.builtInSpeaker),
        }),
        coordinator.handleAudioDevicesChangedForTesting({
          _outputDevice(AudioDeviceType.builtInSpeaker),
          _outputDevice(AudioDeviceType.wiredHeadphones),
        }),
        coordinator.handleAudioDevicesChangedForTesting({
          _outputDevice(AudioDeviceType.builtInSpeaker),
        }),
      ];
      await Future.wait(flapping);
      await pumpEventQueue();

      check(
        because: 'the headset is out, so the call belongs on the loudspeaker',
        routeChanges,
      ).deepEquals(<bool>[true]);
    });
  });
}

AudioDevice _outputDevice(AudioDeviceType type) => AudioDevice(
  id: type.name,
  name: type.name,
  isInput: false,
  isOutput: true,
  type: type,
);
