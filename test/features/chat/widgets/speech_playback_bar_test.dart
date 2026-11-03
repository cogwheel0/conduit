import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/widgets/speech_playback_bar.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget _harness(_Playback playback) => ProviderScope(
  overrides: [textToSpeechControllerProvider.overrideWith(() => playback)],
  child: MaterialApp(
    localizationsDelegates: conduitLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const Scaffold(body: SpeechPlaybackBar()),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: const TextScaler.linear(2)),
      child: child!,
    ),
  ),
);

void main() {
  testWidgets('read-aloud shows elapsed time instead of Listen', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(_Playback((_) {})));
    await tester.pumpAndSettle();
    expect(find.text('0:00'), findsOneWidget);
    expect(find.text('Listen'), findsNothing);
  });

  for (final entry in {
    const Duration(seconds: 65): '1:05',
    const Duration(hours: 1, minutes: 2, seconds: 3): '1:02:03',
  }.entries) {
    testWidgets('elapsed timestamp formats ${entry.value}', (tester) async {
      await tester.pumpWidget(_harness(_Playback((_) {}, elapsed: entry.key)));
      await tester.pumpAndSettle();
      expect(find.text(entry.value), findsOneWidget);
    });
  }

  for (final size in [const Size(390, 844), const Size(1024, 768)]) {
    testWidgets('playback controls fit and retain state at 2x text in $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final actions = <String>[];
      await tester.pumpWidget(_harness(_Playback(actions.add)));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        0.5,
      );
      await tester.tap(find.byKey(const ValueKey('speech-playback-toggle')));
      await tester.pumpAndSettle();
      expect(actions, ['pause']);
      await tester.tap(find.byKey(const ValueKey('speech-playback-toggle')));
      await tester.pumpAndSettle();
      expect(actions, ['pause', 'resume']);
      await tester.tap(find.byKey(const ValueKey('speech-playback-stop')));
      await tester.pumpAndSettle();
      expect(actions, ['pause', 'resume', 'stop']);
      expect(find.byKey(const ValueKey('speech-playback-bar')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('audio duration drives progress after a timed seek', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        _Playback(
          (_) {},
          elapsed: const Duration(seconds: 15),
          duration: const Duration(minutes: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      .25,
    );
  });

  testWidgets('15-second skip controls dispatch both directions', (
    tester,
  ) async {
    final actions = <String>[];
    await tester.pumpWidget(_harness(_Playback(actions.add)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('speech-playback-backward')));
    await tester.tap(find.byKey(const ValueKey('speech-playback-forward')));
    expect(actions, ['skip:-15', 'skip:15']);
    final back = tester
        .getCenter(find.byKey(const ValueKey('speech-playback-backward')))
        .dx;
    final play = tester
        .getCenter(find.byKey(const ValueKey('speech-playback-toggle')))
        .dx;
    final forward = tester
        .getCenter(find.byKey(const ValueKey('speech-playback-forward')))
        .dx;
    expect(back, lessThan(play));
    expect(play, lessThan(forward));
  });

  testWidgets('an error offers retry without displaying raw engine details', (
    tester,
  ) async {
    final actions = <String>[];
    await tester.pumpWidget(_harness(_Playback(actions.add, failed: true)));
    await tester.pumpAndSettle();
    expect(find.textContaining('Synthetic engine details'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('speech-playback-retry')));
    await tester.pumpAndSettle();
    expect(actions, ['retry']);
    expect(
      find.byKey(const ValueKey('speech-playback-toggle')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

class _Playback extends TextToSpeechController {
  _Playback(
    this._onAction, {
    bool failed = false,
    this.elapsed = Duration.zero,
    this.duration = Duration.zero,
  }) : _failed = failed;
  final void Function(String) _onAction;
  final bool _failed;
  final Duration elapsed;
  final Duration duration;

  @override
  TextToSpeechState build() => TextToSpeechState(
    elapsed: elapsed,
    duration: duration,
    canSeek: true,
    initialized: true,
    available: true,
    activeMessageId: 'garden-guide',
    status: _failed ? TtsPlaybackStatus.error : TtsPlaybackStatus.speaking,
    errorMessage: _failed ? 'Synthetic engine details' : null,
    sentences: const ['abcd'],
    activeSentenceIndex: 0,
    wordEndInSentence: 2,
  );

  @override
  Future<void> skip(Duration offset) async {
    _onAction('skip:${offset.inSeconds}');
  }

  @override
  Future<void> pause() async {
    _onAction('pause');
    state = state.copyWith(status: TtsPlaybackStatus.paused);
  }

  @override
  Future<void> resume() async {
    _onAction('resume');
    state = state.copyWith(status: TtsPlaybackStatus.speaking);
  }

  @override
  Future<void> retry() async {
    _onAction('retry');
    state = state.copyWith(
      status: TtsPlaybackStatus.speaking,
      clearErrorMessage: true,
    );
  }

  @override
  Future<void> stop() async {
    _onAction('stop');
    state = state.copyWith(
      status: TtsPlaybackStatus.idle,
      clearActiveMessageId: true,
    );
  }
}
