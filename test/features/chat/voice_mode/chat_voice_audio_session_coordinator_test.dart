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
        AudioDeviceType.bluetoothLe,
        AudioDeviceType.usbAudio,
        AudioDeviceType.hearingAid,
        AudioDeviceType.carAudio,
      ]) {
        check(
          because: '$type should keep the call off the loudspeaker',
          ChatVoiceAudioSessionCoordinator.isExternalAudioAccessory(type),
        ).isTrue();
      }
    });

    test('does not count anything a call cannot play through', () {
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
        // A call runs in communication mode, which cannot route to either.
        AudioDeviceType.bluetoothA2dp,
        AudioDeviceType.airPlay,
      ]) {
        check(
          because: '$type is not somewhere a call can play',
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
        AudioDeviceType.bluetoothSco,
      ]);
      await reportDevices(const [
        AudioDeviceType.builtInSpeaker,
        AudioDeviceType.bluetoothSco,
        AudioDeviceType.wiredHeadphones,
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

    test('lets the hardware back in after a refused button press', () async {
      coordinator.debugRefuseRouteChanges = true;
      check(await coordinator.setSpeakerphoneEnabled(false)).isFalse();
      coordinator.debugRefuseRouteChanges = false;

      // The press moved nothing, so it must not cost the rest of the call its
      // automatic routing.
      await reportDevices(const [AudioDeviceType.builtInSpeaker]);

      check(routeChanges).deepEquals(<bool>[true]);
    });

    test('ignores a microphone with no output of its own', () async {
      await coordinator.handleAudioDevicesChangedForTesting({
        _outputDevice(AudioDeviceType.builtInSpeaker),
        // A plugged-in mic is not somewhere to play the answer.
        AudioDevice(
          id: 'mic',
          name: 'usb mic',
          isInput: true,
          isOutput: false,
          type: AudioDeviceType.usbAudio,
        ),
      });
      await pumpEventQueue();

      check(routeChanges).deepEquals(<bool>[true]);
    });

    test('ignores the speaker button once the call is being torn down', () async {
      final hangingUp = coordinator.deactivate();
      await coordinator.setSpeakerphoneEnabled(true);
      await hangingUp;

      // The next call still gets its automatic default: the press was rejected
      // outright rather than latched as a manual choice.
      await reportDevices(const [AudioDeviceType.builtInSpeaker]);

      check(routeChanges).deepEquals(<bool>[true]);
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

    test('tears the call down when disposal beats hanging up', () async {
      await reportDevices(const [AudioDeviceType.builtInSpeaker]);
      check(routeChanges).deepEquals(<bool>[true]);

      // Riverpod gives no order to provider disposal, so the coordinator can go
      // first and never see the controller's `deactivate`. Disposing has to
      // hand the route back on its own.
      await coordinator.dispose();

      check(coordinator.debugRouteTeardowns).deepEquals(<String>['dispose']);
      check(
        because: 'a disposed coordinator has no call left to route',
        await coordinator.setSpeakerphoneEnabled(true),
      ).isFalse();
      await reportDevices(const [AudioDeviceType.wiredHeadphones]);
      check(routeChanges).deepEquals(<bool>[true]);
    });

    test('survives hanging up and disposal both arriving', () async {
      await coordinator.deactivate();
      await coordinator.dispose();

      check(coordinator.debugRouteTeardowns)
          .deepEquals(<String>['deactivate', 'dispose']);
    });

    test('stays shut once disposed, however late hanging up is', () async {
      await coordinator.dispose();
      // Teardown normally lifts the shutter for the next call. A disposed
      // coordinator has no next call, so this must not leave the button able to
      // put the phone back into communication mode.
      await coordinator.deactivate();

      check(await coordinator.setSpeakerphoneEnabled(true)).isFalse();
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
