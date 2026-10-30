import 'dart:async';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:conduit_core/conduit_core.dart';
import 'package:conduit_core/features/chat/server_speech/openwebui_server_speech.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit/features/chat/services/native_stt_service.dart';
import 'package:conduit_core/features/chat/services/server_vad_recorder.dart';
import 'package:conduit/features/chat/services/voice_input_service.dart';
import 'package:dio/dio.dart'
    show DioException, DioExceptionType, RequestOptions;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:permission_handler_platform_interface/permission_handler_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:vad/vad.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Regression guard for issue #557: on a fresh install iOS reports the mic
  // permission as "denied" (not-determined). checkPermissions() must actively
  // REQUEST the permission so the system dialog appears, rather than only
  // reading the current status and silently failing the voice flow.
  group('VoiceInputService.checkPermissions', () {
    late _MockPermissionHandlerPlatform mockPermissions;
    late PermissionHandlerPlatform originalPlatform;

    setUpAll(() {
      registerFallbackValue(<Permission>[Permission.microphone]);
    });

    setUp(() {
      originalPlatform = PermissionHandlerPlatform.instance;
      mockPermissions = _MockPermissionHandlerPlatform();
      PermissionHandlerPlatform.instance = mockPermissions;
    });

    tearDown(() {
      PermissionHandlerPlatform.instance = originalPlatform;
    });

    test('requests the microphone dialog when status is not granted', () async {
      when(() => mockPermissions.checkPermissionStatus(Permission.microphone))
          .thenAnswer((_) async => PermissionStatus.denied);
      when(() => mockPermissions.requestPermissions(any())).thenAnswer(
        (_) async => {Permission.microphone: PermissionStatus.granted},
      );

      final granted = await VoiceInputService().checkPermissions();

      check(granted).isTrue();
      // The core of the bug: it must call requestPermissions, not just read.
      verify(() => mockPermissions.requestPermissions(any())).called(1);
    });

    test('does not re-prompt when permission is already granted', () async {
      when(() => mockPermissions.checkPermissionStatus(Permission.microphone))
          .thenAnswer((_) async => PermissionStatus.granted);

      final granted = await VoiceInputService().checkPermissions();

      check(granted).isTrue();
      verifyNever(() => mockPermissions.requestPermissions(any()));
    });

    test(
      'returns false without granting when the user denies the request',
      () async {
        when(() => mockPermissions.checkPermissionStatus(Permission.microphone))
            .thenAnswer((_) async => PermissionStatus.denied);
        when(() => mockPermissions.requestPermissions(any())).thenAnswer(
          (_) async => {Permission.microphone: PermissionStatus.denied},
        );

        final granted = await VoiceInputService().checkPermissions();

        check(granted).isFalse();
        verify(() => mockPermissions.requestPermissions(any())).called(1);
      },
    );
  });
  group('VoiceInputService.silenceDurationToVadFrames', () {
    test('does not shorten the requested pause window', () {
      check(VoiceInputService.silenceDurationToVadFrames(2000)).equals(63);
      check(VoiceInputService.silenceDurationToVadFrames(2017)).equals(64);
    });

    test('preserves longer server STT silence windows', () {
      check(VoiceInputService.silenceDurationToVadFrames(3000)).equals(94);
      check(VoiceInputService.silenceDurationToVadFrames(5000)).equals(157);
    });
  });

  group('VoiceInputService.resolveServerLanguageHint', () {
    test('uses explicit STT language', () {
      final language = VoiceInputService.resolveServerLanguageHint(
        configuredLanguageCode: 'PL',
      );

      check(language).equals('pl');
    });

    test('omits language when no explicit language is set', () {
      final language = VoiceInputService.resolveServerLanguageHint(
        configuredLanguageCode: null,
      );

      check(language).isNull();
    });

    test('omits language for auto-like inputs', () {
      final language = VoiceInputService.resolveServerLanguageHint(
        configuredLanguageCode: 'auto',
      );

      check(language).isNull();
    });
  });

  test(
    'native capture drains audio on stop without persisting voice calls',
    () async {
      final native = _FakeNativeSttService();
      final service = _SupportedVoiceInputService(nativeStt: native);
      addTearDown(service.dispose);
      await service.initialize(forceLocalStt: true);
      final bytes = <int>[];
      var closed = false;
      final stream = await service.startListening(
        recording: VoiceInputRecording(
          add: bytes.addAll,
          close: () async => closed = true,
        ),
      );
      final subscription = stream.listen((_) {});
      expect(native.emitAudioRequested, isTrue);
      native._events.add(
        NativeSttEvent(type: 'audio', pcm: Uint8List.fromList([1, 2])),
      );
      await pumpEventQueue();
      native.onStop = () async {
        expect(closed, isFalse);
        native._events.add(
          NativeSttEvent(type: 'audio', pcm: Uint8List.fromList([3, 4])),
        );
        await pumpEventQueue();
      };
      await service.stopListening();
      native.onStop = null;
      expect(bytes, [1, 2, 3, 4]);
      expect(closed, isTrue);
      await subscription.cancel();
      final next = await service.startListening();
      final nextSub = next.listen((_) {});
      expect(native.emitAudioRequested, isFalse);
      await service.stopListening();
      await nextSub.cancel();
    },
  );

  test('incomplete recovery audio reports its typed error and drains the saved prefix', () async {
    final native = _FakeNativeSttService();
    final service = _SupportedVoiceInputService(nativeStt: native);
    addTearDown(service.dispose);
    await service.initialize(forceLocalStt: true);
    final bytes = <int>[];
    final failure = Completer<Object>();
    final stream = await service.startListening(recording: VoiceInputRecording(
      add: bytes.addAll, close: () async {},
    ));
    final subscription = stream.listen((_) {}, onError: failure.complete);
    native._events.add(NativeSttEvent(type: 'audio', pcm: Uint8List.fromList([1, 2])));
    native._events.add(const NativeSttEvent(type: 'error', code: 'AUDIO_PRESERVATION_FAILED', message: 'Synthetic overflow'));
    final error = await failure.future;
    expect(error, isA<NativeSttException>().having((error) => error.code, 'code', 'AUDIO_PRESERVATION_FAILED'));
    await service.stopListening();
    expect(bytes, [1, 2]);
    await subscription.cancel();
  });

  group('VoiceInputService on-device recognition language', () {
    test('leaves the native locale unset for automatic recognition', () async {
      final nativeStt = _FakeNativeSttService();
      final service = _SupportedVoiceInputService(nativeStt: nativeStt);

      await service.initialize(forceLocalStt: true);

      check(nativeStt.availabilityLocaleId).isNull();
      check(service.selectedLocaleId).isNull();
    });

    test(
      'uses a supported system-language variant when auto is unavailable',
      () async {
        final nativeStt = _FakeNativeSttService(systemLocaleId: 'en-IN');
        final service = _SupportedVoiceInputService(
          nativeStt: nativeStt,
          usesAutomaticNativeLanguage: false,
        );

        await service.initialize(forceLocalStt: true);

        check(nativeStt.availabilityLocaleId).equals('en-US');
        check(service.selectedLocaleId).equals('en-US');
      },
    );

    test('resolves the system sentinel to the current device tag', () async {
      final nativeStt = _FakeNativeSttService();
      final service = _SupportedVoiceInputService(
        nativeStt: nativeStt,
        deviceLocaleTag: 'en-GB',
      );
      service.setLocale(SettingsService.voiceLocaleSystemDefault);

      await service.initialize(forceLocalStt: true);

      check(nativeStt.availabilityLocaleId).equals('en-GB');
      check(service.selectedLocaleId).equals('en-GB');
    });

    test('preserves an explicit full locale while loading locales', () async {
      final nativeStt = _FakeNativeSttService();
      final service = _SupportedVoiceInputService(nativeStt: nativeStt);
      service.setLocale('pl_PL');

      await service.initialize(forceLocalStt: true);
      await service.startListening();

      check(nativeStt.availabilityLocaleId).equals('pl-PL');
      check(nativeStt.startLocaleId).equals('pl-PL');
      check(service.selectedLocaleId).equals('pl-PL');
      await service.stopListening();
    });

    test(
      'applies live explicit, system, and auto preference changes',
      () async {
        final nativeStt = _FakeNativeSttService();
        final service = _SupportedVoiceInputService(
          nativeStt: nativeStt,
          deviceLocaleTag: 'en-GB',
        );
        await service.initialize(forceLocalStt: true);

        service.setLocale('pl-PL');
        await service.initialize(forceLocalStt: true);
        service.setLocale(SettingsService.voiceLocaleSystemDefault);
        await service.initialize(forceLocalStt: true);
        service.setLocale(null);
        await service.initialize(forceLocalStt: true);

        check(nativeStt.availabilityLocaleIds)
            .deepEquals([null, 'pl-PL', 'en-GB', null]);
        check(service.selectedLocaleId).isNull();
      },
    );
  });

  test('forwards native failures to transcript-event listeners', () async {
    final nativeStt = _FakeNativeSttService();
    final service = _SupportedVoiceInputService(nativeStt: nativeStt);
    await service.initialize(forceLocalStt: true);
    await service.startListening();

    final errorCompleter = Completer<Object>();
    final subscription = service.transcriptEvents.listen(
      (_) {},
      onError: (Object error, StackTrace _) {
        if (!errorCompleter.isCompleted) {
          errorCompleter.complete(error);
        }
      },
    );

    nativeStt.emit(
      const NativeSttEvent(
        type: 'error',
        code: 'TEST_FAILURE',
        message: 'recognition failed',
      ),
    );

    final error = await errorCompleter.future.timeout(
      const Duration(seconds: 1),
    );
    check(error.toString()).contains('recognition failed');

    await subscription.cancel();
    await service.stopListening();
    await nativeStt.dispose();
  });

  test('hands native capture to response wait without a stop gap', () async {
    final nativeStt = _FakeNativeSttService();
    final service = _SupportedVoiceInputService(
      nativeStt: nativeStt,
      supportsNativeResponseWaitCapture: true,
    );
    await service.initialize(forceLocalStt: true);
    await service.startListening();

    check(await service.prepareResponseWaitHandoff()).isFalse();
    check(nativeStt.detachCalls).equals(1);
    check(nativeStt.stopCalls).equals(0);

    await service.stopListening();
    check(nativeStt.stopCalls).equals(1);
    await nativeStt.dispose();
  });

  test('stops detached native capture before starting server STT', () async {
    final nativeStt = _FakeNativeSttService();
    final recorder = _FakeServerVadRecorder();
    final service = _SupportedVoiceInputService(
      nativeStt: nativeStt,
      serverSpeech: () => OpenWebUiServerSpeech(_MockApiService()),
      serverVadRecorderFactory: () => recorder,
      supportsNativeResponseWaitCapture: true,
    );
    await service.initialize(forceLocalStt: true);
    await service.startListening();
    await service.prepareResponseWaitHandoff();

    service.updatePreference(SttPreference.serverOnly);
    await service.startListening();

    check(nativeStt.stopCalls).equals(1);
    check(service.isUsingNativeLocalStt).isFalse();
    await service.stopListening();
    await pumpEventQueue();
    check(recorder.calls).not((it) => it.contains('start-stream'));

    await service.dispose();
    await recorder.close();
    await nativeStt.dispose();
  });

  test(
    'server-only speech uses the device in a chat that cannot transcribe',
    () async {
      final nativeStt = _FakeNativeSttService();
      final service = _SupportedVoiceInputService(
        nativeStt: nativeStt,
        serverSpeech: () => null,
        supportsNativeResponseWaitCapture: true,
      );
      service.updatePreference(SttPreference.serverOnly);
      check(service.prefersServerOnly).isFalse();
      check(service.prefersDeviceOnly).isTrue();

      await service.initialize();
      await service.startListening();
      check(service.isUsingNativeLocalStt).isTrue();

      await service.stopListening();
      await service.dispose();
      await nativeStt.dispose();
    },
  );

  group('VoiceInputService server STT consumers', () {
    test('cancels a queued server recorder start after stop', () async {
      final recorder = _FakeServerVadRecorder();
      final service = _SupportedVoiceInputService(
        nativeStt: _FakeNativeSttService(),
        serverSpeech: () => OpenWebUiServerSpeech(_MockApiService()),
        serverVadRecorderFactory: () => recorder,
      );
      service.updatePreference(SttPreference.serverOnly);
      await service.initialize();

      await service.startListening();
      await service.stopListening();
      await pumpEventQueue();

      check(recorder.calls).not((it) => it.contains('start-stream'));
      await service.dispose();
      await recorder.close();
    });

    test('processes samples for a live-mode event-only consumer', () {
      check(
        VoiceInputService.shouldProcessServerSamplesForTesting(
          hasTextConsumer: false,
          hasTranscriptEventConsumer: true,
        ),
      ).isTrue();
    });

    test('processes samples for the normal text consumer', () {
      check(
        VoiceInputService.shouldProcessServerSamplesForTesting(
          hasTextConsumer: true,
          hasTranscriptEventConsumer: false,
        ),
      ).isTrue();
    });

    test('skips samples when every consumer has detached', () {
      check(
        VoiceInputService.shouldProcessServerSamplesForTesting(
          hasTextConsumer: false,
          hasTranscriptEventConsumer: false,
        ),
      ).isFalse();
    });
  });

  // Issue #822: the server answered with a transcript, but a stop tapped
  // while the request was in flight closed the streams it was coming back on.
  group('VoiceInputService stop while the server transcribes', () {
    late _FakeServerVadRecorder recorder;
    late _FakeVadHandler vad;
    late _MockApiService api;
    late VoiceInputService service;
    late Completer<Map<String, dynamic>> reply;
    final speech = List<double>.filled(1600, 0.1);

    setUpAll(() => registerFallbackValue(Uint8List(0)));

    setUp(() async {
      recorder = _FakeServerVadRecorder();
      vad = _FakeVadHandler();
      api = _MockApiService();
      reply = Completer<Map<String, dynamic>>();
      when(
        () => api.transcribeSpeech(
          audioBytes: any(named: 'audioBytes'),
          fileName: any(named: 'fileName'),
          mimeType: any(named: 'mimeType'),
          language: any(named: 'language'),
        ),
      ).thenAnswer((_) => reply.future);
      service = _SupportedVoiceInputService(
        nativeStt: _FakeNativeSttService(),
        serverSpeech: () => OpenWebUiServerSpeech(api),
        serverVadRecorderFactory: () => recorder,
        vadHandlerFactory: () => vad,
      );
      service.updatePreference(SttPreference.serverOnly);
      await service.initialize();
    });

    tearDown(() async {
      if (!reply.isCompleted) reply.complete(const {'text': ''});
      await service.dispose();
      await recorder.close();
    });

    test(
      'flushes captured audio before waiting for server transcription',
      () async {
        final captured = <int>[];
        var closed = 0;
        final stream = await service.startListening(
          recording: VoiceInputRecording(
            add: captured.addAll,
            close: () async {
              expect(recorder.calls, contains('stop'));
              closed++;
            },
          ),
        );
        final subscription = stream.listen((_) {});
        await pumpEventQueue();
        recorder.audio.add(Uint8List.fromList([1, 2, 3, 4]));
        await vad.heardAudio;
        vad.speaking = speech.toList();
        final stopped = service.stopListening();
        await pumpEventQueue();
        expect(captured, [1, 2, 3, 4]);
        expect(closed, 1);
        expect(reply.isCompleted, isFalse);
        reply.complete({'text': 'A synthetic transcription'});
        await stopped;
        await service.stopListening();
        expect(closed, 1);
        await subscription.cancel();
      },
    );

    test('keeps the transcript of the pause that ended speech', () async {
      final texts = <String>[];
      var done = false;
      (await service.startListening()).listen(
        texts.add,
        onDone: () => done = true,
      );
      await pumpEventQueue();
      check(recorder.calls).contains('start-stream');

      // The pause ends the utterance and sends it to the server.
      vad.endSpeech(speech);
      await pumpEventQueue();
      check(service.transcribing.value).isTrue();

      final stopped = service.stopListening();
      await pumpEventQueue();
      check(done).isFalse();

      reply.complete(const {'text': 'late words'});
      await stopped;
      check(texts).deepEquals(['late words']);
      check(done).isTrue();
    });

    test(
      'keeps the transcript when stop lands as the recorder stops',
      () async {
        final texts = <String>[];
        (await service.startListening()).listen(texts.add);
        await pumpEventQueue();

        // The pause's own stop is still shutting the microphone down.
        final recorderStop = Completer<void>();
        recorder.stopGate = recorderStop.future;
        vad.endSpeech(speech);
        await pumpEventQueue();
        check(recorder.calls).contains('stop');

        final stopped = service.stopListening();
        await pumpEventQueue();
        recorderStop.complete();
        await pumpEventQueue();
        reply.complete(const {'text': 'quick tap'});
        await stopped;

        check(texts).deepEquals(['quick tap']);
      },
    );

    test('leaves a listen started meanwhile to its own speech', () async {
      final firstTexts = <String>[];
      (await service.startListening()).listen(firstTexts.add);
      await pumpEventQueue();
      vad.endSpeech(speech);
      await pumpEventQueue();
      check(service.transcribing.value).isTrue();

      final secondTexts = <String>[];
      var secondDone = false;
      final started = service.startListening().then(
        (stream) =>
            stream.listen(secondTexts.add, onDone: () => secondDone = true),
      );
      await pumpEventQueue();
      reply.complete(const {'text': 'first take'});
      await started;
      await pumpEventQueue();

      check(firstTexts).deepEquals(['first take']);
      check(secondTexts).isEmpty();
      check(secondDone).isFalse();
      check(service.isListening).isTrue();
    });

    test('drops a start that a stop overtook while it waited', () async {
      (await service.startListening()).listen((_) {});
      await pumpEventQueue();
      vad.endSpeech(speech);
      await pumpEventQueue();

      // A start queues behind the transcription, then its owner leaves.
      final started = service.startListening();
      await pumpEventQueue();
      final stopped = service.stopListening();
      await pumpEventQueue();
      reply.complete(const {'text': 'first take'});
      final second = await started;
      await stopped;

      check(await second.isEmpty).isTrue();
      check(service.isListening).isFalse();
    });

    test('starts again after a stop cancelled a waiting start', () async {
      (await service.startListening()).listen((_) {});
      await pumpEventQueue();
      vad.endSpeech(speech);
      await pumpEventQueue();

      final cancelled = service.startListening();
      await pumpEventQueue();
      final stopped = service.stopListening();
      await pumpEventQueue();
      var secondDone = false;
      final restarted = service.startListening().then(
        (stream) => stream.listen((_) {}, onDone: () => secondDone = true),
      );
      await pumpEventQueue();
      reply.complete(const {'text': 'first take'});
      check(await (await cancelled).isEmpty).isTrue();
      await stopped;
      await restarted;
      await pumpEventQueue();

      check(secondDone).isFalse();
      check(service.isListening).isTrue();
    });

    test('drops a restart that a later stop overtook', () async {
      (await service.startListening()).listen((_) {});
      await pumpEventQueue();
      vad.endSpeech(speech);
      await pumpEventQueue();

      final cancelled = service.startListening();
      await pumpEventQueue();
      final firstStop = service.stopListening();
      await pumpEventQueue();
      final restarted = service.startListening();
      await pumpEventQueue();
      // The screen that asked for the restart leaves before it opens.
      final secondStop = service.stopListening();
      await pumpEventQueue();
      reply.complete(const {'text': 'first take'});
      await cancelled;
      await firstStop;
      final stream = await restarted;
      await secondStop;

      check(await stream.isEmpty).isTrue();
      check(service.isListening).isFalse();
    });

    test('keeps a listen started after a stop that is waiting', () async {
      (await service.startListening()).listen((_) {});
      await pumpEventQueue();
      vad.endSpeech(speech);
      await pumpEventQueue();

      final stopped = service.stopListening();
      await pumpEventQueue();
      var secondDone = false;
      final started = service.startListening().then(
        (stream) => stream.listen((_) {}, onDone: () => secondDone = true),
      );
      await pumpEventQueue();
      reply.complete(const {'text': 'first take'});
      await stopped;
      await started;
      await pumpEventQueue();

      check(secondDone).isFalse();
      check(service.isListening).isTrue();
    });

    test('ends on an upload timeout and frees a waiting start', () async {
      final errors = <Object>[];
      var firstDone = false;
      (await service.startListening()).listen(
        (_) {},
        onError: errors.add,
        onDone: () => firstDone = true,
      );
      await pumpEventQueue();
      vad.endSpeech(speech);
      await pumpEventQueue();

      var secondDone = false;
      final started = service.startListening().then(
        (stream) => stream.listen((_) {}, onDone: () => secondDone = true),
      );
      await pumpEventQueue();
      reply.completeError(
        DioException(
          requestOptions: RequestOptions(path: '/api/v1/audio/transcriptions'),
          type: DioExceptionType.sendTimeout,
        ),
      );
      await started;
      await pumpEventQueue();

      // The failure reaches the listener, which ends "Transcribing…".
      check(errors).length.equals(1);
      check(firstDone).isTrue();
      check(service.transcribing.value).isFalse();
      check(secondDone).isFalse();
      check(service.isListening).isTrue();
    });

    test('still restarts a listen that is running', () async {
      var firstDone = false;
      (await service.startListening()).listen(
        (_) {},
        onDone: () => firstDone = true,
      );
      await pumpEventQueue();

      // The start's own stop of the running listen must not cancel it.
      var secondDone = false;
      (await service.startListening()).listen(
        (_) {},
        onDone: () => secondDone = true,
      );
      await pumpEventQueue();

      check(firstDone).isTrue();
      check(secondDone).isFalse();
      check(service.isListening).isTrue();
    });

    test('still hands a held call recorder over to the device', () async {
      (await service.beginListeningEvents()).listen((_) {});
      await pumpEventQueue();
      vad.endSpeech(speech);
      await pumpEventQueue();
      reply.complete(const {'text': 'over to you'});
      await pumpEventQueue();
      check(service.isHoldingServerRecorderForResponse).isTrue();

      // Releasing the held recorder is the start's own stop.
      service.updatePreference(SttPreference.deviceOnly);
      await service.startListening();

      check(service.isHoldingServerRecorderForResponse).isFalse();
      check(service.isUsingNativeLocalStt).isTrue();
    });

    test('ends a call without waiting for a transcript it left', () async {
      final events = await service.beginListeningEvents();
      final subscription = events.listen((_) {});
      await pumpEventQueue();
      vad.endSpeech(speech);
      await pumpEventQueue();
      check(service.isHoldingServerRecorderForResponse).isTrue();

      // Hanging up detaches from the transcript before stopping.
      await subscription.cancel();
      var stopped = false;
      unawaited(service.stopListening().then((_) => stopped = true));
      await pumpEventQueue();

      check(stopped).isTrue();
      check(service.isHoldingServerRecorderForResponse).isFalse();
    });
  });

  // Issues #752 and #853: stopping, the recording cap and the wait for
  // speech must never drop what the user is still saying.
  group('VoiceInputService keeps speech in progress', () {
    late _FakeServerVadRecorder recorder;
    late _FakeVadHandler vad;
    late _MockApiService api;
    late List<Uint8List> uploads;
    VoiceInputService? service;
    final firstWords = List<double>.filled(1600, 0.25);
    final moreWords = List<double>.filled(3200, 0.5);

    setUpAll(() => registerFallbackValue(Uint8List(0)));

    setUp(() {
      recorder = _FakeServerVadRecorder();
      vad = _FakeVadHandler();
      api = _MockApiService();
      uploads = <Uint8List>[];
      when(
        () => api.transcribeSpeech(
          audioBytes: any(named: 'audioBytes'),
          fileName: any(named: 'fileName'),
          mimeType: any(named: 'mimeType'),
          language: any(named: 'language'),
        ),
      ).thenAnswer((invocation) async {
        uploads.add(invocation.namedArguments[#audioBytes] as Uint8List);
        return const {'text': 'still talking'};
      });
    });

    tearDown(() async {
      await service?.dispose();
      service = null;
      await recorder.close();
    });

    Future<VoiceInputService> start({
      Ref? ref,
      Duration noSpeech = const Duration(seconds: 90),
      Duration cap = const Duration(minutes: 10),
    }) async {
      final started = _SupportedVoiceInputService(
        ref: ref,
        nativeStt: _FakeNativeSttService(),
        serverSpeech: () => OpenWebUiServerSpeech(api),
        serverVadRecorderFactory: () => recorder,
        vadHandlerFactory: () => vad,
        serverNoSpeechTimeout: noSpeech,
        serverRecordingMaxDuration: cap,
      )..updatePreference(SttPreference.serverOnly);
      await started.initialize();
      return service = started;
    }

    /// The samples of an uploaded 16-bit mono WAV, after its 44-byte header.
    List<int> samplesOf(Uint8List wav) =>
        Int16List.fromList(Int16List.sublistView(wav, 44)).toList();

    int pcm(double sample) => (sample * 32767).round();

    test('transcribes what is being said when stop is tapped', () async {
      final voice = await start();
      final texts = <String>[];
      var done = false;
      (await voice.startListening()).listen(
        texts.add,
        onDone: () => done = true,
      );
      await pumpEventQueue();
      check(recorder.calls).contains('start-stream');

      // No pause has ended the speech yet.
      vad.speaking = List.of(moreWords);
      await voice.stopListening();

      check(uploads).length.equals(1);
      check(samplesOf(uploads.single))
          .deepEquals([for (final sample in moreWords) pcm(sample)]);
      check(texts).deepEquals(['still talking']);
      check(done).isTrue();
    });

    test('scores the audio it was already handed before stopping', () async {
      final voice = await start();
      (await voice.startListening()).listen((_) {});
      await pumpEventQueue();

      vad.speaking = <double>[];
      final words = Int16List.fromList([for (var i = 0; i < 1600; i++) i]);
      recorder.audio.add(Uint8List.sublistView(words));
      // The VAD has the audio and is part-way through scoring it.
      await vad.heardAudio;
      await voice.stopListening();

      check(samplesOf(uploads.single))
          .deepEquals([for (final sample in words) pcm(sample / 32768)]);
    });

    test('sends the words after a pause along with those before', () async {
      final voice = await start();
      (await voice.startListening()).listen((_) {});
      await pumpEventQueue();

      // A pause ends the first words while more are already coming in.
      vad.speaking = List.of(moreWords);
      vad.endSpeech(firstWords);
      await pumpEventQueue();

      check(uploads).length.equals(1);
      check(samplesOf(uploads.single)).deepEquals([
        for (final sample in [...firstWords, ...moreWords]) pcm(sample),
      ]);
    });

    test('transcribes what was said when the recording cap ends it', () async {
      final voice = await start(cap: const Duration(milliseconds: 100));
      final texts = <String>[];
      (await voice.startListening()).listen(texts.add);
      await pumpEventQueue();
      vad.speaking = List.of(moreWords);

      await Future<void>.delayed(const Duration(milliseconds: 200));
      await pumpEventQueue();

      check(voice.isListening).isFalse();
      check(samplesOf(uploads.single)).length.equals(moreWords.length);
      check(texts).deepEquals(['still talking']);
    });

    test('a call keeps its recorder when the cap ends a turn', () async {
      final voice = await start(cap: const Duration(milliseconds: 100));
      final events = <VoiceTranscriptEvent>[];
      (await voice.beginListeningEvents()).listen(events.add);
      await pumpEventQueue();
      vad.speaking = List.of(moreWords);

      await Future<void>.delayed(const Duration(milliseconds: 200));
      await pumpEventQueue();

      check(events.map((event) => (event.text, event.isFinal)))
          .deepEquals([('still talking', true)]);
      check(voice.isHoldingServerRecorderForResponse).isTrue();
      check(recorder.calls).not((calls) => calls.contains('stop'));
    });

    test('waits for speech from the last frame scored as speech', () async {
      final voice = await start(noSpeech: const Duration(milliseconds: 300));
      var done = false;
      (await voice.startListening()).listen((_) {}, onDone: () => done = true);
      await pumpEventQueue();

      // Quiet speech scores above the 0.35 that keeps speech going but
      // below the 0.6 that starts it.
      for (var i = 0; i < 12; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        vad.frame(isSpeech: 0.4);
      }
      check(voice.isListening).isTrue();

      // Frames scored as silence do not hold it open.
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        vad.frame(isSpeech: 0.3);
      }
      await pumpEventQueue();

      check(voice.isListening).isFalse();
      check(done).isTrue();
      check(uploads).isEmpty();
    });

    test('keeps half a second after speech at a 4 s pause setting', () async {
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWith(
            () => _VoiceLocaleSettingsNotifier(
              const AppSettings(voiceSilenceDuration: 4000),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final voiceProvider = Provider<Future<VoiceInputService>>(
        (ref) => start(ref: ref),
      );
      final voice = await container.read(voiceProvider);
      (await voice.startListening()).listen((_) {});
      await pumpEventQueue();

      check(vad.startArgs).isNotNull()
        ..has((args) => args[#redemptionFrames], 'redemptionFrames').equals(125)
        ..has(
          (args) => args[#endSpeechPadFrames],
          'endSpeechPadFrames',
        ).equals(16)
        ..has(
          (args) => args[#submitUserSpeechOnPause],
          'submitUserSpeechOnPause',
        ).equals(true);
    });
  });

  group('ServerVadRecorderSession', () {
    test(
      'rejects denied permission without connecting VAD or recording',
      () async {
        final recorder = _FakeServerVadRecorder(permissionGranted: false);
        final session = ServerVadRecorderSession(recorder);
        var connected = false;

        await check(
          session.start(
            config: const AudioCaptureConfig(
              profile: AudioCaptureProfile.dictation,
            ),
            iosAudioSessionManagedExternally: false,
            connectVad: (_) async => connected = true,
            onRecorderError: (_, _) {},
          ),
        ).throws<StateError>();

        check(connected).isFalse();
        check(recorder.calls).deepEquals(['permission', 'dispose']);
      },
    );

    test('connects VAD before starting externally managed iOS audio', () async {
      final recorder = _FakeServerVadRecorder();
      final session = ServerVadRecorderSession(recorder);
      final received = <Uint8List>[];
      StreamSubscription<Uint8List>? vadSubscription;

      await session.start(
        config: const AudioCaptureConfig(
          profile: AudioCaptureProfile.dictation,
        ),
        iosAudioSessionManagedExternally: true,
        connectVad: (audioStream) async {
          recorder.calls.add('vad-ready');
          vadSubscription = audioStream.listen(received.add);
        },
        onRecorderError: (_, _) {},
      );

      check(recorder.calls).deepEquals([
        'permission',
        'manage-ios:false',
        'vad-ready',
        'start-stream',
      ]);
      recorder.audio.add(Uint8List.fromList([1, 2]));
      await Future<void>.delayed(Duration.zero);
      check(received.single).deepEquals(Uint8List.fromList([1, 2]));

      await session.stopForwarding();
      await vadSubscription?.cancel();
      await session.stopRecorder();
      await session.dispose();
      check(recorder.calls).deepEquals([
        'permission',
        'manage-ios:false',
        'vad-ready',
        'start-stream',
        'stop',
        'dispose',
      ]);
      await recorder.close();
    });

    test('holds the recorder while discarding response-wait audio', () async {
      final recorder = _FakeServerVadRecorder();
      final session = ServerVadRecorderSession(recorder);
      final received = <Uint8List>[];
      StreamSubscription<Uint8List>? vadSubscription;

      await session.start(
        config: const AudioCaptureConfig(
          profile: AudioCaptureProfile.dictation,
        ),
        iosAudioSessionManagedExternally: true,
        connectVad: (audioStream) async {
          vadSubscription = audioStream.listen(received.add);
        },
        onRecorderError: (_, _) {},
      );
      recorder.audio.add(Uint8List.fromList([1]));
      await Future<void>.delayed(Duration.zero);

      check(await session.holdForResponse()).isTrue();
      recorder.audio.add(Uint8List.fromList([2]));
      await Future<void>.delayed(Duration.zero);
      check(received).has((it) => it.length, 'length').equals(1);
      check(session.isHoldingForResponse).isTrue();
      check(recorder.calls).not((it) => it.contains('stop'));

      final resumed = <Uint8List>[];
      StreamSubscription<Uint8List>? resumedVadSubscription;
      check(
        await session.resumeForwarding(
          connectVad: (audioStream) async {
            resumedVadSubscription = audioStream.listen(resumed.add);
          },
        ),
      ).isTrue();
      recorder.audio.add(Uint8List.fromList([3]));
      await Future<void>.delayed(Duration.zero);
      check(resumed.single).deepEquals(Uint8List.fromList([3]));
      check(recorder.calls.where((call) => call == 'start-stream').length)
          .equals(1);

      await session.stopForwarding();
      await vadSubscription?.cancel();
      await resumedVadSubscription?.cancel();
      await session.stopRecorder();
      await session.dispose();
      check(session.isHoldingForResponse).isFalse();
      check(recorder.calls.where((call) => call == 'stop').length).equals(1);
      await recorder.close();
    });

    test(
      'reports a recorder error while response audio is discarded',
      () async {
        final recorder = _FakeServerVadRecorder();
        final session = ServerVadRecorderSession(recorder);
        final reportedError = Completer<Object>();
        StreamSubscription<Uint8List>? vadSubscription;

        await session.start(
          config: const AudioCaptureConfig(
            profile: AudioCaptureProfile.dictation,
          ),
          iosAudioSessionManagedExternally: true,
          connectVad: (audioStream) async {
            vadSubscription = audioStream.listen((_) {});
          },
          onRecorderError: (error, _) => reportedError.complete(error),
        );
        check(await session.holdForResponse()).isTrue();

        recorder.audio.addError(StateError('microphone stream failed'));
        final error = await reportedError.future.timeout(
          const Duration(seconds: 1),
        );
        check(error.toString()).contains('microphone stream failed');

        await session.stopForwarding();
        await vadSubscription?.cancel();
        await session.stopRecorder();
        await session.dispose();
        check(recorder.calls.where((call) => call == 'stop').length).equals(1);
        await recorder.close();
      },
    );

    test(
      'leaves standalone iOS audio-session management at Record defaults',
      () async {
        final recorder = _FakeServerVadRecorder();
        final session = ServerVadRecorderSession(recorder);
        StreamSubscription<Uint8List>? vadSubscription;

        await session.start(
          config: const AudioCaptureConfig(
            profile: AudioCaptureProfile.dictation,
          ),
          iosAudioSessionManagedExternally: false,
          connectVad: (audioStream) async {
            vadSubscription = audioStream.listen((_) {});
          },
          onRecorderError: (_, _) {},
        );

        check(recorder.calls).deepEquals(['permission', 'start-stream']);
        await session.stopForwarding();
        await vadSubscription?.cancel();
        await session.stopRecorder();
        await session.dispose();
        await recorder.close();
      },
    );

    test('preserves start failure when cleanup also fails', () async {
      final recorder = _FakeServerVadRecorder(
        startError: StateError('start failed'),
        disposeError: StateError('dispose failed'),
      );
      final session = ServerVadRecorderSession(recorder);
      StreamSubscription<Uint8List>? vadSubscription;

      final future = session.start(
        config: const AudioCaptureConfig(
          profile: AudioCaptureProfile.dictation,
        ),
        iosAudioSessionManagedExternally: false,
        connectVad: (audioStream) async {
          vadSubscription = audioStream.listen((_) {});
        },
        onRecorderError: (_, _) {},
      );

      await expectLater(
        future,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'start failed',
          ),
        ),
      );
      await vadSubscription?.cancel();
      check(recorder.calls)
          .deepEquals(['permission', 'start-stream', 'dispose']);
      await recorder.close();
    });

    test(
      'does not start Record after a stop races VAD initialization',
      () async {
        final recorder = _FakeServerVadRecorder();
        final session = ServerVadRecorderSession(recorder);
        final vadReady = Completer<void>();
        StreamSubscription<Uint8List>? vadSubscription;

        final startFuture = session.start(
          config: const AudioCaptureConfig(
            profile: AudioCaptureProfile.dictation,
          ),
          iosAudioSessionManagedExternally: false,
          connectVad: (audioStream) async {
            vadSubscription = audioStream.listen((_) {});
            await vadReady.future;
          },
          onRecorderError: (_, _) {},
        );
        await Future<void>.delayed(Duration.zero);
        await session.stopForwarding();
        vadReady.complete();

        await expectLater(startFuture, throwsStateError);
        await vadSubscription?.cancel();
        check(recorder.calls).deepEquals(['permission', 'dispose']);
        await recorder.close();
      },
    );

    test('reports errors from an active Record stream', () async {
      final recorder = _FakeServerVadRecorder();
      final session = ServerVadRecorderSession(recorder);
      final reportedError = Completer<Object>();
      StreamSubscription<Uint8List>? vadSubscription;

      await session.start(
        config: const AudioCaptureConfig(
          profile: AudioCaptureProfile.dictation,
        ),
        iosAudioSessionManagedExternally: false,
        connectVad: (audioStream) async {
          vadSubscription = audioStream.listen((_) {});
        },
        onRecorderError: (error, _) => reportedError.complete(error),
      );
      recorder.audio.addError(StateError('stream failed'));

      final error = await reportedError.future;
      check(error)
          .isA<StateError>()
          .has((it) => it.message, 'message')
          .equals('stream failed');
      await session.stopForwarding();
      await vadSubscription?.cancel();
      await session.stopRecorder();
      await session.dispose();
      await recorder.close();
    });
  });

  group('VoiceInputService.shouldSettleNativeDictation', () {
    test('settles cumulative native dictation on final result', () {
      check(
        VoiceInputService.shouldSettleNativeDictationForTesting(
          isFinal: true,
          nativeAccumulateResults: true,
          usingServerStt: false,
        ),
      ).isTrue();
    });

    test('keeps voice-call native STT continuous after final chunks', () {
      check(
        VoiceInputService.shouldSettleNativeDictationForTesting(
          isFinal: true,
          nativeAccumulateResults: false,
          usingServerStt: false,
        ),
      ).isFalse();
    });

    test('does not settle server STT through the native final path', () {
      check(
        VoiceInputService.shouldSettleNativeDictationForTesting(
          isFinal: true,
          nativeAccumulateResults: true,
          usingServerStt: true,
        ),
      ).isFalse();
    });
  });

  group('localVoiceRecognitionAvailableProvider', () {
    test('forces a local STT probe even in server-only mode', () async {
      final fakeService = _FakeVoiceInputService(
        hasLocalSttValue: false,
        onDeviceSupportValue: true,
      );
      final container = ProviderContainer(
        overrides: [voiceInputServiceProvider.overrideWithValue(fakeService)],
      );
      addTearDown(container.dispose);

      final available = await container.read(
        localVoiceRecognitionAvailableProvider.future,
      );

      check(available).isTrue();
      check(fakeService.initializeForceLocalSttArgs).deepEquals([true]);
    });

    test('reprobes when the configured recognition locale changes', () async {
      final fakeService = _FakeVoiceInputService(
        hasLocalSttValue: true,
        onDeviceSupportValue: true,
      );
      final container = ProviderContainer(
        overrides: [
          voiceInputServiceProvider.overrideWithValue(fakeService),
          appSettingsProvider.overrideWith(
            () => _VoiceLocaleSettingsNotifier(const AppSettings()),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(localVoiceRecognitionAvailableProvider.future);
      await container
          .read(appSettingsProvider.notifier)
          .setVoiceLocaleId('pl-PL');
      await container.read(localVoiceRecognitionAvailableProvider.future);

      check(fakeService.localeIds).deepEquals([null, 'pl-PL']);
      check(fakeService.initializeForceLocalSttArgs).deepEquals([true, true]);
    });
  });
}

class _VoiceLocaleSettingsNotifier extends AppSettingsNotifier {
  _VoiceLocaleSettingsNotifier(this._initial);

  final AppSettings _initial;

  @override
  AppSettings build() => _initial;

  @override
  Future<void> setVoiceLocaleId(String? localeId) async {
    state = state.copyWith(
      voiceLocaleId: SettingsService.normalizeVoiceLocaleId(localeId),
    );
  }
}

class _FakeVoiceInputService extends VoiceInputService {
  _FakeVoiceInputService({
    required this.hasLocalSttValue,
    required this.onDeviceSupportValue,
  });

  final bool hasLocalSttValue;
  final bool onDeviceSupportValue;
  final List<bool> initializeForceLocalSttArgs = <bool>[];
  final List<String?> localeIds = <String?>[];

  @override
  void setLocale(String? localeId) {
    localeIds.add(SettingsService.normalizeVoiceLocaleId(localeId));
  }

  @override
  bool get hasLocalStt => hasLocalSttValue;

  @override
  Future<bool> initialize({bool forceLocalStt = false}) async {
    initializeForceLocalSttArgs.add(forceLocalStt);
    return true;
  }

  @override
  Future<bool> checkOnDeviceSupport() async => onDeviceSupportValue;

  @override
  Future<void> dispose() async {}
}

class _MockPermissionHandlerPlatform extends Mock
    with MockPlatformInterfaceMixin
    implements PermissionHandlerPlatform {}

class _MockApiService extends Mock implements ApiService {}

class _FakeServerVadRecorder implements AudioCapturePort {
  _FakeServerVadRecorder({
    this.permissionGranted = true,
    this.startError,
    this.disposeError,
  });

  final bool permissionGranted;
  final Object? startError;
  final Object? disposeError;
  final List<String> calls = <String>[];
  final StreamController<Uint8List> audio =
      StreamController<Uint8List>.broadcast();

  /// Holds [stop] open until it completes, like a slow platform recorder.
  Future<void>? stopGate;

  Future<void> close() => audio.close();

  @override
  Future<bool> hasPermission() async {
    calls.add('permission');
    return permissionGranted;
  }

  @override
  Future<void> manageIosAudioSession(bool manage) async {
    calls.add('manage-ios:$manage');
  }

  @override
  Future<Stream<Uint8List>> startStream(AudioCaptureConfig config) async {
    calls.add('start-stream');
    if (startError case final error?) throw error;
    return audio.stream;
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    await stopGate;
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    if (disposeError case final error?) throw error;
  }
}

/// VAD stand-in. Like the real handler it owns the audio stream it is given;
/// without a listener, closing that stream never completes and stops hang.
class _FakeVadHandler extends Fake implements VadHandler {
  final _speechEnd = StreamController<List<double>>.broadcast();
  final _frames =
      StreamController<
        ({double isSpeech, double notSpeech, List<double> frame})
      >.broadcast();
  final _errors = StreamController<String>.broadcast();
  final _heard = Completer<void>();
  StreamSubscription<Uint8List>? _audio;

  /// What the service passed to `startListening`.
  Map<Symbol, dynamic>? startArgs;

  /// Speech under way and not yet ended by a pause. Audio the VAD scores
  /// joins it, and [stopListening] hands it over, as the real handler does
  /// with `submitUserSpeechOnPause`.
  List<double>? speaking;

  /// Completes when the first audio reaches the VAD.
  Future<void> get heardAudio => _heard.future;

  void endSpeech(List<double> samples) => _speechEnd.add(samples);

  void frame({required double isSpeech}) => _frames.add((
    isSpeech: isSpeech,
    notSpeech: 1 - isSpeech,
    frame: const <double>[],
  ));

  /// Scores [bytes] a frame at a time, yielding between frames like the real
  /// VAD's model loop.
  Future<void> _score(Uint8List bytes) async {
    if (!_heard.isCompleted) _heard.complete();
    final pcm = Int16List.sublistView(bytes);
    for (var start = 0; start < pcm.length; start += 64) {
      await Future<void>.value();
      speaking?.addAll([
        for (final sample in pcm.skip(start).take(64)) sample / 32768,
      ]);
    }
  }

  @override
  Stream<List<double>> get onSpeechEnd => _speechEnd.stream;

  @override
  Stream<({double isSpeech, double notSpeech, List<double> frame})>
  get onFrameProcessed => _frames.stream;

  @override
  Stream<String> get onError => _errors.stream;

  @override
  Future<void> stopListening() async {
    final inProgress = speaking;
    speaking = null;
    if (inProgress != null && inProgress.isNotEmpty) {
      _speechEnd.add(inProgress);
    }
    await _audio?.cancel();
    _audio = null;
  }

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #startListening) {
      startArgs = invocation.namedArguments;
      final audio = invocation.namedArguments[#audioStream];
      _audio = (audio as Stream<Uint8List>?)?.listen(_score);
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

class _SupportedVoiceInputService extends VoiceInputService {
  _SupportedVoiceInputService({
    required super.nativeStt,
    super.ref,
    super.serverSpeech,
    super.serverVadRecorderFactory,
    super.vadHandlerFactory,
    super.serverNoSpeechTimeout,
    super.serverRecordingMaxDuration,
    this.deviceLocaleTag = 'en-US',
    this.usesAutomaticNativeLanguage = true,
    this.supportsNativeResponseWaitCapture = false,
  });

  @override
  final String deviceLocaleTag;

  @override
  final bool usesAutomaticNativeLanguage;

  @override
  final bool supportsNativeResponseWaitCapture;

  @override
  bool get isSupportedPlatform => true;
}

class _FakeNativeSttService extends NativeSttService {
  _FakeNativeSttService({this.systemLocaleId = 'en-US'});

  final String systemLocaleId;
  final StreamController<NativeSttEvent> _events =
      StreamController<NativeSttEvent>.broadcast();
  String? availabilityLocaleId;
  final List<String?> availabilityLocaleIds = <String?>[];
  String? startLocaleId;
  bool emitAudioRequested = false;
  Future<void> Function()? onStop;
  int detachCalls = 0;
  int stopCalls = 0;

  void emit(NativeSttEvent event) => _events.add(event);

  Future<void> dispose() => _events.close();

  @override
  bool get isSupportedPlatform => true;

  @override
  Future<NativeSttLocales> getLocales({String? deviceLocaleId}) async {
    return NativeSttLocales(
      systemLocaleId: systemLocaleId,
      locales: const [
        NativeSttLocale(localeId: 'en-US', name: 'English'),
        NativeSttLocale(localeId: 'pl-PL', name: 'Polish'),
      ],
    );
  }

  @override
  Future<NativeSttAvailability> checkAvailability({
    String? localeId,
    bool allowOnlineFallback = true,
  }) async {
    availabilityLocaleId = localeId;
    availabilityLocaleIds.add(localeId);
    return const NativeSttAvailability(
      available: true,
      engine: 'automatic-test',
    );
  }

  @override
  Future<Stream<NativeSttEvent>> startListening({
    String? localeId,
    bool preserveAudioSession = false,
    bool emitPartialResults = true,
    bool accumulateResults = true,
    bool allowOnlineFallback = true,
    bool emitAudio = false,
  }) async {
    startLocaleId = localeId;
    emitAudioRequested = emitAudio;
    return _events.stream;
  }

  @override
  Future<void> detachListeningEvents() async {
    detachCalls += 1;
  }

  @override
  Future<void> stopListening() async {
    stopCalls += 1;
    await onStop?.call();
  }
}
