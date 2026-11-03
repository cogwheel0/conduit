import 'dart:async';

import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/services/text_to_speech_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';

void main() {
  late _Speech speech;
  late ProviderContainer container;
  late TextToSpeechController controller;

  setUp(() {
    speech = _Speech();
    container = ProviderContainer(
      overrides: [
        appSettingsProvider.overrideWithValue(const AppSettings()),
        textToSpeechServiceProvider.overrideWithValue(speech),
      ],
    );
    controller = container.read(textToSpeechControllerProvider.notifier);
  });
  tearDown(() => container.dispose());

  Future<void> play() => controller.toggleForMessage(
    messageId: 'garden-guide',
    text: 'A blue flower grows near the gate.',
  );

  test('elapsed time excludes loading and pauses, resets on retry, and stops on disposal', () {
    fakeAsync((time) {
      final speech = _Speech();
      final ready = Completer<bool>();
      speech.initialization = ready.future;
      final local = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWithValue(const AppSettings()),
          textToSpeechServiceProvider.overrideWithValue(speech),
        ],
      );
      final control = local.read(textToSpeechControllerProvider.notifier);
      TextToSpeechState state() => local.read(textToSpeechControllerProvider);
      unawaited(
        control.toggleForMessage(
          messageId: 'paper',
          text: 'Fold a blue square.',
        ),
      );
      time.flushMicrotasks();
      time.elapse(const Duration(minutes: 1));
      expect(state().elapsed, Duration.zero);
      ready.complete(true);
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 65));
      expect(state().elapsed.inSeconds, 65);
      // Repeated start events during one utterance do not reset its clock.
      speech.onStart!();
      unawaited(control.pause());
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 10));
      expect(state().elapsed.inSeconds, 65);
      unawaited(control.resume());
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 2));
      expect(state().elapsed.inSeconds, 67);
      speech.onError!('Synthetic playback failure');
      time.elapse(const Duration(seconds: 10));
      expect(state().elapsed.inSeconds, 67);
      unawaited(control.retry());
      time.flushMicrotasks();
      expect(state().elapsed, Duration.zero);
      time.elapse(const Duration(seconds: 2));
      expect(state().elapsed.inSeconds, 2);
      local.dispose();
      time.flushMicrotasks();
      expect(time.periodicTimerCount, 0);
    });
  });

  test('an interrupted message keeps its identity for recovery', () async {
    await play();
    speech.onError!('Synthetic audio interruption');
    final state = container.read(textToSpeechControllerProvider);
    expect(state.status, TtsPlaybackStatus.error);
    expect(state.activeMessageId, 'garden-guide');
  });

  test('a failed pause becomes a recoverable playback error', () async {
    await play();
    speech.failPause = true;
    await controller.pause();
    final state = container.read(textToSpeechControllerProvider);
    expect(state.status, TtsPlaybackStatus.error);
    expect(state.activeMessageId, 'garden-guide');
  });

  test('a pause error event remains recoverable during a seek', () async {
    speech.seekable = true;
    await play();
    final pending = Completer<Duration?>();
    speech.seekResult = pending.future;
    final seek = controller.skip(const Duration(seconds: 15));
    speech.pauseErrorEvent = true;
    await controller.pause();
    pending.complete(null);
    await seek;
    final state = container.read(textToSpeechControllerProvider);
    expect(state.status, TtsPlaybackStatus.error);
    expect(state.activeMessageId, 'garden-guide');
    expect(state.errorMessage, 'Synthetic pause failure');
  });

  test('initialization errors keep the message available for retry', () async {
    final errors = <TextToSpeechState>[];
    final sub = container.listen(textToSpeechControllerProvider, (_, next) {
      if (next.status == TtsPlaybackStatus.error) errors.add(next);
    });
    addTearDown(sub.close);
    speech.initialization = Future.error(
      StateError('Synthetic initialization failure'),
    );
    await play();
    expect(errors, isNotEmpty);
    expect(
      errors.every((state) => state.activeMessageId == 'garden-guide'),
      isTrue,
    );
    speech.initialization = null;
    await controller.retry();
    expect(speech.spoken, ['A blue flower grows near the gate.']);
  });

  test('stop cancels a request still initializing', () async {
    final initialization = Completer<bool>();
    speech.initialization = initialization.future;
    final playback = play();
    await controller.stop();
    initialization.complete(true);
    await playback;
    expect(speech.spoken, isEmpty);
    expect(
      container.read(textToSpeechControllerProvider).status,
      TtsPlaybackStatus.idle,
    );
  });

  test('retry replays the interrupted request', () async {
    await play();
    speech.onError!('Synthetic audio interruption');
    await controller.retry();
    expect(speech.spoken, [
      'A blue flower grows near the gate.',
      'A blue flower grows near the gate.',
    ]);
    expect(
      container.read(textToSpeechControllerProvider).status,
      TtsPlaybackStatus.speaking,
    );
    expect(container.read(textToSpeechControllerProvider).errorMessage, isNull);
  });

  test(
    'completion during initialization cannot erase the next retry',
    () async {
      await play();
      final ready = Completer<bool>();
      speech.initialization = ready.future;
      final next = controller.toggleForMessage(
        messageId: 'paper',
        text: 'Fold a square.',
      );
      await pumpEventQueue();
      speech.onComplete!();
      ready.complete(true);
      await next;
      speech.onError!('Synthetic playback interruption');
      await controller.retry();
      expect(
        speech.spoken.where((text) => text == 'Fold a square.'),
        hasLength(2),
      );
    },
  );

  test('stop forgets an interrupted request', () async {
    await play();
    speech.onError!('Synthetic audio interruption');
    await controller.stop();
    await controller.retry();
    expect(speech.spoken, hasLength(1));
    expect(
      container.read(textToSpeechControllerProvider).activeMessageId,
      isNull,
    );
  });

  for (final pauseWhileSeeking in [false, true]) {
    test('a seek ignores its internal pause and preserves user pause intent '
        '(user pause: $pauseWhileSeeking)', () async {
      speech.seekable = true;
      await play();
      final pending = Completer<Duration?>();
      speech.seekResult = pending.future;
      final seek = controller.skip(const Duration(seconds: 15));
      speech.onPause!();
      expect(
        container.read(textToSpeechControllerProvider).status,
        TtsPlaybackStatus.speaking,
      );
      if (pauseWhileSeeking) await controller.pause();
      pending.complete(const Duration(seconds: 15));
      await seek;
      expect(
        container.read(textToSpeechControllerProvider).status,
        pauseWhileSeeking
            ? TtsPlaybackStatus.paused
            : TtsPlaybackStatus.speaking,
      );
    });
  }

  test('a cancelled paused seek refreshes control availability', () async {
    speech.seekable = true;
    await play();
    await controller.pause();
    final pending = Completer<Duration?>();
    speech.seekResult = pending.future;
    final seek = controller.skip(const Duration(seconds: 15));
    speech.seekable = false;
    pending.complete(null);
    await seek;
    final state = container.read(textToSpeechControllerProvider);
    expect(state.canSeek, isFalse);
    expect(state.seeking, isFalse);
    expect(state.status, TtsPlaybackStatus.paused);
  });

  test('a stopped seek cannot disable or retime a newer reply', () async {
    speech.seekable = true;
    await play();
    final pending = Completer<Duration?>();
    speech.seekResult = pending.future;
    final seek = controller.skip(const Duration(seconds: 15));
    await Future<void>.delayed(Duration.zero);
    expect(container.read(textToSpeechControllerProvider).seeking, isTrue);
    await controller.stop();
    await controller.toggleForMessage(
      messageId: 'second',
      text: 'A blue paper circle.',
    );
    expect(container.read(textToSpeechControllerProvider).seeking, isFalse);
    pending.complete(const Duration(seconds: 15));
    await seek;
    final state = container.read(textToSpeechControllerProvider);
    expect(state.activeMessageId, 'second');
    expect(state.elapsed, lessThan(const Duration(seconds: 15)));
    expect(state.seeking, isFalse);
  });

  for (final resume in [false, true]) {
    test(
      'a delayed ${resume ? 'resume' : 'pause'} error leaves newer playback alone',
      () async {
        await play();
        if (resume) await controller.pause();
        final result = Completer<void>();
        if (resume) {
          speech.resumeResult = result.future;
        } else {
          speech.pauseResult = result.future;
        }
        final previous = resume ? controller.resume() : controller.pause();
        await controller.toggleForMessage(
          messageId: 'paper-crane',
          text: 'Fold the green paper along the diagonal.',
        );
        result.completeError(StateError('Synthetic delayed playback failure'));
        await previous;
        final state = container.read(textToSpeechControllerProvider);
        expect(state.activeMessageId, 'paper-crane');
        expect(state.status, TtsPlaybackStatus.speaking);
        expect(state.errorMessage, isNull);
      },
    );
  }
}

