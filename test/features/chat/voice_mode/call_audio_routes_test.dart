import 'package:conduit/features/chat/voice_mode/chat_voice_audio_session_coordinator.dart';
import 'package:conduit/features/chat/voice_mode/chat_voice_mode_controller.dart';
import 'package:conduit/features/chat/voice_mode/call_audio_routes.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Call extends ChatVoiceModeController {
  @override
  ChatVoiceModeSnapshot build() => ChatVoiceModeSnapshot(
    phase: ChatVoiceModePhase.listening,
    startedAt: DateTime(2026, 10, 22),
    activeCallId: 'call',
    isCollapsed: true,
  );
  @override
  Future<void> pause() async =>
      state = state.copyWith(phase: ChatVoiceModePhase.paused);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.cogwheel.conduit/telecom_call');
  for (final refusal in [false, true]) {
    test(
      'route cycling follows confirmed Android output (refusal=$refusal)',
      () async {
        var selected = 'speaker';
        var bluetooth = true;
        final requested = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'selectAudioRoute') {
                requested.add((call.arguments as Map)['route'] as String);
                if (!refusal) selected = requested.last;
              }
              return {
                'selected': selected,
                'routes': [
                  {'id': 'speaker', 'name': 'Speaker', 'kind': 'speaker'},
                  {'id': 'phone', 'name': 'Phone earpiece', 'kind': 'phone'},
                  if (bluetooth)
                    {
                      'id': 'bt',
                      'name': 'Connected headphones',
                      'kind': 'bluetooth',
                    },
                ],
              };
            });
        final owner = ChatVoiceAudioSessionCoordinator()
          ..debugTreatAsAndroid = true;
        final container = ProviderContainer(
          overrides: [
            voiceAudioSessionProvider.overrideWithValue(owner),
            chatVoiceModeControllerProvider.overrideWith(_Call.new),
          ],
        );
        final subscription = container.listen(
          callAudioRoutesProvider,
          (_, _) {},
        );
        await Future<void>.delayed(Duration.zero);
        final controller = container.read(callAudioRoutesProvider.notifier);
        await controller.refresh();
        expect(container.read(callAudioRoutesProvider).selected, 'speaker');
        expect(await controller.cycle(), !refusal);
        expect(
          container.read(callAudioRoutesProvider).selected,
          refusal ? 'speaker' : 'phone',
        );
        expect(requested, ['phone']);
        if (!refusal) {
          await controller.cycle();
          expect(
            container.read(callAudioRoutesProvider).current!.name,
            'Connected headphones',
          );
          bluetooth = false;
          selected = 'phone';
          await controller.refresh();
          expect(
            container.read(chatVoiceModeControllerProvider).phase,
            ChatVoiceModePhase.paused,
          );
          expect(
            container
                .read(callAudioRoutesProvider)
                .routes
                .any((r) => r.kind == 'bluetooth'),
            isFalse,
          );
        }
        subscription.close();
        container.dispose();
        await owner.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      },
    );
  }
  test('a late route request cannot restore audio after hangup', () async {
    var writes = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'selectAudioRoute') writes++;
          return {'selected': 'phone', 'routes': []};
        });
    final owner = ChatVoiceAudioSessionCoordinator()
      ..debugTreatAsAndroid = true;
    final pending = owner.selectCallAudioRoute('phone');
    await owner.deactivate();
    expect(await pending, isFalse);
    expect(writes, 0);
    await owner.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
}
