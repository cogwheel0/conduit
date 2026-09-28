@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/l10n/strings.g.dart';
import 'package:conduit_desktop_ui/src/pages/audio_settings_tab.dart';
import 'package:conduit_desktop_ui/src/rpc/voice_providers.dart';
import 'package:conduit_desktop_ui/src/voice_port.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_test/jaspr_test.dart';

const VoiceModels _models = VoiceModels(
  models: <VoiceModel>[
    VoiceModel(
      id: 'tiny.en',
      name: 'Tiny (English)',
      sizeBytes: 77704715,
      englishOnly: true,
    ),
    VoiceModel(
      id: 'base',
      name: 'Base',
      sizeBytes: 147951465,
      downloaded: true,
    ),
    VoiceModel(
      id: 'small',
      name: 'Small',
      sizeBytes: 487601967,
      receivedBytes: 243800984,
    ),
  ],
);

class _FakeVoice extends VoiceActions {
  _FakeVoice(super.ref);

  VoiceSettings current = const VoiceSettings(serverStt: true);
  final List<VoiceSettingsEdit> saved = <VoiceSettingsEdit>[];

  @override
  Future<VoiceSettings> settings() async => current;

  @override
  Future<VoiceSettings> save(VoiceSettingsEdit edit) async {
    saved.add(edit);
    return current;
  }

  VoiceModels list = _models;
  final List<String> downloads = <String>[];

  @override
  Future<VoiceModels> models() async => list;

  @override
  Future<VoiceModels> downloadModel(String id) async {
    downloads.add(id);
    return list;
  }

  @override
  Future<VoiceVoices> voices() async => const VoiceVoices(
    voices: <VoiceOption>[VoiceOption(id: 'echo', name: 'Echo')],
    defaultVoice: 'alloy',
  );
}

/// The `input` whose id is [id]: its handlers are called directly, as a
/// change event cannot carry a value on the VM.
/// Dynamic: the inputs differ in their value type.
dynamic _input(String id) => find
    .byComponentPredicate((c) => c is input && c.id == id)
    .evaluate()
    .first
    .component;

void main() {
  late _FakeVoice voice;
  late RecordingVoice port;

  Component scoped({VoiceSettings? settings}) {
    port = RecordingVoice();
    return ProviderScope(
      overrides: [
        voicePortProvider.overrideWithValue(port),
        voiceModelsProvider.overrideWith((ref) => Stream.value(_models)),
        voiceActionsProvider.overrideWith((ref) {
          voice = _FakeVoice(ref);
          if (settings != null) voice.current = settings;
          return voice;
        }),
      ],
      child: const AudioSettingsTab(),
    );
  }

  testComponents('each setting saves as it changes', (tester) async {
    tester.pumpComponent(scoped());
    await pumpEventQueue();
    _input('voice-hold').onChange(true);
    _input('voice-silence').onChange(1200);
    _input('voice-language').onInput('FR');
    _input('tts-rate').onChange(0.75);
    await pumpEventQueue();
    expect(voice.saved.map((edit) => edit.toJson()), [
      const VoiceSettingsEdit(holdToTalk: true).toJson(),
      const VoiceSettingsEdit(silenceMs: 1200).toJson(),
      const VoiceSettingsEdit(sttLanguage: 'fr').toJson(),
      const VoiceSettingsEdit(rate: 0.75).toJson(),
    ]);
  });

  testComponents('a language code that is not one says so', (tester) async {
    tester.pumpComponent(scoped());
    await pumpEventQueue();
    _input('voice-language').onInput('english');
    await pumpEventQueue();
    expect(find.text(t.app.sttTranscriptionLanguageInvalid), findsOneComponent);
    expect(voice.saved, isEmpty);
  });

  testComponents('the server engine is offered only when it speaks', (
    tester,
  ) async {
    tester.pumpComponent(scoped());
    await pumpEventQueue();
    expect(_input('tts-engine-server').disabled, isTrue);
    expect(find.text(t.app.ttsServerUnavailableWarning), findsOneComponent);
    // The system's voices, by name.
    expect(find.text('Amelie (fr-FR)'), findsOneComponent);
  });

  testComponents('with the server engine, its voices are the choice', (
    tester,
  ) async {
    tester.pumpComponent(
      scoped(
        settings: const VoiceSettings(serverTts: true, ttsEngine: 'server'),
      ),
    );
    await pumpEventQueue();
    expect(find.text('Echo'), findsOneComponent);
    expect(find.text('${t.app.ttsSystemDefault} (alloy)'), findsOneComponent);
  });

  testComponents('preview says a sentence with the chosen voice', (
    tester,
  ) async {
    tester.pumpComponent(scoped());
    await pumpEventQueue();
    await tester.click(
      find.ancestor(
        of: find.text(t.app.ttsPreview),
        matching: find.tag('button'),
      ),
    );
    await pumpEventQueue();
    expect(port.spoken.single, startsWith('device:'));
  });

  testComponents('on this computer: models to download, use and delete', (
    tester,
  ) async {
    tester.pumpComponent(
      scoped(
        settings: const VoiceSettings(
          localStt: true,
          sttEngine: 'local',
          localModel: 'base',
          localReady: true,
        ),
      ),
    );
    await pumpEventQueue();
    await pumpEventQueue();
    expect(find.text(t.desktop.desktopSttModelsTitle), findsOneComponent);
    expect(find.text(t.desktop.desktopSttModelInUse), findsOneComponent);
    expect(
      find.text(t.desktop.desktopSttModelDownloading(percent: '50')),
      findsOneComponent,
    );
    await tester.click(
      find.byComponentPredicate(
        (c) => c is DomComponent && c.id == 'download-tiny.en',
      ),
    );
    await pumpEventQueue();
    expect(voice.downloads, ['tiny.en']);
    // The server engine is offered only when the server transcribes.
    expect(_input('stt-engine-server').disabled, isTrue);
  });

  testComponents('without the local engine, no engine choice at all', (
    tester,
  ) async {
    tester.pumpComponent(scoped());
    await pumpEventQueue();
    expect(find.text(t.desktop.desktopSttEngineLocal), findsNothing);
  });
}