class _Speech extends Fake implements TextToSpeechService {
  @override
  bool get canSeek => seekable;
  bool seekable = false;
  Future<Duration?>? seekResult;
  @override
  Future<Duration?> seekRelative(Duration offset) async => await seekResult;
  @override
  Duration? get playbackPosition => null;
  @override
  Duration? get playbackDuration => null;
  final spoken = <String>[];
  bool failPause = false;
  bool pauseErrorEvent = false;
  Future<bool>? initialization;
  Future<void>? pauseResult;
  Future<void>? resumeResult;
  VoidCallback? onStart;
  VoidCallback? onComplete;
  VoidCallback? onCancel;
  VoidCallback? onPause;
  VoidCallback? onContinue;
  void Function(String)? onError;

  @override
  bool get isInitialized => true;

  @override
  bool get isAvailable => true;

  @override
  void bindHandlers({
    VoidCallback? onStart,
    VoidCallback? onComplete,
    VoidCallback? onCancel,
    VoidCallback? onPause,
    VoidCallback? onContinue,
    void Function(String)? onError,
    void Function(int)? onSentenceIndex,
    void Function(int, int)? onDeviceWordProgress,
  }) {
    this.onStart = onStart;
    this.onComplete = onComplete;
    this.onCancel = onCancel;
    this.onPause = onPause;
    this.onContinue = onContinue;
    this.onError = onError;
  }

  @override
  Future<bool> initialize({
    String? deviceVoice,
    String? serverVoice,
    double speechRate = 0.5,
    double pitch = 1,
    double volume = 1,
    TtsEngine engine = TtsEngine.device,
  }) async => await (initialization ?? Future.value(true));

  @override
  List<String> splitTextForSpeech(String text, {bool seekable = false}) => [
    text,
  ];

  @override
  Future<void> speak(String text, {bool seekable = false}) async {
    spoken.add(text);
    onStart?.call();
  }

  @override
  Future<void> stop() async => onCancel?.call();

  @override
  Future<void> pause() async {
    await pauseResult;
    if (failPause) throw StateError('Synthetic pause failure');
    if (pauseErrorEvent) {
      onError?.call('Synthetic pause failure');
      return;
    }
    onPause?.call();
  }

  @override
  Future<void> resume() async {
    await resumeResult;
    onContinue?.call();
  }
}
