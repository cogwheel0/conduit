import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/src/bootstrap.dart';
import 'package:conduitd/src/core_runtime.dart';
import 'package:conduitd/src/daemon_paths.dart';
import 'package:conduitd/src/event_bus.dart';
import 'package:conduitd/src/local_whisper.dart';
import 'package:conduitd/src/log.dart';
import 'package:conduitd/src/voice_service.dart';
import 'package:test/test.dart';

import 'support/null_sink.dart';

/// Transcribing on this computer, through the daemon's voice service
/// with no server at all. The whisper parts run when a built library and a
/// model are at hand: CONDUIT_WHISPER_LIB and CONDUIT_WHISPER_MODEL (a
/// ggml-tiny.en.bin), with CONDUIT_SPEECH_SAMPLE the fox sentence as WAV.
void main() {
  late Directory temporary;
  late CoreRuntime runtime;
  final library = Platform.environment['CONDUIT_WHISPER_LIB'];
  final model = Platform.environment['CONDUIT_WHISPER_MODEL'];
  final sample = Platform.environment['CONDUIT_SPEECH_SAMPLE'];

  setUpAll(() async {
    temporary = Directory.systemTemp.createTempSync('voice-local-test');
    runtime = await CoreRuntime.start(
      config: BootstrapConfig(
        sessionToken: 'a' * 43,
        masterKey: base64.encode(List<int>.generate(32, (i) => i)),
        userDataDir: temporary.path,
      ),
      directories: DaemonDirectories.create(temporary.path),
      log: DaemonLog(level: 'error', sink: NullSink()),
    );
  });

  tearDownAll(() async {
    await runtime.dispose();
    temporary.deleteSync(recursive: true);
  });

  VoiceService service({String? withLibrary}) => VoiceService(
    runtime.container,
    events: EventBus(),
    whisperDirectory: Directory('${temporary.path}/whisper'),
    whisperLibrary: withLibrary,
  );

  test('the engine and model are settings of their own', () async {
    final voice = service();
    expect((await voice.settings()).sttEngine, 'server');
    final saved = await voice.save(
      const VoiceSettingsEdit(sttEngine: 'local', localModel: 'tiny.en'),
    );
    expect(saved.sttEngine, 'local');
    expect(saved.localModel, 'tiny.en');
    expect(saved.localReady, isFalse, reason: 'nothing downloaded');
    await expectLater(
      voice.save(const VoiceSettingsEdit(localModel: 'huge')),
      throwsA(isA<RpcError>()),
    );
    // Back to the default for the next test.
    await voice.save(const VoiceSettingsEdit(sttEngine: 'server'));
  });

  test('lists the models, none downloaded', () {
    final models = service().models().models;
    expect(models.map((m) => m.id), contains('base.en'));
    expect(models.every((m) => !m.downloaded), isTrue);
    expect(models.firstWhere((m) => m.id == 'small').sizeBytes, 487601967);
  });

  test('with no model yet, the server transcribes instead', () async {
    final voice = service(withLibrary: library ?? '/nonexistent');
    await voice.save(const VoiceSettingsEdit(sttEngine: 'local'));
    try {
      await expectLater(
        // No server either, here: that is what it says.
        voice.transcribe(
          Uint8List.fromList(<int>[1, 2, 3]),
          contentType: 'audio/wav',
        ),
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            ConduitErrorCodes.unauthenticated,
          ),
        ),
      );
    } finally {
      await voice.save(const VoiceSettingsEdit(sttEngine: 'server'));
    }
  });

  test(
    'transcribes with a downloaded model, and wants WAV',
    () async {
      final dir = Directory('${temporary.path}/whisper')..createSync();
      // Stands in for the download: the same file, where it would land.
      File(model!).copySync('${dir.path}/${whisperModel('tiny.en')!.fileName}');
      final voice = service(withLibrary: library);
      final settings = await voice.save(
        const VoiceSettingsEdit(sttEngine: 'local', localModel: 'tiny.en'),
      );
      expect(settings.localStt, isTrue);
      expect(settings.localReady, isTrue);
      try {
        final transcript = await voice.transcribe(
          File(sample!).readAsBytesSync(),
          contentType: 'audio/wav',
        );
        expect(transcript.text.toLowerCase(), contains('quick brown fox'));
        await expectLater(
          voice.transcribe(
            File(sample).readAsBytesSync(),
            contentType: 'audio/webm',
          ),
          throwsA(isA<RpcError>()),
        );
        expect(
          voice.models().models.firstWhere((m) => m.id == 'tiny.en').downloaded,
          isTrue,
        );
        voice.deleteModel('tiny.en');
        expect((await voice.settings()).localReady, isFalse);
      } finally {
        await voice.save(const VoiceSettingsEdit(sttEngine: 'server'));
      }
    },
    skip: library == null || model == null || sample == null
        ? 'set CONDUIT_WHISPER_LIB, CONDUIT_WHISPER_MODEL and CONDUIT_SPEECH_SAMPLE'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
