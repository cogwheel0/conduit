@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduit_core/features/chat/composer/composer_recording_store.dart';
import 'package:conduit_core/features/chat/server_speech/direct_voice_provider_settings.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:test/test.dart';

import 'support/fake_openai.dart';
import 'support/null_sink.dart';

/// Dictation's daemon side over a Direct connection kept on this computer:
/// which engine and backend dictation uses, a recording transcribed by the
/// chat's own backend (the Voice Provider), and recordings kept with the
/// draft as the phone keeps them.
void main() {
  late Directory temporary;
  late CoreRuntime runtime;
  late FakeOpenAi provider;
  late String modelId;
  late String connectionId;
  late VoiceService voice;
  late DictationService dictation;
  late DraftsService drafts;
  late RecordingsService recordings;

  /// [seconds] of 16 kHz mono PCM: a quiet ramp, never silence.
  Uint8List pcm(double seconds) {
    final samples = (16000 * seconds).round();
    final data = ByteData(samples * 2);
    for (var i = 0; i < samples; i++) {
      data.setInt16(i * 2, (i % 200) - 100, Endian.little);
    }
    return data.buffer.asUint8List();
  }

  setUpAll(() async {
    temporary = Directory.systemTemp.createTempSync('dictation-test');
    runtime = await CoreRuntime.start(
      config: BootstrapConfig(
        sessionToken: 'a' * 43,
        masterKey: base64.encode(List<int>.generate(32, (i) => i)),
        userDataDir: temporary.path,
      ),
      directories: DaemonDirectories.create(temporary.path),
      log: DaemonLog(level: 'error', sink: NullSink()),
    );
    provider = await FakeOpenAi.start();
    final direct = DirectService(runtime.container);
    await direct.setPreferred(preferred: true);
    final saved = await direct.save(
      DirectConnectionEdit(
        name: 'Fake',
        kind: DirectKind.openai,
        baseUrl: provider.baseUrl,
        manualModelIds: const <String>['fake-model'],
      ),
    );
    connectionId = saved.connections.single.id;
    final models = ModelsService(runtime.container);
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    ModelSummary? offered;
    while (offered == null && DateTime.now().isBefore(deadline)) {
      offered = (await models.list()).models
          .where((m) => m.connection == 'Fake')
          .firstOrNull;
      if (offered == null) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    modelId = offered!.id;
    await models.select(modelId);
    voice = VoiceService(
      runtime.container,
      events: EventBus(),
      whisperDirectory: Directory('${temporary.path}/whisper'),
      whisperLibrary: '/nonexistent',
    );
    dictation = DictationService(runtime.container, voice: voice);
    drafts = DraftsService(runtime.container, temporary: TemporaryChats());
    recordings = RecordingsService(drafts: drafts, dictation: dictation);
  });

  tearDownAll(() async {
    await provider.close();
    await runtime.dispose();
    temporary.deleteSync(recursive: true);
  });

  AppSettingsNotifier settings() =>
      runtime.container.read(appSettingsProvider.notifier);

  test('the engine and language follow Settings › Audio', () async {
    await settings().setSttPreference(SttPreference.deviceOnly);
    await settings().setSttLanguageCode('de');
    await settings().setVoiceSilenceDuration(1200);
    var status = await dictation.status(DictationTarget(modelId: modelId));
    expect(status.engine, 'device');
    expect(status.language, 'de');
    expect(status.silenceMs, 1200);
    expect(status.localAvailable, isTrue, reason: 'a library path was given');
    expect(status.localReady, isFalse, reason: 'no model downloaded');

    await settings().setSttPreference(SttPreference.serverOnly);
    status = await dictation.status(DictationTarget(modelId: modelId));
    expect(status.engine, 'server');
    // A Direct model with no Voice Provider never goes to another backend.
    expect(status.serverAvailable, isFalse);
    expect(status.serverSource, isNull);
  });

  test('a Direct chat transcribes through its Voice Provider', () async {
    await settings().setDirectVoiceProvider(
      DirectVoiceProviderSettings(
        profileId: connectionId,
        transcriptionModel: 'whisper-1',
      ),
    );
    final status = await dictation.status(DictationTarget(modelId: modelId));
    expect(status.serverAvailable, isTrue);
    expect(status.serverSource, 'direct');

    final before = provider.transcriptions.length;
    final transcript = await dictation.transcribe(
      pcm16Wav(pcm(0.5)),
      contentType: 'audio/wav',
      engine: 'server',
      modelId: modelId,
    );
    expect(transcript.text, 'A fake transcript.');
    final sent = provider.transcriptions.skip(before).single;
    expect(sent.language, 'de');
    expect(sent.bytes, greaterThan(16000));

    // Another account signs in while the chat's model is read: the audio
    // goes to no backend, and Try Again can send it under the new one.
    final late = dictation.transcribe(
      pcm16Wav(pcm(0.5)),
      contentType: 'audio/wav',
      engine: 'server',
      modelId: modelId,
      session: dictation.session(),
    );
    runtime.container.invalidate(openWebUiAuthSessionEpochProvider);
    await expectLater(
      late,
      throwsA(
        isA<RpcError>()
            .having((e) => e.code, 'code', ConduitErrorCodes.sessionExpired)
            .having((e) => e.retryable, 'retryable', isTrue),
      ),
    );
    expect(provider.transcriptions.length, before + 1);
  });

  test('whisper asked for by name must be ready', () async {
    await expectLater(
      dictation.transcribe(
        pcm16Wav(pcm(0.2)),
        contentType: 'audio/wav',
        engine: 'local',
      ),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.unsupported,
        ),
      ),
    );
    await expectLater(
      dictation.transcribe(Uint8List(0), engine: 'server'),
      throwsA(isA<RpcError>()),
    );
  });

  test('a recording is kept with the draft until it is discarded', () async {
    const target = RecordingTarget(folderId: 'dictation-folder');
    expect((await recordings.list(target)).recordings, isEmpty);
    final started = await recordings.begin(target, sessionId: 'window-1');
    final id = started.id!;
    expect(started.stored, isTrue);

    final chunk = base64Encode(pcm(1));
    var saved = await recordings.append(RecordingChunk(id: id, pcm: chunk));
    expect(saved.savedBytes, 32000);
    saved = await recordings.append(RecordingChunk(id: id, pcm: chunk));
    expect(saved.savedBytes, 64000);
    // Committed as it goes: listed while still open.
    final listed = (await recordings.list(target)).recordings.single;
    expect(listed.id, id);
    expect(listed.durationMs, 2000);

    saved = await recordings.close(RecordingRef(id: id));
    expect(saved.savedBytes, 64000);
    expect(saved.discarded, isFalse);

    final wav = await recordings.wav(
      RecordingRef(id: id, folderId: 'dictation-folder'),
    );
    expect(ascii.decode(wav.sublist(0, 4)), 'RIFF');
    expect(wav.length, 44 + 64000);
    // Another draft's id reads nothing.
    await expectLater(
      recordings.wav(RecordingRef(id: id, folderId: 'another-folder')),
      throwsA(isA<RpcError>()),
    );

    final transcript = await recordings.transcribe(
      RecordingTranscribe(
        id: id,
        folderId: 'dictation-folder',
        modelId: modelId,
      ),
    );
    expect(transcript.text, 'A fake transcript.');

    // Another account signs in while it is read: nothing reaches a backend.
    final sentBefore = provider.transcriptions.length;
    final late = recordings.transcribe(
      RecordingTranscribe(
        id: id,
        folderId: 'dictation-folder',
        modelId: modelId,
      ),
    );
    runtime.container.invalidate(openWebUiAuthSessionEpochProvider);
    await expectLater(
      late,
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.sessionExpired,
        ),
      ),
    );
    expect(provider.transcriptions.length, sentBefore);

    final after = await recordings.discard(
      RecordingRef(id: id, folderId: 'dictation-folder'),
    );
    expect(after.recordings, isEmpty);
  });

  test('an empty recording is not kept', () async {
    const target = RecordingTarget(folderId: 'empty-folder');
    final id = (await recordings.begin(target, sessionId: 'w')).id!;
    final saved = await recordings.close(RecordingRef(id: id));
    expect(saved.discarded, isTrue);
    expect((await recordings.list(target)).recordings, isEmpty);
    await expectLater(
      recordings.append(RecordingChunk(id: id, pcm: '')),
      throwsA(
        isA<RpcError>().having(
          (e) => e.code,
          'code',
          ConduitErrorCodes.notFound,
        ),
      ),
    );
  });

  test('a window that goes leaves its recording for the next launch', () async {
    const target = RecordingTarget(folderId: 'crash-folder');
    final id = (await recordings.begin(target, sessionId: 'gone')).id!;
    await recordings.append(RecordingChunk(id: id, pcm: base64Encode(pcm(1))));
    await recordings.closeOwnedBy('gone');
    // Its next session finds it, and can no longer append to it.
    final listed = (await recordings.list(target)).recordings.single;
    expect(listed.byteCount, 32000);
    await expectLater(
      recordings.append(RecordingChunk(id: id, pcm: '')),
      throwsA(isA<RpcError>()),
    );
    await recordings.discard(RecordingRef(id: id, folderId: 'crash-folder'));
  });

  test('a temporary chat keeps no recordings', () async {
    const target = RecordingTarget(chatId: 'local:temp-voice');
    expect((await recordings.list(target)).stored, isFalse);
    final started = await recordings.begin(target, sessionId: 'w');
    expect(started.stored, isFalse);
    expect(started.id, isNull);
  });

  test('audio that is not base64 or not whole samples is refused', () async {
    const target = RecordingTarget(folderId: 'bad-folder');
    final id = (await recordings.begin(target, sessionId: 'w')).id!;
    addTearDown(
      () => recordings.discard(RecordingRef(id: id, folderId: 'bad-folder')),
    );
    await expectLater(
      recordings.append(RecordingChunk(id: id, pcm: '***')),
      throwsA(isA<RpcError>()),
    );
    await expectLater(
      recordings.append(
        RecordingChunk(id: id, pcm: base64Encode(<int>[1, 2, 3])),
      ),
      throwsA(isA<RpcError>()),
    );
  });
}
